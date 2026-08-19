## Description #############################################################################
#
# Tests related to the editor jump.
#
############################################################################################

"""
    _with_editor_stub(f::Function) -> Vector{Tuple{String, Int}}

Run `f(calls)` with the editor launcher stubbed to record its `(path, line)` arguments
into `calls`, restoring the real launcher afterwards and returning the recorded calls.
"""
function _with_editor_stub(f::Function)
    calls = Tuple{String, Int}[]
    TS._EDITOR_OPENER[] = (path, line) -> push!(calls, (path, line))

    try
        f(calls)
    finally
        TS._EDITOR_OPENER[] = nothing
    end

    return calls
end

@testset "Frame Jump" begin
    _with_editor_stub() do calls
        m = make_model()
        m.visible_h = 10

        # Jump to the selected frame: the fixture frame h lives at line 30 of this test
        # suite's runtests.jl, a real file.
        update!(m, KeyEvent(:char, '/'))
        update!(m, KeyEvent(:char, 'h'))
        update!(m, KeyEvent(:enter))
        sel = TS.selected_row(m)
        @test TS.node_name(sel) == "h"

        update!(m, KeyEvent(:char, 'e'))
        @test length(calls) == 1
        @test calls[1] == (string(sel.sf.file), 30)
        @test isfile(calls[1][1])
        @test isempty(m.notice)

        # C frames have no Julia source.
        update!(m, KeyEvent(:char, '/'))
        update!(m, KeyEvent(:char, 'k'))
        update!(m, KeyEvent(:enter))
        update!(m, KeyEvent(:char, 'e'))
        @test length(calls) == 1
        @test occursin("C frames", m.notice)

        # Unresolvable source files report a notice.
        update!(m, KeyEvent(:char, '/'))
        update!(m, KeyEvent(:char, 'm'))
        update!(m, KeyEvent(:enter))
        update!(m, KeyEvent(:char, 'e'))
        @test length(calls) == 1
        @test occursin("not found", m.notice)

        # The pinned aggregate root row cannot be opened.
        update!(m, KeyEvent(:home))
        @test TS.selected_row(m) === m.root
        update!(m, KeyEvent(:char, 'e'))
        @test length(calls) == 1
        @test occursin("Aggregate rows", m.notice)
    end

    # A failing launcher surfaces as a notice, not a crash.
    m = make_model()
    m.visible_h = 10
    TS._EDITOR_OPENER[] = (path, line) -> error("boom")

    try
        update!(m, KeyEvent(:char, '/'))
        update!(m, KeyEvent(:char, 'h'))
        update!(m, KeyEvent(:enter))
        update!(m, KeyEvent(:char, 'e'))
        @test occursin("Could not launch", m.notice)
    finally
        TS._EDITOR_OPENER[] = nothing
    end
end

@testset "TUI Suspension" begin
    # A remote terminal skips the raw-mode and probe paths, making the escape output
    # deterministic and CI-safe.
    t = Tachikoma.Terminal(;
        io = IOBuffer(), size = (rows = 30, cols = 100), external_size = true
    )
    m = make_model()

    # The application loop hands the terminal to the model through init!.
    Tachikoma.init!(m, t)
    @test m.term === t

    # The interface is left before the body runs and re-entered afterwards, with the
    # previous buffer blanked so the next frame repaints everything.
    body_output = String[]

    TS._with_suspended_tui(m) do
        push!(body_output, String(take!(t.io)))
    end

    after = String(take!(t.io))
    @test occursin(Tachikoma.ALT_SCREEN_OFF, body_output[1])
    @test !occursin(Tachikoma.ALT_SCREEN_ON, body_output[1])
    @test occursin(Tachikoma.ALT_SCREEN_ON, after)
    @test all(c -> c.char == ' ', Tachikoma.previous_buf(t).content)

    # The interface is re-entered even when the body throws.
    @test_throws ErrorException TS._with_suspended_tui(() -> error("boom"), m)
    after = String(take!(t.io))
    @test occursin(Tachikoma.ALT_SCREEN_ON, after)

    # Without a terminal handle (headless use), the body runs directly.
    m.term = nothing
    @test TS._with_suspended_tui(() -> 42, m) == 42
end

if CTHULHU_AVAILABLE
    @testset "Inspector Jump" begin
        _with_editor_stub() do calls
            mi = Cthulhu.get_specialization(_inspect_caller, Tuple{Int})
            m = TS.inspector_viewer(mi)

            update!(m, KeyEvent(:char, 'e'))
            meth = TS.inspect_top(m.inspect).mi.def
            @test length(calls) == 1
            @test calls[1] == (string(meth.file), Int(meth.line))
            @test isfile(calls[1][1])
        end
    end
end
