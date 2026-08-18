## Description #############################################################################
#
# Tests related to the source panel resolution and the syntax highlighting.
#
############################################################################################

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
