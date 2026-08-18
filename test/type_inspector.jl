## Description #############################################################################
#
# Tests related to the type-instability inspector.
#
############################################################################################

@testset "Type Instability Inspector" begin
    # ANSI escape parsing into styled spans.
    lines = TS.ansi_spans("plain\n\e[33myellow\e[39m tail\n\e[1;31mboldred\e[0m")
    @test length(lines) == 3
    @test length(lines[1]) == 1
    @test lines[1][1].content == "plain"

    @test lines[2][1].content == "yellow"
    @test lines[2][1].style.fg == Tachikoma.Color256(3)
    @test lines[2][2].content == " tail"

    @test lines[3][1].content == "boldred"
    @test lines[3][1].style.bold
    @test lines[3][1].style.fg == Tachikoma.Color256(1)

    # Extended 256-color sequences.
    ext = TS.ansi_spans("\e[38;5;99mx\e[0m")
    @test ext[1][1].style.fg == Tachikoma.Color256(99)

    # Stability classification: concrete, small union, and abstract types.
    @test !TS.is_unstable_rt(Int)
    @test TS.is_unstable_rt(Union{Int, Float64})
    @test TS.is_unstable_rt(Any)
    @test TS.type_stability_style(Int).fg == TS.tstyle(:primary).fg
    @test TS.type_stability_style(Union{Int, Float64}).fg == TS.tstyle(:warning).fg
    @test TS.type_stability_style(Any).fg == TS.tstyle(:error).fg

    # Standalone inspector on a type-unstable call chain.
    mi = Cthulhu.get_specialization(_inspect_caller, Tuple{Int})
    m = TS.inspector_viewer(mi)
    @test m.mode == :inspect
    @test m.inspect.standalone
    @test length(m.inspect.stack) == 1

    fr = TS.inspect_top(m.inspect)
    @test !isempty(fr.entries)
    @test fr.src_error === nothing
    @test !isempty(fr.code_lines)
    @test !isempty(fr.ir_lines)
    @test any(TS.is_unstable_entry, fr.entries)

    # The unstable callee appears in the list with its Union return type.
    idx = findfirst(e -> occursin("_inspect_unstable", e.label), fr.entries)
    @test idx !== nothing
    @test occursin("Union", fr.entries[idx].rt_str)
    @test fr.entries[idx].ci !== nothing

    # Rendering.
    tb = TestBackend(110, 30)
    frame = Tachikoma.Frame(
        tb.buf,
        Rect(1, 1, 110, 30),
        Tachikoma.GraphicsRegion[],
        Tachikoma.PixelSnapshot[]
    )
    tview(m, frame)
    @test find_text(tb, "Type Inspector") !== nothing
    @test find_text(tb, "[2] Call Sites") !== nothing
    @test find_text(tb, "[1] Annotated Source") !== nothing
    @test find_text(tb, "_inspect_caller") !== nothing

    # LazyGit-like pane ids: the number keys jump straight to a pane.
    @test m.inspect.focus === :calls
    update!(m, KeyEvent(:char, '1'))
    @test m.inspect.focus === :code
    update!(m, KeyEvent(:char, '2'))
    @test m.inspect.focus === :calls

    # Mouse: the wheel over the call-site list moves the selection, and a click over
    # the code pane focuses it.
    st = m.inspect
    @test (st.calls_rect.height > 0) && (st.code_rect.height > 0)
    cur0 = fr.cursor
    update!(
        m,
        MouseEvent(
            st.calls_rect.x,
            st.calls_rect.y,
            mouse_scroll_down,
            mouse_press,
            false,
            false,
            false
        )
    )
    @test fr.cursor == cur0 + 1
    update!(
        m,
        MouseEvent(
            st.code_rect.x + 1,
            st.code_rect.y + 1,
            mouse_left,
            mouse_press,
            false,
            false,
            false
        )
    )
    @test st.focus === :code
    update!(m, KeyEvent(:char, '2'))
    TS.inspect_move!(m, cur0 - fr.cursor)
    @test fr.cursor == cur0

    # Descend into the unstable callee and back.
    fr.cursor = idx + 1
    update!(m, KeyEvent(:enter))
    @test length(m.inspect.stack) == 2
    @test occursin("_inspect_unstable", TS.inspect_top(m.inspect).label)

    update!(m, KeyEvent(:backspace))
    @test length(m.inspect.stack) == 1

    # Toggle to the typed IR view and render it.
    update!(m, KeyEvent(:char, 't'))
    @test TS.inspect_top(m.inspect).view == :ir
    Tachikoma.reset!(tb.buf)
    tview(m, frame)
    @test find_text(tb, "Typed IR") !== nothing

    update!(m, KeyEvent(:char, 't'))
    @test TS.inspect_top(m.inspect).view == :source

    # Leaving the standalone inspector quits the application.
    update!(m, KeyEvent(:char, 'q'))
    @test m.quit

    # Entering from the frame list: rows without a method instance explain themselves in
    # the status notice, rows with one open the inspector, and closing it returns to the
    # frame list.
    m2 = make_model()

    # f: plain frame without a method instance.
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.mode == :tree
    @test m2.notice == "This row carries no method instance to inspect."

    # The pinned aggregate root row.
    update!(m2, KeyEvent(:home))
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.notice == "Aggregate rows cannot be type-inspected."

    # k: C frame (child of f).
    update!(m2, KeyEvent(:down))
    update!(m2, KeyEvent(:enter))
    m2.cursor = findfirst(n -> TS.node_name(n) == "k", m2.rows)
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.notice == "C frames cannot be type-inspected."
    @test m2.mode == :tree

    # Any other key clears the notice.
    update!(m2, KeyEvent(:up))
    @test isempty(m2.notice)
    update!(m2, KeyEvent(:backspace))

    node = TS.selected_row(m2)
    node.sf = StackFrame(
        :_inspect_caller,
        Symbol(@__FILE__),
        1,
        mi,
        false,
        false,
        0
    )
    update!(m2, KeyEvent(:char, 'i'))
    @test m2.mode == :inspect
    @test !m2.inspect.standalone

    update!(m2, KeyEvent(:escape))
    @test m2.mode == :tree
    @test !m2.quit
end
