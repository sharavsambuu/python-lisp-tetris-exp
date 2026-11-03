# tests/test_shell_traversal.py — the whole shell, driven by scripted keys.
#
# The smoke tests boot into a match directly; this one walks the *shell*:
# title → campaign → a challenge → play, real key events through the real
# loop, then the play controls (move, rotate, drop, hold, soft drop), then
# pause/resume/escape back to the title, then a free-play match. It also
# measures every menu screen's overlay lines against the window, so a label
# that outgrows the viewport turns red here instead of on a player's screen.

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"
sys.path.insert(0, str(ROOT))

os.environ["SDL_VIDEODRIVER"] = "dummy"
os.environ["SDL_AUDIODRIVER"] = "dummy"

import pygame  # noqa: E402
import pytest  # noqa: E402

from lisp import install_primitives, load_lisp, make_env, run  # noqa: E402
from lisp.types import NIL, intern, intern_keyword  # noqa: E402

MODULES = ["core/rop", "domain/geometry", "domain/board", "domain/bag",
           "domain/modes", "domain/game", "domain/plan", "domain/telemetry", "domain/director", "rules/commands",
           "rules/kicks", "rules/scoring", "policies/gravity",
           "rules/pipeline", "domain/duel", "content/campaign", "content/roster",
           "content/locale",
           "conductor/profile", "presentation/view",
           "conductor/effects", "conductor/screens", "conductor/input",
           "conductor/arcade"]

K_TYPE = intern_keyword("type")
K_KEY = intern_keyword("key")
T_DOWN = intern("key-down")


class ScriptedKeys:
    """A poll-events! that answers one scripted key per frame."""

    def __init__(self, keys):
        self.keys = list(keys)
        self.i = 0

    def __call__(self):
        if self.i < len(self.keys):
            k = self.keys[self.i]
            self.i += 1
            return [[[K_TYPE, T_DOWN], [K_KEY, k]]]
        return NIL


@pytest.fixture()
def env():
    pygame.init()
    try:
        e = make_env(search_paths=[SCHEME])

        def draw_rect(x, y, w, h, rgb):
            pygame.draw.rect(pygame.display.get_surface(), tuple(rgb),
                             pygame.Rect(int(x), int(y), int(w), int(h)))

        install = [
            ("open-window!", lambda w, h, t: pygame.display.set_mode((640, 640))),
            ("clear-screen!", lambda rgb: pygame.display.get_surface().fill(tuple(rgb))),
            ("draw-rect!", draw_rect),
            ("draw-rects!", lambda flat, dx=0, dy=0: None),
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
            ("read-profile", lambda: NIL),
            ("write-profile!", lambda doc: True),
            ("held?", lambda n: False),
            ("sfx!", lambda n: None),
            ("quit!", lambda: None),
            ("autostart?", lambda: False),
        ]
        install_primitives(e, install, source="test_shell_traversal")
        for m in MODULES:
            load_lisp(e, SCHEME / (m + ".scm"))
        run('(open-window! 640 640 "test")', e)
        run("(boot!)", e)
        yield e
    finally:
        pygame.quit()


def step(env):
    """One frame of the real loop."""
    run("(arcade-step!)", env)


def screen(env):
    return run("*screen*", env)


def phase(env):
    return run("(tag-of (game-phase *st*))", env)


def pump(env, keys):
    """Swap in a scripted key pump and run one frame per key."""
    install_primitives(env, [("poll-events!", ScriptedKeys(keys))],
                       source="test_shell_traversal")
    for _ in keys:
        step(env)


def test_campaign_ladder_to_play(env):
    """title → campaign → first challenge → a live match."""
    assert screen(env) == "title"
    run('(menu-key! "return")', env)   # pick the campaign
    assert screen(env) == "campaign"
    step(env)                          # draw the ladder once
    run('(menu-key! "return")', env)   # pick the first challenge
    assert screen(env) == "play", "picking a campaign level did not start a match"
    assert phase(env) == "playing"
    # The recipe is the challenge's: a 5-line sprint.
    assert run('(config-target-lines (game-config *st*))', env) == 5


def test_play_controls_move_the_piece(env):
    """Movement keys land in the *kept* state, not a discarded one."""
    run('(start-match! \'marathon \'() \'free #f #f #f)', env)
    assert phase(env) == "playing"
    x0 = run("(falling-x (game-active *st*))", env)
    pump(env, ["left", "left", "right"])
    x1 = run("(falling-x (game-active *st*))", env)
    assert x1 == x0 - 1, f"three moves should net -1 column, {x0} -> {x1}"
    # A rotate turns the piece.
    r0 = run("(falling-rot (game-active *st*))", env)
    pump(env, ["up"])
    r1 = run("(falling-rot (game-active *st*))", env)
    assert r1 == (r0 + 1) % 4, "up did not rotate the piece"


def test_pause_resume_and_escape_to_title(env):
    run('(start-match! \'marathon \'() \'free #f #f #f)', env)
    pump(env, ["p"])
    assert phase(env) == "paused", "P did not pause the match"
    pump(env, ["p"])
    assert phase(env) == "playing", "P did not resume the match"
    pump(env, ["escape"])
    assert phase(env) == "paused"
    pump(env, ["escape"])
    assert screen(env) == "title", "escape from a paused match did not go back"


def test_hold_and_drop_score(env):
    run('(start-match! \'marathon \'() \'free #f #f #f)', env)
    pump(env, ["space"])
    assert run("(game-score *st*)", env) > 0, "a hard drop paid no points"
    assert run("(game-active *st*)", env) is not None, "no piece spawned after the drop"
    # The hold: park the piece, then the swap is spent until the next lock.
    pump(env, ["c"])
    assert run("(game-can-hold *st*)", env) is False, \
        "the second hold before a lock should be refused"


def test_game_over_returns_to_title(env):
    """Slam pieces into one column until top-out, then RETURN goes back."""
    run('(start-match! \'marathon \'() \'free #f #f #f)', env)
    import itertools
    install_primitives(env, [("poll-events!",
                              ScriptedKeys(list(itertools.repeat("space", 60))))],
                       source="test_over")
    for _ in range(60):
        step(env)
        if phase(env) == "over":
            break
    assert phase(env) == "over", "slamming one column never topped out"
    install_primitives(env, [("poll-events!", ScriptedKeys(["return"]))],
                       source="test_over_back")
    step(env)
    assert screen(env) == "title", "RETURN after a game over did not go back"


def test_menu_overlays_fit_the_window(env):
    """No overlay line on any screen is wider than the window."""
    run('(boot!)', env)
    run('(set! *campaign* (campaign-by-id "ascent"))', env)
    for scr, menu in [("title", None), ("campaign", "(campaign-menu *campaign*)"),
                      ("mode", "(mode-menu)"), ("level", "(level-menu)")]:
        run("(set! *screen* '" + scr + ")", env)
        if menu:
            run("(set! *menu* " + menu + ")", env)
        for spec in run("(screen-overlay)", env):
            text = str(spec[0]).replace('"', "")
            w = run('(text-width "' + text + '" ' + str(spec[1]) + ")", env)
            assert w <= 640, f"{scr}: {text!r} is {w}px wide"

