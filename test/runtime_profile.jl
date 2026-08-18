## Description #############################################################################
#
# Tests related to the runtime profile viewer: compilation info and profile integration.
#
############################################################################################

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
