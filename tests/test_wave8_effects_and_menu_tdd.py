"""Wave 8 TDD tests: directional shake, clear particles, drop/lock flash, and menu highlight."""

from pathlib import Path

from shslisp import Primitive, load_lisp, make_env, run

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"


def _make_view_env():
    draw_log = []
    env = make_env(search_paths=[SCHEME])

    def reg(name, fn):
        env.define(name, Primitive(name, fn))

    reg("clear-screen!", lambda *args: draw_log.append(("clear", args)))
    reg("draw-rect!", lambda *args: draw_log.append(("rect", args)))
    reg("draw-rects!", lambda *args: draw_log.append(("rects", args)))
    reg("draw-frame!", lambda *args: draw_log.append(("frame", args)))
    reg("draw-text!", lambda *args: draw_log.append(("text", args)))
    reg("draw-text-fit!", lambda *args: draw_log.append(("text-fit", args)))
    reg("text-width", lambda s, sz: len(str(s)) * max(1, int(sz // 2)))
    reg("measure-text", lambda s, sz: [len(str(s)) * max(1, int(sz // 2)), int(sz)])
    reg("tint!", lambda *args: draw_log.append(("tint", args)))
    reg("present!", lambda *args: draw_log.append(("present", args)))
    reg("sfx!", lambda *args: None)

    for rel in [
        "core/rop.scm",
        "domain/geometry.scm",
        "domain/board.scm",
        "domain/bag.scm",
        "domain/modes.scm",
        "domain/game.scm",
        "domain/duel.scm",
        "domain/plan.scm",
        "content/roster.scm",
        "content/locale.scm",
        "rules/commands.scm",
        "rules/kicks.scm",
        "rules/scoring.scm",
        "policies/gravity.scm",
        "rules/pipeline.scm",
        "presentation/view.scm",
        "conductor/effects.scm",
    ]:
        load_lisp(env, SCHEME / rel)
    return env, draw_log


def test_t81_directional_shake_alternates_across_frames():
    env, _ = _make_view_env()
    run("(import (tetris game))", env=env)
    run("(define g (fresh-game seed: 1))", env=env)
    run("(view-reset!)", env=env)
    run("(view-shake! 4.0)", env=env)

    sx1 = run("(shake-x)", env=env)
    run("(view-fx-step! 16 g)", env=env)
    sx2 = run("(shake-x)", env=env)
    run("(view-fx-step! 16 g)", env=env)
    sx3 = run("(shake-x)", env=env)

    assert sx1 != 0
    assert sx2 != 0
    assert (sx1 > 0 and sx2 < 0 and sx3 > 0) or (sx1 < 0 and sx2 > 0 and sx3 < 0)


def test_t82_clear_particles_drop_trail_and_lock_flash_render_and_decay():
    env, draw_log = _make_view_env()
    run("(import (tetris game))", env=env)
    run("(define g (fresh-game seed: 1))", env=env)
    run("(view-reset!)", env=env)

    run("(view-drop-trail! 'left 10)", env=env)
    run("(view-lock-flash! 'left)", env=env)
    run("(view-clear-beam! 'left '(18 19))", env=env)
    assert run("(view-busy? g)", env=env) is True

    draw_log.clear()
    run("(draw-game! g)", env=env)
    rects = [item for item in draw_log if item[0] == "rect"]
    assert len(rects) > 4

    for _ in range(30):
        run("(view-fx-step! 20 g)", env=env)
    assert run("(view-busy? g)", env=env) is False


def test_t83_active_menu_row_draws_highlight_bar_inside_window():
    env, draw_log = _make_view_env()
    draw_log.clear()
    run('(draw-overlay! \'(("TITLE" 30) ("> Start" 22) ("  Quit" 22)))', env=env)

    w = run("window-width", env=env)
    h = run("window-height", env=env)
    rects = [args for kind, args in draw_log if kind == "rect"]
    # Background veil + at least one highlight slab for "> Start"
    assert len(rects) >= 2
    for x, y, rw, rh, _rgb in rects:
        assert x >= 0 and y >= 0
        assert x + rw <= w
        assert y + rh <= h
