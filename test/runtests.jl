## Description #############################################################################
#
# Tests for TerminalScope.jl.
#
############################################################################################

using Test

using FlameGraphs
using LeftChildRightSiblingTrees
using Profile
using Tachikoma
using TerminalScope

import Cthulhu
import Preferences
import SnoopCompile
import SnoopCompileCore

using Base.StackTraces: StackFrame

import Tachikoma: update!, should_quit

const TS = TerminalScope

"""
    tview(m, f) -> Nothing

Call `Tachikoma.view`, which is not exported to avoid clashing with `Base.view`.
"""
tview(m, f) = Tachikoma.view(m, f)

############################################################################################
#                                         Fixture                                          #
############################################################################################

"""
    _sf(func::Symbol, file::Symbol, line::Int; from_c::Bool = false) -> StackFrame

Create a `StackFrame` for the test fixture.
"""
function _sf(func::Symbol, file::Symbol, line::Int; from_c::Bool = false)
    return StackFrame(func, file, line, nothing, from_c, false, 0)
end

"""
    fixture_graph() -> LeftChildRightSiblingTrees.Node{FlameGraphs.NodeData}

Build a hand-crafted flame graph with a known structure:

    root (100)
    ├── f (80)
    │   ├── g (50)
    │   │   └── h (50)   [runtime dispatch]
    │   └── k (20)       [GC]
    └── m (15)
"""
function fixture_graph()
    ND = FlameGraphs.NodeData
    root = Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:100))
    f = addchild(root, ND(_sf(:f, Symbol(@__FILE__), 10), 0x00, 1:80))
    g = addchild(f, ND(_sf(:g, Symbol(@__FILE__), 20), 0x00, 1:50))
    addchild(g, ND(_sf(:h, Symbol(@__FILE__), 30), FlameGraphs.runtime_dispatch, 1:50))
    addchild(f, ND(_sf(:k, :Sys, 40; from_c = true), FlameGraphs.gc_event, 51:70))
    addchild(root, ND(_sf(:m, Symbol("missing_file.jl"), 5), 0x00, 81:95))
    return root
end

"""
    make_model() -> TS.ProfileViewer

Create a viewer model from the test fixture graph.
"""
make_model() = TS.ProfileViewer(fixture_graph())

############################################################################################
#                                        Test Sets                                         #
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

@testset "Formatting" begin
    @test TS.format_count(0) == "0"
    @test TS.format_count(999) == "999"
    @test TS.format_count(1234) == "1,234"
    @test TS.format_count(1234567) == "1,234,567"

    @test TS.format_pct(57.34) == "57.3%"
    @test TS.format_pct(0.0) == "0.0%"
    @test TS.format_pct(0.04) == "<0.1%"
    @test TS.format_pct(100.0) == "100.0%"

    @test TS.format_seconds(0.0) == "0.0 ns"
    @test TS.format_seconds(4.2e-7) == "420.0 ns"
    @test TS.format_seconds(3.4e-4) == "340.0 µs"
    @test TS.format_seconds(0.0012) == "1.2 ms"
    @test TS.format_seconds(12.34) == "12.34 s"
    @test TS.format_seconds(65.0) == "1 min 5.0 s"

    @test length(TS.bar_string(50.0, 8)) == 8
    @test TS.bar_string(100.0, 4) == "████"
    @test TS.bar_string(0.0, 4) == "    "

    root = TS.build_tree(fixture_graph())
    @test TS.node_name(root) == "all samples"
    @test TS.node_location(root) == ""
    f = root.children[1]
    @test TS.node_name(f) == "f"
    @test endswith(TS.node_location(f), ":10")
    @test TS.node_package(f) == "TerminalScope.jl"
    @test TS.node_package(root) === nothing

    # Package resolution of source files.
    @test TS.file_package(@__FILE__) == "TerminalScope.jl"
    @test TS.file_package(pathof(Profile)) == "Profile.jl"
    @test TS.file_package("this_file_does_not_exist.jl") === nothing
    @test TS.file_package("") === nothing

    int_jl = Base.find_source_file("int.jl")
    ((int_jl !== nothing) && isfile(int_jl)) && @test TS.file_package("int.jl") == "Base"
end

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

@testset "Mouse Handling" begin
    mev(x, y, btn) = MouseEvent(x, y, btn, mouse_press, false, false, false)

    m = make_model()
    tb = TestBackend(100, 30)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, 100, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    tview(m, frame)

    # Rendering records the panel areas used by the mouse hit tests.
    lr = m.list_rows_rect
    cr = m.code_rect
    @test (lr.width > 0) && (lr.height > 0)
    @test (cr.width > 0) && (cr.height > 0)

    # The wheel over the frame list moves the cursor and focuses the list.
    m.tree_focus = :code
    c0 = m.cursor
    update!(m, mev(lr.x, lr.y, mouse_scroll_down))
    @test m.cursor == c0 + 1
    @test m.tree_focus === :list
    update!(m, mev(lr.x, lr.y, mouse_scroll_up))
    @test m.cursor == c0

    # A click moves the cursor to the clicked row, and clicking the selected row again
    # enters it.
    update!(m, mev(lr.x + 2, lr.y, mouse_left))
    @test m.cursor == 1
    update!(m, mev(lr.x + 2, lr.y + 1, mouse_left))
    @test m.cursor == 2
    @test TS.node_name(TS.selected_row(m)) == "f"
    update!(m, mev(lr.x + 2, lr.y + 1, mouse_left))
    @test TS.node_name(m.current) == "f"

    # A click below the listed rows does nothing.
    rows_n = length(m.rows)
    cur = m.cursor
    update!(m, mev(lr.x, lr.y + rows_n + 3, mouse_left))
    @test (m.cursor == cur) && (TS.node_name(m.current) == "f")

    # The wheel over the source panel scrolls the code and focuses the panel.
    tview(m, frame)
    d = m.detail
    s0 = d.src_scroll
    update!(m, mev(cr.x + 1, cr.y + 1, mouse_scroll_down))
    @test m.tree_focus === :code
    @test d.src_scroll == s0 + 3
    update!(m, mev(cr.x + 1, cr.y + 1, mouse_scroll_up))
    @test d.src_scroll == s0

    # Non-left buttons and release events are ignored.
    update!(m, mev(lr.x, lr.y, mouse_right))
    @test m.tree_focus === :code
    update!(m, MouseEvent(lr.x, lr.y, mouse_left, mouse_release, false, false, false))
    @test m.tree_focus === :code

    # A click closes the help dialog.
    update!(m, KeyEvent(:char, '?'))
    @test m.help
    update!(m, mev(lr.x, lr.y, mouse_left))
    @test !m.help
