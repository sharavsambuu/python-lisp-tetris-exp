# Chapter 1 — A language inside a language

*The file it dissects: `host/pygame_host.py`, `scheme/main.scm`.*

> **Where you are.** This is the start. You need working Scheme reads —
> `(define (f x) ...)`, `let`, `cond` — and Python. Nothing else.
>
> **By the end of this chapter you can** explain where every line of the game
> runs, name all the primitives the script may call, and boot your own
> scripted session against the host.
>
> **The running project.** Each chapter ends by adding one piece to a small
> game you build alongside the reading — a Breakout clone on this same DSL.
> This chapter: boot a session and draw your paddle.

Most "game scripting" is a Python loop with a few Lua callbacks. This project
inverts it: **Python is the runtime, Scheme is the program.** Python builds the
window, the clock, the SDL event queue, and an interpreter environment; then it
loads `scheme/main.scm` and never touches the game again. Everything you think
of as "the game" — screens, input policy, gravity, the AI, the campaign ladder,
even the main loop — is Scheme.

Before diving in, a word on how to read this series: every chapter follows the
same shape. A **naive version** of an idea, the **reason it fails** in a real
game, then the version this codebase ships — with the bug scars that motivated
it. The exercises are not quizzes; they build your Breakout clone piece by
piece, so by chapter 12 you will have written a second, smaller game in the
same style, and the techniques will be things you have *done*, not things you
have *read*.

## 1.1 The seam is a list of nineteen names

The entire surface Python offers the game is declared in one place
(`host/pygame_host.py`):

```python
#: The seam: the ONLY names the game may call. Sixteen — painters, the clock,
#: the pump, the speaker, the boot config. Nothing is discovered at runtime;
#: a reviewer reads this list and sees every door between the two worlds.
def install_primitives(env, host):
    for name, fn in [...]:
        env.define(intern(name), Primitive(name, fn))
```

The names, grouped by what they own:

| Group | Primitives |
|---|---|
| paint | `open-window!`, `clear-screen!`, `draw-rect!`, `draw-frame!`, `draw-text!`, `present!`, `tint!` |
| measure | `text-width` |
| time | `tick!` |
| input | `poll-events!`, `quit-requested?`, `held?` |
| sound | `sfx!` |
| boot/teardown | `boot-config`, `autostart?`, `quit!` |

### One primitive, from both sides

It is worth seeing one primitive end to end, because every one of the nineteen
follows the same shape. On the Python side, a method on the host object:

```python
def text_width(self, s, size) -> int:
    return self._font(size).size(str(s))[0]
```

On the Scheme side, an ordinary call:

```scheme
(text-width "SCORE" 18)   ; ⇒ some pixel count
```

