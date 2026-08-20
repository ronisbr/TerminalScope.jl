## Description #############################################################################
#
# Flame-graph panel rendered with the terminal graphics protocols (Kitty graphics or
# Sixel) through Tachikoma's PixelImage widget.
#
############################################################################################

"""
    FLAME_PATH

Span flag: the node lies on the path from the tree root to the current node.
"""
const FLAME_PATH = 0x01

"""
    FLAME_SUBTREE

Span flag: the node belongs to the subtree rooted at the current node (inclusive).
"""
const FLAME_SUBTREE = 0x02

"""
    _FLAME_BAND_MIN

Minimum height [px] of one depth level of the flame graph.
"""
const _FLAME_BAND_MIN = 4

"""
    _FLAME_BAND_MAX

Maximum height [px] of one depth level of the flame graph.
"""
const _FLAME_BAND_MAX = 18

"""
    _FLAME_RAMP_DARK

Heat ramp control colors (sand, amber, brick) of the dark theme variant. The ramp is
deliberately desaturated: the widest rectangles are always the hottest ones, so a
saturated hot end would dominate the panel.
"""
const _FLAME_RAMP_DARK = (
    ColorRGB(0xD6, 0xBE, 0x6E), ColorRGB(0xC9, 0x8A, 0x52), ColorRGB(0xB0, 0x55, 0x4A)
)

"""
    _FLAME_RAMP_LIGHT

Heat ramp control colors (sand, amber, brick) of the light theme variant, darkened for
legibility on the white surface (see [`_FLAME_RAMP_DARK`](@ref)).
"""
const _FLAME_RAMP_LIGHT = (
    ColorRGB(0xC2, 0x9A, 0x3A), ColorRGB(0xB0, 0x6A, 0x38), ColorRGB(0x9E, 0x4A, 0x40)
)

"""
    struct FlameSpan

Represent the horizontal extent of one node in one depth level of the flame graph.

# Fields

- `x0::Float64`: Start of the span as a fraction of the drawable width, in `[0, 1)`.
- `x1::Float64`: End of the span (exclusive) as a fraction of the drawable width.
- `node::PVNode`: Node the span represents.
- `flags::UInt8`: Emphasis flags, a combination of [`FLAME_PATH`](@ref) and
    [`FLAME_SUBTREE`](@ref).
"""
struct FlameSpan
    x0::Float64
    x1::Float64
    node::PVNode
    flags::UInt8
end

"""
    mutable struct FlameState

Store the state of the flame-graph panel shown at the bottom of the main view.

# Fields

- `visible::Bool`: Whether the panel is enabled (toggled with the `f` key). The panel
    also requires a terminal graphics protocol to render (see [`flame_active`](@ref)).
- `img::Union{PixelImage, Nothing}`: Cached pixel buffer, recreated when the panel size
    changes.
- `rect::Rect`: Screen area of the panel interior, written during rendering and used by
    the mouse handling. It is empty while the panel is not shown.
- `levels::Vector{Vector{FlameSpan}}`: Node spans per drawn depth level, where level `1`
    is the tree root, written by the painter and read by the mouse hit-test.
- `row_level::Vector{Int}`: Depth level under each cell row of the panel interior
    (1-based), or `0` for margin and gap rows.
- `margin::Int`: Left and right pixel margin of the drawing.
- `draw_w::Int`: Drawable width [px] of the flame graph.
- `truncated::Bool`: Whether the tree is deeper than the drawn levels.
- `sig::UInt64`: Signature of the last painted state (see [`_flame_sig`](@ref)), or `0`
    to force a repaint.
"""
mutable struct FlameState
    visible::Bool
    img::Union{PixelImage, Nothing}
    rect::Rect
    levels::Vector{Vector{FlameSpan}}
    row_level::Vector{Int}
    margin::Int
    draw_w::Int
    truncated::Bool
    sig::UInt64
end

