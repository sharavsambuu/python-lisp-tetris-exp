# Chapter 13 — Hot paths: Scheme that keeps the frame

*The files it dissects: `scheme/presentation/view.scm` (the painter),
`scheme/conductor/arcade.scm` (the planner and the loop), and
`tests/scm/bench-view.scm` (the harness that caught them).*

> **Where you are.** Chapter 10 fixed the host's half of the frame budget —
> the caches, the quiet frames, the seam. Then a player report arrived that
> no host fix could touch: *as the board fills, the game crawls.* This
> chapter is the interpreter's half, learned from that bug and two like it.
>
> **By the end of this chapter you can** read a slowdown's signature from a
> player report, name the three traps that cause it in a tree-walking
> interpreter, build a worst-case benchmark harness, and guard a hot path
> with a test whose bounds are justified by measurement.
>
> **The running project.** Profile one Breakout hot path with the harness
> from §13.1, fix it with one of the three moves, and pin it with a
> benchmark test.

A tree-walking interpreter has an alien cost profile: there is no malloc
storm and no SIMD — there is **per-node dispatch**, and the constant per
*call* is enormous. The consequence inverts your instincts: the algorithm's
big-O class matters less than the *count of interpreter calls* a frame makes.
Every trap in this chapter is a way that count quietly exploded, and every
fix is a way to bring it back down. All numbers are measured, not estimated,
with the harness in §13.1.

## 13.1 The signature: a slowdown that grows with the state

The report was one sentence — *"when the board fills with bricks, the game
slows down hard"* — and it was already half a diagnosis. Work that grows
with the state means something in the frame path is priced per cell, per
row, or per fact. In this game the suspects are few: the painter, the
busy-check that gates repainting, and the planner.

But suspicion is not measurement. The discipline is a **worst-case harness**:
craft the extreme state deliberately, then time `run()` from Python around
it — the interpreter's cost, isolated from SDL's. `tests/scm/bench-view.scm`
is exactly that: boot a real match through the fake host, then fill every
cell of every row. The timing side is plain Python — one warm call, then
the average:

```python
run("(draw-board! *st*)", env)               # warm
t0 = time.perf_counter()
for _ in range(5):
    run("(draw-board! *st*)", env)
per_call_ms = (time.perf_counter() - t0) / 5 * 1000
```

The before numbers, on a 200-cell board: `draw-board!` **289 ms**, a full
`arcade-step!` frame **333 ms**, `px` **0.69 ms per call**, `stack-top`
**11.6 ms**, `view-busy?` **8.0 ms**. A 16.67 ms frame budget against a
333 ms frame — the game was not degrading, it had fallen off a cliff. Three
traps explain all of it.

## 13.2 Trap 1 — macro sugar in an inner loop

The painter's grid-to-pixel converters were written as SRFI 197 pipelines,
because the data does flow left to right — scale, offset, shake:

```scheme
;; BEFORE — pedagogically nice, catastrophically placed.
(define (px x) (chain x (* _ (lay cell:)) (+ (lay board-x:) _ (shake-offset))))
(define (py y) (chain y (* _ (lay cell:)) (+ (lay board-y:) _ (shake-offset))))
```

`chain` is a macro: every call expands into nested lambdas, and a
tree-walking interpreter *re-walks that expansion on every call* — **0.69 ms**
against **0.026 ms** for the plain arithmetic. Now multiply: a full board
draws 200 settled cells, each calling `px` and `py` — ~400 chain calls,
~270 ms of pure sugar before a single rectangle is drawn. The fix is not a
ban on `chain`; it is a placement rule:

> **`chain` is for pipelines that run once. An inner loop pays for its
> sugar on every call** — a hot `px` is plain arithmetic, with the order in
> a comment.

```scheme
;; AFTER — the order lives in the comment now, the cost lives in the frame.
(define (px x) (+ (lay board-x:) (* x (lay cell:)) (shake-offset)))
(define (py y) (+ (lay board-y:) (* y (lay cell:)) (shake-offset)))
```

The same move hoists the loop invariants. `draw-board!` read the layout
(`lay cell:`, `board-x:`, the shake) *per cell*; the hot version reads them
once, and the body is one multiply, two adds, and the seam crossing:

```scheme
(define (draw-board! st)
  ;; The hot path: one call per settled cell per repaint. The layout
  ;; reads and the shake are hoisted out of the loop — the body is one
  ;; multiply, two adds, and the seam crossing.
  (let* ((cell (lay cell:))
         (s (- cell 1))
         (ox (+ (lay board-x:) (shake-offset)))
         (oy (+ (lay board-y:) (shake-offset))))
    (for-each
     (lambda (entry)
       (let ((pos (car entry)) (name (cdr entry)))
         (draw-rect! (+ ox (* (car pos) cell))
                     (+ oy (* (cdr pos) cell))
                     s s (piece-color name))))
     (board-cells (game-board st)))))
```

**How to spot it:** estimate *calls per frame × per-call overhead*. Sugar
(`chain`, `cut`, composed arrows) is free at ten calls a frame — the planner
uses `cut` throughout and nobody should take it away. It is fatal at four
hundred. Measured: `draw-board!` **289 → 14.6 ms**.

## 13.3 Trap 2 — building data to answer a question

`stack-top` needs one number: the topmost occupied row. It answered by
flattening the whole board into a cell list and folding `min` over it:

```scheme
;; BEFORE — a question about the first cell, priced for all two hundred.
(define (stack-top st)
  (let loop ((cells (board-cells (game-board st))) (top matrix-height))
    (if (null? cells)
        top
        (loop (cdr cells)
              (min top (cdr (car (car cells))))))))
```

The fold is elegant and the allocation is the crime: `board-cells` builds
200 pairs, the fold walks them, and the interpreter charges per node —
**11.6 ms**, every time. The honest shape is a direct scan that can stop at
the first occupied cell:

```scheme
;; AFTER — a direct scan with an early exit, not a flatten-and-fold: this
;; runs every frame inside `view-busy?`, and building a full board's cell
;; list to learn what the first row already knew cost ~12ms a call.
(define (stack-top st)
  (let ((b (game-board st)))
    (let loop-y ((y 0))
      (if (>= y matrix-height)
          matrix-height
          (let loop-x ((x 0))
            (cond ((>= x matrix-width) (loop-y (+ y 1)))
                  ((board-ref b x y) y)
                  (else (loop-x (+ x 1)))))))))
```

**11.6 → 0.04 ms** — nearly three hundred times, for the price of writing
the loop instead of composing it. The lesson is not "never fold": `full-rows`
genuinely must see every row, and folds are the right tool there. The lesson
is **a question about the first thing should not price the whole
collection**. `find` and `memq` early-exit and are fine; `map`-then-`min`
over a flattened list is the trap. In an interpreter, allocation is per-node
too — the intermediate list is not free just because it is immutable.

## 13.4 Trap 3 — paying per frame for what changes per epoch

The third trap was not a function being slow — it was a *boolean being true
for minutes*. `view-busy?` gates repainting (chapter 6): the frame draws
when something happened, or when an animation still owes frames. Its danger
arm answered "the stack is four rows from the ceiling":

```scheme
;; BEFORE — true every frame for the rest of the match.
(define (view-busy? st)
  (or (> *flash-ms* 0)
      (> *beam-ms* 0)
      (> *hold-pulse-ms* 0)
      (not (= *score-shown* (game-score st)))
      (danger-tint? st)))
```

Once the stack neared the ceiling, `view-busy?` never answered `#f` again —
so the *whole* frame repainted 60 times a second just to let a border
breathe. The pulse is a slow sine (`sin (* 8 *fx-t*)`); sampling it at 60
fps buys nothing over 15. The fix is a **gate**: state that decays with the
fx clock, asked by the busy-check, re-armed by the painter:

```scheme
;; AFTER — the danger arm expires; painting re-arms it.
(define (view-busy? st)
  (or (> *flash-ms* 0)
      (> *beam-ms* 0)
      (> *hold-pulse-ms* 0)
      (not (= *score-shown* (game-score st)))
      (and (danger-tint? st) (<= *danger-paint-ms* 0))))
```

