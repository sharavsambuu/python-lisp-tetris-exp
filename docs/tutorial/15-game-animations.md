# Chapter 15 — The moving edge: game animations

*The files it dissects: `scheme/presentation/view.scm`,
`scheme/conductor/arcade.scm`.*

> **Where you are.** Chapter 7 introduced the effects rail — a flash, a
> shake, a beam, fed by journal facts. This chapter goes deeper, pop by
> pop: the actual *math* of one animation, how one rail serves many
> moments, how a run's depth becomes a dose, and the two contracts that
> keep animations honest — the repaint gate and the width budget.
>
> **By the end of this chapter you can** dissect any animation into
> progress, ease, and paint; serve several moments from one decayed rail
> without them fighting; make an animation's *intensity* read a game
> quantity; and guarantee that every animation finishes and every label
> fits.
>
> **The running project.** ⟡ Breakout gets a combo of its own: a
> `brick-combo` popup that pops in big, escalates with consecutive brick
> breaks, and fades — the full anatomy of this chapter, on a smaller game.

The animations in this game are deliberately small — a flash, a shake, a
beam, one popup. What makes them feel *finished* is not quantity; it is
that each one is built from the same three-part anatomy, honored the same
two contracts, and paced by the same clock. This chapter dissects them in
that order.

## 15.1 The rail is data, decayed by real dt

The whole animation system is a handful of decayed variables in the view —
no animation objects, no scene graph, no callbacks:

```scheme
(define *shake-px* 0.0)
(define *flash-rgb* #f)
(define *flash-ms* 0)
(define *beam-rows* '())
(define *beam-ms* 0)
(define *hold-pulse-ms* 0)
(define *pop-ms* 0)
(define *pop-kind* #f)
```

One step per frame decays them all, and it receives the *real* dt:

```scheme
(define (view-fx-step! dt st)
  (set! *fx-t* (+ *fx-t* (/ dt 1000.0)))
  (set! *shake-px* (max 0.0 (* *shake-px* 0.85)))
  (set! *pop-ms* (max 0 (- *pop-ms* dt)))
  ...)
```

Two rules make this rail trustworthy. First, **decay in milliseconds, not
frames**: a flash awarded `120` wears off in 120 *milliseconds*, so a 60 fps
run and a 144 fps run wear it the same length. A rail that decays "per
frame" paces animations to the render rate — the classic slideshow bug.
Second, **floors everywhere**: `(max 0 ...)` on every timer, so an
overshoot can never turn a timer negative and a `> 0` test can never lie.

## 15.2 One pop, dissected

The combo popup is the game's most complete animation — every trick in one
block. Here it is, then the dissection:

```scheme
(if (> *pop-ms* 0)
    (let* ((total (if (eq? *pop-kind* 'b2b)
                      1100
                      (+ *combo-pop-ms* (* 100 (min 4 (- *combo-n* 1))))))
           (t (- 1.0 (/ *pop-ms* total)))            ; progress 0..1
           (pop (max 0.0 (- 1.0 (* t 5.0))))         ; first fifth: pop-in
           (base (+ 20 (* 6 (min 4 (- *combo-n* 1))))) ; the run's depth
           (size (min 44 (exact (round (* base (+ 1.0 (* 0.6 pop)))))))
           (s (if (eq? *pop-kind* 'b2b)
                  (tr 'popup-b2b)
                  (tr-fmt 'popup-combo *combo-n*)))
           (hot (if (eq? *pop-kind* 'b2b) (color warn:) (color accent:)))
           (rgb (mix-rgb '(16 16 24) hot (max 0.0 (- 1.0 (* t t))))) ; fade
           (x (centered-x (lay board-x:)
                          (* matrix-width (lay cell:))
                          s size)))
      (draw-text! x (+ (lay board-y:) (cell-size) 4) s size rgb))
    #f)
```

Every animation in the game answers the same four questions — read them off
the bindings:

- **How long does it live?** `total` — 900ms for a combo, plus 100ms per
  link beyond the first, capped at four. A deeper run *stays* longer; the
  lifetime itself is part of the dose.