"""
    FlameState() -> FlameState

Create an empty `FlameState` with the panel enabled and no cached image.
"""
function FlameState()
    return FlameState(
        true, nothing, Rect(), Vector{FlameSpan}[], Int[], 1, 0, false, UInt64(0)
    )
end

"""
    flame_available(m) -> Bool

Return `true` if the viewer `m` supports the flame-graph panel: the terminal must
provide a graphics protocol (Kitty graphics or Sixel) and the viewer must show a cost
tree (the invalidations viewer has no flame graph).
"""
flame_available(m) = (m.unit !== :invalidations) && (graphics_protocol() !== gfx_none)

"""
    flame_active(m) -> Bool

Return `true` if the flame-graph panel of the viewer `m` must be rendered: it is
available (see [`flame_available`](@ref)) and not hidden by the `f` toggle.
"""
flame_active(m) = m.flame.visible && flame_available(m)

"""
    _flame_selected(m) -> Union{PVNode, Nothing}

Return the tree node highlighted by the flame graph: the node under the cursor, or, in
the flat self-time view, the hottest tree occurrence of the selected flat row.
"""
function _flame_selected(m)
    if m.flat
        isempty(m.flat_targets) && return nothing
        return m.flat_targets[clamp(m.cursor, 1, length(m.flat_targets))]
    end

    return selected_row(m)
end

"""
    toggle_flame!(m) -> Nothing

Toggle the visibility of the flame-graph panel of the viewer `m`. When the panel is not
available, set a status notice explaining why instead.
"""
function toggle_flame!(m)
    if m.unit === :invalidations
        m.notice = "The invalidations viewer has no flame graph."
    elseif graphics_protocol() === gfx_none
        m.notice = "The flame graph requires Kitty or Sixel terminal graphics."
    else
        m.flame.visible = !m.flame.visible
    end

    return nothing
end

"""
    _flame_path_set(current::PVNode) -> Set{UInt64}

Return the `objectid`s of `current` and all its ancestors, used to flag the spans on the
root-to-current path.
"""
function _flame_path_set(current::PVNode)
    path = Set{UInt64}()
    node = current

    while node !== nothing
        push!(path, objectid(node))
        node = node.parent
    end

    return path
end

"""
    _flame_levels(
        root::PVNode,
        current::PVNode,
        draw_w::Int,
        max_levels::Int
    ) -> Vector{Vector{FlameSpan}}

Compute the flame-graph span layout of the tree rooted at `root`: one span vector per
depth level (level `1` is `root`), down to `max_levels` levels. Children are packed
left-aligned in their stored (cost-sorted) order with cumulative offsets, and a child
narrower than one pixel of the `draw_w` drawable width is culled with its subtree while
still advancing the offset. The right-hand remainder of each span is the node's self
cost and stays unfilled. The spans carry the emphasis flags relative to `current` (see
[`FlameSpan`](@ref)).
"""
function _flame_levels(root::PVNode, current::PVNode, draw_w::Int, max_levels::Int)
    levels = [FlameSpan[] for _ in 1:max_levels]
    total = max(root.count, 1)
    min_frac = 1 / max(draw_w, 1)
    path = _flame_path_set(current)

    function visit(node::PVNode, x0::Float64, x1::Float64, level::Int, in_subtree::Bool)
        in_subtree |= node === current

        flags = UInt8(0)
        (objectid(node) in path) && (flags |= FLAME_PATH)
        in_subtree && (flags |= FLAME_SUBTREE)

        push!(levels[level], FlameSpan(x0, x1, node, flags))
        (level == max_levels) && return nothing

        acc = x0

        for c in node.children
            w = c.count / total
            (w >= min_frac) && visit(c, acc, acc + w, level + 1, in_subtree)
            acc += w
        end

        return nothing
    end

    visit(root, 0.0, 1.0, 1, false)
    return levels
end

