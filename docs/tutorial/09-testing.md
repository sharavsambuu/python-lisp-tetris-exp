# Chapter 9 — Testing a game with no mocks

*The files it dissects: `tests/scm/fake-host.scm`, `tests/scm/testkit.scm`,
`tests/scm/gameplay-tests.scm`, `tests/scm/shell-tests.scm`,
`tests/scm/run-all.scm`, `tests/test_scheme.py`, and the real-pump twin
`tests/test_menu_transitions.py`.*

> **Where you are.** Chapters 1–8 built a complete, smart, visible game.
> Before optimizing anything (chapter 10), you make it *provable*. Everything
> you built — the pump, the journal, the pipeline — is testable, and this
> chapter shows how.
>
> **By the end of this chapter you can** implement a host contract twice
> (real + fake), write playthrough tests with seeded clocks, walk the same
> transition map through both hosts, and choose between unit, playthrough,
> log, transition, and pixel assertions.
>
> **The running project.** Breakout's bounce contract becomes a test: ball
> hits wall, direction flips, no frames lost.

Chapter 1 promised that a closed seam makes the game testable. This chapter
collects the debt: the entire game runs headless in pure Scheme, against a
**fake host that is itself Scheme**, and the tests read like playthroughs.

## 9.1 The host, as data

`tests/scm/fake-host.scm` defines all sixteen host primitives in Scheme,
shadowing the Python ones the pytest harness installed:

```scheme
;;; tests/scm/fake-host.scm — the host, as data.
;;;
;;; The edge modules (presentation/view, the four conductor files) speak to
;;; sixteen host primitives. This file DEFINES ALL SIXTEEN in Scheme, shadowing the
;;; Python ones the pytest harness installed, so the whole arcade loop runs
;;; in pure Scheme: no pygame, no SDL dummy driver, no seam. Every painter
;;; call is recorded in `*host-log*`, so UI behavior is asserted against a
;;; draw-call log instead of pixels — a layout tweak moves log entries, not
;;; test coordinates.
```

The recording fakes answer exactly what the real host answers — poll events
are the same alists keyed by the `type:`/`key:` keywords, an empty queue is
the Scheme empty list, `text-width` is the same `length×size/2` measure:

```scheme
(define (draw-text! x y s size rgb) (host-log! 'text x y s size rgb))

(define (text-width s size)
  ;; Same honest measure the headless host uses: half the type size per
  ;; glyph. The real painter's font differs; the *fit* invariant does not.
  (* (string-length s) (quotient size 2)))
```

This is not a mock in the mocking-framework sense — it is a **second
implementation of the contract**, and the fake's fidelity is what makes the
tests honest. Note the comment discipline: wherever the fake makes a choice
(the text-width measure), the comment names which part is the *contract* and
which is the *coincidence*.

## 9.2 Scripting the world

The fake host exposes a small scripting vocabulary — and the distinction
between its two "press a key" verbs is the chapter's best fidelity lesson:

```scheme
;; Queue one key-down: the alist shape the real host builds. A press also
;; seeds the repeat pump's countdown for that key — DAS starts at the press.
(define (host-press! key) ...)
(define (host-release! key) ...)
(define (host-clock! dt n) ...)          ;; the next n frames advance dt each
(define (host-run-frames! n) ...)        ;; run the real loop for n frames
(define (host-run-while-playing! n) ...) ;; run until a win or a loss
(define (host-type! key) ...)            ;; press AND HOLD — the DAS tests
                                         ;;   want the repeats it fires
(define (host-tap! key) ...)             ;; press, one frame, pump entry
                                         ;;   cleared — a physical keypress
(define (host-queue-quit!) ...)          ;; a quit, as the WM sends one
```

Why two verbs? Because `host-press!` seeds the repeat pump and nothing
releases it — a *fake* has no keyup unless something queues one, and a
physical keyboard always does. The first menu-traversal suite used the hold
verb everywhere, and the stale pump entries fired repeat floods for the rest
of the run — burying later presses in the queue, so the ESC tests failed in
ways the real game could not reproduce. The fix is not a tweak, it is a
second verb with a contract:

```scheme
;; A quick tap: press, one frame, then the pump's countdown for that key is
;; cleared. A physical key's KEYUP lands between frames, so a tap never
;; reaches the DAS delay and never repeats. ...
;; (`host-type!` keeps the hold — that is what the DAS tests want; a menu
;; traversal wants taps, or stale entries fire repeat floods for the rest
;; of the run and bury later presses.)
(define (host-tap! key)
  (host-type! key)
  (set! *host-held-clock*
        (filter (lambda (e) (not (string=? (car e) key)))
                *host-held-clock*)))
```

The scar generalizes: **a fake must model not just what the real host does
but what the physical world does between frames** — a KEYUP is world
behavior, not host behavior, and the first fake omitted it. The DAS tests
use `host-type!`; every menu traversal uses `host-tap!`.

The read-back side is a log, and the log is queried, not dumped:

```scheme
(define (host-ops op) ...)        ;; every log entry for one op, oldest first
(define (host-text-strings) ...)  ;; every string the painter drew
(define (host-sfx-names) ...)     ;; every blip, in order — the effects rail
(define (host-fits-window? e) ...) ;; nothing painted outside the viewport
```

And the fake host implements the **same repeat pump** as the real one
(chapter 6), including the dt clamp:

```scheme
;; The same clamp the real host runs: a fat test clock must not bill a
;; 1000ms frame to the repeat pump — it would fire a burst of catch-up
;; repeats that floods the queue ahead of real presses.
(set! dt (min dt 66))
```

That last clamp is a scar: the game-over test feeds a 1000ms-per-frame clock,
and the unclamped pump once fired ~25 catch-up repeats per press — flooding
the event queue ahead of real presses. **Whenever the fake and the real host
share a timing behavior, test through the fake only if the fake clamps like
the real thing.**


## 9.3 A playthrough is a test

The DAS contract, end to end (`tests/scm/gameplay-tests.scm`):

```scheme
;; Holding left, from a fresh match so the repeat clock starts at zero.
;; The press frame fires one move and starts the clock; the pump lives in
;; the HOST (the reference edge's design): the delay is 150ms and the
;; interval 40ms. So: 8 frames (128ms) — one move, nothing more — then 4
;; more frames (192ms on the clock) — repeats fire. That is the whole DAS
;; contract, and it holds no matter which piece spawned (a wall would
;; clamp a naive "n columns" claim).
(boot-into! 'marathon '())
(let* ((x0 (falling-x (game-active *st*))))
  (host-press! "left")            ; the press is this frame's event
  (host-clock! 16 8)              ; 8 frames = 128ms, inside the delay
  (host-run-frames! 8)
  (let ((held-x (falling-x (game-active *st*))))
    (tk-check "the press moved one column, and no repeat has fired"
              (- x0 held-x) 1)
    (host-clock! 16 4)            ; 4 more frames = 192ms on the clock
    (host-run-frames! 4)
    (tk-check "past the delay, the repeat fires"
              (< (falling-x (game-active *st*)) held-x) #t)
    (host-release! "left")
    (host-run-frames! 1)          ; the release takes its own frame
    (tk-assert "the piece is still on the board" (game-active *st*))))
```

Notice what the test *doesn't* assert: "moved 3 columns." A wall would make
that assertion lie. It asserts the **contract** — one move inside the delay,
further movement past it — which holds for any piece at any wall.

## 9.4 The kit that collects failures

`tests/scm/testkit.scm` is a tiny assertion library with one design decision:
**collect, don't stop.**

```scheme
;; Unlike the domain tests (which raise on the first failure), this kit
;; COLLECTS failures: a UI or gameplay suite has many independent checks,
;; and a red suite should say everything it saw, not just its first
;; surprise. `tk-report!` ends the file: it prints the tally and raises if
;; anything failed, so a clean load is still the green light.
```

The report names each failure with actual and expected values — and the whole
report prints before the raise, because the *point* of a game test failing is
the story of the match, not the first wrong pixel.

