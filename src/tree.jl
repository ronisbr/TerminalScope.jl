## Description #############################################################################
#
# Viewer-side tree model built from the FlameGraphs.jl output.
#
############################################################################################

"""
    mutable struct PVNode

Represent one frame of the profile call tree in a form suitable for interactive display.

# Fields

- `sf::StackFrame`: Stack frame of this node. The root node carries the sentinel frame
    `Base.StackTraces.UNKNOWN`.
- `count::Int`: Inclusive number of profile samples in which this frame appeared.
- `self::Int`: Number of samples spent in this frame itself, excluding its children.
- `pct_total::Float64`: Inclusive samples as a percentage [%] of the total sample count.
- `pct_parent::Float64`: Inclusive samples as a percentage [%] of the parent's samples.
- `status::UInt8`: FlameGraphs status bitfield (`0x01` = runtime dispatch, `0x02` = garbage
    collection event).
- `depth::Int`: Depth of the node in the tree, where the root has depth `0`.
- `parent::Union{PVNode, Nothing}`: Parent node, or `nothing` for the root.
- `children::Vector{PVNode}`: Child nodes sorted by `count` in descending order.
- `inference::Bool`: Whether the frame belongs to the Julia compiler (type inference).
- `allocs::Int`: Secondary cost of the node, used by the allocation viewer to hold the
    value of the inactive unit (allocation counts while `count` holds bytes, and vice
    versa). It is `0` for the other viewers.
"""
mutable struct PVNode
    sf::StackFrame
    count::Int
    self::Int
    pct_total::Float64
    pct_parent::Float64
    status::UInt8
    depth::Int
    parent::Union{PVNode, Nothing}
    children::Vector{PVNode}
    inference::Bool
    allocs::Int
end

"""
    PVNode(sf::StackFrame; kwargs...) -> PVNode

Create a `PVNode` for the stack frame `sf`, defaulting every other field to an empty
value: zero costs and percentages, no status flags, depth `0`, no parent, no children,
and not an inference frame.

# Keywords

- `count::Int`: Inclusive cost of the node.
    (**Default**: `0`)
- `self::Int`: Cost of the node itself, excluding its children.
    (**Default**: `0`)
- `pct_total::Float64`: Inclusive cost as a percentage [%] of the total cost.
    (**Default**: `0.0`)
- `pct_parent::Float64`: Inclusive cost as a percentage [%] of the parent's cost.
    (**Default**: `0.0`)
- `status::UInt8`: FlameGraphs status bitfield.
    (**Default**: `0x00`)
- `depth::Int`: Depth of the node in the tree.
    (**Default**: `0`)
- `parent::Union{PVNode, Nothing}`: Parent node.
    (**Default**: `nothing`)
- `inference::Bool`: Whether the frame belongs to the Julia compiler.
    (**Default**: `false`)
- `allocs::Int`: Secondary cost of the node.
    (**Default**: `0`)
"""
function PVNode(
    sf::StackFrame;
    count::Int = 0,
    self::Int = 0,
    pct_total::Float64 = 0.0,
    pct_parent::Float64 = 0.0,
    status::UInt8 = 0x00,
    depth::Int = 0,
    parent::Union{PVNode, Nothing} = nothing,
    inference::Bool = false,
    allocs::Int = 0
)
    return PVNode(
        sf,
        count,
        self,
        pct_total,
        pct_parent,
        status,
        depth,
        parent,
        PVNode[],
        inference,
        allocs
    )
end

"""
    build_tree(g) -> PVNode

Convert the FlameGraphs tree rooted at `g` (a `LeftChildRightSiblingTrees.Node` holding
`FlameGraphs.NodeData`) into a `PVNode` tree with cost-sorted children.

Children are sorted by inclusive sample count in descending order using a stable sort, so
ties keep the original profile order.
"""
function build_tree(g)
    total = length(g.data.span)
    return _build_node(g, nothing, 0, total)
end

