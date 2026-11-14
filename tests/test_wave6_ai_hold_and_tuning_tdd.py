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


def test_t62_arcade_ai_uses_lookahead_k_5_and_evaluates_hold():
    arcade_src = (SCHEME / "conductor" / "arcade.scm").read_text(encoding="utf-8")
    assert "(define *lookahead-k* 5)" in arcade_src
    assert "ai-should-hold?" in arcade_src
    assert "(hold-piece)" in arcade_src
