## Description #############################################################################
#
# Tests related to the themes.
#
############################################################################################

@testset "Themes" begin
    # Theme lookup and validation.
    @test TS._theme_for(:dark) === TS.SCOPE_DARK_THEME
    @test TS._theme_for(:light) === TS.SCOPE_LIGHT_THEME
    @test_throws ArgumentError TS._theme_for(:solarized)

    # Palette identity: amber chrome and navy-family structure in both variants.
    @test TS.SCOPE_DARK_THEME.accent == Tachikoma.Color256(214)
    @test TS.SCOPE_DARK_THEME.title == TS.SCOPE_DARK_THEME.accent
    @test TS.SCOPE_LIGHT_THEME.accent == Tachikoma.Color256(172)
    @test TS.SCOPE_LIGHT_THEME.bg == Tachikoma.Color256(231)

    # The default variant is changed by theme! and rejected when unknown.
    @test TS.DEFAULT_THEME[] == :dark
    @test TS.theme!(:light) == :light
    @test TS.DEFAULT_THEME[] == :light
    @test_throws ArgumentError TS.theme!(:solarized)
    @test TS.DEFAULT_THEME[] == :light
    TS.theme!(:dark)
    @test TS.DEFAULT_THEME[] == :dark

    # Color preference parsing: xterm-256 codes and quantized hex strings.
    @test TS._color_code(214) == 214
    @test TS._color_code(0) == 0
    @test TS._color_code(-1) === nothing
    @test TS._color_code(256) === nothing
    @test TS._color_code("#F59E0B") == Int(Tachikoma.hex_to_color256(0xF59E0B).code)
    @test TS._color_code("F59E0B") == TS._color_code("#F59E0B")
    @test TS._color_code("#F59") === nothing
    @test TS._color_code("not a color") === nothing
    @test TS._color_code(1.5) === nothing

    # Theme building honors the color preferences of the active project.
    @test TS._build_theme(:dark).bg == Tachikoma.Color256(234)
    @test_logs (:info,) TS.set_theme_color!(:dark, :bg, 17)
    @test TS._build_theme(:dark).bg == Tachikoma.Color256(17)
    @test_logs (:info,) TS.set_theme_color!(:light, :accent, "#F59E0B")
    @test TS._build_theme(:light).accent == Tachikoma.Color256(TS._color_code("#F59E0B"))
    @test_logs (:info,) TS.reset_theme_colors!()
    @test TS._build_theme(:dark).bg == Tachikoma.Color256(234)
    @test TS._build_theme(:light).accent == Tachikoma.Color256(172)

    # The selection background is a preference slot outside the Tachikoma theme and
    # follows the active light mode.
    old_light = Tachikoma.light_mode()
    Tachikoma.set_light_mode!(false)
    @test TS.selection_bg() == TS.SCOPE_DARK_SELECTION
    Tachikoma.set_light_mode!(true)
    @test TS.selection_bg() == TS.SCOPE_LIGHT_SELECTION
    Tachikoma.set_light_mode!(old_light)

    @test TS.SCOPE_DARK_SELECTION == Tachikoma.Color256(TS.SELECTION_DEFAULTS[:dark])
    @test TS.SCOPE_LIGHT_SELECTION == Tachikoma.Color256(TS.SELECTION_DEFAULTS[:light])
    @test_logs (:info,) TS.set_theme_color!(:dark, :selection, 238)
    @test TS._pref_color(:dark, :selection, TS.SELECTION_DEFAULTS[:dark]) ==
        Tachikoma.Color256(238)
    @test_logs (:info,) TS.reset_theme_colors!()
    @test TS._pref_color(:dark, :selection, TS.SELECTION_DEFAULTS[:dark]) ==
        Tachikoma.Color256(TS.SELECTION_DEFAULTS[:dark])

    # An invalid stored preference falls back to the default with a warning.
    Preferences.set_preferences!(TS, "dark_bg" => "oops"; force = true)
    theme = @test_logs (:warn,) TS._build_theme(:dark)
    @test theme.bg == Tachikoma.Color256(234)
    Preferences.delete_preferences!(TS, "dark_bg"; force = true)

    # Setter validation.
    @test_throws ArgumentError TS.set_theme_color!(:solarized, :bg, 0)
    @test_throws ArgumentError TS.set_theme_color!(:dark, :bgcolor, 0)
    @test_throws ArgumentError TS.set_theme_color!(:dark, :bg, 999)
    @test_throws ArgumentError TS.set_theme_color!(:dark, :bg, "#XYZ")
end
