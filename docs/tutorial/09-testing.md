# Chapter 9 — Testing a game with no mocks

*The files it dissects: `tests/scm/fake-host.scm`, `tests/scm/testkit.scm`,
`tests/scm/gameplay-tests.scm`, `tests/test_scheme.py`.*

> **Where you are.** Chapters 1–8 built a complete, smart, visible game.
> Before optimizing anything (chapter 10), you make it *provable*. Everything
> you built — the pump, the journal, the pipeline — is testable, and this
> chapter shows how.
>
> **By the end of this chapter you can** implement a host contract twice
> (real + fake), write playthrough tests with seeded clocks, and choose
> between log assertions, contract tests, and pixel tests.
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
;;; The edge modules speak to sixteen host primitives. This file DEFINES
;;; ALL SIXTEEN in Scheme, shadowing the Python ones the pytest harness
;;; installed, so the whole arcade loop runs in pure Scheme: no pygame,
;;; no SDL dummy driver, no seam. Every painter call is recorded in
;;; `*host-log*`, so UI behavior is asserted against a draw-call log
;;; instead of pixels.
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

The fake host exposes a small scripting vocabulary:

```scheme
;; Queue one key-down: the alist shape the real host builds. A press also
;; seeds the repeat pump's countdown for that key — DAS starts at the press.
(define (host-press! key) ...)
(define (host-release! key) ...)
(define (host-clock! dt n) ...)          ;; the next n frames advance dt each
(define (host-run-frames! n) ...)        ;; run the real loop for n frames
(define (host-run-while-playing! n) ...) ;; run until a win or a loss
(define (host-type! key) ...)            ;; press a key, give it one frame
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

## 9.5 The pytest harness

`tests/test_scheme.py` drives the Scheme files from Python:

```python
def test_gameplay_behavior():
    """The whole input → command → rules → presentation loop, headless."""
    _load("gameplay-tests.scm", extra_paths=[TESTS])
```

The harness's job is minimal — build an environment with the search paths,
install the real host primitives, load the file, and let `tk-report!`'s raise
be the pass/fail. The *content* of testing lives in Scheme, next to the code
it tests. Keep it that way: a test suite split across two languages ages
badly unless the Python side is dumb glue.

Two more tests worth reading in `test_scheme.py`:

- **the purity fence** — the domain libraries never touch a host primitive;
- **the monad laws** — the railway's three properties, pinned so a refactor
  of `result-bind` cannot silently break composition.

## 9.6 Pixel tests, for the one thing fakes can't see

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

---

✓ **Checkpoint.** You can fake a host contract faithfully, script a seeded
  playthrough test, and pick the right assertion level — log, contract, or
  pixel — for what you are proving.

*Next: [Performance in an interpreter](10-performance.md) — where the
milliseconds go.*