"""
    _build_node(g, parent::Union{PVNode, Nothing}, depth::Int, total::Int) -> PVNode

Recursively convert the FlameGraphs node `g` at `depth` into a `PVNode` attached to
`parent`, computing percentages against the `total` sample count.
"""
function _build_node(g, parent::Union{PVNode, Nothing}, depth::Int, total::Int)
    nd = g.data
    count = length(nd.span)
    pct_total = total == 0 ? 0.0 : 100 * count / total

    pct_parent = if parent === nothing
        100.0
    elseif parent.count == 0
        0.0
    else
        100 * count / parent.count
    end

    node = PVNode(
        nd.sf;
        count = count,
        self = count,
        pct_total = pct_total,
        pct_parent = pct_parent,
        status = nd.status,
        depth = depth,
        parent = parent,
        inference = is_inference_frame(nd.sf)
    )

    for c in g
        push!(node.children, _build_node(c, node, depth + 1, total))
    end

    sort!(node.children; by = c -> c.count, rev = true)
    node.self = max(0, count - sum(c -> c.count, node.children; init = 0))

    return node
end

"""
    hot_entry(root::PVNode; significance::Float64 = 0.05) -> PVNode

Return the deepest node reachable from `root` through a chain of pass-through nodes,
where a node is pass-through when it has exactly one significant child — one holding at
least `significance` of the node's inclusive count — and that child has children of its
own. This is the natural starting point of the frame list, past the REPL and script
evaluation machinery, whose frames form such a chain (possibly with noise siblings from
truncated or foreign-thread stacks).
"""
function hot_entry(root::PVNode; significance::Float64 = 0.05)
    node = root

    while !isempty(node.children)
        top = node.children[1]
        (top.count < significance * node.count) && break

        # Stop at branching points: a second significant child.
        (length(node.children) >= 2) &&
            (node.children[2].count >= significance * node.count) && break

        isempty(top.children) && break
        node = top
    end

    return node
end

"""
    level_rows(node::PVNode) -> Vector{PVNode}

Return the rows shown by the frame list when `node` is the current node: `node` itself as
the pinned parent row followed by its children.
"""
level_rows(node::PVNode) = PVNode[node; node.children]

"""
    count_nodes(node::PVNode) -> Int

Return the total number of nodes in the tree rooted at `node`, including `node` itself.
"""
function count_nodes(node::PVNode)
    n = 1

    for c in node.children
        n += count_nodes(c)
    end

    return n
end

"""
    build_inference_tree(tinf) -> PVNode

Convert the inference timing tree `tinf` returned by `SnoopCompileCore.@snoop_inference`
into a `PVNode` tree whose counts are inference plus LLVM compilation times [ns].
"""
function build_inference_tree(tinf)
    root_sf = StackFrame(Symbol("inference"), Symbol(""), -1, nothing, false, false, 0)
    root = PVNode(root_sf)

    for c in tinf.children
        push!(root.children, _build_inference_node(c, root, 1))
    end

    own = round(Int, 1e9 * SnoopCompileCore.inclusive(tinf.ci))
    root.count = own + sum(c -> c.count, root.children; init = 0)
    root.self = round(Int, 1e9 * SnoopCompileCore.exclusive(tinf.ci))

    _finalize_percentages!(root, root.count)
    return root
end

"""
    _build_inference_node(itn, parent::PVNode, depth::Int) -> PVNode

Recursively convert the `SnoopCompileCore.InferenceTimingNode` `itn` at `depth` into a
`PVNode` attached to `parent`, with counts in inference plus LLVM compilation time [ns].
Percentages are left unset; they are filled by [`_finalize_percentages!`](@ref).
"""
function _build_inference_node(itn, parent::PVNode, depth::Int)
    mi = SnoopCompileCore.methodinstance(itn.ci)
    node = PVNode(_mi_stackframe(mi); depth = depth, parent = parent)

    for c in itn.children
        push!(node.children, _build_inference_node(c, node, depth + 1))
    end

    own = round(Int, 1e9 * SnoopCompileCore.inclusive(itn.ci))
    node.count = own + sum(c -> c.count, node.children; init = 0)
    node.self = round(Int, 1e9 * SnoopCompileCore.exclusive(itn.ci))

    return node
