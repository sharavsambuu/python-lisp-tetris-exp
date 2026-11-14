"""Wave 6 TDD tests: stronger AI roster tuning, lookahead-k=5, and AI hold."""

from pathlib import Path

from shslisp import load_lisp, make_env, run

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"


def test_t61_roster_enables_roof_penalty_and_faster_clocks():
    env = make_env(search_paths=[SCHEME])
    for rel in [
        "domain/geometry.scm",
        "domain/plan.scm",
        "content/roster.scm",
    ]:
        load_lisp(env, SCHEME / rel)
    run("(import (tetris plan) (tetris roster))", env=env)

    # Every persona now has a non-zero roof penalty (6th dial)
    for pid in ("wall", "blitz", "scholar", "mirror"):
        roof = run(f"(w-roof (persona-weights (persona-by-id '{pid})))", env=env)
        assert roof > 0, f"{pid} should have w-roof > 0"

    # Scholar remains slowest, but faster than the old speed=2
    scholar_speed = run("(persona-speed (persona-by-id 'scholar))", env=env)
    wall_speed = run("(persona-speed (persona-by-id 'wall))", env=env)
    assert scholar_speed >= 4
    assert wall_speed > scholar_speed


def test_t62_arcade_ai_uses_lookahead_and_evaluates_hold_without_crash():
    from shslisp import Primitive

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

    assert run("*lookahead-k*", env=env) >= 2
    run("(import (tetris game) (tetris plan))", env=env)
    run("(define g (fresh-game seed: 1))", env=env)
    run("(search-reset! g (list 0 (falling-name (game-active g))))", env=env)
    res = run("(ai-should-hold? g (weights 2.0 3.0 0.8 0.8 1.5 0.7) -9999.0)", env=env)
    assert res is True
