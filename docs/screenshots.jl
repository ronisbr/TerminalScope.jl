## Description #############################################################################
#
# Generate the SVG screenshots of the documentation. Run from the repository root:
#
#     julia --project=. docs/screenshots.jl
#
# The screenshots are written to docs/src/assets/screenshots/. Most of them render
# hand-crafted, deterministic profile data over a sample workload file, so the output is
# reproducible; the inference and type-inspector shots run the real analyses on the same
# workload.
#
############################################################################################

using FlameGraphs
using Profile
using Tachikoma
using TerminalScope

import Cthulhu
import SnoopCompileCore

using Base.StackTraces: StackFrame

const TS = TerminalScope
const LCRST = FlameGraphs.LeftChildRightSiblingTrees
const ND = FlameGraphs.NodeData

const OUT_DIR = joinpath(@__DIR__, "src", "assets", "screenshots")
const WIDTH = 104
const HEIGHT = 30

############################################################################################
#                                     Sample Workload                                      #
############################################################################################

# The line numbers of this file are referenced by the synthetic profiles below, so the
# source panel of the screenshots shows real highlighted code.
const WORKLOAD = raw"""
## Description #############################################################################
#
# Sample satellite tracking workload used to generate the documentation screenshots.
#
############################################################################################

function run_simulation(orbits, steps)
    states    = propagate_orbits(orbits, steps)
    residuals = estimate_residuals(states)
    return summarize(states, residuals)
end

function propagate_orbits(orbits, steps)
    states = Vector{Float64}(undef, length(orbits))

    for (i, orb) in enumerate(orbits)
        states[i] = integrate_state(orb, steps)
    end

    return states
end

function integrate_state(state, steps)
    for _ in 1:steps
        state = rk4_step(state, 1.0e-3)
    end

    return state
end

rk4_step(x, h) = x + h * (dynamics(x) + 2dynamics(x + h / 2) + dynamics(x + h)) / 4

dynamics(x) = -9.81 * sin(x) + perturbation(x)

perturbation(x) = 1.0e-3 * cos(35x)

function estimate_residuals(states)
    return abs.(states .- mean_state(states))
end

mean_state(states) = sum(states) / length(states)

function summarize(states, residuals)
    report = string("mean = ", mean_state(states), ", max = ", maximum(residuals))
    return (states = states, report = report)
end

fetch_gain(config) = config["gain"]

function apply_gain(config, states)
    gain = fetch_gain(config)
    return [gain * s for s in states]
end
"""

const WORKLOAD_PATH = joinpath(mktempdir(), "workload.jl")
write(WORKLOAD_PATH, WORKLOAD)
const WFILE = Symbol(WORKLOAD_PATH)

# Two copies of the workload: `Workload` backs the invalidation and inspector shots, and
# `WorkloadFresh` stays uncompiled until the inference shot records its first call.
module Workload end
module WorkloadFresh end

Base.include(Workload, WORKLOAD_PATH)
Base.include(WorkloadFresh, WORKLOAD_PATH)

############################################################################################
#                                         Helpers                                          #
############################################################################################

"""
    _sf(func, file, line; from_c = false) -> StackFrame

Create a stack frame for the synthetic profiles.
"""
_sf(func, file, line; from_c = false) =
    StackFrame(Symbol(func), Symbol(file), line, nothing, from_c, false, 0)

"""
    _key!(m, args...) -> Nothing

Dispatch one key event to the model `m`.
"""
_key!(m, args...) = Tachikoma.update!(m, KeyEvent(args...))

"""
    _type!(m, text::AbstractString) -> Nothing

Dispatch every character of `text` to the model `m`.
"""
_type!(m, text::AbstractString) = foreach(c -> _key!(m, :char, c), text)

