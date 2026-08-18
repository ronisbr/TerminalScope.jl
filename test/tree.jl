## Description #############################################################################
#
# Tests related to the viewer tree model and the machinery skip with auto-descend.
#
############################################################################################

@testset "Tree Construction" begin
    root = TS.build_tree(fixture_graph())

    @test root.count == 100
    @test root.pct_total == 100.0
    @test root.pct_parent == 100.0
    @test root.depth == 0
    @test root.parent === nothing
    @test TS.is_tree_root(root)
    @test TS.count_nodes(root) == 6

    # Children must be sorted by count in descending order.
    @test [c.count for c in root.children] == [80, 15]
    f = root.children[1]
    @test [c.count for c in f.children] == [50, 20]

    # Self samples are the inclusive count minus the children counts.
    @test root.self == 100 - 80 - 15
    @test f.self == 80 - 50 - 20
    @test f.children[1].self == 0

    # Percentages.
    @test f.pct_total == 80.0
    @test f.children[1].pct_parent == 100 * 50 / 80

    # Status flags.
    h = f.children[1].children[1]
    @test TS.is_dispatch(h)
    @test !TS.is_gc(h)
    k = f.children[2]
    @test TS.is_gc(k)
    @test k.sf.from_c

    # Depths.
    @test h.depth == 3
end

@testset "Level Rows" begin
    root = TS.build_tree(fixture_graph())

    # The frame list shows the current node as the pinned parent row plus its children.
    rows = TS.level_rows(root)
    @test [TS.node_name(n) for n in rows] == ["all samples", "f", "m"]

    f = root.children[1]
    @test [TS.node_name(n) for n in TS.level_rows(f)] == ["f", "g", "k"]

    # A leaf lists only itself.
    h = f.children[1].children[1]
    @test TS.level_rows(h) == [h]
end

@testset "Machinery Skip and Auto-Descend" begin
    # A machinery-like profile: a pass-through chain root → a → b carrying ~all samples,
    # branching at c.
    #
    #     root (100)
    #     └── a (98)
    #         └── b (98)
    #             └── c (98)
    #                 ├── d (60)
    #                 └── e (38)
    #                     └── e1 (10)
    ND = FlameGraphs.NodeData
    file = Symbol(@__FILE__)
    root = Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:100))
    a = addchild(root, ND(_sf(:a, file, 1), 0x00, 1:98))
    b = addchild(a, ND(_sf(:b, file, 2), 0x00, 1:98))
    c = addchild(b, ND(_sf(:c, file, 3), 0x00, 1:98))
    addchild(c, ND(_sf(:d, file, 4), 0x00, 1:60))
    e = addchild(c, ND(_sf(:e, file, 5), 0x00, 61:98))
    addchild(e, ND(_sf(:e1, file, 6), 0x00, 61:70))

    m = TS.ProfileViewer(root)

    # The viewer starts past the pass-through chain, at the first branching node.
    @test TS.node_name(m.current) == "c"
    @test TS.node_name.(m.rows) == ["c", "d", "e"]
    @test m.cursor == 2

    # No skip happens when the top child is below the dominance threshold.
    @test TS.is_tree_root(TS.hot_entry(TS.build_tree(fixture_graph())))

    # ← walks back to the first branching ancestor, cursor on the skipped chain.
    update!(m, KeyEvent(:left))
    @test m.current === m.root
    @test TS.node_name(TS.selected_row(m)) == "a"

    # Enter auto-descends through the single-child chain back to the branching point.
    update!(m, KeyEvent(:enter))
    @test TS.node_name(m.current) == "c"
    @test m.cursor == 2

    # Enter on a node whose single child is a leaf stops at the node.
    m.cursor = findfirst(n -> TS.node_name(n) == "e", m.rows)
    update!(m, KeyEvent(:enter))
    @test TS.node_name(m.current) == "e"
    @test TS.node_name.(m.rows) == ["e", "e1"]

    # Backspace inverts each step in one keypress.
    update!(m, KeyEvent(:backspace))
    @test TS.node_name(m.current) == "c"
    @test TS.node_name(TS.selected_row(m)) == "e"
    update!(m, KeyEvent(:backspace))
    @test m.current === m.root
    @test TS.node_name(TS.selected_row(m)) == "a"
end
