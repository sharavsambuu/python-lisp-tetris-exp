# Chapter 6 — Frames and time

*The files it dissects: `scheme/conductor/arcade.scm` (the loop),
`host/pygame_host.py` (the clock and the pump).*

> **Where you are.** You can model a match as a value and its transitions as
> arrows. Nothing moves yet — this chapter is where time arrives.
>
> **By the end of this chapter you can** write a frame loop with the four
> ordering disciplines, bank milliseconds for gravity, clamp dt at the
> boundary, and explain why the DAS/ARR pump lives in the host and not the
> game.
>
> **The running project.** Breakout's ball starts moving: a frame loop with
> banked dt, and a dirty flag so quiet frames cost nothing.

A game loop is where "pure functional" meets "60 times a second." This chapter
walks one frame end to end, then goes deep on the two time disciplines that
took the longest to get right: gravity banking and the input repeat pump.

## 6.1 One frame, in order

The play screen's frame is `play-frame` in the conductor:

```scheme
;; One frame of the live match. The order is the discipline: events
;; first (a key press lands *before* the gravity of the frame it
;; happened in) — and the state the events produced is SAVED, or the
;; player's keys would land in a discarded world — then the AI's one
;; step, then gravity, then the draw. A frame draws only when something
;; happened. Held-key repeats arrived in this frame's events, pumped by
;; the host on its own clock.
(define (play-frame st dirty)
  (let* ((dt (tick!))
         (evs (poll-events!)))
    (set! *st* (apply-events st evs))
    (ai-step!)
    (let-values (((st* time-moved) (step-time-v *st* dt)))
      (set! *st* st*)
      (view-fx-step! dt *st*)
      (let* ((anything (or *dirty* time-moved
                           (view-busy? *st*)
                           (not (null? (game-journal *st*))))))
        ;; The drained state is the state: `drain-journal!` answers the
        ;; record with the paper trail cleared, and losing that value
        ;; would re-count every old fact on every frame — the journal
        ;; must actually drain.
        (if anything
            (begin
              (draw-game! *st*)
              (set! *st* (drain-journal! *st*)))
            #f)))))
```

Four disciplines, each learned from a bug:

1. **Events before gravity.** A key press lands in the frame it happened in.
2. **Save the event state.** `apply-events` returns a new state; forgetting
   the `set!` means keys land in a discarded world.
3. **Draw only when something happened** — the dirty flag, `time-moved`,
   `view-busy?` (an animation still running), or a journal waiting to be read.
4. **Thread the drained state.** The comment is a scar: a rewrite once dropped
   `drain-journal!`'s return value, and stale facts re-fired every frame —
   the AI's lock counter ran away, sounds machine-gunned, frames repainted
   forever. *A pure function that answers "the state after" must be threaded.*

## 6.2 Gravity banks milliseconds

The naive gravity is `if (elapsed > interval) fall`. The correct one is a
**bank**: accumulate the frame's dt, pay whole ticks out, keep the remainder.

```scheme
;; One frame of banking: add the frame's dt to the bank, and answer the
;; new bank together with how many whole ticks it now pays for. The
;; remainder stays banked — no milliseconds are lost at level changes.
(define (advance-bank bank dt interval)
  (let* ((owed (+ bank dt))
         (ticks (quotient owed interval)))
    (values (- owed (* ticks interval)) ticks)))
```

`scheme/policies/gravity.scm` owns the curve (`drop-interval`); the pipeline
spends the bank (`step-time`), and stops the moment the phase changes under it:

```scheme
;; Run the ticks the bank paid for, stopping the moment the phase changes
;; under us (a lock can end the game mid-burst).
(define (gravity-ticks state n)
  (let loop ((s state) (i 0))
    (if (or (>= i n) (not (playing? s)))
        (ok s)
        (result-bind (soft-fall s) (cut loop <> (+ i 1))))))
```

### The bank, in numbers

One second of play at level 1 (interval 900ms), frame by frame:

| frame | dt | owed = bank + dt | ticks | new bank | the piece |
|------:|---:|-----------------:|------:|---------:|-----------|
| 1–55 | 16 | 16 … 880 | 0 | 16 … 880 | waits |
| 56 | 16 | 896 | 0 | 896 | waits |
| 57 | 16 | 912 | **1** | **12** | falls one row |
| 58–111 | 16 | 28 … 888 | 0 | … | waits |
| 112 | 16 | 904 | **1** | **4** | falls again |

Two things to notice. First, the tick lands on frame 57, not 56.25 — the
bank *absorbs* the fact that frames are indivisible, and the 12ms remainder
is why the next tick comes at frame 112 and not 113. Second, imagine a level
up between frames 57 and 112 (interval drops to, say, 600): the banked
remainder keeps counting — no milliseconds are lost at level changes, which
is the whole reason the bank lives in the state instead of a local.

Three details that matter:

- **The bank lives in the game state**, so a paused match freezes time by
  simply not being stepped.
- **A level change never loses milliseconds** — the remainder survives.
- **The clock is also a mode condition**: an ultra's zero crosses into a
  victory on the clock's own track, right here — the same `check-victory` the
  lock track uses.

## 6.3 The dt clamp

`host/pygame_host.py`:

