## Description #############################################################################
#
# Type-instability inspector backed by Cthulhu.jl: analysis, state, and rendering.
#
############################################################################################

"""
    struct InspectEntry

Represent one row of the call-site list of the inspector.

# Fields

- `label::String`: Display text of the call without the return type.
- `rt_str::String`: Display text of the inferred return type, or an empty string when it
    is unknown.
- `rt_style::Style`: Style of the return type, colored by its type stability.
- `line::Int`: Absolute source line of the call site, or `0` when it is unknown.
- `ci::Union{Core.CodeInstance, Nothing}`: Inferred code instance of the callee used to
    descend into it, or `nothing` when the call cannot be descended into.
- `dynamic::Bool`: Whether the call is a runtime (dynamic) dispatch.
- `unstable::Bool`: Whether the inferred return type is type-unstable (see
    [`is_unstable_rt`](@ref)).
- `sub::Bool`: Whether the entry is one target of a union-split call site.
"""
struct InspectEntry
    label::String
    rt_str::String
    rt_style::Style
    line::Int
    ci::Union{Core.CodeInstance, Nothing}
    dynamic::Bool
    unstable::Bool
    sub::Bool
end

"""
    mutable struct InspectFrame

Store the analysis of one method instance shown by the inspector.

# Fields

- `mi::Core.MethodInstance`: Inspected method instance.
- `label::String`: Display text of the method instance signature.
- `rt_str::String`: Display text of the inferred return type.
- `rt_style::Style`: Style of the return type, colored by its type stability.
- `entries::Vector{InspectEntry}`: Call sites of the method body.
- `code_lines::Vector{Vector{Span}}`: Styled lines of the type-annotated source code, or
    empty when the source cannot be annotated.
- `ir_lines::Vector{Vector{Span}}`: Styled lines of the inferred (typed) Julia IR.
- `start_line::Int`: Absolute source line of the first row of `code_lines`.
- `src_error::Union{String, Nothing}`: Message explaining why the annotated source is not
    available, or `nothing` when it was produced successfully.
- `view::Symbol`: Active code pane content, either `:source` or `:ir`.
- `cursor::Int`: Row under the cursor in the call-site list (1-based, row 1 is the pinned
    method row).
- `scroll::Int`: Scroll offset [rows] of the call-site list (0-based).
- `code_scroll::Int`: Vertical scroll offset [lines] of the code pane (0-based).
- `code_hscroll::Int`: Horizontal scroll offset [columns] of the code pane (0-based).
"""
mutable struct InspectFrame
    mi::Core.MethodInstance
    label::String
    rt_str::String
    rt_style::Style
    entries::Vector{InspectEntry}
    code_lines::Vector{Vector{Span}}
    ir_lines::Vector{Vector{Span}}
    start_line::Int
    src_error::Union{String, Nothing}
    view::Symbol
    cursor::Int
    scroll::Int
    code_scroll::Int
    code_hscroll::Int
end

"""
    mutable struct InspectState

Store the state of the type-instability inspector.

# Fields

- `provider::Any`: Cthulhu provider holding the inference caches, created lazily on the
    first use by the `TerminalScopeCthulhuExt` extension, or `nothing` before that.
- `loading::Bool`: Whether a background task is currently loading the Cthulhu backend.
- `pending_mi::Union{Core.MethodInstance, Nothing}`: Method instance to open as soon as
    the backend finishes loading, or `nothing`.
- `stack::Vector{InspectFrame}`: Stack of the visited frames; the last one is displayed.
- `focus::Symbol`: Pane receiving the scroll keys, either `:calls` or `:code`.
- `standalone::Bool`: Whether the inspector is the only view of the application, so
    leaving it quits.
- `return_mode::Symbol`: Mode to restore when the inspector is closed.
- `calls_h::Int`: Height [rows] of the call-site list, written during rendering.
- `code_h::Int`: Height [rows] of the code pane, written during rendering.
- `code_w::Int`: Width [columns] of the code pane text area, written during rendering.
- `calls_rect::Rect`: Screen area of the call-site list, written during rendering and
    used by the mouse handling. It is empty while the pane is not shown.
- `code_rect::Rect`: Screen area of the code pane, written during rendering and used by
    the mouse handling. It is empty while the pane is not shown.
"""
mutable struct InspectState
    provider::Any
    loading::Bool
    pending_mi::Union{Core.MethodInstance, Nothing}
    stack::Vector{InspectFrame}
    focus::Symbol
    standalone::Bool
    return_mode::Symbol
    calls_h::Int
    code_h::Int
    code_w::Int
    calls_rect::Rect
    code_rect::Rect
