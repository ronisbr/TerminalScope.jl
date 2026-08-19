## Description #############################################################################
#
# Rendering of the header, tree view, status bar, and help dialog.
#
############################################################################################

"""
    HELP_ENTRIES

Key bindings shown in the help dialog as tuples `(section, key, description)`.
"""
const HELP_ENTRIES = (
    (:tree, "↑ / ↓", "Move the cursor / scroll the code"),
    (:tree, "PgUp / PgDn", "Move one page"),
    (:tree, "Home / End", "Go to the first / last row"),
    (:tree, "Enter / →", "Enter the node (code for a leaf)"),
    (:tree, "Bksp / ←", "Go back to the parent node"),
    (:tree, "Tab, 1 / 2", "Focus the list / source panel"),
    (:tree, "0 / \$", "Code: go to the line start / end"),
    (:tree, "^D / ^U", "Code: scroll half a page"),
    (:tree, "/", "Search frames in the whole tree"),
    (:tree, "n / N", "Jump to the next / previous match"),
    (:tree, "i", "Inspect type instabilities"),
    (:tree, "s", "Toggle the flat self-time view"),
    (:tree, "f", "Toggle the flame-graph panel"),
    (:tree, "u", "Toggle bytes / allocs (allocations)"),
    (:tree, "q", "Quit the application"),
    (:inspect, "↑ / ↓", "Select a call site"),
    (:inspect, "Enter / →", "Descend into the call site"),
    (:inspect, "Bksp / ←", "Ascend to the caller"),
    (:inspect, "Tab, 1 / 2", "Focus the code / call-site pane"),
    (:inspect, "t", "Toggle source / typed IR"),
    (:inspect, "q / Esc", "Close the inspector"),
    (:general, "j k h l g G", "Vim aliases of ↓ ↑ ← → Home End"),
    (:general, "+ / -", "Grow / shrink the focused panel"),
    (:general, "Mouse", "Wheel scrolls; click selects / enters"),
    (:general, "?", "Toggle this help dialog"),
)

"""
    HELP_SECTIONS

Display titles of the help dialog sections.
"""
const HELP_SECTIONS = (
    :tree => "Main View", :inspect => "Type Inspector", :general => "General"
)

"""
    view(m::ProfileViewer, f::Frame) -> Nothing

Render the full application frame for the model `m` into `f`: header, active view (tree
or detail), status bar, and, when open, the help dialog.
"""
function view(m::ProfileViewer, f::Frame)
    buf = f.buffer
    area = f.area

    if (area.width < 20) || (area.height < 6)
        set_string!(buf, area.x, area.y, "Terminal too small", tstyle(:error; bold = true))
        return nothing
    end

    header_h =
        ((m.mode == :inspect) || (m.compile !== nothing) || (m.inference_samples > 0)) ? 4 :
        3

    rects = split_layout(Layout(Vertical, [Fixed(header_h), Fill(), Fixed(1)]), area)
    (length(rects) < 3) && return nothing

    if m.mode == :inspect
        render_inspect_header!(m, buf, rects[1])
        render_inspect!(m, buf, rects[2])
    else
        render_header!(m, buf, rects[1])
        render_main!(m, f, rects[2])
    end

    render_status!(m, buf, rects[3])
    m.help && render_help!(buf, area)

    return nothing
end

