# tests/test_menu_transitions.py — every screen transition, through the REAL host.
#
# The traversal suite (test_shell_traversal.py) drives the conductor with
# scripted keyword events; this one crosses the *whole* edge: real pygame
# events posted into the queue, the host's real poll_events! pump, the real
# keymap, the real DAS state — then the conductor's loop, one frame at a
# time. It walks every arrow in the shell's map:
#
#   title ──enter──▶ campaign ──esc──▶ title
#     └──enter──▶ mode ──esc──▶ title; mode ──enter──▶ level ──esc──▶ title
#   play (live) ──esc──▶ paused ──esc──▶ title
#   play (over) ──esc/return──▶ title; ──r──▶ a fresh match
#   play (won)  ──esc/return──▶ title
#   title ──esc──▶ quit
#
# The reason this file exists: a finished session is a *decision point* whose
# keys flow through `result-step!` → `play-key!` — a different door than the
# live match's `apply-events`. A regression there (the ESC-after-game-over
# report) is invisible to a harness that only tests RETURN.

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

from lisp import load_lisp, run  # noqa: E402

import host.pygame_host as ph  # noqa: E402

MODULES = ["core/rop", "domain/geometry", "domain/board", "domain/bag",
           "domain/modes", "domain/game", "domain/plan", "rules/commands",
           "rules/kicks", "rules/scoring", "policies/gravity",
           "rules/pipeline", "content/campaign", "content/locale",
           "presentation/view", "conductor/arcade"]


@pytest.fixture()
def env():
    """The real host on SDL's dummy drivers, with the conductor loaded."""
    pygame.init()
    try:
        host = ph.PygameHost(headless=True)
        e = ph.make_game_env(host)
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


def press(env, name):
    """One physical press, through the real queue: down then up."""
    code = ph.KEY_CODES[name]
    pygame.event.post(pygame.event.Event(pygame.KEYDOWN, key=code))
    pygame.event.post(pygame.event.Event(pygame.KEYUP, key=code))


def pump(env, keys):
    """A sequence of presses, one frame each."""
    for k in keys:
        press(env, k)
        step(env)


def screen(env):
    return run("*screen*", env)


def phase(env):
    return str(run("(game-phase *st*)", env))


def start_match(env, mode="marathon", options="'()"):
    run(f"(start-match! '{mode} {options} 'free #f #f #f)", env)
    assert screen(env) == "play"
    assert "playing" in phase(env)


def play_until_over(env, key="space", cap=200):
    """Slam pieces into one column until top-out."""
    for _ in range(cap):
        press(env, key)
        step(env)
        if "over" in phase(env):
            return
    raise AssertionError(f"{cap} {key!r} presses never topped out")


# --------------------------------------------------------------------------- #
#  the forward walks: every menu screen is reachable                          #
# --------------------------------------------------------------------------- #

def test_boot_lands_on_title(env):
    assert screen(env) == "title"


def test_title_opens_the_campaign_ladder(env):
    pump(env, ["return"])
    assert screen(env) == "campaign", "RETURN on the title did not open the ladder"


def test_title_opens_free_play_then_mode_then_level(env):
    pump(env, ["down", "return"])
    assert screen(env) == "mode", "Free play did not open the mode list"
    pump(env, ["return"])


# --------------------------------------------------------------------------- #
#  the back walks: ESC is "back one step" from every screen                    #
# --------------------------------------------------------------------------- #

def test_escape_from_campaign_returns_to_title(env):
    pump(env, ["return"])
    assert screen(env) == "campaign"
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC on the campaign ladder did not go back"


def test_escape_from_mode_returns_to_title(env):
    pump(env, ["down", "return"])
    assert screen(env) == "mode"
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC on the mode screen did not go back"


def test_escape_from_level_returns_to_title(env):
    pump(env, ["down", "return", "return"])
    assert screen(env) == "level"
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC on the level picker did not go back"


def test_escape_from_live_match_pauses_then_leaves(env):
    start_match(env)
    pump(env, ["escape"])
    assert "paused" in phase(env), "ESC in a live match did not pause"
    assert screen(env) == "play"
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC from a paused match did not go back"


def test_escape_on_title_quits(env):
    pump(env, ["escape"])
    assert run("(quit-requested?)", env) is True, "ESC on the title did not quit"


# --------------------------------------------------------------------------- #
#  the finished match: a decision point with its own keymap                    #
# --------------------------------------------------------------------------- #

def test_escape_after_game_over_returns_to_title(env):
    """The reported bug: ESC on a topped-out match must reach the title."""
    start_match(env)
    play_until_over(env)
    assert screen(env) == "play", "top-out left the play screen"
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC after a game over did not reach the title"


def test_return_after_game_over_returns_to_title(env):
    start_match(env)
    play_until_over(env)
    pump(env, ["return"])
    assert screen(env) == "title", "RETURN after a game over did not reach the title"


