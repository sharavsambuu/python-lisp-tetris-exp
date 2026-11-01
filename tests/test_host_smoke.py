# tests/test_host_smoke.py — the whole game, headless, on SDL's dummy drivers.
#
# The conductor's loop is Scheme's; the tests only prove the edge can drive
# it: boot to the title screen, autostart into a match, let the --play bot
# type at the keymap for a few hundred frames, and exit cleanly — plus an
# in-process pass that samples the painted screen pixel by pixel.

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"
PY = ROOT / "env" / "bin" / "python"
if not PY.exists():  # not running inside the project's venv
    PY = Path(sys.executable)


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
    honest steps — the interpreter's 5M hang detector used to kill it about
    two minutes into a game. The host now raises the ceiling; this runs
    enough frames to blow past the old budget and must exit clean.
    """
    r = run_host("--frames", "2500", "--autostart", "--play", timeout=240)
    assert r.returncode == 0, r.stderr[-2000:]
    assert "LispBudgetError" not in r.stderr, r.stderr[-2000:]


def test_game_env_raises_the_step_budget():
    """The regression fence for the mid-play crash: the host's env must set
    a session-length step budget, not the interpreter's 5M default — a
    painted frame costs ~1k honest steps, so 5M dies in about two minutes
    of real play.
    """
    import os

    os.environ["SDL_VIDEODRIVER"] = "dummy"
    os.environ["SDL_AUDIODRIVER"] = "dummy"
    sys.path.insert(0, str(ROOT))
    import importlib

    import lisp.evaluator

    import host.pygame_host as ph

    host = ph.PygameHost(headless=True)
    try:
        ph.make_game_env(host)
        assert lisp.evaluator.STEPS_BUDGET >= 500_000_000, (
            "the game session runs under the 5M hang budget: a long match "
            "will die mid-play")
    finally:
        import pygame

        pygame.quit()


def test_step_budget_is_a_per_program_ceiling():
    """The mechanism the fix relies on, proved cheaply: one top-level form
    carries ONE step budget across every frame, and the budget trips — no
    matter how honest the steps — when the form outlives it.
    """
    import os

    os.environ["SDL_VIDEODRIVER"] = "dummy"
    os.environ["SDL_AUDIODRIVER"] = "dummy"
    sys.path.insert(0, str(ROOT))
    import pygame

    from lisp import load_lisp, make_env, run
    from lisp.errors import LispBudgetError
    from lisp.types import NIL

    pygame.init()
    try:
        env = make_env(search_paths=[SCHEME])
        install = [
            ("open-window!", lambda w, h, t: pygame.display.set_mode((640, 640))),
            ("clear-screen!", lambda rgb: pygame.display.get_surface().fill(tuple(rgb))),
            ("draw-rect!", lambda x, y, w, h, rgb: pygame.draw.rect(
                pygame.display.get_surface(), tuple(rgb),
                pygame.Rect(int(x), int(y), int(w), int(h)))),
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
            ("autostart?", lambda: False),
        ]
        from lisp import install_primitives

        install_primitives(env, install, source="test_step_budget")
        for mod in ["core/rop", "domain/geometry", "domain/board", "domain/bag",
                    "domain/modes", "domain/game", "domain/plan",
                    "rules/commands", "rules/kicks", "rules/scoring",
                    "policies/gravity", "rules/pipeline", "content/campaign",
                    "presentation/view", "conductor/arcade"]:
            load_lisp(env, SCHEME / (mod + ".scm"))

        run('(open-window! 640 640 "test")', env)
        run('(boot!)', env)
        run("(start-match! 'marathon '() 'free #f #f #f)", env)

        import lisp.evaluator

        session = "(let loop ((i 0))" \
                  "  (if (< i 120)" \
                  "      (begin (set! *dirty* #t) (arcade-step!) (loop (+ i 1)))" \
                  "      i))"

        # A tiny ceiling trips mid-session — the hang detector is per form.
        lisp.evaluator.STEPS_BUDGET = 30_000
        try:
            run(session, env)
            raised = False
        except LispBudgetError:
            raised = True
        assert raised, "a 30k budget survived 120 painted frames?"

        # The host's session ceiling carries the same form to the end.
        lisp.evaluator.STEPS_BUDGET = 2_000_000_000
        assert run(session, env) == 120
    finally:
        pygame.quit()
        # Other suites in this process expect the runner's own budget.
        import lisp.evaluator

        lisp.evaluator.STEPS_BUDGET = 50_000_000


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
                "presentation/view", "conductor/arcade"]:
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
    run("(play-frame *st* #t)", env)
    assert surf.get_at((5, 5))[:3] == (16, 16, 22), "background not painted"
    assert surf.get_at((188, 58))[:3] == (110, 110, 135), "well frame missing"
    assert surf.get_at((30, 60))[:3] == (32, 32, 44), "hold panel missing"