No marshalling layer, no IDL, no code generation. The DSL's `Primitive`
wrapper takes the Python callable and makes it a Scheme procedure; arguments
cross as native values (strings, numbers, lists, the DSL's keyword objects).
That simplicity is *why* the seam stayed at sixteen names for the whole first
arc — adding a seventeenth is a method plus one line in the list, so there is
no economy-of-scale pressure to build a kitchen-sink primitive like
`draw-ui!` that smuggles decisions across the boundary. When the game finally
grew a memory, two names earned their place (chapter 20) — and the list, not
a convention, is what made the growth reviewable.

The same symmetry applies to *data*. The boot config crosses as an alist the
Scheme side can `assq`:

```python
# The CLI as the alist Scheme boots from:
# ((mode . "sprint") (level . 5) (seed . 7) (ai . #t) (autostart . #t))
# — only the flags the run actually carried.
def boot_config(self) -> list: ...
```

```scheme
(let ((entry (assq 'mode (boot-config))))
  (if entry (cadr entry) 'marathon))
```

Python builds a list of pairs; Scheme reads it with the ordinary list tools.
The host never needs to know what a "mode" *means* — it only reports what the
command line said.

That is the whole contract. Two properties fall out of it, and both are worth
more than they look:

1. **Reviewability.** A security reviewer (or you, in six months) reads one
   list and knows every effect the script can have on the world. There is no
   `import os` hiding in Scheme-land, because the DSL has no `import`.
2. **Testability.** Chapter 9 replaces this list with a Scheme fake of the same
   names and the entire game runs headless in pure Scheme. That is only
   possible because the seam is *closed*.

## 1.2 Loading order is the architecture

`scheme/main.scm` is nine loads and a call:

```scheme
(load "core/rop")            ; the railway first: everyone imports it

(load "domain/geometry")     ; the pure domain, bottom of the dependency DAG
(load "domain/board")
(load "domain/bag")
(load "domain/modes")
(load "domain/game")
(load "domain/plan")

(load "rules/commands")      ; the rules layer: domain + railway
(load "rules/kicks")
(load "rules/scoring")
(load "policies/gravity")
(load "rules/pipeline")

(load "content/campaign")    ; content: data, not code

(load "presentation/view")   ; the edge: speaks to the host

(load "conductor/effects")   ; the effects rail: speaker policy, screen awards
(load "conductor/screens")   ; the menus, the screens, the menu input
(load "conductor/input")     ; the key dispatch: events, keys, repeats
(load "conductor/arcade")    ; the shared state, match lifecycle, AI, the loop

(arcade-main)                ; Scheme's own tail-call loop, forever
```

The order *is* the dependency graph, written top to bottom. Inside `scheme/`,
there is no hidden registry or plugin discovery: the whole program is data you
can read in one screen. At the Python edge, `host/pygame_host.py` also exposes
`install(env)` so `python -m shslisp --plugin host.pygame_host:install` can
open a headless REPL or run scripts against the host primitives, and `main()`
catches `LispError` to print a multi-frame Scheme traceback via
`exc.format_traceback()`.

One subtlety hides in the word `load`. Loading a `define-library` file
*registers* the library — its body does not run until something first imports
it. So `main.scm` reads top-down as "here are the contexts, in dependency
order," while the actual evaluation order is decided by the import graph. The
edge modules (`view`, the four `conductor` files) are the exception: not being
libraries, their bodies run at load, which is exactly when their top-level
defines need to exist for `arcade-main` to see them. The conductor's four
files share one interaction environment and load in a fixed order (effects →
screens → input → arcade); a call from one into another resolves at run time,
so the order is for the reader, not the evaluator.

## 1.3 Two kinds of module, on purpose

Look at the headers of two files:

```scheme
;;; domain/board.scm — a REAL R7RS library:
(define-library (tetris board)
  (import (scheme base) (tetris geometry))
  (export make-board board-ref cells-fit? ...)
  (begin ...))
```

```scheme
;;; presentation/view.scm — deliberately NOT a library:
(import (scheme base) ... (tetris rules) (tetris commands))
(begin ...)
```

Why the difference? A `define-library` is a **closed scope**: it sees only its
declared imports, so a domain module *cannot* call `draw-rect!` or `tick!` even
by accident — those names are not in its scope. The edge modules (view,
conductor) speak to the host by nature, so they are prelude-style modules whose
scope is the interaction environment.

The purity fence is not a comment; it is enforced by a test
(`tests/test_scheme.py`):

```python
def test_domain_modules_are_pure_r7rs_libraries():
    """The domain libraries must never touch a host primitive."""
    ...
```

**Lesson:** when you embed a DSL, decide on day one which modules may see the
host, and make the *language* enforce it — scope, not discipline.

## 1.4 Who owns what

The seam also splits responsibility by *change rate*:

- **Python owns mechanisms** that must be fast or correct in real time: the
  frame clock, the SDL event queue, the font caches, the held-key repeat pump
  (chapter 6), the audio device.
- **Scheme owns policies** that designers iterate on: what a clear is worth,
  how levels grow, which key does what, when a mode is won, what the AI
  prefers.

The tell that a responsibility is on the wrong side: you need to recompile
(or restart Python) to tweak it, or you catch yourself writing game nouns
(`board`, `piece`, `score`) into the host. The host in this repo knows how to
draw a rectangle; it has no idea a rectangle might be a Tetris cell.

## Exercises

0. ⟡ **Running project.** Boot a headless session of your own from Python:
   build the environment, install the primitives, load a one-line script of
   yours that calls `(open-window! ...)` and `(draw-rect! ...)`. That colored
   rectangle is your Breakout paddle — everything you add later hangs off
   this boot.
1. Add a seventeenth primitive `window-title!` that renames the window. Touch
   exactly three places: the host's implementation, the seam list, and this
   tutorial's table.
2. Move `(load "policies/gravity")` above `(load "rules/commands")` and explain
   from the load order alone why nothing breaks — then find the one import in
   `pipeline.scm` that would have caught it if you had gotten it wrong.
3. The DSL has no `import os`. Write the Scheme you *would* write to read a
   file, and enjoy the fact that the answer is "ask the host for a primitive."

---

✓ **Checkpoint.** You can boot the game headless, name every primitive the
  script can call, and say which side of the seam each responsibility
  belongs on.

*Next: [Closed vocabularies](02-closed-vocabularies.md) — the five enums that
run the game, and why forgetting a case is a named error.*