"""
    render_header!(m::ProfileViewer, buf::Buffer, rect::Rect) -> Nothing

Render the header block with the general information about the profile into `buf` inside
`rect`, mutating `buf`.
"""
function render_header!(m::ProfileViewer, buf::Buffer, rect::Rect)
    title = if m.unit === :time
        " Inference Profile "
    elseif m.unit === :invalidations
        " Invalidations "
    elseif (m.unit === :bytes) || (m.unit === :allocs)
        " Allocations "
    else
        " Profile "
    end

    block = Block(;
        title = title,
        title_style = tstyle(:title; bold = true),
        title_right = " TerminalScope.jl ",
        title_right_style = tstyle(:text_dim),
        border_style = tstyle(:border),
        box = BOX_ROUNDED,
    )
    inner = render(block, rect, buf)
    ((inner.height < 1) || (inner.width < 1)) && return nothing

    label = tstyle(:text_dim)
    value = tstyle(:accent; bold = true)
    x = inner.x + 1
    y = inner.y
    mx = right(inner)

    nodes_str = string(format_count(length(m.rows)), " / ", format_count(m.total_nodes))

    if m.unit === :time
        x = set_string!(buf, x, y, "Inf. Time ", label; max_x = mx)
        x = set_string!(buf, x, y, format_seconds(m.nsamples / 1e9), value; max_x = mx)
        x = set_string!(buf, x, y, "   Nodes ", label; max_x = mx)
        set_string!(buf, x, y, nodes_str, value; max_x = mx)
        return nothing
    end

    if (m.unit === :bytes) || (m.unit === :allocs)
        bytes = m.unit === :bytes ? m.root.count : m.root.allocs
        nalloc = m.unit === :bytes ? m.root.allocs : m.root.count

        x = set_string!(buf, x, y, "Memory ", label; max_x = mx)
        x = set_string!(buf, x, y, format_bytes(bytes), value; max_x = mx)
        x = set_string!(buf, x, y, "   Allocs ", label; max_x = mx)
        x = set_string!(buf, x, y, format_count(nalloc), value; max_x = mx)
        x = set_string!(buf, x, y, "   Sorting by ", label; max_x = mx)
        x = set_string!(
            buf, x, y, m.unit === :bytes ? "memory" : "allocs", value; max_x = mx
        )
        x = set_string!(buf, x, y, "   Nodes ", label; max_x = mx)
        set_string!(buf, x, y, nodes_str, value; max_x = mx)
        return nothing
    end

    if m.unit === :invalidations
        x = set_string!(buf, x, y, "Invalidated ", label; max_x = mx)
        x = set_string!(buf, x, y, format_count(m.nsamples), value; max_x = mx)
        x = set_string!(buf, x, y, "   Triggers ", label; max_x = mx)
        x = set_string!(buf, x, y, format_count(length(m.root.children)), value; max_x = mx)
        x = set_string!(buf, x, y, "   Nodes ", label; max_x = mx)
        set_string!(buf, x, y, nodes_str, value; max_x = mx)
        return nothing
    end

    x = set_string!(buf, x, y, "Samples ", label; max_x = mx)
    x = set_string!(buf, x, y, format_count(m.nsamples), value; max_x = mx)
    x = set_string!(buf, x, y, "   Delay ", label; max_x = mx)
    x = set_string!(buf, x, y, format_seconds(m.delay), value; max_x = mx)
    x = set_string!(buf, x, y, "   Est. Time ", label; max_x = mx)
    x = set_string!(buf, x, y, format_seconds(m.nsamples * m.delay), value; max_x = mx)
    x = set_string!(buf, x, y, "   Nodes ", label; max_x = mx)
    set_string!(buf, x, y, nodes_str, value; max_x = mx)

    (inner.height >= 2) && render_header_extra!(m, buf, inner.x + 1, y + 1, mx)
    return nothing
end

"""
    render_header_extra!(m::ProfileViewer, buf::Buffer, x::Int, y::Int, mx::Int) -> Nothing

Render the second header line with the type inference sample aggregate and the wall-clock
compilation measurements, when available, into `buf` at `(x, y)` clipped to `mx`.
"""
function render_header_extra!(m::ProfileViewer, buf::Buffer, x::Int, y::Int, mx::Int)
    label = tstyle(:text_dim)
    value = tstyle(:accent; bold = true)

    if m.inference_samples > 0
        pct = m.nsamples == 0 ? 0.0 : 100 * m.inference_samples / m.nsamples
        x = set_string!(buf, x, y, "Inference ", label; max_x = mx)
        x = set_string!(
            buf,
            x,
            y,
            string(format_count(m.inference_samples), " (", format_pct(pct), ")"),
            tstyle(:primary; bold = true);
            max_x = mx,
        )
        x = set_string!(buf, x, y, "   ", label; max_x = mx)
    end

    if m.compile !== nothing
        c = m.compile
        pct_run = c.elapsed > 0 ? 100 * c.compile / c.elapsed : 0.0
        pct_re = c.compile > 0 ? 100 * c.recompile / c.compile : 0.0

        x = set_string!(buf, x, y, "Compile ", label; max_x = mx)
        x = set_string!(buf, x, y, format_seconds(c.compile), value; max_x = mx)
        set_string!(
            buf,
            x,
            y,
            string(
                " (",
                format_pct(pct_run),
                " of run, ",
                format_pct(pct_re),
                " recompilation)",
            ),
            label;
            max_x = mx,
        )
    end

    return nothing
