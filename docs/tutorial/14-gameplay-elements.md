# Chapter 14 — Building gameplay elements in Scheme

*The files it dissects: `scheme/rules/pipeline.scm`,
`scheme/rules/scoring.scm`, `scheme/domain/modes.scm`,
`scheme/domain/game.scm`.*

> **Where you are.** The machinery works — states transform through the
> railway (chapter 3), time banks and ticks (chapter 6), the journal drains
> into feedback (chapter 7). This chapter is the craft chapter: how a *game
> element* — a mode, a scoring rule, a combo chain, a win condition — gets
> built so that adding the fifth one is a diff to a table and nothing else.
>
> **By the end of this chapter you can** grow a closed variant into a new
> way to play, share one rule between two customers with a single flag,
> price a scoring chain so it stays integer-true, and announce a moment to
> the edge with one journal fact.
>
> **The running project.** ⟡ Breakout gets its first *element*: a
> `multiball` power-up. Journal `(multiball)` when the last brick of a row
> breaks, and let the element live entirely as a fact plus one case in the
> award table.

Every gameplay element in this game was built with the same four moves:
**name the vocabulary** (a variant), **write the one rule** (a Kleisli
arrow), **price the flavor** (a policy record), and **announce the moment**
(a journal fact). This chapter walks each move with the real code, in the
order a new element would meet them.

## 14.1 A way to play is a variant, not a subclass

The game has four ways to play, and the type system knows it exactly:

```scheme
;; The closed four. Every dispatch on a mode anywhere in the program is a
;; variant-match over exactly these; a fifth way to play is a diff here
;; and nothing else.
(define-variant mode (marathon) (sprint) (ultra) (cheese))
```

Chapter 2 made the argument: a closed variant fails *loudly*. Add a fifth
mode and every `variant-match` that dispatches on modes becomes a compile-
time to-do list. The mode's *knobs* (where the level starts, what the
target is) ride along as a plain record:

```scheme
(define-record-type mode-config
  (make-mode-config mode starting-level target-lines time-limit cheese-rows)
  mode-config?
  (mode config-mode)
  (starting-level config-starting-level)
  ...)
```

Note what the config does *not* contain: no scoring, no sounds, no colors.
It is the match's *recipe* — the thing a menu hands to `new-game` and a
replay reproduces. Everything the feel needs lives elsewhere, in tables the
recipe merely indexes (14.4).

## 14.2 One descent, three customers, two questions

Gravity, a soft-drop keypress and a *held* soft-drop key's repeat all move the
piece down a row. They are the same rule, and the code says so — one arrow,
three callers:

```scheme
;; One pull of descent: down a row, or — if the floor is there — the lock
;; track. Two questions travel with a pull, and they are deliberately separate.
(define (fall-by-one state loud? paid?)
  ...)
(define (soft-fall state loud?) (fall-by-one state loud? #t))
;; gravity-ticks calls (fall-by-one s #f #f) — quiet and unpaid
;; apply-command's `down` arm passes the caller's loud?: a press is loud, a
;; held key's repeat is not (conductor/input.scm answers that question)
```

This began as **one** flag, and the story of why it became two is this
section. The single boolean said two things at once:

- **Silence.** A fall a second is a blip a second — a machine gun. The
  player's keypress is a fact worth announcing; the clock's work is not.
- **Price.** The same flag decided the wage: `(if loud? (policy-soft-row …) 0)`.
  **Gravity never pays**, in any mode — the clock's work is not skill.

One flag, two policies read beautifully while there were two customers. Then
the third arrived. The host's repeat pump (DAS/ARR) spends a held key every
40ms, so a held soft drop is 25 rows a second — and those rows are *the
player's hand*. They must be **paid** (a key press is skill, and the wage does
not depend on the volume) and they must be **silent** (a blip every tick is a
buzz). With one boolean, `loud? #f` bought silence by demoting a player's
repeat to the clock's work: paid nothing, heard nothing. Two policies, one
name, and the arrival of a customer they disagreed about is what exposed it.

