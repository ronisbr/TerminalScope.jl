## Description #############################################################################
#
# Tests related to the invalidation viewer.
#
############################################################################################

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
        MI(nothing, :deleting), MI(binding, :rebinding), MI(nothing, :unknown)
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
            Tachikoma.PixelSnapshot[],
        )
        tview(m, frame)
        @test find_text(tb, "Invalidations") !== nothing
        @test find_text(tb, "Triggers") !== nothing
        @test find_text(tb, "Instances") !== nothing

        # The info strip shows the instance count without time estimates.
        Tachikoma.reset!(tb.buf)
        tview(m, frame)
        @test find_text(tb, "Instances") !== nothing

        # The inspector opens on an invalidated method instance. The block requires the
        # Cthulhu backend, so it is skipped when Cthulhu cannot be loaded.
        if CTHULHU_AVAILABLE
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
end
