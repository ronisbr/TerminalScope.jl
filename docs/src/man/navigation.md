# [Navigation and Themes](@id man_navigation)

```@meta
CurrentModule = TerminalScope
```

## The Main View

Every profile viewer shares the same layout: the frame list on the left and the source
panel on the right, updated live while navigating.

- **`[1] Frames`**: One level of the tree at a time — the current node as a pinned parent
  row (`⬑`) followed by its children, sorted by cost. Entering a node auto-descends
  through single-child chains until the next branching point, and going back inverts the
  auto-descent in one key press.
- **`[2] Source`**: A compact information strip (name, tags, costs, and method signature)
  above the syntax-highlighted source of the selected row, with the frame line marked
  with `▶`.

The panels are numbered like in LazyGit: the number keys jump straight to a panel, and
the movement keys act on the focused one.

| Keys              | Action                                                        |
|:------------------|:--------------------------------------------------------------|
| `↑` / `↓`         | Move the cursor (list) or scroll the code (source panel)      |
| `j` `k` `h` `l` `g` `G` | Vim-style aliases of `↓` `↑` `←` `→` `Home` `End`       |
| `PgUp` / `PgDn`   | Move or scroll one page                                       |
| `Home` / `End`    | Go to the first / last row, or the top / bottom of the code   |
| `Enter` / `→`     | Enter the node; on a leaf, focus the source panel             |
| `Bksp` / `←`      | Go back to the parent node                                    |
| `Tab`, `1` / `2`  | Switch or jump the panel focus                                |
| `+` / `-`         | Maximize / restore the focused panel                          |
| `0` / `$`         | Source panel: go to the line start / end                      |
| `^D` / `^U`       | Source panel: scroll half a page                              |
| `i`               | Inspect the selected frame for type instabilities             |
| `u`               | Allocations: toggle between bytes and allocation counts       |
| `?`               | Toggle the help dialog                                        |
| `q`               | Quit                                                          |

The status bar always shows the most important bindings of the active view, and the `?`
dialog lists all of them.

The mouse is supported as well: the wheel scrolls the panel under the cursor — moving
the selection in the lists and the view in the code panes — and a left click focuses the
clicked panel, moving the selection to the clicked row. Clicking the selected row again
enters it.

## Themes

The viewers ship with a dark and a light theme, matching the SatelliteToolbox ecosystem
presentation palette: navy structure, amber chrome, cyan data emphasis, and magenta
secondary emphasis.

The default variant is `:dark`. It can be changed for the session:

```julia
TerminalScope.theme!(:light)
```

or per invocation, since every function entry point accepts a `theme` keyword:

```julia
scope_profile(g; theme = :light)
```

```@docs
theme!
```
