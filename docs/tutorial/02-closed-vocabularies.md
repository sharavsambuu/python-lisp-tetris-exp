# Chapter 2 — Closed vocabularies

*The files it dissects: `scheme/domain/game.scm`, `scheme/rules/commands.scm`.*

> **Where you are.** Chapter 1 gave you the seam: sixteen primitives, and a
> program that is pure Scheme. Now you design your first data.
>
> **By the end of this chapter you can** declare a closed vocabulary with
> `define-variant`, dispatch with `variant-match` (and explain every `else`
> arm), and decide when *not* to reach for one.
>
> **The running project.** You will declare Breakout's vocabularies — its
> phases, commands, and events — the same way Tetris declares its own.

A game is a conversation between a handful of small vocabularies: phases
(title/playing/paused/won/over), commands (left/right/…), refusals (wall/…),
events (spawned/locked/cleared/…), modes. In most codebases these are strings
or ints scattered across a hundred `if`s. Here each one is a **closed variant**
declared once, and every dispatch is a **match with no silent arm**.

## 2.1 Declaring a vocabulary

From `scheme/domain/game.scm`:

```scheme
;; The phases, as one closed set. Every dispatch on phase anywhere in the
;; program is a variant-match over exactly these five cases.
(define-variant phase (title) (playing) (paused) (won) (over))
```

From `scheme/rules/commands.scm`:

```scheme
(define-variant command
  (left) (right) (down) (rotate-cw) (rotate-ccw)
  (hard-drop) (hold-piece) (restart))
```

From `scheme/rules/pipeline.scm`:

```scheme
;; The closed set of ways the game says no.
(define-variant refusal (wall) (hold-used) (inactive) (unknown-command))
```

Three lines each, and the vocabulary now exists as a *type*: `phase?`,
`command?`, `refusal?` are predicates; constructors are the case names;
`variant-tags` can list the cases. Crucially, the set is **closed** — a new
way to say no means editing this declaration, and the compiler of every
`variant-match` over it knows the day you do.

## 2.2 Dispatch with no silent arm

Every dispatch in the game is a `variant-match`:

```scheme
(define (phase-playing? s)
  (variant-match (game-phase s)
    ((playing) #t)
    (else #f)))
```

```scheme
(define (apply-command state cmd)
  (variant-match cmd
    ((left)       ((>=> falling (cut try-shift <> -1 0)) state))
    ((right)      ((>=> falling (cut try-shift <> 1 0)) state))
    ((down)       ((>=> falling soft-fall) state))
    ((rotate-cw)  ((>=> falling (cut try-rotate <> 1)) state))
    ((rotate-ccw) ((>=> falling (cut try-rotate <> -1)) state))
    ((hard-drop)  ((>=> falling hard-drop!) state))
    ((hold-piece) ((>=> falling hold-swap) state))
    ((restart)    (ok (restart-match state)))
    (else         (err (unknown-command)))))
```

The `else` arm is a *decision*, not a default: for `apply-command` the else is
itself a named refusal (`unknown-command`), because the command set is closed
and reaching it means the caller invented a command. The DSL's rule of thumb:

> **A missing case should be a compile/named error, never a silently wrong
> behavior.** Add a new event kind — say `combo-broken` — and every
> `variant-match` over events that lacks an arm names the tag it met.

## 2.3 Variants carry payloads

An event is not just a tag; the facts a game announces carry their data:

```scheme
(locked (falling-name p))     ; WHICH piece locked
(cleared rows)                ; WHICH rows cleared — as row indices
(dropped d)                   ; HOW FAR the piece fell
(spawned name)
```

The constructors are positional, and the accessors are ordinary `variant-match`
dispatches. This is what lets chapter 7's effects rail turn a `cleared` fact
into *bars over exactly those rows* without a second channel of information.

## 2.4 The vocabulary IS the design document

Read only the declarations and you know the whole game:

```scheme
(define-variant phase   (title) (playing) (paused) (won) (over))
(define-variant refusal (wall) (hold-used) (inactive) (unknown-command))
(define-variant command (left) (right) (down) (rotate-cw)
                        (rotate-ccw) (hard-drop) (hold-piece) (restart))
```

Two details worth stealing:

- **`won` is distinct from `over`, on purpose** (`game.scm` header): a sprint
  finished is a *victory*; the campaign ladder reads the phase, and a game
  over must never read as a win. Encoding that distinction in the type beats
  encoding it in a boolean someone will flip by accident.
- **Refusals are a variant, not an exception** (chapter 3): a wall is not an
  error, it is *the game saying no*, and the caller matches on the reason.

## 2.5 When *not* to use a variant

`score` is an integer. `level` is an integer. The bag is a pair. Not everything
is a vocabulary — variants are for **closed sets of alternatives a program
branches on**. If you never dispatch on it, keep it plain data; the fastest way
to ruin a DSL codebase is enum-itis.

## Exercises

0. ⟡ **Running project.** Declare Breakout's three vocabularies:
   `(define-variant bphase (ready) (playing) (won) (over))`,
   `(define-variant bcommand (left) (right) (launch))`, and a `bevent`
   variant with `(bounced)`, `(brick-broken x y)`, `(ball-lost)`. If you
   hesitate over whether something is a phase or an event, write down the
   dispatches you imagine — the vocabularies *are* the design.

1. Add `(paused)`-style support for a *hard-drop warning* event: announce
   `(dropped d)` already exists — add `(locked-clear name rows)` that fires
   instead of `locked` when the lock cleared rows, and switch one
   `variant-match` over events to use it. Count the matchers you had to touch;
   that number is the vocabulary's blast radius.
2. `mode` is also a variant (marathon/sprint/ultra/cheese). Find where a mode's
   *options* are validated and explain why a typo in `target-lines` raises a
   named condition instead of defaulting silently.
3. The keymap (`commands.scm`) is an SRFI 241 `match` over *strings*:
   `("space" (hard-drop))`. Why is the keymap a match over strings rather than
   a variant? (Hint: who owns the spelling of a physical key?)

---

✓ **Checkpoint.** You can design a game's data as closed vocabularies — and
  you know the three questions a new variant must answer: what cases, what
  payloads, who dispatches.

*Next: [The railway](03-the-railway.md) — every command is a Kleisli arrow, and
the whole pipeline is one operator.*
