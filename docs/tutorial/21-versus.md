# Chapter 21 — Versus

*The files it dissects: `scheme/presentation/view.scm` (the two-board
painter and the batch primitive), `scheme/conductor/arcade.scm` (the
duel session), and the bench that decided the layout.*

> **Where you are.** The duel is a pure value (chapter 18), the
> opponents have faces (chapter 19), the progress survives restarts
> (chapter 20) — and no human has ever been in the circuit. This
> chapter puts you in the left well.
>
> **By the end of this chapter you can** measure a painter before
> committing to a layout, grow a seam by a name that earned its place
> through a number, share one search between solo and versus play
> without duplicating it, and route one keyboard to one side of a
> two-sided fight.
>
> **The running project.** Breakout goes head-to-head: your paddle,
> a rival's, one ball, and a score sheet that remembers.

## 21.1 The number that decided the layout

The plan had a law for this stage: *measure the two-board painter
before committing to a layout.* So the measurement came first, and it
killed the obvious plan. One full board — 200 settled cells — painted
through the seam's per-cell `draw-rect!` cost **~27 ms**. Two boards:
~55 ms. An 18 fps worst case. The layout didn't matter; the *crossing
count* did. The paint itself is nothing — pygame draws 200 rectangles
in under a millisecond. The cost is 200 trips across the seam, ~130 µs
each.

The fix is one new primitive, and it is the cleanest case study for
the seam discipline of chapter 1: a name earns its place with a
number, not an opinion.

```python
def draw_rects(self, flat) -> None:
    """A batch of rectangles, one seam crossing for all of them."""
    surface = self._require_display()
    values = [int(v) for v in flat]          # (x y w h r g b) × n
    for i in range(0, len(values), 7):
        x, y, w, h, r, g, b = values[i:i + 7]
        pygame.draw.rect(surface, (r, g, b), pygame.Rect(x, y, w, h))
```

The Scheme side builds one flat list — seven numbers a cell, pushed in
reverse so one `reverse` finishes the job — and crosses once. The
board dropped from ~27 ms to ~2 ms; the two-board worst frame to a few
milliseconds, pinned by a bench test that paints **two full boards**
every run. The seam is nineteen names now, and the nineteenth is the
cheapest one in the vocabulary per rectangle painted.

## 21.2 Two wells, one window

The layout followed the measurement: two full-size wells do not fit
640 px, and scaling the cells down buys clutter, not room. So the
duel *re-opens the window* — 1088 px wide for the fight, the original
640 for everything else. The player's side is the whole solo picture
(hold, stats, keys, the combo popup); the opponent's side is a
next-only panel (the AI does not hold), a name plate, and the same
field at a second origin.

The painter refactor that made this cheap was parameterization, not
duplication: `draw-board-at!`, `draw-well-at!`, `draw-ghost-at!`,
`draw-playing-field!` all take an origin and a side, and the solo game
calls them with the constants it always used. One painter, two
addresses.

The effect rails split by ownership:

- **Per side:** the clear beam (each board wears its own), the garbage
  meter (what just landed on *you*), each side's lock counter (each
  AI reads its own).
- **The window's:** the flash and the shake — one veil, one thud.
- **The player's only:** the combo popup. One headline per side, and
  the opponent's combos read through their beam and the garbage they
  send — not through text painted over their well.

## 21.3 One search, two sides

The AI is the same one-ply planner (chapter 8) on both screens, and
the refactor that proved it was small: `ai-step-match!` takes a match,
the weights, the placement budget, and a lock counter, and answers the
new match. Solo play calls it with the player's dials; the duel calls
it with the persona's — weights, the speed knob as the budget, its own
lock count. One AI runs at a time (the player is human in a duel), so
the search state stays shared. The persona's *speed is literally the
number of placements its search may score per frame* — the honest
lever from chapter 19, now wired.

The duel frame reads like the discipline it inherited:

```scheme
(set! *duel* (duel-with-left *duel*
               (duel-events (duel-left *duel*) evs)))  ; keys first
(set! *duel* (duel-with-right *duel*
               (ai-step-match! ...)))                 ; the AI's step
(duel-award! 'left ...) (duel-award! 'right ...)       ; facts award
(set! *duel* (duel-step *duel* dt))                    ; the world moves
```

The awards run **before** the step, because the exchange drains both
journals inside the pure value — the edge's last look at a fact is its
only one. And the settle moved *out* of the live branch: a duel that
sits decided at frame entry must still write its record, the same
"settle once, whatever route" scar the solo loop earned chapters ago.

## 21.4 The ladder is the menu

The versus screen is the roster wearing its record: each persona with
title and tally, the next rung open, the rest locked — strict
sequential, because an accomplishment needs a gate. A win over the
rung the ladder points at advances it and writes the per-persona
record through the profile (chapter 20's document gaining its first
real reader); a loss keeps the tally and the gate. The keyboard routes
by screen as always — one new case in the dispatch, one new screen
with its own decision points (pause, forfeit, the result).

## 21.5 Pitfalls, one each

- **Measuring after the layout.** The 27 ms number inverted the plan's
  first-choice layout for free. Measure the hot path before the design
  commits, or the design will commit you.
- **Assuming the scenario instead of simulating it.** The first duel
  test idled the player and expected their stack to top out first. The
  Wall's own gravity ramp — hundreds of cleared lines — ended the
  *AI's* side first. The settle paths are forced top-outs now;
  deterministic, cheap, and honest about what they test.
- **A seam primitive without a fake.** `draw-rects!` exists in five
  places: the real host and four test stand-ins. The broadcast edit is
  the seam's toll — pay it in the same commit, or an unrelated suite
  dies at boot twenty minutes later.

✓ **Checkpoint.** You can measure a painter and let the number pick
the layout, batch a hot path across a closed seam, drive two matches
from one search, and wire a human into a fight that was, until now,
AI-vs-AI.

## Exercises

0. ⟡ **Running project.** Breakout versus: one window, two paddles,
   one ball, three rival knob vectors — and a scoreboard row that
   survives a restart.
1. The garbage meter fires the frame *after* the garbage lands (the
   exchange journals it; the edge sees it next frame). Sketch a
   *pending* garbage queue in the duel value — a warning beat before
   delivery — and name the two places the offset rule would have to
   learn about it.
2. The flash and shake are the window's, not the sides'. Argue the
   other half: what would per-side shake cost, and what would it read
   as? Write the answer as a comment on the rail's state.
3. The batch painter crosses once per board. Sketch the next
   measurement — what would `draw-text!` batching buy, and at what
   cost to the width-budget fitting? When is the answer "never"?