end

"""
    tree_columns(row_w::Int, count_w::Int) -> NTuple{4, Int}

Return the widths `(pct_w, bar_w, count_w, right_w)` of the right-aligned columns of a
frame list row of `row_w` characters: the percentage of the total cost, the mini cost
bar, the cost cell, and the full right-aligned region. The bar and the cost cell are
dropped (width `0`) on narrow rows.
"""
function tree_columns(row_w::Int, count_w::Int)
    pct_w = 6
    bar_w = row_w >= 60 ? 8 : 0
    right_w = pct_w + 2 + count_w + (bar_w > 0 ? 2 + bar_w : 0)

    if row_w < right_w + 15
        bar_w = 0
        right_w = pct_w + 2 + count_w
    end

    if row_w < right_w + 10
        count_w = 0
        right_w = pct_w
    end

    return (pct_w, bar_w, count_w, right_w)
end

"""
    render_main!(m::ProfileViewer, f::Frame, rect::Rect) -> Nothing

Render the main view into `f` inside `rect`: the frame list on the left, the source
panel of the selected row on the right, and, on terminals with a graphics protocol, the
flame-graph panel along the bottom (see [`render_flame_panel!`](@ref)). Each zoom step
moves the split toward the zoomed panel, regardless of the focus; at the last step only
the focused panel renders, filling the whole `rect` and hiding the flame graph. The
flame graph is also hidden while the help dialog is open, since the Kitty protocol
draws images above the text and the dialog can overlap the panel.
"""
function render_main!(m::ProfileViewer, f::Frame, rect::Rect)
    buf = f.buffer
    m.list_rows_rect = Rect()
    m.code_rect = Rect()
    m.flame.rect = Rect()

    if m.zoom >= ZOOM_MAX
        if m.tree_focus === :list
            render_tree!(m, buf, rect; focused = true)
        else
            render_source_panel!(m, buf, rect; focused = true)
        end

        return nothing
    end

    show_flame = flame_active(m) && !m.help && (rect.height >= 16)
    main = rect
    flame_rect = Rect()

    if show_flame
        flame_h = clamp(rect.height ÷ 4, 6, 12)
        rows = split_layout(Layout(Vertical, [Fill(), Fixed(flame_h)]), rect)

        if length(rows) >= 2
            main = rows[1]
            flame_rect = rows[2]
        else
            show_flame = false
        end
    end

    # Each intermediate zoom step moves the split by 15% toward the zoomed panel.
    list_pct = 45 + 15 * (m.zoom_panel === :list ? m.zoom : -m.zoom)
    cols = split_layout(Layout(Horizontal, [Percent(list_pct), Fill()]), main)
    (length(cols) < 2) && return nothing

    render_tree!(m, buf, cols[1]; focused = m.tree_focus === :list)
    render_source_panel!(m, buf, cols[2]; focused = m.tree_focus === :code)
    show_flame && render_flame_panel!(m, f, flame_rect)
    return nothing
end