end

"""
    _finalize_percentages!(node::PVNode, total::Int) -> PVNode

Recursively fill `pct_total` and `pct_parent` of the tree rooted at `node` against the
`total` count, and sort the children of every node by count in descending order.
"""
function _finalize_percentages!(node::PVNode, total::Int)
    node.pct_total = total == 0 ? 0.0 : 100 * node.count / total

    node.pct_parent = if node.parent === nothing
        100.0
    elseif node.parent.count == 0
        0.0
    else
        100 * node.count / node.parent.count
    end

    sort!(node.children; by = c -> c.count, rev = true)

    for c in node.children
        _finalize_percentages!(c, total)
    end

    return node
end

"""
    _method_sig_string(m::Method) -> String

Return the display signature of the method `m`, e.g. `"target(x::Int64)"`, without the
module and source location suffix.
"""
function _method_sig_string(m::Method)
    s = try
        sprint(show, m)
    catch
        return string(m.name)
    end

    r = findfirst(" @ ", s)
    return r === nothing ? s : s[1:first(r) - 1]
end

"""
    _binding_label(b::Core.Binding) -> String

Return the display name of the binding `b`, e.g. `"Main.x"`.
"""
function _binding_label(b::Core.Binding)
    return try
        string(b.globalref)
    catch
        "binding"
    end
end

"""
    _invalidation_trigger(tree) -> Tuple{String, Symbol, Int}

Return the display name, source file, and source line of the trigger of the
`SnoopCompile.MethodInvalidations` `tree`. The trigger is a `Method` for insertions and
deletions and a `Core.Binding` for rebindings. `SnoopCompile.invalidation_trees` also
emits a catch-all tree with no trigger and reason `:unknown`, collecting the
invalidations it could not attribute to any recorded definition; it is labeled
`"unattributed invalidations"`.
"""
function _invalidation_trigger(@nospecialize(tree))
    meth = tree.method

    (meth isa Method) && return (
        string(tree.reason, ' ', _method_sig_string(meth)),
        meth.file,
        Int(meth.line)
    )

    (meth isa Core.Binding) &&
        return (string(tree.reason, ' ', _binding_label(meth)), Symbol(""), 0)

    label = tree.reason === :unknown ? "unattributed invalidations" :
        string(tree.reason, " unknown method")
    return (label, Symbol(""), 0)
end

"""
    _invalidation_sig_label(sig) -> String

Return the display name of the invalidated call signature `sig` of a method-table
backedge, which is a `Type` or, for rebindings, a `Core.Binding`.
"""
function _invalidation_sig_label(@nospecialize(sig))
    (sig isa Core.Binding) && return _binding_label(sig)

    return try
        string(sig)
    catch
        "signature"
    end
end

"""
    _build_instance_pvnode(node, parent::PVNode, depth::Int) -> PVNode

Convert the SnoopCompile `InstanceNode` `node` (or a bare `Core.MethodInstance`) at
`depth` into a `PVNode` attached to `parent`. The node count is the number of invalidated
method instances in its subtree, including itself. Percentages are left unset; they are
filled by [`_finalize_percentages!`](@ref).
"""
function _build_instance_pvnode(@nospecialize(node), parent::PVNode, depth::Int)
    mi = node isa Core.MethodInstance ? node : node.mi
    pv = PVNode(_mi_stackframe(mi); count = 1, self = 1, depth = depth, parent = parent)

    if !(node isa Core.MethodInstance)
        for c in node.children
            push!(pv.children, _build_instance_pvnode(c, pv, depth + 1))
        end
    end

    pv.count = 1 + sum(c -> c.count, pv.children; init = 0)
    return pv
end

