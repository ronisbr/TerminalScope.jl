## Description #############################################################################
#
# Generate the PNG screenshots of the documentation. Run from the repository root:
#
#     julia --project=docs/screenshots -e 'using Pkg; Pkg.develop(path = "."); Pkg.instantiate()'
#     julia --project=docs/screenshots docs/screenshots/generate.jl
#
# The screenshots are written to docs/src/assets/screenshots/. Most of them render
# hand-crafted, deterministic profile data over a sample workload file, so the output is
# reproducible; the inference and type-inspector shots run the real analyses on the same
# workload. The frames are rasterized with a real monospace font (see [`FONT_PATH`](@ref))
# through the Tachikoma APNG exporter, so the images look identical in every viewer. The
# Iosevka faces are downloaded from the official release on the first run into a cache
# outside the repository (see [`_ensure_iosevka`](@ref)).
#
############################################################################################

using FlameGraphs
using Profile
using Tachikoma
using TerminalScope

import ColorTypes
import Cthulhu
import Downloads
import FreeTypeAbstraction
import PNGFiles
import SnoopCompileCore

using Base.StackTraces: StackFrame

const TS = TerminalScope
const LCRST = FlameGraphs.LeftChildRightSiblingTrees
const ND = FlameGraphs.NodeData

const OUT_DIR = joinpath(@__DIR__, "..", "src", "assets", "screenshots")
const WIDTH = 140
const HEIGHT = 32

# One terminal cell in pixels and the font size filling it, sized for crisp text on
# high-density displays. The cell width follows the advance width of the chosen font
# (see `_FONT_CANDIDATES`).
const CELL_H = 36
const FONT_SIZE = 30

"""
    _FONTS_DIR

Cache directory of the downloaded screenshot fonts, kept outside the repository so the
font files can never be committed.
"""
const _FONTS_DIR = joinpath(homedir(), ".cache", "terminalscope", "fonts")

"""
    _IOSEVKA_VERSION

Pinned Iosevka release used to rasterize the screenshots.
"""
const _IOSEVKA_VERSION = "34.8.0"

"""
    _IOSEVKA_FACES

File names of the Iosevka faces used by the rasterizer: the regular face plus the bold
and italic siblings the glyph cache discovers from it.
"""
const _IOSEVKA_FACES = [
    "Iosevka-Regular.ttf",
    "Iosevka-Bold.ttf",
    "Iosevka-Italic.ttf",
    "Iosevka-BoldItalic.ttf",
]

"""
    _ensure_iosevka() -> Nothing

Download the pinned Iosevka release into [`_FONTS_DIR`](@ref) when its faces are not
cached yet: the official per-style TTF package is fetched (about 170 MiB, one time),
the [`_IOSEVKA_FACES`](@ref) are extracted from it, and the archive is deleted. A
download failure only warns, so the font candidates below can fall back to a locally
installed font.
"""
function _ensure_iosevka()
    all(f -> isfile(joinpath(_FONTS_DIR, f)), _IOSEVKA_FACES) && return nothing

    url = "https://github.com/be5invis/Iosevka/releases/download/" *
        "v$(_IOSEVKA_VERSION)/PkgTTF-Iosevka-$(_IOSEVKA_VERSION).zip"

    try
        mkpath(_FONTS_DIR)
        @info "Downloading Iosevka v$(_IOSEVKA_VERSION) (about 170 MiB, one time)..."
        archive = Downloads.download(url)

        try
            run(`unzip -o -q -j $archive $_IOSEVKA_FACES -d $_FONTS_DIR`)
        finally
            rm(archive; force = true)
        end
    catch err
        @warn "Could not download Iosevka. Falling back to a locally installed font." err
    end

    return nothing
end

_ensure_iosevka()