end

@testset "Frame Search" begin
    m = make_model()
    m.visible_h = 10

    # Typing the query: / opens the prompt, characters append, Backspace deletes, and
    # Esc cancels without searching.
    update!(m, KeyEvent(:char, '/'))
    @test m.search_input == ""
    update!(m, KeyEvent(:char, 'x'))
    update!(m, KeyEvent(:char, 'y'))
    @test m.search_input == "xy"
    update!(m, KeyEvent(:backspace))
    @test m.search_input == "x"
    update!(m, KeyEvent(:escape))
    @test m.search_input === nothing
    @test isempty(m.search_matches)

    # While the prompt is open, q and ? are query text, not global keys.
    update!(m, KeyEvent(:char, '/'))
    update!(m, KeyEvent(:char, 'q'))
    update!(m, KeyEvent(:char, '?'))
    @test m.search_input == "q?"
    @test !m.help
    @test !should_quit(m)
    update!(m, KeyEvent(:escape))

    # n and N without a confirmed search do nothing.
    update!(m, KeyEvent(:char, 'n'))
    @test m.search_idx == 0
    @test m.current === m.root

    # Searching for a deep frame navigates the viewer to its level, and the search is
    # case-insensitive.
    update!(m, KeyEvent(:char, '/'))
    update!(m, KeyEvent(:char, 'H'))
    update!(m, KeyEvent(:enter))
    @test m.search_input === nothing
    @test m.search_query == "H"
    @test length(m.search_matches) == 1
    @test m.search_idx == 1
    @test TS.node_name(m.current) == "g"
    @test TS.node_name(TS.selected_row(m)) == "h"
    @test m.tree_focus === :list
    @test occursin("Match 1/1", m.notice)

    # n / N cycle through the matches with wraparound. The query "f" matches the frame
    # f by name and the frame m by its location (missing_file.jl).
    update!(m, KeyEvent(:char, '/'))
    update!(m, KeyEvent(:char, 'f'))
    update!(m, KeyEvent(:enter))
    @test length(m.search_matches) == 2
    @test m.search_idx == 1
    @test TS.node_name(TS.selected_row(m)) == "f"
    update!(m, KeyEvent(:char, 'n'))
    @test m.search_idx == 2
    @test TS.node_name(TS.selected_row(m)) == "m"
    update!(m, KeyEvent(:char, 'n'))
    @test m.search_idx == 1
    update!(m, KeyEvent(:char, 'N'))
    @test m.search_idx == 2

    # A query without matches keeps the position and reports a notice.
    cur = m.current
    update!(m, KeyEvent(:char, '/'))

    for c in "zzz"
        update!(m, KeyEvent(:char, c))
    end

    update!(m, KeyEvent(:enter))
    @test isempty(m.search_matches)
    @test occursin("No frames match", m.notice)
    @test m.current === cur

    # The status bar renders the open prompt.
    tb = TestBackend(100, 30)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, 100, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    update!(m, KeyEvent(:char, '/'))
    update!(m, KeyEvent(:char, 'a'))
    tview(m, frame)
    @test find_text(tb, "/a") !== nothing
    update!(m, KeyEvent(:escape))
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

@testset "Source Panel Resolution" begin
    m = make_model()
    m.visible_h = 10

    # C frame: no source. k is a child of f, so descend into f first.
    update!(m, KeyEvent(:enter))
    m.cursor = findfirst(n -> TS.node_name(n) == "k", m.rows)
    TS.sync_source!(m)
    @test m.detail.src_error == "C function — no Julia source"

    # Missing file: informative error.
    update!(m, KeyEvent(:backspace))
    m.cursor = findfirst(n -> TS.node_name(n) == "m", m.rows)
    TS.sync_source!(m)
    @test m.detail.src_error == "Source file not found"

    # Root: aggregate node.
    m.cursor = 1
    TS.sync_source!(m)
    @test m.detail.src_error == "Aggregate node — no source"
end

