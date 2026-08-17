## Description #############################################################################
#
# Cthulhu-backed analysis of the type-instability inspector. This extension activates
# when the user loads Cthulhu, keeping its load-time invalidations out of sessions that
# only use the profilers.
#
############################################################################################

module TerminalScopeCthulhuExt

using Cthulhu
using TerminalScope

using TerminalScope: InspectEntry, InspectFrame, _error_frame, _mi_label, ansi_spans,
    sync_inspect_code!, type_stability_style

const Logging = TerminalScope.Logging
const Tachikoma = TerminalScope.Tachikoma
const TypedSyntax = TerminalScope.TypedSyntax

"""
    _callsite_ci(info) -> Union{Core.CodeInstance, Nothing}

Return the inferred code instance of the Cthulhu call information `info`, or `nothing`
when the callee cannot be resolved (dynamic dispatch, pure calls, or failed extraction).
"""
function _callsite_ci(@nospecialize(info))
    ci = try
        Logging.with_logger(() -> Cthulhu.get_ci(info), Logging.NullLogger())
    catch
        nothing
    end

    return ci isa Core.CodeInstance ? ci : nothing
end

"""
    _callsite_entry(info, cs::Cthulhu.Callsite, line::Int; sub::Bool = false) -> InspectEntry

Build the call-site list entry for the Cthulhu call information `info` of the call site
`cs` at the absolute source `line`. `sub` marks entries that are one target of a
union-split call site.
"""
function _callsite_entry(@nospecialize(info), cs::Cthulhu.Callsite, line::Int; sub::Bool = false)
    rt = try
        Logging.with_logger(() -> Cthulhu.get_rt(info), Logging.NullLogger())
    catch
        nothing
    end

    rt_str = rt === nothing ? "" : string(rt)

    label = try
        sprint(
            show,
            Cthulhu.Callsite(cs.id, info, cs.head);
            context = :displaysize => (24, 1000)
        )
    catch
        "call"
    end

    label = replace(label, r"^%\d+\s*=\s*(=\s*)?" => "")
    !isempty(rt_str) && (label = String(chopsuffix(label, "::" * rt_str)))

    return InspectEntry(
        String(strip(label)),
        rt_str,
        type_stability_style(rt),
        line,
        _callsite_ci(info),
        info isa Cthulhu.RTCallInfo,
        sub
    )
end

"""
    _sourcenode_line(sn) -> Int

Return the absolute source line of the call-site source node `sn` returned by
`Cthulhu.find_callsites`, or `0` when the node carries no source position.
"""
function _sourcenode_line(@nospecialize(sn))
    (sn isa Cthulhu.Callsite) && return 0

    return try
        JS = TypedSyntax.JuliaSyntax
        JS.source_location(sn.source, JS.first_byte(sn))[1]
    catch
        0
    end
end

"""
    TerminalScope.inspect_frame(
        provider::Cthulhu.DefaultProvider,
        mi::Core.MethodInstance,
        ci::Union{Core.CodeInstance, Nothing} = nothing
    ) -> InspectFrame

Analyze the method instance `mi` with Cthulhu and return the inspector frame holding its
call sites, the type-annotated source, and the typed IR. `ci` is the already inferred
code instance from the parent call site, when available; it is re-generated when it is
missing from the provider caches. Analysis failures produce a frame carrying only an
error message.
"""
function TerminalScope.inspect_frame(
    provider::Cthulhu.DefaultProvider,
    mi::Core.MethodInstance,
    ci::Union{Core.CodeInstance, Nothing} = nothing
)
    return Logging.with_logger(Logging.NullLogger()) do
        local result

        try
            if (ci === nothing) || Cthulhu.should_regenerate_code_instance(provider, ci)
                ci = Cthulhu.generate_code_instance(provider, mi)
            end

            result = Cthulhu.lookup(provider, provider.interp, ci, false)
        catch
            return _error_frame(mi, "Type inference failed for this method")
        end

        entries = InspectEntry[]

        try
            callsites, sourcenodes = Cthulhu.find_callsites(provider, result, ci, true)

            for (k, cs) in enumerate(callsites)
                line = k <= length(sourcenodes) ? _sourcenode_line(sourcenodes[k]) : 0

                if cs.info isa Cthulhu.MultiCallInfo
                    for info in cs.info.callinfos
                        push!(entries, _callsite_entry(info, cs, line; sub = true))
                    end
                else
                    push!(entries, _callsite_entry(cs.info, cs, line))
                end
            end
        catch
            # Keep an empty call-site list when the extraction fails.
        end

        code_lines = Vector{Tachikoma.Span}[]
        start_line = 1
        src_error = nothing
        view = :source

        try
            tsn, _ = TypedSyntax.tsn_and_mappings(
                mi,
                result.src,
                result.rt;
                warn = false,
                strip_macros = true
            )
            tsn === nothing && error("no source")

            JS = TypedSyntax.JuliaSyntax
            start_line = JS.source_location(tsn.source, JS.first_byte(tsn))[1]

            iob = IOBuffer()
            printstyled(
                IOContext(iob, :color => true),
                tsn;
                iswarn = true,
                hide_type_stable = true,
                with_linenumber = false
            )
            code_lines = ansi_spans(String(take!(iob)))
        catch
            src_error = "Source cannot be annotated — showing the typed IR"
            view = :ir
        end

        ir_lines = try
            iob = IOBuffer()
            show(IOContext(iob, :color => true, :limit => true), "text/plain", result.src)
            ansi_spans(String(take!(iob)))
        catch
            Vector{Tachikoma.Span}[]
        end

        return InspectFrame(
            mi,
            _mi_label(mi),
            string(result.rt),
            type_stability_style(result.rt),
            entries,
            code_lines,
            ir_lines,
            start_line,
            src_error,
            view,
            min(2, length(entries) + 1),
            0,
            0,
            0
        )
    end
