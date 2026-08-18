# Invalidations

```@meta
CurrentModule = TerminalScope
```

The `invalidations` mode of [`@scope`](@ref) records the method invalidations caused by
an expression — typically code loading — and opens the viewer with the invalidation
forest:

```julia
@scope invalidations expr
```

The typical usage wraps a package load:

```julia-repl
julia> @scope invalidations using SomePackage
```

The recording is performed by `SnoopCompileCore.@snoop_invalidations`, and the raw data
is organized into trees by `SnoopCompile.invalidation_trees`.

!!! note

    SnoopCompile itself invalidates compiled code when loaded, so TerminalScope loads it
    on the first use of this feature — deliberately **after** the recording, so its own
    invalidations do not pollute the capture. If it cannot be loaded, the raw data is
    returned so nothing is lost.

## The Viewer

![Invalidations viewer](../assets/screenshots/invalidations.svg)

The first level lists the **triggers** — one row per event that invalidated compiled
code — sorted by the number of invalidated method instances:

- `inserting f(::T)`: A new, more specific method was defined;
- `deleting f(::T)`: A method was removed;
- `rebinding Main.x`: A binding (e.g. a constant) was redefined;
- `unattributed invalidations`: Invalidations that `SnoopCompile` could not attribute to
  a recorded definition, common when package images are involved.

Descending into a trigger shows the invalidated method specializations and, recursively,
the callers invalidated through them. Method-table backedges are listed under an
intermediate row named after the invalidated call signature. The cost column shows the
number of invalidated instances in each subtree.

Pressing `i` on an invalidated instance opens the [Type Inspector](@ref man_type_inspector)
on it, so the loose type that made the code vulnerable to invalidation can be found
immediately.

## Viewing Collected Data

```julia
scope_invalidations(invs)
```

accepts either the raw data returned by `SnoopCompileCore.@snoop_invalidations` or the
trees returned by `SnoopCompile.invalidation_trees`.

## Examples

```julia-repl
julia> using TerminalScope

julia> @scope invalidations using CSV

julia> invs = SnoopCompileCore.@snoop_invalidations using DataFrames;

julia> scope_invalidations(invs)
```