`view-fx-step!` — which already runs once a frame with the real dt —
decrements the gate (`(set! *danger-paint-ms* (max 0 (- *danger-paint-ms*
dt)))`), and `draw-playing-field!` re-arms it with 66 ms whenever it
actually paints the border. The pulse is sampled at ~15 fps; the frames
between are free. Measured: the full-frame worst case **20.3 → 5.1 ms**.

The rule has a sharp edge: **throttle cosmetic animation, never gameplay**.
The gate is safe because the border's color is the only thing that changes
between gated frames — gravity, input, and scoring run on their own clocks
and set `*dirty*` themselves. A gate on a *gameplay* repaint would be a
frame of lag, which is a different bug.

And note the family resemblance: the journal-drain scar of chapter 6 is the
same disease on the effects rail — work that repeats forever because a
one-time fact was never consumed. "Did this frame's work already happen?"
is a question every per-frame system must answer exactly once.

## 13.5 The pattern that was already right: cache keyed by identity

The planner never fell into any of these traps, and it is worth reading why.
`best-placement` scores up to 40 placements a frame, and each score needs
the settled board's column heights and the active piece's four rotation
shapes. Computing those per frame would be the textbook trap. Instead, the
planner keys its cache on the *identity of the epoch*:

```scheme
(define (best-placement st ws)
  (let ((key (piece-key st)))
    (when (not (equal? key *search-key*))
      (set! *search-i* 0)
      (set! *search-bx* 3)
      (set! *search-brot* 0)
      (set! *search-best* -1000000000)
      ;; The settled board and the shapes are fixed for this piece's
      ;; whole life — read them once, not four times a frame.
      (set! *search-hts* (column-heights (game-board st)))
      (set! *search-rows* matrix-height)
      (set! *search-shapes*
            (map (lambda (rot) (piece-cells (falling-name (game-active st)) rot))
                 (list 0 1 2 3)))
      (set! *search-key* key))
    ...))
```

The key is `(lock-count, piece-name)` — and it can be trusted because the
board is an immutable value: if the lock count and the piece name are
unchanged, the settled board *is* unchanged, and the cached heights are not
stale but true. No timestamp, no dirty flag, no invalidation bug. That is
the general form:

> **Compute once per epoch, look up per frame — and key the cache on the
> identity of the epoch, which immutable data gives you for free.**

Notice also the search itself is *incremental*: `*search-i*` and
`*search-best*` survive across frames, so the 40 placements are amortized
over the piece's life under a per-frame scoring budget (`*best-per-frame*`).
The planner treats the frame budget as a resource to spend, not a deadline
to fear — the same instinct as chapter 8's frame-budgeted search.

## 13.6 Know which half is yours — again

After these fixes, the painter's remaining cost is ~200 seam crossings a
frame on a full board — which is chapter 10's half, not this one. The
boundary is worth naming because the next "obvious" fix differs by side:

- **Scheme-side cost** (this chapter): fewer interpreter calls — hoist,
  early-exit, cache per epoch, gate the cosmetics.
- **Seam cost** (chapter 10): fewer *crossings* — batch calls, cache in the
  host, keep the crossing payload plain.

A bulk `draw-rects!` primitive that takes all 200 cells in one crossing
would be a seam change — a new primitive name, a new host method, a new
chapter-1 table entry — and it is *not worth it* until the measurements say
so. After the Scheme fixes, the worst-case frame runs ~5 ms of interpreter
work; the seam crossings fit inside the budget. **Re-measure before
re-architecting.**

## 13.7 Traps around the step budget — for tests and harnesses

The step budget (chapter 10 §10.4) has a precise shape, and benchmark or
test code that ignores it fails in confusing ways:

1. **The budget is per top-level form.** A benchmark that times one
   `(draw-board! *st*)` call needs far less headroom than a test that loads
   a whole suite in one `load_lisp` — the hang detector charges each
   top-level form separately.
2. **The raise is not a Scheme condition.** `LispBudgetError` cannot be
   caught by `guard` — deliberately, because a hang detector the program
   could trap would detect nothing. Only the *embedding host* may size it:
   `lisp.evaluator.STEPS_BUDGET = 100_000_000` in the harness, before the
   load. A Scheme-side "try to run it with a bigger budget" is not a thing.
