## Description #############################################################################
#
# Tests related to the rendering of the main view.
#
############################################################################################

@testset "Rendering" begin
    m = make_model()
    tb = TestBackend(100, 30)
    frame = Tachikoma.Frame(
        tb.buf, Rect(1, 1, 100, 30), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]
    )

    # Frame list at the root level: pinned parent row plus the children.
    tview(m, frame)
    @test find_text(tb, "Samples") !== nothing
    @test find_text(tb, "100") !== nothing
    @test find_text(tb, "all samples") !== nothing
    @test find_text(tb, "f") !== nothing
    @test find_text(tb, "80.0%") !== nothing
    @test find_text(tb, "q") !== nothing

    # Descend into f: the level shows the [GC] tag of k.
    update!(m, KeyEvent(:enter))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[GC]") !== nothing

    # Descend into g: the level shows the [dyn] tag of h.
    update!(m, KeyEvent(:enter))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[dyn]") !== nothing

    # The source panel follows the selection: it shows the info strip and the source,
    # with the owner package tagged after the file location.
    @test find_text(tb, "[1] Frames") !== nothing
    @test find_text(tb, "[2] runtests.jl") !== nothing
    @test find_text(tb, "[TerminalScope.jl]") !== nothing
    @test find_text(tb, "Samples") !== nothing

    # Zoom: each + grows the focused panel one step, maximizing it at the last step, and
    # Esc restores the default split.
    pos0 = find_text(tb, "[2] runtests.jl")
    update!(m, KeyEvent(:char, '+'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[1] Frames") !== nothing
    pos1 = find_text(tb, "[2] runtests.jl")
    @test pos1 !== nothing
    @test pos1.x > pos0.x

    # Changing the focus must not move the anchored split.
    update!(m, KeyEvent(:char, '2'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    pos2 = find_text(tb, "[2] runtests.jl")
    @test pos2 !== nothing
    @test pos2.x == pos1.x
    update!(m, KeyEvent(:char, '1'))

    foreach(_ -> update!(m, KeyEvent(:char, '+')), 1:(TS.ZOOM_MAX - 1))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[1] Frames") !== nothing
    @test find_text(tb, "[2] runtests.jl") === nothing
    update!(m, KeyEvent(:char, '2'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "[1] Frames") === nothing
    @test find_text(tb, "[2] runtests.jl") !== nothing
    update!(m, KeyEvent(:escape))
    update!(m, KeyEvent(:char, '1'))

    # Help dialog.
    update!(m, KeyEvent(:char, '?'))
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "Help") !== nothing
    @test find_text(tb, "Quit the application") !== nothing
    @test find_text(tb, "esc to close") !== nothing

    # Degenerate terminal size.
    tb2 = TestBackend(10, 3)
    frame2 = Tachikoma.Frame(
        tb2.buf, Rect(1, 1, 10, 3), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]
    )
    m2 = make_model()
    tview(m2, frame2)
    @test find_text(tb2, "Terminal") !== nothing
end
