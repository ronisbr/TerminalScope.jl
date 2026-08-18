## Description #############################################################################
#
# Tests related to the inference profile viewer.
#
############################################################################################

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
