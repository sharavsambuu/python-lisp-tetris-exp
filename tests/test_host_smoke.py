# tests/test_host_smoke.py — the whole game, headless, on SDL's dummy drivers.
#
# The conductor's loop is Scheme's; the tests only prove the edge can drive
# it: boot to the title screen, autostart into a match, let the --play bot
# type at the keymap for a few hundred frames, and exit cleanly — plus an
# in-process pass that samples the painted screen pixel by pixel.

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"
PY = ROOT / "env" / "bin" / "python"
if not PY.exists():  # not running inside the project's venv
    PY = Path(sys.executable)

# Every test here boots a real subprocess (or a real SDL edge) and plays
# whole frames — the slow end of the suite. `pytest -m "not slow"` skips
# the file; the in-process Scheme suites carry the fast loop.
pytestmark = pytest.mark.slow


def run_host(*flags: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(PY), "-m", "host", "--headless", *flags],
        cwd=ROOT, capture_output=True, text=True, timeout=timeout,
    )


def test_title_screen_boots_and_quits():
    r = run_host("--frames", "60")
    assert r.returncode == 0, r.stderr[-2000:]


def test_bot_plays_a_match():
    """Autostart, type at the game for 400 frames, exit clean.

    The --play bot taps the whole key vocabulary, so this crosses the keymap,
    the pipeline, locks, spawns, the journal, and the speaker — a real match,
    end to end, with no window.
    """
    r = run_host("--frames", "400", "--autostart", "--play")
    assert r.returncode == 0, r.stderr[-2000:]


def test_ai_plays_sprint():
    """The one-ply planner steers a sprint match: no crash, clean exit."""
    r = run_host("--frames", "400", "--autostart", "--mode", "sprint", "--ai")
    assert r.returncode == 0, r.stderr[-2000:]


def test_cheese_and_ultra_boot():
    """The other two modes start a match and run frames without incident."""
    for mode in ("cheese", "ultra"):
        r = run_host("--frames", "150", "--autostart", "--mode", mode, "--seed", "7")
        assert r.returncode == 0, r.stderr[-2000:]


def test_long_session_outlives_the_default_step_budget():
    """A real play session is ONE top-level form that runs for millions of
    honest steps — the interpreter's per-form 5M hang detector used to kill
    it about two minutes into a game, and a session-length 2e9 rubber
    stamp fixed the crash by disabling the detector. The budget is per
    frame now (`tick!` resets the counter); this runs enough frames to
    blow past the old per-form budget many times over and must exit clean.
    """
    r = run_host("--frames", "2500", "--autostart", "--play", timeout=240)
    assert r.returncode == 0, r.stderr[-2000:]
    assert "LispBudgetError" not in r.stderr, r.stderr[-2000:]


def test_game_env_keeps_a_per_frame_budget():
    """The regression fence, flipped: the host's env must NOT set a
    session-length step budget. The budget is per frame — `tick!` resets
    the counter — so the ceiling stays a real hang detector instead of a
    2e9 rubber stamp that no honest program could ever trip.
    """
    import os

    os.environ["SDL_VIDEODRIVER"] = "dummy"
    os.environ["SDL_AUDIODRIVER"] = "dummy"
    sys.path.insert(0, str(ROOT))

    import lisp.evaluator
    import host.pygame_host as ph

    host = ph.PygameHost(headless=True)
    try:
        ph.make_game_env(host)
        assert lisp.evaluator.STEPS_BUDGET == ph.FRAME_STEPS_BUDGET, (
            "the game env set a session-length step budget again: the "
            "per-frame reset in tick! is what keeps the hang detector honest")
    finally:
        import pygame

        pygame.quit()


def test_step_budget_is_a_per_frame_ceiling():
    """The mechanism the fix relies on, proved cheaply, on the REAL host:
    `tick!` resets the step counter once per frame, so a ceiling that could
    never carry 120 painted frames as one sum carries each of them — while
    an endless loop inside one frame (no `tick!`, no reset) still trips.
    """
    import os

    os.environ["SDL_VIDEODRIVER"] = "dummy"
    os.environ["SDL_AUDIODRIVER"] = "dummy"
    sys.path.insert(0, str(ROOT))
    import pygame

    from lisp import load_lisp, run
    from lisp.errors import LispBudgetError

    import lisp.evaluator
    import host.pygame_host as ph

    pygame.init()
    try:
        host = ph.PygameHost(headless=True)
        env = ph.make_game_env(host)
        for mod in ["core/rop", "domain/geometry", "domain/board", "domain/bag",
                    "domain/modes", "domain/game", "domain/plan",
                    "rules/commands", "rules/kicks", "rules/scoring",
                    "policies/gravity", "rules/pipeline", "content/campaign",
                    "content/locale", "presentation/view",
                    "conductor/effects", "conductor/screens",
                    "conductor/input", "conductor/arcade"]:
            load_lisp(env, SCHEME / (mod + ".scm"))

        run('(open-window! 640 640 "test")', env)
        run('(boot!)', env)
        run("(start-match! 'marathon '() 'free #f #f #f)", env)

        session = "(let loop ((i 0))" \
                  "  (if (< i 120)" \
                  "      (begin (set! *dirty* #t) (arcade-step!) (loop (+ i 1)))" \
                  "      i))"

        # Far below one old-style session, far above one honest frame: the
        # per-frame reset carries 120 frames across it; the old per-form
        # budget tripped inside the first ten.
        lisp.evaluator.STEPS_BUDGET = 100_000
        try:
            assert run(session, env) == 120, \
                "120 honest frames did not fit under a 100k per-frame budget"
        finally:
            lisp.evaluator.STEPS_BUDGET = ph.FRAME_STEPS_BUDGET

        # The detector still detects: an endless loop inside one frame —
        # tick! never called, so the counter never resets — dies at the
        # budget with a Lisp error, not never.
        lisp.evaluator.STEPS_BUDGET = 100_000
        try:
            run("(let loop () (loop))", env)
            raised = False
        except LispBudgetError:
            raised = True
        finally:
            lisp.evaluator.STEPS_BUDGET = ph.FRAME_STEPS_BUDGET
        assert raised, "an endless loop survived the per-frame budget"
    finally:
        pygame.quit()


