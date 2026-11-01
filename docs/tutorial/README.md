# Building a Game on a Scheme DSL — the tutorials

These tutorials teach game programming **on an embedded Scheme DSL**, using this
repository — a complete Tetris where Python owns only the window, the clock, the
pixels, and the speaker, and *everything else* runs on the DSL — as the running
example. Every code excerpt is quoted from the real files; every technique is
one the game actually relies on.

Read them in order. Each ends with exercises; the suggested reading pairs each
chapter with the file it dissects.

| # | Chapter | You learn | The file it dissects |
|---|---------|-----------|----------------------|
| 1 | [A language inside a language](01-the-seam.md) | The host/script seam, embedded runtimes, why the boundary is a list of 16 names | `host/pygame_host.py`, `scheme/main.scm` |
| 2 | [Closed vocabularies](02-closed-vocabularies.md) | `define-variant` / `variant-match` — enums that fail loudly | `scheme/domain/game.scm`, `scheme/rules/commands.scm` |
| 3 | [The railway](03-the-railway.md) | A Result monad from scratch, Kleisli composition, refusals as data | `scheme/core/rop.scm`, `scheme/rules/pipeline.scm` |
| 4 | [State as a value](04-state-as-a-value.md) | Immutable aggregates, copy-on-write grids, the randomizer as a value, the journal | `scheme/domain/board.scm`, `bag.scm`, `game.scm` |
| 5 | [Frames and time](05-frames-and-time.md) | The game loop, gravity banking, the dirty flag, the host-side input pump | `scheme/conductor/arcade.scm`, `host/pygame_host.py` |
| 6 | [The edge](06-the-edge.md) | Screens, menus, the effects rail, painters as pure reductions | `scheme/presentation/view.scm`, `scheme/conductor/arcade.scm` |
| 7 | [The one-ply planner](07-the-planner.md) | Profile arithmetic, placement scoring, the frame-budgeted search | `scheme/domain/plan.scm`, `best-placement` in the conductor |
| 8 | [Testing a game with no mocks](08-testing.md) | The host as data, seeded playthroughs, collecting test kits | `tests/scm/fake-host.scm`, `tests/scm/testkit.scm` |
| 9 | [Performance in an interpreter](09-performance.md) | Where the milliseconds go, caches, quiet frames, the step budget | `host/pygame_host.py`, cProfile findings |
| 10 | [Bounded contexts](10-bounded-contexts.md) | DDD with `define-library`: closed scopes, the dependency DAG, the purity fence | the `scheme/` tree, `tests/test_scheme.py` |
| 11 | [Conditions](11-conditions.md) | `raise`/`guard` with named irritants; refusals vs conditions vs errors | `scheme/domain/modes.scm`, `conductor/arcade.scm` |
| 12 | [The six SRFIs](12-the-srfis.md) | SRFI 1/26/88/89/197/241 — where each earns its keep, and the judgment calls | everywhere |

## What the root README flexes → where the series teaches it

| The flex | The chapters |
|---|---|
| **DDD** (bounded contexts, dependency direction, purity fence) | [1](01-the-seam.md), [10](10-bounded-contexts.md) |
| **Typed control flow** (`define-variant` / `variant-match`) | [2](02-closed-vocabularies.md) |
| **ROP** (every transition a Kleisli arrow) | [3](03-the-railway.md) |
| **Monadic pipelines** (one `result-bind`, do-notation, traversals) | [3](03-the-railway.md), [5](05-frames-and-time.md) (gravity through the railway) |
| **Conditions** (raise by name, guard at the conductor) | [11](11-conditions.md) |
| **Functional programming** (the session as a value, journal as data) | [4](04-state-as-a-value.md), [5](05-frames-and-time.md) |
| **SRFI 1** (folds, `every`, `find`, `count`, `iota`, `list-index`) | [12](12-the-srfis.md) (§12.1), [4](04-state-as-a-value.md) |
| **SRFI 26** (`cut` specializes arrows) | [12](12-the-srfis.md) (§12.2), [3](03-the-railway.md) |
| **SRFI 88** (keywords name the tables and event keys) | [12](12-the-srfis.md) (§12.3), [6](06-the-edge.md) |
| **SRFI 89** (`define*` gives the difficulty surface its knobs) | [12](12-the-srfis.md) (§12.4), [4](04-state-as-a-value.md) |
| **SRFI 197** (`chain` shapes the pixel pipelines) | [12](12-the-srfis.md) (§12.5), [6](06-the-edge.md) |
| **SRFI 241** (`match` reads the keymap and award tables) | [12](12-the-srfis.md) (§12.6), [2](02-closed-vocabularies.md) |

## Running the game while you read

```
virtualenv -p python3 env
source env/bin/activate
pip install -r requirements.txt

python -m host                 # the game, windowed
python -m host --headless --frames 900 --autostart --mode sprint --seed 7 --ai
python -m pytest tests/ -q     # the whole suite, headless
```

## The one-paragraph map

`host/pygame_host.py` publishes exactly sixteen primitives through the DSL's
declared `install_primitives` seam — painters, the clock, the event pump, the
speaker, the boot config. Everything else is Scheme in `scheme/`, loaded in
dependency order by `main.scm`:

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
├── policies/gravity.scm      (tetris gravity)  — pacing curves
├── presentation/view.scm     the painter (edge module)
├── conductor/arcade.scm      the shell: screens, input, AI, effects (edge)
└── main.scm                  loads contexts in order, runs (arcade-main)
```

The dependency direction is the design: **conductor → view/rules/content →
domain, and the domain imports nobody.** Chapters 1 and 8 are about why that
arrow pointing one way is the single most valuable property the codebase has.
