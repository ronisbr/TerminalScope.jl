## Description #############################################################################
#
# Tests related to the mouse handling.
#
############################################################################################

@testset "Mouse Handling" begin
    mev(x, y, btn) = MouseEvent(x, y, btn, mouse_press, false, false, false)

    m = make_model()
    tb = TestBackend(100, 30)
    frame = Tachikoma.Frame(
        tb.buf, Rect(1, 1, 100, 30), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]
    )
    tview(m, frame)

    # Rendering records the panel areas used by the mouse hit tests.
    lr = m.list_rows_rect
    cr = m.code_rect
    @test (lr.width > 0) && (lr.height > 0)
    @test (cr.width > 0) && (cr.height > 0)

    # The wheel over the frame list moves the cursor and focuses the list.
    m.tree_focus = :code
    c0 = m.cursor
    update!(m, mev(lr.x, lr.y, mouse_scroll_down))
    @test m.cursor == c0 + 1
    @test m.tree_focus === :list
    update!(m, mev(lr.x, lr.y, mouse_scroll_up))
    @test m.cursor == c0

    # A click moves the cursor to the clicked row, and clicking the selected row again
    # enters it.
    update!(m, mev(lr.x + 2, lr.y, mouse_left))
    @test m.cursor == 1
    update!(m, mev(lr.x + 2, lr.y + 1, mouse_left))
    @test m.cursor == 2
    @test TS.node_name(TS.selected_row(m)) == "f"
    update!(m, mev(lr.x + 2, lr.y + 1, mouse_left))
    @test TS.node_name(m.current) == "f"

    # A click below the listed rows does nothing.
    rows_n = length(m.rows)
    cur = m.cursor
    update!(m, mev(lr.x, lr.y + rows_n + 3, mouse_left))
    @test (m.cursor == cur) && (TS.node_name(m.current) == "f")

    # The wheel over the source panel scrolls the code and focuses the panel.
    tview(m, frame)
    d = m.detail
    s0 = d.src_scroll
    update!(m, mev(cr.x + 1, cr.y + 1, mouse_scroll_down))
    @test m.tree_focus === :code
    @test d.src_scroll == s0 + 3
    update!(m, mev(cr.x + 1, cr.y + 1, mouse_scroll_up))
    @test d.src_scroll == s0

    # Non-left buttons and release events are ignored.
    update!(m, mev(lr.x, lr.y, mouse_right))
    @test m.tree_focus === :code
    update!(m, MouseEvent(lr.x, lr.y, mouse_left, mouse_release, false, false, false))
    @test m.tree_focus === :code

    # A click closes the help dialog.
    update!(m, KeyEvent(:char, '?'))
    @test m.help
    update!(m, mev(lr.x, lr.y, mouse_left))
    @test !m.help
end
