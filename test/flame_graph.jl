## Description #############################################################################
#
# Tests related to the flame-graph panel.
#
############################################################################################

"""
    _flame_frame(tb) -> Tachikoma.Frame

Create a fresh frame over the buffer of the test backend `tb`, with empty graphics
regions so each render starts clean.
"""
function _flame_frame(tb)
    return Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, tb.buf.area.width, tb.buf.area.height),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[],
    )
end

"""
    _with_gfx(f::Function, protocol) -> Any

Run `f()` with the global graphics protocol forced to `protocol`, restoring the previous
value afterwards.
"""
function _with_gfx(f::Function, protocol)
    old = Tachikoma.GRAPHICS_PROTOCOL[]
    Tachikoma.GRAPHICS_PROTOCOL[] = protocol

    try
        return f()
    finally
        Tachikoma.GRAPHICS_PROTOCOL[] = old
    end
end

@testset "Span Layout" begin
    m = make_model()
    root = m.root
    f = root.children[1]

    # Whole-tree layout: children packed left-aligned in cost order, one level per
    # depth, and the right-hand self remainder unfilled.
    levels = TS._flame_levels(root, root, 1000, 4)
    @test length(levels) == 4

    @test length(levels[1]) == 1
    @test levels[1][1].node === root
    @test levels[1][1].x0 == 0.0
    @test levels[1][1].x1 == 1.0

    @test [TS.node_name(s.node) for s in levels[2]] == ["f", "m"]
    @test levels[2][1].x0 == 0.0
    @test levels[2][1].x1 ≈ 0.8
    @test levels[2][2].x0 ≈ 0.8
    @test levels[2][2].x1 ≈ 0.95

    @test [TS.node_name(s.node) for s in levels[3]] == ["g", "k"]
    @test levels[3][1].x0 == 0.0
    @test levels[3][1].x1 ≈ 0.5
    @test levels[3][2].x0 ≈ 0.5
    @test levels[3][2].x1 ≈ 0.7

    @test [TS.node_name(s.node) for s in levels[4]] == ["h"]

    # When the root is the current node, every span is inside its subtree, and only the
    # root itself is on the path.
    @test levels[1][1].flags == (TS.FLAME_PATH | TS.FLAME_SUBTREE)
    @test levels[2][1].flags == TS.FLAME_SUBTREE
    @test levels[4][1].flags == TS.FLAME_SUBTREE

    # With the current node deeper in the tree, its ancestors carry the path flag, its
    # subtree the subtree flag, and the other branches none.
    levels = TS._flame_levels(root, f, 1000, 4)
    @test levels[1][1].flags == TS.FLAME_PATH
    @test levels[2][1].flags == (TS.FLAME_PATH | TS.FLAME_SUBTREE)
    @test levels[2][2].flags == 0x00
    @test levels[3][1].flags == TS.FLAME_SUBTREE
    @test levels[3][2].flags == TS.FLAME_SUBTREE

    # A frame narrower than one pixel is culled with its subtree, without disturbing the
    # offsets of the other spans.
    levels = TS._flame_levels(root, root, 6, 4)
    @test [TS.node_name(s.node) for s in levels[2]] == ["f"]
    @test levels[3][1].x0 == 0.0
    @test levels[3][1].x1 ≈ 0.5
    @test levels[3][2].x0 ≈ 0.5
    @test levels[3][2].x1 ≈ 0.7

    # The surviving depth honors the same culling.
    @test TS._flame_depth(root, 1000) == 4
    @test TS._flame_depth(root, 6) == 4
end

@testset "Hidden Without Graphics" begin
    m = make_model()
    tb = TestBackend(100, 30)
    frame = _flame_frame(tb)
    tview(m, frame)

    # No graphics protocol: the panel is hidden and the layout is the two-panel one.
    @test isempty(frame.gfx_regions)
    @test m.flame.rect.width == 0
    @test find_text(tb, "[1] Frames") !== nothing
    @test find_text(tb, "Flame Graph") === nothing
    @test TS.flame_active(m) == false
end

@testset "Rendered With Graphics" begin
    _with_gfx(Tachikoma.gfx_kitty) do
        m = make_model()
        tb = TestBackend(100, 30)
        frame = _flame_frame(tb)
        tview(m, frame)

        # One graphics region in the bottom band of the body.
        @test length(frame.gfx_regions) == 1
        region = frame.gfx_regions[1]
        @test region.row > 20
        @test find_text(tb, "Flame Graph") !== nothing
        @test m.flame.rect.width > 0

        # The pixel buffer follows the deterministic headless cell size (8 x 16 px).
        img = m.flame.img
        @test img.pixel_w == 8 * m.flame.rect.width
        @test img.pixel_h == 16 * m.flame.rect.height

        # The production Sixel occlusion filter keeps the region: no text was written
        # inside the image area.
        @test Tachikoma._filter_visible_gfx(frame.gfx_regions, tb.buf) == frame.gfx_regions

        # The heat drawing filled pixels, and the selected node is painted with the
        # theme primary color.
        sel = to_rgb(theme().primary)
        @test any(p -> (p.r, p.g, p.b) == (sel.r, sel.g, sel.b), img.pixels)

        # The panel is hidden while a panel is maximized.
        foreach(_ -> update!(m, KeyEvent(:char, '+')), 1:TS.ZOOM_MAX)
        Tachikoma.reset!(tb.buf)
        frame = _flame_frame(tb)
        tview(m, frame)
        @test isempty(frame.gfx_regions)
        @test m.flame.rect.width == 0
        update!(m, KeyEvent(:escape))
    end