end

"""
    InspectState() -> InspectState

Create an empty `InspectState` with no provider, an empty frame stack, and the call-site
list focused.
"""
function InspectState()
    return InspectState(
        nothing,
        false,
        nothing,
        InspectFrame[],
        :calls,
        false,
        :tree,
        1,
        1,
        1,
        Rect(),
        Rect(),
    )
end

############################################################################################
#                                         Analysis                                         #
############################################################################################

"""
    is_unstable_rt(rt) -> Bool

Return `true` if the inferred return type `rt` is type-unstable, i.e., a non-concrete
`Type` as classified by `TypedSyntax.is_type_unstable`.
"""
is_unstable_rt(@nospecialize(rt)) = (rt isa Type) && TypedSyntax.is_type_unstable(rt)

"""
    type_stability_style(rt) -> Style

Return the style of the inferred type `rt` following the Cthulhu conventions: the theme
error color for abstract types, the warning color for small `Union`s, and the primary
(cyan) color for concrete (stable) types.
"""
function type_stability_style(@nospecialize(rt))
    is_unstable_rt(rt) || return tstyle(:primary)
    TypedSyntax.is_small_union_or_tunion(rt) && return tstyle(:warning; bold = true)
    return tstyle(:error; bold = true)
end

"""
    is_unstable_entry(e::InspectEntry) -> Bool

Return `true` if the call site `e` returns a type-unstable value or is a dynamic
dispatch.
"""
is_unstable_entry(e::InspectEntry) = e.dynamic || e.unstable

"""
    ansi_spans(text::AbstractString) -> Vector{Vector{Span}}

Split `text` into lines of styled `Span`s by interpreting the ANSI SGR escape sequences
produced by `printstyled` and the typed IR printer (colors, bold, italic, and underline).
Unknown sequences are dropped.
"""
function ansi_spans(text::AbstractString)
    lines = Vector{Span}[]
    cur = Span[]
    seg = IOBuffer()

    fg::Union{Color256, ColorRGB, Nothing} = nothing
    bold = false
    dim = false
    italic = false
    underline = false

    make_style() =
        fg === nothing ?
        Style(; bold = bold, dim = dim, italic = italic, underline = underline) :
        Style(; fg = fg, bold = bold, dim = dim, italic = italic, underline = underline)

    function flush_seg!()
        s = String(take!(seg))
        !isempty(s) && push!(cur, Span(s, make_style()))
        return nothing
    end

    function apply_sgr!(params::Vector{Int})
        isempty(params) && push!(params, 0)
        i = 1

        while i <= length(params)
            p = params[i]

            if p == 0
                fg = nothing
                bold = dim = italic = underline = false
            elseif p == 1
                bold = true
            elseif p == 2
                dim = true
            elseif p == 3
                italic = true
            elseif p == 4
                underline = true
            elseif p == 22
                bold = dim = false
            elseif p == 23
                italic = false
            elseif p == 24
                underline = false
            elseif 30 <= p <= 37
                fg = Color256(p - 30)
            elseif p == 39
                fg = nothing
            elseif 90 <= p <= 97
                fg = Color256(p - 82)
            elseif (p == 38) && (i + 2 <= length(params)) && (params[i + 1] == 5)
                fg = Color256(params[i + 2])
                i += 2
            elseif (p == 38) && (i + 4 <= length(params)) && (params[i + 1] == 2)
                fg = ColorRGB(params[i + 2], params[i + 3], params[i + 4])
                i += 4
            end

            i += 1
        end

        return nothing
    end

    i = firstindex(text)

    while i <= lastindex(text)
        c = text[i]

        if c == '\e'
            j = nextind(text, i)

            if (j <= lastindex(text)) && (text[j] == '[')
                k = nextind(text, j)
                lo = k

                while (k <= lastindex(text)) && ((text[k] == ';') || isdigit(text[k]))
                    k = nextind(text, k)
                end

                if (k <= lastindex(text)) && (text[k] == 'm')
                    flush_seg!()
                    params = [
                        parse(Int, p) for
                        p in split(text[lo:prevind(text, k)], ';') if !isempty(p)
                    ]
                    apply_sgr!(params)
                end

                i = (k <= lastindex(text)) ? nextind(text, k) : k
                continue
            end
        elseif c == '\n'
            flush_seg!()
            push!(lines, cur)
            cur = Span[]
        elseif c != '\r'
            print(seg, c)
        end

        i = nextind(text, i)
    end

    flush_seg!()
    push!(lines, cur)
    return lines
