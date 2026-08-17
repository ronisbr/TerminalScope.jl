## Description #############################################################################
#
# TerminalScope.jl: interactive terminal UI to diagnose Julia code — runtime profiles,
# type inference profiles, type instabilities, and method invalidations.
#
############################################################################################

module TerminalScope

using FlameGraphs
using Profile
using Tachikoma

import InteractiveUtils
import JuliaSyntaxHighlighting
import Logging
import PrecompileTools
import SnoopCompileCore
import StyledStrings
import TypedSyntax

using Base.StackTraces: StackFrame

Tachikoma.@tachikoma_app

export @scope, scope_profile, scope_inference, scope_allocs, scope_invalidations,
    scope_descend

include("tree.jl")
include("format.jl")
include("detail.jl")
include("inspect.jl")
include("app.jl")
include("render.jl")

"""
    SCOPE_DARK_THEME

Dark TerminalScope theme, matching the SatelliteAnalysis.jl presentation palette: navy
structure, amber chrome (titles, costs, focus), cyan data emphasis, and magenta secondary
emphasis, quantized to the closest xterm-256 colors.
"""
const SCOPE_DARK_THEME = Tachikoma.Theme(
    "scope-dark",
    Color256(234),  # bg: navy #0A1929.
    Color256(24),   # border: navy blue #1E3A5F, biased to keep the blue hue.
    Color256(214),  # border_focus: amber #F59E0B.
    Color256(255),  # text: off-white #F1F5F9.
    Color256(109),  # text_dim: blue-gray #94A3B8.
    Color256(75),   # text_bright: cyan #38BDF8.
    Color256(75),   # primary: cyan #38BDF8.
    Color256(205),  # secondary: magenta #F472B6.
    Color256(214),  # accent: amber #F59E0B.
    Color256(78),   # success: green #34D399.
    Color256(220),  # warning: gold #FBBF24, kept distinct from the accent.
    Color256(203),  # error: coral #F87171.
    Color256(214)   # title: amber #F59E0B.
)

"""
    SCOPE_LIGHT_THEME

Light TerminalScope theme, matching the SatelliteAnalysis.jl presentation palette on a
white surface, with the accents darkened for contrast as in the original.
"""
const SCOPE_LIGHT_THEME = Tachikoma.Theme(
    "scope-light",
    Color256(231),  # bg: white #FFFFFF.
    Color256(188),  # border: light slate #CBD5E1.
    Color256(172),  # border_focus: amber #D97706.
    Color256(234),  # text: navy #0A1929.
    Color256(238),  # text_dim: slate #334155.
    Color256(32),   # text_bright: cyan #0284C7.
    Color256(32),   # primary: cyan #0284C7.
    Color256(162),  # secondary: magenta #DB2777.
    Color256(172),  # accent: amber #D97706.
    Color256(29),   # success: green #059669.
    Color256(136),  # warning: dark gold, kept distinct from the accent.
    Color256(160),  # error: red #DC2626.
    Color256(172)   # title: amber #D97706.
)

"""
    DEFAULT_THEME

Theme variant used by the viewers when none is given, either `:dark` or `:light`. Change
it with [`theme!`](@ref).
"""
const DEFAULT_THEME = Ref{Symbol}(:dark)

"""
    _theme_for(variant::Symbol) -> Tachikoma.Theme

Return the theme of the `variant`, either `:dark` or `:light`, throwing an
`ArgumentError` for any other value.
"""
function _theme_for(variant::Symbol)
    (variant === :dark) && return SCOPE_DARK_THEME
    (variant === :light) && return SCOPE_LIGHT_THEME
    throw(ArgumentError("Unknown theme `:$variant`. The options are `:dark` and `:light`."))
end

"""
    theme!(variant::Symbol) -> Symbol

Set the default theme variant of the TerminalScope viewers to `variant`, either `:dark`
or `:light`, and return it. Every entry point also accepts a `theme` keyword overriding
this default for one invocation.
"""
function theme!(variant::Symbol)
    _theme_for(variant)
    DEFAULT_THEME[] = variant
    return variant
end

"""
    _run_app(m::ProfileViewer; theme::Symbol = DEFAULT_THEME[]) -> Nothing

Run the Tachikoma application for the model `m` under the `theme` variant (`:dark` or
`:light`), restoring the previously active theme and light mode when the application
exits.
"""
function _run_app(m::ProfileViewer; theme::Symbol = DEFAULT_THEME[])
    t = _theme_for(theme)
    old = Tachikoma.THEME[]
    old_light = Tachikoma.light_mode()

    set_theme!(t)
    Tachikoma.set_light_mode!(theme === :light)

    try
        app(m)
    finally
        Tachikoma.THEME[] = old
        Tachikoma.set_light_mode!(old_light)
    end

    return nothing
