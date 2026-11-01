# Chapter 4 — State as a value

*The files it dissects: `scheme/domain/board.scm`, `scheme/domain/bag.scm`,
`scheme/domain/game.scm`.*

Functional programming in games usually dies at the board: "mutating a 10×20
grid is obviously fine." This codebase makes the opposite bet — **the whole
session is a value** — and this chapter shows the three techniques that make
the bet affordable.

## 4.1 The grid: copy-on-write vectors

`scheme/domain/board.scm`:

```scheme
;; The grid, and nothing but the grid. A board is an immutable value: a vector
;; of rows, a row a vector of #f or a piece-name symbol. Nothing here mutates
;; a board in place — "place" and "clear" answer a *new* board — because a
;; whole session is a value you can hold, snapshot, and replay.

(define (board-copy b)
  (vector-map (lambda (row) (vector-copy row)) b))

;; The settled board with one piece merged in. Pure: rows are copied, the
;; input board is untouched.
(define (board-place b name cells)
  (let ((fresh (board-copy b)))
    (for-each
     (lambda (c)
       (let ((x (car c)) (y (cdr c)))
         (if (and (>= y 0) (< y matrix-height))
             (vector-set! (vector-ref fresh y) x name)
             #f)))
     cells)
    fresh))
```

The trick: the *type* is immutable-by-convention, the *implementation* is a
mutable vector, and the mutation happens only on the fresh copy. That gives
O(rows) copies instead of O(cells) allocation, while keeping the value
semantics — `board-place` on a snapshot can never leak into the snapshot.

Reads are folds (SRFI 1), and one fold carries both the index and the answer:

```scheme
;; The indices of the full rows, oldest first — a fold that carries both
;; the index and the answer.
(define (full-rows b)
  (reverse
   (cdr
    (fold (lambda (row acc)
            (let ((i (car acc)) (full (cdr acc)))
              (if (every (lambda (cell) (not (eq? cell #f)))
                         (vector->list row))
                  (cons (+ i 1) (cons i full))
                  (cons (+ i 1) full))))
          (cons 0 '())
          (vector->list b)))))
```

One boundary rule worth reading twice — the ceiling does not exist:

```scheme
;; Outside the side walls or below the floor is *not* free; above the
;; ceiling is.
(define (cell-free? b x y)
  (cond ((or (< x 0) (>= x matrix-width)) #f)
        ((>= y matrix-height) #f)
        ((< y 0) #t)
        (else (not (board-ref b x y)))))
```


## 4.2 The randomizer as a value

Guideline Tetris deals from a 7-bag. Here the bag is a *pair*: the queue of
pieces still to deal, and the generator's seed (`scheme/domain/bag.scm`):

```scheme
;; The randomizer as a *value*. ... Every draw answers a piece and a new
;; state; nothing here mutates, so a game's whole random future is a value
;; the tests can hold and steer.

(define modulus 2147483647)          ; 2^31 - 1, a Lehmer-friendly prime
(define multiplier 48271)

(define (next-seed seed)
  (modulo (* seed multiplier) modulus))

(define (bag-next st)
  (let* ((queue (car st))
         (seed (cdr st))
         (piece (car queue))
         (rest (cdr queue)))
    (if (>= (length rest) (length piece-names))
        (values piece (cons rest seed))
        (let-values (((rest* seed*) (bag-refill-from rest seed)))
          (values piece (cons rest* seed*))))))
```

Two payoffs:

- **Seeded matches.** `new-game seed: 7` deals the same match every time. The
  tests in chapter 8 steer a seeded future instead of mocking randomness.
- **Replays that differ only in the player's hands.** `restart-match` keeps
  the *recipe and the random stream* — the bag continues where it was:

```scheme
;; A restart keeps the recipe and the random stream: the config is the
;; match's own, the bag continues where it was — a replay is a new board
;; dealt from the same future.
(define (restart-match state)
  (let* ((config (game-config state))
         (seed (cdr (game-bag state)))
         ...))
```

Notice the PRNG is *owned by the domain*, not by Python's `random`. A game
that can be replayed from a seed cannot have its dice rolled by the runtime.

## 4.3 The aggregate, and `game-with` as a lens

The whole match is one record — phase, board, falling piece, hold slot, bag,
score line, combo, back-to-back flag, clock, config, and the journal. Updates
go through one lens, `game-with` (`scheme/domain/game.scm`), built on SRFI 89
keyword arguments:

```scheme
(game-with s phase: (playing) journal: '())
```

Every field you do not name is carried over unchanged. This is the poor man's
record update, and it has a property fancy lens libraries would add: **there
is exactly one place a field is written.**

## 4.4 The journal: facts as data

The state carries its own event log, newest first:

```scheme
;; Journal one event, newest first.
(define (with-event s ev)
  (game-with s journal: (cons ev (game-journal s))))

;; The state as seen after the consumer has read the journal: the paper
;; trail is emptied without touching a single other field.
(define (journal-drained s)
  (game-with s journal: '()))
```

Transitions *announce*; the conductor *decides* what an announcement means:

- the speaker plays a sound per fact (`sfx-journal!`),
- the effects rail awards flash/shake per fact (`award-journal!`),
- the tests assert on facts instead of pixels: `(memq 'victory ...)`.

This is event sourcing in miniature, and the discipline that makes it work is
in the pipeline's comment:

```scheme
;; The rows go into the journal *as rows* — the edge's animation paints
;; where they were, so the fact must say where, not how many.
```

**Facts must carry enough data for every consumer** — the painter needs row
indices, the scorer needs the count. Record the *richest* form; derive the
rest.

One warning this codebase earned the hard way (see chapter 5): a journal is a
debt. If the consumer forgets to drain it, every stale fact re-fires every
frame — sounds machine-gun, animations re-award, and the AI's lock counter
runs away. `journal-drained` returning a *new state* (not mutating) is what
made that bug possible; the fix was to thread the returned state.

## 4.5 Content is data too

`scheme/content/campaign.scm` extends the same idea to game design: a
challenge is a named match recipe — mode, options, goal — and a campaign is an
ordered ladder over recipes:

```scheme
;; A challenge is (("id" …) ("title" …) ("mode" …) ("options" …) ("goal" …)).
;; The fields are read by accessors, so a challenge reads as the record it is.
(define (challenge id title mode options goal) ...)
```

A new campaign is a diff to a list, not a feature. When your DSL makes content
cheap, you ship more of it.

## Exercises

1. `board-clear` answers `(values fresh n)`. Rewrite it as a fold that keeps
   non-full rows and justify why the fresh board is built top-down.
2. Snapshot the game state, apply `(rotate-cw)`, and assert the snapshot's
   board is unchanged. The test is three lines — write it.
3. Add `(level-up new-level)` to the journal from `lock-active`'s re-level
   branch, then consume it in the conductor's award table with a small shake.
   You have just added a whole feedback feature without touching the rules.

---

*Next: [Frames and time](05-frames-and-time.md) — the loop, gravity banking,
and why the input pump lives in the host.*

That single `(< y 0) #t` is what lets a piece spawn partly above the matrix —
a domain rule expressed as four lines of collision, not as a special case
smeared across the spawn code.
