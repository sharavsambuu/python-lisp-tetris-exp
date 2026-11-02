# Chapter 12 — The six SRFIs, doing real work

*The files it dissects: everywhere — this chapter is a field guide.*

> **Where you are.** The final chapter, and the reference one. Every technique
> you have used leaned on a piece of the standard library; this chapter
> collects the six, each with its real call sites and its judgment call.
> Read it straight through once, then return to it as a map.
>
> **By the end of this chapter you can** name where each of the six SRFIs
> earns its keep, and — more importantly — where each one is the *wrong*
> spelling.
>
> **The running project.** The last step: replace three hand-rolled loops in
> your Breakout with the SRFI spellings that shorten them.

The DSL ships six SRFIs, and the game uses every one of them for something
real. This chapter is the map: for each SRFI, what it is, where it earns its
keep, and the judgment call of when to reach for it.

## 12.1 SRFI 1 — the list library that carries the grid math

Folds are the workhorse. `board.scm`'s `full-rows` walks the grid with a fold
that carries both the index and the answer:

```scheme
(reverse
 (cdr
  (fold (lambda (row acc)
          (let ((i (car acc)) (full (cdr acc)))
            (if (every (lambda (cell) (not (eq? cell #f)))
                       (vector->list row))
                (cons (+ i 1) (cons i full))
                (cons (+ i 1) full))))
        (cons 0 '())
        (vector->list b))))
```

The same SRFI everywhere else:

- `every` — collision: `(every (lambda (c) (cell-free? b (car c) (cdr c))) cells)`
- `find` / `count` / `list-index` — journal scans and ladder walks
- `iota` — generating row and column ranges
- `map` — note the import: `(rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))`.
  Closed library scopes must not silently shadow `scheme base`'s `map`, so the
  rename is *discipline made visible* — when you read `srfi-1:map` you know
  exactly which map is running.

**When to reach for it:** any read that reduces a collection to a value. The
rule the codebase follows: folds for reads, `let loop` for anything with an
early exit or two accumulators that disagree.

The bag's shuffle shows SRFI 1's `take`/`drop` pair doing the picker's work —
and the whole shuffle is a fold over a seed:

```scheme
;; A shuffle expressed as a fold: walk the list, taking each pick from a
;; position drawn off the generator, building the shuffled bag on the way.
(define (shuffle xs seed)
  (let loop ((items xs) (seed seed) (acc '()))
    (if (null? items)
        (values acc seed)
        (let* ((seed* (next-seed seed))
               (i (modulo seed* (length items)))
               (picked (list-ref items i))
               (rest (append (take items i) (drop items (+ i 1)))))
          (loop rest seed* (cons picked acc))))))
```

Two accumulators moving in lockstep — the shrinking list and the advancing
seed — with `values` handing both back. A named-`let` loop is the honest
spelling here: the body mutates *nothing*, and the seed threading is visible
in every recursive call.

## 12.2 SRFI 26 — `cut`, the arrow specialization

Partials without lambda noise. The dispatcher (chapter 3) is unreadable
without it:

```scheme
((left)  ((>=> falling (cut try-shift <> -1 0)) state))
```

and the resumable loops in the pipeline lean on it too:

```scheme
(result-bind (soft-fall s) (cut loop <> (+ i 1)))
```

`cut` shines when the *hole* is not the last argument — `try-shift` takes the
state first, dx/dy after, and only `cut` can specialize the tail. Where the
hole is last, plain section syntax or a lambda is fine; the codebase uses
`cut` exactly where argument order demands it, not as a style accent.

The purest example is in geometry, where rotations are *generated* rather
than transcribed:

```scheme
;; One CW rotation in an n box: (x y) -> (n-1-y x). Our y grows downward,
;; so this is the screen-honest spelling of the SRS turn.
(define (rotated-cell n cell)
  (cons (- (- n 1) (cdr cell)) (car cell)))

(define (all-rotations name)
  (let ((n (piece-box name)))
    (let loop ((r 0) (cells (shape-of name)) (acc '()))
      (if (= r 4)
          (reverse acc)
          (loop (+ r 1)
                (map (cut rotated-cell n <>) cells)
                (cons cells acc))))))
```

`(cut rotated-cell n <>)` binds the box size and leaves the cell open — the
exactly-once-specialized mapper that four lambdas would stutter. And notice
what the generator buys: no rotation table *can* drift from the spawn shape
it came from, because the rotations are derived. Compare with transcribing
sixteen cell lists by hand and trusting the seventh.

## 12.3 SRFI 88 — keywords as named-options atoms

Keywords (`cell:`, `type:`, `i:`) are this dialect's self-evaluating names.
Three real uses:

**Layout and palette tables** (`view.scm`) — a layout is a named-options
thing:

```scheme
(define layout
  (list (cons cell: 26) (cons board-x: 190) (cons board-y: 60) ...))

(define (lay k) (cdr (assq k layout)))
```

**The event alist keys the host sends** (`pygame_host.py` → the conductor):

```python
K_TYPE = intern_keyword("type")
K_KEY = intern_keyword("key")
```

```scheme
(let ((type (cadr (assq type: ev))))
  (case type ((key-down) ...) ((key-repeat) ...)))
```


## 12.4 SRFI 89 — `define*`: the difficulty surface as named parameters

The game's constructor takes optional keyword parameters — the whole
difficulty surface, spelled at the call site:

```scheme
(define* (new-game (seed: seed 20261101)
                   (level: start-level #f)
                   (mode: mode-name 'marathon)
                   (options: options '()))
  ...)
```

