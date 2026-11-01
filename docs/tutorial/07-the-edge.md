# Chapter 7 — The edge

*The files it dissects: `scheme/presentation/view.scm`,
`scheme/conductor/arcade.scm`.*

> **Where you are.** The game now runs — states transform, time passes. This
> chapter is where the player finally *sees* it, and where you learn the
> structures that keep edge code from rotting.
>
> **By the end of this chapter you can** write a painter as a pure
> reduction, keep animations in a decayed-state rail fed by journal facts,
> and wire `view-busy?` into the loop's dirty flag.
>
> **The running project.** Breakout gets painted — and a flash when a brick
> breaks, awarded from the journal exactly like Tetris's clear beam.

The edge is where the game meets the world: screens, keys, sounds, pixels.
It is also where DSL codebases usually rot into soup. This chapter shows the
three structures that keep it clean: the painter as a *pure reduction*, the
menu as *data*, and the effects rail as *decayed state fed by facts*.

## 7.1 The painter is a reduction, not a renderer

`presentation/view.scm` has no game state of its own (beyond the effects
rail below). Its whole job:

```scheme
;;; This module knows the game's shape and the host's painter primitives,
;;; and nothing else about either: it reduces a game state to rectangles
;;; and text, one host call at a time.
```

Layout is a keyword table (SRFI 88 — keywords are this dialect's atoms):

```scheme
(define layout
  (list (cons cell: 26)
        (cons board-x: 190)
        (cons board-y: 60)
        (cons left-x: 24)
        (cons right-x: 476)
        (cons panel-w: 140)))

(define (lay k) (cdr (assq k layout)))
```

and the palette is the same shape keyed by piece name — note the keyword
round-trip, `(string->keyword (symbol->string name))`, that turns a piece
symbol into its palette entry without a single `case`.

The reduction itself is barely a page. The settled board is drawn by one
`for-each` over an alist of `((x . y) . name)` cells:

```scheme
(define (draw-board! st)
  (let ((s (cell-size)))
    (for-each
     (lambda (entry)
       (let ((pos (car entry)) (name (cdr entry)))
         (draw-rect! (px (car pos)) (py (cdr pos)) s s
                     (piece-color name))))
     (board-cells (game-board st)))))
```

Every interesting decision is *elsewhere*: what the cells are is the board's
job, where they land on screen is `px`/`py`'s (scale, origin, shake), and
what color they wear is the palette's. The painter is the one place those
three answers meet — and it meets them without owning any of them. That is
the "pure reduction" property in miniature: hold the painter's input fixed
and its draw-call log is a deterministic function of it, which is exactly
what chapter 9's fake-host tests assert against.

A test reads the painted result back *pixel by pixel* through the real host
(`tests/test_host_smoke.py::test_painter_paints`): background, well frame,
cells. The painter is honest enough to be verified against a screenshot's
coordinates, because it is a pure reduction with no hidden state.

## 7.2 The effects rail: decayed state, fed by facts

Animations are the classic excuse for game-object spaghetti. Here the whole
rail is a handful of decayed variables in the view, stepped once per frame
with the real dt:

```scheme
;; The conductor decides *what a fact is worth* (the award table is its
;; own); this module owns the decay and the paint. `view-fx-step!` runs
;; once a frame with the real dt, so a 60 fps run and a 144 fps run wear
;; a flash the same length.

(define *shake-px* 0.0)
(define *flash-rgb* #f)
(define *flash-ms* 0)
(define *score-shown* 0)
(define *beam-rows* '())
(define *beam-ms* 0)
(define *hold-pulse-ms* 0)
```

The decay step shrinks the shake geometrically, burns the flash and beam
timers down by dt, and eases the score ticker toward the real score:

```scheme
;; The ticker chases the real score: an eighth of the gap per frame,
;; at least one, so a small gain still visibly rolls.
(let ((target (game-score st)))
  (cond ((> *score-shown* target) (set! *score-shown* target))
        ((< *score-shown* target)
         (set! *score-shown*
               (min target (+ *score-shown*
                              (max 1 (quotient (- target *score-shown*) 8))))))
        (else #f)))
```

The division of labor is strict:

- **The conductor owns the award table** — what a fact is *worth* (a tetris
  shakes harder than a single). It reads the journal and calls
  `view-shake!` / `view-flash!` / `view-clear-beam!`.
- **The view owns the decay** — how an award wears off. No game rule reads
  any of these variables; the rail is purely presentational.

The same split governs sound, and it answers a subtle design question: when
one frame contains *several* facts — a lock, a clear, a level up — which
sound plays? The conductor's answer is a **ranking table**, loudest first,
and a search for the biggest fact in the drain:

```scheme
(define *sfx-fact*   ;; (fact-tag kind), loudest first
  '((game-over "over")
    (victory   "victory")
    (level-up  "level-up")
    (cleared   "clear")
    (restarted "start")))

(define (sfx-journal! events)
  (let loop ((order *sfx-fact*))
    (if (null? order)
        (for-each sfx-event! events)
        (let ((hit (find (lambda (ev) (eq? (tag-of ev) (car (car order))))
                         events)))
          (if hit
              (sfx! (cadr (car order)))
              (loop (cdr order)))))))
```

The loop plays *one* headline — the first table row that matches any fact in
the drain — and then the per-event sounds (moves, rotations) still play
underneath. Reordering the list *is* the mixing decision; no code changes
when the designer decides a level-up should out-shout a clear.


And the rail tells the loop when it still owes frames:

```scheme
;; True while the rail still owes frames: a flash burning, a beam or
;; pulse decaying, the ticker short of the real score, or a danger pulse
;; breathing. The conductor repaints while this answers true, so an
;; animation finishes even though "nothing happened" in the match.
(define (view-busy? st)
  (or (> *flash-ms* 0)
      (> *beam-ms* 0)
      (> *hold-pulse-ms* 0)
      (not (= *score-shown* (game-score st)))
      (danger-tint? st)))
```

This is the bridge between the dirty-flag optimization (chapter 6) and
animations: *nothing happened* is not the same as *nothing is moving*. Without
`view-busy?`, every animation would freeze the instant the match went quiet.

## 7.3 The award table: the journal becomes feedback

The conductor reads the drained journal and pays out
(`conductor/arcade.scm`):

```scheme
;; The rows go into the journal *as rows* — the edge's animation paints
;; where they were, so the fact must say where, not how many.
(let ((rgb (or (cadr (assq (length rows) *clear-palette*)) '(200 200 210))))
  (view-flash! rgb (+ *clear-flash-base-ms*
                      (* *clear-flash-per-line-ms* (length rows))))
  (view-clear-beam! rows))
```

Note the palette lookup — keyed by the *count* of cleared rows, so a tetris
wears a different color than a single. And note the scar in that line's
history: the first version read `(cdr (assq ...))` on an entry like
`(2 (90 90 110))`, which answers `((90 90 110))` — a list *containing* the
color — and `tint!` crashed the moment the first row cleared. The fix was
`cadr`. **Alist etiquette: know whether your entries are pairs or two-element
lists, and put the accessor next to the table.**

The rest of the award table shows how small per-fact feedback stays. A long
slam shakes; a swap pulses the hold panel; the big moments flash in their own
colors:

```scheme
((dropped d)
 (if (>= d 6) (fx-thud! *slam-shake-px*) #f))
((hold-swapped) (view-hold-pulse!))
((hold-refused) (fx-thud! 1.0))
((level-up _) (view-flash! '(80 220 200) 170) (fx-thud! *level-up-shake-px*))
((victory) (view-flash! '(230 230 240) 220))
((game-over) (view-flash! '(160 40 40) 260))
```

Six lines, six feedback personalities, all derived from facts the *rules*
already announced. Note what is absent: the award table never asks "what
score did this clear pay" — that would couple presentation to scoring. It
reads only the *facts*, which is why a scoring change can never silently
change an animation.

## 7.4 Screens and menus as data

The conductor's screens are a closed symbol set (`title | campaign | mode |
level | play`) and each screen's content is a *menu value* — a list of
labeled entries plus a cursor:

```scheme
(define (make-menu entries) (list entries 0))
(define (menu-entries m) (car m))
(define (menu-cursor m) (cadr m))
(define (menu-move m delta) ...)
```

`menu-key!` is a small cond: up/down move the cursor, return calls `choose!`,
escape calls `back!` — and `back!` is the whole navigation stack:

```scheme
(define (back!)
  (case *screen*
    ((title) (quit!))
    (else (show-screen! 'title (title-menu)))))
```

`choose!` is where data becomes a match: the cursor's entry carries a tag
(`'campaign`, `'mode`, `'free`, …) and each tag starts the thing it names.
Because menus are values, a menu is trivially testable — build one, move,
assert the cursor.

## 7.5 One dispatcher for keys, per screen

Every polled event flows through one `dispatch-key!`:

```scheme
(define (dispatch-key! key)
  (case *screen*
    ((title) (menu-key! key))
    ((campaign) (menu-key! key))
    ((mode) (menu-key! key))
    ((level) (menu-key-with-level! key))
    ((play) (play-key! key))
    (else #f)))
```

and `play-key!` dispatches on *phase* — steering keys while live, onward keys
when over, resume keys when paused. Input handling is a two-level dispatch
(screen × phase) and nothing else. When a new screen appears, the compiler of
the `case` is the checklist.

## Exercises

0. ⟡ **Running project.** Paint Breakout: a painter that reduces your state
   to `draw-rect!` calls with a keyword layout table, plus an effects rail
   with one flash. Award it from your journal's `(brick-broken x y)` facts in
   a drain step, and prove the flash finishes by wiring `bview-busy?` into
   your loop's dirty flag.
1. Add a screen-flash when the level climbs: journal a `(level-up n)` fact,
   award `view-flash!` with the accent color in the award table, and assert on
   the fake host's `tint` log (chapter 9).
2. The danger pulse breathes on `*fx-t*`. Make the hold panel's pulse breathe
   on the same clock instead of a flat decay, and decide which reads better.
3. `menu-move` wraps or clamps depending on its guard. Make the campaign
   ladder *not* wrap (a ladder has ends) and add the check to the UI tests.

---

✓ **Checkpoint.** You can write a painter that is a pure reduction, keep
  animations in a decayed rail, and make the loop repay animation frames.

*Next: [The one-ply planner](08-the-planner.md) — an AI that budgets its
thinking like it budgets its frames.*