end

"""
    _mi_label(mi::Core.MethodInstance) -> String

Return the display text of the method instance `mi`, e.g. `"caller(::Int64)"`.
"""
function _mi_label(mi::Core.MethodInstance)
    s = try
        sprint(show, mi)
    catch
        return "unknown"
    end

    return String(chopprefix(s, "MethodInstance for "))
end

"""
    inspector_available() -> Bool

Return `true` if the Cthulhu-backed inspector analysis is available, i.e., the
`TerminalScopeCthulhuExt` extension is loaded because the user has run `using Cthulhu`.
"""
inspector_available() =
    Base.get_extension(@__MODULE__, :TerminalScopeCthulhuExt) !== nothing

"""
    inspect_frame(provider, mi::Core.MethodInstance[, ci]) -> InspectFrame

Analyze the method instance `mi` with Cthulhu and return the inspector frame. The method
is provided by the `TerminalScopeCthulhuExt` extension.
"""
function inspect_frame end

"""
    _enter_inspect_impl!(m, mi::Core.MethodInstance) -> Nothing

Open the inspector on `mi`. The method is provided by the `TerminalScopeCthulhuExt`
extension; use [`enter_inspect!`](@ref), which guards for its availability.
"""
function _enter_inspect_impl! end

"""
    _descend_frame(provider, ci::Core.CodeInstance) -> InspectFrame

Return the inspector frame of the callee behind `ci`. The method is provided by the
`TerminalScopeCthulhuExt` extension.
"""
function _descend_frame end

"""
    _descend_specialization(f, types) -> Union{Core.MethodInstance, Nothing}

Return the method instance of `f` specialized for `types`. The method is provided by the
`TerminalScopeCthulhuExt` extension.
"""
function _descend_specialization end

"""
    _error_frame(mi::Core.MethodInstance, msg::String) -> InspectFrame

Return an `InspectFrame` for `mi` carrying only the error message `msg`.
"""
function _error_frame(mi::Core.MethodInstance, msg::String)
    return InspectFrame(
        mi,
        _mi_label(mi),
        "",
        tstyle(:text_dim),
        InspectEntry[],
        Vector{Span}[],
        Vector{Span}[],
        1,
        msg,
        :source,
        1,
        0,
        0,
        0,
    )
end

############################################################################################
#                                        Navigation                                        #
############################################################################################

"""
    inspect_top(st::InspectState) -> Union{InspectFrame, Nothing}

Return the frame displayed by the inspector, or `nothing` when the stack is empty.
"""
inspect_top(st::InspectState) = isempty(st.stack) ? nothing : st.stack[end]

"""
    selected_entry(fr::InspectFrame) -> Union{InspectEntry, Nothing}

Return the call-site entry under the cursor of `fr`, or `nothing` when the cursor is on
the pinned method row.
"""
function selected_entry(fr::InspectFrame)
    idx = fr.cursor - 1
    (1 <= idx <= length(fr.entries)) || return nothing
    return fr.entries[idx]