"""
    build_invalidation_tree(trees) -> PVNode

Convert the invalidation trees returned by `SnoopCompile.invalidation_trees` into a
`PVNode` tree whose counts are numbers of invalidated method instances. The first level
holds one node per trigger — a method insertion or deletion (named
`"<reason> <method signature>"`) or a binding redefinition (named
`"rebinding <module>.<name>"`) — followed by the invalidated specializations and,
recursively, the callers invalidated through them. Method-table backedges are listed
under an intermediate node named after the invalidated call signature.
"""
function build_invalidation_tree(trees)
    root_sf = StackFrame(Symbol("invalidations"), Symbol(""), -1, nothing, false, false, 0)
    root = PVNode(root_sf)

    for tree in trees
        name, file, line = _invalidation_trigger(tree)
        sf = StackFrame(Symbol(name), file, line, nothing, false, false, 0)
        tnode = PVNode(sf; depth = 1, parent = root)

        for r in tree.backedges
            push!(tnode.children, _build_instance_pvnode(r, tnode, 2))
        end

        for (sig, r) in tree.mt_backedges
            sig_sf = StackFrame(
                Symbol(_invalidation_sig_label(sig)),
                Symbol(""),
                0,
                nothing,
                false,
                false,
                0
            )
            snode = PVNode(sig_sf; depth = 2, parent = tnode)
            push!(snode.children, _build_instance_pvnode(r, snode, 3))
            snode.count = sum(c -> c.count, snode.children; init = 0)
            push!(tnode.children, snode)
        end

        tnode.count = sum(c -> c.count, tnode.children; init = 0)
        push!(root.children, tnode)
    end

    root.count = sum(c -> c.count, root.children; init = 0)
    _finalize_percentages!(root, root.count)
    return root
end

"""
    _is_alloc_internal(sf::StackFrame) -> Bool

Return `true` if `sf` is an internal frame of the allocation machinery — the profiler
recorder or any C runtime frame at the leaf side of the trace (`jl_gc_pool_alloc`,
`ijl_alloc_...`, and similar) — stripped from the recorded stack traces so the tree
leaves are the allocating Julia frames.
"""
_is_alloc_internal(sf::StackFrame) =
    (sf.func === :maybe_record_alloc_to_profile) || sf.from_c

"""
    _alloc_type_name(T) -> String

Return the display name of the allocated type `T`, using `"unknown"` for allocations
whose type could not be identified by the profiler.
"""
function _alloc_type_name(@nospecialize(T))
    (T === Profile.Allocs.UnknownType) && return "unknown"

    return try
        string(T)
    catch
        "unknown"
    end
end

"""
    demangle_name(name::AbstractString) -> String

Return a readable version of the compiler-mangled function `name`: keyword-argument
bodies (`"#pretty_table#123"`) and old-style keyword wrappers (`"f##kw"`) map to the
plain function name, anonymous functions (`"#37"`) are prefixed with `λ`, and `var"..."`
quoting is stripped. Any other name is returned unchanged.
"""
function demangle_name(name::AbstractString)
    startswith(name, "var\"") && endswith(name, "\"") && (name = name[5:prevind(name, lastindex(name))])

    m = match(r"^#([^#]+)#\d+$", name)
    (m !== nothing) && !all(isdigit, m.captures[1]) && return String(m.captures[1])

    m = match(r"^#?(.+)##kw$", name)
    (m !== nothing) && return String(m.captures[1])

    m = match(r"^#\d+(?:#\d+)?$", name)
    (m !== nothing) && return "λ" * String(name)

    return String(name)
end

"""
    _demangled_sf(sf::StackFrame) -> StackFrame

Return `sf` with its function name replaced by [`demangle_name`](@ref), keeping the
location and method instance.
"""
function _demangled_sf(sf::StackFrame)
    name = demangle_name(string(sf.func))
    (name == string(sf.func)) && return sf

    return StackFrame(
        Symbol(name),
        sf.file,
        sf.line,
        sf.linfo,
        sf.from_c,
        sf.inlined,
        sf.pointer
    )
end

