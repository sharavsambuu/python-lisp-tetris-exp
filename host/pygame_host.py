"""The pygame edge: window, clock, pixels, speaker — published as primitives.

**Bounded context.** This module knows pygame-ce and the seam
(:func:`lisp.make_env` / :func:`lisp.install_primitives`) and nothing else. It
never imports anything from ``scheme/`` — the two sides meet only at the
declared primitive table in ``PygameHost.primitives``, and at the one program
entry point: loading ``scheme/main.scm`` into an environment built here.

The contract with the Scheme side is small, and every name in it is written
down once, in that table:

* ``(open-window! w h title)`` — Scheme decides the window size; Python only
  opens what it is asked for.
* ``(clear-screen! rgb)``, ``(draw-rect! x y w h rgb)``,
  ``(draw-frame! x y w h rgb)``, ``(draw-text! x y s size rgb)``,
  ``(text-width s size)``, ``(present!)`` — the painter. Colors travel as
  ``(r g b)`` lists; a cell is a rectangle; there is no game in here.
* ``(tick!)`` — the clock: one call per frame, answers the elapsed
  milliseconds (and holds the frame to ~60 fps).
* ``(poll-events!)`` — the event pump, answered as an *alist per event*:
  ``((type: . quit))`` or ``((type: . key-down) (key: . "left"))``. Data, not
  callbacks: the Scheme side folds over it.
* ``(held? name)``, ``(quit-requested?)``, ``(autostart?)``,
  ``(sfx! name)``, ``(quit!)`` — input state, the speaker, the teardown.

A headless run is a first-class citizen: ``--frames N`` answers quit after N
frames (that is how the smoke test drives the whole game with SDL's dummy
drivers), and ``--autostart`` tells the Scheme title screen to skip itself.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pygame

from lisp import install_primitives, make_env
from lisp.types import intern_keyword, intern

__all__ = ["PygameHost", "make_game_env", "main", "SCHEME_DIR"]

#: The event keys, as the keyword objects the Scheme side assqs on.
K_TYPE = intern_keyword("type")
K_KEY = intern_keyword("key")

#: The event types, as symbols the Scheme side cases on.
T_QUIT = intern("quit")
T_KEY_DOWN = intern("key-down")
T_KEY_UP = intern("key-up")

#: Keycode -> the name the Scheme side sees. Lowercase words, one spelling
#: each; the keymap in ``scheme/rules/commands.scm`` owns the mapping the
#: other way. Anything unlisted is simply never reported.
KEY_NAMES = {
    pygame.K_LEFT: "left",
    pygame.K_RIGHT: "right",
    pygame.K_DOWN: "down",
    pygame.K_UP: "up",
    pygame.K_SPACE: "space",
    pygame.K_z: "z",
    pygame.K_x: "x",
    pygame.K_c: "c",
    pygame.K_p: "p",
    pygame.K_r: "r",
    pygame.K_q: "q",
    pygame.K_LSHIFT: "shift",
    pygame.K_RSHIFT: "shift",
    pygame.K_RETURN: "return",
    pygame.K_KP_ENTER: "return",
    pygame.K_ESCAPE: "escape",
}

#: Held keys the DAS policy may care about — the same spelling as KEY_NAMES.
HELD_KEYS = ("left", "right", "down")

#: name -> keycode, for the scripted-input mode (``--play``): a tiny bot that
#: lives at the edge and types at the game so a headless smoke test crosses
#: the whole input path — keymap, pipeline, journal, speaker.
KEY_CODES = {name: code for code, name in KEY_NAMES.items()}

#: name -> (frequency Hz, seconds, volume) — the whole soundtrack. A beep is
#: synthesized into a small buffer on first use and cached. The closed set is
#: the audio vocabulary: a kind says *what the blip is*, never *when* — the
#: sound policy lives in the conductor.
BEEP_SPECS = {
    "move": (220, 0.03, 0.35),
    "rotate": (330, 0.04, 0.35),
    "lock": (150, 0.06, 0.5),
    "clear": (520, 0.12, 0.5),
    "tetris": (660, 0.2, 0.6),
    "drop": (110, 0.08, 0.5),
    "hold": (392, 0.05, 0.4),
    "soft-drop": (260, 0.025, 0.3),
    "hard-drop": (110, 0.08, 0.5),
    "denied": (90, 0.09, 0.5),
    "start": (440, 0.15, 0.5),
    "over": (70, 0.4, 0.6),
    "victory": (523, 0.25, 0.55),
    "level-up": (587, 0.18, 0.5),
    "pause": (196, 0.07, 0.4),
    "menu-move": (300, 0.03, 0.3),
    "menu-select": (460, 0.08, 0.45),
}

class PygameHost:
    """The edge object: one instance, installed into the env as primitives."""

    def __init__(self, *, headless: bool = False, max_frames: int | None = None,
                 autostart: bool = False, play_script: bool = False,
                 mode: str | None = None, level: int | None = None,
                 seed: int | None = None, ai: bool = False) -> None:
        if headless:
            os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
            os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
        self._display_ready = False
        self._sound_ready = False
        self.screen: pygame.Surface | None = None
        self.clock: pygame.time.Clock | None = None
        self.max_frames = max_frames
        self.autostart = autostart
        self.play_script = play_script
        self.mode = mode
        self.level = level
        self.seed = seed
        self.ai = ai
        self._frames = 0
        self._quit_seen = False
        self._sounds: dict[str, pygame.mixer.Sound] = {}
        # Font and rendered-text caches: a painted frame draws ~20 strings,
        # and building a freetype Font per call costs real milliseconds —
        # the difference between a 16ms frame and a 40ms one, which the
        # player feels as input lag and bursty DAS. Fonts are cached by
        # size; rendered surfaces by (text, size, color), bounded so the
        # ticker's ever-changing numbers cannot grow it without end.
        self._fonts: dict[int, pygame.font.Font] = {}
        self._text_cache: dict[tuple[str, int, tuple[int, int, int]], pygame.Surface] = {}
        self._init_pygame()

    # ------------------------------------------------------------------ #
    #  setup                                                              #
    # ------------------------------------------------------------------ #

    def _init_pygame(self) -> None:
        pygame.init()
        try:
            pygame.mixer.init(22050, -16, 1, 512)
            self._sound_ready = True
        except pygame.error:
            self._sound_ready = False  # no audio device: the game still runs

    def open_window(self, w: int, h: int, title: str) -> None:
        """The one crossing that creates the display. Scheme asks; Python obeys."""
        self.screen = pygame.display.set_mode((int(w), int(h)))
        pygame.display.set_caption(str(title))
        self.clock = pygame.time.Clock()
        self._display_ready = True

    def _require_display(self) -> pygame.Surface:
        if not self._display_ready:
            raise RuntimeError(
                "host: the window is not open — call (open-window! w h title) first"
            )
        return self.screen

    # ------------------------------------------------------------------ #
    #  the clock and the event pump                                       #
    # ------------------------------------------------------------------ #

    def tick(self) -> int:
        """One frame: hold ~60 fps, answer the elapsed milliseconds."""
        dt = self.clock.tick(60)
        # A hitch (GC, OS, a slow first frame) must not hand the conductor a
        # giant dt: gravity would leap rows and the repeat policy would land
        # a burst of moves in one frame — the player sees a skip. The clock
        # is capped at four frames' worth; the loop is already behind, and
        # catch-up beyond that reads as a stutter, not as time.
        self._frames += 1
        return int(min(dt, 66))

    def poll_events(self) -> list:
        """The frame's events, as alists the Scheme side can fold over.

        Each event is ``((type: . kind) [key: …])`` — the keys are the host's
        keyword objects (so ``assq`` matches them), the kinds are symbols the
        conductor ``case``s on, and key names are strings the keymap matches.
        No events is the *Scheme* empty list, so ``(null? evs)`` is honest.
        """
        from lisp.types import NIL

        events: list = []
        if self.max_frames is not None and self._frames >= self.max_frames:
            self._quit_seen = True  # the headless run's way to say "done"
        for raw in pygame.event.get():
            if raw.type == pygame.QUIT:
                self._quit_seen = True
                events.append([[K_TYPE, T_QUIT]])
            elif raw.type == pygame.KEYDOWN:
                name = KEY_NAMES.get(raw.key)
                if name is not None:
                    events.append([[K_TYPE, T_KEY_DOWN], [K_KEY, name]])
            elif raw.type == pygame.KEYUP:
                name = KEY_NAMES.get(raw.key)
                if name is not None:
                    events.append([[K_TYPE, T_KEY_UP], [K_KEY, name]])
        if self.play_script and self._frames % 12 == 0:
            # The bot taps a key from the whole vocabulary, cycling — enough
            # to steer, rotate, drop, and hold its way around.
            keys = ["left", "x", "right", "down", "space", "c", "z", "space"]
            name = keys[(self._frames // 12) % len(keys)]
            code = KEY_CODES.get(name, pygame.K_SPACE)
            pygame.event.post(pygame.event.Event(pygame.KEYDOWN, key=code))
            pygame.event.post(pygame.event.Event(pygame.KEYUP, key=code))
        return events if events else NIL

    def quit_seen(self) -> bool:
        return self._quit_seen

    def boot_config(self) -> list:
        """The CLI as the alist Scheme boots from.

        ``((mode . "sprint") (level . 5) (seed . 7) (ai . #t)
        (autostart . #t))`` — only the flags the run actually carried, so
        the Scheme side can ``assq`` its way through and treat an absent
        key as "not asked for".
        """
        from lisp.types import NIL, Symbol, make_list

        def pair(key, value):
            return make_list([Symbol(key), value])

        out = NIL
        pairs = []
        if self.mode is not None:
            pairs.append(pair("mode", self.mode))
        if self.level is not None:
            pairs.append(pair("level", int(self.level)))
        if self.seed is not None:
            pairs.append(pair("seed", int(self.seed)))
        if self.ai:
            pairs.append(pair("ai", True))
        if self.autostart:
            pairs.append(pair("autostart", True))
        for p in reversed(pairs):
            out = make_list([p, out])
        return out


    # ------------------------------------------------------------------ #
    #  the painter                                                        #
    # ------------------------------------------------------------------ #

    def clear_screen(self, rgb) -> None:
        self._require_display().fill(tuple(int(c) for c in rgb))

    def draw_rect(self, x, y, w, h, rgb) -> None:
        pygame.draw.rect(
            self._require_display(),
            tuple(int(c) for c in rgb),
            pygame.Rect(int(x), int(y), int(w), int(h)),
        )

    def draw_frame(self, x, y, w, h, rgb) -> None:
        pygame.draw.rect(
            self._require_display(),
            tuple(int(c) for c in rgb),
            pygame.Rect(int(x), int(y), int(w), int(h)),
            width=2,
        )

    def _font(self, size: int) -> pygame.font.Font:
        """One Font per size, built once — never per call."""
        size = int(size)
        font = self._fonts.get(size)
        if font is None:
            font = pygame.font.Font(None, size)
            self._fonts[size] = font
        return font

    def draw_text(self, x, y, s, size, rgb) -> None:
        color = tuple(int(c) for c in rgb)
        key = (str(s), int(size), color)
        surface = self._text_cache.get(key)
        if surface is None:
            if len(self._text_cache) > 256:
                self._text_cache.clear()  # the ticker's old numbers age out
            surface = self._font(size).render(
                str(s), True, color)
            self._text_cache[key] = surface
        self._require_display().blit(surface, (int(x), int(y)))

    def text_width(self, s, size) -> int:
        return self._font(size).size(str(s))[0]

    def present(self) -> None:
        pygame.display.flip()

    def tint(self, rgb) -> None:
        """One additive veil over the whole window — a flash that brightens.

        The conductor decides *when*; this is only the paint. An additive
        fill, so the palette underneath stays readable through the veil.
        """
        self._require_display().fill(
            tuple(min(255, int(c)) for c in rgb), special_flags=pygame.BLEND_RGB_ADD
        )

    # ------------------------------------------------------------------ #
    #  input state and the speaker                                        #
    # ------------------------------------------------------------------ #

    def held(self, name) -> bool:
        if not self._display_ready or str(name) not in HELD_KEYS:
            return False
        keys = pygame.key.get_pressed()
        code = {v: k for k, v in KEY_NAMES.items()}.get(str(name))
        return bool(code is not None and keys[code])

    def _beep(self, name: str) -> pygame.mixer.Sound:
        if name in self._sounds:
            return self._sounds[name]
        import array
        import math

        freq, seconds, volume = BEEP_SPECS[name]
        rate = 22050
        n = int(rate * seconds)
        samples = array.array("h")
        for i in range(n):
            t = i / rate
            # A soft square: the fundamental with a little 3rd harmonic, so it
            # reads as a blip rather than a buzzer; the decay keeps the tail
            # from clicking.
            wave = math.sin(2 * math.pi * freq * t)
            wave += 0.3 * math.sin(2 * math.pi * 3 * freq * t)
            envelope = 1.0 - (i / n)
            samples.append(int(32767 * volume * 0.5 * envelope * wave / 1.3))
        sound = pygame.mixer.Sound(samples.tobytes())
        self._sounds[name] = sound
        return sound

    def sfx(self, name) -> None:
        if not self._sound_ready or str(name) not in BEEP_SPECS:
            return
        self._beep(str(name)).play()

    def quit(self) -> None:
        self._quit_seen = True



    # ------------------------------------------------------------------ #
    #  the seam: the whole crossing, in one declared list                 #
    # ------------------------------------------------------------------ #

    def primitives(self) -> list:
        """The vocabulary this host publishes, as (name, callable) pairs."""
        return [
            ("open-window!", self.open_window),
            ("clear-screen!", self.clear_screen),
            ("draw-rect!", self.draw_rect),
            ("draw-frame!", self.draw_frame),
            ("draw-text!", self.draw_text),
            ("text-width", self.text_width),
            ("present!", self.present),
            ("tint!", self.tint),
            ("tick!", self.tick),
            ("poll-events!", self.poll_events),
            ("quit-requested?", self.quit_seen),
            ("boot-config", self.boot_config),
            ("held?", self.held),
            ("sfx!", self.sfx),
            ("quit!", self.quit),
            ("autostart?", lambda: self.autostart),
        ]


# --------------------------------------------------------------------------- #
#  wiring                                                                      #
# --------------------------------------------------------------------------- #

SCHEME_DIR = Path(__file__).resolve().parent.parent / "scheme"


def make_game_env(host: PygameHost):
    """The environment the game runs in: DSL profile + this host's primitives."""
    # The step budget is the interpreter's hang detector for ONE top-level
    # form — and the whole session is one top-level form (`arcade-main`'s
    # loop). A painted frame costs roughly a thousand honest steps, so the
    # 5M default dies about two minutes into a real game. The ceiling here
    # is a session-length bound (hours of play), not a hang detector; the
    # headless run's frame cap is what bounds an automated run.
    import lisp.evaluator

    lisp.evaluator.STEPS_BUDGET = 2_000_000_000
    env = make_env(search_paths=[SCHEME_DIR])
    install_primitives(env, host.primitives(), source="host/pygame_host.py")
    return env


def main(argv: list[str] | None = None) -> int:
    """Run the game: build the env, load ``scheme/main.scm``, let Scheme drive."""
    argv = list(sys.argv[1:] if argv is None else argv)
    headless = "--headless" in argv
    autostart = "--autostart" in argv
    play_script = "--play" in argv
    max_frames = None
    if "--frames" in argv:
        max_frames = int(argv[argv.index("--frames") + 1])
    mode = None
    if "--mode" in argv:
        mode = argv[argv.index("--mode") + 1]
    level = None
    if "--level" in argv:
        level = int(argv[argv.index("--level") + 1])
    seed = None
    if "--seed" in argv:
        seed = int(argv[argv.index("--seed") + 1])
    ai = "--ai" in argv

    host = PygameHost(headless=headless, max_frames=max_frames,
                      autostart=autostart, play_script=play_script,
                      mode=mode, level=level, seed=seed, ai=ai)
    env = make_game_env(host)
    from lisp import load_lisp

    try:
        load_lisp(env, SCHEME_DIR / "main.scm")
    except SystemExit:
        pass  # the game asked to leave; that is a normal ending
    finally:
        pygame.quit()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