"""
    render_svg(m, name::String; theme::Symbol = :dark) -> Nothing

Render one frame of the model `m` under the `theme` variant and export it to
`OUT_DIR/name.svg`.
"""
function render_svg(m, name::String; theme::Symbol = :dark)
    set_theme!(theme === :dark ? TS.SCOPE_DARK_THEME : TS.SCOPE_LIGHT_THEME)
    Tachikoma.set_light_mode!(theme === :light)

    tb = TestBackend(WIDTH, HEIGHT)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, WIDTH, HEIGHT),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    Tachikoma.view(m, frame)

    # The background and default foreground use the design-intent SatelliteAnalysis
    # colors instead of their xterm-256 quantization, so the pages look crisp.
    bg = theme === :dark ? "#0A1929" : "#FFFFFF"
    fg = theme === :dark ? "#F1F5F9" : "#0A1929"

    export_svg(
        joinpath(OUT_DIR, name * ".svg"),
        WIDTH,
        HEIGHT,
        [copy(tb.buf.content)],
        [0.0];
        bg_color = bg,
        fg_color = fg
    )

    set_theme!(TS.SCOPE_DARK_THEME)
    Tachikoma.set_light_mode!(false)
    println("  generated $name.svg")
    return nothing
end

############################################################################################
#                                     Runtime Profile                                      #
############################################################################################

"""
    runtime_viewer() -> TS.ProfileViewer

Create the runtime profile viewer of the screenshots from a hand-crafted flame graph of
the sample workload, including a dynamic dispatch, a GC event, and a C frame.
"""
function runtime_viewer()
    root = LCRST.Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:1000))
    ev = LCRST.addchild(root, ND(_sf("eval", "boot.jl", 430), 0x00, 1:995))
    sim = LCRST.addchild(ev, ND(_sf("run_simulation", WFILE, 8), 0x00, 1:990))

    prop = LCRST.addchild(sim, ND(_sf("propagate_orbits", WFILE, 17), 0x00, 1:700))
    integ = LCRST.addchild(prop, ND(_sf("integrate_state", WFILE, 25), 0x00, 1:660))
    rk4 = LCRST.addchild(integ, ND(_sf("rk4_step", WFILE, 31), 0x00, 1:640))
    dyn = LCRST.addchild(
        rk4,
        ND(_sf("dynamics", WFILE, 33), FlameGraphs.runtime_dispatch, 1:520)
    )
    LCRST.addchild(dyn, ND(_sf("sin", "special/trig.jl", 29), 0x00, 1:300))
    LCRST.addchild(dyn, ND(_sf("perturbation", WFILE, 35), 0x00, 301:480))
    LCRST.addchild(rk4, ND(_sf("+", "promotion.jl", 425), 0x00, 521:610))

    est = LCRST.addchild(
        sim,
        ND(_sf("estimate_residuals", WFILE, 38), FlameGraphs.runtime_dispatch, 701:880)
    )
    LCRST.addchild(est, ND(_sf("mean_state", WFILE, 41), 0x00, 701:800))
    LCRST.addchild(est, ND(_sf("materialize", "broadcast.jl", 892), 0x00, 801:860))

    sm = LCRST.addchild(sim, ND(_sf("summarize", WFILE, 44), 0x00, 881:960))
    LCRST.addchild(sm, ND(_sf("string", "strings/io.jl", 189), 0x00, 881:940))

    LCRST.addchild(
        sim,
        ND(_sf("jl_gc_small_alloc", "gc.c", 0; from_c = true), FlameGraphs.gc_event, 961:985)
    )

    return TS.ProfileViewer(root; compile = TS.CompileStats(3.42, 0.87, 0.12))
end

############################################################################################
#                                    Allocation Profile                                    #
############################################################################################

"""
    alloc_results() -> NamedTuple

Create synthetic allocation profile results over the sample workload, mixing one large
buffer with many small allocations of several types.
"""
function alloc_results()
    st_prop = [
        _sf("propagate_orbits", WFILE, 14),
        _sf("run_simulation", WFILE, 8),
        _sf("eval", "boot.jl", 430)
    ]
    st_integ = [
        _sf("integrate_state", WFILE, 25),
        _sf("propagate_orbits", WFILE, 17),
        _sf("run_simulation", WFILE, 8),
        _sf("eval", "boot.jl", 430)
    ]
    st_sum = [
        _sf("string", "strings/io.jl", 189),
        _sf("summarize", WFILE, 44),
        _sf("run_simulation", WFILE, 8),
        _sf("eval", "boot.jl", 430)
    ]
    st_est = [
        _sf("materialize", "broadcast.jl", 892),
        _sf("estimate_residuals", WFILE, 38),
        _sf("run_simulation", WFILE, 8),
        _sf("eval", "boot.jl", 430)
    ]

    alloc(T, st, size) = Profile.Allocs.Alloc(T, st, size, C_NULL, UInt64(0))
    allocs = [alloc(Vector{Float64}, st_prop, 80_000)]

    for _ in 1:64
        push!(allocs, alloc(Vector{Float64}, st_integ, 1_024))
    end

    for _ in 1:12
        push!(allocs, alloc(String, st_sum, 256))
    end

    for _ in 1:3
        push!(allocs, alloc(Vector{Float64}, st_est, 8_192))
    end

    return (allocs = allocs,)