"""
    _alloc_child!(
        index::Dict{Tuple{UInt64, Any}, PVNode},
        parent::PVNode,
        key,
        sf::StackFrame
    ) -> PVNode

Return the child of `parent` identified by `key`, creating it with the stack frame `sf`
and registering it in `index` when it does not exist yet.
"""
function _alloc_child!(
    index::Dict{Tuple{UInt64, Any}, PVNode},
    parent::PVNode,
    @nospecialize(key),
    sf::StackFrame
)
    k = (objectid(parent), key)
    child = get(index, k, nothing)
    (child !== nothing) && return child

    child = PVNode(sf; depth = parent.depth + 1, parent = parent)
    push!(parent.children, child)
    index[k] = child
    return child
end

"""
    build_alloc_tree(results; line_costs = nothing) -> PVNode

Convert the allocation profile `results` returned by `Profile.Allocs.fetch()` into a
`PVNode` tree whose counts are allocated bytes and whose secondary costs (`allocs`) are
allocation counts. Each allocation walks its stack trace from the root, and a leaf named
after the allocated type is appended under the allocating call site, so descending past
the deepest frame shows what was allocated there. Frame names are demangled with
[`demangle_name`](@ref), and keyword wrapper frames are collapsed by
[`_collapse_alloc_wrappers!`](@ref).

When `line_costs` is a `Dict{Symbol, Dict{Int, Tuple{Int, Int}}}`, it is filled with the
`(bytes, allocations)` charged to each line of each file. Each allocation charges, in
every file its stack passes through, only the innermost frame of that file — so within a
file the cost lands on the line closest to the allocation and caller lines stay clean,
while user files are still credited for allocations that bottom out inside Base. The
per-file grouping lets the detail view fetch the costs of one file with a single lookup.
"""
function build_alloc_tree(results; line_costs = nothing)
    root_sf = StackFrame(Symbol("allocations"), Symbol(""), -1, nothing, false, false, 0)
    root = PVNode(root_sf)
    index = Dict{Tuple{UInt64, Any}, PVNode}()

    for a in results.allocs
        st = a.stacktrace
        leaf = firstindex(st)

        while (leaf <= lastindex(st)) && _is_alloc_internal(st[leaf])
            leaf += 1
        end

        root.count += a.size
        root.allocs += 1
        node = root

        for i in lastindex(st):-1:leaf
            sf = _demangled_sf(st[i])
            node = _alloc_child!(index, node, (sf.func, sf.file, sf.line, sf.from_c), sf)
            node.count += a.size
            node.allocs += 1
        end

        tname = _alloc_type_name(a.type)
        tsf = StackFrame(Symbol(tname), Symbol(""), 0, nothing, false, false, 0)
        tnode = _alloc_child!(index, node, (:type, tname), tsf)
        tnode.count += a.size
        tnode.allocs += 1

        if line_costs !== nothing
            seen = Set{Symbol}()

            for j in leaf:lastindex(st)
                sf = st[j]
                (sf.from_c || (sf.line <= 0) || (sf.file in seen)) && continue
                push!(seen, sf.file)

                file_costs = get!(Dict{Int, Tuple{Int, Int}}, line_costs, sf.file)
                bytes, n = get(file_costs, Int(sf.line), (0, 0))
                file_costs[Int(sf.line)] = (bytes + a.size, n + 1)
            end
        end
    end

    _collapse_alloc_wrappers!(root)
    _fill_alloc_self!(root)
    _finalize_percentages!(root, root.count)
    return root
end

"""
    _collapse_alloc_wrappers!(node::PVNode) -> Nothing

Recursively remove compiler wrapper levels from the allocation tree rooted at `node`:
a child named `kwcall` carrying a single equal-cost child is replaced by that child, and
a chain of frames with the same demangled name and equal costs (a keyword body inside
its outer function) is merged into the outermost frame, which keeps its display
location.
"""
function _collapse_alloc_wrappers!(node::PVNode)
    for c in node.children
        _collapse_alloc_wrappers!(c)
    end

    # Apply both rules bottom-up until each child slot is stable, so a keyword body
    # exposed by removing a `kwcall` wrapper is merged into its outer function as well.
    for i in eachindex(node.children)
        while true
            c = node.children[i]

            # Replace a pure `kwcall` wrapper by its single callee.
            if (node_name(c) == "kwcall") && (length(c.children) == 1) &&
                (c.children[1].count == c.count)
                g = c.children[1]
                g.parent = node
                g.depth = node.depth + 1
                node.children[i] = g
                continue
            end

            # Merge a same-named single child (the keyword body) into `c`.
            if (length(c.children) == 1) && (c.children[1].count == c.count) &&
                (node_name(c.children[1]) == node_name(c))
                g = c.children[1]
                c.children = g.children

                for gc in c.children
                    gc.parent = c
                end

                continue
            end

            break
        end
    end

    return nothing
