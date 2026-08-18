## Description #############################################################################
#
# Application model and keyboard handling.
#
############################################################################################

"""
    struct CompileStats

Store the wall-clock compilation measurements taken while an expression was profiled.

# Fields

- `elapsed::Float64`: Total run time [s] of the profiled expression.
- `compile::Float64`: Time [s] spent compiling, including recompilation.
- `recompile::Float64`: Time [s] spent recompiling previously compiled code.
"""
struct CompileStats
    elapsed::Float64
    compile::Float64
    recompile::Float64
end

"""
    ZOOM_MAX

Number of zoom steps of the focused panel: `+` and `-` move the split one step at a time
from `0` (default split) to `ZOOM_MAX` (maximized, hiding the other panel).
"""
const ZOOM_MAX = 3

"""
    mutable struct ProfileViewer <: Model

Store the state of the interactive profile viewer application.

# Fields

- `root::PVNode`: Root of the profile tree.
- `current::PVNode`: Node whose children are listed by the frame list.
- `rows::Vector{PVNode}`: Cache of the frame list rows: `current` as the pinned parent
    row followed by its children. Do not modify directly; it is rebuilt by
    [`set_current!`](@ref).
- `cursor::Int`: Index of the row under the cursor (1-based).
- `scroll::Int`: Scroll offset [rows] of the frame list (0-based).
- `visible_h::Int`: Height [rows] of the scrollable pane, written during rendering and
    used by the paging keys.
- `mode::Symbol`: Active view, either `:tree` or `:inspect`.
- `nsamples::Int`: Total number of profile samples.
- `delay::Float64`: Sampling delay [s] used to estimate wall-clock times.
- `total_nodes::Int`: Total number of nodes in the profile tree.
- `detail::DetailState`: State of the source panel that follows the selected row.
- `help::Bool`: Whether the help dialog is open.
- `quit::Bool`: Whether the application must terminate.
- `unit::Symbol`: Unit of the node counts, either `:samples` or `:time` [ns].
- `compile::Union{CompileStats, Nothing}`: Compilation measurements of the profiled
    expression, or `nothing` when they are not available.
- `inference_samples::Int`: Number of samples spent in type inference, or `0` when the
    unit is not `:samples`.
- `inspect::InspectState`: State of the type-instability inspector.
- `line_costs::Dict{Tuple{Symbol, Int}, Tuple{Int, Int}}`: Bytes and allocation counts
    charged to each `(file, line)` — per file, the innermost frame of each allocation —
    filled by the allocation viewer and used by the per-line column of the detail view.
    Empty for the other viewers.
- `notice::String`: Transient message shown in the status bar until the next key press,
    or an empty string.
- `tasks::Any`: `Tachikoma.TaskQueue` draining background tasks (e.g. the on-demand
    Cthulhu load) into [`update!`](@ref) as `TaskEvent`s, or `nothing` before the model
    is assembled.
- `wake::Base.RefValue{Any}`: Wake-up function provided by the application loop, used by
    completed background tasks to trigger a redraw, or `nothing` outside the loop.
- `tree_focus::Symbol`: Panel of the main view receiving the scroll keys, either `:list`
    or `:code`.
- `zoom::Int`: Zoom step of the active view, from `0` (default split) to
    [`ZOOM_MAX`](@ref) (maximized, hiding the other panel).
- `zoom_panel::Symbol`: Panel the zoom favors, anchored when a zoom step is applied and
    unaffected by later focus changes. In the maximized mode, the fullscreen panel
    follows the focus instead (see [`zoom!`](@ref)).
- `list_rows_rect::Rect`: Screen area of the frame list rows, written during rendering
    and used by the mouse handling. It is empty while the panel is not shown.
- `code_rect::Rect`: Screen area of the source panel, written during rendering and used
    by the mouse handling. It is empty while the panel is not shown.
"""
mutable struct ProfileViewer <: Model
    root::PVNode
    current::PVNode
    rows::Vector{PVNode}
    cursor::Int
    scroll::Int
    visible_h::Int
    mode::Symbol
    nsamples::Int
    delay::Float64
    total_nodes::Int
    detail::DetailState
    help::Bool
    quit::Bool
    unit::Symbol
    compile::Union{CompileStats, Nothing}
    inference_samples::Int
    inspect::InspectState
    line_costs::Dict{Tuple{Symbol, Int}, Tuple{Int, Int}}
    notice::String
    tasks::Any
    wake::Base.RefValue{Any}
    tree_focus::Symbol
    zoom::Int
    zoom_panel::Symbol
    list_rows_rect::Rect
    code_rect::Rect