"""
    _flame_depth(root::PVNode, draw_w::Int) -> Int

Return the deepest level of the tree rooted at `root` whose span survives the
minimum-width culling of a `draw_w` drawable width (see [`_flame_levels`](@ref)).
"""
function _flame_depth(root::PVNode, draw_w::Int)
    total = max(root.count, 1)
    min_frac = 1 / max(draw_w, 1)

    function depth(node::PVNode, level::Int)
        d = level

        for c in node.children
            (c.count / total >= min_frac) && (d = max(d, depth(c, level + 1)))
        end

        return d
    end

    return depth(root, 1)
end

"""
    _flame_heat(pct_total::Float64, light::Bool) -> ColorRGB

Return the heat color of a frame taking `pct_total` [%] of the total cost, interpolated
on a muted sand-amber-brick ramp with a square-root easing so cheap frames stay
distinguishable. `light` selects the theme variant of the ramp.
"""
function _flame_heat(pct_total::Float64, light::Bool)
    t = sqrt(clamp(pct_total / 100, 0.0, 1.0))
    y, o, r = light ? _FLAME_RAMP_LIGHT : _FLAME_RAMP_DARK
    return t < 0.5 ? color_lerp(y, o, 2t) : color_lerp(o, r, 2t - 1)
end

"""
    _flame_sig(m) -> UInt64

Return the signature of the state the flame graph depends on: the current node, the
highlighted node, the flat view mode, the cost unit, the light mode, and the pixel
dimensions of the cached image. The panel is repainted only when the signature changes.
"""
function _flame_sig(m)
    img = m.flame.img
    sel = _flame_selected(m)

    return hash((
        objectid(m.current),
        sel === nothing ? UInt64(0) : objectid(sel),
        m.flat,
        m.unit,
        light_mode(),
        img.pixel_w,
        img.pixel_h,
    ))
end

"""
    _paint_flame!(m) -> Nothing

Repaint the flame graph into the cached pixel buffer of the viewer `m`, mutating
`m.flame`: the whole tree is drawn from the root at the bottom with the stacks growing
upward, each frame heat-colored by its share of the total cost (see
[`_flame_heat`](@ref)). The root-to-current path and the subtree of the current node
are drawn at full heat, the remaining frames dimmed toward the background, and the
highlighted node (see
[`_flame_selected`](@ref)) filled with the theme primary color. When the tree is deeper
than the panel fits, a dashed strip along the top edge signals the truncation.
"""
function _paint_flame!(m)
    st = m.flame
    img = st.img
    pw = img.pixel_w
    ph = img.pixel_h

    set_background!(img, to_rgba(to_rgb(theme().bg)))
    clear!(img)

    margin = 1
    draw_w = max(pw - 2 * margin, 1)
    avail_h = max(ph - 2 * margin, 1)

    # == Depth Capacity ====================================================================

    tree_depth = _flame_depth(m.root, draw_w)
    truncated = tree_depth > max(avail_h ÷ _FLAME_BAND_MIN, 1)

    # When truncated, the top 2 pixel rows plus a 1 px gap hold the "more levels" strip.
    draw_h = max(avail_h - (truncated ? 3 : 0), _FLAME_BAND_MIN)
    n_levels = clamp(draw_h ÷ _FLAME_BAND_MIN, 1, tree_depth)
    band_h = clamp(draw_h ÷ n_levels, _FLAME_BAND_MIN, _FLAME_BAND_MAX)
    v_gap = 1

    # == Span Layout =======================================================================

    levels = _flame_levels(m.root, m.current, draw_w, n_levels)

    st.levels = levels
    st.margin = margin
    st.draw_w = draw_w
    st.truncated = truncated

    # == Painting ==========================================================================

    sel = _flame_selected(m)
    light = light_mode()
    bg_rgb = to_rgb(theme().bg)
    sel_rgb = to_rgb(theme().primary)

    for (level, spans) in enumerate(levels)
        y1 = ph - margin - (level - 1) * band_h
        y0 = y1 - (band_h - 1) + v_gap
        (y0 > y1) && continue

        for span in spans
            px0 = margin + floor(Int, span.x0 * draw_w) + 1
            px1 = max(px0, margin + floor(Int, span.x1 * draw_w))
            (px1 - px0 >= 3) && (px1 -= 1)

            node = span.node

            color = if node === sel
                sel_rgb
            elseif span.flags == 0x00
                color_lerp(_flame_heat(node.pct_total, light), bg_rgb, 0.4)
            else
                _flame_heat(node.pct_total, light)
            end

            fill_rect!(img, px0, y0, px1, y1, color)
        end
    end

    # == Truncation Strip ==================================================================

    if truncated
        dim_rgb = to_rgb(theme().text_dim)
        px = margin + 1

        while px <= margin + draw_w
            fill_rect!(
                img, px, margin + 1, min(px + 3, margin + draw_w), margin + 2, dim_rgb
            )
            px += 8
        end
    end

    # == Cell Row to Depth Level Map =======================================================

    resize!(st.row_level, img.cells_h)
    fill!(st.row_level, 0)

    for r in 1:img.cells_h
        py = clamp(round(Int, (r - 0.5) * ph / img.cells_h), 1, ph)

        for level in 1:n_levels
            y1 = ph - margin - (level - 1) * band_h
            y0 = y1 - (band_h - 1) + v_gap

            if y0 <= py <= y1
                st.row_level[r] = level
                break
            end
        end
    end

    return nothing
