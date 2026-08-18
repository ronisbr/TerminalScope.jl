## Description #############################################################################
#
# Detail view: frame information pane and source-code pane.
#
############################################################################################

"""
    mutable struct DetailState

Store the state of the source panel that follows the selected frame row.

# Fields

- `node::Union{PVNode, Nothing}`: Node whose source is being shown, or `nothing` before
    the first selection.
- `src_lines::Vector{String}`: Lines of the resolved source file, or empty when no source
    is available.
- `src_chars::Vector{Vector{Char}}`: Characters of each source line, used for horizontal
    clipping and syntax highlighting.
- `src_segments::Vector{Vector{Tuple{UnitRange{Int}, Style}}}`: Styled segments of each
    source line as character ranges, produced by the native Julia syntax highlighter.
- `src_path::Union{String, Nothing}`: Absolute path of the resolved source file, or
    `nothing` when no source is available.
- `src_scroll::Int`: Vertical scroll offset [lines] of the source pane (0-based).
- `src_hscroll::Int`: Horizontal scroll offset [columns] of the source pane (0-based).
- `src_h::Int`: Height [rows] of the source pane, written during rendering.
- `src_text_w::Int`: Width [columns] of the source pane text area (after the line-number
    gutter), written during rendering.
- `src_error::Union{String, Nothing}`: Message explaining why no source can be shown, or
    `nothing` when the source was loaded successfully.
"""
mutable struct DetailState
    node::Union{PVNode, Nothing}
    src_lines::Vector{String}
    src_chars::Vector{Vector{Char}}
    src_segments::Vector{Vector{Tuple{UnitRange{Int}, Style}}}
    src_path::Union{String, Nothing}
    src_scroll::Int
    src_hscroll::Int
    src_h::Int
    src_text_w::Int
    src_error::Union{String, Nothing}
end

"""
    DetailState() -> DetailState

Create an empty `DetailState` with no node and no loaded source.
"""
function DetailState()
    return DetailState(
        nothing,
        String[],
        Vector{Char}[],
        Vector{Tuple{UnitRange{Int}, Style}}[],
        nothing,
        0,
        0,
        1,
        1,
        nothing
    )
end

"""
    resolve_source(node::PVNode) -> Union{String, Nothing}

Return the absolute path of the Julia source file of `node`, or `nothing` when the node
has no Julia source (C functions, the tree root, or files that cannot be found).
"""
function resolve_source(node::PVNode)
    is_tree_root(node) && return nothing
    node.sf.from_c && return nothing

    file = string(node.sf.file)
    isempty(file) && return nothing
    isfile(file) && return file

    resolved = Base.find_source_file(file)
    (resolved !== nothing) && isfile(resolved) && return resolved

    return nothing
end

"""
    _PACKAGE_CACHE

Cache of the [`file_package`](@ref) lookups, keyed by the frame file string.
"""
const _PACKAGE_CACHE = Dict{String, Union{String, Nothing}}()

"""
    _project_name(path::String) -> Union{String, Nothing}

Return the `name` entry of the top-level section of the project file at `path`, or
`nothing` when the file does not exist, cannot be read, or does not name a package.
"""
function _project_name(path::String)
    isfile(path) || return nothing

    try
        for line in eachline(path)
            m = match(r"^\s*name\s*=\s*\"([^\"]+)\"", line)
            (m !== nothing) && return String(m.captures[1])

            # The name entry belongs to the top-level section, before any [table].
            startswith(lstrip(line), '[') && break
        end
    catch
    end

    return nothing
end

"""
    file_package(file::AbstractString) -> Union{String, Nothing}

Return the display name of the package that owns the source file `file`, e.g.
`"SatelliteToolbox.jl"`, resolved from the closest ancestor project file that names a
package. Return `"Base"` for files of the Julia base library, and `nothing` when the
owner cannot be determined. The file system is walked once per distinct `file`; the
result is cached.
"""
function file_package(file::AbstractString)
    return get!(() -> _resolve_package(String(file)), _PACKAGE_CACHE, String(file))
