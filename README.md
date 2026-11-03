# python-lisp-tetris-exp

Scheme LISP Tetris but uses Python as runtime.

Serves as a demonstration of [shs-python-scheme-dsl](https://github.com/sharavsambuu/shs-python-scheme-dsl)
library usage — and a flex: **the entire Tetris is Scheme.** Python owns only
the window, the clock, the pixels, and the speaker; the domain, the rules,
the pacing, the input policy, the screens, the campaigns, and the game loop
itself all run on the DSL.

# Run it

```
virtualenv -p python3 env
source env/bin/activate
pip install -r requirements.txt

python -m host                 # the game, windowed — title menu first

# headless, straight into a match, seeded, steered by the one-ply AI:
python -m host --headless --frames 900 --autostart --mode sprint --seed 7 --ai

# the same, with the director pacing the match toward its pressure band:
python -m host --headless --frames 900 --autostart --mode sprint --seed 7 --ai --director
```

Modes: `marathon` (endless), `sprint` (`target-lines`), `ultra`
(`time-limit`), `cheese` (`cheese-rows`). The title menu walks
campaign → level ladder → play; free play picks a mode and a starting
level. In a match: `a` toggles the AI, `d` toggles the director, `g`
toggles the ghost, `p` pauses, `r` restarts, `esc` backs one screen.

# The seam

`host/pygame_host.py` publishes exactly eighteen primitives through the DSL's
declared `install_primitives` seam — painters (`draw-rect!`, `draw-text!`,
`tint!`, …), the clock (`tick!`), the event pump (`poll-events!`), the boot
config (`boot-config`), the profile (`read-profile`, `write-profile!`), the
speaker (`sfx!`), and the teardown. Nothing is
discovered at runtime; a reviewer reads one list and sees every name Python
offers.

Everything else is Scheme, in `scheme/`:

```
scheme/
├── core/rop.scm              (tetris result)   — the railway, as a library
├── domain/
│   ├── geometry.scm          (tetris geometry) — shapes; rotations are generated
│   ├── board.scm             (tetris board)    — an immutable grid, fold-cleared
│   ├── bag.scm               (tetris bag)      — the 7-bag as a pure value
│   ├── modes.scm             (tetris modes)    — the four ways to play, as data
│   ├── game.scm              (tetris game)     — the aggregate + phase/event ADTs
│   ├── plan.scm              (tetris plan)     — the AI's profile arithmetic
│   ├── telemetry.scm         (tetris telemetry) — the match's vital signs, as probes
│   └── director.scm          (tetris director) — the pacing decision core
├── rules/
│   ├── commands.scm          (tetris commands) — the closed command set + keymap
│   ├── kicks.scm             (tetris kicks)    — SRS wall-kick tables
│   ├── scoring.scm           (tetris scoring)  — awards, combo, back-to-back
│   └── pipeline.scm          (tetris rules)    — the Kleisli transition layer
├── content/campaign.scm      (tetris campaign) — challenges, ladders, progress
├── policies/gravity.scm      (tetris gravity)  — pacing curves, DAS knobs
├── presentation/view.scm     the painter (edge module)
├── conductor/effects.scm     the effects rail: speaker policy, screen awards (edge)
├── conductor/screens.scm     the menu values, the screens, the menu input (edge)
├── conductor/input.scm       the key dispatch: events, keys, repeats (edge)
├── conductor/arcade.scm      the conductor: session state, match lifecycle, AI, loop (edge)
└── main.scm                  loads contexts in order, runs (arcade-main)
```

# What is being flexed

- **DDD.** Every pure context is a real R7RS `define-library` with an explicit
  export list — a closed scope that *cannot* see the host, which is what makes
  the purity fence enforceable (a test checks it). The edge layers (view,
  conductor) are deliberately prelude-style modules, because they speak to the
  host by nature. Dependency direction: conductor → view/rules/content →
  domain; the domain imports nobody.
- **Typed control flow.** `phase`, `event`, `refusal`, `command`, and `mode`
  are closed variants declared with `define-variant`; every dispatch is a
  `variant-match` with no silent arm. Forgetting a case is a named error that
  lists the cases that exist.
- **ROP.** Every transition is a Kleisli arrow — state in, `(ok state')` or
  `(err refusal)` out — composed with the fish operator `>=>`. Slide, rotate
  (with kicks), soft drop, hard drop, hold, lock, spawn, victory: all arrows.
  A wall refusal cancels exactly that command and nothing else.
- **Monadic pipelines.** One `result-bind` implements the short-circuit; map,
  fold, traverse, `result-do`, and the fish are built on it. The monad laws
  are pinned in the test suite.
- **Conditions.** Mode options and campaign lookups refuse *by name* —
  `raise` with the valid set in the irritants, caught by `guard` at the
  conductor — a menu typo is a message, never a silent default.
- **Functional programming.** The whole session is a value: the board is an
  immutable vector-of-vectors, the bag's random future is a value under a
  seed, the campaign progress and bests are pure alists, and the journal is
  data the conductor drains into the speaker and the effects rail.
- **The SRFIs, all six, doing real work:**
  - **SRFI 1** — `fold`/`every`/`find`/`count`/`iota`/`list-index` carry the
    grid math, the journal scans, and the ladder walks.
  - **SRFI 26** — `cut` specializes arrows and cell rotators (`(cut try-shift
    <> -1 0)`).
  - **SRFI 88** — keywords name the layout table (`cell:`, `board-x:`), the
    palette, the shape table, and the event alist keys the host sends.
  - **SRFI 89** — `define*` gives the game its difficulty surface
    (`(new-game seed: … mode: … options: …)`) and the config/gravity curves
    their knobs.
  - **SRFI 197** — `chain` spells the view's one-shot pipelines (`centered-x`);
    the per-cell pixel math is plain arithmetic, because a `chain` step pays
    its expansion on every call (§12.5's scar).
  - **SRFI 241** — `match` with string and integer constant patterns reads
    the keymap and the award table as the tables they are (note the `,_`
    wildcard: bare symbols are constants in this SRFI).
- **The director.** A second loop over the match: `(tetris telemetry)` reads
  the stack's pressure off the game value (pure probes, documented ranges),
  `(tetris director)` turns a pressure reading into a pace multiplier
  (dead band, proportional error, hard clamps), and the match carries the
  pace as a field — so `step-time` bends the gravity curve through
  `(tetris gravity)`'s `paced-interval`, and every adjustment journals as a
  `(paced n)` fact. The director may bend the curve; it may never leave the
  player's hands. `--director` (or `d` in a match) turns it on; seeded
  headless runs pace it against the same disturbances with and without it.

# Tests

```
python -m pytest tests/ -q
```

The tests are Scheme: `tests/scm/` holds the suites (the pure domain, whole
match playthroughs against a fake host implemented in Scheme, screen behavior
asserted against a draw-call log, the shell's whole transition table), and
`tests/scm/run-all.scm` orchestrates them all under one interpreter. Python
is the bootstrap — it boots the DSL, sizes the step budget, and keeps a thin
real-SDL layer (subprocess smoke runs, one pixel test). The full story,
including where Python makes sense and which suite a new test belongs in,
is in [`tests/README.md`](tests/README.md).

# Layout of a frame

On the play screen the loop is: poll events → keys become commands → the
AI takes its one step (if on) → the repeat policy (DAS/ARR) injects held
keys → gravity banks the frame's milliseconds → draw only if the world
changed → drain the journal into the speaker and the effects rail → loop.
A quiet frame costs a few comparisons; a loud one crosses the seam a few
hundred times, all batched.

# Known limits

Said plainly, because a demo that hides its ceiling is a sales pitch:

- **Interpreter speed.** Every frame runs through a pure-Python
  tree-walking interpreter: a painted frame costs a few thousand
  interpreter steps, an AI-assisted frame a few tens of thousands. That
  is fine at Tetris's pace and wrong for anything that needs real
  per-frame math — physics, many sprites, shaders. The host's painting
  and event pump are native; the *game* is not.
- **The step budget is per frame.** The DSL's step budget is a hang
  detector scoped to one root evaluation, and the whole session is one
  root evaluation (`arcade-main`'s loop) — so the host resets the
  counter in `tick!`, once per frame, and `FRAME_STEPS_BUDGET`
  (5M) bounds a single frame. An endless loop in a frame dies with a
  `LispBudgetError`; a session runs forever under fresh counts. The
  reset touches the pinned DSL's thread-local internals (there is no
  public handle yet); if the internals move, the getattr chain degrades
  to the old session-length semantics rather than crashing.
- **One runtime, pinned.** The game runs on one interpreter, pinned to
  one commit of one repository. That is deliberate — the DSL is the
  whole runtime, and a HEAD change can break it — but it does mean the
  project's life is tied to that repo.
- **Scheme literacy.** The entire game is R7RS libraries, SRFIs, and
  hygienic macros. The [`docs/tutorial/`](docs/tutorial/README.md)
  series exists to get a contributor over that wall; without it, the
  bus factor on this code is small.
