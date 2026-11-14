"""Wave 9 TDD tests: SRFI 226/158/190/18 adoption in Scheme Tetris."""

from pathlib import Path

from shslisp import Primitive, load_lisp, make_env, run

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"


def _make_arcade_env():
    env = make_env(search_paths=[SCHEME])
    for name in [
        "clear-screen!", "draw-rect!", "draw-rects!", "draw-frame!",
        "draw-text!", "draw-text-fit!", "tint!", "present!", "sfx!",
        "open-window!", "close-window!", "set-window-title!", "sleep-ms",
        "write-profile!",
    ]:
        env.define(name, Primitive(name, lambda *args: None))
    env.define("text-width", Primitive("text-width", lambda s, sz: len(str(s)) * max(1, int(sz // 2))))
    env.define("poll-events", Primitive("poll-events", lambda: []))
    env.define("ticks-ms", Primitive("ticks-ms", lambda: 0))
    env.define("read-profile", Primitive("read-profile", lambda: "{}"))

    for rel in [
        "core/rop.scm",
        "domain/geometry.scm",
        "domain/board.scm",
        "domain/bag.scm",
        "domain/modes.scm",
        "domain/game.scm",
        "domain/duel.scm",
        "domain/plan.scm",
        "domain/telemetry.scm",
        "domain/director.scm",
        "content/roster.scm",
        "content/campaign.scm",
        "content/locale.scm",
        "rules/commands.scm",
        "rules/kicks.scm",
        "rules/scoring.scm",
        "policies/gravity.scm",
        "rules/pipeline.scm",
        "presentation/view.scm",
        "conductor/effects.scm",
        "conductor/screens.scm",
        "conductor/input.scm",
        "conductor/arcade.scm",
    ]:
        load_lisp(env, SCHEME / rel)
    return env


def test_t91_arcade_coroutine_search_yields_pending_and_finishes_plan():
    env = _make_arcade_env()
    run("(import (tetris game) (tetris plan))", env=env)
    run("(define g (fresh-game seed: 1))", env=env)
    run("(define ws (weights 2.0 2.8 0.6 0.7 1.6 0.9))", env=env)
    run("(search-reset! g (list 0 (falling-name (game-active g))))", env=env)
    run("(define coro (make-search-coro g ws 10))", env=env)

    steps = []
    for _ in range(30):
        res = run("(coro)", env=env)
        steps.append(res)
        if res != "pending":
            break
    assert "pending" in steps
    final = steps[-1]
    assert isinstance(final, list) and len(final) == 2
    assert 0 <= final[0] < 10
    assert 0 <= final[1] < 4


def test_t92_srfi18_and_srfi226_available_in_tetris_env():
    env = _make_arcade_env()
    res = run(
        """
        (begin
          (define acc 0)
          (define t (make-thread (lambda ()
                                   (set! acc (+ acc 1))
                                   (thread-yield!)
                                   (set! acc (+ acc 2))
                                   acc)))
          (thread-start! t)
          (thread-yield!)
          (thread-join! t))
        """,
        env=env,
    )
    assert res == 3
