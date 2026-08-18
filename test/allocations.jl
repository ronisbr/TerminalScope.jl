## Description #############################################################################
#
# Tests related to the allocation viewer.
#
############################################################################################

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
    lc = Dict{Symbol, Dict{Int, Tuple{Int, Int}}}()
    wroot = TS.build_alloc_tree(
        (allocs = [Profile.Allocs.Alloc(Int, wrapped, 64, C_NULL, UInt64(0))],);
        line_costs = lc
    )
    f = wroot.children[1]
    @test TS.node_name(f) == "f"
    @test f.sf.line == 10
    @test TS.node_name(f.children[1]) == "g"
    @test TS.node_name(f.children[1].children[1]) == "Int64"
    @test lc == Dict(file => Dict(20 => (64, 1)))

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
