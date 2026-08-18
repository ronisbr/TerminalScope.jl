<p align="center">
  <img src="./docs/src/assets/logo.svg" width="150" title="TerminalScope.jl"><br>
</p>

# TerminalScope.jl

[![CI](https://img.shields.io/github/actions/workflow/status/ronisbr/TerminalScope.jl/ci.yml?style=flat-square&logo=githubactions&logoColor=white&labelColor=475569&label=CI)](https://github.com/ronisbr/TerminalScope.jl/actions/workflows/ci.yml)
[![docs-stable](https://img.shields.io/badge/docs-stable-16A34A?style=flat-square&logo=gitbook&logoColor=white&labelColor=475569)][docs-stable-url]
[![docs-dev](https://img.shields.io/badge/docs-dev-D97706?style=flat-square&logo=gitbook&logoColor=white&labelColor=475569)][docs-dev-url]
[![License](https://img.shields.io/github/license/ronisbr/TerminalScope.jl?style=flat-square&logo=readme&logoColor=white&labelColor=475569&color=0284C7)](https://github.com/ronisbr/TerminalScope.jl/blob/main/LICENSE.txt)

The **TerminalScope.jl** provides an interactive terminal user interface (TUI) to
diagnose the performance of Julia code. It bundles four analyses under one macro and one
consistent drill-down interface:

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

## Usage

All the analyses are reached through the macro `@scope`, whose first argument selects
the mode:

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
the selected row — updated live while navigating — on the right. Press `?` inside the
viewer for the complete set of key bindings.

## Theme Customization

The viewers ship with a dark theme (default) and a light one, selected with
`TerminalScope.theme!(:dark)` or `TerminalScope.theme!(:light)`. Every color of both
variants can be overridden through [Preferences.jl][preferences-url]:

```julia
# Colors accept an xterm-256 code (0-255) or a hex string (quantized to xterm-256).
TerminalScope.set_theme_color!(:dark, :accent, "#38BDF8")
TerminalScope.set_theme_color!(:light, :bg, 255)

# Restore the default palette of both variants.
TerminalScope.reset_theme_colors!()
```

The available slots are `:bg`, `:border`, `:border_focus`, `:text`, `:text_dim`,
`:text_bright`, `:primary`, `:secondary`, `:accent`, `:success`, `:warning`, `:error`,
`:title`, and `:selection` (the background of the row under the cursor). The overrides
are stored in the `LocalPreferences.toml` file of the active project and take effect
after restarting Julia.

## Documentation

For more information, see the [documentation][docs-stable-url].

[docs-dev-url]: https://ronisbr.github.io/TerminalScope.jl/dev
[preferences-url]: https://github.com/JuliaPackaging/Preferences.jl
[docs-stable-url]: https://ronisbr.github.io/TerminalScope.jl/stable