"""
    _FONT_CANDIDATES

Candidate monospace fonts of [`FONT_PATH`](@ref) as `(path, cell width)` pairs, in
order of preference. The cell width is the glyph advance at [`FONT_SIZE`](@ref):
Iosevka advances 0.5 em and the other candidates 0.6 em.
"""
const _FONT_CANDIDATES = [
    (joinpath(_FONTS_DIR, "Iosevka-Regular.ttf"), 15),
    (joinpath(homedir(), "Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"), 18),
    (joinpath(homedir(), "Library/Fonts/JetBrainsMono-Regular.ttf"), 18),
    (joinpath(homedir(), ".local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf"), 18),
    ("/System/Library/Fonts/Menlo.ttc", 18),
    ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 18),
    ("/usr/share/fonts/TTF/DejaVuSansMono.ttf", 18),
]

const _FONT_CHOICE = let idx = findfirst(c -> isfile(c[1]), _FONT_CANDIDATES)
    idx === nothing ? ("", 0) : _FONT_CANDIDATES[idx]
end

"""
    FONT_PATH

Monospace font used to rasterize the screenshots: the first installed candidate of
[`_FONT_CANDIDATES`](@ref). Bold and italic sibling files are picked up automatically.
Extend the candidate list when regenerating the screenshots on a machine without any of
these fonts.
"""
const FONT_PATH = _FONT_CHOICE[1]

"""
    CELL_W

Width [px] of one terminal cell: the glyph advance of [`FONT_PATH`](@ref) at
[`FONT_SIZE`](@ref).
"""
const CELL_W = _FONT_CHOICE[2]

isempty(FONT_PATH) && error(
    "No monospace font found. Extend the _FONT_CANDIDATES list in $(@__FILE__)."
)

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
    ephemeris = load_ephemeris("ephemeris.txt")
    states    = propagate_orbits(orbits, steps)
    residuals = estimate_residuals(states)
    attitude  = interpolate_attitude(states, ephemeris)
    write_results("results.txt", states, attitude)
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

function load_ephemeris(path)
    isfile(path) || return collect(0.0:0.1:2.0)
    return [parse(Float64, token) for token in split(read(path, String))]
end

interpolate_attitude(states, ephemeris) = 0.5 .* (states .+ mean_state(ephemeris))

function write_results(path, states, attitude)
    open(io -> join(io, states, '\n'), path, "w")
    return nothing
end

function summarize(states, residuals)
    report = string("mean = ", mean_state(states), ", max = ", maximum(residuals))
    return (states = states, report = report)
end

fetch_gain(config) = config["gain"]

function apply_gain(config, states)
    gain    = fetch_gain(config)
    offset  = config["offset"]
    scaled  = [gain * s for s in states]
    shifted = [s + offset for s in scaled]
    return sum(shifted)
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
    ANSI_BRIGHT

Bright xterm-256 replacement of each of the 16 base ANSI colors, applied to the dark
screenshots. The syntax highlighting and the typed-IR printer use the base ANSI colors,
which real terminals render with the user palette; the SVG export would otherwise use
the dark xterm defaults, which are unreadable on the navy background.
"""
const ANSI_BRIGHT = Dict{Int, Int}(
    0 => 240,
    1 => 203,
    2 => 114,
    3 => 221,
    4 => 75,
    5 => 213,
    6 => 80,
    7 => 252,
    8 => 245,
    9 => 210,
    10 => 120,
    11 => 228,
    12 => 111,
    13 => 219,
    14 => 123,
    15 => 255,
)

"""
    _brighten_ansi(cells::Vector{Tachikoma.Cell}) -> Vector{Tachikoma.Cell}

Return `cells` with every base ANSI foreground color replaced by its [`ANSI_BRIGHT`](@ref)
equivalent.
"""
function _brighten_ansi(cells::Vector{Tachikoma.Cell})
    return map(cells) do cell
        fg = cell.style.fg
        (fg isa Color256) || return cell

        code = get(ANSI_BRIGHT, Int(fg.code), nothing)
        code === nothing && return cell

        s = cell.style
        style = Style(
            Color256(code),
            s.bg,
            s.bold,
            s.dim,
            s.italic,
            s.underline,
            s.strikethrough,
            s.hyperlink
        )
        return Tachikoma.Cell(cell.char, style, cell.suffix)
    end
end

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
    _rgb(r::Integer, g::Integer, b::Integer) -> ColorTypes.RGB{ColorTypes.N0f8}

Create the APNG background color from the 8-bit channels `r`, `g`, and `b`.
"""
_rgb(r::Integer, g::Integer, b::Integer) =
    ColorTypes.RGB{ColorTypes.N0f8}(r / 255, g / 255, b / 255)

