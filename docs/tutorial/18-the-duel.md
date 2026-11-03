# Chapter 18 — The duel

*The files it dissects: `scheme/domain/duel.scm`, the `receive-garbage`
arrow in `scheme/rules/pipeline.scm`, and the self-play section of
`tests/scm/domain-tests.scm`.*

> **Where you are.** The game plays (chapters 5–8), proves itself
> (chapter 9), and paces itself (chapter 17). Every transition already
> announces itself on a journal. This chapter points two matches at each
> other — and lets the journals do the fighting.
>
> **By the end of this chapter you can** read a match's journal as an
> attack, cancel two attacks in flight with one subtraction, hold an
> entire fight — both wells, both bags, every hole column — as one pure
> value, and let two AIs play a complete duel under a seed with no mocks
> and no pixels.
>
> **The running project.** Breakout gets a rival paddle: two walls of
> bricks, one ball each, and bricks you clear send a new row to the
> rival's wall. Same skeleton, one score sheet.

A versus mode is where the journal pays its biggest dividend. The
single-player game taught its facts to two customers: the speaker plays
a sound per fact, the effects rail paints one. The duel is the third —
the same `(cleared rows)`, `(combo n)`, and `(b2b)` facts, read as an
**attack ledger**. No new event is invented; the fight reuses the
match's own voice.

## 18.1 The journal as an attack ledger

Reading a side's attack is a fold over facts:

```scheme
(define (journal-attack table st)
  (let loop ((facts (game-journal st)) (acc 0))
    (if (null? facts)
        acc
        (variant-match (car facts)
          ((cleared rows)
           (loop (cdr facts)
                 (+ acc (attack-rows-for-clear table (length rows)))))
          ((combo n) (loop (cdr facts) (+ acc (combo-attack-rows n))))
          ((b2b) (loop (cdr facts) (+ acc b2b-attack-bonus)))
          (else (loop (cdr facts) acc))))))
```

Every unrecognized fact falls through the `else` arm untouched — the
journal's closed vocabulary means the reader can never misread a fact
invented later. The function is pure: it *reads* the journal; the
exchange drains it.

## 18.2 The attack table is the design doc

How much a clear should send is game design, not arithmetic — so it
lives in data, exactly like the scoring policies of chapter 14:

```scheme
(define default-attack-table
  '((1 . 0) (2 . 1) (3 . 2) (4 . 4)))
```

A single sends nothing — a fight kept alive by singles should not
starve the defender into the floor; a Tetris sends four. The combo
escalates through its own table and **caps**: a long run is pressure,
not a firing squad. And a mode's flavor is a diff to the table, never a
flag:

```scheme
(define (attack-table-for mode-tag)
  (if (eq? mode-tag 'sprint)
      '((1 . 0) (2 . 0) (3 . 0) (4 . 0))
      default-attack-table))
```

The sprint's whole duel rule is that one row: nothing sends, because
the race is against the target line. A closed table also means an entry
that is *not* in it sends nothing — a new clear size becomes a
decision, never a guess that leaks rows.

## 18.3 The exchange: the offset rule

Two matches, one fight. The heart of `(tetris duel)` is the exchange,
and its heart is one subtraction:

```scheme
(differ (- la ra))
```

`la` and `ra` are the two sides' pending attacks, read from their
journals. The defender's own clear is the cancellation: attacks in
flight offset each other, and only the net lands. A simultaneous
triple cancels a simultaneous triple to *nothing* — the duel's
heartbeat — and a triple against a single sends two rows to the single's
side. There is no special case for simultaneity; the offset is the
arithmetic.

Two disciplines make the exchange honest:

- **Drain before you deliver.** Both journals drain *first*, then the
  net lands via `receive-garbage` — whose arrow journals `(garbage n)`
  on the receiver. Drain first and the exchange's own fact survives to
  be read by the edge, the telemetry, and the next exchange; drain
  after and you would spend the fact the moment you wrote it.
- **Land through the arrow, not around it.** The exchange never touches
  the board. `receive-garbage` owns the holes, the bag stream, the
  ride — the chapter 5 discipline of one writer per concern, applied to
  violence. Because the holes spend the *same* Lehmer stream the pieces
  shuffle from, a seeded duel replays exactly: the garbage and the deal
  are one deterministic future.

## 18.4 The duel as a value