def test_painter_paints():
    """One drawn match frame, sampled pixel by pixel.

    The dummy video driver keeps the framebuffer, so a frame drawn by the
    conductor can be read back: the background, the well frame, and the hold
    panel must carry the exact palette values the view declares.
    """
    import os

    os.environ["SDL_VIDEODRIVER"] = "dummy"
    os.environ["SDL_AUDIODRIVER"] = "dummy"

    sys.path.insert(0, str(ROOT))
    import pygame

    from lisp import load_lisp, make_env, run
    from lisp.types import NIL

    pygame.init()

    env = make_env(search_paths=[SCHEME])

    def draw_rect(x, y, w, h, rgb):
        pygame.draw.rect(pygame.display.get_surface(), tuple(rgb),
                         pygame.Rect(int(x), int(y), int(w), int(h)))

    install = [
        ("open-window!", lambda w, h, t: pygame.display.set_mode((int(w), int(h)))),
        ("clear-screen!", lambda rgb: pygame.display.get_surface().fill(tuple(rgb))),
        ("draw-rect!", draw_rect),
        ("draw-frame!", lambda x, y, w, h, rgb: pygame.draw.rect(
            pygame.display.get_surface(), tuple(rgb),
            pygame.Rect(int(x), int(y), int(w), int(h)), width=2)),
        ("draw-text!", lambda *a: None),
        ("text-width", lambda s, size: len(str(s)) * size // 2),
        ("present!", lambda: None),
        ("tint!", lambda rgb: None),
        ("tick!", lambda: 16),
        ("poll-events!", lambda: NIL),
        ("quit-requested?", lambda: False),
        ("boot-config", lambda: NIL),
        ("held?", lambda n: False),
        ("sfx!", lambda n: None),
        ("quit!", lambda: None),
        ("autostart?", lambda: True),
    ]
    from lisp import install_primitives

    install_primitives(env, install, source="test_painter_paints")

    for mod in ["core/rop", "domain/geometry", "domain/board", "domain/bag",
                "domain/modes", "domain/game", "domain/plan",
                "rules/commands", "rules/kicks", "rules/scoring",
                "policies/gravity", "rules/pipeline", "content/campaign",
                "content/locale", "presentation/view",
            "conductor/effects", "conductor/screens",
            "conductor/input", "conductor/arcade"]:
        load_lisp(env, SCHEME / (mod + ".scm"))

    run('(open-window! 640 640 "test")', env)

    # The menu screens draw: boot into the title, paint it, sample it. The
    # overlay veil covers the whole window on a menu screen, dimming the
    # furniture — so the corner reads as the veil, not the background.
    run('(boot!)', env)
    assert run("*screen*", env) == "title", "boot did not land on the title"
    run("(draw-screen!)", env)
    surf = pygame.display.get_surface()
    assert surf.get_at((5, 5))[:3] == (10, 10, 16), "menu veil missing"

    # Menu traversal: down to Free play, pick it, pick a mode, start.
    run('(menu-key! "down")', env)     # cursor to Free play
    run('(menu-key! "return")', env)   # pick it
    assert run("*screen*", env) == "mode", "free play did not open the mode list"
    run('(menu-key! "return")', env)   # marathon
    assert run("*screen*", env) == "level", "mode pick did not open the level picker"
    run('(menu-key! "return")', env)   # level 1
    assert run("*screen*", env) == "play", "the level pick did not start a match"

    # A match is live and its frame paints the whole picture.
    assert run("(phase-playing? *st*)", env) is True
    run("(play-frame *st*)", env)
    assert surf.get_at((5, 5))[:3] == (16, 16, 22), "background not painted"
    assert surf.get_at((188, 58))[:3] == (110, 110, 135), "well frame missing"
    assert surf.get_at((30, 60))[:3] == (32, 32, 44), "hold panel missing"

