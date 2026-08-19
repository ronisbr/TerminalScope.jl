## Description #############################################################################
#
# Tests related to the whole-tree frame search.
#
############################################################################################

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
        tb.buf, Rect(1, 1, 100, 30), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]
    )
    update!(m, KeyEvent(:char, '/'))
    update!(m, KeyEvent(:char, 'a'))
    tview(m, frame)
    @test find_text(tb, "/a") !== nothing

    # The prompt is left-aligned like the Neovim command line, with the slash in the
    # accent color and the query text in the theme text color.
    @test char_at(tb, 2, 30) == '/'
    @test char_at(tb, 3, 30) == 'a'
    @test style_at(tb, 2, 30).fg == TS.tstyle(:accent).fg
    @test style_at(tb, 3, 30).fg == TS.tstyle(:text).fg
    update!(m, KeyEvent(:escape))
end

@testset "Regex Search" begin
    m = make_model()
    m.visible_h = 10

    # Anchors restrict the match to the name: "f" alone also matches the location
    # missing_file.jl of the frame m, while "^f$" matches only the frame f.
    @test length(TS._search_matches(m.root, "f")) == 2
    @test length(TS._search_matches(m.root, "^f\$")) == 1

    # The regex path stays case-insensitive, and alternations work.
    @test length(TS._search_matches(m.root, "^H\$")) == 1
    @test length(TS._search_matches(m.root, "^(f|k)\$")) == 2

    # A dot matches any character in a valid pattern.
    @test length(TS._search_matches(m.root, "missing.file")) == 1

    # An invalid pattern falls back to a case-insensitive substring match instead of
    # throwing: "([" matches nothing here, and the prompt flow reports it.
    cur = m.current
    update!(m, KeyEvent(:char, '/'))

    for c in "(["
        update!(m, KeyEvent(:char, c))
    end

    update!(m, KeyEvent(:enter))
    @test isempty(m.search_matches)
    @test occursin("No frames match", m.notice)
    @test m.current === cur

    # The substring fallback still finds frames whose names contain regex
    # metacharacters.
    ND = FlameGraphs.NodeData
    root = Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:10))
    addchild(root, ND(_sf(Symbol("f[1]"), Symbol(@__FILE__), 10), 0x00, 1:10))
    @test length(TS._search_matches(TS.build_tree(root), "f[")) == 1
end