```scheme
(define-record-type duel
  (wrap-duel left right winner)
  duel?
  (left duel-left)
  (right duel-right)
  (winner duel-winner))
```

Three fields, nothing else: the two matches and a winner-or-not. The
duel is a value like the match is a value (chapter 5) — a replay can
hold the whole fight, and the tests assert on it like any other field.

The win condition is the opponent's **top-out**. The exchange reads the
phases after the garbage lands, and a side whose match is over has lost
— the over phase arriving through the ordinary spawn refusal, the one
game-over path the pipeline has always had. The duel invents no second
way to die; it *reads* the death the match already announces. And a
decided duel stays decided however often the exchange reruns — idempotent
by construction, the way a pure reduction should be.

`duel-step` is the conductor's whole contract with the fight: give both
sides `dt` of world time, then exchange. The `dt` goes to both sides
whole — the symmetry is the point, and the conductor never arbitrates.

## 18.5 The test with nothing to mock

A duel needs two players. The one-ply planner from chapter 8 *is* a
player: score the forty placements, march, slam. Drive both sides with
it, exchange after each round, repeat:

```scheme
(define (self-play seed-l seed-r)
  (let loop ((d (make-duel (fresh-game seed: seed-l)
                           (fresh-game seed: seed-r)))
             (i 0))
    (cond ((duel-over? d) d)
          ((> i 400) (error "the duel never ended"))
          (else
           (loop (duel-exchange
                  (duel-with-right
                   (duel-with-left d (drive-one (duel-left d)))
                   (drive-one (duel-right d))))
                 (+ i 1))))))
```

The assertions are on the duel value, not pixels: the same seeds crown
the same winner twice; the loser's phase is `over`; the winner's is
`playing`; and combined, the two boards carry the wreckage of a real
fight. There is nothing to mock, because everything under test is pure —
the host, the window, the clock, none of it exists here.

One cost needed measuring, because a self-play duel is a *long
computation in one form*: about 35 million interpreter steps for the
fifty-five-round fight the seeds deal. The step budget is per root
call, so the suite's ceiling was raised to 150M — with the number
written down next to it, the way chapter 13 says a bound earns its
keep. A ceiling without a measurement is a guess; a measured ceiling is
a contract.

## 18.6 Pitfalls, one each

- **A fact spent twice is a fact lied about.** The journals drain
  exactly once per exchange — and *before* the delivery, or the
  `(garbage n)` you just journaled is spent the moment it exists. The
  test that pins it: after a cancelled exchange, both journals are
  empty and both boards are too.
- **An unfueled march spins on a wall.** The steering loop drives until
  the piece sits at the chosen placement — but after garbage raises a
  stack, a rotation or a shift can be *refused*, the unwrapped result
  is the unchanged state, and the march never ends. Give the march
  fuel: forty steps, then slam from wherever the piece got. The step
  budget catches the unfueled loop — in tests, at fifty million steps;
  in production it is a hang.
- **The win condition is a phase, not a flag.** It is tempting to track
  "someone topped out" as a boolean at the moment of the kill. Do not.
  Read `phase-over?` after the exchange, the way `check-victory` reads
  the mode's condition after a lock — one reader, one truth, and a duel
  that ends only when the match itself says so.

✓ **Checkpoint.** You can read a journal as an attack, cancel two
attacks in flight with one subtraction, hold a whole fight as a pure
value, and prove the fight deterministic under a seed — no mocks, no
pixels, one measured ceiling.

## Exercises

0. ⟡ **Running project.** Give Breakout a rival paddle: two brick walls,
   one ball each. Bricks you clear send a new row to the rival's wall;
   first wall to *fill* loses. Keep both sides in one value and one
   exchange — do not let the two games talk except through the offset.
1. The sprint's diff is one table row. Add a cheese duel flavor: what
   should a clear *send* on a board that is half garbage already? Write
   the row, then the test that pins it, then play three seeded duels
   under it and say whether the dig attacks or the dig defends.
2. Make the arithmetic meet itself: a double-plus-combo-chain against a
   back-to-back Tetris — who receives what, exactly? Write the test
   first, then check it against the tables, and adjust whichever side
   of the ledger you think is wrong.
3. Log both boards' pressure per round of a seeded self-play and plot
   the two series. Where does the fight turn, and was it the garbage or
   the bag that turned it? (Chapter 17's probes work on either side
   unchanged — that is the point of them.)
