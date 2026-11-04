# Chapter 16 — The mixing desk: game sound effects

*The files it dissects: `scheme/conductor/effects.scm` (the speaker's
routing table and the journal drain), `host/pygame_host.py` (the tones).*

> **Where you are.** Chapter 7 showed the speaker's contract — `sfx!` takes
> one name, the host owns the noise — and chapter 15 fed the effects rail.
> This chapter is the sound chapter proper: how the tones are *data*, how
> one frame's several facts become one headline, how an announcer rides on
> top without becoming a siren, and why the loudest design decision in the
> game is *silence*.
>
> **By the end of this chapter you can** add a sound as one table row,
> mix a frame's facts with a ranking table plus one overlay, escalate
> pitch with a cap, and audit a sound table for orphans.
>
> **The running project.** ⟡ Breakout gets a brick-shatter sound whose
> pitch rises with the brick's row height — one spec row, one tier
> function, one test on the fake host's sound log.

The game's sounds are not audio files. They are *generated* — a handful of
table rows in the host, synthesized into soft square waves at boot. That
keeps the repository file-free and, more importantly, keeps every mixing
decision in one readable table.

## 16.1 The seam owns the speaker; the game owns the score

The host publishes exactly one sound primitive — `sfx!`, a name — and one
table of what names mean:

```python
BEEP_SPECS = {
    "move": (220, 0.03, 0.35),
    "rotate": (330, 0.04, 0.35),
    "lock": (150, 0.06, 0.5),
    "clear": (520, 0.12, 0.5),
    "tetris": (660, 0.2, 0.6),
    "combo-2": (590, 0.10, 0.5),
    ...
    "menu-move": (300, 0.03, 0.3),
    "menu-select": (460, 0.08, 0.45),
}
```

Each row is `(frequency, seconds, volume)` — a sound is one line of data.
The Scheme side never touches frequency; it *asks by name*, and an unknown
name is a silent no-op at the seam (a typo in a sound name must never
crash a frame — the same refusal discipline as chapter 4, expressed as
grace).

Note the direction: the game says *what happened*; the host decides *what
that sounds like*. Swapping the generated beeps for sampled audio files is
a host-only diff — the game's 30-odd `sfx!` call sites would not change.

## 16.2 A tone is a formula with an envelope

The host synthesizes each spec at first play and caches it:

```python
def _beep(self, name: str) -> pygame.mixer.Sound:
    ...
    freq, seconds, volume = BEEP_SPECS[name]
    rate = 22050
    n = int(rate * seconds)
    samples = array.array("h")
    for i in range(n):
        t = i / rate
        # A soft square: the fundamental with a little 3rd harmonic, so it
        # reads as a blip rather than a buzzer; the decay keeps the tail
        # from clicking.
        wave = math.sin(2 * math.pi * freq * t)
        wave += 0.3 * math.sin(2 * math.pi * 3 * freq * t)
        envelope = 1.0 - (i / n)
        samples.append(int(32767 * volume * 0.5 * envelope * wave / 1.3))
        ...
```

Worth reading closely, because it teaches what a *usable* game tone is:

- **A pure sine is a doorbell; a true square is a buzzer.** The fundamental
  plus 0.3× its third harmonic sits between — an edge soft enough to hear
  thirty times a minute.
- **The envelope is linear decay** — `1 - i/n`. A tone that ends at full
  volume *clicks*; the decay fades the tail to zero so the stop is
  inaudible.
- **The divisor `1.3` is headroom** — fundamental plus harmonic peaks above
  1.0, and the headroom keeps the sum from clipping against the 16-bit
  ceiling.

The lesson generalizes past generated audio: whatever makes the noise, its
*character* (harmonics, envelope, headroom) is host craft, and its
*meaning* (which fact, how loud in the mix) is game craft. Keep the two on
their own sides of the seam.

## 16.3 The mixing desk is a ranking table

One frame can contain several facts — a lock, a clear, a level up. Playing
each fact's sound is a machine gun; playing one is a *mix*. The
conductor's mixing desk is a ranking table, loudest first:

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
              (begin
                (sfx! (headline-kind (car (car order)) hit
                                     (cadr (car order))))
                ...)
              (loop (cdr order)))))))