end

"""
    sync_inspect_code!(st::InspectState) -> Nothing

Mutate the code pane scroll of the displayed frame so that the source line of the
selected call site is centered, when the annotated source is shown and the line is known.
"""
function sync_inspect_code!(st::InspectState)
    fr = inspect_top(st)
    fr === nothing && return nothing
    (fr.view === :source) || return nothing

    entry = selected_entry(fr)
    ((entry === nothing) || (entry.line <= 0)) && return nothing

    row = entry.line - fr.start_line + 1
    h = max(st.code_h, 1)
    fr.code_scroll = clamp(row - 1 - h ÷ 2, 0, max(0, length(fr.code_lines) - h))
    return nothing
end

"""
    enter_inspect!(m, mi::Core.MethodInstance) -> Nothing

Open the type-instability inspector on the method instance `mi`, switching the
application mode of the model `m` to `:inspect`. On the first use, the Cthulhu backend
is loaded by a background task while a status notice explains the wait, and the
inspector opens automatically when the load finishes.
"""
function enter_inspect!(m, mi::Core.MethodInstance)
    if inspector_available()
        Base.invokelatest(_enter_inspect_impl!, m, mi)
        return nothing
    end

    st = m.inspect
    st.pending_mi = mi
    m.notice = "Loading the inspector backend (Cthulhu) — one-time initialization..."

    if !st.loading && (m.tasks !== nothing)
        st.loading = true
        Tachikoma.spawn_task!(
            () -> _ensure_inspector(; quiet = true), m.tasks, :inspector_loaded
        )
    end

    return nothing
end

"""
    exit_inspect!(m) -> Nothing

Close the inspector, restoring the previous application mode of the model `m`, or
quitting the application when the inspector runs standalone.
"""
function exit_inspect!(m)
    st = m.inspect

    if st.standalone
        m.quit = true
    else
        m.mode = st.return_mode
    end

    return nothing
end

"""
    inspect_descend!(m) -> Nothing

Descend into the call site under the cursor of the inspector of `m`, pushing its frame
onto the stack. Ascend when the cursor is on the pinned method row, and do nothing when
the call site cannot be descended into.
"""
function inspect_descend!(m)
    st = m.inspect
    fr = inspect_top(st)
    fr === nothing && return nothing

    entry = selected_entry(fr)

    if entry === nothing
        inspect_ascend!(m)
        return nothing
    end

    (entry.ci === nothing) && return nothing

    push!(st.stack, Base.invokelatest(_descend_frame, st.provider, entry.ci))
    st.focus = :calls
    sync_inspect_code!(st)
    return nothing
end

"""
    inspect_ascend!(m) -> Nothing

Pop the displayed frame of the inspector of `m`, going back to its caller, or close the
inspector when the displayed frame is the entry point.
"""
function inspect_ascend!(m)
    st = m.inspect

    if length(st.stack) <= 1
        exit_inspect!(m)
        return nothing
    end

    pop!(st.stack)
    sync_inspect_code!(st)
    return nothing
end

"""
    inspect_move!(m, delta::Int) -> Nothing

Move the call-site cursor of the inspector of `m` by `delta` rows, clamping to the list
and keeping the cursor visible, then sync the code pane to the selected call site.
"""
function inspect_move!(m, delta::Int)
    st = m.inspect
    fr = inspect_top(st)
    fr === nothing && return nothing

    n = length(fr.entries) + 1
    fr.cursor = clamp(fr.cursor + delta, 1, n)
    fr.scroll = _clamped_scroll(fr.scroll, fr.cursor, max(st.calls_h, 1), n)

    sync_inspect_code!(st)
    return nothing
end

"""
    inspect_code_lines(fr::InspectFrame) -> Vector{Vector{Span}}

Return the lines displayed by the code pane of `fr` according to its active view.
"""
inspect_code_lines(fr::InspectFrame) = fr.view === :source ? fr.code_lines : fr.ir_lines

