# tests/test_scheme.py — the Scheme suites, headless.
#
# Each suite runs through the DSL with no pygame: the checks themselves
# raise (or the testkit reports), so a clean load *is* the green light.

import os
from pathlib import Path

import pytest

import lisp.evaluator
from lisp import load_lisp, make_env, run

# The domain tests steer a whole sprint match through the one-ply planner —
# hundreds of thousands of interpreter steps in one top-level form. In
# production the step budget is a PER-FRAME hang detector (the host's
# `tick!` resets the counter each frame); a test that *is* a long
# computation in one form asks for more. `_load` raises the budget per
# suite, and the autouse fixture below restores it afterwards, so one
# suite's ceiling can never leak into another's.
DEFAULT_BUDGET = 50_000_000

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"
TESTS = ROOT / "tests" / "scm"


@pytest.fixture(autouse=True)
def _restore_step_budget():
    """Snapshot the interpreter's step budget around every test.

    `_load` (and some tests directly) set `lisp.evaluator.STEPS_BUDGET` —
    a module global shared by every suite in the process. Whatever a test
    raises it to, this puts it back, so a leaked ceiling can never quietly
    loosen another suite's hang detector.
    """
    saved = lisp.evaluator.STEPS_BUDGET
    yield
    lisp.evaluator.STEPS_BUDGET = saved


def _load(name, extra_paths=(), budget=DEFAULT_BUDGET):
    lisp.evaluator.STEPS_BUDGET = budget
    env = make_env(search_paths=[SCHEME, *extra_paths])
    load_lisp(env, TESTS / name)
    assert env is not None


def test_pure_domain():
    _load("domain-tests.scm")


@pytest.mark.slow
def test_gameplay_behavior():
    """Whole matches through the real conductor loop, against the fake host."""
    _load("gameplay-tests.scm", extra_paths=[TESTS])


def test_ui_behavior():
    """Screens and painter calls, asserted against the fake host's draw log."""
    _load("ui-tests.scm", extra_paths=[TESTS])


@pytest.mark.slow
def test_shell_transitions():
    """Every screen transition, keys through the fake host's event queue."""
    _load("shell-tests.scm", extra_paths=[TESTS])


@pytest.mark.slow
@pytest.mark.skipif(not os.environ.get("SCHEME_RUN_ALL"),
                    reason="run-all re-runs every Scheme suite under one "
                           "env — the slow walk. SCHEME_RUN_ALL=1 to "
                           "include it; the suites themselves run above.")
def test_run_all_orchestrates_every_suite():
    """The Scheme runner loads and guards all four suites in one env.

    `run-all.scm` is the Scheme-side entry point (`shs run
    tests/scm/run-all.scm`); this test proves the orchestration — shared
    env, cached module loads, per-suite guards — holds together, so the
    suites stay runnable with pytest as nothing but the bootstrap that
    raised the step budget. The shared env carries every earlier suite's
    top-level bindings, and the planner-heavy forms pay a little for that,
    so the ceiling here is sized for the whole walk, not one suite.
    """
    _load("run-all.scm", extra_paths=[TESTS], budget=500_000_000)


def test_domain_modules_are_pure_r7rs_libraries():
    """The domain imports no host name: its libraries are closed scopes.

    A cheap architectural fence: the pure contexts import only (scheme
    base), the SRFIs, each other, and (tetris result) — never a painter or a
    speaker. If someone wires the host into the domain, this goes red.
    """
    forbidden = ("draw-rect", "draw-frame", "draw-text", "clear-screen",
                 "sfx!", "open-window!", "tick!", "poll-events!",
                 "present!", "held?", "quit!", "tint!", "boot-config")
    pure = [
        "domain/geometry.scm", "domain/board.scm", "domain/bag.scm",
        "domain/modes.scm", "domain/game.scm", "domain/plan.scm",
        "domain/telemetry.scm", "domain/director.scm",
        "rules/commands.scm", "rules/kicks.scm",
        "rules/scoring.scm", "policies/gravity.scm", "rules/pipeline.scm",
        "core/rop.scm", "content/campaign.scm", "content/locale.scm",
    ]
    for rel in pure:
        text = (SCHEME / rel).read_text()
        for word in forbidden:
            assert word not in text, f"{rel} names the host: {word}"


@pytest.mark.slow
def test_painter_keeps_up_with_a_full_board():
    """draw-board! on a full board stays far under the frame budget.

    A regression guard for the `chain`-in-the-inner-loop slowdown: px/py
    once paid ~0.7 ms a call in macro expansion, and a full board's
    repaint burned ~300 ms — a slideshow. Plain arithmetic paints the
    same 200 cells in ~15 ms. The bound sits far above the fixed cost
    and far below the regressed one, so only a real regression trips it.
    """
    import time

    lisp.evaluator.STEPS_BUDGET = 100_000_000
    env = make_env(search_paths=[SCHEME, TESTS])
    load_lisp(env, TESTS / "bench-view.scm")

    run("(draw-board! *st*)", env)  # warm
    t0 = time.perf_counter()
    for _ in range(5):
        run("(draw-board! *st*)", env)
    per_call_ms = (time.perf_counter() - t0) / 5 * 1000
    assert per_call_ms < 100, (
        f"draw-board! on a full board takes {per_call_ms:.0f} ms — the "
        "painter is burning its budget in the inner loop again")