So the question split in two, and every caller now answers both:

| caller | `loud?` | `paid?` | reads as |
|---|---|---|---|
| the clock's gravity tick | `#f` | `#f` | the clock earns nothing, says nothing |
| a soft-drop **press** | `#t` | `#t` | the player acted (a moment) and earns the row |
| a held key's **repeat** | `#f` | `#t` | the player acted (a tick) and still earns the row |

The lesson survives from the one-flag version, sharpened: when a rule has
customers who differ in *announcement* or *price*, do not write two rules —
write one rule with the difference as a parameter. But give each difference its
own parameter. **The flag whose name needs the word "and" to explain it is two
flags wearing one name**, and the case that proves it is whichever customer
arrives last — here, the held key, whose existence the whole DAS pump was
already built around.

## 14.3 The lock chain: one indivisible fact

Locking a piece is the game's busiest moment: merge, collapse, re-level,
score, chain, maybe end the match. The pipeline resists the temptation to
scatter it — it is *one arrow*, and its comment is a scar:

```scheme
;; Merge the active piece into the board, collapse any full rows, and
;; re-level. One arrow: lock is a single indivisible fact of the domain.
```

The scoring chain inside it is where the classic table lives. Read it as a
stack of *prices*, each one a function you can test alone:

```scheme
(base      (scale-points (clear-points n (game-level s1))
                         (policy-clear-mult pol)))
(awarded   (if (game-b2b s1)
               (quotient (* base (policy-b2b-halves pol)) 2)
               base))
(bonus     (scale-points (combo-bonus (game-combo s1) (game-level s1))
                         (policy-combo-mult pol)))
(dug       (* (policy-garbage-row pol)
              (garbage-rows-in rows (game-board s1))))
(points    (+ awarded bonus dug))
```

Three disciplines make this chain trustworthy:

1. **The level comes from the config's starting level, never the current
   one** — a level is a pure function of the line count, so it can never
   compound on itself. A formula that reads its own output is a formula
   that drifts.
2. **Sterility breaks the combo silently** — a lock with no clear sets
   `combo: 0` and journals nothing. The chain's state is *in the record*
   (chapter 5), so the next lock reads the truth, not a memory.
3. **Every price is a pure function of data** — `clear-points`,
   `combo-bonus`, `b2b-points` know nothing about the board. The domain
   tests pin each to an exact number (`(combo-bonus 2 3)` is `300`), so
   the chain's parts cannot drift while the whole is being edited.

## 14.4 Flavor as one record: the per-mode policy

Four modes score differently — a race is not a score attack, and a dig is
not a race. The temptation is an `if` per mode in the scoring chain. The
build instead folds the whole flavor into **one record per mode**, and the
chain scales and gates the classic table through it:

```scheme
(define-record-type scoring-policy
  (make-scoring-policy soft-row hard-row clear-mult combo-mult
                       b2b-halves garbage-row)
  scoring-policy?
  (soft-row policy-soft-row)
  (hard-row policy-hard-row)
  (clear-mult policy-clear-mult)
  (combo-mult policy-combo-mult)
  (b2b-halves policy-b2b-halves)
  (garbage-row policy-garbage-row))

(define (scoring-policy-for mode-tag)
  (case mode-tag
    ((marathon) (make-scoring-policy 1 2 1 1 3 0))
    ((sprint)   (make-scoring-policy 0 0 2 1 3 0))
    ((ultra)    (make-scoring-policy 1 2 1 2 4 0))
    ((cheese)   (make-scoring-policy 0 0 1 1 3 200))
    (else (scoring-policy-for 'marathon))))
```

The table *is* the design doc: sprint falls free and clears double; ultra's
chains pay double; cheese's harvest pays 200 a garbage row. Two disciplines
keep a flavor table honest:

- **Integers only.** The half-step multiplier travels as *halves* (`3` =
  ×1.5, `4` = ×2) and pays `(quotient (* base halves) 2)` — the same
  floored arithmetic `b2b-points` keeps. A score is always an integer the
  HUD can print without a decimal point; rationals and floats drift.
- **A default arm that refuses to guess.** The `else` falls back to
  marathon rather than raising — a new mode must *play* before its flavor
  is designed, and the classic table is the honest placeholder.

The chain reads the policy once per scored step — a tiny record
construction, not a cache-worthy cost (chapter 10: cache at the seam, and
only a measurement justifies it).

## 14.5 The journal announces the moment

A scoring change the player *feels* deserves a *fact*, and the journal is
where facts go (chapter 5). The combo chain is the exemplary case — the
rule journals the run's depth from the second consecutive clear, because
the first pays nothing and says nothing:

```scheme
;; The combo fact announces the RUN, not the clear: from the second
;; consecutive clear on — the first paid nothing, this one pays the chain.
(append (list (cleared rows) (scored points))
        (if (>= (game-combo s3) 2)
            (list (combo (game-combo s3)))
            '())
        (if (and (is-b2b? n) (not (game-b2b s1)))
            (list (b2b))
            '()))
```

Two judgments worth stealing:

- **The fact is the moment, not the state.** `(combo 3)` says "a run just
  reached three" — an *event* the edge can react to once. The run's depth
  is already in the record; duplicating it as a per-frame fact would
  machine-gun the speaker.
- **The chain's opening is the moment; the continuation is not.** A linked
  Tetris pays its half again silently — `(b2b)` fires only when a chain
  *starts*. The player hears the flourish once; the money keeps flowing
  quietly.

The fact needs a variant (chapter 2 — closed vocabulary, in
`domain/game.scm`), and then three readers each take their share: the
speaker's tier beep, the effects rail's popup, the painter's size. One
fact, three consumers — and the rules never know any of them exist.

## 14.6 Win conditions read, not asked twice

Each mode owns its victory, and the dispatch is a pure function of data:

```scheme
(define (victory? game-lines game-clock board config)
  (variant-match (config-mode config)
    ((sprint) (>= game-lines (config-target-lines config)))
    ((ultra)  (>= game-clock (clock-limit config)))
    ((cheese) (= (garbage-count board) 0))
    (else #f)))
```

No phase change happens here — this function only *answers*. The phase
change lives in the pipeline, at the one place the answer can be true:
`lock-and-spawn` is `lock-active >=> spawn-piece >=> check-victory` —
locking *then* spawning *then* asking means a top-out and a victory are
honest (a spawn that does not fit is the over phase, announced in the
journal like any other fact). A victory check bolted into the lock arrow
would skip the spawn — and never notice that the *next* piece was the one
that could not fit.

## Exercises

0. ⟡ **Running project.** Breakout's `multiball`: journal `(multiball)`
   from the brick-break rule, add it to the award table with a flash and a
   beep, and assert on the fake host's log that the fact drains exactly
   once (a drained journal must not re-fire it — chapter 9's machine-gun
   scar).
1. Add a fifth mode tag to `mode-names` and list every `variant-match` the
   evaluator's error messages send you to. Fix each with an `else` that
   falls back to an existing mode's behavior — then design its real policy
   row in `scoring-policy-for`.
2. The cheese harvest pays 200 a garbage *row*. Change it to pay per
   garbage *cell* in the cleared rows, and write the domain test that pins
   the new number. Decide which reads better while playing, and say why in
   a comment.
3. Write the domain test that pins a sprint win at its target lines to
   `#t` — then the one that proves an ultra does *not* win at 40 lines.

---

✓ **Checkpoint.** You can grow the closed mode variant into a new way to
  play, share one rule between two customers with a flag, price a scoring
  chain in integer-true flavors, and hand a moment to the edge as one
  journal fact.

*Next: [The moving edge](15-game-animations.md) — the animation rail the
journal feeds, pop by pop.*