One loader quirk is documented in the file and worth knowing for your own
DSL: `define-syntax` does not cross a file boundary here, but procedures do.
So the sugar (`tk-check`/`tk-assert`) is re-defined as a two-line macro in
each suite, and all the state lives in the kit.

## 9.5 The whole shell, walked twice

The gameplay suite proves what a *match* does. The shell — which key goes to
which screen — gets its own suite, `shell-tests.scm`, and it teaches two
tricks beyond the playthroughs.

**The first trick: walk the same map through both hosts.** The shell's
transition table is checked by two suites that differ in exactly one thing —
the host:

- `shell-tests.scm` walks it through the fake host: queued alists, the
  scripted clock, the log;
- `test_menu_transitions.py` walks the *same* map through the REAL pygame
  pump: real keycodes, real KEYDOWN/KEYUP pairs, SDL's dummy driver.

The conductor's dispatch is thus checked against two independent
implementations of the event contract. Wherever the two suites disagree,
one of the hosts is lying — and the suite tells you which. (This is how the
tap-vs-type scar of §9.2 was found: the fake's event queue diverged from a
physical keyboard's, and the disagreement *was* the bug report.)

**The second trick: make the bug's precondition constructible.** Some bugs
are hard to reach through play. The result-screen journal bug (a dropped
`drain-journal!` return value that replayed the victory every frame) lives
only when a terminal phase holds an unread fact — a state normal play
always drains before the phase flips. So the regression test *constructs*
the precondition directly:

```scheme
;; The result screen reads the journal exactly once: a terminal fact is
;; announced on the frame it lands and never again, however long the
;; result sits. The journal must actually DRAIN — a dropped
;; `drain-journal!` return value here repainted the screen and replayed
;; the victory every frame, machine-gun style.
(boot-into! 'sprint '((target-lines 1)))
(set! *st* (with-event (game-with *st* phase: (won)) (victory)))
(host-run-frames! 10)
(tk-check "the victory is heard exactly once"
          (count (cut string=? "victory" <>) (host-sfx-names)) 1)
(tk-assert "the result journal drained" (null? (game-journal *st*)))
```

Ten result frames; the victory must be heard exactly once. Before the fix
this printed ten. The test is honest precisely because the state is forced:
state is a value, so `(game-with *st* phase: (won))` is not a mock — it is
the real state, one fact short of drained. The same suite keeps forcing
helpers for the other hard-to-reach states: `win-now!` (a victory with the
recipe kept) and `play-until-over!` (slam pieces into the spawn column
until top-out — no steering, a fat clock, gravity fills the well).

## 9.6 Choosing the level

With five suites in the drawer, the question is which one a new test
belongs in. The answer is the *level* of the claim:

| The claim is about… | The suite | Asserts against |
|---|---|---|
| a pure function, invariant, or refusal | `domain-tests.scm` | values, directly |
| behavior a player would feel (DAS rhythm, a scoring chain, a won ladder) | `gameplay-tests.scm` | match state, phases, the sfx log |
| what a screen paints and whether it fits | `ui-tests.scm` | the draw-call log |
| which key goes to which screen | `shell-tests.scm` | `*screen*` and the phase after every key |
| that the draw calls *land* | `test_host_smoke.py` | real pixels, real process |
| that a hot path *stays* fast | the benchmark guard (chapter 13) | wall-clock with justified bounds |

Two rules keep the drawer tidy. **Climb only as high as the claim**: a
screen-transition bug does not need a pixel test, and a scoring bug does
not need the real pump. And **when the finding is about the host's event
shape, add the twin** — the fake-host check plus the real-pump twin in
`test_menu_transitions.py`, so the contract is pinned from both sides.

## 9.7 Pitfalls, one scar each

The strategy above is the positive space. These are the negative — each one
a way a DSL test suite lies to you, each learned the hard way:

- **A test that leans on the previous test's state is a test that breaks
  when reordered.** The conductor is top-level `set!` state, and the loader
  runs suites in one shared environment — so every section opens with the
  ritual (`boot-fresh!` / `boot-into!`), and no assertion may reach back
  past it. The state is a value; build the one the claim needs.
- **Membership checks cannot see repetition.** The original victory check
  was `(member "victory" (host-sfx-names))` — and it *passed* while the
  journal-drain bug replayed the sound three times. Repetition is a failure
  mode; count, don't just search:

  ```scheme
  (tk-check "the victory is heard exactly once"
            (count (cut string=? "victory" <>) (host-sfx-names)) 1)
  ```

- **A clean load is the green light — so make silence impossible.** A suite
  that loads and prints nothing has proven nothing: the kit's `tk-report!`
  prints a verdict, and the domain suite raises on the first surprise. If
  your harness can exit green with no output, it will, eventually, proudly.
- **The step budget is per top-level form — in the harness.** A suite that
  passes alone can die under the orchestrator after an innocent edit makes
  its heaviest form heavier — and the raise is uncatchable by `guard`
  (chapter 13 §13.7). The raise lives in the bootstrap; know which form is
  your heaviest. (In production the story is different: the host's `tick!`
  resets the counter once per frame, so the game's budget is per frame —
  chapter 10 §10.4. The harness has no frame boundary, so its budget is
  still per form.)
- **Enumerate the closed vocabularies.** `define-variant` makes a forgotten
  dispatch arm a named error at runtime — but only if something *reaches*
  that arm. The dead `sfx-command!` table survived because no test walked
  every command and asked what it sounds like. A loop over the variant's
  constructors is the cheapest fence you will ever write.
- **A textual fence is a weak fence.** The purity test greps forbidden
  substrings, so it false-positives on a comment and cannot see a smuggled
  `(import ...)`. Keep it as a tripwire, but trust the closed library
  scopes — the compiler-enforced boundary — not the grep.
- **Assert the invariant, not the incident.** "The journal is empty after
  any painted frame" would have caught the drain bug in every suite at
  once; the incident-specific test catches it once. Where a scar has a
  general shape, pin the shape.

## 9.8 The pytest harness, and the Scheme-side runner

`tests/test_scheme.py` drives the Scheme files from Python:

```python
def test_gameplay_behavior():
    """Whole matches through the real conductor loop, against the fake host."""
    _load("gameplay-tests.scm", extra_paths=[TESTS])
```

The harness's job is minimal — build an environment with the search paths,
load the file, and let `tk-report!`'s raise be the pass/fail. It installs
*nothing*: the fake host defines all sixteen primitives in Scheme, so the
suites never see a Python-installed name. The *content* of testing lives in
Scheme, next to the code it tests. Keep it that way: a test suite split
across two languages ages badly unless the Python side is dumb glue.

The whole harness is one helper, plus the fixture that keeps suites from
leaking their ceiling into each other:

```python
# tests/test_scheme.py — the Scheme suites, headless.
#
# Each suite runs through the DSL with no pygame: the checks themselves
# raise (or the testkit reports), so a clean load *is* the green light.

@pytest.fixture(autouse=True)
def _restore_step_budget():
    """Snapshot the interpreter's step budget around every test."""
    saved = lisp.evaluator.STEPS_BUDGET
    yield
    lisp.evaluator.STEPS_BUDGET = saved

def _load(name, extra_paths=(), budget=DEFAULT_BUDGET):
    lisp.evaluator.STEPS_BUDGET = budget
    env = make_env(search_paths=[SCHEME, *extra_paths])
    load_lisp(env, TESTS / name)
    assert env is not None
```

The budget line deserves its own comment (it has one in the file): the domain
tests steer a whole sprint match through the one-ply planner — hundreds of
thousands of interpreter steps in one top-level form. The interpreter's
default 5M-step budget is a *per-frame hang detector* in production (the
host's `tick!` resets the counter each frame — chapter 10 §10.4); a test that
*is* a long computation in one form asks for more. The number lives in the
harness, not in the game, so a stuck game loop still dies loudly — `_load`
raises it per suite, and the autouse fixture restores it afterwards, so one
suite's ceiling can never leak into another's.

The suites that play whole matches or boot real subprocesses carry a `slow`
marker (registered in `pytest.ini`), so the iteration loop stays fast:

```
python -m pytest tests/ -m "not slow" -q     # seconds, not minutes
python -m pytest tests/ -q                   # the CI door: everything
```

And the glue is thinner than it looks, because the suites can run *without*
pytest at all. `tests/scm/run-all.scm` is a Scheme-side orchestrator: one
interpreter, all four suites, each wrapped in a `guard` with a tally and an
honest exit code —

```
SHS_PATH=scheme:tests/scm env/bin/shs run tests/scm/run-all.scm
```

— which is the proof that pytest is the bootstrap, not the framework. Under
pytest, the orchestration is itself a test, gated behind `SCHEME_RUN_ALL=1`
because it re-runs every suite (the walk is slow; the suites already ran
above it). One more guard lives in the same file:
`test_painter_keeps_up_with_a_full_board` times `draw-board!` on a crafted
full board — a benchmark with committed bounds, whose craft is chapter 13's.

Two more tests worth reading in `test_scheme.py`:

- **the purity fence** — the domain libraries never touch a host primitive;
- **the monad laws** — the railway's three properties, pinned so a refactor
  of `result-bind` cannot silently break composition.

And the deepest suite, `domain-tests.scm`, shows the *character* of DSL
testing: assertions as sentences, one behavior each. A sample from the board
section:

```scheme
(define b0 (make-board))
(assert "a new board is empty" (board-empty? b0))

;; Fill the bottom row across all ten columns: full, then clear.
(define b1
  (board-place b0 'i (map (lambda (x) (cons x 19)) (iota matrix-width))))
(assert "the row is full now" (equal? (full-rows b1) '(19)))
(assert "the original board is untouched" (board-empty? b0))
```

Even the monad laws read as behavior, not as category theory:

```scheme
(define (halve n) (if (even? n) (ok (/ n 2)) (err "odd")))
```

…then left identity, right identity, and associativity are asserted over
`halve` — three `check`s that would catch a `result-bind` that ran the next
arrow on failures, or dropped the carried value. When a law has a concrete
witness like `halve`, a failure message points at the *behavior* that broke,
not at a Greek letter.

## 9.9 Pixel tests, for the one thing fakes can't see

`tests/test_host_smoke.py::test_painter_paints` boots the REAL host with the
SDL dummy driver, plays to a live match, paints one frame, and reads pixels:

```python
assert surf.get_at((5, 5))[:3] == (16, 16, 22), "background not painted"
assert surf.get_at((188, 58))[:3] == (110, 110, 135), "well frame missing"
```

Use these sparingly — they are brittle by nature — but keep a few: the fake
host proves the *sequence* of draw calls; only the real host proves the calls
*land*. One painted frame is worth fifty mocked ones.

## Exercises

0. ⟡ **Running project.** Test Breakout's bounce contract through a fake
   host: ball reaches the wall, direction flips, no frames lost — with a
   seeded clock so the ball path is a value you can steer. Assert on the
   journal facts, not on pixels.
1. The fake host's `tint!` records rgb lists. Write the test for chapter 7's
   exercise 1 (a level-up flash) against that log.
2. `host-clock! 1000 2000` feeds a fat clock. Find every test that relies on
   the clamp and write the one that would catch its removal.
3. Add `host-screenshot!` to the fake host that returns the draw log as a
   canonical string, and snapshot-test the title screen's layout.
4. Take one of the shell's transitions and write its real-pump twin in
   `test_menu_transitions.py`. Then break the conductor's dispatch for that
   key on purpose, and check which of the two suites catches it — and
   whether both name the same lie.

---

✓ **Checkpoint.** You can fake a host contract faithfully, script a seeded
  playthrough test, walk a transition map through both hosts, and pick the
  right assertion level — unit, playthrough, log, transition, or pixel —
  for what you are proving.

*Next: [Performance in an interpreter](10-performance.md) — where the
milliseconds go.*