end

"""
    scope_profile(g; kwargs...) -> Nothing

Open the interactive terminal viewer for the flame graph rooted at `g`, a node returned
by `FlameGraphs.flamegraph`. The viewer takes over the terminal until the user quits with
the `q` key.

# Keywords

- `compile::Union{CompileStats, Nothing}`: Compilation measurements of the profiled
    expression, shown in the header when available.
    (**Default**: `nothing`)
- `theme::Symbol`: Theme variant, either `:dark` or `:light`. See also [`theme!`](@ref).
    (**Default**: `DEFAULT_THEME[]`)
"""
function scope_profile(
    g;
    compile::Union{CompileStats, Nothing} = nothing,
    theme::Symbol = DEFAULT_THEME[]
)
    _run_app(ProfileViewer(g; compile = compile); theme = theme)
    return nothing
end

"""
    scope_profile(; kwargs...) -> Nothing

Build the flame graph from the current `Profile` data and open the interactive terminal
viewer. Print a warning and return without opening the viewer when no profile data is
available.

# Keywords

- `compile::Union{CompileStats, Nothing}`: Compilation measurements of the profiled
    expression, shown in the header when available.
    (**Default**: `nothing`)
- `theme::Symbol`: Theme variant, either `:dark` or `:light`. See also [`theme!`](@ref).
    (**Default**: `DEFAULT_THEME[]`)
"""
function scope_profile(;
    compile::Union{CompileStats, Nothing} = nothing,
    theme::Symbol = DEFAULT_THEME[]
)
    g = FlameGraphs.flamegraph()

    if g === nothing
        @warn "The profile is empty. Run `@scope expr` or `Profile.@profile expr` first."
        return nothing
    end

    return scope_profile(g; compile = compile, theme = theme)
end

"""
    scope_inference(tinf; theme::Symbol = DEFAULT_THEME[]) -> Nothing

Open the interactive terminal viewer for the inference timing tree `tinf` returned by
`SnoopCompileCore.@snoop_inference`, with the frame costs shown as inference plus LLVM
compilation times. The viewer takes over the terminal until the user quits with the `q`
key. `theme` selects the `:dark` or `:light` variant; see also [`theme!`](@ref).
"""
function scope_inference(tinf; theme::Symbol = DEFAULT_THEME[])
    _run_app(inference_viewer(tinf); theme = theme)
    return nothing
end

"""
    alloc_viewer(results) -> ProfileViewer

Create the viewer model from the allocation profile `results` returned by
`Profile.Allocs.fetch()`, with node counts in allocated bytes and allocation counts as
the secondary cost.
"""
function alloc_viewer(results)
    line_costs = Dict{Tuple{Symbol, Int}, Tuple{Int, Int}}()
    root = build_alloc_tree(results; line_costs = line_costs)
    m = _viewer(root, :bytes, 0.0, nothing, 0)
    m.nsamples = root.count
    m.line_costs = line_costs
    return m
end

"""
    scope_allocs(results = Profile.Allocs.fetch(); theme::Symbol = DEFAULT_THEME[]) -> Nothing

Open the interactive terminal viewer for the allocation profile `results` returned by
`Profile.Allocs.fetch()`. The tree shows where memory was allocated, ranked by allocated
bytes; the `u` key re-ranks it by number of allocations. Descending past the deepest
frame lists the allocated types. When the profile was collected with a sample rate below
`1.0`, the shown bytes and counts are the recorded fraction, not the totals. The viewer
takes over the terminal until the user quits with the `q` key. `theme` selects the
`:dark` or `:light` variant; see also [`theme!`](@ref).

See also [`@scope`](@ref).
"""
function scope_allocs(results = Profile.Allocs.fetch(); theme::Symbol = DEFAULT_THEME[])
    if isempty(results.allocs)
        @warn "The allocation profile is empty. Run `@scope allocs expr` or " *
            "`Profile.Allocs.@profile expr` first."
        return nothing
    end

    _run_app(alloc_viewer(results); theme = theme)
    return nothing
end