- **How far along is it?** `t` — the fraction of life already spent. Every
  ease in the game is a function of this one number, never of frame count.
- **How does it enter and leave?** `pop` is `1 - 5t` floored at zero: the
  type starts 1.6× its size and settles within the first fifth of the
  life — a *pop-in*, not a fade-in. The fade is the mirror image:
  `(mix-rgb dark hot (1 - t²))` blends the color toward the veil's dark
  with a quadratic ease, so the exit accelerates. Enter fast, leave
  faster: feedback should be felt, not watched.
- **What does the moment say?** The text comes from the locale table
  (`tr`/`tr-fmt`), the color from the moment's kind — the *painter* never
  hardcodes a word or a mood.

Note what the block does *not* do: no timers of its own, no allocation per
frame beyond a few numbers, no state change at all. A painter frame is a
pure function of (state, rail) — chapter 7's contract, kept under load.

## 15.3 One rail, many moments

The combo run and the b2b chain could each own a timer, a text binding, a
paint branch — two animations where one serves. The build folds them into
**one rail with a kind tag**:

```scheme
(define (view-combo-pop! n)
  (set! *pop-kind* 'combo)
  (set! *combo-n* n)
  (set! *pop-ms* (+ *combo-pop-ms* (* 100 (min 4 (- n 1))))))
(define (view-b2b-pop!)
  (set! *pop-kind* 'b2b)
  (set! *pop-ms* 1100))
```

The award table feeds both, and a rarer moment overwrites a commoner one —
a b2b Tetris *is* a clear, so the chain's opening takes the stage. One rail
means one decay, one `view-busy?` arm, one paint branch — and the two
moments cannot fight for the screen because there is only one stage.

The general rule: **moments share a rail; kinds share a painter.** When a
third moment arrives (a level-up announcement? a record badge?), the
question is never "where does its timer go" — it is "is it a new kind, or
does it reuse one?"

## 15.4 Escalation: the depth is the dose

A combo that looks the same at link two and link five is a label, not a
feedback loop. The escalation rides the run's depth through every channel
the popup has:

```scheme
;; The size escalates: +6px a link, capped at four links deep.
(base (+ 20 (* 6 (min 4 (- *combo-n* 1)))))
;; The lifetime escalates: +100ms a link, capped the same way.
(+ *combo-pop-ms* (* 100 (min 4 (- *combo-n* 1))))
```

And the pitch escalates in the speaker (chapter 16) with the same cap. The
cap is the taste: **a ten-link run stays a chord, not a siren.** Every
escalation has a ceiling, and the ceilings agree — the dose grows for the
first few links and then *holds*, so the feedback saturates instead of
spiking. The player reads "this run is deep" from the first three links;
beyond that, more pixels would be noise.

The same taste sets the *floor*: link two is already visibly bigger than
link one's nothing. An escalation that starts at zero reads as a bug; one
that starts at "slightly more" reads as momentum.

## 15.5 The repaint gate: the loop owes frames

Animations are the bridge between the dirty flag (chapter 6) and the
player's eye. The loop repaints when *something happened* — and the rail
answers when something is *still moving*:

```scheme
(define (view-busy? st)
  (or (> *flash-ms* 0)
      (> *beam-ms* 0)
      (> *hold-pulse-ms* 0)
      (> *pop-ms* 0)
      (not (= *score-shown* (game-score st)))
      (and (danger-tint? st) (<= *danger-paint-ms* 0))))
```

Every rail timer appears here, or its animation freezes the moment the
match goes quiet. This is also where the game's most instructive
regression lived — worth telling as a story, because the fix shaped the
whole gate.

**The idle fall.** A player reported: with no keys pressed, the falling
piece froze on screen; press a key and it jumped to where it belonged. The
logic was fine — the piece fell, the board advanced. The *paint gate* was
blind: it read the journal, and gravity's falls are **silent by design**
(a journal fact per tick would machine-gun the speaker — chapter 16). So
an idle match repainted *nothing*.