def test_r_after_game_over_starts_a_fresh_match(env):
    start_match(env)
    play_until_over(env)
    pump(env, ["r"])
    assert screen(env) == "play", "R after a game over did not restart"
    assert "playing" in phase(env), "the restarted match is not live"


def test_escape_after_a_won_match_returns_to_title(env):
    """A victory is the other terminal phase — same decision point."""
    start_match(env, "sprint", "'((target-lines 1))")
    run("(set! *st* (game-with *st* phase: (won)))", env)
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC after a victory did not reach the title"


def test_return_after_a_won_free_match_returns_to_title(env):
    start_match(env, "sprint", "'((target-lines 1))")
    run("(set! *st* (game-with *st* phase: (won)))", env)
    pump(env, ["return"])
    assert screen(env) == "title", "RETURN after a victory did not reach the title"


def test_leaving_a_match_owes_the_menu_a_paint(env):
    """The dirty-flag handshake, through the real pump.

    The regression: the leaving frame repainted the old screen and cleared
    *dirty*, so the title never painted — *screen* said 'title while the
    window still showed GAME OVER. This host records no draw log, but the
    handshake is observable: the leaving frame must leave the paint owed,
    and the menu's frame must pay it.
    """
    start_match(env, "sprint", "'((target-lines 1))")
    run("(set! *st* (game-with *st* phase: (won)))", env)
    step(env)                            # the result paints once
    press(env, "escape")
    step(env)                            # the leaving frame
    assert screen(env) == "title"
    assert run("*dirty*", env), "the leaving frame spent the menu's paint"
    step(env)                            # the menu's frame
    assert not run("*dirty*", env), "the menu never paid the paint it owed"


def test_effects_do_not_follow_the_next_match(env):
    """The beam and flash belong to the match that earned them."""
    start_match(env)
    run("(view-clear-beam! '(1 2 3 4))", env)
    run("(view-flash! '(255 255 0) 300)", env)
    pump(env, ["escape", "escape"])      # live -> paused -> title
    assert screen(env) == "title"
    assert run("*flash-ms*", env) == 0, "the flash followed us to the title"
    start_match(env)
    assert run("*beam-ms*", env) == 0, "the old beam survived into a new match"


def test_q_quits_from_a_paused_match(env):
    """Q is the quit key everywhere else; a paused match answers too."""
    start_match(env)
    pump(env, ["escape"])                # live -> paused
    press(env, "q")
    step(env)
    assert run("(quit-requested?)", env), "Q ignored while paused"


# --------------------------------------------------------------------------- #
#  the round trip: the shell still works after a whole session                 #
# --------------------------------------------------------------------------- #

def test_shell_survives_a_full_session_round_trip(env):
    """Play → top out → back to the title → the menus answer again.

    A stale menu value (or a conductor that forgot to rebuild the title
    screen) would show up here as a dead second visit.
    """
    pump(env, ["down", "return", "return", "return"])   # free play, marathon, level 1
    assert screen(env) == "play"
    play_until_over(env)
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC after game over did not reach the title"
    pump(env, ["down", "return"])                       # free play again
    assert screen(env) == "mode", "the mode screen did not reopen after a session"
    pump(env, ["return"])                               # marathon
    assert screen(env) == "level", "the level picker did not reopen after a session"
    pump(env, ["return"])                               # level 1
    assert screen(env) == "play", "a second match did not start"
    assert "playing" in phase(env)


def test_r_after_a_won_match_starts_a_fresh_match(env):
    """The replay is the same recipe, from the same origin."""
    start_match(env, "sprint", "'((target-lines 1))")
    run("(set! *st* (game-with *st* phase: (won)))", env)
    pump(env, ["r"])
    assert screen(env) == "play", "R after a victory did not restart"
    assert "playing" in phase(env), "the replayed match is not live"
    assert run("(config-target-lines (game-config *st*))", env) == 1, \
        "the replay lost its recipe"


def test_return_on_a_won_campaign_rung_starts_the_next_challenge(env):
    pump(env, ["return", "return"])              # title → ladder → first rung
    assert screen(env) == "play"
    run("(set! *st* (game-with *st* phase: (won)))", env)
    pump(env, ["return"])
    assert screen(env) == "play", "a won rung's RETURN did not start the next challenge"
    assert "playing" in phase(env)


def test_escape_from_a_won_campaign_rung_returns_to_title(env):
    pump(env, ["return", "return"])
    assert screen(env) == "play"
    run("(set! *st* (game-with *st* phase: (won)))", env)
    pump(env, ["escape"])
    assert screen(env) == "title", "ESC on a won campaign rung did not go back"


def test_dead_keys_are_ignored_on_the_over_screen(env):
    """Only return, r and escape move the over screen (q quits, elsewhere)."""
    start_match(env)
    play_until_over(env)
    pump(env, ["down", "space", "p", "left"])
    assert screen(env) == "play", "a dead key moved the over screen"
    assert "over" in phase(env), "a dead key left the over phase"
