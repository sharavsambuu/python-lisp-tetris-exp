# tests/ — the tests are Scheme; Python is the light switch

The game is Scheme, so the tests are Scheme. Every suite in `tests/scm/` —
unit checks over the pure domain, whole-match playthroughs, screen behavior,
the shell's transition table — is written in the DSL and run by the DSL.
Python remains only where it is the runtime, not the test: booting the
interpreter, one budget knob, and the pixels only SDL can prove.

```
tests/
├── scm/                        the suites themselves — Scheme
│   ├── testkit.scm             the assertion kit: collect failures, report, raise
│   ├── fake-host.scm           the host, as data: all 16 primitives in Scheme
│   ├── domain-tests.scm        the pure domain, headless
│   ├── gameplay-tests.scm      whole matches through the real conductor loop
│   ├── ui-tests.scm            screens asserted against the draw-call log
│   ├── shell-tests.scm         every screen transition, keys through the queue
│   └── run-all.scm             the Scheme-side runner: one interpreter, all suites
├── test_scheme.py              pytest as bootstrap: fresh env + step budget per suite
├── test_shell_traversal.py     the shell walked through scripted keyword events
├── test_menu_transitions.py    the same transition map through the REAL pygame pump
└── test_host_smoke.py          the real SDL edge: subprocess runs, a pixel test
```

# The two hosts

The edge modules speak to eighteen primitives (`open-window!`, `tick!`,
`poll-events!`, `draw-rect!`, `sfx!`, …). The tests implement that contract
**twice**:

- **`fake-host.scm`** — the same eighteen names in pure Scheme. Every painter
  call is recorded in `*host-log*`; events are queued as the same
  `type:`/`key:` alists the real pump builds; the clock answers scripted dt
  values; and the DAS/ARR repeat pump runs the same cadence and the same
  66 ms clamp as `pygame_host.py`. No pygame, no window, no seam — the whole
  arcade loop runs in Scheme.
- **`host/pygame_host.py`** — the real edge. A few tests drive it (SDL's
  dummy drivers headless) because a fake, however faithful, proves the
  *sequence* of draw calls; only the real host proves the calls *land*.

This is not mocking — it is a second implementation of the contract, and the
disagreements between the two suites are findings, not noise. (Real example:
the fake host once kept a pressed key's repeat countdown forever, because
nothing releases it — a physical keyboard sends KEYUP. The flood of stale
`key-repeat` events buried every later press. That is why menu traversal uses
`host-tap!` and only the DAS tests use `host-type!`.)

# The suites

| suite | runs against | asserts on | failure style |
|---|---|---|---|
| `domain-tests.scm` | nothing — pure calls | values and invariants | raises on first failure |
| `gameplay-tests.scm` | the real conductor loop + fake host | match state, phases, sfx log | kit: collected, reported |
| `ui-tests.scm` | screens + fake host | which texts painted where, fit in the window | kit: collected, reported |
| `shell-tests.scm` | the shell + fake host | `*screen*` and the phase after every key | kit: collected, reported |

`testkit.scm` is the shared kit: `tk-check`/`tk-assert` (sugared per suite —
`define-syntax` does not cross a file boundary in this loader) record pass
and fail; `tk-report!` prints the tally and raises if anything failed, so a
clean load is still the green light. `domain-tests` predates the kit and
raises on the first surprise; either way, **no output is not success** — a
suite ends with a printed verdict or a red exception.


# Run them

```sh
# everything (the CI door):
python -m pytest tests/ -q

# the fast loop: pure domain + purity fence + shell traversal, seconds not
# minutes — skips the whole-match walks and the subprocess smoke runs:
python -m pytest tests/ -m "not slow" -q

# everything, including the full run-all walk (it re-runs every Scheme
# suite under one interpreter, so the default run skips it):
SCHEME_RUN_ALL=1 python -m pytest tests/ -q

# the Scheme suites, orchestrated by Scheme (no pytest in the loop):
SHS_PATH=scheme:tests/scm env/bin/shs run tests/scm/run-all.scm

# one suite, straight through the interpreter:
SHS_PATH=scheme:tests/scm env/bin/shs run tests/scm/ui-tests.scm
```