"""
    _scope_allocs_expansion(opts, expr) -> Expr

Build the `@scope allocs` expansion: `expr` runs once as a warm-up (unless disabled with
`warmup = false`), then again under the allocation profiler, and the viewer opens with
the result. The supported options are `sample_rate = value` and `warmup = bool`.
"""
function _scope_allocs_expansion(opts, @nospecialize(expr))
    rate = 1.0
    warmup = true

    for a in opts
        if (a isa Expr) && (a.head === :(=)) && (a.args[1] === :sample_rate)
            rate = a.args[2]
        elseif (a isa Expr) && (a.head === :(=)) && (a.args[1] === :warmup)
            warmup = a.args[2]
        else
            throw(ArgumentError(
                "Unknown option `$a`. The options of `@scope allocs` are " *
                "`sample_rate = value` and `warmup = bool`."
            ))
        end
    end

    # Expand to explicit start/stop calls instead of `Profile.Allocs.@profile`: splicing
    # a `sample_rate = ...` expression into a nested macro call lets hygiene rename the
    # keyword before the inner macro sees it.
    return quote
        if $(esc(warmup))
            $(esc(expr))
        end

        Profile.Allocs.clear()
        Profile.Allocs.start(; sample_rate = $(esc(rate)))

        try
            $(esc(expr))
        finally
            Profile.Allocs.stop()
        end

        scope_allocs(Profile.Allocs.fetch())
    end
end

"""
    invalidation_viewer(trees) -> ProfileViewer

Create the viewer model from the invalidation trees returned by
`SnoopCompile.invalidation_trees`, with node counts in numbers of invalidated method
instances.
"""
function invalidation_viewer(trees)
    root = build_invalidation_tree(trees)
    return _viewer(root, :invalidations, 0.0, nothing, 0)
end

"""
    _CTHULHU_ID

Package identifier of Cthulhu, used to load it on demand.
"""
const _CTHULHU_ID =
    Base.PkgId(Base.UUID("f68482b8-f384-11e8-15f7-abe071a5a75f"), "Cthulhu")

"""
    _SNOOPCOMPILE_ID

Package identifier of SnoopCompile, used to load it on demand.
"""
const _SNOOPCOMPILE_ID =
    Base.PkgId(Base.UUID("aa65fe97-06da-5843-b5b1-d5d13cad87d2"), "SnoopCompile")

"""
    _load_backend(pkg::Base.PkgId, ext::Symbol; quiet::Bool = false) -> Bool

Load the dependency `pkg` so that the extension `ext` activates, returning whether the
extension is available afterwards. The load is skipped when the extension is already
active. `quiet` suppresses the loading message and any load-time output, used when a
Tachikoma application controls the terminal.

Cthulhu and SnoopCompile are loaded this way, on first use, because loading them
invalidates compiled code of unrelated packages; sessions that only use the profilers
never pay that cost.
"""
function _load_backend(pkg::Base.PkgId, ext::Symbol; quiet::Bool = false)
    (Base.get_extension(@__MODULE__, ext) !== nothing) && return true

    try
        if quiet
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    Base.require(pkg)
                end
            end
        else
            @info "Loading $(pkg.name) (one-time initialization of this feature)..."
            Base.require(pkg)
        end
    catch
        return false
    end

    return Base.get_extension(@__MODULE__, ext) !== nothing
end

"""
    _ensure_inspector(; quiet::Bool = false) -> Bool

Load Cthulhu on demand and return whether the inspector backend is available.
"""
_ensure_inspector(; quiet::Bool = false) =
    _load_backend(_CTHULHU_ID, :TerminalScopeCthulhuExt; quiet = quiet)

"""
    _ensure_snoopcompile(; quiet::Bool = false) -> Bool

Load SnoopCompile on demand and return whether the invalidation backend is available.
"""
_ensure_snoopcompile(; quiet::Bool = false) =
    _load_backend(_SNOOPCOMPILE_ID, :TerminalScopeSnoopCompileExt; quiet = quiet)

"""
    _invalidation_trees(invs) -> Vector

Organize the raw invalidation data `invs` into `SnoopCompile.MethodInvalidations` trees.
The method is provided by the `TerminalScopeSnoopCompileExt` extension.
"""
function _invalidation_trees end

"""
    _invalidation_forest(invs) -> AbstractVector

Return the invalidation trees for `invs`: the input itself when it already is a
collection of trees (`SnoopCompile.MethodInvalidations`), and the result of
`SnoopCompile.invalidation_trees` otherwise (the raw `SnoopCompileCore.InvalidationLists`
returned by `SnoopCompileCore.@snoop_invalidations`).
"""
function _invalidation_forest(@nospecialize(invs))
    (invs isa AbstractVector) && return invs
    return Base.invokelatest(_invalidation_trees, invs)
end

