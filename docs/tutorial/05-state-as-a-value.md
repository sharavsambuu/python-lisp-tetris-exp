# Chapter 5 — State as a value

*The files it dissects: `scheme/domain/board.scm`, `scheme/domain/bag.scm`,
`scheme/domain/game.scm`.*

> **Where you are.** You have the plumbing (1–3) and the failure channels
> (4). Now the data itself: what a *match* is, and why the whole thing is a
> value instead of a pile of mutable fields.
>
> **By the end of this chapter you can** build a copy-on-write grid, model a
> randomizer as a value under a seed, thread updates through one lens, and
> design a journal whose facts every consumer can use.
>
> **The running project.** Breakout's brick wall becomes an immutable
> vector-of-vectors, and broken bricks become journal facts.

Functional programming in games usually dies at the board: "mutating a 10×20
grid is obviously fine." This codebase makes the opposite bet — **the whole
session is a value** — and this chapter shows the three techniques that make
the bet affordable.

## 5.1 The grid: copy-on-write vectors

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


## 5.2 The randomizer as a value

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
  tests in chapter 9 steer a seeded future instead of mocking randomness.
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

Two more bag reads the game leans on, both pure. `bag-peek` reads the future
without consuming it — the NEXT panel is drawn from it:

```scheme
;; The next n piece names, without consuming them. A peek into the future.
(define (bag-peek st n)
  (take (car st) n))
```

```scheme
;; view.scm — the next three, drawn in the panel, in their colors.
(let loop ((names (bag-peek (game-bag st) 3)) (i 0)) ...)
```

And determinism is itself a test — the same seed, the same deal:

```scheme
;; Determinism: the same seed, the same deal.
(check (bag-queue (make-bag 1234)) (bag-queue (make-bag 1234)))

;; The peek never differs from what the draws answer.
(let-values (((first-bag-draw st*) (bag-next (make-bag 7))))
  (check (car (bag-peek (make-bag 7) 3)) first-bag-draw))
```

That second check is the quiet one worth noticing: a peek that diverged from
the draws would be a *plausible* bug — the NEXT panel would show a piece that
never arrives — and only a test that compares the two reads catches it.

## 5.3 The aggregate, and `game-with` as a lens

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

The lens composes into constructors. `fresh-game` — what the conductor boots
into and what the tests use to skip the title screen — is three `game-with`
calls deep:

```scheme
;; A game that is already falling: what the conductor boots into, and what
;; the tests use to skip the title screen.
(define (fresh-game . args)
  (let ((g (apply new-game args)))
    (let-values (((piece bag) (bag-next (game-bag g))))
      (let* ((name piece)
             (p (make-falling name (spawn-x-for name) spawn-y 0)))
        (game-with (game-with g
                              phase: (playing)
                              active: p
                              bag: bag
                              journal: '())
                   journal: (list (spawned name)))))))
```

Read the last two lines closely: the inner call names four fields; the outer
call *replaces the journal* — because the inner call's generic update must
not look like a fresh match's history. Nesting lenses reads top-down as
"deal a piece, then announce the spawn," and each step is one field-level
decision.

## 5.4 The journal: facts as data

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

One warning this codebase earned the hard way (see chapter 6): a journal is a
debt. If the consumer forgets to drain it, every stale fact re-fires every
frame — sounds machine-gun, animations re-award, and the AI's lock counter
runs away. `journal-drained` returning a *new state* (not mutating) is what
made that bug possible; the fix was to thread the returned state.

## 5.5 Content is data too

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

0. ⟡ **Running project.** Build Breakout's brick wall as an immutable
   vector-of-vectors — `(make-wall)`, `(wall-hit w x y)` answering a *new*
   wall — and make your ball's position part of a single record updated
   through one `bwith` lens. Journal a `(brick-broken x y)` fact per hit.
1. `board-clear` answers `(values fresh n)`. Rewrite it as a fold that keeps
   non-full rows and justify why the fresh board is built top-down.
2. Snapshot the game state, apply `(rotate-cw)`, and assert the snapshot's
   board is unchanged. The test is three lines — write it.
3. Add `(level-up new-level)` to the journal from `lock-active`'s re-level
   branch, then consume it in the conductor's award table with a small shake.
   You have just added a whole feedback feature without touching the rules.

---

✓ **Checkpoint.** You can build an immutable grid, a value-valued randomizer,
  and a journal — and you know the one discipline a journal demands: the
  drained state must be threaded.

*Next: [Frames and time](06-frames-and-time.md) — the loop, gravity banking,
and why the input pump lives in the host.*

That single `(< y 0) #t` is what lets a piece spawn partly above the matrix —
a domain rule expressed as four lines of collision, not as a special case
smeared across the spawn code.

### The immutability, proved

The value semantics are not a promise; the domain tests pin them
(`tests/scm/domain-tests.scm`):

```scheme
;; Fill the bottom row across all ten columns: full, then clear.
(define b1
  (board-place b0 'i (map (lambda (x) (cons x 19)) (iota matrix-width))))
(assert "the row is full now" (equal? (full-rows b1) '(19)))
(assert "the original board is untouched" (board-empty? b0))
```

The second assertion is the whole chapter in one line: after placing a piece,
`b0` — the *input* — is still empty. The same test file checks the boundary
rule from both sides:

```scheme
;; Collision: walls refuse, the ceiling does not.
(assert "left wall is solid"
        (not (cells-fit? b0 '((0 . 0) (-1 . 0)))))
(assert "the floor is solid"
        (not (cells-fit? b0 '((0 . 20)))))
(assert "above the ceiling is free"
        (cells-fit? b0 '((0 . -1) (1 . -1))))
```

And `column-heights` — the read the AI's whole scoring stands on — is
asserted against a literal vector, so the reader can see the shape:

```scheme
(check (column-heights (board-place b0 'o (cells-at 'o 0 4 18)))
       '#(0 0 0 0 2 2 0 0 0 0))
```

An O dropped at column 4 shows up as two columns of height 2. When you debug
the planner in chapter 8, this is the number it thinks with.
