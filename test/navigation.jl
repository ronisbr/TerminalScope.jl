## Description #############################################################################
#
# Tests related to the keyboard navigation: drill-down, vim aliases, focus, zoom, and help.
#
############################################################################################

@testset "Key Handling: Drill-Down Navigation" begin
    m = make_model()
    m.visible_h = 10

    # Initial state: the root level is listed and the cursor sits on the hottest child.
    @test TS.node_name.(m.rows) == ["all samples", "f", "m"]
    @test m.cursor == 2
    @test TS.node_name(TS.selected_row(m)) == "f"

    update!(m, KeyEvent(:up))
    @test m.cursor == 1
    @test TS.is_parent_row(m, TS.selected_row(m))

    update!(m, KeyEvent(:up))
    @test m.cursor == 1

    update!(m, KeyEvent(:end_key))
    @test m.cursor == 3

    update!(m, KeyEvent(:home))
    @test m.cursor == 1

    # Enter on the pinned parent row of the root level does nothing (no parent).
    update!(m, KeyEvent(:enter))
    @test m.current === m.root
    @test m.mode == :tree

    # Enter on a node with children descends into it.
    update!(m, KeyEvent(:down))
    update!(m, KeyEvent(:enter))
    @test TS.node_name(m.current) == "f"
    @test TS.node_name.(m.rows) == ["f", "g", "k"]
    @test m.cursor == 2

    # → also descends.
    update!(m, KeyEvent(:right))
    @test TS.node_name(m.current) == "g"
    @test TS.node_name.(m.rows) == ["g", "h"]

    # Enter on a leaf focuses the source panel; Backspace there returns to the list.
    update!(m, KeyEvent(:enter))
    @test m.mode == :tree
    @test m.tree_focus === :code
    update!(m, KeyEvent(:backspace))
    @test m.tree_focus === :list

    # Backspace goes up, placing the cursor on the node the user came from.
    update!(m, KeyEvent(:backspace))
    @test TS.node_name(m.current) == "f"
    @test TS.node_name(TS.selected_row(m)) == "g"

    # ← also goes up.
    update!(m, KeyEvent(:left))
    @test m.current === m.root
    @test TS.node_name(TS.selected_row(m)) == "f"

    # Backspace at the root level does nothing.
    update!(m, KeyEvent(:backspace))
    @test m.current === m.root

    # Enter on the pinned parent row goes up as well.
    update!(m, KeyEvent(:enter))
    @test TS.node_name(m.current) == "f"
    update!(m, KeyEvent(:home))
    @test TS.is_parent_row(m, TS.selected_row(m))
    update!(m, KeyEvent(:enter))
    @test m.current === m.root

    # q quits.
    @test !should_quit(m)
    update!(m, KeyEvent(:char, 'q'))
    @test should_quit(m)
end

@testset "Key Handling: Vim Aliases" begin
    m = make_model()
    m.visible_h = 10

    # j / k / g / G move the cursor like ↓ / ↑ / Home / End.
    update!(m, KeyEvent(:char, 'k'))
    @test m.cursor == 1
    update!(m, KeyEvent(:char, 'j'))
    @test m.cursor == 2
    update!(m, KeyEvent(:char, 'G'))
    @test m.cursor == length(m.rows)
    update!(m, KeyEvent(:char, 'g'))
    @test m.cursor == 1

    # l descends and h ascends like → and ←.
    update!(m, KeyEvent(:char, 'j'))
    update!(m, KeyEvent(:char, 'l'))
    @test TS.node_name(m.current) == "f"
    update!(m, KeyEvent(:char, 'h'))
    @test m.current === m.root
    @test TS.node_name(TS.selected_row(m)) == "f"

    # j / k scroll the code when the source panel is focused.
    m.tree_focus = :code
    d = m.detail
    d.node = m.rows[2]
    d.src_lines = ["line $i" for i in 1:100]
    d.src_chars = collect.(d.src_lines)
    d.src_segments = [Tuple{UnitRange{Int}, TS.Style}[] for _ in 1:100]
    d.src_h = 10
    d.src_scroll = 0

    update!(m, KeyEvent(:char, 'j'))
    @test d.src_scroll == 1
    update!(m, KeyEvent(:char, 'k'))
    @test d.src_scroll == 0
    update!(m, KeyEvent(:char, 'G'))
    @test d.src_scroll == 90
    update!(m, KeyEvent(:char, 'g'))
    @test d.src_scroll == 0