3. **Tail calls cost no depth, but they cost steps.** A named-let loop over
   a million cells is honest work and will trip a 5M budget; that is the
   detector saying "this form is doing a lot" — raise it in the bootstrap
   and move on.

The harness pattern is `tests/scm/bench-view.scm` plus a pytest guard, and
the guard's *bounds* are the craft. Too tight and CI noise fails the build;
too loose and it guards nothing. The bounds come from the two measurements:

```python
def test_painter_keeps_up_with_a_full_board():
    """draw-board! on a full board stays far under the frame budget.

    A regression guard for the `chain`-in-the-inner-loop slowdown: px/py
    once paid ~0.7 ms a call in macro expansion, and a full board's
    repaint burned ~300 ms — a slideshow. Plain arithmetic paints the
    same 200 cells in ~15 ms. The bound sits far above the fixed cost
    and far below the regressed one, so only a real regression trips it.
    """
    ...
    per_call_ms = (time.perf_counter() - t0) / 5 * 1000
    assert per_call_ms < 100, (
        f"draw-board! on a full board takes {per_call_ms:.0f} ms — the "
        "painter is burning its budget in the inner loop again")
```

100 ms sits 6× above the fixed cost (15 ms) and 3× below the regressed one
(289 ms) — a regression trips it on any machine, and a slow CI runner never
does. A benchmark without a committed number is a hobby; a test without
headroom is a flake. This is both, avoided.

## 13.8 The field guide

| Symptom | Likely cause | The move | Measured here |
|---|---|---|---|
| "It slows down as the game progresses" | per-frame work priced per cell/fact | early-exit scan, cache per epoch (§13.3, §13.5) | `stack-top` 11.6 → 0.04 ms |
| "Got ~20× slower after a refactor" | macro sugar in an inner loop | plain arithmetic, hoist invariants (§13.2) | `draw-board!` 289 → 14.6 ms |
| "A constant animation eats the budget" | a busy-check that never says no | repaint gate on the cosmetic (§13.4) | worst frame 20 → 5 ms |
| "The test suite crawls though the game is fine" | the painter is billed per *simulated* frame | fix the painter; the suite speeds up for free | suite 5:40 → 2:15 |
| `LispBudgetError` in a long test | one form, millions of honest steps | raise `STEPS_BUDGET` in the bootstrap (ch. 10) | — |
| Sounds/repaints replay forever | a pure function's return value dropped | thread the state (ch. 6's scar) | — |
| "Profile says the host, but frames still miss" | seam crossings per frame | batch crossings; re-measure first (§13.6) | — |

The meta-lesson is the one chapter 10 ended on, extended: **know which half
of the budget is yours** — and now also *which interpreter call count* is
yours. The three traps in this chapter are all the same sin counted
different ways: paying per call for something that could be paid once —
per epoch, per change, or per frame.

## Exercises

0. ⟡ **Running project.** Build a worst-case harness for one Breakout hot
   path (the paddle frame, the brick field, the particle rail): craft the
   extreme state, time `run()` from Python, and write down the number.
   Fix whatever the number indicts, and pin the path with a benchmark test
   whose bounds you can justify from the two measurements.
1. Time `stack-top` on an *empty* board and on a full board. Explain why
   the early-exit version's worst case is the empty board, and why that is
   the cheap half of the danger check anyway.
2. Find one `map`-then-`fold` in the codebase that could early-exit — and
   then explain why `full-rows` is *not* one. The distinction is the lesson.
3. Count the seam crossings on a full-board frame (the fake host's op log
   makes this a one-liner). Multiply by a measured per-crossing cost, and
   argue for or against a bulk `draw-rects!` primitive — in writing.

---

✓ **Checkpoint.** You can read a slowdown's signature from one player
  sentence, build a worst-case harness, name the three traps (sugar in the
  inner loop, data built to answer a question, per-frame cost for
  per-epoch state), and pin a hot path with a benchmark test whose bounds
  are measurements, not vibes.

*Next: the series is complete — [the root README](../../README.md) flexes
what these chapters built, and [tests/README.md](../../tests/README.md)
explains the test architecture this chapter's guard lives in.*