The fix lives in the conductor's stair over the time step — the gate
learned to answer a different question. Not "did the journal speak", but
"did anything the screen could show, change":

```scheme
;; Gravity is silent by design: a fall journals nothing, or the speaker
;; would blip once per tick — so the journal cannot tell the paint gate
;; that the world moved while the player idled. Time moved the *visible*
;; world when the active piece changed (it fell, or a lock spawned the
;; next shape) or the clock crossed a whole second (the ultra's HUD
;; counts in them).
(define (piece-fields p)
  (if p
      (list (falling-name p) (falling-x p) (falling-y p) (falling-rot p))
      '()))
```

The test that pins it burns the boot frame's dirty flag first, queues a
second of ticks with no input, and asserts the piece advanced *and* the
frame count grew. Two lessons fall out, and both generalize:

- **The gate's question is visibility, not activity.** Clock ticks that
  change no pixel may pass silently; clock ticks that change the ultra's
  countdown may not.
- **A silent rule needs a spokesman.** When a rule is quiet *on purpose*,
  some other signal must carry what it would have said — or the player
  sees a frozen world while a live one advances underneath.

One refinement keeps the gate cheap: the danger pulse repaints the *whole*
board every frame it breathes, and a full board's repaint is real money
(chapter 13). So the pulse is gated — it re-arms a 66ms ticket when it
paints, and the busy test reads the ticket: the pulse samples at ~15 fps,
and the frames between are free.

## 15.6 The type scales, the text never

The panels do not move, but translations do — Mongolian runs about ten
percent wider than the width the English layout assumed, and long labels
ran past the window edge. The fix is a painter policy, not a layout change:

```scheme
;; A locale's spellings differ in length, and the panels do not move —
;; so the TYPE scales, never the text: shrink the size until the
;; string fits its budget (floored at 10, so a pathological string
;; degrades to small type, not to nothing).
(define (fit-size s size max-w)
  (if (or (<= size 10) (<= (text-width s size) max-w))
      size
      (fit-size s (- size 1) max-w)))

(define (draw-text-fit! x y s size rgb max-w)
  (draw-text! x y s (fit-size s size max-w) rgb))
```

The policy is one sentence — **the type scales, the text never** — and it
rides a single measurement per shrink step (`text-width`, one cached-font
call), only while the string overflows, only on frames that paint it. The
floor matters as much as the loop: without it, a pathological string
degrades to *nothing*; with it, to *small type* — visible, honest, and
impossible to lose.

The general form: when two constraints collide (fixed panels vs free
text), decide which one bends *in the policy*, name the sentence, and put
the measurement where the loop can afford it.

## Exercises

0. ⟡ **Running project.** Breakout's `brick-combo`: award a popup from
   consecutive brick breaks — pop-in over the first fifth, fade on the
   square, size +2px per link capped at five — and prove it finishes by
   asserting the frame count stops growing once the rail drains.
1. The b2b popup's lifetime is a flat 1100ms. Make it escalate with the
   chain's *payout* instead of a constant, and decide (in a comment)
   whether the player can even read the difference.
2. The score ticker eases with `max 1 (quotient gap 8)`. Change the ease
   to a square (`gap² / 1000`, floored) and feel the difference on a
   tetris's 800 points versus a single's 100.
3. The danger pulse samples at ~15 fps. Make the sample rate fall as the
   stack rises — the closer to the ceiling, the faster the breath — and
   cap it so a full repaint never happens twice a frame's worth.
4. `fit-size` floors at 10. Write the UI test that crafts a 60-character
   label in the keys panel and asserts it paints at the floor instead of
   vanishing.

---

✓ **Checkpoint.** You can dissect any animation into progress, ease, and
  paint; serve many moments from one decayed rail; dose a feedback loop
  with ceilings; keep the repaint gate answering *visibility*; and bend
  type instead of text when constraints collide.

*Next: [The mixing desk](16-game-sound.md) — the speaker seam, the ranking
table, and the announcer that rides on top.*
