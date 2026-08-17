## Description #############################################################################
#
# Precompilation workload: exercise the hot interactive paths (model building, rendering,
# and key handling) so the first keystrokes of the real application are fast.
#
############################################################################################

PrecompileTools.@setup_workload begin
    LCRST = FlameGraphs.LeftChildRightSiblingTrees

    _pc_sf(func, file, line; from_c = false) =
        StackFrame(func, file, line, nothing, from_c, false, 0)

    ND = FlameGraphs.NodeData
    _pc_root = LCRST.Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:100))
    _pc_f = LCRST.addchild(_pc_root, ND(_pc_sf(:f, Symbol(@__FILE__), 10), 0x00, 1:80))
    _pc_g = LCRST.addchild(_pc_f, ND(_pc_sf(:g, Symbol(@__FILE__), 20), 0x00, 1:50))
    LCRST.addchild(
        _pc_g,
        ND(_pc_sf(:h, Symbol(@__FILE__), 30), FlameGraphs.runtime_dispatch, 1:50)
    )
    LCRST.addchild(
        _pc_f,
        ND(_pc_sf(:k, :Sys, 40; from_c = true), FlameGraphs.gc_event, 51:70)
    )
    LCRST.addchild(_pc_root, ND(_pc_sf(:m, Symbol("x.jl"), 5), 0x00, 81:95))

    # Synthetic allocation records exercising the allocation-tree paths without running
    # the real allocation profiler during precompilation.
    _pc_st = stacktrace()
    _pc_allocs = (
        allocs = [
            Profile.Allocs.Alloc(Vector{Float64}, _pc_st, 128, C_NULL, UInt64(0)),
            Profile.Allocs.Alloc(String, _pc_st, 32, C_NULL, UInt64(1))
        ],
    )

    PrecompileTools.@compile_workload begin
        set_theme!(SCOPE_DARK_THEME)

        m = ProfileViewer(_pc_root)
        tb = TestBackend(100, 30)
        frame = Tachikoma.Frame(
            tb.buf,
            Rect(1, 1, 100, 30),
            Tachikoma.GraphicsRegion[],
            Tachikoma.PixelSnapshot[]
        )

        # Frame list: render, cursor movement, drill-down, and paging.
        view(m, frame)
        update!(m, KeyEvent(:down))
        view(m, frame)
        update!(m, KeyEvent(:up))
        update!(m, KeyEvent(:pagedown))
        update!(m, KeyEvent(:enter))
        view(m, frame)
        update!(m, KeyEvent(:backspace))
        view(m, frame)

        # Source panel: focus switching, scrolling, and the zoom toggle.
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(:tab))
        view(m, frame)
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(:char, '+'))
        view(m, frame)
        update!(m, KeyEvent(:char, '-'))
        update!(m, KeyEvent(:char, '1'))

        # Help dialog.
        update!(m, KeyEvent(:char, '?'))
        view(m, frame)
        update!(m, KeyEvent(:escape))

        # One frame in the light theme so its style paths are cached as well.
        set_theme!(SCOPE_LIGHT_THEME)
        Tachikoma.set_light_mode!(true)
        view(m, frame)
        Tachikoma.set_light_mode!(false)
        set_theme!(SCOPE_DARK_THEME)

        # Allocation viewer: tree building, rendering with the per-line cost column, and
        # the unit toggle.
        m_alloc = alloc_viewer(_pc_allocs)
        view(m_alloc, frame)
        update!(m_alloc, KeyEvent(:down))
        update!(m_alloc, KeyEvent(:char, 'u'))
        view(m_alloc, frame)
        update!(m_alloc, KeyEvent(:char, 'u'))
        update!(m_alloc, KeyEvent(:home))
        view(m_alloc, frame)

        # Invalidation tree conversion and rendering, with a duck-typed stand-in for
        # `SnoopCompile.MethodInvalidations` (SnoopCompile is a weak dependency).
        mi_inv = invalidation_viewer([
            (method = nothing, reason = :unknown, backedges = Any[], mt_backedges = Any[])
        ])
        view(mi_inv, frame)
        update!(mi_inv, KeyEvent(:down))
        view(mi_inv, frame)

        # Inspector rendering helpers. The full inspector workload lives in the
        # `TerminalScopeCthulhuExt` extension, which precompiles separately.
        ansi_spans("plain \e[33myellow\e[39m \e[1;31mbold\e[0m\nsecond \e[38;5;99mline\e[0m")
        type_stability_style(Union{Int, Float64})
        type_stability_style(Any)
        type_stability_style(Int)
    end
end
