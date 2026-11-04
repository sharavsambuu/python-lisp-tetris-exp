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

### A command, traced

It is worth following one press through the whole machine. The player taps
`left`; the conductor's keymap turns it into `(left)`; `apply-command` takes
the `((left) ...)` arm and runs the composed arrow:

1. `falling` receives the state. Phase is `playing`, there is an active piece
   → `(ok state)`. The railway stays on the success rail.
2. `(cut try-shift <> -1 0)` receives the same state. It computes the piece's
   would-be position — say column 3 becomes column 2 — and asks
   `fits-at?`.
3. **It fits:** a new state is built with the piece one column left, the
   journal gains a `(moved)` fact, and the answer is `(ok state')`.
4. **It doesn't:** the answer is `(err (wall))`. Nothing was built, nothing
   was journaled, and — because `apply-command` returns the Result to its
   caller — the *conductor* decides that a wall is a non-event.

The important observation: at no point did either arrow "check then do
something else." Each arrow is a total function from state to Result, and the
composition is data. That is what makes the next section's dispatcher read as
a table.


## 3.3 The dispatcher is a table of compositions

```scheme
(define* (apply-command state cmd (loud: loud? #t))
  (variant-match cmd
    ((left)       ((>=> falling (cut try-shift <> -1 0 loud?)) state))
    ((right)      ((>=> falling (cut try-shift <> 1 0 loud?)) state))
    ((down)       ((>=> falling (cut soft-fall <> loud?)) state))
    ((rotate-cw)  ((>=> falling (cut try-rotate <> 1)) state))
    ((hard-drop)  ((>=> falling hard-drop!) state))
    ((hold-piece) ((>=> falling hold-swap) state))
    ((restart)    (ok (restart-match state)))
    (else         (err (unknown-command)))))
```

The `loud?` keyword is the one word three of these rows needed: the commands a
*held* key can repeat (the two slides and the soft drop) must know whether this
call is a press or the repeat pump's tick. It rides as a keyword rather than a
fourth positional because every other caller — the AI, the tests, a burst —
wants the default (`#t`, a hand's press), and a default nobody has to spell is
a default nobody can get wrong.

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

The table itself is data — the canonical SRS nudges, transcribed once with the
y axis flipped to match the screen (`scheme/rules/kicks.scm`):

```scheme
;; JLSTZ, y already flipped to screen coordinates (down is positive).
(define jlstz-kicks
  (list (cons (cons 0 1)  '((0 . 0) (-1 . 0) (-1 . -1) (0 . 2) (-1 . 2)))
        (cons (cons 1 0)  '((0 . 0) (1 . 0) (1 . 1) (0 . -2) (1 . -2)))
        ...))
```

The key is `(from . to)` — which rotation you are leaving and entering — and
the value is the ordered nudge list. The lookup adds two pieces of domain
knowledge that keep the table honest:

```scheme
(define (kicks-for name from to)
  (cond ((eq? name 'o) '((0 . 0)))       ; an O "rotates" onto itself
        ((= from to) '((0 . 0)))         ; a non-rotation needs no nudge
        ((eq? name 'i) (cdr (assoc (cons from to) i-kicks)))
        (else (cdr (assoc (cons from to) jlstz-kicks)))))
```

The first two arms are the interesting ones: they encode facts the *table*
must not be trusted to remember (every entry's first nudge is `(0 . 0)` — the
plain turn — precisely because the loop tries nudges in order).

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
;; One pull of descent: down a row, or — if the floor is there — the lock
;; track. Two questions travel with a pull, and they are deliberately
;; separate: `loud?` — is this a *moment* worth announcing? and `paid?` —
;; whose wage is the row? A press is loud and paid; a held key's repeat is
;; quiet and paid; gravity is neither.
(define (fall-by-one state loud? paid?)
  (let* ((p (game-active state))
         (ny (+ (falling-y p) 1)))
    (if (fits-at? state (falling-name p) (falling-rot p)
                  (falling-x p) ny)
        (let ((s* (game-with state
                             active: (make-falling (falling-name p)
                                                   (falling-x p) ny
                                                   (falling-rot p))
                             score: (+ (game-score state)
                                       (if paid?
                                           (policy-soft-row (policy-of state))
                                           0)))))
          (ok (if loud? (with-event s* (soft-dropped)) s*)))
        (lock-and-spawn state))))

;; The soft-drop key's arrow: the shared descent, always paid for, announced
;; only when the caller says it is a moment.
(define (soft-fall state loud?)
  (fall-by-one state loud? #t))
```

A held key's `down` and a due gravity tick go through the *same* descent, so
there is exactly one lock path, one spawn path, one game-over path. When a bug
report says "the piece locked twice", there is one place to look. The one
thing the callers do not share is the journal entry: gravity passes `loud? #f`
(and earns nothing), a *press* is loud and paid, and a held key's *repeat* is
paid but silent — the pump spends a key every 40ms, and a blip a tick is a
buzz. Chapter 14.2 tells the story of why that distinction had to become two
flags rather than one.

The harder compositions are worth reading as prose. `hard-drop!` is a
conditional pipeline: fall the whole distance, *then* lock — unless the
distance is zero, in which case the fall is a no-op and the lock happens
directly:

```scheme
;; Slam the piece to its ghost and lock in the same breath. A zero
;; distance still locks — the pipeline does not care how far it fell.
(define (hard-drop! state)
  (let ((d (drop-distance state)))
    (if (= d 0)
        (lock-and-spawn state)
        (result-bind (fall-n state d 'hard) lock-and-spawn))))
```

`result-bind` here is do-notation by hand: "run the fall; on success, feed
the fallen state to lock-and-spawn." The DSL's prelude also ships a
`result-do` sugar that spells the same shape imperatively — the lock track
itself, written as three labeled steps:

```scheme
(result-do (locked-s <- (lock-active state))
           (spawned-s <- (spawn-piece locked-s))
           (check-victory spawned-s))
```

— which is *exactly* `lock-and-spawn`'s fish composition, one short-circuit,
no plumbing. One place a short-circuit can live means both spellings are the
same machine underneath. Pick the spelling that reads better; the railway does
not care.

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
