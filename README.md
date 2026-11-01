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
```

Modes: `marathon` (endless), `sprint` (`target-lines`), `ultra`
(`time-limit`), `cheese` (`cheese-rows`). The title menu walks
campaign → level ladder → play; free play picks a mode and a starting
level. In a match: `a` toggles the AI, `g` toggles the ghost, `p` pauses,
`r` restarts, `esc` backs one screen.

# The seam

`host/pygame_host.py` publishes exactly sixteen primitives through the DSL's
declared `install_primitives` seam — painters (`draw-rect!`, `draw-text!`,
`tint!`, …), the clock (`tick!`), the event pump (`poll-events!`), the boot
config (`boot-config`), the speaker (`sfx!`), and the teardown. Nothing is
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
│   └── plan.scm              (tetris plan)     — the AI's profile arithmetic
├── rules/
│   ├── commands.scm          (tetris commands) — the closed command set + keymap
│   ├── kicks.scm             (tetris kicks)    — SRS wall-kick tables
│   ├── scoring.scm           (tetris scoring)  — awards, combo, back-to-back
│   └── pipeline.scm          (tetris rules)    — the Kleisli transition layer
├── content/campaign.scm      (tetris campaign) — challenges, ladders, progress
├── policies/gravity.scm      (tetris gravity)  — pacing curves, DAS knobs
├── presentation/view.scm     the painter (edge module)
├── conductor/arcade.scm      the shell: screens, input, AI, effects (edge)
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
  - **SRFI 197** — `chain` shapes the pixel pipelines in the view.
  - **SRFI 241** — `match` with string and integer constant patterns reads
    the keymap and the award table as the tables they are (note the `,_`
    wildcard: bare symbols are constants in this SRFI).

# Tests

```
python -m pytest tests/ -q
```

Seven tests: the whole pure domain checked headlessly (`tests/scm/
domain-tests.scm` — geometry invariants, board immutability, bag deals,
mode configs and their named refusals, cheese seeding, per-mode victory,
combo/b2b scoring, the plan arithmetic, campaign content and progress, a
restart that keeps its recipe, a sprint match won through the one-ply
planner, and the monad laws); the purity fence; and five headless runs of
the real game — boot, a bot playing a match, the AI steering a sprint, both
remaining modes booting, and a drawn screen read back pixel by pixel.

# Layout of a frame

On the play screen the loop is: poll events → keys become commands → the
AI takes its one step (if on) → the repeat policy (DAS/ARR) injects held
keys → gravity banks the frame's milliseconds → draw only if the world
changed → drain the journal into the speaker and the effects rail → loop.
A quiet frame costs a few comparisons; a loud one crosses the seam a few
hundred times, all batched.