end

"""
    ProfileViewer(g; compile::Union{CompileStats, Nothing} = nothing) -> ProfileViewer

Create the viewer model from the FlameGraphs tree rooted at `g`, listing the first
branching level of the tree — past the REPL and script evaluation machinery — and
placing the cursor on the most expensive child.

# Keywords

- `compile::Union{CompileStats, Nothing}`: Compilation measurements of the profiled
    expression, shown in the header when available.
    (**Default**: `nothing`)
"""
function ProfileViewer(g; compile::Union{CompileStats, Nothing} = nothing)
    root = build_tree(g)
    _, delay = Profile.init()
    return _viewer(root, :samples, delay, compile, inference_samples(root))
end

"""
    inference_viewer(tinf) -> ProfileViewer

Create the viewer model from the inference timing tree `tinf` returned by
`SnoopCompileCore.@snoop_inference`, with node counts in inference time [ns].
"""
function inference_viewer(tinf)
    root = build_inference_tree(tinf)
    return _viewer(root, :time, 0.0, nothing, 0)
end

"""
    _viewer(
        root::PVNode,
        unit::Symbol,
        delay::Float64,
        compile::Union{CompileStats, Nothing},
        inference::Int
    ) -> ProfileViewer

Assemble the viewer model for the tree rooted at `root` with counts in `unit`. The frame
list starts at the first branching level (see [`hot_entry`](@ref)), past the REPL and
script evaluation machinery.
"""
function _viewer(
    root::PVNode,
    unit::Symbol,
    delay::Float64,
    compile::Union{CompileStats, Nothing},
    inference::Int
)
    current = hot_entry(root)
    rows = level_rows(current)

    m = ProfileViewer(
        root,
        current,
        rows,
        min(2, length(rows)),
        0,
        1,
        :tree,
        root.count,
        delay,
        count_nodes(root),
        DetailState(),
        false,
        false,
        unit,
        compile,
        inference,
        InspectState(),
        Dict{Tuple{Symbol, Int}, Tuple{Int, Int}}(),
        "",
        nothing,
        Base.RefValue{Any}(nothing),
        :list,
        0,
        :list,
        Rect(),
        Rect()
    )

    m.tasks = Tachikoma.TaskQueue(;
        on_ready = () -> begin
            w = m.wake[]
            (w === nothing) || w()
            nothing
        end
    )

    return m
end

should_quit(m::ProfileViewer) = m.quit

"""
    task_queue(m::ProfileViewer) -> Tachikoma.TaskQueue

Return the background task queue of the model, drained by the application loop.
"""
task_queue(m::ProfileViewer) = m.tasks

"""
    set_wake!(m::ProfileViewer, notify::Function) -> Nothing

Store the wake-up function of the application loop, used by completed background tasks
to trigger a redraw.
"""
function set_wake!(m::ProfileViewer, notify::Function)
    m.wake[] = notify
    return nothing
end

"""
    update!(m::ProfileViewer, evt::Tachikoma.TaskEvent) -> Nothing

Process the completion of a background task. Currently the only task is the on-demand
load of the Cthulhu inspector backend: on success, the inspector opens on the method
instance that requested it; on failure, a status notice is shown.
"""
function update!(m::ProfileViewer, evt::Tachikoma.TaskEvent)
    (evt.id === :inspector_loaded) || return nothing

    st = m.inspect
    st.loading = false
    pending = st.pending_mi
    st.pending_mi = nothing

    if evt.value !== true
        m.notice = "The type inspector requires Cthulhu, which could not be loaded."
        return nothing
    end

    m.notice = ""
    (pending !== nothing) && Base.invokelatest(_enter_inspect_impl!, m, pending)
    return nothing
end

"""
    selected_row(m::ProfileViewer) -> Union{PVNode, Nothing}

Return the node under the cursor, or `nothing` when the row list is empty.
"""
function selected_row(m::ProfileViewer)
    isempty(m.rows) && return nothing
    return m.rows[clamp(m.cursor, 1, length(m.rows))]
end