"""
    render_tree!(m::ProfileViewer, buf::Buffer, rect::Rect; focused::Bool = true) -> Nothing

Render the scrollable frame list of the current node into `buf` inside `rect`, mutating
`buf` and updating `m.visible_h` and `m.scroll`. The list is topped by a header line
labeling the columns when there is room for it. `focused` selects the border highlight.
In the flat self-time view, the panel is titled `Hot Frames` and the percentage column
is labeled `Self`.
"""
function render_tree!(m::ProfileViewer, buf::Buffer, rect::Rect; focused::Bool = true)
    block = Block(;
        title = m.flat ? " [1] Hot Frames " : " [1] Frames ",
        title_style = tstyle(:title; bold = focused),
        border_style = tstyle(focused ? :border_focus : :border),
        box = BOX_ROUNDED,
    )
    inner = render(block, rect, buf)
    ((inner.height < 1) || (inner.width < 1)) && return nothing

    header_h = inner.height >= 2 ? 1 : 0
    rows_y = inner.y + header_h
    rows_h = inner.height - header_h

    m.visible_h = max(rows_h, 1)
    m.list_rows_rect = Rect(inner.x, rows_y, inner.width, rows_h)
    clamp_scroll!(m)

    need_sb = length(m.rows) > rows_h
    content_right = right(inner) - (need_sb ? 1 : 0)
    count_w = max(7, length(count_cell(m.nsamples, m.unit)), length(count_label(m.unit)))

    (header_h == 1) &&
        render_tree_header!(buf, inner.x, inner.y, content_right, count_w, m.unit, m.flat)

    for (i, y) in zip((m.scroll + 1):length(m.rows), rows_y:bottom(inner))
        node = m.rows[i]
        render_row!(
            buf,
            inner,
            y,
            node,
            i == m.cursor,
            is_parent_row(m, node),
            content_right,
            count_w,
            m.unit,
        )
    end

    if need_sb
        track, thumb = scrollbar_styles(focused)
        sb = Scrollbar(length(m.rows), rows_h, m.scroll; style = track, thumb_style = thumb)
        render(sb, Rect(right(inner), rows_y, 1, rows_h), buf)
    end

    return nothing
end

"""
    render_tree_header!(
        buf::Buffer,
        x::Int,
        y::Int,
        content_right::Int,
        count_w::Int,
        unit::Symbol,
        flat::Bool
    ) -> Nothing

Render the frame list header line into `buf` at line `y`, mutating `buf`. It labels the
columns of the rows below: the frame name and location on the left and, on the right,
the mini cost bar, the cost in `unit` (samples, inference time, or invalidated
instances), and the percentage of the total cost — labeled `Self` instead of `Total`
when `flat` selects the flat self-time view. The labels are aligned with the columns of
a row spanning from `x` to `content_right`, whose cost cell is `count_w` characters
wide.
"""
function render_tree_header!(
    buf::Buffer, x::Int, y::Int, content_right::Int, count_w::Int, unit::Symbol, flat::Bool
)
    row_w = content_right - x + 1
    row_w < 1 && return nothing

    pct_w, bar_w, count_w, right_w = tree_columns(row_w, count_w)
    style = tstyle(:text_dim; bold = true)
    right_x = content_right - right_w + 1
    mx = right_x - 2

    set_string!(buf, x + 2, y, "Frame", style; max_x = mx)

    (bar_w > 0) && set_string!(buf, right_x, y, lpad("Cost", bar_w), style)

    (count_w > 0) && set_string!(
        buf,
        content_right - pct_w - 1 - count_w,
        y,
        lpad(count_label(unit), count_w),
        style,
    )

    set_string!(
        buf, content_right - pct_w + 1, y, lpad(flat ? "Self" : "Total", pct_w), style
    )
    return nothing
end

