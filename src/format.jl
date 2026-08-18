## Description #############################################################################
#
# Pure formatting and style-selection helpers used by the renderer.
#
############################################################################################

"""
    node_name(node::PVNode) -> String

Return the display name of `node`: the root frame name (or `"all samples"` for an
unnamed root), `"unknown"` for frames without a function name, and the function name
otherwise.
"""
function node_name(node::PVNode)
    name = string(node.sf.func)
    is_tree_root(node) && return isempty(name) ? "all samples" : name
    return isempty(name) ? "unknown" : name
end

"""
    node_location(node::PVNode) -> String

Return the display location of `node` as `"file.jl:line"` using only the base name of the
file, or an empty string when the node has no location information.
"""
function node_location(node::PVNode)
    is_tree_root(node) && return ""
    file = string(node.sf.file)
    isempty(file) && return ""
    return string(basename(file), ":", node.sf.line)
end

"""
    node_package(node::PVNode) -> Union{String, Nothing}

Return the display name of the package that owns the source file of `node` (see
[`file_package`](@ref)), or `nothing` when the node has no location information or the
owner cannot be determined.
"""
function node_package(node::PVNode)
    is_tree_root(node) && return nothing
    file = string(node.sf.file)
    isempty(file) && return nothing
    return file_package(file)
end

"""
    format_count(n::Int) -> String

Return `n` formatted with `,` as the thousands separator.
"""
function format_count(n::Int)
    str = string(abs(n))
    groups = String[]

    for i in length(str):-3:1
        push!(groups, str[max(1, i - 2):i])
    end

    return string(n < 0 ? "-" : "", join(reverse(groups), ","))
end

"""
    format_pct(pct::Float64) -> String

Return the percentage `pct` [%] formatted with one decimal place, using `"<0.1%"` for
positive values below `0.05` and `"0.0%"` for zero.
"""
function format_pct(pct::Float64)
    (pct > 0) && (pct < 0.05) && return "<0.1%"
    return string(round(pct; digits = 1), "%")
end

"""
    format_seconds(t::Float64) -> String

Return the duration `t` [s] formatted with automatic scaling to ns, µs, ms, s, or min.
"""
function format_seconds(t::Float64)
    t < 1e-6 && return string(round(t * 1e9; digits = 1), " ns")
    t < 1e-3 && return string(round(t * 1e6; digits = 1), " µs")
    t < 1 && return string(round(t * 1000; digits = 1), " ms")
    t < 60 && return string(round(t; digits = 2), " s")
    m = floor(Int, t / 60)
    return string(m, " min ", round(t - 60m; digits = 1), " s")
end

"""
    format_bytes(n::Int) -> String

Return `n` [bytes] formatted with automatic scaling to B, KiB, MiB, or GiB.
"""
function format_bytes(n::Int)
    n < 1024 && return string(n, " B")
    n < 1024^2 && return string(round(n / 1024; digits = 1), " KiB")
    n < 1024^3 && return string(round(n / 1024^2; digits = 1), " MiB")
    return string(round(n / 1024^3; digits = 2), " GiB")
end

"""
    count_cell(count::Int, unit::Symbol) -> String

Return the cost column text for `count`: a formatted duration when `unit` is `:time`
(`count` in [ns]), a formatted size when it is `:bytes`, and a formatted count otherwise
(`:samples`, `:invalidations`, or `:allocs`).
"""
function count_cell(count::Int, unit::Symbol)
    (unit === :time) && return format_seconds(count / 1e9)
    (unit === :bytes) && return format_bytes(count)
    return format_count(count)
end

"""
    count_label(unit::Symbol) -> String

Return the header label of the cost column for `unit`: `"Samples"`, `"Time"`,
`"Instances"`, `"Memory"`, or `"Allocs"`.
"""
function count_label(unit::Symbol)
    (unit === :time) && return "Time"
    (unit === :invalidations) && return "Instances"
    (unit === :bytes) && return "Memory"
    (unit === :allocs) && return "Allocs"
    return "Samples"
end

