# Chapter 6 — The edge

*The files it dissects: `scheme/presentation/view.scm`,
`scheme/conductor/arcade.scm`.*

The edge is where the game meets the world: screens, keys, sounds, pixels.
It is also where DSL codebases usually rot into soup. This chapter shows the
three structures that keep it clean: the painter as a *pure reduction*, the
menu as *data*, and the effects rail as *decayed state fed by facts*.

## 6.1 The painter is a reduction, not a renderer

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

A test reads the painted result back *pixel by pixel* through the real host
(`tests/test_host_smoke.py::test_painter_paints`): background, well frame,
cells. The painter is honest enough to be verified against a screenshot's
coordinates, because it is a pure reduction with no hidden state.

## 6.2 The effects rail: decayed state, fed by facts

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

This is the bridge between the dirty-flag optimization (chapter 5) and
animations: *nothing happened* is not the same as *nothing is moving*. Without
`view-busy?`, every animation would freeze the instant the match went quiet.

## 6.3 The award table: the journal becomes feedback

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

## 6.4 Screens and menus as data

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

## 6.5 One dispatcher for keys, per screen

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

1. Add a screen-flash when the level climbs: journal a `(level-up n)` fact,
   award `view-flash!` with the accent color in the award table, and assert on
   the fake host's `tint` log (chapter 8).
2. The danger pulse breathes on `*fx-t*`. Make the hold panel's pulse breathe
   on the same clock instead of a flat decay, and decide which reads better.
3. `menu-move` wraps or clamps depending on its guard. Make the campaign
   ladder *not* wrap (a ladder has ends) and add the check to the UI tests.

---

*Next: [The one-ply planner](07-the-planner.md) — an AI that budgets its
thinking like it budgets its frames.*