@testset "Syntax Highlighting" begin
    code = "function f(x)\n    return \"hi\" # comment\nend\n"
    segs = TS.highlight_lines(code, 3)
    @test length(segs) == 3

    # The `function` keyword must be its own styled segment.
    @test segs[1][1][1] == 1:8
    @test TS.face_style(:julia_keyword).fg !== nothing

    # The first line must mix differently styled segments.
    @test length(unique(last.(segs[1]))) >= 2

    # The segments must cover the entire line without gaps.
    @test first(segs[1][1][1]) == 1
    @test last(segs[1][end][1]) == length("function f(x)")

    # An empty line produces no segments; degenerate inputs keep the line count.
    @test isempty(TS.highlight_lines("a\n\nb", 3)[2])
    @test length(TS.highlight_lines("", 1)) == 1
    @test length(TS.highlight_lines("x", 1)) == 1
end

@testset "Compilation Info" begin
    # Wall-clock compile statistics are shown on the second header line.
    m = TS.ProfileViewer(fixture_graph(); compile = TS.CompileStats(2.0, 0.5, 0.05))
    @test m.compile !== nothing

    tb = TestBackend(100, 30)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, 100, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    tview(m, frame)
    @test find_text(tb, "Compile") !== nothing

    # 0.5 s of a 2.0 s run, and 0.05 s of the 0.5 s compilation.
    @test find_text(tb, "25.0%") !== nothing
    @test find_text(tb, "10.0%") !== nothing

    # Compiler module detection.
    @test TS._is_compiler_module(Core.Compiler)
    @test !TS._is_compiler_module(Base)
    @test !TS._is_compiler_module(Main)

    # Inference frames are detected through the module of their method instance.
    mi = nothing

    for f in (Core.Compiler.typeinf, Core.Compiler.widenconst)
        for meth in methods(f)
            sp = collect(Base.specializations(meth))

            if !isempty(sp)
                mi = first(sp)
                break
            end
        end

        (mi === nothing) || break
    end

    if mi === nothing
        @warn "No compiler method instance was found. Skipping the detection test."
    else
        sf = StackFrame(:typeinf, Symbol("typeinfer.jl"), 1, mi, false, false, 0)
        @test TS.is_inference_frame(sf)
    end

    @test !TS.is_inference_frame(_sf(:f, Symbol(@__FILE__), 1))

    # The aggregate counts only the topmost inference subtrees.
    root = TS.build_tree(fixture_graph())
    @test TS.inference_samples(root) == 0
    root.children[1].inference = true
    root.children[1].children[1].children[1].inference = true
    @test TS.inference_samples(root) == 80
end

@testset "Inference Profiling" begin
    @eval _snoop_target(x) = sum(abs2, [x, 2x, 3x])
    tinf = SnoopCompileCore.@snoop_inference Base.invokelatest(_snoop_target, 3.0)

    root = TS.build_inference_tree(tinf)
    @test TS.is_tree_root(root)
    @test TS.node_name(root) == "inference"
    @test root.count >= 0

    m = TS.inference_viewer(tinf)
    @test m.unit === :time
    @test m.compile === nothing
    @test m.inference_samples == 0

    tb = TestBackend(100, 30)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, 100, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    tview(m, frame)
    @test find_text(tb, "Inference Profile") !== nothing
    @test find_text(tb, "Inf. Time") !== nothing

    if isempty(m.root.children)
        @warn "No inference was recorded. Skipping the inference detail test."
    else
        # The info strip of an inferred frame shows the time costs.
        Tachikoma.reset!(tb.buf)
        tview(m, frame)
        @test find_text(tb, "Inclusive") !== nothing
    end

    # The macro expands without errors.
    @test (@macroexpand @scope inference 1 + 1) isa Expr
    @test (@macroexpand @scope 1 + 1) isa Expr
    @test (@macroexpand @scope delay = 0.0001 1 + 1) isa Expr
    @test (@macroexpand @scope delay = 0.0001 n = 10^7 1 + 1) isa Expr
    @test_throws ArgumentError (@macroexpand @scope foo = 1 1 + 1)

    # The delay option configures the sampling profiler; run the expansion up to (but
    # not including) the viewer launch.
    old_n, old_delay = Profile.init()
    ex = @macroexpand @scope delay = 0.002 (1 + 1)
    Core.eval(@__MODULE__, Expr(:block, ex.args[1:(end - 1)]...))
    @test Profile.init()[2] == 0.002
    Profile.init(; n = old_n, delay = old_delay)
end

