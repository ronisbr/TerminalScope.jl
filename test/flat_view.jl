## Description #############################################################################
#
# Tests related to the flat self-time view.
#
############################################################################################

@testset "Aggregation" begin
    m = make_model()

    # Fixture self costs: h = 50, k = 20, m = 15, f = 10, root = 5, and g = 0.
    rows, targets = TS.flat_profile(m.root, m.unit)
    @test [TS.node_name(n) for n in rows] == ["h", "k", "m", "f"]
    @test [n.count for n in rows] == [50, 20, 15, 10]
    @test [n.self for n in rows] == [50, 20, 15, 10]
    @test rows[1].pct_total == 50.0
    @test all(n -> n.parent === m.root, rows)
    @test all(n -> isempty(n.children), rows)
    @test length(targets) == length(rows)

    # The status flags survive the aggregation.
    @test TS.is_dispatch(rows[1])
    @test TS.is_gc(rows[2])

    # Occurrences of the same frame under different parents merge into one row whose
    # target is the hottest occurrence.
    ND = FlameGraphs.NodeData
    root = Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:100))
    a = addchild(root, ND(_sf(:a, Symbol(@__FILE__), 100), 0x00, 1:60))
    addchild(a, ND(_sf(:x, Symbol(@__FILE__), 200), 0x00, 1:40))
    b = addchild(root, ND(_sf(:b, Symbol(@__FILE__), 110), 0x00, 61:100))
    addchild(b, ND(_sf(:x, Symbol(@__FILE__), 200), 0x00, 61:90))

    mg = TS.ProfileViewer(root)
    rows, targets = TS.flat_profile(mg.root, mg.unit)
    @test [TS.node_name(n) for n in rows] == ["x", "a", "b"]
    @test rows[1].count == 70
    @test targets[1].count == 40
    @test TS.node_name(targets[1].parent) == "a"
end

@testset "State Machine" begin
    m = make_model()
    m.visible_h = 10

    # Enter the flat view: flat rows installed, cursor on the hottest one, and the
    # source panel follows the flat selection.
    update!(m, KeyEvent(:char, 's'))
    @test m.flat
    @test [TS.node_name(n) for n in m.rows] == ["h", "k", "m", "f"]
    @test m.cursor == 1
    @test length(m.flat_targets) == 4
    @test m.tree_focus === :list

    # Enter jumps into the tree view at the hottest occurrence.
    h = m.root.children[1].children[1].children[1]
    update!(m, KeyEvent(:enter))
    @test !m.flat
    @test isempty(m.flat_targets)
    @test TS.node_name(m.current) == "g"
    @test TS.selected_row(m) === h

    # Leaving with s (and with Backspace) restores the saved tree position.
    saved_current = m.current
    saved_selected = TS.selected_row(m)
    update!(m, KeyEvent(:char, 's'))
    @test m.flat
    update!(m, KeyEvent(:char, 's'))
    @test !m.flat
    @test m.current === saved_current
    @test TS.selected_row(m) === saved_selected

    update!(m, KeyEvent(:char, 's'))
    update!(m, KeyEvent(:backspace))
    @test !m.flat
    @test m.current === saved_current
    @test TS.selected_row(m) === saved_selected

    # A search jump always lands in the tree view.
    update!(m, KeyEvent(:char, 's'))
    update!(m, KeyEvent(:char, '/'))
    update!(m, KeyEvent(:char, 'h'))
    update!(m, KeyEvent(:enter))
    @test !m.flat
    @test TS.node_name(TS.selected_row(m)) == "h"

    # The invalidations viewer has no flat view.
    mi = TS.invalidation_viewer([(
        method = nothing, reason = :unknown, backedges = Any[], mt_backedges = Any[]
    )])
    update!(mi, KeyEvent(:char, 's'))
    @test !mi.flat
    @test occursin("not available", mi.notice)
end

@testset "Allocation Attribution" begin
    st = stacktrace()
    synth = (
        allocs = [
            Profile.Allocs.Alloc(Vector{Float64}, st, 128, C_NULL, UInt64(0)),
            Profile.Allocs.Alloc(String, st, 32, C_NULL, UInt64(1)),
        ],
    )
    m = TS.alloc_viewer(synth)
    update!(m, KeyEvent(:char, 's'))
    @test m.flat

    # The synthetic type leaves are charged to the allocating call site and are not
    # listed themselves.
    names = [TS.node_name(n) for n in m.rows]
    @test !("String" in names)
    @test !("Vector{Float64}" in names)
    @test sum(n -> n.count, m.rows) == 160
    @test m.rows[1].count == 160
    @test m.rows[1].allocs == 2

    # The unit toggle re-ranks the flat rows in place, staying in the flat view.
    key = TS._flat_key(m.rows[1])
    update!(m, KeyEvent(:char, 'u'))
    @test m.flat
    @test m.unit === :allocs
    @test m.rows[1].count == 2
    @test m.rows[1].allocs == 160
    @test TS._flat_key(m.rows[m.cursor]) == key
end

@testset "Flat Rendering" begin
    m = make_model()
    update!(m, KeyEvent(:char, 's'))

    # The wide backend leaves room for the flat indicator on the right of the status
    # bar hints.
    tb = TestBackend(160, 30)
    frame = Tachikoma.Frame(
        tb.buf, Rect(1, 1, 160, 30), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]
    )
    tview(m, frame)

    # Flat title, Self column label, no pinned parent glyph, and the flat status
    # indicator.
    @test find_text(tb, "[1] Hot Frames") !== nothing
    @test find_text(tb, "Self") !== nothing
    @test find_text(tb, "⬑") === nothing
    @test find_text(tb, "Flat view: hottest frames by self samples") !== nothing

    # The help dialog lists the new bindings.
    update!(m, KeyEvent(:char, '?'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "flat self-time view") !== nothing
    update!(m, KeyEvent(:escape))
end
