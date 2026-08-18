## Description #############################################################################
#
# Tests related to the lazy loading of the Cthulhu and SnoopCompile backends.
#
############################################################################################

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