"""
    is_parent_row(m::ProfileViewer, node::PVNode) -> Bool

Return `true` if `node` is the pinned parent row of the frame list, i.e., the current
node itself.
"""
is_parent_row(m::ProfileViewer, node::PVNode) = node === m.current

"""
    _clamped_scroll(scroll::Int, cursor::Int, h::Int, n::Int) -> Int

Return `scroll` clamped so that the 1-based `cursor` row stays inside a visible pane of
`h` rows scrolling over a list of `n` rows.
"""
function _clamped_scroll(scroll::Int, cursor::Int, h::Int, n::Int)
    scroll = clamp(scroll, cursor - h, cursor - 1)
    return clamp(scroll, 0, max(0, n - h))
end

"""
    clamp_scroll!(m::ProfileViewer) -> Nothing

Mutate `m.scroll` so that the cursor row stays inside the visible pane.
"""
function clamp_scroll!(m::ProfileViewer)
    m.scroll = _clamped_scroll(m.scroll, m.cursor, max(m.visible_h, 1), length(m.rows))
    return nothing
end

"""
    move_cursor!(m::ProfileViewer, delta::Int) -> Nothing

Mutate `m.cursor` by `delta` rows, clamping to the row list and keeping the cursor
visible.
"""
function move_cursor!(m::ProfileViewer, delta::Int)
    isempty(m.rows) && return nothing
    m.cursor = clamp(m.cursor + delta, 1, length(m.rows))
    clamp_scroll!(m)
    return nothing
end

"""
    set_current!(
        m::ProfileViewer,
        node::PVNode,
        cursor_on::Union{PVNode, Nothing}
    ) -> Nothing

Make `node` the current node of the frame list, mutating `m.current`, `m.rows`,
`m.cursor`, and `m.scroll`. The cursor is placed on `cursor_on` when it is one of the new
rows, and on the first child (or the parent row for a leaf) otherwise.
"""
function set_current!(m::ProfileViewer, node::PVNode, cursor_on::Union{PVNode, Nothing})
    m.current = node
    m.rows = level_rows(node)

    idx = cursor_on === nothing ? nothing : findfirst(n -> n === cursor_on, m.rows)
    m.cursor = idx === nothing ? min(2, length(m.rows)) : idx

    m.scroll = 0
    clamp_scroll!(m)
    return nothing
end

"""
    descend!(m::ProfileViewer) -> Nothing

Enter the node under the cursor: go up when the cursor is on the pinned parent row, open
the detail view when the node is a leaf, and list the node's children otherwise,
auto-descending through single-child chains until the first branching point. Mutate the
navigation state of `m` accordingly.
"""
function descend!(m::ProfileViewer)
    node = selected_row(m)
    node === nothing && return nothing

    if is_parent_row(m, node)
        ascend!(m)
    elseif isempty(node.children)
        m.tree_focus = :code
    else
        while (length(node.children) == 1) && !isempty(node.children[1].children)
            node = node.children[1]
        end

        set_current!(m, node, nothing)
    end

    return nothing
end

"""
    ascend!(m::ProfileViewer) -> Nothing

Go back to the closest ancestor of the current node that is a branching point, placing
the cursor on the node the user came from and mutating the navigation state of `m`. This
inverts the auto-descent of [`descend!`](@ref) in one keypress. Do nothing when the
current node is the tree root.
"""
function ascend!(m::ProfileViewer)
    prev = m.current
    node = prev.parent
    node === nothing && return nothing

    while (node.parent !== nothing) && (length(node.children) == 1)
        prev = node
        node = node.parent
    end

    set_current!(m, node, prev)
    return nothing
end

"""
    update!(m::ProfileViewer, evt::KeyEvent) -> Nothing

Process the keyboard event `evt`, mutating the model `m` according to the active view
(help dialog, frame list, or detail).
"""
function update!(m::ProfileViewer, evt::KeyEvent)
    is_char(c::Char) = (evt.key == :char) && (evt.char == c)

    # Status notices live until the next key press, except while a background load is
    # in flight, whose notice stays until the load finishes.
    m.inspect.loading || (m.notice = "")

    # == Help Dialog =======================================================================

    if m.help
        if (evt.key == :escape) || is_char('?') || is_char('q')
            m.help = false
        end

        return nothing
    end

    # == Global Keys =======================================================================

    if is_char('?')
        m.help = true
        return nothing
    end

    m.mode == :tree ? _update_tree!(m, evt) : _update_inspect!(m, evt)
    return nothing