and the aggregate's lens takes keywords with `#!key`:

```scheme
(game-with s phase: (playing) journal: '())
```

Two things `define*` buys over plain optional args: calls *read* —
`(new-game seed: 7 mode: 'sprint options: '((target-lines 20)))` says what
each number means — and defaults live next to the parameter, so the
constructor's contract is its signature. The mode options are validated by
`(tetris modes)`, which raises a named condition on a typo (chapter 4)
rather than guessing.

## 12.5 SRFI 197 — `chain` for one-shot pipelines

Some of the painter's math is a pipeline: measure the string, take half the
slack, add the left edge. `chain` writes it in reading order:

```scheme
(define (centered-x left width s size)
  (chain (quotient (- width (text-width s size)) 2)
         (+ left _)))
```

`_` is the placeholder, substituted at each step. The nested-arithmetic
spelling of the same line buries the *order* in inside-out parens. `chain`
is used only in the view, only for math that runs once a frame or less.

And that qualifier is the chapter's scar. The grid-to-pixel converters `px`
and `py` were once `chain` pipelines too — and they run once per settled
cell per repaint. A `chain` step pays its macro expansion on every call:
~0.7 ms a call in this interpreter against ~0.03 ms for the arithmetic. Two
hundred settled cells later, the *sugar* was burning ~300 ms a frame — more
than the seam itself. The fix was not a ban but a placement rule:

> `chain` is for pipelines that run once. An inner loop pays for its sugar
> on every call — a hot `px` is plain arithmetic, with the order in a
> comment.

## 12.6 SRFI 241 — `match` with constant patterns

Two tables read as tables. The keymap (`commands.scm`) — string patterns
match by `equal?`, and the catch-all is `,_`:

```scheme
;; Host key name -> command, or #f when the key is not the game's. The
;; patterns are string literals (matched by equal?) and the catch-all is
;; SRFI 241's `,_` — a bare `_` would be a constant, matched by name.
(define (key->command key)
  (match key
    ("left" (left))
    ("right" (right))
    ("down" (down))
    ("up" (rotate-cw))
    ("x" (rotate-cw))
    ("z" (rotate-ccw))
    ("space" (hard-drop))
    ("shift" (hold-piece))
    ("c" (hold-piece))
    ("r" (restart))
    (,_ #f)))
```

and the award table (`scoring.scm`) — integer constants, the classic Tetris
payouts:

```scheme
(define (line-points n)
  (match n
    (1 100)
    (2 300)
    (3 500)
    (4 800)
    (,_ 0)))
```

The `,_` wildcard is the SRFI's sharpest edge: **bare symbols are constants
in this `match`**, matched by name — so the wildcard must be written `,_`.
The codebase's comments repeat it because everyone writes this bug once.

## 12.7 The judgment calls, in one table

| SRFI | The codebase's rule of thumb |
|---|---|
| 1 | Folds for reads; `let loop` when exiting early or juggling accumulators |
| 26 | `cut` when the hole is not the last argument |
| 88 | Keywords for small fixed option tables and cross-language event keys |
| 89 | `define*` for any constructor whose arguments have meanings |
| 197 | `chain` for one-shot left-to-right pipelines — never an inner loop |
| 241 | `match` for tables read by constant patterns; remember `,_` |

The meta-lesson: **each SRFI is used where it is the shortest honest
spelling, and nowhere else.** A utility imported but unused is a dependency
you explain forever; all six here have call sites you can visit in a minute.

## Exercises

0. ⟡ **Running project.** The last step: replace three hand-rolled loops in
   your Breakout with the SRFI spellings that shorten them — a fold for a
   read, a `match` for a table, a `chain` for a coordinate pipeline. If a
   rewrite is *longer*, that is the lesson.
1. Find the one place `srfi-1:fold` and a hand-written `let loop` solve the
   same problem in different files. Argue which is right, and whether the
   codebase should standardize.
2. The event alist keys (`type:`, `key:`) are interned in Python. Break one
   spelling on the Python side and follow the failure — where does it
   surface, and how far is it from the cause?
3. Rewrite `line-points` as an alist lookup. Which version would you rather
   meet in a review, and what does that say about when `match` is a table?

✓ **Checkpoint.** You know where each of the six SRFIs earns its keep — and
  you have finished the running project: a second game, written in the same
  style, by your own hand.

---

*The series ends here. The map is in [the index](README.md); the next
tutorial worth writing is the one about the feature you build next.*

Python interns the *same* keyword objects the Scheme side assqs on — the
keyword is the contract between the two languages, checkable by `eq?`.

**The piece palette lookup** — a symbol becomes a keyword without a `case`:

```scheme
(define (piece-color name)
  (color (string->keyword (symbol->string name))))
```

**The shape table** (`geometry.scm`) — the same atoms make the spawn shapes
read like a literal, and the lookup needs no quoting:

```scheme
;; Spawn shapes: name -> (keyword . cells), cells as (x . y) in the box.
;; The keywords are SRFI 88 objects — self-evaluating, so the table reads
;; like a literal and assq finds entries without quoting.
(define spawn-shapes
  (list (cons 'i: '((0 . 1) (1 . 1) (2 . 1) (3 . 1)))
        (cons 'o: '((0 . 0) (1 . 0) (0 . 1) (1 . 1)))
        (cons 't: '((1 . 0) (0 . 1) (1 . 1) (2 . 1)))
        ...))
```

**When:** a small, fixed set of named options read by `assq`. **When not:**
anything the player types — keywords are for the programmer's vocabulary.
