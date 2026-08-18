## Description #############################################################################
#
# Theme system: SatelliteAnalysis-based color palettes, Preferences.jl overrides, and the
# default variant selection.
#
############################################################################################

"""
    THEME_SLOTS

Color slots of a TerminalScope theme, in the order of the `Tachikoma.Theme` constructor.
Each slot of each variant can be overridden with a Preferences.jl preference named
`"<variant>_<slot>"`, e.g. `"dark_bg"` (see [`set_theme_color!`](@ref)).
"""
const THEME_SLOTS = (
    :bg,
    :border,
    :border_focus,
    :text,
    :text_dim,
    :text_bright,
    :primary,
    :secondary,
    :accent,
    :success,
    :warning,
    :error,
    :title,
)

"""
    THEME_DEFAULTS

Default xterm-256 color codes of the [`THEME_SLOTS`](@ref) of the `:dark` and `:light`
theme variants, matching the SatelliteAnalysis.jl presentation palette: navy structure,
amber chrome (titles, costs, focus), cyan data emphasis, and magenta secondary emphasis,
quantized to the closest xterm-256 colors. The light variant uses a white surface with
the accents darkened for contrast as in the original.
"""
const THEME_DEFAULTS = Dict{Symbol, NTuple{13, Int}}(
    :dark => (
        234,  # bg: navy #0A1929.
        24,   # border: navy blue #1E3A5F, biased to keep the blue hue.
        214,  # border_focus: amber #F59E0B.
        255,  # text: off-white #F1F5F9.
        109,  # text_dim: blue-gray #94A3B8.
        75,   # text_bright: cyan #38BDF8.
        75,   # primary: cyan #38BDF8.
        205,  # secondary: magenta #F472B6.
        214,  # accent: amber #F59E0B.
        78,   # success: green #34D399.
        220,  # warning: gold #FBBF24, kept distinct from the accent.
        203,  # error: coral #F87171.
        214,  # title: amber #F59E0B.
    ),
    :light => (
        231,  # bg: white #FFFFFF.
        188,  # border: light slate #CBD5E1.
        172,  # border_focus: amber #D97706.
        234,  # text: navy #0A1929.
        238,  # text_dim: slate #334155.
        32,   # text_bright: cyan #0284C7.
        32,   # primary: cyan #0284C7.
        162,  # secondary: magenta #DB2777.
        172,  # accent: amber #D97706.
        29,   # success: green #059669.
        136,  # warning: dark gold, kept distinct from the accent.
        160,  # error: red #DC2626.
        172,  # title: amber #D97706.
    ),
)

"""
    _color_code(value::Any) -> Union{Int, Nothing}

Convert the color preference `value` — an xterm-256 code (0-255) or a hex string like
`"#F59E0B"`, quantized to the closest xterm-256 color — to an xterm-256 code, returning
`nothing` when the value is invalid.
"""
function _color_code(value::Any)
    (value isa Integer) && return (0 <= value <= 255) ? Int(value) : nothing

    if value isa AbstractString
        str = lstrip(value, '#')
        (length(str) == 6) || return nothing
        hex = tryparse(UInt32, str; base = 16)
        (hex === nothing) && return nothing
        return Int(Tachikoma.hex_to_color256(hex).code)
    end

    return nothing
end

"""
    _pref_color(variant::Symbol, slot::Symbol, default::Int) -> Color256

Return the color of the theme `slot` of `variant`, taking the `"<variant>_<slot>"`
preference over the `default` xterm-256 code. An invalid preference value falls back to
`default` with a warning.
"""
function _pref_color(variant::Symbol, slot::Symbol, default::Int)
    value = Preferences.load_preference(@__MODULE__, "$(variant)_$(slot)", default)
    code = _color_code(value)

    if code === nothing
        @warn "Invalid color preference `$(variant)_$(slot) = $(repr(value))`. " *
            "Using the default color."
        code = default
    end

    return Color256(code)
end

"""
    _build_theme(variant::Symbol) -> Tachikoma.Theme

Assemble the theme of `variant`, either `:dark` or `:light`, from the default colors and
the Preferences.jl overrides (see [`set_theme_color!`](@ref)).
"""
function _build_theme(variant::Symbol)
    defaults = THEME_DEFAULTS[variant]
    colors = ntuple(i -> _pref_color(variant, THEME_SLOTS[i], defaults[i]), 13)
    return Tachikoma.Theme("scope-$(variant)", colors...)
end

"""
    SCOPE_DARK_THEME

Dark TerminalScope theme, built from [`THEME_DEFAULTS`](@ref) and the Preferences.jl
color overrides (see [`set_theme_color!`](@ref)).
"""
const SCOPE_DARK_THEME = _build_theme(:dark)

"""
    SCOPE_LIGHT_THEME

Light TerminalScope theme, built from [`THEME_DEFAULTS`](@ref) and the Preferences.jl
color overrides (see [`set_theme_color!`](@ref)).
"""
const SCOPE_LIGHT_THEME = _build_theme(:light)

"""
    SELECTION_DEFAULTS

Default xterm-256 color codes of the `:selection` slot of the `:dark` and `:light` theme
variants: the background used to highlight the row under the cursor. The slot lives
outside `Tachikoma.Theme`, which has no selection color, but is overridden through the
same preference mechanism as the [`THEME_SLOTS`](@ref) (see [`set_theme_color!`](@ref)).
"""
const SELECTION_DEFAULTS = Dict{Symbol, Int}(:dark => 237, :light => 252)

