# Chapter 10 — Bounded contexts

*The files it dissects: the `scheme/` tree as a whole,
`tests/test_scheme.py` (the purity fence), `scheme/content/campaign.scm`.*

Chapter 1 showed the seam between Python and Scheme. This chapter is about the
seams *inside* the Scheme: the game is organized as **bounded contexts** —
real R7RS `define-library` modules with explicit export lists — and the
dependency direction between them is the architecture. This is the "DDD" the
README flexes, and it is enforced, not aspirational.

## 10.1 A context is a closed scope

Every pure context is a library:

```scheme
(define-library (tetris board)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (tetris geometry))
  (export make-board board? board-ref cell-free? cells-fit?
          board-place full-rows board-clear column-heights
          board-cells board-empty?)
  (begin ...))
```

Three properties, all from the `define-library` form:

1. **The export list is the public API.** `(tetris board)` promises eleven
   names. Everything else in the file is invisible — including every helper
   you were tempted to reach into from the rules layer.
2. **The import list is the world.** The board sees Scheme base, SRFI 1, and
   geometry. It does *not* see the bag, the game, the conductor, or any host
   primitive — not because a linter says so, but because those names are not
   in scope and cannot be.
3. **The scope is closed even against the prelude.** `rop.scm`'s header notes
   that a `define-library` cannot see the preloaded interaction environment —
   which is why `(tetris result)` re-declares the Result vocabulary and
   imports it explicitly. A library's world is *exactly* its imports.

## 10.2 The dependency DAG, written twice

The layout in `main.scm` writes the graph top-down; the import lists write it
again, per-file. The two rules that make this DDD rather than just folders:

- **The domain imports nobody.** `(tetris board)` cannot call `draw-rect!`,
  and `(tetris bag)` cannot read `boot-config`. The domain doesn't know a
  window exists.
- **Content imports only modes.** `(tetris campaign)` is a *library*, not a
  config file — it validates through the same mode machinery the menu uses,
  but it never sees the pipeline. A new campaign is a diff to data.

## 10.3 The purity fence is a test

The rule "the domain imports nobody" is checked, in `tests/test_scheme.py`:

```python
def test_domain_modules_are_pure_r7rs_libraries():
    """The domain libraries must never touch a host primitive."""
```

The test asserts no host primitive name reaches a domain library's scope.
This is the step most codebases skip — they *decide* the layering and *hope*
it holds. Here the decision is executable: an accidental `(draw-rect! ...)`
in `board.scm` is a red test, not a code review comment.

**Lesson:** a boundary that matters gets a test. Scope rules decay in
proportion to how silently they can be broken.

## 10.4 Why the edge is not a library

`presentation/view.scm` and `conductor/arcade.scm` are deliberately
prelude-style modules:

```scheme
;;; presentation/view.scm — the painter (an edge module, not a library).
;;;
;;; This module is deliberately NOT a define-library: it speaks to the
;;; host's painter primitives, and a library's closed scope — the same
;;; fence that keeps the pure domain airtight — would refuse it.
```

The temptation is to make *everything* a library for uniformity. Resist it:
the edge's whole job is to touch the world, and a closed scope would force
the host primitives through the import list — at which point the seam
(chapter 1) would be a formality instead of a fence. Two module kinds, chosen
by whether the module may see the host, is the whole taxonomy.

## 10.5 Content is a context, not a file

`content/campaign.scm` shows the payoff of treating content as a first-class
context:

```scheme
;;; Campaigns, levels and mode presets, as data. Content, not code: a
;;; *challenge* is a named match recipe — a mode, the options a menu hands
;;; straight to `new-game`, and a one-line goal. ... nothing here knows a
;;; key, a screen, or the pipeline — so a new campaign, or a new "mode"
;;; (a challenge preset), is a diff to a list below and nothing else.
```

The context validates its own references (chapter 11: a bad challenge id
raises a condition naming the valid set), resolves ladders up front ("levels
is a list of challenges, not ids: the ladder is already resolved"), and keeps
progress as hash-table values the conductor threads. Designers work here
without touching a rule.

## 10.6 The contexts, and what each one may know

| Context | Sees | May never see |
|---|---|---|
| `(tetris geometry)` | scheme base | everything else |
| `(tetris board)` | geometry | bag, game, rules, host |
| `(tetris bag)` | geometry | board, game, rules, host |
| `(tetris modes)` | scheme base | board, bag, game, rules, host |
| `(tetris game)` | geometry, board, bag, modes | rules, host |
| `(tetris plan)` | geometry | game, rules, host |
| `(tetris commands)` | scheme base | game, rules, host |
| `(tetris kicks)` / `(tetris scoring)` | scheme base | game, host |
| `(tetris rules)` | railway + all domain | host |
| `(tetris campaign)` | modes | game, rules, host |
| view, conductor | everything + the host | — |

That last column is the design. Read it as a promise: no game rule knows a
pixel, no pixel knows a rule.

## Exercises

1. Add `(tetris stats)` — a context for lines-per-minute arithmetic — and
   place it in the DAG. Justify its imports from the table above.
2. Break the fence on purpose: call `sfx!` from `bag.scm` and run the purity
   test. Read the failure; that message is the fence working.
3. `campaign.scm` resolves ladders eagerly. Make it lazy (levels as ids,
   resolved on read) and find which consumer breaks — then decide whether
   eager resolution was a design choice or an accident.

---

*Next: [Conditions](11-conditions.md) — errors that name their fix.*

def test_purity_fence():
    """The domain libraries must never touch a host primitive."""
```

The test asserts no host primitive name reaches a domain library's scope.
This is the step most codebases skip — they *decide* the layering and *hope*
it holds. Here the decision is executable: an accidental `(draw-rect! ...)`
in `board.scm` is a red test, not a code review comment.

**Lesson:** a boundary that matters gets a test. Scope rules decay in
proportion to how silently they can be broken.