end

"""
    _fill_alloc_self!(node::PVNode) -> Nothing

Recursively fill the `self` cost of the allocation tree rooted at `node` as the node
count minus the counts of its children, so type leaves carry their full cost as self.
"""
function _fill_alloc_self!(node::PVNode)
    node.self = max(0, node.count - sum(c -> c.count, node.children; init = 0))

    for c in node.children
        _fill_alloc_self!(c)
    end

    return nothing
end

"""
    swap_alloc_unit!(node::PVNode) -> Nothing

Recursively swap the primary (`count`) and secondary (`allocs`) costs of the allocation
tree rooted at `node`, used when toggling the display between bytes and allocation
counts. The percentages and the child order must be re-finalized by the caller.
"""
function swap_alloc_unit!(node::PVNode)
    node.count, node.allocs = node.allocs, node.count

    for c in node.children
        swap_alloc_unit!(c)
    end

    return nothing
end

"""
    _mi_stackframe(mi::Core.MethodInstance) -> StackFrame

Return a `StackFrame` describing the method instance `mi`, suitable for display and
source resolution by the viewer.
"""
function _mi_stackframe(mi::Core.MethodInstance)
    def = mi.def

    if def isa Method
        return StackFrame(def.name, def.file, Int(def.line), mi, false, false, 0)
    end

    return StackFrame(Symbol("top-level scope"), Symbol(""), 0, mi, false, false, 0)
end

"""
    _is_compiler_module(mod::Module) -> Bool

Return `true` if `mod` or one of its parents is the Julia compiler module.
"""
function _is_compiler_module(mod::Module)
    while true
        ((mod === Core.Compiler) || (nameof(mod) === :Compiler)) && return true
        pm = parentmodule(mod)
        (pm === mod) && return false
        mod = pm
    end
end

"""
    is_inference_frame(sf::StackFrame) -> Bool

Return `true` if `sf` belongs to the Julia compiler (type inference), detected from the
module of its method instance.
"""
function is_inference_frame(sf::StackFrame)
    linfo = sf.linfo
    (linfo isa Core.MethodInstance) || return false

    def = linfo.def
    mod = def isa Method ? def.module : def
    (mod isa Module) || return false

    return _is_compiler_module(mod)
end

"""
    inference_samples(node::PVNode) -> Int

Return the number of samples spent in type inference in the tree rooted at `node`,
counting the inclusive samples of the topmost inference frames only, so nested inference
frames are not counted twice.
"""
function inference_samples(node::PVNode)
    node.inference && return node.count
    s = 0

    for c in node.children
        s += inference_samples(c)
    end

    return s
end

"""
    is_dispatch(node::PVNode) -> Bool

Return `true` if `node` was flagged by FlameGraphs as a runtime dispatch event.
"""
is_dispatch(node::PVNode) = (node.status & FlameGraphs.runtime_dispatch) != 0

"""
    is_gc(node::PVNode) -> Bool

Return `true` if `node` was flagged by FlameGraphs as a garbage collection event.
"""
is_gc(node::PVNode) = (node.status & FlameGraphs.gc_event) != 0

"""
    is_inference(node::PVNode) -> Bool

Return `true` if `node` is a frame of the Julia compiler (type inference).
"""
is_inference(node::PVNode) = node.inference

"""
    is_tree_root(node::PVNode) -> Bool

Return `true` if `node` is the root of the profile tree.
"""
is_tree_root(node::PVNode) = node.parent === nothing
