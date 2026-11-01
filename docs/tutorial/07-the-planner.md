# Chapter 7 — The one-ply planner

*The files it dissects: `scheme/domain/plan.scm`, `best-placement` and
`ai-step!` in `scheme/conductor/arcade.scm`.*

An AI in an interpreted DSL has a budget problem Python games never feel: a
frame is ~16ms and every interpreter step costs. The AI here is a one-ply
placement evaluator — try all 40 placements, score each on the height profile
it would leave, steer toward the best — and the interesting engineering is
*how little of it runs per frame*.

## 7.1 The arithmetic: score a profile, not a board

`scheme/domain/plan.scm` never sees a game. It scores a **height profile** —
a vector of ten column heights:

```scheme
;; Weights: (cleared holes bumpiness wells). `cleared` is the height of
;; the *lowest* column after the placement — keeping the roofline low is
;; what keeps the game alive; the other three are penalties. They are
;; data, so a caller can publish its own.
(define (weights cleared holes bumpiness wells)
  (list cleared holes bumpiness wells))
```

The terms are tiny folds over the vector: `min-of` (the roofline after the
clear), `bumpiness` (the total rise between neighbors), `well-depth` (a column
lower than both neighbors — the term that saves the AI):

```scheme
;; A column lower than both neighbours is a well; its depth is what has
;; to be filled. This is the term that saves an AI: every placement adds
;; four cells, so the *sum* of heights is the same wherever the piece
;; lands — nothing in it rewards filling a low column. The well term
;; does, and without it one early gap becomes an unfillable tomb.
```

The profile is a **vector, deliberately**:

```scheme
;; `heights` is a *vector* — the stack height of each column — because the
;; planner scores forty placements per piece and a raise of a list profile
;; allocates a new ten-list per cell; on the vector the same raise is one
;; `vector-copy` plus one `vector-set!`, both single interpreter steps.
```

That is the chapter's first lesson: **in an interpreter, allocation is the
cost.** The same math on lists was visibly slower; on vectors it is two
primitive steps per candidate.

## 7.2 The search, budgeted by design

`best-placement` (in the conductor) walks 40 placements — 4 rotations × 10
columns — but scores at most `*best-per-frame*` (6) per call, remembering
where it stopped:

```scheme
(define *best-per-frame* 6)  ;; placements scored per call

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
      (set! *search-shapes*
            (map (lambda (rot) (piece-cells (falling-name (game-active st)) rot))
                 (list 0 1 2 3)))
      (set! *search-key* key))
    (let loop ((scored 0) (i *search-i*))

## 7.3 The piece key: invalidating the plan

```scheme
(define (piece-key st)
  ;; The identity of the piece a plan belongs to: the lock count *and*
  ;; the kind. A count alone is not enough: a hold swaps the active
  ;; piece without locking one, so the key would stay the same and the
  ;; plan would steer the new piece with the old piece's shape.
  (list *lock-count*
        (if (game-active st) (falling-name (game-active st)) #f)))
```

Caching a plan requires a cache key, and the *obvious* key (lock count) is
wrong the moment hold exists — a swap changes the piece without a lock. The
key is therefore `(locks, piece-name)`. **Every memo needs a wrongness story**:
know what would invalidate it, and make that thing part of the key.

## 7.4 Steering: one command a frame

`ai-step!` runs once per frame and issues **at most one command**:

```scheme
(define (ai-step!)
  (when (and *ai* (phase-playing? *st*) (game-active *st*))
    (let ((key (piece-key *st*)))
      (when (not (equal? key *plan-key*))
        (set! *plan-key* key)
        (set! *plan-ready* #f))
      (when (not *plan-ready*)
        (let ((plan (best-placement *st* *weights*)))
          (when (not (eq? plan 'pending))
            (set! *plan-x* (car plan))
            (set! *plan-rot* (cadr plan))
            (set! *plan-ready* #t))))
      (when *plan-ready*
        (steer-to! *st* *plan-x* *plan-rot*)))))
```

and `steer-to!` is a greedy walk: rotate until the rotation matches, move
until the column matches, then hard-drop. A refused move (a kick failed, a
shift hit a wall) falls through to `ai-drop!` — the AI never argues with the
board, it slams what it has.

Why one command per frame? Because the player can only press one key per
frame, and an AI that applies ten moves per frame is playing a different game
— and because it bounds the AI's cost to a few `apply-command` calls, keeping
the frame budget honest (see chapter 9).

## 7.5 The AI is just another player

The planner sits *on top of* the pipeline: it issues the same `(left)`,
`(rotate-cw)`, `(hard-drop)` commands a human's keys produce. It has no back
door into the board. That is why the purity fence holds with the AI on, and
why the "AI wins a sprint" test is a playthrough test, not a unit test — the
AI is exercised through exactly the surface a player uses.

## Exercises

1. Add a fifth weight, `holes-row` (holes higher in the stack are worse), to
   `placement-score`. The AI should stop digging under the ridge. Turn the
   weight knob up until you can *watch* it change behavior in `--headless`.
2. Make `*best-per-frame*` adaptive: 10 placements when the piece is high in
   the well, 3 when it is about to lock. Measure the sprint win rate change.
3. The `'pending` protocol is a hand-rolled coroutine. Rewrite `best-placement`
   as a real generator (or CPS) and argue which version a maintainer should
   meet first.

---

*Next: [Testing a game with no mocks](08-testing.md) — the host as data.*

      (cond ((>= i 40)
             (set! *search-i* i)
             (list *search-bx* *search-brot*))
            ((>= scored *best-per-frame*)
             (set! *search-i* i)
             'pending)
            (else ...))))))
```

Read the three answers it can give:

- `(>= i 40)` → `(list bx brot)` — the plan is ready.
- budget spent → **`'pending`** — keep the partial best, resume next frame.
- otherwise → keep scoring.

`'pending` is the trick: the search is a *resumable computation* across
frames, with its progress in variables instead of a continuation. A piece
takes ~7 frames to fully plan (40 ÷ 6), which is free — the piece is falling
anyway.