"""
    inspect_scroll_code!(m, dv::Int, dh::Int) -> Nothing

Scroll the code pane of the inspector of `m` by `dv` lines and `dh` columns, clamping to
the pane content.
"""
function inspect_scroll_code!(m, dv::Int, dh::Int)
    st = m.inspect
    fr = inspect_top(st)
    fr === nothing && return nothing

    lines = inspect_code_lines(fr)
    h = max(st.code_h, 1)
    fr.code_scroll = clamp(fr.code_scroll + dv, 0, max(0, length(lines) - h))

    maxw = isempty(lines) ? 0 : maximum(spans_width, lines)
    fr.code_hscroll = clamp(fr.code_hscroll + dh, 0, max(0, maxw - max(st.code_w, 1)))
    return nothing
end

"""
    inspect_toggle_view!(m) -> Nothing

Toggle the code pane of the inspector of `m` between the annotated source and the typed
IR, resetting the scroll offsets. The annotated source is skipped when it is not
available.
"""
function inspect_toggle_view!(m)
    fr = inspect_top(m.inspect)
    fr === nothing && return nothing

    fr.view = fr.view === :source ? :ir : :source
    (fr.view === :source) && (fr.src_error !== nothing) && (fr.view = :ir)

    fr.code_scroll = 0
    fr.code_hscroll = 0
    (fr.view === :source) && sync_inspect_code!(m.inspect)
    return nothing
end

"""
    inspect_breadcrumb(st::InspectState) -> String

Return the descend path of the inspector frames joined by `" ▸ "`, left-truncated with
`…` when longer than 60 characters.
"""
function inspect_breadcrumb(st::InspectState)
    names = String[]

    for fr in st.stack
        def = fr.mi.def
        push!(names, def isa Method ? string(def.name) : "toplevel")
    end

    return _truncate_crumb(join(names, " ▸ "))
end

############################################################################################
#                                        Rendering                                         #
############################################################################################

"""
    render_inspect_header!(m, buf::Buffer, rect::Rect) -> Nothing

Render the inspector header block with the inspected method, its inferred return type,
and the descend depth into `buf` inside `rect`, mutating `buf`.
"""
function render_inspect_header!(m, buf::Buffer, rect::Rect)
    block = Block(;
        title = " Type Inspector ",
        title_style = tstyle(:title; bold = true),
        title_right = " TerminalScope.jl ",
        title_right_style = tstyle(:text_dim),
        border_style = tstyle(:border),
        box = BOX_ROUNDED,
    )
    inner = render(block, rect, buf)
    ((inner.height < 1) || (inner.width < 1)) && return nothing

    fr = inspect_top(m.inspect)
    fr === nothing && return nothing

    label = tstyle(:text_dim)
    x = inner.x + 1
    y = inner.y
    mx = right(inner)

    x = set_string!(buf, x, y, "Method ", label; max_x = mx)
    x = set_string!(buf, x, y, fr.label, tstyle(:accent; bold = true); max_x = mx)
    x = set_string!(buf, x, y, "   Returns ", label; max_x = mx)
    set_string!(buf, x, y, fr.rt_str, fr.rt_style; max_x = mx)

    if inner.height >= 2
        x = inner.x + 1
        y += 1
        x = set_string!(buf, x, y, "Depth ", label; max_x = mx)
        x = set_string!(
            buf,
            x,
            y,
            string(length(m.inspect.stack)),
            tstyle(:accent; bold = true);
            max_x = mx,
        )

        n_unstable = count(is_unstable_entry, fr.entries)
        x = set_string!(buf, x, y, "   Unstable Call Sites ", label; max_x = mx)
        set_string!(
            buf,
            x,
            y,
            string(n_unstable, " / ", length(fr.entries)),
            n_unstable > 0 ? tstyle(:warning; bold = true) : tstyle(:success);
            max_x = mx,
        )
    end

    return nothing
end