end

"""
    inspect_selected!(m::ProfileViewer) -> Nothing

Open the type-instability inspector on the node under the cursor, when its frame carries
a method instance. Otherwise, set a status notice explaining why the row cannot be
inspected: the inspector needs a `MethodInstance` as its entry point, which C frames,
inlined frames, aggregate rows, and synthetic rows (allocated types, invalidation
triggers) do not have.
"""
function inspect_selected!(m::ProfileViewer)
    node = selected_row(m)
    node === nothing && return nothing

    linfo = node.sf.linfo

    if linfo isa Core.MethodInstance
        enter_inspect!(m, linfo)
    elseif is_tree_root(node)
        m.notice = "Aggregate rows cannot be type-inspected."
    elseif node.sf.from_c
        m.notice = "C frames cannot be type-inspected."
    elseif node.sf.inlined
        m.notice = "Inlined frame without a method instance — inspect a parent frame."
    else
        m.notice = "This row carries no method instance to inspect."
    end

    return nothing
end

"""
    zoom!(m::ProfileViewer, focus::Symbol, other::Symbol, delta::Int) -> Nothing

Apply one zoom step to the panel `focus` of the active view, growing it when `delta` is
`+1` and shrinking it when `delta` is `-1`, mutating `m.zoom` and `m.zoom_panel`. The
split stays anchored to `m.zoom_panel` afterwards, so later focus changes do not move
it: stepping from the default split anchors the zoom on the panel the step favors
(`focus` when growing, `other` when shrinking), and stepping against the anchored panel
walks the split back toward the default, re-anchoring once it is crossed. Shrinking the
focused panel stops at its minimum size: the maximized mode is only reachable by growing
the focused panel itself. In the maximized mode, the fullscreen panel follows the focus,
so the zoom re-anchors on `focus` before stepping.
"""
function zoom!(m::ProfileViewer, focus::Symbol, other::Symbol, delta::Int)
    (m.zoom == ZOOM_MAX) && (m.zoom_panel = focus)

    if m.zoom == 0
        m.zoom_panel = delta > 0 ? focus : other
        m.zoom = 1
    else
        limit = focus === m.zoom_panel ? ZOOM_MAX : ZOOM_MAX - 1
        m.zoom = clamp(m.zoom + (focus === m.zoom_panel ? delta : -delta), 0, limit)
    end

    return nothing
end

"""
    _update_tree!(m::ProfileViewer, evt::KeyEvent) -> Nothing

Process the keyboard event `evt` for the main view, mutating the model `m`. The panel
focused with the Tab or number keys receives the movement keys: the frame list navigates
the tree, and the source panel scrolls the code. `+` and `-` grow and shrink the focused
panel one step at a time, up to maximizing it (see [`zoom!`](@ref)), and Esc restores
the default split.
"""
function _update_tree!(m::ProfileViewer, evt::KeyEvent)
    is_char(c::Char) = (evt.key == :char) && (evt.char == c)
    is_ctrl(c::Char) = (evt.key == :ctrl) && (evt.char == c)
    d = m.detail
    on_list = m.tree_focus === :list

    if (evt.key == :tab) || (evt.key == :backtab)
        m.tree_focus = on_list ? :code : :list

    elseif is_char('1')
        m.tree_focus = :list

    elseif is_char('2')
        m.tree_focus = :code

    elseif is_char('+')
        zoom!(m, m.tree_focus, on_list ? :code : :list, +1)

    elseif is_char('-')
        zoom!(m, m.tree_focus, on_list ? :code : :list, -1)

    elseif evt.key == :escape
        m.zoom = 0

    elseif is_char('i')
        inspect_selected!(m)

    elseif is_char('u')
        toggle_alloc_unit!(m)

    elseif is_char('q')
        m.quit = true

    elseif on_list
        page = max(1, m.visible_h - 1)

        if (evt.key == :up) || is_char('k')
            move_cursor!(m, -1)
        elseif (evt.key == :down) || is_char('j')
            move_cursor!(m, +1)
        elseif evt.key == :pageup
            move_cursor!(m, -page)
        elseif evt.key == :pagedown
            move_cursor!(m, +page)
        elseif (evt.key == :home) || is_char('g')
            move_cursor!(m, -length(m.rows))
        elseif (evt.key == :end_key) || is_char('G')
            move_cursor!(m, +length(m.rows))
        elseif (evt.key == :enter) || (evt.key == :right) || is_char('l')
            descend!(m)
        elseif (evt.key == :backspace) || (evt.key == :left) || is_char('h')
            ascend!(m)
        end
    else
        h = max(d.src_h, 1)
        page = max(1, h - 1)
        half = max(1, h ÷ 2)

        if (evt.key == :up) || is_char('k')
            detail_scroll!(d, -1, 0)
        elseif (evt.key == :down) || is_char('j')
            detail_scroll!(d, +1, 0)
        elseif (evt.key == :left) || is_char('h')
            detail_scroll!(d, 0, -4)
        elseif (evt.key == :right) || is_char('l')
            detail_scroll!(d, 0, +4)
        elseif evt.key == :pageup
            detail_scroll!(d, -page, 0)
        elseif evt.key == :pagedown
            detail_scroll!(d, +page, 0)
        elseif is_ctrl('u')
            detail_scroll!(d, -half, 0)
        elseif is_ctrl('d')
            detail_scroll!(d, +half, 0)
        elseif (evt.key == :home) || is_char('g')
            detail_vset!(d, 0)
        elseif (evt.key == :end_key) || is_char('G')
            detail_vset!(d, typemax(Int) ÷ 2)
        elseif is_char('0')
            detail_hset!(d, 0)
        elseif is_char('$')
            detail_hset!(d, typemax(Int) ÷ 2)
        elseif (evt.key == :enter) || (evt.key == :backspace)
            m.tree_focus = :list
        end
    end

    return nothing