```python
def tick(self) -> int:
    """One frame: hold ~60 fps, answer the elapsed milliseconds."""
    dt = self.clock.tick(60)
    # A hitch (GC, OS, a slow first frame) must not hand the conductor a
    # giant dt: gravity would leap rows and the repeat pump would land
    # a burst of moves in one frame — the player sees a skip. The clock
    # is capped at four frames' worth; the loop is already behind, and
    # catch-up beyond that reads as a stutter, not as time.
    dt = int(min(dt, 66))
    self._last_dt = float(dt)
    self._frames += 1
    return dt
```

A window drag is a 3-second frame. Without the clamp, one drag hands the game
180 gravity ticks and 90 DAS repeats — the player comes back to a different
world. With it, a hitch costs at most four frames of game time. **Clamp at the
boundary where time is measured, not in the game logic** — the game should be
able to trust its dt.


## 6.4 The input pump lives in the host

Held-key repeat (DAS/ARR) has a natural home, and it took three attempts to
find it. The final design is the donor project's: the *host* pumps repeats as
events, the game never tracks held state.

```python
#: The held-key repeat pump — the same cadence the reference edge uses:
#: how long a hold waits before its first repeat, and how fast it repeats
#: after that. The pump lives here, in the edge, NOT in the game: KEYDOWN
#: starts a key's countdown, KEYUP removes it, and every frame the pump
#: fires ``key-repeat`` events for the keys that are due — exactly periodic
#: in time, immune to frame jitter, and immune to the stale-credit bug a
#: hand-threaded game timer grows.
REPEAT_DELAY_MS = 150
REPEAT_INTERVAL_MS = 40
```

The pump itself, run every `poll_events`:

```python
# The pump: every held key counts down by this frame's dt, and each
# time one lands at zero it fires a repeat and re-arms.
dt = self._last_dt
for key, remaining in list(self._held.items()):
    remaining -= dt
    name = KEY_NAMES.get(key)
    while remaining <= 0 and name:
        events.append([[K_TYPE, T_KEY_REPEAT], [K_KEY, name]])
        remaining += REPEAT_INTERVAL_MS
    self._held[key] = remaining
```

### The pump, in numbers

You press and hold `left` at frame 0. With dt = 16ms per frame:

| frame | countdown after this frame | events |
|------:|---------------------------:|--------|
| 0 (KEYDOWN) | 150 − 16 = 134 | the press itself → one move |
| 1–8 | 118 … 22 | silence — 128ms in, still inside the delay |
| 9 | 6 | silence |
| 10 | 6 − 16 = **−10** → fire, re-arm to 30 | one `key-repeat` |
| 11 | 14 | — |
| 12 | −2 → fire, re-arm to 38 | one `key-repeat` |
| 13–15 | 22, 6, −10 → fire | one every 2–3 frames |

Steady state: a repeat every 40ms of *game time*, which at 60fps is 2–3
frames — and at 30fps is 1–2 frames. The rate is in **milliseconds**, not
frames, which is the entire point: halve the frame rate and the glide speed
stays the same. A frame-counting pump would glide half as fast on a slow
machine.

The events themselves are the same alist shape every other event uses, so the
conductor's fold never special-cases them:

```scheme
;; what one poll hands back, when a key came due:
(((type: . key-repeat) (key: . "left")))
```

Why the host and not the game? Three failures taught the lesson:

1. **SDL's own repeat** only ever repeats the *last* key — so tapping rotate
   while holding left kills the left repeat. The host pumps *every* held key.
2. **A game-side timer** must be threaded through every frame function; a
   rewrite dropped it and holds went dead.
3. **Stale credit**: a game-side timer that survived a key re-press made the
   new hold repeat instantly — a lurch. Per-key countdowns in the host start
   from the KEYDOWN itself, so the bug has nowhere to live.

The Scheme side stays trivial — a closed table of which repeats mean anything:

```scheme
;; The keys a *held* key may repeat — one-shots (rotate, hard drop,
;; hold, restart) stay one per physical press. The host pumps the
;; repeats; this table is only the conductor's "which repeats mean
;; anything" decision.
(define repeat-able '("left" "right" "down"))
```

and one `case` arm in `apply-event` that applies the command *without* the
press blip — 25 blips a second is a machine gun, not feedback.

## 6.5 The loop is a tail call

The whole program is:

```scheme
(let loop ()
  (if (quit-requested?)
      (begin (quit!) #f)
      (begin
        (arcade-step!)
        (loop))))
```

A tail call, so the loop runs forever in constant stack. An embedded DSL does
not need a runtime loop from the host — Scheme's own recursion is the loop,
and "quit" is a fact the host observes.

## Exercises

0. ⟡ **Running project.** Write Breakout's frame loop: `tick!` for dt, bank
   the milliseconds toward the ball's next step, move on whole ticks, clamp
   nothing in game logic — and draw only when the ball moved or a journal
   fact waits. Then hold a wall-destroying 2-second dt in your head and
   explain why the clamp lives in the host.
1. Pause currently freezes gravity by not stepping. Make pause *also* freeze
   the ultra clock and prove it by stepping 100 paused frames and asserting
   `game-clock` is unchanged.
2. Raise `REPEAT_INTERVAL_MS` to 60 and add a test that a 500ms hold moves
   left exactly the right number of cells. Feel is a test now.
3. The pump fires repeats even when the game is paused (the conductor ignores
   them). Move that decision into the host by clearing `_held` on pause — or
   argue why the conductor is the right owner.

---

✓ **Checkpoint.** You can write the frame loop in the right order, bank time
  so no milliseconds are lost, and argue for the pump's home in the host from
  three failed alternatives.

*Next: [The edge](07-the-edge.md) — screens, menus, and the effects rail.*
