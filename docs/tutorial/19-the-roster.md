# Chapter 19 — The roster

*The files it dissects: `scheme/content/roster.scm`, the `attack` term in
`scheme/domain/plan.scm`, and the persona sweep in
`tests/scm/domain-tests.scm`.*

> **Where you are.** The duel exists (chapter 18), and its loser is
> whatever the pipeline says it is. But "the AI" is one voice. This
> chapter gives the opponent a name, a title, and a personality you can
> measure.
>
> **By the end of this chapter you can** add an opponent as a diff to a
> data file, grow a scoring function by one term without disturbing its
> existing callers, know why the *speed* knob — not the weights — is the
> honest difficulty lever, and pin a personality with a seeded sweep.
>
> **The running project.** Breakout gets three rival paddles with
> different tracking styles and one shared score sheet: a wall that
> never chases, a chaser that never holds position, and a mirror.

The campaign (chapter 14's neighbor in `content/`) already established
the law: **content, not code** — a new level is a diff to a list. The
roster applies it to opponents. A persona is a record with two kinds of
fields, and keeping them apart is the whole design:

```scheme
(make-persona id: 'blitz
              name: "Blitz"
              title: "does not dig, does not care"
              weights: (weights 1.2 1.0 0.3 0.3 2.5)
              speed: 12
              band: 0.12)
```

- **Flavor** (`name`, `title`): mutable, translatable later, purely for
  the player.
- **Mechanics** (`id`, `weights`, `speed`, `band`): load-bearing. The
  id keys the ladder, the save file, and the locale table; the weights
  steer the search; the speed bounds the search per frame; the band is
  the leash the duel director will hold (chapter 22).

The weight vector is the planner's, grown by one. Chapter 8's four terms
judged *shape*; the fifth judges *events*:

```scheme
;; The rows this placement completes outright. A row is complete when
;; every column reaches it, so the count is exactly the rise of the
;; profile's minimum — before the clear collapses anything, which the
;; planner does not model.
(define (completed-rows heights raised)
  (- (min-of raised) (min-of heights)))
```

`placement-score` now reads as rewards minus penalties, with the
persona's appetite on the reward side:

```scheme
(- (+ (* (w-cleared ws) cleared)
      (* (w-attack ws) attack))
   (+ (* (w-holes ws) holes)
      (* (w-bumpiness ws) (bumpiness raised))
      (* (w-wells ws) (wells-sum raised rows))))
```

A high `attack` weight buys rows *this piece*, at exactly the price the
penalty terms name. Note what the term does **not** do: it does not
reach into the duel's attack table (chapter 18). The planner counts the
events; the duel prices them. Two layers, one fact each — the planner
never imports the pipeline, and the purity fence (chapter 11) holds.

## 19.1 What the sweep actually shows

A personality claim needs a measurement, the same way the director's
pacing did (chapter 17). The sweep: same seed, same deal, each style on
its own board for twenty locks, then read the board and the journal:

```scheme
(let* ((wall (style-report (persona-weights (persona-by-id 'wall))))
       (blitz (style-report (persona-weights (persona-by-id 'blitz)))))
  (assert "blitz digs far more holes than the wall"
          (> (cadr blitz) (* 2 (cadr wall))))
  (assert "the wall's flat stack clears the early rows"
          (>= (caddr wall) (caddr blitz))))
```

The numbers the seeds dealt: Blitz's board held **eight** holes to The
Wall's **two** — but The Wall *cleared more rows* (4 to 3). That
inversion is the chapter's honest center: at one-ply depth, "attack
appetite" does not show up as early aggression; it shows up as the mess
a style will tolerate to keep pieces moving. The flat stack — the
defensive shape — is what completes the early rows. One-ply personas
differ in **style**, and the sweep is what makes that a measured claim
instead of a vibe.

## 19.2 The speed knob is the honest lever

If the weights do not make an opponent *stronger*, what does? The
**speed** knob — and it is honest because its cost is visible and
bounded. The conductor's search (chapter 8) does not score forty
placements in one frame; it scores a budget and defers the rest:

```scheme
(define *best-per-frame* 6)  ;; placements scored per call
```

A persona's `speed` is exactly this number wearing a name. Twelve
placements a frame is a fast, sharp opponent; two is a thinker who
plays the same forty options a piece late. The difficulty is *latency
of judgment*, not depth of judgment — and it is provably bounded: the
search loop leaves the frame after `speed` placements, every frame,
whatever the board looks like. Chapter 13's worst-case thinking, turned
into a difficulty curve.

This is why the roster signs its honesty note: **"distinct opponents"
is the claim; "smarter AI" is not.** The weights make opponents feel
different; the speed knob makes them hard; the band (chapter 22) will
make them fair. Overselling one-ply weights as intelligence is the
fastest way to a player's justified distrust.

## 19.3 A meeting with the house bot

Style is measured solo; outcomes are measured in duels. Each persona
meets a scripted bot — the baseline weights, the same search — under
fixed seeds:

```scheme
(let ((w (duel-winner (self-play-with (persona-weights (persona-by-id 'wall))
                                      (weights 2.0 2.5 0.5 0.6 1.0)
                                      61 62))))
  (assert "the wall's meeting is decided" (memq w '(left right))))
```

Each meeting is its own top-level form, because a duel costs about
thirty-five million interpreter steps and the step budget is per form
(chapter 18's measured ceiling). The outcomes are deterministic by
purity — the same seeds crown the same winner forever — so the pinned
assertions are a *record*, and a retuned roster re-pins its record the
way a change to scoring re-pins its numbers.

## 19.4 Pitfalls, one each

- **A personality without a sweep is a font choice.** Naming an
  opponent "Blitz" and giving it fast weights proves nothing until a
  seeded run shows the board it produces. The sweep is cheap; the
  vibe is expensive.
- **The weights are not a difficulty slider.** One-ply depth cannot be
  tuned smarter — only different. Reach for the speed knob when a rung
  must be harder, and for the band when it must be fairer.
- **Content ids are load-bearing.** Renaming `'blitz` to `'blitz2`
  breaks every save file and ladder entry that names him. Flavor is
  mutable; ids are forever — the same discipline as the journal's
  closed event vocabulary (chapter 5).

✓ **Checkpoint.** You can add an opponent as a data diff, price a new
preference with one term that leaves every existing caller intact,
bound an opponent's per-frame cost with a named knob, and prove a
personality with a seeded sweep.

## Exercises

0. ⟡ **Running project.** Give Breakout its three rival paddles: a wall
   (never leaves center), a chaser (always tracks the ball), a mirror
   (copies your last move). Same paddle code, three *knob vectors* —
   and one seeded sweep proving the styles play differently.
1. Add a fifth persona of your own to the roster — id, flavor, five
   dials — and write the sweep assertion that would fail if its weights
   were a copy of The Wall's. What does your opponent tolerate that
   nobody else does?
2. The planner counts completed rows, but the duel's table pays
   non-linearly (0, 1, 2, 4). Sketch what a *table-aware* attack term
   would do to the dependency DAG — which library would need to import
   which — and decide whether the purity fence should bend or the
   duplication should live. Say why in a comment.
3. Run the persona sweep at forty locks instead of twenty. Do the
   style gaps widen or close? What does that tell you about one-ply
   horizons — and about how long the sweep should run to be evidence?