"""
    render_png(m, name::String; theme::Symbol = :dark) -> Nothing

Render one frame of the model `m` under the `theme` variant and rasterize it with
[`FONT_PATH`](@ref) to `OUT_DIR/name.png` (a single-frame APNG, which every viewer
displays as a still PNG).
"""
function render_png(m, name::String; theme::Symbol = :dark)
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

    # The base ANSI colors stay untouched in the light variant, where the xterm
    # defaults are legible on white.
    cells = theme === :dark ? _brighten_ansi(tb.buf.content) : copy(tb.buf.content)

    # The dark background is almost black with a subtle cool tint, composing with the
    # navy-and-amber theme without reading as blue; the default foreground uses the
    # design-intent SatelliteAnalysis text color.
    bg = theme === :dark ? _rgb(0x0D, 0x11, 0x17) : _rgb(0xFF, 0xFF, 0xFF)
    fg = theme === :dark ? Tachikoma.ColorRGB(0xF1, 0xF5, 0xF9) :
        Tachikoma.ColorRGB(0x0A, 0x19, 0x29)

    path = joinpath(OUT_DIR, name * ".png")
    Tachikoma.export_apng_from_snapshots(
        path,
        WIDTH,
        HEIGHT,
        [cells],
        [0.0];
        font_path = FONT_PATH,
        font_size = FONT_SIZE,
        cell_w = CELL_W,
        cell_h = CELL_H,
        bg = bg,
        default_fg = fg
    )

    # The APNG writer stores the pixels uncompressed; re-encode the single frame as a
    # plain compressed PNG.
    PNGFiles.save(path, PNGFiles.load(path))

    set_theme!(TS.SCOPE_DARK_THEME)
    Tachikoma.set_light_mode!(false)
    println("  generated $name.png")
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
    sim = LCRST.addchild(ev, ND(_sf("run_simulation", WFILE, 9), 0x00, 1:990))

    prop = LCRST.addchild(sim, ND(_sf("propagate_orbits", WFILE, 20), 0x00, 1:520))
    integ = LCRST.addchild(prop, ND(_sf("integrate_state", WFILE, 28), 0x00, 1:490))
    rk4 = LCRST.addchild(integ, ND(_sf("rk4_step", WFILE, 34), 0x00, 1:470))
    dyn = LCRST.addchild(
        rk4,
        ND(_sf("dynamics", WFILE, 36), FlameGraphs.runtime_dispatch, 1:380)
    )
    LCRST.addchild(dyn, ND(_sf("sin", "special/trig.jl", 29), 0x00, 1:200))
    LCRST.addchild(dyn, ND(_sf("perturbation", WFILE, 38), 0x00, 201:340))
    LCRST.addchild(rk4, ND(_sf("+", "promotion.jl", 425), 0x00, 381:440))

    est = LCRST.addchild(
        sim,
        ND(_sf("estimate_residuals", WFILE, 41), FlameGraphs.runtime_dispatch, 521:700)
    )
    LCRST.addchild(est, ND(_sf("mean_state", WFILE, 44), 0x00, 521:600))
    LCRST.addchild(est, ND(_sf("materialize", "broadcast.jl", 892), 0x00, 601:670))

    eph = LCRST.addchild(sim, ND(_sf("load_ephemeris", WFILE, 48), 0x00, 701:790))
    LCRST.addchild(eph, ND(_sf("read", "iostream.jl", 446), 0x00, 701:760))

    sm = LCRST.addchild(sim, ND(_sf("summarize", WFILE, 59), 0x00, 791:860))
    LCRST.addchild(sm, ND(_sf("string", "strings/io.jl", 189), 0x00, 791:845))

    att = LCRST.addchild(sim, ND(_sf("interpolate_attitude", WFILE, 51), 0x00, 861:915))
    LCRST.addchild(att, ND(_sf("materialize", "broadcast.jl", 892), 0x00, 861:900))

    wr = LCRST.addchild(sim, ND(_sf("write_results", WFILE, 54), 0x00, 916:950))
    LCRST.addchild(wr, ND(_sf("unsafe_write", "io.jl", 735), 0x00, 916:940))

    LCRST.addchild(
        sim,
        ND(_sf("jl_gc_small_alloc", "gc.c", 0; from_c = true), FlameGraphs.gc_event, 951:975)
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
    st_sim = [_sf("run_simulation", WFILE, 9), _sf("eval", "boot.jl", 430)]
    st_prop = [_sf("propagate_orbits", WFILE, 17), st_sim...]
    st_integ = [_sf("integrate_state", WFILE, 28), _sf("propagate_orbits", WFILE, 20), st_sim...]
    st_eph = [_sf("split", "strings/util.jl", 608), _sf("load_ephemeris", WFILE, 48), st_sim...]
    st_sum = [_sf("string", "strings/io.jl", 189), _sf("summarize", WFILE, 59), st_sim...]
    st_est = [_sf("materialize", "broadcast.jl", 892), _sf("estimate_residuals", WFILE, 41), st_sim...]
    st_att = [_sf("materialize", "broadcast.jl", 892), _sf("interpolate_attitude", WFILE, 51), st_sim...]

    alloc(T, st, size) = Profile.Allocs.Alloc(T, st, size, C_NULL, UInt64(0))
    allocs = [alloc(Vector{Float64}, st_prop, 80_000)]

    for _ in 1:64
        push!(allocs, alloc(Vector{Float64}, st_integ, 1_024))
    end

    for _ in 1:24
        push!(allocs, alloc(String, st_eph, 512))
    end

    for _ in 1:12
        push!(allocs, alloc(String, st_sum, 256))
    end

    for _ in 1:3
        push!(allocs, alloc(Vector{Float64}, st_est, 8_192))
    end

    for _ in 1:2
        push!(allocs, alloc(Vector{Float64}, st_att, 8_192))
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
    Base.invokelatest(W.propagate_orbits, collect(0.1:0.1:1.0), 10)
    Base.invokelatest(W.estimate_residuals, collect(0.1:0.1:1.0))

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

tinf = SnoopCompileCore.@snoop_inference begin
    Base.invokelatest(WorkloadFresh.propagate_orbits, collect(0.1:0.1:1.0), 50)
    Base.invokelatest(WorkloadFresh.estimate_residuals, collect(0.1:0.1:1.0))
end
render_png(TS.inference_viewer(tinf), "inference_profile")

# == Runtime Profile =======================================================================

render_png(runtime_viewer(), "runtime_profile")

# == Allocation Profile ====================================================================

render_png(TS.alloc_viewer(alloc_results()), "allocation_profile")

# == Invalidations =========================================================================

render_png(TS.invalidation_viewer(invalidation_trees()), "invalidations")

# == Type Inspector ========================================================================

config = Dict{String, Any}("gain" => 2.0, "offset" => 0.5)
Base.invokelatest(Workload.apply_gain, config, [1.0, 2.0])
mi = Cthulhu.get_specialization(
    Workload.apply_gain,
    Tuple{Dict{String, Any}, Vector{Float64}}
)
render_png(TS.inspector_viewer(mi), "type_inspector")

# == Frame Search ==========================================================================

m = runtime_viewer()
_key!(m, :char, '/')
_type!(m, "state")
render_png(m, "search_prompt")

_key!(m, :enter)
render_png(m, "search_results")

# == Help Dialog ===========================================================================

m = runtime_viewer()
_key!(m, :char, '?')
render_png(m, "help_dialog")

# == Light Theme ===========================================================================

render_png(runtime_viewer(), "light_theme"; theme = :light)

println("Done.")
