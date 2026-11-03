# Building a Game on a Scheme DSL — the tutorials

These tutorials teach game programming **on an embedded Scheme DSL**, using this
repository — a complete Tetris where Python owns only the window, the clock, the
pixels, and the speaker, and *everything else* runs on the DSL — as the running
example. Every code excerpt is quoted from the real files; every technique is
one the game actually relies on.

## How the series teaches

The chapters form one arc, in seven parts. Each chapter opens with
**where you are** and **what you will be able to do**, and closes with a
**checkpoint** — a one-line self-test. Read them in order the first time;
after that, each stands alone as a reference.

Alongside the reading you build a **running project**: a Breakout clone on the
same DSL, one piece per chapter — a boot and a paddle in chapter 1, a frame
loop in chapter 6, an AI in chapter 8, a purity fence in chapter 11, a
benchmark guard in chapter 13 — and the feel of chapters 14–16: a
multiball element, a brick-combo popup, and a pitch-graded shatter. The
exercises marked ⟡ are its steps; by the end you will have written a second,
smaller game in this style, and every technique will be something you have
*done*, not something you have *read*.

### Part I — Foundations (how the two worlds meet)

| # | Chapter | You learn |
|---|---------|-----------|
| 1 | [A language inside a language](01-the-seam.md) | The host/script seam, embedded runtimes, why the boundary is a list of 16 names |
| 2 | [Closed vocabularies](02-closed-vocabularies.md) | `define-variant` / `variant-match` — enums that fail loudly |
| 3 | [The railway](03-the-railway.md) | A Result monad from scratch, Kleisli composition, refusals as data |
| 4 | [Conditions](04-conditions.md) | `raise`/`guard` with named irritants; refusals vs conditions vs errors |

### Part II — The machine (building the game)

| # | Chapter | You learn |
|---|---------|-----------|
| 5 | [State as a value](05-state-as-a-value.md) | Immutable aggregates, copy-on-write grids, the randomizer as a value, the journal |
| 6 | [Frames and time](06-frames-and-time.md) | The game loop, gravity banking, the dirty flag, the host-side input pump |
| 7 | [The edge](07-the-edge.md) | Screens, menus, the effects rail, painters as pure reductions |

### Part III — Making it real (smart, proven, fast)

| # | Chapter | You learn |
|---|---------|-----------|
| 8 | [The one-ply planner](08-the-planner.md) | Profile arithmetic, placement scoring, the frame-budgeted search |
| 9 | [Testing a game with no mocks](09-testing.md) | The host as data, seeded playthroughs, the two-host transition walk, pitfalls, collecting test kits |
| 10 | [Performance in an interpreter](10-performance.md) | Where the milliseconds go, caches, quiet frames, the step budget |

### Part IV — The craft (naming what you have learned)

| # | Chapter | You learn |
|---|---------|-----------|
| 11 | [Bounded contexts](11-bounded-contexts.md) | DDD with `define-library`: closed scopes, the dependency DAG, the purity fence |
| 12 | [The six SRFIs](12-the-srfis.md) | SRFI 1/26/88/89/197/241 — where each earns its keep, and the judgment calls |
| 13 | [Hot paths](13-hot-paths.md) | The three slowdown traps of a tree-walking interpreter, worst-case harnesses, benchmark guards with justified bounds |

### Part V — The feel (making it fun, and keeping it honest)

| # | Chapter | You learn |
|---|---------|-----------|
| 14 | [Building gameplay elements](14-gameplay-elements.md) | Modes as closed variants, one rule two customers, per-mode scoring policies, the journal announces the moment |
| 15 | [The moving edge](15-game-animations.md) | The animation rail dissected pop by pop, escalation with ceilings, the repaint gate answers visibility, type scales text never |
| 16 | [The mixing desk](16-game-sound.md) | Generated tones as table rows, the ranking mix, the announcer overlay, escalation without a siren, silence as a decision |

### Part VI — The loop that watches (closing the second loop)

| # | Chapter | You learn |
|---|---------|-----------|
| 17 | [The director](17-the-director.md) | Telemetry probes with documented ranges, the pressure band, pacing as a field of the match, A/B runs under a seed |

### Part VII — The opponent (two loops, one fight)

| # | Chapter | You learn |
|---|---------|-----------|
| 18 | [The duel](18-the-duel.md) | Garbage as a domain arrow from the match's own random stream, the attack table as data, the offset rule, the duel as a pure value, AI-vs-AI self-play under a seed |
| 19 | [The roster](19-the-roster.md) | Opponents as content, the planner's style term, the speed knob as the honest difficulty lever, personalities pinned by a seeded sweep |
| 20 | [The profile](20-the-profile.md) | Growing a closed seam, a versioned document at the edge with the meaning on the script side, atomic writes, save points as semantic moments, the failure posture of a save file |
| 21 | [Versus](21-versus.md) | Measuring the painter before the layout, the batch primitive that earned its place on the seam, two boards from one painter, the persona ladder as a menu, a human in the circuit |


## What the root README flexes → where the series teaches it

| The flex | The chapters |
|---|---|
| **DDD** (bounded contexts, dependency direction, purity fence) | [1](01-the-seam.md), [11](11-bounded-contexts.md) |
| **Typed control flow** (`define-variant` / `variant-match`) | [2](02-closed-vocabularies.md) |
| **ROP** (every transition a Kleisli arrow) | [3](03-the-railway.md) |
| **Monadic pipelines** (one `result-bind`, do-notation, traversals) | [3](03-the-railway.md), [6](06-frames-and-time.md) (gravity through the railway) |
| **Conditions** (raise by name, guard at the conductor) | [4](04-conditions.md) |
| **Functional programming** (the session as a value, journal as data) | [5](05-state-as-a-value.md), [6](06-frames-and-time.md) |
| **SRFI 1** (folds, `every`, `find`, `count`, `iota`, `list-index`) | [12](12-the-srfis.md) (§12.1), [5](05-state-as-a-value.md) |
| **SRFI 26** (`cut` specializes arrows) | [12](12-the-srfis.md) (§12.2), [3](03-the-railway.md) |
| **SRFI 88** (keywords name the tables and event keys) | [12](12-the-srfis.md) (§12.3), [7](07-the-edge.md) |
| **SRFI 89** (`define*` gives the difficulty surface its knobs) | [12](12-the-srfis.md) (§12.4), [5](05-state-as-a-value.md) |
| **SRFI 197** (`chain` shapes the pixel pipelines) | [12](12-the-srfis.md) (§12.5), [7](07-the-edge.md), [13](13-hot-paths.md) (§13.2 — where it does *not* belong) |
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

`host/pygame_host.py` publishes exactly nineteen primitives through the DSL's
declared `install_primitives` seam — painters, the clock, the event pump, the
speaker, the boot config, the profile document. Everything else is Scheme in `scheme/`, loaded in
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
├── conductor/
│   ├── effects.scm           the effects rail: speaker policy, screen awards (edge)
│   ├── screens.scm           the menu values, the screens, the menu input (edge)
│   ├── input.scm             the key dispatch: events, keys, repeats (edge)
│   └── arcade.scm            the conductor: session state, match lifecycle, AI, loop (edge)
└── main.scm                  loads contexts in order, runs (arcade-main)
```

The dependency direction is the design: **conductor → view/rules/content →
domain, and the domain imports nobody.** Chapters 1 and 11 are about why that
arrow pointing one way is the single most valuable property the codebase has.
