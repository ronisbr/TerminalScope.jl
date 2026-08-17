# TerminalScope.jl

```@meta
CurrentModule = TerminalScope
```

This package provides an interactive terminal user interface (TUI) to diagnose the
performance of Julia code. It bundles four analyses under one macro and one consistent
drill-down interface:

- **Runtime profile**: where the time is spent, from the sampling profiler;
- **Allocation profile**: where the memory is allocated, including what was allocated;
- **Inference profile**: where the compiler spends its time inferring types;
- **Invalidations**: which method definitions invalidate previously compiled code.

On top of those, a **type-instability inspector** — in the spirit of `Cthulhu.@descend` —
shows the source code annotated with the inferred types and lets the user descend through
the call sites, directly from any profiled frame.

## Installation

This package can be installed using:

```julia-repl
julia> using Pkg
julia> Pkg.add("TerminalScope")
```

## Quick Start

All the analyses are reached through the macro [`@scope`](@ref), whose first argument
selects the mode:

```julia
using TerminalScope

@scope f(x)                          # Runtime profile (default mode).
@scope allocs f(x)                   # Allocation profile.
@scope inference f(x)                # Type-inference profile.
@scope invalidations using SomePkg   # Method invalidations.
@scope descend f(x)                  # Type-instability inspector.
```

Each mode opens a full-screen viewer that takes over the terminal until the user quits
with the `q` key. The main view shows the frame list on the left and the source code of
the selected row — updated live while navigating — on the right. See
[Navigation and Themes](@ref man_navigation) for the complete set of key bindings.

The corresponding function forms open the viewer on already-collected data:
[`scope_profile`](@ref), [`scope_allocs`](@ref), [`scope_inference`](@ref),
[`scope_invalidations`](@ref), and [`scope_descend`](@ref).

!!! note

    The type inspector and the invalidation analysis are backed by
    [Cthulhu.jl](https://github.com/JuliaDebug/Cthulhu.jl) and
    [SnoopCompile.jl](https://github.com/timholy/SnoopCompile.jl). Loading those packages
    invalidates compiled code of unrelated packages, so TerminalScope only loads them on
    the first use of the features that need them. Sessions that only use the profilers
    never pay that cost.

## Manual Outline

```@contents
Pages = [
    "man/runtime_profile.md",
    "man/allocation_profile.md",
    "man/inference_profile.md",
    "man/invalidations.md",
    "man/type_inspector.md",
    "man/navigation.md",
]
Depth = 2
```