"""
    render_inspect_entry!(
        buf::Buffer,
        x::Int,
        y::Int,
        entry::InspectEntry,
        selected::Bool,
        mx::Int
    ) -> Nothing

Render one call-site list row for `entry` at `(x, y)` into `buf`, clipped at column `mx`,
mutating `buf`. `selected` applies the cursor highlight.
"""
function render_inspect_entry!(
    buf::Buffer, x::Int, y::Int, entry::InspectEntry, selected::Bool, mx::Int
)
    glyph = entry.sub ? " ↳ " : (entry.ci === nothing ? "· " : "▸ ")
    x = set_string!(
        buf, x, y, glyph, with_selection(tstyle(:text_dim), selected); max_x = mx
    )

    name_style = entry.ci === nothing ? tstyle(:text_dim) : tstyle(:text)
    selected &&
        (name_style = Style(; fg = name_style.fg, bold = true, dim = name_style.dim))
    x = set_string!(
        buf, x, y, entry.label, with_selection(name_style, selected); max_x = mx
    )

    entry.dynamic && (
        x = set_string!(
            buf,
            x,
            y,
            " [dyn]",
            with_selection(tstyle(:error; bold = true), selected);
            max_x = mx,
        )
    )

    !isempty(entry.rt_str) && set_string!(
        buf,
        x,
        y,
        "::" * entry.rt_str,
        with_selection(entry.rt_style, selected);
        max_x = mx,
    )

    return nothing
end