end

"""
    toggle_alloc_unit!(m::ProfileViewer) -> Nothing

Toggle the cost unit of the allocation viewer between allocated bytes and allocation
counts, re-ranking the whole tree by the new unit and keeping the cursor on the selected
node. Do nothing when `m` is not an allocation viewer.
"""
function toggle_alloc_unit!(m::ProfileViewer)
    ((m.unit === :bytes) || (m.unit === :allocs)) || return nothing

    selected = selected_row(m)
    swap_alloc_unit!(m.root)
    _fill_alloc_self!(m.root)
    _finalize_percentages!(m.root, m.root.count)

    m.unit = m.unit === :bytes ? :allocs : :bytes
    m.nsamples = m.root.count
    set_current!(m, m.current, selected)
    return nothing
end

"""
    _update_inspect!(m::ProfileViewer, evt::KeyEvent) -> Nothing

Process the keyboard event `evt` for the type-instability inspector, mutating the model
`m`. The scroll keys act on the pane selected with the Tab key.
"""
function _update_inspect!(m::ProfileViewer, evt::KeyEvent)
    st = m.inspect
    is_char(c::Char) = (evt.key == :char) && (evt.char == c)

    on_calls = st.focus === :calls
    h = max(on_calls ? st.calls_h : st.code_h, 1)
    page = max(1, h - 1)

    move!(delta) = on_calls ? inspect_move!(m, delta) : inspect_scroll_code!(m, delta, 0)

    if (evt.key == :escape) || is_char('q')
        exit_inspect!(m)

    elseif (evt.key == :tab) || (evt.key == :backtab)
        st.focus = on_calls ? :code : :calls

    elseif is_char('1')
        st.focus = :code

    elseif is_char('2')
        st.focus = :calls

    elseif is_char('+')
        zoom!(m, st.focus, on_calls ? :code : :calls, +1)

    elseif is_char('-')
        zoom!(m, st.focus, on_calls ? :code : :calls, -1)

    elseif (evt.key == :up) || is_char('k')
        move!(-1)

    elseif (evt.key == :down) || is_char('j')
        move!(+1)

    elseif (evt.key == :left) || is_char('h')
        on_calls ? inspect_ascend!(m) : inspect_scroll_code!(m, 0, -4)

    elseif (evt.key == :right) || is_char('l')
        on_calls ? inspect_descend!(m) : inspect_scroll_code!(m, 0, +4)

    elseif evt.key == :enter
        on_calls ? inspect_descend!(m) : nothing

    elseif evt.key == :backspace
        inspect_ascend!(m)

    elseif evt.key == :pageup
        move!(-page)

    elseif evt.key == :pagedown
        move!(+page)

    elseif (evt.key == :home) || is_char('g')
        move!(-typemax(Int) ÷ 2)

    elseif (evt.key == :end_key) || is_char('G')
        move!(+typemax(Int) ÷ 2)

    elseif is_char('t')
        inspect_toggle_view!(m)
    end

    return nothing