"""
    render_row!(
        buf::Buffer,
        inner::Rect,
        y::Int,
        node::PVNode,
        selected::Bool,
        is_parent::Bool,
        content_right::Int,
        count_w::Int,
        unit::Symbol
    ) -> Nothing

Render one frame list row for `node` at screen line `y` into `buf`, mutating `buf`. The
row spans from `inner.x` to `content_right` and shows, from right to left, the percentage
of the total cost, the cost in `unit` right-aligned to `count_w` characters, and a mini
cost bar. `selected` applies the cursor highlight, and `is_parent` renders the row as the
pinned parent entry of the list.
"""
function render_row!(
    buf::Buffer,
    inner::Rect,
    y::Int,
    node::PVNode,
    selected::Bool,
    is_parent::Bool,
    content_right::Int,
    count_w::Int,
    unit::Symbol,
)
    row_w = content_right - inner.x + 1
    row_w < 1 && return nothing

    # == Cursor Highlight ==================================================================

    if selected
        set_string!(buf, inner.x, y, " "^row_w, with_selection(tstyle(:text), true))
    end

    # == Right-Aligned Columns =============================================================

    pct_w, bar_w, count_w, right_w = tree_columns(row_w, count_w)
    right_x = content_right - right_w + 1

    if bar_w > 0
        set_string!(
            buf,
            right_x,
            y,
            bar_string(node.pct_total, bar_w),
            with_selection(bar_style(node.pct_total), selected),
        )
    end

    if count_w > 0
        set_string!(
            buf,
            content_right - pct_w - 1 - count_w,
            y,
            lpad(count_cell(node.count, unit), count_w),
            with_selection(tstyle(:accent; bold = selected), selected),
        )
    end

    set_string!(
        buf,
        content_right - pct_w + 1,
        y,
        lpad(format_pct(node.pct_total), pct_w),
        with_selection(tstyle(:text_dim), selected),
    )

    # == Left Part: Glyph, Name, Tags, and Location ========================================

    mx = right_x - 2
    x = inner.x

    glyph = is_parent ? "⬑ " : (isempty(node.children) ? "· " : "▸ ")
    x = set_string!(
        buf, x, y, glyph, with_selection(tstyle(:text_dim), selected); max_x = mx
    )

    name_style = is_parent ? tstyle(:secondary; bold = true) : row_name_style(node)

    if selected
        name_style = with_selection(
            Style(;
                fg = name_style.fg,
                bold = true,
                dim = name_style.dim,
                italic = name_style.italic,
            ),
            true,
        )
    end

    x = set_string!(buf, x, y, node_name(node), name_style; max_x = mx)

    for (tag, style) in node_tags(node)
        x = set_string!(buf, x, y, tag, with_selection(style, selected); max_x = mx)
    end

    loc = node_location(node)

    if !isempty(loc)
        x = set_string!(
            buf,
            x,
            y,
            "  " * loc,
            with_selection(tstyle(:text_dim; italic = true), selected);
            max_x = mx,
        )

        pkg = node_package(node)

        if pkg !== nothing
            set_string!(
                buf, x, y, " [$pkg]", with_selection(package_style(), selected); max_x = mx
            )
        end
    end

    return nothing
end

"""
    breadcrumb(node::Union{PVNode, Nothing}) -> String

Return the ancestry path of `node` joined by `" ▸ "`, left-truncated with `…` when longer
than 60 characters.
"""
function breadcrumb(node::Union{PVNode, Nothing})
    node === nothing && return ""
    names = String[]
    n = node

    while n !== nothing
        pushfirst!(names, node_name(n))
        n = n.parent
    end

    return _truncate_crumb(join(names, " ▸ "))
end

"""
    render_status!(m::ProfileViewer, buf::Buffer, rect::Rect) -> Nothing

Render the bottom status line with the most important key bindings for the active view
and the breadcrumb of the current node into `buf` inside `rect`, mutating `buf`.
"""
function render_status!(m::ProfileViewer, buf::Buffer, rect::Rect)
    key = tstyle(:accent; bold = true)
    txt = tstyle(:text_dim)

    searching = (m.mode == :tree) && (m.search_input !== nothing)

    hints = if m.help
        ["esc/q" => "close"]
    elseif searching
        ["⏎" => "search", "esc" => "cancel"]
    elseif m.mode == :tree
        hints = [
            "↑↓" => "move",
            "⏎/→" => "enter",
            "⌫/←" => "back",
            "1/2" => "pane",
            "+/-" => "zoom",
            "/" => "search",
            "s" => m.flat ? "tree" : "self",
            "i" => "inspect",
            "?" => "help",
            "q" => "quit",
        ]
        flame_available(m) && insert!(hints, 8, "f" => "flame")
        ((m.unit === :bytes) || (m.unit === :allocs)) &&
            insert!(hints, 6, "u" => m.unit === :bytes ? "by allocs" : "by memory")
        hints
    else
        [
            "↑↓" => "move",
            "⏎/→" => "descend",
            "⌫/←" => "ascend",
            "1/2" => "pane",
            "+/-" => "zoom",
            "t" => "src/IR",
            "q" => "close",
        ]
    end

    hint_spans = Span[]

    for (k, desc) in hints
        push!(hint_spans, Span(k, key))
        push!(hint_spans, Span(" " * desc * "  ", txt))
    end

    # While searching, the prompt takes the left side like the Neovim command line, and
    # the hints move to the right.
    left = if searching
        Span[
            Span(" /", tstyle(:accent; bold = true)),
            Span(m.search_input * "▏", tstyle(:text; bold = true)),
        ]
    else
        pushfirst!(hint_spans, Span(" ", txt))
    end

    right_spans = if searching
        hint_spans
    elseif !isempty(m.notice)
        Span[Span(m.notice * " ", tstyle(:accent; bold = true))]
    else
        crumb_str = if m.mode == :inspect
            inspect_breadcrumb(m.inspect)
        elseif m.flat
            "Flat view: hottest frames by self " * lowercase(count_label(m.unit))
        else
            breadcrumb(m.current)
        end

        Span[Span(crumb_str * " ", txt)]
    end

    render(StatusBar(; left = left, right = right_spans, style = txt), rect, buf)
    return nothing
