# Chapter 3 — The railway

*The files it dissects: `scheme/core/rop.scm`, `scheme/rules/pipeline.scm`.*

> **Where you are.** Chapters 1–2 gave you the seam and the vocabularies.
> This is the chapter where the game starts *working* — and where most
> codebases reach for `if`. Hold on to chapter 2's refusal idea; it becomes
> a data type here.
>
> **By the end of this chapter you can** implement a Result monad from
> scratch, compose transitions with the fish operator, and say precisely
> where a refusal stops and where it doesn't.
>
> **The running project.** Breakout's paddle gets left/right arrows that
> refuse at the walls — through the same railway.

Tetris is a machine for saying no. A slide into a wall says no. A rotation with
no room says no. A hold with the hold already spent says no. The naive
implementation is a tangle of `if`s that mutate-or-return; this codebase runs
every command through a **railway** — each transition is a function
`state → (ok state') | (err refusal)`, and composition is one operator.

## 3.1 The Result, from scratch

`scheme/core/rop.scm` defines the whole thing in ~40 lines:

```scheme
(define-variant result
  (ok value)
  (err reason))

;; THE one primitive. Every short-circuit in the game flows through here.
(define (result-bind r f)
  (if (result-ok? r) (f (ok-value r)) r))

;; Kleisli composition: two arrows A -> Result become one.
(define (>=> f g)
  (lambda (x) (result-bind (f x) g)))
```

That is the entire monad. `result-bind` is the *only* place a short-circuit can
live: run the next arrow on success, pass the refusal through untouched
otherwise. Everything else is built on it — `result-map`, `result-fold`,
`sequence-results` (a list of Results becomes a Result of a list),
`traverse-results`, and a ladder back off the rails:

```scheme
;; A raising computation joins the railway.
(define (attempt thunk)
  (guard (e (#t (err e)))
    (ok (thunk))))
```

The monad laws are pinned in the test suite — worth doing for your own railway,
because it is exactly three properties and they catch a broken `bind` early.

## 3.2 Every command is an arrow

The pipeline (`scheme/rules/pipeline.scm`) defines the transitions:

```scheme
;; Slide by (dx dy), or refuse on a wall.
(define (try-shift state dx dy)
  (let* ((p (game-active state))
         (nx (+ dx (falling-x p)))
         (ny (+ dy (falling-y p))))
    (if (fits-at? state (falling-name p) (falling-rot p) nx ny)
        (ok (with-event
             (game-with state
                        active: (make-falling (falling-name p) nx ny
                                              (falling-rot p)))
             (moved)))
        (err (wall)))))
```

Note the shape: **gate, then effect, then event**. The gate (`falling`) is an
arrow too — a live phase and a piece under gravity — and it is the first arrow
on every movement track:

```scheme
(define (falling state)
  (if (and (phase-playing? state) (game-active state))
      (ok state)
      (err (inactive))))
```


## 3.3 The dispatcher is a table of compositions

```scheme
(define (apply-command state cmd)
  (variant-match cmd
    ((left)       ((>=> falling (cut try-shift <> -1 0)) state))
    ((right)      ((>=> falling (cut try-shift <> 1 0)) state))
    ((down)       ((>=> falling soft-fall) state))
    ((rotate-cw)  ((>=> falling (cut try-rotate <> 1)) state))
    ((hard-drop)  ((>=> falling hard-drop!) state))
    ((hold-piece) ((>=> falling hold-swap) state))
    ((restart)    (ok (restart-match state)))
    (else         (err (unknown-command)))))
```

There is no orchestrating if/else: **the pipeline is the control flow.** The
biggest composition in the game is the lock track — lock *then* spawn *then*
ask whether the mode just won:

```scheme
(define (lock-and-spawn state)
  ((>=> lock-active (>=> spawn-piece check-victory)) state))
```

Locking *then* spawning *then* checking victory, with nothing in between, is
what makes top-out and victory honest — a lock that clears the last sprint line
must win *after* the rows collapse, and a spawn into a full well must top out
*after* the spawn.

## 3.4 Rotation is a fold over nudges

SRS wall kicks are a loop over a table — each nudge tried in order, the first
that fits is the turn, and running out of nudges is a plain `(err (wall))`:

```scheme
(define (try-rotate state dir)
  ...
  (let loop ((ks (kicks-for name from to)))
    (if (null? ks)
        (err (wall))
        (let* ((k (car ks))
               (nx (+ (falling-x p) (car k)))
               (ny (+ (falling-y p) (cdr k))))
          (if (fits-at? state name to nx ny)
              (ok (with-event (game-with state active: (make-falling name nx ny to))
                              (rotated)))
              (loop (cdr ks)))))))
```

## 3.5 Refusal scoping: per-command short-circuit, frame-wide continue

Here is the subtlest decision in the file. A wall refusal cancels *exactly that
command* — but a burst of commands in one frame must keep going:

```scheme
;; A burst of commands: fold them through, and on a refusal *keep the
;; last good state and go on* — a wall does not cancel the rest of the
;; frame's input. The railway runs per command; the fold runs always.
(define (apply-commands state cmds)
  (fold (lambda (cmd acc)
          (let ((r (result-bind acc (cut apply-command <> cmd))))
            (if (result-ok? r) r acc)))
        (ok state)
        cmds))
```

The fold's accumulator is the last **good** state, so a failed right-slide does
not poison the rotate that follows it in the same frame. Get this backwards and
the game eats inputs — a classic input-eating bug, prevented by making the
policy explicit in one fold.

## 3.6 Gravity joins the same railway

Time is just another caller:

```scheme
;; One gravity pull: down a row, or — if the floor is there — the lock track.
;; This is the arrow gravity and the soft-drop key share.
(define (soft-fall state)
  (let ((r (try-shift state 0 1)))
    (if (result-ok? r)
        (let ((s* (ok-value r)))
          (ok (game-with s* score: (+ (game-score s*) (drop-points 'soft 1)))))
        (lock-and-spawn state))))
```

A held key's `down` and a due gravity tick go through the *same* arrow, so
there is exactly one lock path, one spawn path, one game-over path. When a bug
report says "the piece locked twice", there is one place to look.

## Exercises

0. ⟡ **Running project.** Write Breakout's paddle arrows: `(define (paddle st)
   ...)` gating on a live phase, then `try-shift`-style slides that refuse
   with `(err (wall))` at the screen edges. Compose them:
   `((>=> bfalling (cut bshift <> -1)) state)`.
1. Add a restart confirmation: a new refusal case `(needs-confirm)`, an arrow
   that refuses with it on the first `restart`, and a conductor that turns a
   second press within 2 seconds into the real restart. Count the files you
   touched — that is the feature's true footprint.
2. Prove the left-identity law: `(result-bind (ok v) f)` ≡ `(f v)`. Then find
   the test that already pins it.
3. `(cut try-shift <> -1 0)` is SRFI 26. Rewrite the dispatcher without `cut`
   and count the extra lambdas; then decide which spelling you would ship.

---

✓ **Checkpoint.** You can build a Result monad from two constructors and one
  bind, compose transitions with `>=>`, and read `apply-command` as the
  table of arrows it is.

*Next: [Conditions](04-conditions.md) — what happens when things go wrong:
refusals, named conditions, and errors, and why they are three different
things.*