"""
    scope_invalidations(invs) -> Nothing

Open the interactive terminal viewer for the method invalidations `invs`, either the raw
data returned by `SnoopCompileCore.@snoop_invalidations` or the trees returned by
`SnoopCompile.invalidation_trees`. The first level lists the methods whose definition
triggered invalidations; descending shows the invalidated specializations and,
recursively, the callers invalidated through them. The `i` key opens the type-instability
inspector on the selected instance. The viewer takes over the terminal until the user
quits with the `q` key. `theme` selects the `:dark` or `:light` variant; see also
[`theme!`](@ref).

Organizing raw invalidation data requires SnoopCompile, which is loaded on the first
use (its load-time invalidations do not affect sessions that only use the profilers).
When it cannot be loaded, a warning is printed and the raw data is returned so it can be
viewed later.

See also [`@scope`](@ref).
"""
function scope_invalidations(@nospecialize(invs); theme::Symbol = DEFAULT_THEME[])
    if !(invs isa AbstractVector) && !_ensure_snoopcompile()
        @warn "Could not load SnoopCompile, which is required to organize raw " *
            "invalidation data. The raw data is returned unchanged."
        return invs
    end

    trees = _invalidation_forest(invs)

    if isempty(trees)
        @warn "No invalidations were recorded."
        return nothing
    end

    _run_app(invalidation_viewer(trees); theme = theme)
    return nothing
end

"""
    _scope_invalidations_expansion(expr) -> Expr

Build the `@scope invalidations` expansion: `expr` runs under
`SnoopCompileCore.@snoop_invalidations` and the viewer opens with the result.
"""
function _scope_invalidations_expansion(@nospecialize(expr))
    return quote
        local invs = SnoopCompileCore.@snoop_invalidations $(esc(expr))
        scope_invalidations(invs)
    end
end

"""
    inspector_viewer(mi::Core.MethodInstance) -> ProfileViewer

Create a viewer model whose only view is the type-instability inspector opened on the
method instance `mi`, so that closing the inspector quits the application.
"""
function inspector_viewer(mi::Core.MethodInstance)
    root = PVNode(
        Base.StackTraces.UNKNOWN,
        0,
        0,
        0.0,
        100.0,
        0x00,
        0,
        nothing,
        PVNode[],
        false
    )

    m = _viewer(root, :samples, 0.0, nothing, 0)
    m.inspect.standalone = true
    enter_inspect!(m, mi)
    return m
end

"""
    scope_descend(f, types::Type{<:Tuple} = Tuple{}; theme::Symbol = DEFAULT_THEME[]) -> Nothing

Open the interactive type-instability inspector on the method of `f` specialized for the
argument types `types`, similar to `Cthulhu.descend`. The inspector shows the source code
annotated with the inferred types, colored by type stability, and the call sites of the
method, which can be descended into with the Enter key. The viewer takes over the
terminal until the user quits with the `q` key. `theme` selects the `:dark` or `:light`
variant; see also [`theme!`](@ref).

The inspector requires Cthulhu, which is loaded on the first use (its load-time
invalidations do not affect sessions that only use the profilers).

See also [`@scope`](@ref).
"""
function scope_descend(
    @nospecialize(f),
    @nospecialize(types::Type{<:Tuple} = Tuple{});
    theme::Symbol = DEFAULT_THEME[]
)
    if !_ensure_inspector()
        @warn "Could not load Cthulhu, which the type-instability inspector requires."
        return nothing
    end

    mi = Base.invokelatest(_descend_specialization, f, types)

    if mi === nothing
        @warn "No method of the given function matches the given argument types."
        return nothing
    end

    _run_app(inspector_viewer(mi); theme = theme)
    return nothing
end