end

@testset "Key Handling: Source Panel and Help" begin
    m = make_model()
    m.visible_h = 10

    # The source panel follows the row under the cursor: syncing loads its source (the
    # fixture frames point to this file).
    TS.sync_source!(m)
    @test TS.node_name(m.detail.node) == "f"
    @test m.detail.src_error === nothing
    @test !isempty(m.detail.src_lines)

    # Tab and the number keys move the focus between the panels.
    @test m.tree_focus === :list
    update!(m, KeyEvent(:tab))
    @test m.tree_focus === :code
    update!(m, KeyEvent(:tab))
    @test m.tree_focus === :list
    update!(m, KeyEvent(:char, '2'))
    @test m.tree_focus === :code
    update!(m, KeyEvent(:char, '1'))
    @test m.tree_focus === :list

    # + and - move the zoom one step at a time, anchored to the zoomed panel; Esc
    # restores the default split.
    update!(m, KeyEvent(:char, '+'))
    @test (m.zoom, m.zoom_panel) == (1, :list)
    update!(m, KeyEvent(:char, '-'))
    @test m.zoom == 0

    # Shrinking at the default split zooms the other panel, and growing the focused
    # panel walks the split back toward the default.
    update!(m, KeyEvent(:char, '-'))
    @test (m.zoom, m.zoom_panel) == (1, :code)
    update!(m, KeyEvent(:char, '+'))
    @test m.zoom == 0

    # Repeated - keeps the focused panel at its minimum size instead of hiding it.
    foreach(_ -> update!(m, KeyEvent(:char, '-')), 1:(TS.ZOOM_MAX + 2))
    @test (m.zoom, m.zoom_panel) == (TS.ZOOM_MAX - 1, :code)
    update!(m, KeyEvent(:escape))

    foreach(_ -> update!(m, KeyEvent(:char, '+')), 1:(TS.ZOOM_MAX + 1))
    @test (m.zoom, m.zoom_panel) == (TS.ZOOM_MAX, :list)

    # The anchored split does not follow the focus below the maximized mode, while the
    # maximized mode re-anchors the zoom on the focused panel when stepping.
    update!(m, KeyEvent(:char, '2'))
    @test (m.zoom, m.zoom_panel) == (TS.ZOOM_MAX, :list)
    update!(m, KeyEvent(:char, '-'))
    @test (m.zoom, m.zoom_panel) == (TS.ZOOM_MAX - 1, :code)
    update!(m, KeyEvent(:char, '1'))
    @test (m.zoom, m.zoom_panel) == (TS.ZOOM_MAX - 1, :code)
    update!(m, KeyEvent(:escape))
    @test m.zoom == 0

    # With the source panel focused, the movement keys scroll the code.
    update!(m, KeyEvent(:char, '2'))
    m.detail.src_h = 8
    update!(m, KeyEvent(:home))
    @test m.detail.src_scroll == 0
    update!(m, KeyEvent(:down))
    @test m.detail.src_scroll == 1

    # Horizontal scrolling with ← / → and the vim-like 0 / $ keys.
    update!(m, KeyEvent(:right))
    @test m.detail.src_hscroll == 4
    update!(m, KeyEvent(:left))
    @test m.detail.src_hscroll == 0
    update!(m, KeyEvent(:char, '$'))
    @test m.detail.src_hscroll > 0
    update!(m, KeyEvent(:char, '0'))
    @test m.detail.src_hscroll == 0

    # Half-page scrolling with Ctrl+D / Ctrl+U.
    m.detail.src_h = 8
    update!(m, KeyEvent(:home))
    update!(m, KeyEvent(:ctrl, 'd'))
    @test m.detail.src_scroll == 4
    update!(m, KeyEvent(:ctrl, 'u'))
    @test m.detail.src_scroll == 0

    # Enter in the code panel returns the focus to the list.
    update!(m, KeyEvent(:enter))
    @test m.tree_focus === :list

    # The help dialog opens with ? and closes with Esc, ignoring tree keys meanwhile.
    update!(m, KeyEvent(:char, '?'))
    @test m.help
    c0 = m.cursor
    update!(m, KeyEvent(:down))
    @test m.cursor == c0
    update!(m, KeyEvent(:escape))
    @test !m.help

    # q closes the help dialog without quitting.
    update!(m, KeyEvent(:char, '?'))
    update!(m, KeyEvent(:char, 'q'))
    @test !m.help
    @test !should_quit(m)
end
