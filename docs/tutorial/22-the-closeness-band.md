# Chapter 22 — The closeness band

*The files it dissects: `scheme/domain/director.scm` (the leash's pure
arithmetic), `scheme/conductor/arcade.scm` (the duel director's loop
and the retune), `scheme/conductor/profile.scm` (the "leashes" shelf),
and the seeded A/B that measured the claim.*

> **Where you are.** The fight exists (chapter 18), the opponents have
> faces and leashes (chapter 19), the memory persists (chapter 20),
> and you are in the circuit (chapter 21). One loop is missing: the
> one that keeps the fight *worth having*. This chapter closes it —
> and with it, Part VII.
>
> **By the end of this chapter you can** build a regulator whose probe
> is a *relationship* rather than a state, hold the ethical wall
> between "adjusting the game" and "adjusting the player", tune by
> experiment instead of arithmetic, and let a slow outer loop learn
> across sessions through a document that already exists.
>
> **The running project.** Breakout's director holds the rally gap,
> not just the rally length: a probe over both paddles' distances, an
> actuator that touches only the rival paddle.

## 22.1 The probe is a relationship

The solo director (chapter 17) regulates one player's *pressure* — a
number about a single board. The duel's director regulates the *gap
between two sides*, and a gap is a relationship: it has a sign and a
magnitude, and both matter.

The probe — `duel-gap` — reads each side's lines cleared plus four
lines' worth of board pressure (the telemetry's 0-to-1 blend of mean
and peak stack height, chapter 17's probe doing a second job), and
subtracts: positive means the player is ahead, negative means the AI
is running away. Pressure weighs four lines a side because a full
board and a four-line deficit end the match the same way. The raw gap
normalizes against a *blowout scale* — eight lines-equivalent — so
`closeness` reads 0 at a knife's edge and 1 at a blowout, and every
band in the game is a fraction of that one scale.

Note what the probe does *not* read: pending garbage. The exchange
lands garbage the frame it resolves (chapter 18's offset rule), so
there is nothing pending to read — the exercise that sketches a
warning beat (chapter 21, exercise 1) is also the exercise that would
teach this probe a third term.

## 22.2 The band, the throttle, the wall

The leash's hold zone is the *band* — and the band is not the
director's knob. It is the persona's. The roster gave every opponent a
`band` in chapter 19 ("tighter means a harder rung, stage 6"); the
director simply honors it. The Wall holds you to a knife's edge
(band 0.06); the Scholar all but reads your screen (0.02).

Outside the band, the error moves one multiplier, in one direction:
the AI behind speeds up, the AI ahead slows down, clamped to a range
the player can feel but not fear (0.6–1.6). The multiplier bends two
actuators, and the ethical wall is the whole design:

- **the budget** — the placements the AI's search may score per frame.
  The persona's speed knob (chapter 19's honest lever) times the
  throttle;
- **the gravity** — the same move, damped to half strength, on the
  AI's well's fall rate.

Never the player's garbage. Never the player's pieces. Never the
player's gravity. The asymmetry is the point: a director that bends
the player is a director that plays the game for you, and the player
*will* feel it even if they cannot name it. The wall costs nothing to
enforce — it is which game's fields the actuators touch — and it is
why the mode can be called fair with a straight face.

And the throttles of the loop itself: the solo director speaks every
second past a 0.05 change. The duel director waits two seconds past a
0.03 change. *Slower and quieter* — visible rubber-banding is the
fastest way to kill a versus mode. The band does the work; the
adjustments only maintain it.

## 22.3 The claim, measured

"Adaptive difficulty" is a claim, and the plan's done-when demanded
the number: a seeded self-play duel, twice — the leash off, the leash
on. The left side plays the Mirror's weights acting every second
frame; the right plays the Wall's weights acting every third; same
seeds both runs.

| run | mean \|gap\| | frames within 2 lines | outcome |
|---|---|---|---|
| leash off | 2.38 | 52% | undecided at 600 frames |
| leash on | 0.73 | 94% | decided at 502 — the *Wall* won |

The band held: three times closer, nearly twice the time in the fun
zone. And the second row carries a warning the table can't soften:
the leash was strong enough to *flip the outcome* — the weaker
persona won the directed run. Keeping a fight close and deciding who
wins are different services, and a regulator with clamps this strong
is doing both. The gain and the clamps are tuned by playing, not by
arithmetic; if the flip bothers you, the dials to reach for are the
gain (2.0) and the high clamp (1.6).

## 22.4 The slow outer loop

The band holds one match. The *retune* holds a rivalry: every settled
duel moves the persona's band one step — a win tightens it (a harder
re-fight), a loss loosens it — clamped so it never reaches zero and
never stops caring. The step rides the profile's `"leashes"` shelf,
the document stage 4 versioned from day one with this shelf sketched
into its header, so the tuning survives the restart.

This is the homeostat's second loop, and its honesty matters: the
outcome touches one knob, one step, and the knob only ever bends the
*AI's* leash. A losing streak loosens the band — the AI is reeled in
sooner, held closer, denied its runaway — which is the system
admitting, in data, that it was too much. No dialog asks how you're
feeling. The record is the feeling.

## 22.5 Pitfalls, one each

- **A probe without a sign.** The first draft normalized |gap| and
  lost the direction — the director could see the blowout but not
  whose it was. A closeness differential is signed or it is useless;
  the throttle's direction *is* the sign.
- **A metric that flatters the regulator.** "Time in band" with the
  band's own width as the window measures the band, not the fight.
  The A/B reports the mean gap and a fixed two-line window, and it
  reports the outcome row too — including the flip it would be
  convenient to hide.
- **The schema sketch becoming a promise.** The profile header
  sketched `"leashes"` as sub-documents (`("wall" . (("pace" . 1.2)
  ...))`) back when the design guessed. The shipped shape is a scalar
  band per persona — and the header comment was rewritten the same
  commit, because a sketch that outlives its guessing becomes a lie
  with a version number.

✓ **Checkpoint.** You can regulate a relationship, hold an ethical
wall between the game and the player, prove a difficulty claim with a
seeded A/B, and let a document you already had carry a loop you added
today. Part VII is closed: two loops, one fight, and the fight keeps
itself interesting.

## Exercises

0. ⟡ **Running project.** Breakout's director holds the rally gap:
   probe both paddles' distance to the ball, actuate only the rival
   paddle's speed, and let a per-rival band survive the restart.
1. The A/B's directed run flipped the outcome. Sweep the gain (1.0,
   2.0, 4.0) with the clamps fixed, and find where "keeps it close"
   becomes "decides it" — report the boundary as a number, not a
   feeling.
2. The probe weighs pressure at four lines a side. Justify the four,
   or replace it: what would you measure to know? (Hint: the A/B
   harness is sixty lines and reuses everything.)
3. The retune's step is 0.01 and its clamps are 0.01–0.25. Sketch what
   a *persistent* losing streak does to the Scholar's rung over ten
   re-fights — and argue whether the floor should be the persona's
   band or the clamp's.