end

"""
    _resolve_package(file::String) -> Union{String, Nothing}

Perform the uncached owner lookup of [`file_package`](@ref).
"""
function _resolve_package(file::String)
    isempty(file) && return nothing

    path = if isabspath(file) && isfile(file)
        file
    else
        resolved = Base.find_source_file(file)
        ((resolved !== nothing) && isfile(resolved)) ? resolved : nothing
    end

    path === nothing && return nothing
    path = abspath(path)

    # Files of the Julia base library live under the distribution share directory and
    # have no project file.
    startswith(path, abspath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base")) &&
        return "Base"

    # Walk up the directory tree to the closest project file that names a package. This
    # covers installed packages, dev'ed packages, and the standard libraries.
    dir = dirname(path)

    while true
        for proj in ("Project.toml", "JuliaProject.toml")
            name = _project_name(joinpath(dir, proj))
            (name !== nothing) && return name * ".jl"
        end

        parent = dirname(dir)
        (parent == dir) && return nothing
        dir = parent
    end
end

"""
    load_source!(d::DetailState) -> Nothing

Resolve, read, and highlight the source file of `d.node`, mutating `d` by filling
`src_lines`, `src_chars`, `src_segments`, `src_path`, and `src_error`, and resetting the
scroll offsets.
"""
function load_source!(d::DetailState)
    d.src_lines = String[]
    d.src_chars = Vector{Char}[]
    d.src_segments = Vector{Tuple{UnitRange{Int}, Style}}[]
    d.src_path = nothing
    d.src_scroll = 0
    d.src_hscroll = 0
    d.src_error = nothing

    node = d.node
    node === nothing && return nothing

    if is_tree_root(node)
        d.src_error = "Aggregate node — no source"
        return nothing
    elseif node.sf.from_c
        d.src_error = "C function — no Julia source"
        return nothing
    end

    path = resolve_source(node)

    if path === nothing
        d.src_error = "Source file not found"
        return nothing
    end

    try
        content = read(path, String)
        lines = String.(split(content, '\n'))
        endswith(content, '\n') && !isempty(lines) && pop!(lines)

        d.src_lines = lines
        d.src_chars = collect.(lines)
        d.src_segments = highlight_lines(content, length(lines))
        d.src_path = path
    catch
        d.src_error = "Could not read source file"
    end

    return nothing
end

############################################################################################
#                                   Syntax Highlighting                                    #
############################################################################################

# Map of the StyledStrings named ANSI colors to their terminal color indices.
const _ANSI_COLOR_INDEX = Dict{Symbol, Int}(
    :black => 0,
    :red => 1,
    :green => 2,
    :yellow => 3,
    :blue => 4,
    :magenta => 5,
    :cyan => 6,
    :white => 7,
    :bright_black => 8,
    :grey => 8,
    :gray => 8,
    :bright_red => 9,
    :bright_green => 10,
    :bright_yellow => 11,
    :bright_blue => 12,
    :bright_magenta => 13,
    :bright_cyan => 14,
    :bright_white => 15
)

# Cache of the resolved face styles, keyed by the annotation face value.
const _FACE_STYLE_CACHE = Dict{Any, Style}()

"""
    face_style(face) -> Style

Return the Tachikoma style of the StyledStrings `face` (usually a `Symbol` naming a
`JuliaSyntaxHighlighting` face), resolving its foreground color, weight, and slant.
`nothing` maps to the default text style.
"""
function face_style(face)
    face === nothing && return Style()

    return get!(_FACE_STYLE_CACHE, face) do
        f = StyledStrings.getface(face)
        v = f.foreground.value

        fg = if v isa Symbol
            idx = get(_ANSI_COLOR_INDEX, v, nothing)
            idx === nothing ? nothing : Color256(idx)
        else
            ColorRGB(v.r, v.g, v.b)
        end

        bold = f.weight in (:semibold, :bold, :extrabold, :black)
        italic = f.slant === :italic

        fg === nothing && return Style(; bold = bold, italic = italic)
        return Style(; fg = fg, bold = bold, italic = italic)
    end
end

"""
    highlight_lines(
        content::String,
        nlines::Int
    ) -> Vector{Vector{Tuple{UnitRange{Int}, Style}}}

Highlight the Julia source `content` with `JuliaSyntaxHighlighting` and return, for each
of its `nlines` lines, the styled segments as character ranges within the line. Return
unstyled segments when the highlighter fails.
"""
function highlight_lines(content::String, nlines::Int)
    face_of = Vector{Any}(undef, ncodeunits(content))
    fill!(face_of, nothing)

    try
        hl = JuliaSyntaxHighlighting.highlight(content)

        for a in Base.annotations(hl)
            (a.label === :face) || continue

            for b in a.region
                face_of[b] = a.value
            end
        end
    catch
        # Fall through and emit unstyled segments.
    end

    segments = Vector{Tuple{UnitRange{Int}, Style}}[]
    cur = Tuple{UnitRange{Int}, Style}[]
    col = 0
    seg_lo = 1
    seg_face = nothing

    flush_segment!() = (col >= seg_lo) && push!(cur, (seg_lo:col, face_style(seg_face)))

    for i in eachindex(content)
        if content[i] == '\n'
            flush_segment!()
            push!(segments, cur)
            cur = Tuple{UnitRange{Int}, Style}[]
            col = 0
            seg_lo = 1
            seg_face = nothing
            continue
        end

        f = face_of[i]

        if (f !== seg_face) && (col >= seg_lo)
            flush_segment!()
            seg_lo = col + 1
            seg_face = f
        elseif col < seg_lo
            seg_face = f
        end

        col += 1
    end

    if (col > 0) || (length(segments) < nlines)
        flush_segment!()
        push!(segments, cur)
    end

    # Guard against a line count mismatch so rendering never goes out of bounds.
    while length(segments) < nlines
        push!(segments, Tuple{UnitRange{Int}, Style}[])
    end

    return segments
end

"""
    center_source!(d::DetailState, height::Int) -> Nothing

Mutate `d.src_scroll` so that the frame line is vertically centered in a source pane of
`height` rows.
"""
function center_source!(d::DetailState, height::Int)
    node = d.node
    node === nothing && return nothing
    d.src_scroll = clamp(
        node.sf.line - 1 - height ÷ 2,
        0,
        max(0, length(d.src_lines) - height)
    )
    return nothing
end

"""
    detail_vmax(d::DetailState) -> Int

Return the maximum vertical scroll offset of the source pane of `d`.
"""
detail_vmax(d::DetailState) = max(0, length(d.src_lines) - max(d.src_h, 1))

"""
    detail_hmax(d::DetailState) -> Int

Return the maximum horizontal scroll offset of the source pane of `d`, computed from the
widest currently visible line.
"""
function detail_hmax(d::DetailState)
    isempty(d.src_chars) && return 0
    lo = clamp(d.src_scroll + 1, 1, length(d.src_chars))
    hi = clamp(d.src_scroll + max(d.src_h, 1), 1, length(d.src_chars))
    maxlen = maximum(length(d.src_chars[i]) for i in lo:hi)
    return max(0, maxlen - max(d.src_text_w, 1))
end

"""
    detail_scroll!(d::DetailState, dv::Int, dh::Int) -> Nothing

Scroll the source pane of `d` by `dv` lines and `dh` columns, clamping to its content.
"""
function detail_scroll!(d::DetailState, dv::Int, dh::Int)
    (dv != 0) && (d.src_scroll = clamp(d.src_scroll + dv, 0, detail_vmax(d)))
    (dh != 0) && (d.src_hscroll = clamp(d.src_hscroll + dh, 0, detail_hmax(d)))
    return nothing
end

"""
    detail_hset!(d::DetailState, h::Int) -> Nothing

Set the horizontal scroll offset of the source pane of `d` to `h`, clamping to its
content.
"""
function detail_hset!(d::DetailState, h::Int)
    d.src_hscroll = clamp(h, 0, detail_hmax(d))
    return nothing
end

"""
    detail_vset!(d::DetailState, v::Int) -> Nothing

Set the vertical scroll offset of the source pane of `d` to `v`, clamping to its
content.
"""
function detail_vset!(d::DetailState, v::Int)
    d.src_scroll = clamp(v, 0, detail_vmax(d))
    return nothing
end

"""
    info_strip(node::PVNode, delay::Float64, unit::Symbol) -> Vector{Vector{Span}}

Return the compact styled rows shown above the source code for the selected `node`: the
name with its flags, the costs of the active `unit` with the percentages, and the method
signature when the frame carries one. When `unit` is `:samples`, the `delay` [s] is used
to estimate wall-clock times.
"""
function info_strip(node::PVNode, delay::Float64, unit::Symbol)
    label = tstyle(:text_dim)
    value = tstyle(:text)
    accent = tstyle(:accent, bold = true)

    # == Name and Flags ====================================================================

    top = Span[Span(node_name(node), tstyle(:title, bold = true))]

    for (tag, style) in node_tags(node)
        push!(top, Span(tag, style))
    end

    node.sf.from_c && push!(top, Span(" [C]", tstyle(:text_dim)))
    node.sf.inlined && push!(top, Span(" [inlined]", tstyle(:secondary)))

    loc = node_location(node)
    !isempty(loc) && push!(top, Span("  " * loc, tstyle(:text_dim, italic = true)))

    pkg = node_package(node)
    (pkg !== nothing) && push!(top, Span(" [$pkg]", package_style()))

    # == Costs =============================================================================

    costs = Span[]

    if (unit === :bytes) || (unit === :allocs)
        bytes = unit === :bytes ? node.count : node.allocs
        nalloc = unit === :bytes ? node.allocs : node.count
        push!(costs, Span("Memory ", label), Span(format_bytes(bytes), accent))
        push!(costs, Span("   Allocs ", label), Span(format_count(nalloc), accent))
        push!(costs, Span("   Self ", label), Span(count_cell(node.self, unit), value))
    elseif unit === :invalidations
        push!(costs, Span("Instances ", label), Span(format_count(node.count), accent))
    elseif unit === :samples
        push!(costs, Span("Samples ", label), Span(format_count(node.count), accent))
        push!(costs, Span(" (", label), Span(format_seconds(node.count * delay), value))
        push!(costs, Span(")   Self ", label), Span(format_count(node.self), value))
    else
        push!(
            costs,
            Span("Inclusive ", label),
            Span(format_seconds(node.count / 1e9), accent)
        )
        push!(
            costs,
            Span("   Self ", label),
            Span(format_seconds(node.self / 1e9), value)
        )
    end

    push!(costs, Span("   Total ", label), Span(format_pct(node.pct_total), accent))
    push!(costs, Span("   Parent ", label), Span(format_pct(node.pct_parent), value))

    rows = Vector{Span}[top, costs]

    # == Method Signature ==================================================================

    linfo = node.sf.linfo

    if linfo isa Core.MethodInstance
        sig = try
            sprint(show, linfo)
        catch
            ""
        end

        !isempty(sig) &&
            push!(rows, Span[Span("Method ", label), Span(sig, value)])
    end

    return rows
end

"""
    spans_width(spans::Vector{Span}) -> Int

Return the total display width [columns] of `spans`.
"""
spans_width(spans::Vector{Span}) = sum(s -> textwidth(s.content), spans; init = 0)

"""
    set_spans_hclipped!(
        buf::Buffer,
        x::Int,
        y::Int,
        spans::Vector{Span},
        hskip::Int,
        mx::Int
    ) -> Int

Render `spans` at `(x, y)` into `buf`, skipping the first `hskip` display columns and
clipping at column `mx`. Return the column after the last drawn character.
"""
function set_spans_hclipped!(
    buf::Buffer,
    x::Int,
    y::Int,
    spans::Vector{Span},
    hskip::Int,
    mx::Int
)
    col = 0

    for span in spans
        (x > mx) && break
        sw = textwidth(span.content)

        if col + sw <= hskip
            col += sw
            continue
        end

        s = span.content

        if col < hskip
            idx = firstindex(s)
            skipped = 0

            while (idx <= lastindex(s)) && (skipped < hskip - col)
                skipped += textwidth(s[idx])
                idx = nextind(s, idx)
            end

            s = s[idx:end]
        end

        x = set_string!(buf, x, y, s, span.style; max_x = mx)
        col += sw
    end

    return x
end

"""
    render_code_line!(
        buf::Buffer,
        x::Int,
        y::Int,
        chars::Vector{Char},
        segments::Vector{Tuple{UnitRange{Int}, Style}},
        hskip::Int,
        mx::Int,
        selected::Bool
    ) -> Nothing

Render one syntax-highlighted source line at `(x, y)` into `buf`, skipping the first
`hskip` characters and clipping at column `mx`. `selected` applies the target-line
highlight background to every segment.
"""
function render_code_line!(
    buf::Buffer,
    x::Int,
    y::Int,
    chars::Vector{Char},
    segments::Vector{Tuple{UnitRange{Int}, Style}},
    hskip::Int,
    mx::Int,
    selected::Bool
)
    isempty(chars) && return nothing

    for (rg, style) in segments
        (x > mx) && break
        lo = max(first(rg), hskip + 1)
        hi = min(last(rg), length(chars))
        (lo > hi) && continue
        x = set_string!(
            buf,
            x,
            y,
            String(chars[lo:hi]),
            with_selection(style, selected);
            max_x = mx
        )
    end

    return nothing
end

"""
    line_cost_column(m, node::PVNode) -> Union{Nothing, Tuple{Dict{Int, Int}, Int, Int}}

Return the per-line allocation column data of the source file of `node` for the model
`m`: the value of the active unit per line, the maximum value, and the column width
[chars]. Return `nothing` when `m` is not an allocation viewer or no line of the file
allocated.
"""
function line_cost_column(m, node::PVNode)
    ((m.unit === :bytes) || (m.unit === :allocs)) || return nothing

    file = node.sf.file
    vals = Dict{Int, Int}()

    for ((f, l), (bytes, n)) in m.line_costs
        (f === file) || continue
        v = m.unit === :bytes ? bytes : n
        (v > 0) && (vals[l] = get(vals, l, 0) + v)
    end

    isempty(vals) && return nothing

    maxv = maximum(values(vals))
    width = clamp(maximum(length(count_cell(v, m.unit)) for v in values(vals)), 6, 12)
    return (vals, maxv, width)
end

"""
    sync_source!(m) -> Nothing

Make the source panel follow the row under the cursor: when the selection changed since
the last render, load and highlight its source file and center it on the frame line,
mutating `m.detail`.
"""
function sync_source!(m)
    d = m.detail
    node = selected_row(m)
    ((node === nothing) || (node === d.node)) && return nothing

    d.node = node
    load_source!(d)
    center_source!(d, max(d.src_h, 1))
    return nothing
end

"""
    render_source_panel!(m, buf::Buffer, rect::Rect; focused::Bool) -> Nothing

Render the source panel into `buf` inside `rect`, mutating `buf` and the state stored in
`m.detail`: a compact information strip for the row under the cursor (name, flags,
costs, and method signature) above the syntax-highlighted source code with the frame
line highlighted. In the allocation viewer, a heat-colored column between the line
numbers and the code shows the cost charged to each line. `focused` selects the border
highlight.
"""
function render_source_panel!(m, buf::Buffer, rect::Rect; focused::Bool)
    ((rect.width > 2) && (rect.height > 2)) || return nothing

    sync_source!(m)
    d = m.detail
    node = d.node
    node === nothing && return nothing

    title = d.src_path === nothing ? " [2] Source " : " [2] $(basename(d.src_path)) "
    pkg = d.src_path === nothing ? nothing : file_package(d.src_path)
    title_right = pkg === nothing ? "" : " $(pkg) "

    # The right title is dropped when the panel is too narrow to hold both titles,
    # since it would otherwise be drawn over the file name.
    (textwidth(title) + textwidth(title_right) + 6 > rect.width) && (title_right = "")

    block = Block(;
        title = title,
        title_right = title_right,
        title_right_style = package_style(),
        border_style = tstyle(focused ? :border_focus : :border),
        title_style = tstyle(:title, bold = focused),
        box = BOX_ROUNDED
    )
    inner = render(block, rect, buf)
    ((inner.height < 1) || (inner.width < 1)) && return nothing

    # == Information Strip =================================================================

    strip_rows = info_strip(node, m.delay, m.unit)
    strip_h = min(length(strip_rows) + 1, inner.height)
    mx_strip = right(inner)

    for (row, y) in zip(strip_rows, inner.y:(inner.y + strip_h - 2))
        set_spans_hclipped!(buf, inner.x + 1, y, row, 0, mx_strip)
    end

    if strip_h <= inner.height
        set_string!(
            buf,
            inner.x,
            inner.y + strip_h - 1,
            "─"^inner.width,
            tstyle(:border)
        )
    end

    src = Rect(inner.x, inner.y + strip_h, inner.width, max(inner.height - strip_h, 0))
    ((src.height < 1) || (src.width < 1)) && return nothing

    d.src_h = max(src.height, 1)

    if d.src_error !== nothing
        msg = d.src_error
        pos = center(src, min(length(msg), src.width), 1)
        set_string!(buf, pos.x, pos.y, msg, tstyle(:text_dim, italic = true))
        return nothing
    end

    d.src_scroll = clamp(d.src_scroll, 0, max(0, length(d.src_lines) - src.height))

    costs = line_cost_column(m, node)
    cost_w = costs === nothing ? 0 : costs[3] + 1
    gutter_w = length(string(length(d.src_lines))) + 1
    mx = right(src) - 1
    text_x = src.x + gutter_w + cost_w + 3
    d.src_text_w = max(mx - text_x + 1, 1)
    target = node.sf.line

    inner = src

    for (i, y) in zip((d.src_scroll + 1):length(d.src_lines), inner.y:bottom(inner))
        is_target = i == target

        if is_target
            set_string!(
                buf,
                inner.x,
                y,
                " "^(mx - inner.x + 1),
                with_selection(tstyle(:text), true)
            )
        end

        num_style = is_target ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        x = set_string!(
            buf,
            inner.x,
            y,
            lpad(string(i), gutter_w),
            with_selection(num_style, is_target);
            max_x = mx
        )

        if costs !== nothing
            vals, maxv, vw = costs
            v = get(vals, i, 0)

            cell, style = if v > 0
                (
                    lpad(count_cell(v, m.unit), vw),
                    bar_style(maxv == 0 ? 0.0 : 100 * v / maxv)
                )
            else
                (" "^vw, tstyle(:text_dim))
            end

            x = set_string!(
                buf,
                x + 1,
                y,
                cell,
                with_selection(style, is_target);
                max_x = mx
            )
        end

        x = set_string!(
            buf,
            x,
            y,
            is_target ? " ▶ " : "   ",
            with_selection(tstyle(:accent, bold = true), is_target);
            max_x = mx
        )
        render_code_line!(
            buf,
            x,
            y,
            d.src_chars[i],
            d.src_segments[i],
            d.src_hscroll,
            mx,
            is_target
        )
    end

    if length(d.src_lines) > inner.height
        sb = Scrollbar(
            length(d.src_lines),
            inner.height,
            d.src_scroll;
            style = tstyle(:border),
            thumb_style = tstyle(:accent)
        )
        render(sb, Rect(right(inner), inner.y, 1, inner.height), buf)
    end

    return nothing
end