"""
    bar_string(pct::Float64, width::Int) -> String

Return a horizontal bar of `width` cells filled proportionally to `pct` [%], using
eighth-block glyphs for the fractional cell.
"""
function bar_string(pct::Float64, width::Int)
    width <= 0 && return ""
    frac = clamp(pct / 100, 0.0, 1.0) * width
    full = floor(Int, frac)
    rem8 = round(Int, 8 * (frac - full))

    bar = repeat('█', min(full, width))

    if (full < width) && (rem8 > 0)
        bar *= BARS_H[rem8]
    end

    return rpad(bar, width)
end

"""
    bar_style(pct::Float64) -> Style

Return the style of the mini cost bar for a node taking `pct` [%] of the total samples:
green below 33 %, yellow below 66 %, and red above.
"""
function bar_style(pct::Float64)
    pct < 33 && return tstyle(:success)
    pct < 66 && return tstyle(:warning)
    return tstyle(:error)
end

"""
    _TEXT_TERTIARY

Tertiary text color of the SatelliteAnalysis.jl presentation palette (`#64748B`), used
for the package ownership labels. It is legible on both the navy and the white surfaces,
so it is shared by the two theme variants.
"""
const _TEXT_TERTIARY = SLATE.c500

"""
    package_style() -> Style

Return the style of the package ownership labels, e.g. `[SatelliteToolbox.jl]`.
"""
package_style() = Style(; fg = _TEXT_TERTIARY, italic = true)

"""
    node_tags(node::PVNode) -> Vector{Tuple{String, Style}}

Return the status tags shown after the name of `node` — `" [dyn]"` for runtime
dispatch, `" [GC]"` for garbage collection, and `" [inf]"` for compiler frames — with
their styles.
"""
function node_tags(node::PVNode)
    tags = Tuple{String, Style}[]
    is_dispatch(node) && push!(tags, (" [dyn]", tstyle(:error; bold = true)))
    is_gc(node) && push!(tags, (" [GC]", tstyle(:warning; bold = true)))
    is_inference(node) && push!(tags, (" [inf]", tstyle(:primary; bold = true)))
    return tags
end

"""
    _truncate_crumb(path::String) -> String

Return the breadcrumb `path` unchanged when it has at most 60 characters, and
left-truncated with `…` otherwise.
"""
function _truncate_crumb(path::String)
    length(path) <= 60 && return path
    return "…" * path[prevind(path, end, 59):end]
end

"""
    row_name_style(node::PVNode) -> Style

Return the style of the function name of `node` in the tree view: the theme error color
for runtime dispatch, the warning color for garbage collection, dimmed for C frames,
bright and bold for hot frames (≥ 50 % of the total samples), and the default text style
otherwise.
"""
function row_name_style(node::PVNode)
    is_dispatch(node) && return tstyle(:error)
    is_gc(node) && return tstyle(:warning)
    node.sf.from_c && return tstyle(:text_dim)
    node.pct_total >= 50 && return tstyle(:text_bright; bold = true)
    return tstyle(:text)
end

"""
    scrollbar_styles(focused::Bool) -> Tuple{Style, Style}

Return the track and thumb styles of a panel scrollbar, following the border color of
the panel: the thumb uses the focus-highlighted border color when the panel is focused
and the regular border color otherwise, with the track dimmed in the unfocused case so
the thumb stays readable.
"""
function scrollbar_styles(focused::Bool)
    focused && return (tstyle(:border), tstyle(:border_focus))
    return (tstyle(:border; dim = true), tstyle(:border))
end

"""
    selection_bg() -> Color256

Return the background color used to highlight the row under the cursor, adapted to the
current light or dark mode. The color is the `:selection` slot of the active variant,
overridable through Preferences.jl (see [`set_theme_color!`](@ref)).
"""
selection_bg() = light_mode() ? SCOPE_LIGHT_SELECTION : SCOPE_DARK_SELECTION

"""
    with_selection(style::Style, selected::Bool) -> Style

Return `style` unchanged when `selected` is `false`, or a copy with the selection
background applied when `selected` is `true`.
"""
function with_selection(style::Style, selected::Bool)
    selected || return style

    return Style(;
        fg = style.fg,
        bg = selection_bg(),
        bold = style.bold,
        dim = style.dim,
        italic = style.italic,
        underline = style.underline,
    )
end
