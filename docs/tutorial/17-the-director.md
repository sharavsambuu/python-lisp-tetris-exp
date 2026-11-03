# Chapter 17 — The director

*The files it dissects: `scheme/domain/telemetry.scm`,
`scheme/domain/director.scm`, the `pace` field in `scheme/domain/game.scm`,
and the `direct!` step in `scheme/conductor/arcade.scm`.*

> **Where you are.** The game is complete: smart (chapter 8), proven
> (chapter 9), fast (chapter 10, 13), and it feels good (chapters 14–16).
> This chapter adds the loop the player never sees: one that watches the
> match and paces it.
>
> **By the end of this chapter you can** read a game's state as a single
> regulated number, hold that number in a band with a dead band and hard
> clamps, carry the decision on the match record itself, and measure a
> pacing change under a seed.
>
> **The running project.** Breakout gets a director: when the ball's
> rallies die too fast, the paddle lengthens; when they last too long, it
> shortens. Same skeleton, different probes.

Chapter 8 built a controller that plays. This chapter builds one that
*watches* — a second loop over the match, closing through the pacing knobs
the domain already publishes. The two loops are independent: the AI steers
pieces, the director paces time, and neither knows the other exists.

## 17.1 Telemetry: the state as a number

A decision needs a reading. `(tetris telemetry)` is pure probes over the
game value — no hooks, no clock, no state:

```scheme
;; The regulated number: 2/3 the mean, 1/3 the peak, over the well's
;; height. 0 = empty, 1 = full.
(define (pressure st)
  (/ (+ (* 2 (stack-mean st)) (stack-peak st))
     (* 3 matrix-height)))
```

Two disciplines make a probe trustworthy. First, a **documented range** —
pressure answers 0..1, so a decision can be arithmetic on it and a test can
pin it. Second, **the blend says what matters**: the mean alone would hide
the one tall column that actually ends matches, so the peak rides along at
a third. A probe is a claim about what to look at; write the claim down
next to the arithmetic.

## 17.2 The decision core: band, error, clamps

`(tetris director)` turns a reading into a pace multiplier. The shape is
the oldest one in the book:

```scheme
(define (director-pace d pressure)
  (if (<= (abs (- pressure (director-target d))) (director-band d))
      1
      (pace-clamp d (- 1 (* (director-gain d)
                            (- (director-target d) pressure))))))
```

Three decisions, each worth naming:

- **The dead band.** Inside the band around the target the director holds
  (pace 1) — the level's own curve, untouched. Without it, the pace
  chatters: every cleared row would swing the multiplier.
- **The sign.** Pressure *below* the target means a player with room to
  spare, so the pace drops below 1 and the well falls faster; pressure
  above buys relief. Write the sign down — inverted feedback is the bug
  that feels like lag.
- **The clamps.** The pace range (`low-pace` 0.5, `high-pace` 2.0) is a
  hard contract: *the director may bend the curve, never leave the
  player's hands.* A pacing loop that can pin the player is a bug with a
  difficulty setting.

The knobs are a value (`make-director` with keyword defaults, SRFI 89), so
a mode or a campaign can carry its own director without touching the core —
the same move as the scoring policies in chapter 14.

## 17.3 The actuator: pace as a field of the match

Where does the pace live? In the match record itself:

```scheme
;; `pace` is the multiplier the director bends the gravity curve by —
;; 1 plays the curve untouched, below 1 falls faster, above 1 falls
;; slower. A field of the record on purpose: the pacing a match plays
;; under is part of the match's value, so a replay replays the director's
;; decisions too.
```

and gravity bends through one seam:

```scheme
(define (paced-interval level pace)
  (max curve-floor (* pace (drop-interval level))))
```

This is the chapter's structural lesson. The plant stays pure — `step-time`
just reads a field — and the director never reaches into the rules; it
writes a value the rules already read. A restart resets the pace with
everything else, a replay replays it, and the tests assert on it like any
other field. If your regulator's decisions are not *in the state*, they are
not part of the game.

Note the floor: the curve's 60ms holds even at pace 0.5 on a level-30
curve. A limiter at the actuator backs the limiter at the decision — two
chances to refuse.

## 17.4 The edge loop: speak slowly, and only when there is something to say

The decision core is stateless; the *loop* around it lives in the
conductor, beside the AI's:

```scheme
(define (direct! st)
  (let ((m (director-pace *director-config* (pressure st))))
    (if (and (>= (- (game-clock st) *director-last*) *director-cooldown*)
             (>= (abs (- m (game-pace st))) 0.05))
        (begin
          (set! *director-last* (game-clock st))
          (with-event (game-with st pace: m) (paced m)))
        st)))
```

Two throttles, because a director that speaks every frame is a director
that is not listening: a **cooldown** (ms of match clock between
adjustments) and a **threshold** (a change smaller than 0.05 is not worth
a fact). And when it does speak, it speaks in the journal — `(paced m)` is
a fact like `(cleared rows)`, so the match's record carries the director's
side of the story, and every consumer downstream keeps working untouched.

## 17.5 Measuring: the seed is the experiment

`--director` boots the loop; `d` toggles it mid-match. The point of the
flags is the A/B run:

```
python -m host --headless --frames 2000 --autostart --mode marathon --seed 7 --ai
python -m host --headless --frames 2000 --autostart --mode marathon --seed 7 --ai --director
```

Same seed, same disturbances, one variable. Record the pressure each run
and compare the time *outside* the band — that number is the director's
whole report card. A pacing change you have not measured under a seed is a
vibe.

## 17.6 Pitfalls, one each

- **Inverted feedback feels like difficulty.** A sign error makes the
  director push the player *further* from the band, smoothly and
  confidently. The unit test that catches it: pressure 0 must cool the
  pace *below* 1, pressure 1 must raise it *above*.
- **A probe without a range is a rumor.** If `pressure` did not promise
  0..1, the gain, the band, and the clamps would be guesses pinned to
  nothing.
- **The loop is not the core.** Keep the decision pure and the loop in the
  edge, exactly like the AI's search (chapter 8). The day you want a
  different cooldown, a different setpoint per mode, or a director that
  only runs in campaign, you move edge code — the arithmetic never moves.

✓ **Checkpoint.** You can read a match as one number, hold that number in
a band with a dead band and hard clamps, carry the decision on the match
record, and measure the difference under a seed.

## Exercises

0. ⟡ **Running project.** Give Breakout a director: a probe (average rally
   length over the last N bounces), a target, and one knob (paddle width).
   Hold the rally length in a band, and log every adjustment.
1. Give the sprint mode its own director — a tighter band, a hotter gain —
   by passing knobs at `start-match!` time. Nothing in `(tetris director)`
   changes.
2. The director currently paces gravity only. The bag is a value too
   (`bag-refill-from`): sketch — carefully — what a generosity knob would
   do to the replay story, and decide whether you would ship it.
3. Log the pressure *with* each `(paced m)` fact, then plot both series
   from a seeded run. Where does the director overshoot, and which knob
   would calm it?