"""
    SCOPE_DARK_SELECTION

Selection background of the dark theme variant, built from [`SELECTION_DEFAULTS`](@ref)
and the Preferences.jl color overrides (see [`set_theme_color!`](@ref)).
"""
const SCOPE_DARK_SELECTION = _pref_color(:dark, :selection, SELECTION_DEFAULTS[:dark])

"""
    SCOPE_LIGHT_SELECTION

Selection background of the light theme variant, built from [`SELECTION_DEFAULTS`](@ref)
and the Preferences.jl color overrides (see [`set_theme_color!`](@ref)).
"""
const SCOPE_LIGHT_SELECTION = _pref_color(:light, :selection, SELECTION_DEFAULTS[:light])

"""
    _PREF_SLOTS

Every color slot that can be overridden with a Preferences.jl preference: the
[`THEME_SLOTS`](@ref) of the `Tachikoma.Theme` plus the `:selection` slot (see
[`SELECTION_DEFAULTS`](@ref)).
"""
const _PREF_SLOTS = (THEME_SLOTS..., :selection)

"""
    set_theme_color!(
        variant::Symbol,
        slot::Symbol,
        color::Union{Integer, AbstractString}
    ) -> Nothing

Persist `color` as the color of the theme `slot` of `variant` using Preferences.jl,
overriding the default of [`THEME_DEFAULTS`](@ref). The change is written to the
`LocalPreferences.toml` file of the active project and takes effect after restarting
Julia. The function throws when the variant, slot, or color is invalid.

# Arguments

- `variant::Symbol`: Theme variant, either `:dark` or `:light`.
- `slot::Symbol`: Color slot, one of [`THEME_SLOTS`](@ref) — `:bg`, `:border`,
    `:border_focus`, `:text`, `:text_dim`, `:text_bright`, `:primary`, `:secondary`,
    `:accent`, `:success`, `:warning`, `:error`, or `:title` — or `:selection`, the
    background of the row under the cursor.
- `color::Union{Integer, AbstractString}`: Color as an xterm-256 code (0-255) or a hex
    string like `"#F59E0B"`, which is quantized to the closest xterm-256 color.

# Extended help

## Throws

- `ArgumentError`: The variant is not `:dark` or `:light`, the slot is not one of
    [`THEME_SLOTS`](@ref), or the color is neither a code in 0-255 nor a `"#RRGGBB"`
    string.

## Examples

```julia-repl
julia> TerminalScope.set_theme_color!(:dark, :accent, "#38BDF8")

julia> TerminalScope.set_theme_color!(:light, :bg, 255)
```
"""
function set_theme_color!(
    variant::Symbol, slot::Symbol, color::Union{Integer, AbstractString}
)
    haskey(THEME_DEFAULTS, variant) || throw(
        ArgumentError("Unknown theme `:$variant`. The options are `:dark` and `:light`."),
    )

    (slot in _PREF_SLOTS) || throw(
        ArgumentError(
            "Unknown theme slot `:$slot`. The options are " *
            join((":$s" for s in _PREF_SLOTS), ", ") *
            ".",
        ),
    )

    (_color_code(color) === nothing) && throw(
        ArgumentError(
            "Invalid color `$(repr(color))`. Use an xterm-256 code (0-255) or a hex " *
            "string like \"#F59E0B\".",
        ),
    )

    Preferences.set_preferences!(@__MODULE__, "$(variant)_$(slot)" => color; force = true)
    @info "Theme color saved. Restart Julia for it to take effect."
    return nothing
end

"""
    reset_theme_colors!() -> Nothing

Delete every theme color preference of both variants, restoring the default colors of
[`THEME_DEFAULTS`](@ref) after restarting Julia.
"""
function reset_theme_colors!()
    keys = ["$(v)_$(s)" for v in (:dark, :light) for s in _PREF_SLOTS]
    Preferences.delete_preferences!(@__MODULE__, keys...; force = true)
    @info "Theme colors reset to the defaults. Restart Julia for it to take effect."
    return nothing
end

"""
    DEFAULT_THEME

Theme variant used by the viewers when none is given, either `:dark` or `:light`. Change
it with [`theme!`](@ref).
"""
const DEFAULT_THEME = Ref{Symbol}(:dark)

"""
    _theme_for(variant::Symbol) -> Tachikoma.Theme

Return the theme of the `variant`, either `:dark` or `:light`, throwing an
`ArgumentError` for any other value.
"""
function _theme_for(variant::Symbol)
    (variant === :dark) && return SCOPE_DARK_THEME
    (variant === :light) && return SCOPE_LIGHT_THEME
    return throw(
        ArgumentError("Unknown theme `:$variant`. The options are `:dark` and `:light`.")
    )
end

"""
    theme!(variant::Symbol) -> Symbol

Set the default theme variant of the TerminalScope viewers to `variant`, either `:dark`
or `:light`, and return it. Every entry point also accepts a `theme` keyword overriding
this default for one invocation.
"""
function theme!(variant::Symbol)
    _theme_for(variant)
    DEFAULT_THEME[] = variant
    return variant
end