end

"""
    _flame_node_at(m, x::Int, y::Int) -> Union{PVNode, Nothing}

Return the tree node whose flame-graph rectangle contains the screen cell `(x, y)`, or
`nothing` when the cell lies outside the panel or over the background.
"""
function _flame_node_at(m, x::Int, y::Int)
    st = m.flame
    r = st.rect
    img = st.img
    (_rect_contains(r, x, y) && (img !== nothing)) || return nothing

    ly = y - r.y + 1
    (1 <= ly <= length(st.row_level)) || return nothing

    level = st.row_level[ly]
    (1 <= level <= length(st.levels)) || return nothing

    fx = clamp((x - r.x + 0.5) / max(r.width, 1), 0.0, 1.0)
    frac = (fx * img.pixel_w - st.margin) / max(st.draw_w, 1)

    for span in st.levels[level]
        (span.x0 <= frac < span.x1) && return span.node
    end

    return nothing
end

"""
    _flame_click!(m, node::PVNode) -> Nothing

Navigate the frame list of the viewer `m` to the flame-graph rectangle of `node`, using
the list click semantics: a click selects the node in its own level, and a click on the
already-selected node enters it. A click always lands in the tree view, leaving the flat
self-time view first when it is active.
"""
function _flame_click!(m, node::PVNode)
    if m.flat
        m.flat = false
        empty!(m.flat_targets)
        m.flat_return = nothing
    end

    if node === selected_row(m)
        descend!(m)
    elseif node.parent === nothing
        set_current!(m, node, nothing)
    else
        set_current!(m, node.parent, node)
    end

    return nothing
end

"""
    render_flame_panel!(m, f::Frame, rect::Rect) -> Nothing

Render the flame-graph panel into `rect`, drawing the border block into the frame buffer
and the flame graph itself through the terminal graphics protocol. The pixel buffer is
cached on the model and repainted only when the panel size or the painted state changes
(see [`_flame_sig`](@ref)). No text is ever written inside the image area, which the
Sixel path requires.
"""
function render_flame_panel!(m, f::Frame, rect::Rect)
    block = Block(;
        title = " Flame Graph ",
        title_style = tstyle(:title),
        border_style = tstyle(:border),
        box = BOX_ROUNDED,
    )
    inner = render(block, rect, f.buffer)
    ((inner.width < 4) || (inner.height < 2)) && return nothing

    st = m.flame
    st.rect = inner

    img = st.img

    if (img === nothing) || (img.cells_w != inner.width) || (img.cells_h != inner.height)
        img = PixelImage(inner.width, inner.height)
        st.img = img
        st.sig = UInt64(0)
    end

    sig = _flame_sig(m)

    if sig != st.sig
        _paint_flame!(m)
        st.sig = sig
    end

    render(img, inner, f)
    return nothing
end