end

@testset "Mouse" begin
    _with_gfx(Tachikoma.gfx_kitty) do
        m = make_model()
        tb = TestBackend(100, 30)
        frame = _flame_frame(tb)
        tview(m, frame)
        r = m.flame.rect

        # Click a rectangle that is not selected: the cursor moves to the node in its
        # own level (level 3 is g, a child of f).
        row = findfirst(==(3), m.flame.row_level)
        @test row !== nothing
        y = r.y + row - 1
        update!(m, MouseEvent(r.x + 1, y, mouse_left, mouse_press, false, false, false))
        @test TS.node_name(m.current) == "f"
        @test TS.node_name(TS.selected_row(m)) == "g"
        @test m.tree_focus === :list

        # A second click on the now-selected rectangle enters it.
        Tachikoma.reset!(tb.buf)
        frame = _flame_frame(tb)
        tview(m, frame)
        r = m.flame.rect
        row = findfirst(==(3), m.flame.row_level)
        y = r.y + row - 1
        update!(m, MouseEvent(r.x + 1, y, mouse_left, mouse_press, false, false, false))
        @test TS.node_name(m.current) == "g"

        # The wheel over the panel ascends and descends the tree.
        update!(
            m, MouseEvent(r.x + 1, r.y, mouse_scroll_up, mouse_press, false, false, false)
        )
        @test TS.node_name(m.current) == "f"

        # A click over a background cell row (no band) does nothing.
        row = findfirst(==(0), m.flame.row_level)

        if row !== nothing
            cur = m.current
            y = r.y + row - 1
            update!(m, MouseEvent(r.x + 1, y, mouse_left, mouse_press, false, false, false))
            @test m.current === cur
        end
    end
end

@testset "Visibility Toggle" begin
    # Under a graphics protocol, f hides and restores the panel.
    _with_gfx(Tachikoma.gfx_kitty) do
        m = make_model()
        tb = TestBackend(100, 30)
        frame = _flame_frame(tb)
        tview(m, frame)
        @test length(frame.gfx_regions) == 1

        update!(m, KeyEvent(:char, 'f'))
        @test !m.flame.visible
        Tachikoma.reset!(tb.buf)
        frame = _flame_frame(tb)
        tview(m, frame)
        @test isempty(frame.gfx_regions)
        @test m.flame.rect.width == 0

        update!(m, KeyEvent(:char, 'f'))
        @test m.flame.visible
        Tachikoma.reset!(tb.buf)
        frame = _flame_frame(tb)
        tview(m, frame)
        @test length(frame.gfx_regions) == 1
    end

    # While the help dialog is open, the panel is hidden so the dialog is never
    # occluded by the image (Kitty draws images above the text).
    _with_gfx(Tachikoma.gfx_kitty) do
        m = make_model()
        update!(m, KeyEvent(:char, '?'))
        tb = TestBackend(100, 30)
        frame = _flame_frame(tb)
        tview(m, frame)
        @test isempty(frame.gfx_regions)
        @test m.flame.rect.width == 0
        update!(m, KeyEvent(:escape))
    end

    # Without a graphics protocol, f explains why the panel cannot be shown.
    m = make_model()
    update!(m, KeyEvent(:char, 'f'))
    @test m.flame.visible
    @test occursin("Kitty or Sixel", m.notice)
end

@testset "Invalidations Excluded" begin
    _with_gfx(Tachikoma.gfx_kitty) do
        mi = TS.invalidation_viewer([(
            method = nothing, reason = :unknown, backedges = Any[], mt_backedges = Any[]
        )])
        tb = TestBackend(100, 30)
        frame = _flame_frame(tb)
        tview(mi, frame)
        @test isempty(frame.gfx_regions)
        @test find_text(tb, "Flame Graph") === nothing

        update!(mi, KeyEvent(:char, 'f'))
        @test occursin("no flame graph", mi.notice)
    end
end

@testset "Deep Tree Truncation" begin
    _with_gfx(Tachikoma.gfx_kitty) do
        # A 40-level chain does not fit the panel bands, so the drawing truncates and
        # flags it.
        ND = FlameGraphs.NodeData
        root = Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:100))
        node = root

        for i in 1:40
            node = addchild(
                node, ND(_sf(Symbol("d", i), Symbol(@__FILE__), i), 0x00, 1:100)
            )
        end

        m = TS.ProfileViewer(root)
        tb = TestBackend(100, 30)
        frame = _flame_frame(tb)
        tview(m, frame)
        @test length(frame.gfx_regions) == 1
        @test m.flame.truncated
        @test length(m.flame.levels) < 40
    end
end

@testset "Repaint Signature" begin
    _with_gfx(Tachikoma.gfx_kitty) do
        m = make_model()
        tb = TestBackend(100, 30)
        tview(m, _flame_frame(tb))

        # Stable without state changes, and sensitive to the cursor and the light mode.
        s1 = TS._flame_sig(m)
        @test TS._flame_sig(m) == s1

        TS.move_cursor!(m, +1)
        s2 = TS._flame_sig(m)
        @test s2 != s1

        old_light = Tachikoma.light_mode()
        Tachikoma.set_light_mode!(!old_light)
        @test TS._flame_sig(m) != s2
        Tachikoma.set_light_mode!(old_light)
        @test TS._flame_sig(m) == s2
    end
end