"""
    _scope_profile_expansion(opts, expr) -> Expr

Build the default `@scope` expansion: `expr` runs under the sampling profiler while its
compilation time is measured, and the viewer opens with the result. The supported
options are `delay = seconds` and `n = samples`, forwarded to `Profile.init`.
"""
function _scope_profile_expansion(opts, @nospecialize(expr))
    delay = nothing
    n = nothing

    for a in opts
        if (a isa Expr) && (a.head === :(=)) && (a.args[1] === :delay)
            delay = a.args[2]
        elseif (a isa Expr) && (a.head === :(=)) && (a.args[1] === :n)
            n = a.args[2]
        else
            throw(ArgumentError(
                "Unknown option `$a`. The options of `@scope` are `delay = seconds` " *
                "and `n = samples`."
            ))
        end
    end

    kws = Any[]
    (delay !== nothing) && push!(kws, Expr(:kw, :delay, esc(delay)))
    (n !== nothing) && push!(kws, Expr(:kw, :n, esc(n)))
    init_call = isempty(kws) ? :(nothing) :
        Expr(:call, :(Profile.init), Expr(:parameters, kws...))

    return quote
        $(init_call)
        Profile.clear()
        Base.cumulative_compile_timing(true)
        local comp0 = Base.cumulative_compile_time_ns()
        local t0 = time_ns()

        try
            Profile.@profile $(esc(expr))
        finally
            Base.cumulative_compile_timing(false)
        end

        local elapsed = (time_ns() - t0) / 1e9
        local comp1 = Base.cumulative_compile_time_ns()

        scope_profile(;
            compile = CompileStats(
                elapsed,
                (comp1[1] - comp0[1]) / 1e9,
                (comp1[2] - comp0[2]) / 1e9
            )
        )
    end
end

"""
    _scope_inference_expansion(expr) -> Expr

Build the `@scope inference` expansion: `expr` runs under
`SnoopCompileCore.@snoop_inference` and the viewer opens with the timing tree.
"""
function _scope_inference_expansion(@nospecialize(expr))
    return quote
        local tinf = SnoopCompileCore.@snoop_inference $(esc(expr))
        scope_inference(tinf)
    end
end

"""
    _SCOPE_MODES

Analysis modes accepted as the first argument of [`@scope`](@ref).
"""
const _SCOPE_MODES = (:profile, :allocs, :inference, :invalidations, :descend)

"""
    @scope([mode,] [options...,] expr)

Analyze `expr` and open the interactive terminal viewer with the result. The first
argument selects the analysis; without it, `expr` runs under the sampling profiler.

# Modes

- `@scope [delay = seconds] [n = samples] expr`: Runtime profile. `delay` is the time
    between two samples and `n` the sample buffer size, forwarded to `Profile.init`
    (they persist for the session). The compilation time of the run is shown in the
    header.
- `@scope allocs [sample_rate = 1.0] [warmup = true] expr`: Allocation profile, ranked
    by bytes with the `u` key re-ranking by allocation counts. `expr` runs once as a
    warm-up so compiler allocations stay out of the profile — pass `warmup = false` when
    its side effects must happen only once, and consider a lower `sample_rate` if the
    profiled run may still compile fresh code.
- `@scope inference expr`: Type-inference profile via
    `SnoopCompileCore.@snoop_inference`. Run it on code that has not been compiled yet
    (typically in a fresh session).
- `@scope invalidations expr`: Method invalidations caused by `expr`, typically
    `@scope invalidations using SomePackage`.
- `@scope descend f(x, y)`: Type-instability inspector on the call, like
    `Cthulhu.@descend`. The call is not executed; only its argument types are used.

The value of `expr` is discarded (except by `descend`, which never runs it). The
corresponding function forms — [`scope_profile`](@ref), [`scope_allocs`](@ref),
[`scope_inference`](@ref), [`scope_invalidations`](@ref), and [`scope_descend`](@ref) —
open the viewer on already-collected data.
"""
macro scope(args...)
    isempty(args) && throw(ArgumentError("@scope requires an expression to analyze."))

    mode = :profile
    rest = collect(Any, args)

    if (rest[1] isa Symbol) && (rest[1] in _SCOPE_MODES)
        mode = popfirst!(rest)
        isempty(rest) &&
            throw(ArgumentError("`@scope $mode` requires an expression to analyze."))
    elseif (rest[1] isa Symbol) && (length(rest) > 1)
        throw(ArgumentError(
            "Unknown @scope mode `$(rest[1])`. The modes are " *
            "$(join(_SCOPE_MODES, ", "))."
        ))
    end

    expr = rest[end]
    opts = rest[1:(end - 1)]

    if mode === :descend
        isempty(opts) ||
            throw(ArgumentError("`@scope descend` accepts no options."))
        return InteractiveUtils.gen_call_with_extracted_types_and_kwargs(
            __module__,
            :scope_descend,
            (expr,)
        )
    end

    if (mode === :inference) || (mode === :invalidations)
        isempty(opts) ||
            throw(ArgumentError("`@scope $mode` accepts no options."))
        return mode === :inference ? _scope_inference_expansion(expr) :
            _scope_invalidations_expansion(expr)
    end

    (mode === :allocs) && return _scope_allocs_expansion(opts, expr)
    return _scope_profile_expansion(opts, expr)
end

include("precompile.jl")

end # module TerminalScope