end

"""
    TerminalScope._enter_inspect_impl!(m, mi::Core.MethodInstance) -> Nothing

Open the type-instability inspector on the method instance `mi`, creating the Cthulhu
provider on the first use, and switch the application mode of the model `m` to
`:inspect`.
"""
function TerminalScope._enter_inspect_impl!(m, mi::Core.MethodInstance)
    st = m.inspect
    (st.provider === nothing) && (st.provider = Cthulhu.DefaultProvider())

    empty!(st.stack)
    push!(st.stack, TerminalScope.inspect_frame(st.provider, mi))
    st.focus = :calls

    (m.mode != :inspect) && (st.return_mode = m.mode)
    m.mode = :inspect
    sync_inspect_code!(st)
    return nothing
end

"""
    TerminalScope._descend_frame(provider, ci::Core.CodeInstance) -> InspectFrame

Return the inspector frame of the callee behind the inferred code instance `ci`, used
when descending into a call site.
"""
TerminalScope._descend_frame(provider, ci::Core.CodeInstance) =
    TerminalScope.inspect_frame(provider, Cthulhu.get_mi(ci), ci)

"""
    TerminalScope._descend_specialization(f, types) -> Union{Core.MethodInstance, Nothing}

Return the method instance of `f` specialized for the argument types `types`, or
`nothing` when no method matches.
"""
function TerminalScope._descend_specialization(@nospecialize(f), @nospecialize(types))
    return try
        Cthulhu.get_specialization(f, types)
    catch
        nothing
    end
end

############################################################################################
#                                      Precompilation                                      #
############################################################################################

const PrecompileTools = TerminalScope.PrecompileTools

PrecompileTools.@setup_workload begin
    _pc_unstable(x) = x > 0 ? 1 : 2.0
    _pc_caller(x) = _pc_unstable(x) + 1.0

    PrecompileTools.@compile_workload begin
        mi = TerminalScope._descend_specialization(_pc_caller, Tuple{Int})

        if mi !== nothing
            m = TerminalScope.inspector_viewer(mi)
            tb = Tachikoma.TestBackend(100, 30)
            frame = Tachikoma.Frame(
                tb.buf,
                Tachikoma.Rect(1, 1, 100, 30),
                Tachikoma.GraphicsRegion[],
                Tachikoma.PixelSnapshot[]
            )
            Tachikoma.view(m, frame)
            Tachikoma.update!(m, Tachikoma.KeyEvent(:down))
            Tachikoma.update!(m, Tachikoma.KeyEvent(:enter))
            Tachikoma.view(m, frame)
            Tachikoma.update!(m, Tachikoma.KeyEvent(:backspace))
            Tachikoma.update!(m, Tachikoma.KeyEvent(:char, 't'))
            Tachikoma.view(m, frame)
        end
    end
end

end # module TerminalScopeCthulhuExt