The `slow` marker (registered in `pytest.ini`) covers the suites that play
whole matches or boot real subprocesses: the gameplay/shell Scheme walks,
the painter bench, and all of `test_host_smoke.py`. The fast loop is for
iterating; the CI door still runs everything.

The step budget, honestly: the interpreter charges each top-level form its
own hang-detector budget (5M steps by default), and that raise is *not* a
Scheme condition — a hang detector the program could `guard` away would be
no detector at all. Whole-match simulations (the AI steering a sprint,
gravity slam after gravity slam) cost millions of steps per form, so the
pytest bootstrap raises the ceiling (`lisp.evaluator.STEPS_BUDGET`: 50M per
suite, 500M for `run-all`'s whole walk). Under a bare `shs run`, suites whose
heaviest form fits the default budget pass today (`ui-tests`); the rest stop
with `LispBudgetError` — the interpreter refusing to look hung, not a test
failure. The permanent fix is a `--budget` flag on the interpreter CLI
(upstream); until then, the pytest bootstrap owns the knob.

# Scripting a playthrough

The fake host's scripting vocabulary, all Scheme:

```scheme
(host-tap! "return")            ; press, one frame, pump entry cleared — a keypress
(host-type! "left")             ; press and HOLD — the DAS tests want the repeats
(host-release! "left")
(host-clock! 1000 2000)         ; the next 2000 frames advance 1000ms each
(host-run-frames! 60)           ; the real loop, n frames
(host-run-while-playing! 2400)  ; the loop until a win, a loss, or the budget
(host-queue-quit!)              ; a quit event, the way the window manager sends one
```

And reading what the game did with it:

```scheme
(host-text-strings)             ; every string the painter drew, oldest first
(host-sfx-names)                ; every blip, in order — the effects rail as data
(host-ops 'rect)                ; every rect call
(host-fits-window? entry)       ; nothing painted outside the viewport
```

Assertions read like behavior, not like code under test:

```scheme
(tk-check "esc after a game over reaches the title" (screen) 'title)
(tk-assert "the victory was announced" (member "victory" (host-sfx-names)))
```

# Where Python makes sense

Three jobs, and no fourth:

1. **Booting the interpreter.** `make_env()` + `load_lisp()` is the metal.
   `test_scheme.py` is four lines per suite: fresh environment, budget up,
   load. No test logic.
2. **The step budget.** See above — a host-embedding decision, made once in
   the bootstrap.
3. **The real SDL edge.** `test_host_smoke.py` launches `python -m host` as a
   subprocess (the smoke runs) and reads pixels back from a dummy-driver
   framebuffer (`test_painter_paints`). If it can be faked, it lives in
   `tests/scm/`; if it needs a real window system, it lives here — kept
   deliberately thin.

Plus one deliberate overlap: `test_menu_transitions.py` walks the shell's
whole transition map through the *real* pygame pump (real keycodes, real
KEYDOWN/KEYUP pairs) while `shell-tests.scm` walks the same map through the
fake. The conductor's dispatch is checked against both hosts; wherever the
two disagree, one of the hosts is lying, and the suite tells you which.

# Which suite for a new test?

- A pure function, invariant, or refusal → `domain-tests.scm`.
- Match behavior a player would notice (DAS rhythm, scoring chains, a won
  ladder, the way out of a finished match) → `gameplay-tests.scm`.
- What a screen paints and whether it fits → `ui-tests.scm`.
- Which key goes to which screen → `shell-tests.scm`; add the real-pump
  twin in `test_menu_transitions.py` if the finding is about the host's
  event shape.
- Pixels or process launch → `test_host_smoke.py`, sparingly — one painted
  frame is worth fifty mocked ones, and fifty is too many.