"""
    render_inspect!(m, buf::Buffer, rect::Rect) -> Nothing

Render the inspector view into `buf` inside `rect`, mutating `buf` and the pane geometry
stored in `m.inspect`. Following the Cthulhu layout, the top pane shows the
type-annotated source (or the typed IR), highlighting the source line of the selected
call site, and the bottom pane lists the call sites of the inspected method with their
return types colored by stability.
"""
function render_inspect!(m, buf::Buffer, rect::Rect)
    st = m.inspect
    st.calls_rect = Rect()
    st.code_rect = Rect()
    fr = inspect_top(st)
    fr === nothing && return nothing

    # At the last zoom step the focused pane fills the whole view; otherwise the
    # call-site list gets the rows it needs, capped at half of the view, and each
    # intermediate zoom step moves the split toward the zoomed pane, regardless of the
    # focus.
    rows = if m.zoom >= ZOOM_MAX
        st.focus === :code ? [rect, Rect(rect.x, rect.y, 0, 0)] :
        [Rect(rect.x, rect.y, 0, 0), rect]
    else
        calls_want = clamp(length(fr.entries) + 3, 5, max(rect.height ÷ 2, 5))

        if m.zoom_panel === :calls
            calls_want += round(Int, m.zoom * (rect.height - calls_want) / ZOOM_MAX)
        else
            calls_want -= round(Int, m.zoom * (calls_want - 3) / ZOOM_MAX)
        end

        split_layout(Layout(Vertical, [Fill(), Fixed(calls_want)]), rect)
    end

    (length(rows) < 2) && return nothing

    # == Bottom Pane: Call Sites ===========================================================

    if (rows[2].width > 2) && (rows[2].height > 2)
        focused = st.focus === :calls
        block = Block(;
            title = " [2] Call Sites ",
            border_style = tstyle(focused ? :border_focus : :border),
            title_style = tstyle(:title; bold = focused),
            box = BOX_ROUNDED,
        )
        inner = render(block, rows[2], buf)

        st.calls_h = max(inner.height, 1)
        st.calls_rect = inner
        n = length(fr.entries) + 1
        fr.scroll = _clamped_scroll(fr.scroll, fr.cursor, st.calls_h, n)

        need_sb = n > inner.height
        mx = right(inner) - (need_sb ? 1 : 0)

        for (i, y) in zip((fr.scroll + 1):n, inner.y:bottom(inner))
            selected = i == fr.cursor

            if selected
                set_string!(
                    buf,
                    inner.x,
                    y,
                    " "^(mx - inner.x + 1),
                    with_selection(tstyle(:text), true),
                )
            end

            if i == 1
                x = set_string!(
                    buf,
                    inner.x,
                    y,
                    "⬑ ",
                    with_selection(tstyle(:text_dim), selected);
                    max_x = mx,
                )
                x = set_string!(
                    buf,
                    x,
                    y,
                    fr.label,
                    with_selection(tstyle(:secondary; bold = true), selected);
                    max_x = mx,
                )
                set_string!(
                    buf,
                    x,
                    y,
                    "::" * fr.rt_str,
                    with_selection(fr.rt_style, selected);
                    max_x = mx,
                )
            else
                render_inspect_entry!(buf, inner.x, y, fr.entries[i - 1], selected, mx)
            end
        end

        if isempty(fr.entries)
            msg = "No call sites"
            pos = center(inner, min(length(msg), inner.width), 1)
            set_string!(buf, pos.x, pos.y, msg, tstyle(:text_dim; italic = true))
        end

        if need_sb
            track, thumb = scrollbar_styles(focused)
            sb = Scrollbar(n, inner.height, fr.scroll; style = track, thumb_style = thumb)
            render(sb, Rect(right(inner), inner.y, 1, inner.height), buf)
        end
    end

    # == Top Pane: Annotated Source or Typed IR ============================================

    if (rows[1].width > 2) && (rows[1].height > 2)
        focused = st.focus === :code
        title = fr.view === :source ? " [1] Annotated Source " : " [1] Typed IR "
        block = Block(;
            title = title,
            border_style = tstyle(focused ? :border_focus : :border),
            title_style = tstyle(:title; bold = focused),
            box = BOX_ROUNDED,
        )
        inner = render(block, rows[1], buf)
        st.code_h = max(inner.height, 1)
        st.code_rect = inner

        lines = inspect_code_lines(fr)

        if isempty(lines)
            msg = something(fr.src_error, "No code available")
            pos = center(inner, min(length(msg), inner.width), 1)
            set_string!(buf, pos.x, pos.y, msg, tstyle(:text_dim; italic = true))
            return nothing
        end

        fr.code_scroll = clamp(fr.code_scroll, 0, max(0, length(lines) - inner.height))

        entry = selected_entry(fr)
        target =
            ((entry !== nothing) && (fr.view === :source)) ?
            entry.line - fr.start_line + 1 : 0

        gutter_w =
            fr.view === :source ? length(string(fr.start_line + length(lines) - 1)) + 1 : 0

        mx = right(inner) - 1
        text_x = inner.x + gutter_w + (fr.view === :source ? 3 : 1)
        st.code_w = max(mx - text_x + 1, 1)

        for (i, y) in zip((fr.code_scroll + 1):length(lines), inner.y:bottom(inner))
            is_target = i == target
            x = inner.x

            if is_target
                set_string!(
                    buf,
                    inner.x,
                    y,
                    " "^(mx - inner.x + 1),
                    with_selection(tstyle(:text), true),
                )
            end

            if fr.view === :source
                num_style = is_target ? tstyle(:accent; bold = true) : tstyle(:text_dim)
                x = set_string!(
                    buf,
                    x,
                    y,
                    lpad(string(fr.start_line + i - 1), gutter_w),
                    with_selection(num_style, is_target);
                    max_x = mx,
                )
                x = set_string!(
                    buf,
                    x,
                    y,
                    is_target ? " ▶ " : "   ",
                    with_selection(tstyle(:accent; bold = true), is_target);
                    max_x = mx,
                )
            else
                x += 1
            end

            spans =
                is_target ?
                Span[Span(s.content, with_selection(s.style, true)) for s in lines[i]] :
                lines[i]
            set_spans_hclipped!(buf, x, y, spans, fr.code_hscroll, mx)
        end

        if length(lines) > inner.height
            track, thumb = scrollbar_styles(focused)
            sb = Scrollbar(
                length(lines),
                inner.height,
                fr.code_scroll;
                style = track,
                thumb_style = thumb,
            )
            render(sb, Rect(right(inner), inner.y, 1, inner.height), buf)
        end
    end

    return nothing
end