end

############################################################################################
#                                      Invalidations                                       #
############################################################################################

"""
    struct InstNode

Duck-typed stand-in for a `SnoopCompile.InstanceNode`, holding a method instance and the
callers invalidated through it.
"""
struct InstNode
    mi::Core.MethodInstance
    children::Vector{InstNode}
end

"""
    invalidation_trees() -> Vector

Create duck-typed invalidation trees over real method instances of the sample workload,
mimicking the output of `SnoopCompile.invalidation_trees`.
"""
function invalidation_trees()
    W = Workload

    # Compile the specializations the trees reference.
    Base.invokelatest(W.run_simulation, collect(0.1:0.1:1.0), 10)

    spec(f, types...) = Cthulhu.get_specialization(f, Tuple{types...})
    mi_dyn = spec(W.dynamics, Float64)
    mi_rk4 = spec(W.rk4_step, Float64, Float64)
    mi_integ = spec(W.integrate_state, Float64, Int)
    mi_prop = spec(W.propagate_orbits, Vector{Float64}, Int)
    mi_pert = spec(W.perturbation, Float64)
    mi_mean = spec(W.mean_state, Vector{Float64})
    mi_est = spec(W.estimate_residuals, Vector{Float64})

    return [
        (
            method = which(W.dynamics, (Float64,)),
            reason = :inserting,
            backedges = Any[
                InstNode(
                    mi_dyn,
                    [InstNode(mi_rk4, [InstNode(mi_integ, [InstNode(mi_prop, InstNode[])])])]
                )
            ],
            mt_backedges = Any[
                (Tuple{typeof(W.dynamics), Float64}, InstNode(mi_rk4, InstNode[]))
            ]
        ),
        (
            method = which(W.perturbation, (Float64,)),
            reason = :inserting,
            backedges = Any[InstNode(mi_pert, [InstNode(mi_dyn, InstNode[])])],
            mt_backedges = Any[]
        ),
        (
            method = which(W.mean_state, (Vector{Float64},)),
            reason = :deleting,
            backedges = Any[InstNode(mi_mean, [InstNode(mi_est, InstNode[])])],
            mt_backedges = Any[]
        ),
    ]
end

############################################################################################
#                                        Generation                                        #
############################################################################################

mkpath(OUT_DIR)
println("Generating the documentation screenshots in $OUT_DIR:")

# == Inference Profile (first, so `WorkloadFresh` is still uncompiled) =====================

tinf = SnoopCompileCore.@snoop_inference Base.invokelatest(
    WorkloadFresh.run_simulation,
    collect(0.1:0.1:1.0),
    50
)
render_svg(TS.inference_viewer(tinf), "inference_profile")

# == Runtime Profile =======================================================================

render_svg(runtime_viewer(), "runtime_profile")

# == Allocation Profile ====================================================================

render_svg(TS.alloc_viewer(alloc_results()), "allocation_profile")

# == Invalidations =========================================================================

render_svg(TS.invalidation_viewer(invalidation_trees()), "invalidations")

# == Type Inspector ========================================================================

config = Dict{String, Any}("gain" => 2.0)
Base.invokelatest(Workload.apply_gain, config, [1.0, 2.0])
mi = Cthulhu.get_specialization(
    Workload.apply_gain,
    Tuple{Dict{String, Any}, Vector{Float64}}
)
render_svg(TS.inspector_viewer(mi), "type_inspector")

# == Frame Search ==========================================================================

m = runtime_viewer()
_key!(m, :char, '/')
_type!(m, "state")
render_svg(m, "search_prompt")

_key!(m, :enter)
render_svg(m, "search_results")

# == Help Dialog ===========================================================================

m = runtime_viewer()
_key!(m, :char, '?')
render_svg(m, "help_dialog")

# == Light Theme ===========================================================================

render_svg(runtime_viewer(), "light_theme"; theme = :light)

println("Done.")