end

"""
    render_help!(buf::Buffer, area::Rect) -> Nothing

Render the centered help dialog listing all key bindings on top of the current frame,
dimming the background, mutating `buf`. The sections are laid out in two balanced columns
when the terminal is wide enough, and in a single column otherwise. The dialog is closed
with the Esc key.
"""
function render_help!(buf::Buffer, area::Rect)
    set_style!(buf, area, tstyle(:text_dim; dim = true))

    gap = 4

    # Rows of one section: a header, its entries, and a trailing blank row.
    sec_rows(section) = 2 + count(e -> e[1] == section, HELP_ENTRIES)
    total_rows = sum(sec_rows(s) for (s, _) in HELP_SECTIONS)

    # Key and description widths of the sections listed in one column.
    function col_widths(col)
        sections = Set(s for (s, _) in col)
        entries = [e for e in HELP_ENTRIES if e[1] in sections]
        kw = maximum(textwidth(e[2]) for e in entries)
        return (kw, kw + 3 + maximum(textwidth(e[3]) for e in entries))
    end

    # Split the sections into two row-balanced columns, falling back to a single column
    # when they do not fit side by side.
    cols2 = [Pair{Symbol, String}[], Pair{Symbol, String}[]]
    acc = 0

    for (s, t) in HELP_SECTIONS
        push!(cols2[acc >= total_rows ÷ 2 ? 2 : 1], s => t)
        acc += sec_rows(s)
    end

    widths2 = any(isempty, cols2) ? nothing : col_widths.(cols2)

    columns, widths =
        if (widths2 !== nothing) && (area.width >= sum(w[2] for w in widths2) + gap + 6)
            cols2, widths2
        else
            col = collect(Pair{Symbol, String}, HELP_SECTIONS)
            [col], [col_widths(col)]
        end

    col_rows(col) = isempty(col) ? 0 : sum(sec_rows(s) for (s, _) in col) - 1
    ncol = length(columns)

    # Interior: the tallest column plus the footer row.
    n_rows = maximum(col_rows, columns) + 1
    w = min(sum(w[2] for w in widths) + (ncol - 1) * gap + 6, area.width)
    h = min(n_rows + 2, area.height)

    rect = center(area, w, h)
    block = Block(;
        title = " Help ",
        title_style = tstyle(:title; bold = true),
        border_style = tstyle(:border_focus),
        box = BOX_HEAVY,
    )
    inner = render(block, rect, buf)
    ((inner.height < 1) || (inner.width < 1)) && return nothing

    for row in inner.y:bottom(inner)
        set_string!(buf, inner.x, row, " "^inner.width, RESET)
    end

    content_bottom = bottom(inner) - 1

    x0 = inner.x + 2

    for (c, col) in enumerate(columns)
        key_w = widths[c][1]
        y = inner.y

        for (section, title) in col
            y > content_bottom && break
            set_string!(
                buf, x0, y, title, tstyle(:secondary; bold = true); max_x = right(inner)
            )
            y += 1

            for (s, k, desc) in HELP_ENTRIES
                s == section || continue
                y > content_bottom && break
                x = set_string!(
                    buf,
                    x0,
                    y,
                    rpad(k, key_w),
                    tstyle(:accent; bold = true);
                    max_x = right(inner),
                )
                set_string!(buf, x + 3, y, desc, tstyle(:text); max_x = right(inner))
                y += 1
            end

            y += 1
        end

        x0 += widths[c][2] + gap
    end

    msg = "esc to close"
    pos = center(inner, textwidth(msg), 1)
    set_string!(buf, pos.x, bottom(inner), msg, tstyle(:text_dim; italic = true))

    return nothing
end
