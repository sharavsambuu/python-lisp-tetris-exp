# tests/test_scheme.py — the Scheme suites, headless.
#
# Each suite runs through the DSL with no pygame: the checks themselves
# raise (or the testkit reports), so a clean load *is* the green light.

from pathlib import Path

import lisp.evaluator
from lisp import load_lisp, make_env

# The domain tests steer a whole sprint match through the one-ply planner —
# hundreds of thousands of interpreter steps in one top-level form. The
# default 5M-step budget is a hang detector for production runs; a test that
# *is* a long computation asks for more. The set lives in a fixture, not at
# module scope, so another suite's cleanup can never shrink it.
lisp.evaluator.STEPS_BUDGET = 50_000_000

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"
TESTS = ROOT / "tests" / "scm"


def _load(name, extra_paths=()):
    lisp.evaluator.STEPS_BUDGET = 50_000_000
    env = make_env(search_paths=[SCHEME, *extra_paths])
    load_lisp(env, TESTS / name)
    assert env is not None


def test_pure_domain():
    _load("domain-tests.scm")


def test_gameplay_behavior():
    """Whole matches through the real conductor loop, against the fake host."""
    _load("gameplay-tests.scm", extra_paths=[TESTS])


def test_ui_behavior():
    """Screens and painter calls, asserted against the fake host's draw log."""
    _load("ui-tests.scm", extra_paths=[TESTS])


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
        "rules/commands.scm", "rules/kicks.scm",
        "rules/scoring.scm", "policies/gravity.scm", "rules/pipeline.scm",
        "core/rop.scm", "content/campaign.scm",
    ]
    for rel in pure:
        text = (SCHEME / rel).read_text()
        for word in forbidden:
            assert word not in text, f"{rel} names the host: {word}"