end

############################################################################################
#                                      Mouse Handling                                      #
############################################################################################

"""
    _rect_contains(r::Rect, x::Int, y::Int) -> Bool

Return `true` if the screen cell `(x, y)` lies inside the rectangle `r`.
"""
_rect_contains(r::Rect, x::Int, y::Int) =
    (r.width > 0) && (r.height > 0) && (r.x <= x <= right(r)) && (r.y <= y <= bottom(r))

"""
    _wheel_delta(evt::MouseEvent) -> Int

Return the vertical scroll direction of the mouse event `evt`: `-1` for wheel up, `+1`
for wheel down, and `0` for any other event.
"""
function _wheel_delta(evt::MouseEvent)
    (evt.button == mouse_scroll_up) && return -1
    (evt.button == mouse_scroll_down) && return +1
    return 0
end

"""
    update!(m::ProfileViewer, evt::MouseEvent) -> Nothing

Process the mouse event `evt`, mutating the model `m`. The wheel scrolls the panel under
the cursor — moving the selection in the lists and the view in the code panes — and a
left click focuses the clicked panel, moving the selection to the clicked row; clicking
the selected row again enters it. A click closes the help dialog when it is open. All
the other mouse events are ignored.
"""
function update!(m::ProfileViewer, evt::MouseEvent)
    wheel = _wheel_delta(evt)
    press = (evt.button == mouse_left) && (evt.action == mouse_press)
    (press || (wheel != 0)) || return nothing

    m.inspect.loading || (m.notice = "")

    if m.help
        press && (m.help = false)
        return nothing
    end

    if m.mode == :tree
        _mouse_tree!(m, evt, press, wheel)
    else
        _mouse_inspect!(m, evt, press, wheel)
    end

    return nothing
end

"""
    _mouse_tree!(m::ProfileViewer, evt::MouseEvent, press::Bool, wheel::Int) -> Nothing

Process the mouse event `evt` for the main view, mutating the model `m`. `press` tells
whether the event is a left press and `wheel` carries the vertical scroll direction (see
[`update!`](@ref)).
"""
function _mouse_tree!(m::ProfileViewer, evt::MouseEvent, press::Bool, wheel::Int)
    if _rect_contains(m.list_rows_rect, evt.x, evt.y)
        m.tree_focus = :list

        if wheel != 0
            move_cursor!(m, wheel)
        elseif press
            row = m.scroll + (evt.y - m.list_rows_rect.y) + 1

            if 1 <= row <= length(m.rows)
                (row == m.cursor) ? descend!(m) : move_cursor!(m, row - m.cursor)
            end
        end
    elseif _rect_contains(m.code_rect, evt.x, evt.y)
        m.tree_focus = :code
        (wheel != 0) && detail_scroll!(m.detail, 3 * wheel, 0)
    end

    return nothing
end

"""
    _mouse_inspect!(m::ProfileViewer, evt::MouseEvent, press::Bool, wheel::Int) -> Nothing

Process the mouse event `evt` for the type-instability inspector, mutating the model
`m`. `press` tells whether the event is a left press and `wheel` carries the vertical
scroll direction (see [`update!`](@ref)).
"""
function _mouse_inspect!(m::ProfileViewer, evt::MouseEvent, press::Bool, wheel::Int)
    st = m.inspect

    if _rect_contains(st.calls_rect, evt.x, evt.y)
        st.focus = :calls

        if wheel != 0
            inspect_move!(m, wheel)
        elseif press
            fr = inspect_top(st)
            fr === nothing && return nothing
            row = fr.scroll + (evt.y - st.calls_rect.y) + 1

            if 1 <= row <= length(fr.entries) + 1
                (row == fr.cursor) ? inspect_descend!(m) :
                    inspect_move!(m, row - fr.cursor)
            end
        end
    elseif _rect_contains(st.code_rect, evt.x, evt.y)
        st.focus = :code
        (wheel != 0) && inspect_scroll_code!(m, 3 * wheel, 0)
    end

    return nothing
end