```

The loop plays *one* headline — the first table row matching any fact in
the drain — and when no ranked fact fired, the per-event sounds (moves,
rotations, locks) play underneath. Reordering the list *is* the mixing
decision: a designer who decides a level-up should out-shout a clear
changes one line, and no code.

One refinement gives the *size* of a clear its own headline:

```scheme
;; A four-line clear headlines with the fanfare, not the plain blip —
;; the speaker's one escalation the *size* of the clear earns.
(define (headline-kind tag ev fallback)
  (if (and (eq? tag 'cleared)
           (variant-match ev ((cleared rows) (= (length rows) 4))
                            (else #f)))
      "tetris"
      fallback))
```

The table maps a *tag* to a sound; the headline function may consult the
fact's *payload*. The tetris fanfare (`660Hz, 0.2s`) existed in the spec
table for a long time before this function wired it — an orphan row, see
16.5.

## 16.4 The announcer overlay — and the machine-gun lesson

The ranking plays one headline per frame. But a combo run wants *two*
sounds at once: the clear's blip *and* the run's tier beep, like an
announcer over the crowd. The overlay is explicit, and narrow:

```scheme
;; The combo announcer is the one overlay: a clear frame headlines with
;; the clear, and the run's tier beep or the chain's opening rides on
;; top of it.
(for-each (lambda (ev)
            (variant-match ev
              ((combo n) (sfx! (combo-sfx n)))
              ((b2b) (sfx! "b2b"))
              (else #f)))
          events)
```

Only the combo and b2b facts earn the overlay — every other per-event
sound keeps the headline's shadow. The narrowness is the point: an overlay
exception per *feature* is readable; a general "play everything" policy is
the machine gun again.

The machine-gun lesson has three scars in this game, and they shaped one rule
and one counter-rule — **a fact per moment, never a fact per tick**, and
**when you silence a rule, name what else carries its news**:

- *Gravity's blips.* A fall a second, journaled, is a blip a second. The rule
  is silent (`loud?` — chapter 14) and its *price* is silent too.
- *The idle freeze.* Because gravity journals nothing, a paint gate that read
  only the journal froze the falling piece while the player idled (chapter
  15). Silence in the speaker forced a *spokesman* in the paint gate.
- *The repeat buzz.* The host's DAS pump spends a held key every 40ms, and
  both the held slide and the held soft drop journaled a `(moved)` per tick —
  `"move"` is 0.03s long, so one every 0.04s is not a blip but a 75%-duty
  buzz, for as long as the key is down. The fix is the pump's own
  distinction: a repeat is a tick, so it goes quiet (chapter 14.2's
  `loud?`/`paid?` split, which is also what let the player's descent stop
  borrowing the slide's timbre). And it cost a spokesman *again* — with the
  journal silent, `*dirty*` had to become the paint gate's witness to a
  glide, or the piece would have frozen exactly as it had the first time.

The pairing of the last two scars is the takeaway: silencing a channel does
not remove the news, it **relocates** it. Whoever used to ask the journal "did
anything happen?" must now be answered by whoever knows.

## 16.5 Silence is a decision

The loudest entries in the sound design are the sounds that do not exist:

- **Gravity falls** say nothing and pay nothing — the clock is not the
  player.
- **Spawns** say nothing — the lock already spoke; a spawn blip would be
  the lock's echo.
- **Danger** has no warning klaxon — the breathing border (chapter 15) is
  the signal, and a siren would break the game's moderate register.
- **Menu hovers** move; only *picks* select — the ear already knows the
  difference between browsing and choosing.

The audit habit that keeps the table honest: every spec row must have a
call site, and every call site a spec row. This game's table grew three
orphans before an audit caught them — `"tetris"`, `"soft-drop"`, and
`"hard-drop"` were defined and never played (the clear blipped for every
clear; soft drops spoke through `"move"`). All three are resolved now, in the
three ways an orphan can be: `"tetris"` earned a call site (`headline-kind`,
the clear's *size* choosing the fanfare); `"soft-drop"` earned one too, once
the player's descent stopped borrowing the slide and became its own fact; and
`"hard-drop"` was **retired**, because it was byte-identical to `"drop"` — the
mix it proposed was the one already playing. An orphan row is a decision
nobody made; a duplicate row is the same decision made twice. The audit is one
grep per side: names in `BEEP_SPECS`, names in `sfx!` calls.

## 16.6 Escalation without a siren

The combo tier is the game's one *pitch* escalation, and its shape is
worth copying:

```scheme
;; The tier pitch a run's depth earns, capped so a ten-link run stays
;; a chord, not a siren.
(define (combo-sfx n)
  (string-append "combo-" (number->string (max 2 (min 5 n)))))
```

Five spec rows — `combo-2` through `combo-5`, 590 to 830Hz — and a clamp
that holds the top. The pitch rises for the first few links and then
*holds*, exactly as the popup's size does (chapter 15): the feedback
saturates, the ear is never punished, and a long run reads as *deep*,
not as *loud*. The `record` fanfare (a beaten session best) and the `b2b`
opening follow the same recipe — one row, one moment, one cap.

The fake host logs every `sfx!` call (`host-sfx-names`), which makes the
whole mixing desk testable without ears: a UI test crafts two consecutive
clears and asserts `"combo-2"` is in the log — the pitch policy pinned by
the same host-as-data trick that pins the drawing (chapter 9).

## Exercises

0. ⟡ **Running project.** Breakout's row-height shatter: a `shatter-low` /
   `shatter-high` spec pair, a tier function of the brick's row, and the
   fake-host assertion that a low brick plays the low tier.
1. The ranking table's shadow rule: on a clear frame, moves and locks say
   nothing. Play the lock blip *under* the clear headline for one frame
   and decide — by listening, then writing a comment — whether the mix
   got better or just busier.
2. ✓ **Done in this build.** The `"soft-drop"` orphan got its call site: the
   player's descent became its own fact (`(soft-dropped)`) with its own
   quieter blip (`260Hz, 0.025s`), and a held key no longer machine-guns
   `"move"` — the fake-host pins live in `tests/scm/gameplay-tests.scm`.
   *The follow-up worth arguing about:* the obvious alternative is a cooldown
   in `effects.scm` (no two `"move"` blips within N ms). Write down the two
   cases it gets wrong before you implement it — a deliberate fast tap
   swallowed, and a buzz only half-muted — and notice *why*: the
   press/repeat distinction exists only at the input edge, so a rate limiter
   downstream is guessing at information it has already thrown away.
3. Write the audit as a test: parse `BEEP_SPECS` and the Scheme sources,
   and assert every spec name has a call site and every call site a spec
   name. An orphan fails CI, not an afternoon.
4. The envelope is linear. Try an exponential decay (`envelope ** 2`) on
   the longest spec (`"over"`, 0.4s) and listen for the click the linear
   envelope was hiding.

---

✓ **Checkpoint.** You can add a sound as one table row, mix a frame with a
  ranking table plus one narrow overlay, escalate with a cap, audit a
  table for orphans, and defend every silence as a decision.

*Next: the series is complete — [the root README](../../README.md) flexes
what these chapters built, and [tests/README.md](../../tests/README.md)
explains the test architecture this chapter's assertions live in.*