@testset "Rendering" begin
    m = make_model()
    tb = TestBackend(100, 30)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, 100, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )

    # Frame list at the root level: pinned parent row plus the children.
    tview(m, frame)
    @test find_text(tb, "Samples") !== nothing
    @test find_text(tb, "100") !== nothing
    @test find_text(tb, "all samples") !== nothing
    @test find_text(tb, "f") !== nothing
    @test find_text(tb, "80.0%") !== nothing
    @test find_text(tb, "q") !== nothing

    # Descend into f: the level shows the [GC] tag of k.
    update!(m, KeyEvent(:enter))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[GC]") !== nothing

    # Descend into g: the level shows the [dyn] tag of h.
    update!(m, KeyEvent(:enter))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[dyn]") !== nothing

    # The source panel follows the selection: it shows the info strip and the source,
    # with the owner package tagged after the file location.
    @test find_text(tb, "[1] Frames") !== nothing
    @test find_text(tb, "[2] runtests.jl") !== nothing
    @test find_text(tb, "[TerminalScope.jl]") !== nothing
    @test find_text(tb, "Samples") !== nothing

    # Zoom: each + grows the focused panel one step, maximizing it at the last step, and
    # Esc restores the default split.
    pos0 = find_text(tb, "[2] runtests.jl")
    update!(m, KeyEvent(:char, '+'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[1] Frames") !== nothing
    pos1 = find_text(tb, "[2] runtests.jl")
    @test pos1 !== nothing
    @test pos1.x > pos0.x

    # Changing the focus must not move the anchored split.
    update!(m, KeyEvent(:char, '2'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    pos2 = find_text(tb, "[2] runtests.jl")
    @test pos2 !== nothing
    @test pos2.x == pos1.x
    update!(m, KeyEvent(:char, '1'))

    foreach(_ -> update!(m, KeyEvent(:char, '+')), 1:(TS.ZOOM_MAX - 1))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[1] Frames") !== nothing
    @test find_text(tb, "[2] runtests.jl") === nothing
    update!(m, KeyEvent(:char, '2'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[1] Frames") === nothing
    @test find_text(tb, "[2] runtests.jl") !== nothing
    update!(m, KeyEvent(:escape))
    update!(m, KeyEvent(:char, '1'))

    # Help dialog.
    update!(m, KeyEvent(:char, '?'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "Help") !== nothing
    @test find_text(tb, "Quit the application") !== nothing
    @test find_text(tb, "esc to close") !== nothing

    # Degenerate terminal size.
    tb2 = TestBackend(10, 3)
    frame2 = Tachikoma.Frame(
        tb2.buf,
        Rect(1, 1, 10, 3),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    m2 = make_model()
    tview(m2, frame2)
    @test find_text(tb2, "Terminal") !== nothing
end

"""
    _inspect_unstable(x) -> Union{Int, Float64}

Type-unstable helper inspected by the type-instability inspector tests.
"""
_inspect_unstable(x) = x > 0 ? 1 : 2.0

"""
    _inspect_caller(x) -> Float64

Caller of the type-unstable helper inspected by the type-instability inspector tests.
"""
function _inspect_caller(x)
    a = _inspect_unstable(x)
    return Float64(a) + 1.0
end

@testset "Type Instability Inspector" begin
    # ANSI escape parsing into styled spans.
    lines = TS.ansi_spans("plain\n\e[33myellow\e[39m tail\n\e[1;31mboldred\e[0m")
    @test length(lines) == 3
    @test length(lines[1]) == 1
    @test lines[1][1].content == "plain"

    @test lines[2][1].content == "yellow"
    @test lines[2][1].style.fg == Tachikoma.Color256(3)
    @test lines[2][2].content == " tail"

    @test lines[3][1].content == "boldred"
    @test lines[3][1].style.bold
    @test lines[3][1].style.fg == Tachikoma.Color256(1)

    # Extended 256-color sequences.
    ext = TS.ansi_spans("\e[38;5;99mx\e[0m")
    @test ext[1][1].style.fg == Tachikoma.Color256(99)

    # Stability classification: concrete, small union, and abstract types.
    @test !TS.is_unstable_rt(Int)
    @test TS.is_unstable_rt(Union{Int, Float64})
    @test TS.is_unstable_rt(Any)
    @test TS.type_stability_style(Int).fg == TS.tstyle(:primary).fg
    @test TS.type_stability_style(Union{Int, Float64}).fg == TS.tstyle(:warning).fg
    @test TS.type_stability_style(Any).fg == TS.tstyle(:error).fg

    # Standalone inspector on a type-unstable call chain.
    mi = Cthulhu.get_specialization(_inspect_caller, Tuple{Int})
    m = TS.inspector_viewer(mi)
    @test m.mode == :inspect
    @test m.inspect.standalone
    @test length(m.inspect.stack) == 1

    fr = TS.inspect_top(m.inspect)
    @test !isempty(fr.entries)
    @test fr.src_error === nothing
    @test !isempty(fr.code_lines)
    @test !isempty(fr.ir_lines)
    @test any(TS.is_unstable_entry, fr.entries)

    # The unstable callee appears in the list with its Union return type.
    idx = findfirst(e -> occursin("_inspect_unstable", e.label), fr.entries)
    @test idx !== nothing
    @test occursin("Union", fr.entries[idx].rt_str)
    @test fr.entries[idx].ci !== nothing

    # Rendering.
    tb = TestBackend(110, 30)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, 110, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    tview(m, frame)
    @test find_text(tb, "Type Inspector") !== nothing
    @test find_text(tb, "[2] Call Sites") !== nothing
    @test find_text(tb, "[1] Annotated Source") !== nothing
    @test find_text(tb, "_inspect_caller") !== nothing

    # LazyGit-like pane ids: the number keys jump straight to a pane.
    @test m.inspect.focus === :calls
    update!(m, KeyEvent(:char, '1'))
    @test m.inspect.focus === :code
    update!(m, KeyEvent(:char, '2'))
    @test m.inspect.focus === :calls

    # Mouse: the wheel over the call-site list moves the selection, and a click over
    # the code pane focuses it.
    st = m.inspect
    @test (st.calls_rect.height > 0) && (st.code_rect.height > 0)
    cur0 = fr.cursor
    update!(
        m,
        MouseEvent(
            st.calls_rect.x,
            st.calls_rect.y,
            mouse_scroll_down,
            mouse_press,
            false,
            false,
            false
        )
    )
    @test fr.cursor == cur0 + 1
    update!(
        m,
        MouseEvent(
            st.code_rect.x + 1,
            st.code_rect.y + 1,
            mouse_left,
            mouse_press,
            false,
            false,
            false
        )
    )
    @test st.focus === :code
    update!(m, KeyEvent(:char, '2'))
    TS.inspect_move!(m, cur0 - fr.cursor)
    @test fr.cursor == cur0

    # Descend into the unstable callee and back.
    fr.cursor = idx + 1
    update!(m, KeyEvent(:enter))
    @test length(m.inspect.stack) == 2
    @test occursin("_inspect_unstable", TS.inspect_top(m.inspect).label)

    update!(m, KeyEvent(:backspace))
    @test length(m.inspect.stack) == 1

    # Toggle to the typed IR view and render it.
    update!(m, KeyEvent(:char, 't'))
    @test TS.inspect_top(m.inspect).view == :ir
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "Typed IR") !== nothing

    update!(m, KeyEvent(:char, 't'))
    @test TS.inspect_top(m.inspect).view == :source

    # Leaving the standalone inspector quits the application.
    update!(m, KeyEvent(:char, 'q'))
    @test m.quit

    # Entering from the frame list: rows without a method instance explain themselves in
    # the status notice, rows with one open the inspector, and closing it returns to the
    # frame list.
    m2 = make_model()

    # f: plain frame without a method instance.
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.mode == :tree
    @test m2.notice == "This row carries no method instance to inspect."

    # The pinned aggregate root row.
    update!(m2, KeyEvent(:home))
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.notice == "Aggregate rows cannot be type-inspected."

    # k: C frame (child of f).
    update!(m2, KeyEvent(:down))
    update!(m2, KeyEvent(:enter))
    m2.cursor = findfirst(n -> TS.node_name(n) == "k", m2.rows)
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.notice == "C frames cannot be type-inspected."
    @test m2.mode == :tree

    # Any other key clears the notice.
    update!(m2, KeyEvent(:up))
    @test isempty(m2.notice)
    update!(m2, KeyEvent(:backspace))

    node = TS.selected_row(m2)
    node.sf = StackFrame(
        :_inspect_caller,
        Symbol(@__FILE__),
        1,
        mi,
        false,
        false,
        0
    )
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.mode == :inspect
    @test !m2.inspect.standalone

    update!(m2, KeyEvent(:escape))
    @test m2.mode == :tree
    @test !m2.quit
end

"""
    _invalidation_target(x) -> Int

Abstractly-typed method superseded during the invalidation tests.
"""
_invalidation_target(x::Integer) = 1

"""
    _invalidation_caller(x::Int) -> Int

Caller compiled against the loose method, invalidated when a specific one is inserted.
"""
_invalidation_caller(x::Int) = _invalidation_target(x) + 1

"""
    _invalidation_outer(x::Int) -> Int

Second-level caller creating a deeper invalidation chain.
"""
_invalidation_outer(x::Int) = _invalidation_caller(x) * 2

@testset "Invalidations" begin
    @test TS.count_cell(1234, :invalidations) == "1,234"
    @test TS.count_label(:samples) == "Samples"
    @test TS.count_label(:time) == "Time"
    @test TS.count_label(:invalidations) == "Instances"

    # Triggers without a `Method`: a missing trigger and a `Core.Binding` rebinding must
    # not crash the tree conversion.
    MI = SnoopCompile.MethodInvalidations
    binding = convert(Core.Binding, GlobalRef(Main, :_invalidation_binding))
    degenerate = TS.build_invalidation_tree([
        MI(nothing, :deleting),
        MI(binding, :rebinding),
        MI(nothing, :unknown)
    ])
    @test length(degenerate.children) == 3
    names = sort([TS.node_name(c) for c in degenerate.children])
    @test names[1] == "deleting unknown method"
    @test names[2] == "rebinding Main._invalidation_binding"
    @test names[3] == "unattributed invalidations"

    _invalidation_outer(1)
    invs = SnoopCompileCore.@snoop_invalidations @eval _invalidation_target(x::Int) = 2

    # The macro passes the raw `InvalidationLists` straight to `scope_invalidations`, so the
    # conversion helper must accept it as well as already-built trees.
    trees = TS._invalidation_forest(invs)
    @test trees isa Vector{SnoopCompile.MethodInvalidations}
    @test TS._invalidation_forest(trees) === trees

    if isempty(trees)
        @warn "No invalidations were recorded. Skipping the invalidation viewer tests."
    else
        root = TS.build_invalidation_tree(trees)
        @test TS.is_tree_root(root)
        @test TS.node_name(root) == "invalidations"
        @test root.count >= 3
        @test length(root.children) == length(trees)

        # The trigger node carries the reason and the inserted method signature.
        trigger = root.children[1]
        @test startswith(TS.node_name(trigger), "inserting")
        @test occursin("_invalidation_target", TS.node_name(trigger))
        @test trigger.count == sum(c -> c.count, trigger.children; init = 0)

        # The invalidated chain is reachable and carries method instances.
        m = TS.invalidation_viewer(trees)
        @test m.unit === :invalidations
        @test m.nsamples == root.count

        node = m.current

        while !isempty(node.children)
            node = node.children[1]
        end

        @test node.sf.linfo isa Core.MethodInstance
        @test occursin("_invalidation", TS.node_name(node))

        # Rendering shows the invalidation header and the Instances column.
        tb = TestBackend(110, 30)
        frame = Tachikoma.Frame(
            tb.buf,
            Rect(1, 1, 110, 30),
            Tachikoma.GraphicsRegion[],
            Tachikoma.PixelSnapshot[]
        )
        tview(m, frame)
        @test find_text(tb, "Invalidations") !== nothing
        @test find_text(tb, "Triggers") !== nothing
        @test find_text(tb, "Instances") !== nothing

        # The info strip shows the instance count without time estimates.
        Tachikoma.reset!(tb.buf)
        tview(m, frame)
        @test find_text(tb, "Instances") !== nothing

        # The inspector opens on an invalidated method instance.
        while true
            n = TS.selected_row(m)
            ((n !== nothing) && (n.sf.linfo isa Core.MethodInstance)) && break
            isempty(n.children) && break
            update!(m, KeyEvent(:enter))
        end

        if TS.selected_row(m).sf.linfo isa Core.MethodInstance
            update!(m, KeyEvent(:char, 'i'))
            @test m.mode == :inspect
            update!(m, KeyEvent(:escape))
            @test m.mode == :tree
        end
    end
end

"""
    _alloc_workload() -> Vector{Vector{Float64}}

Allocation-heavy workload profiled by the allocation viewer tests.
"""
_alloc_workload() = [rand(10) for _ in 1:100]

"""
    _WARM_COUNT

Number of times the `@scope allocs` warm-up test expression has been executed.
"""
const _WARM_COUNT = Ref(0)

@testset "Allocations" begin
    @test TS.format_bytes(512) == "512 B"
    @test TS.format_bytes(2048) == "2.0 KiB"
    @test TS.format_bytes(3 * 1024^2) == "3.0 MiB"
    @test TS.count_cell(2048, :bytes) == "2.0 KiB"
    @test TS.count_cell(2048, :allocs) == "2,048"
    @test TS.count_label(:bytes) == "Memory"
    @test TS.count_label(:allocs) == "Allocs"

    # Synthetic records: tree structure, costs, and the type leaves.
    st = stacktrace()
    synth = (
        allocs = [
            Profile.Allocs.Alloc(Vector{Float64}, st, 128, C_NULL, UInt64(0)),
            Profile.Allocs.Alloc(String, st, 32, C_NULL, UInt64(1))
        ],
    )
    root = TS.build_alloc_tree(synth)
    @test root.count == 160
    @test root.allocs == 2
    @test TS.node_name(root) == "allocations"

    node = root

    while !isempty(node.children) && (node.children[1].sf.file !== Symbol(""))
        node = node.children[1]
    end

    leaf_names = sort([TS.node_name(c) for c in node.children])
    @test leaf_names == ["String", "Vector{Float64}"]

    # The unit toggle swaps the primary and secondary costs everywhere.
    m = TS.alloc_viewer(synth)
    @test m.unit === :bytes
    @test m.nsamples == 160
    update!(m, KeyEvent(:char, 'u'))
    @test m.unit === :allocs
    @test m.nsamples == 2
    @test m.root.count == 2
    @test m.root.allocs == 160
    update!(m, KeyEvent(:char, 'u'))
    @test m.unit === :bytes
    @test m.nsamples == 160

    # Real capture end to end.
    _alloc_workload()
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate = 1.0 _alloc_workload()
    results = Profile.Allocs.fetch()

    if isempty(results.allocs)
        @warn "No allocations were recorded. Skipping the allocation viewer tests."
    else
        mr = TS.alloc_viewer(results)
        @test mr.root.count > 0
        @test mr.root.allocs > 0
        @test mr.root.count == sum(a.size for a in results.allocs)
        @test mr.root.allocs == length(results.allocs)

        tb = TestBackend(110, 30)
        frame = Tachikoma.Frame(
            tb.buf,
            Rect(1, 1, 110, 30),
            Tachikoma.GraphicsRegion[],
            Tachikoma.PixelSnapshot[]
        )
        tview(mr, frame)
        @test find_text(tb, "Allocations") !== nothing
        @test find_text(tb, "Memory") !== nothing
        @test find_text(tb, "Allocs") !== nothing

        # The info strip shows the memory and allocation costs.
        Tachikoma.reset!(tb.buf)
        tview(mr, frame)
        @test find_text(tb, "Memory") !== nothing
    end

    # Compiler name demangling.
    @test TS.demangle_name("pretty_table") == "pretty_table"
    @test TS.demangle_name("#pretty_table#123") == "pretty_table"
    @test TS.demangle_name("var\"#pretty_table#123\"") == "pretty_table"
    @test TS.demangle_name("#_pretty_table#310") == "_pretty_table"
    @test TS.demangle_name("f##kw") == "f"
    @test TS.demangle_name("#37") == "λ#37"
    @test TS.demangle_name("#37#38") == "λ#37#38"
    @test TS.demangle_name("macro expansion") == "macro expansion"
    @test TS.demangle_name("kwcall") == "kwcall"

    # Wrapper collapse: `f → kwcall → #f#9 → g` becomes `f → g`, keeping the outer
    # location, and per-line costs are charged to the innermost Julia frame only.
    file = Symbol(@__FILE__)
    frame(name, line; from_c = false) =
        StackFrame(Symbol(name), file, line, nothing, from_c, false, 0)
    wrapped = [
        frame("jl_alloc", 0; from_c = true),
        frame("g", 20),
        frame("#f#9", 5),
        frame("kwcall", 0),
        frame("f", 10)
    ]
    lc = Dict{Tuple{Symbol, Int}, Tuple{Int, Int}}()
    wroot = TS.build_alloc_tree(
        (allocs = [Profile.Allocs.Alloc(Int, wrapped, 64, C_NULL, UInt64(0))],);
        line_costs = lc
    )
    f = wroot.children[1]
    @test TS.node_name(f) == "f"
    @test f.sf.line == 10
    @test TS.node_name(f.children[1]) == "g"
    @test TS.node_name(f.children[1].children[1]) == "Int64"
    @test lc == Dict((file, 20) => (64, 1))

    # The source panel of an allocating frame shows the per-line cost column, following
    # the active unit.
    mw = TS.alloc_viewer((allocs = [Profile.Allocs.Alloc(Int, wrapped, 64, C_NULL, UInt64(0))],))
    @test mw.line_costs == lc

    update!(mw, KeyEvent(:home))
    @test TS.node_name(TS.selected_row(mw)) == "g"

    tbw = TestBackend(120, 30)
    fw = Tachikoma.Frame(
        tbw.buf,
        Rect(1, 1, 120, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    # The allocating line is the target line, so the gutter cell precedes the marker.
    tview(mw, fw)
    @test find_text(tbw, "64 B ▶") !== nothing

    update!(mw, KeyEvent(:char, 'u'))
    Tachikoma.reset!(tbw.buf)
    tview(mw, fw)
    @test find_text(tbw, "64 B ▶") === nothing
    @test find_text(tbw, "1 ▶") !== nothing
    update!(mw, KeyEvent(:escape))

    # The macro expands without errors, with and without options, and rejects unknown
    # options.
    @test (@macroexpand @scope allocs 1 + 1) isa Expr
    @test (@macroexpand @scope allocs sample_rate = 0.5 1 + 1) isa Expr
    @test_throws ArgumentError (@macroexpand @scope allocs foo = 1 1 + 1)

    # Run the macro expansion up to (but not including) the viewer launch, so the
    # capture path is exercised at runtime: hygiene must not rename the `sample_rate`
    # keyword.
    ex = @macroexpand @scope allocs sample_rate = 1.0 _alloc_workload()
    body = Expr(:block, ex.args[1:(end - 1)]...)
    Core.eval(@__MODULE__, body)
    macro_results = Profile.Allocs.fetch()
    @test !isempty(macro_results.allocs)

    # Mode parsing: unknown modes and modes without an expression are rejected, and
    # option validation is per mode.
    @test_throws ArgumentError (@macroexpand @scope banana 1 + 1)
    @test_throws ArgumentError (@macroexpand @scope allocs)
    @test_throws ArgumentError (@macroexpand @scope inference sample_rate = 1.0 1 + 1)
    @test (@macroexpand @scope inference 1 + 1) isa Expr
    @test (@macroexpand @scope invalidations 1 + 1) isa Expr
    @test (@macroexpand @scope descend sum([1, 2])) isa Expr

    # By default the expression runs twice (warm-up + profiled run); `warmup = false`
    # runs it only once.
    _WARM_COUNT[] = 0
    ex = @macroexpand @scope allocs (_WARM_COUNT[] += 1)
    Core.eval(@__MODULE__, Expr(:block, ex.args[1:(end - 1)]...))
    @test _WARM_COUNT[] == 2

    _WARM_COUNT[] = 0
    ex = @macroexpand @scope allocs warmup = false (_WARM_COUNT[] += 1)
    Core.eval(@__MODULE__, Expr(:block, ex.args[1:(end - 1)]...))
    @test _WARM_COUNT[] == 1
end

@testset "Lazy Invalidating Dependencies" begin
    # Loading TerminalScope alone must not load Cthulhu or SnoopCompile, whose load-time
    # invalidations would force other packages to recompile.
    code = """
        using TerminalScope
        loaded = [k.name for k in keys(Base.loaded_modules)]
        println(("Cthulhu" in loaded) || ("SnoopCompile" in loaded))
    """
    out = read(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`,
        String
    )
    @test strip(out) == "false"

    # The backends load on demand and activate the extensions.
    code = """
        using TerminalScope
        ok = TerminalScope._ensure_inspector() && TerminalScope._ensure_snoopcompile()
        println(ok && TerminalScope.inspector_available())
    """
    out = read(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`,
        String
    )
    @test strip(out) == "true"

    # The extensions are active in this test session, so the guarded features work.
    @test TS.inspector_available()
    @test TS._ensure_inspector()
    @test TS._ensure_snoopcompile()

    # Background-load plumbing: the model exposes a task queue and wake hook, and a
    # completed load task opens the pending inspector request.
    m = make_model()
    @test Tachikoma.task_queue(m) === m.tasks
    woken = Ref(false)
    Tachikoma.set_wake!(m, () -> (woken[] = true))

    mi = TS._descend_specialization(_inspect_caller, Tuple{Int})
    m.inspect.loading = true
    m.inspect.pending_mi = mi
    m.notice = "loading"
    update!(m, Tachikoma.TaskEvent(:inspector_loaded, true))
    @test m.mode == :inspect
    @test !m.inspect.loading
    @test m.inspect.pending_mi === nothing
    @test isempty(m.notice)

    # A failed load reports a notice instead of opening the inspector.
    m2 = make_model()
    m2.inspect.loading = true
    m2.inspect.pending_mi = mi
    update!(m2, Tachikoma.TaskEvent(:inspector_loaded, ErrorException("boom")))
    @test m2.mode == :tree
    @test occursin("Cthulhu", m2.notice)

    # The full spawn path: a load task completes through the queue.
    m3 = make_model()
    m3.inspect.loading = true
    Tachikoma.spawn_task!(() -> TS._ensure_inspector(; quiet = true), m3.tasks, :inspector_loaded)
    evt = take!(m3.tasks.channel)
    @test evt isa Tachikoma.TaskEvent
    @test evt.id === :inspector_loaded
    @test evt.value === true
end

@testset "Themes" begin
    # Theme lookup and validation.
    @test TS._theme_for(:dark) === TS.SCOPE_DARK_THEME
    @test TS._theme_for(:light) === TS.SCOPE_LIGHT_THEME
    @test_throws ArgumentError TS._theme_for(:solarized)

    # Palette identity: amber chrome and navy-family structure in both variants.
    @test TS.SCOPE_DARK_THEME.accent == Tachikoma.Color256(214)
    @test TS.SCOPE_DARK_THEME.title == TS.SCOPE_DARK_THEME.accent
    @test TS.SCOPE_LIGHT_THEME.accent == Tachikoma.Color256(172)
    @test TS.SCOPE_LIGHT_THEME.bg == Tachikoma.Color256(231)

    # The default variant is changed by theme! and rejected when unknown.
    @test TS.DEFAULT_THEME[] == :dark
    @test TS.theme!(:light) == :light
    @test TS.DEFAULT_THEME[] == :light
    @test_throws ArgumentError TS.theme!(:solarized)
    @test TS.DEFAULT_THEME[] == :light
    TS.theme!(:dark)
    @test TS.DEFAULT_THEME[] == :dark

    # Color preference parsing: xterm-256 codes and quantized hex strings.
    @test TS._color_code(214) == 214
    @test TS._color_code(0) == 0
    @test TS._color_code(-1) === nothing
    @test TS._color_code(256) === nothing
    @test TS._color_code("#F59E0B") == Int(Tachikoma.hex_to_color256(0xF59E0B).code)
    @test TS._color_code("F59E0B") == TS._color_code("#F59E0B")
    @test TS._color_code("#F59") === nothing
    @test TS._color_code("not a color") === nothing
    @test TS._color_code(1.5) === nothing

    # Theme building honors the color preferences of the active project.
    @test TS._build_theme(:dark).bg == Tachikoma.Color256(234)
    @test_logs (:info,) TS.set_theme_color!(:dark, :bg, 17)
    @test TS._build_theme(:dark).bg == Tachikoma.Color256(17)
    @test_logs (:info,) TS.set_theme_color!(:light, :accent, "#F59E0B")
    @test TS._build_theme(:light).accent ==
        Tachikoma.Color256(TS._color_code("#F59E0B"))
    @test_logs (:info,) TS.reset_theme_colors!()
    @test TS._build_theme(:dark).bg == Tachikoma.Color256(234)
    @test TS._build_theme(:light).accent == Tachikoma.Color256(172)

    # The selection background is a preference slot outside the Tachikoma theme and
    # follows the active light mode.
    old_light = Tachikoma.light_mode()
    Tachikoma.set_light_mode!(false)
    @test TS.selection_bg() == TS.SCOPE_DARK_SELECTION
    Tachikoma.set_light_mode!(true)
    @test TS.selection_bg() == TS.SCOPE_LIGHT_SELECTION
    Tachikoma.set_light_mode!(old_light)

    @test TS.SCOPE_DARK_SELECTION == Tachikoma.Color256(TS.SELECTION_DEFAULTS[:dark])
    @test TS.SCOPE_LIGHT_SELECTION == Tachikoma.Color256(TS.SELECTION_DEFAULTS[:light])
    @test_logs (:info,) TS.set_theme_color!(:dark, :selection, 238)
    @test TS._pref_color(:dark, :selection, TS.SELECTION_DEFAULTS[:dark]) ==
        Tachikoma.Color256(238)
    @test_logs (:info,) TS.reset_theme_colors!()
    @test TS._pref_color(:dark, :selection, TS.SELECTION_DEFAULTS[:dark]) ==
        Tachikoma.Color256(TS.SELECTION_DEFAULTS[:dark])

    # An invalid stored preference falls back to the default with a warning.
    Preferences.set_preferences!(TS, "dark_bg" => "oops"; force = true)
    theme = @test_logs (:warn,) TS._build_theme(:dark)
    @test theme.bg == Tachikoma.Color256(234)
    Preferences.delete_preferences!(TS, "dark_bg"; force = true)

    # Setter validation.
    @test_throws ArgumentError TS.set_theme_color!(:solarized, :bg, 0)
    @test_throws ArgumentError TS.set_theme_color!(:dark, :bgcolor, 0)
    @test_throws ArgumentError TS.set_theme_color!(:dark, :bg, 999)
    @test_throws ArgumentError TS.set_theme_color!(:dark, :bg, "#XYZ")
end

@testset "Real Profile Integration" begin
    # Profile a workload and check that the flame graph is converted without errors. The
    # workload is repeated until samples are collected to avoid flakiness on fast machines.
    _work(n) = sum(sin(i) + sqrt(abs(cos(i))) for i in 1:n)

    Profile.clear()
    local g = nothing

    for _ in 1:10
        Profile.@profile _work(10_000_000)
        g = FlameGraphs.flamegraph()
        g !== nothing && break
    end

    if g === nothing
        @warn "Could not collect profile samples. Skipping the integration test."
    else
        m = TS.ProfileViewer(g)
        @test m.nsamples > 0
        @test !isempty(m.rows)
        @test m.total_nodes >= length(m.rows)

        tb = TestBackend(120, 40)
        frame = Tachikoma.Frame(
            tb.buf,
            Rect(1, 1, 120, 40),
            Tachikoma.GraphicsRegion[],
            Tachikoma.PixelSnapshot[]
        )
        tview(m, frame)
        @test find_text(tb, "Samples") !== nothing
    end
end
