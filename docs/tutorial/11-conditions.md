# Chapter 11 — Conditions: errors that name their fix

*The files it dissects: `scheme/domain/modes.scm`,
`scheme/content/campaign.scm`, the conductor's `start-match!`,
`scheme/core/rop.scm`.*

A typo in a menu is not a crash; it is a *message the player can act on*.
This codebase's rule: **when a lookup or a validation fails, raise a named
condition whose irritants include the valid set — and catch it exactly one
frame away, where a human can read it.** This is the "conditions" flex from
the README, and it is the difference between a DSL that fails loudly and one
that fails silently.

## 11.1 The domain raises; it never guesses

Mode options are the canonical case (`scheme/domain/modes.scm`). A menu hands
`new-game` a raw alist — `((target-lines 20) (starting-level 5))` — and
`config-from` validates every pair:

```scheme
;; One option's value, checked against its bound. Out of range is a typo,
;; and a typo is named.
(define (checked-option c k v)
  (let ((limits (assq k option-limits)))
    (cond ((not limits)
           (raise (list "unknown mode option" k
                        (string-append "try one of: "
                                       (join-with ", "
                                                  (map symbol->string
                                                       (map car option-limits)))))))
          ((not (number? v))
           (raise (list "mode option expects a number" k v)))
          (else
           (let ((lo (car (cadr limits))) (hi (cadr (cadr limits))))
             (if (and (>= v lo) (<= v hi))
                 ((option-setter k) c v)
                 (raise (list "mode option out of range" k
                              (string-append "between "
                                             (number->string lo) " and "
                                             (number->string hi)) v))))))))
```

Three facts about a wrong option, in every raise:

1. **What went wrong** — "unknown mode option", in words.
2. **What you typed** — the key `k` (and value `v`), not just a complaint.
3. **What would have worked** — "try one of: target-lines, starting-level, …".

The same shape for the mode name itself:

```scheme
(define (unknown-mode-error name)
  (raise (list "unknown mode" name
               (string-append "try one of: "
                              (join-with ", "
                                         (map symbol->string (mode-names)))))))
```

The condition is a plain **list** — message first, irritants after. It is not
an error object with a stack trace; it is data the catcher renders.

## 11.2 The conductor catches, one frame away

The raise happens deep in the domain; the catch happens exactly where the
player pressed the key (`conductor/arcade.scm`):

```scheme
;; Start a match from a mode name + options, from the seed the host
;; handed us (--seed) or the clock's. A typo in the mode or the options
;; raises a named condition; the guard at the call site shows the
;; message instead of dying.
(define (start-match! mode-name options origin challenge key index)
  (guard (e (#t
             (set! *screen* 'title)
             (display "match refused: ")
             (display (describe-condition e))
             (newline)))
    (let ((seed (or *seed* (new-seed))))
      (set! *st* (fresh-game seed: seed mode: mode-name options: options))
      ...)))
```

## 11.4 Conditions vs. refusals vs. errors

The codebase draws a three-way line, and it is worth stealing:

| Kind | Mechanism | Means | Example |
|---|---|---|---|
| **Refusal** | `(err (wall))` — the Result variant | *the game says no* — expected, part of play | a slide into a wall |
| **Condition** | `(raise (list ...))` — caught by `guard` | *the caller's input is wrong* — a typo, named | unknown mode option |
| **Error** | `(error "unwrap of an err" ...)` — a bug | *the program is broken* — never caught | unwrap of an err |

A wall is not an error (chapter 3); a typo is not a refusal; a broken
invariant is neither. The tests exercise all three: mode configs and their
named refusals in `domain-tests.scm`, the guard's message path in the UI
tests.

## 11.5 When a raising computation must join the railway

One bridge between the two worlds, in `rop.scm`:

```scheme
;; A raising computation joins the railway.
(define (attempt thunk)
  (guard (e (#t (err e)))
    (ok (thunk))))
```

`attempt` wraps anything that might raise into an arrow — the escape hatch
that keeps the two error styles composable instead of warring. Use it at the
boundary, not everywhere: a codebase that wraps everything in `attempt` has
chosen neither style.

## Exercises

1. Add a bounds check to `starting-level` by hand — then find that
   `option-limits` already did it, and ask what that says about reading a
   table before writing a check.
2. `describe-condition` renders an error-object's message but ignores its
   irritants. Add them, and find a raise in the DSL runtime that benefits.
3. The guard in `start-match!` catches `(#t)` — *everything*. Narrow it to
   the conditions the domain actually raises, and decide what a genuinely
   unexpected error should do instead.

---

*Next: [The six SRFIs](12-the-srfis.md) — the standard library, doing real
work.*


Read the guard body's discipline: **put the world back before explaining.**
The screen returns to the title, the message prints, and the game continues.
A typo costs a message, never a session.

The renderer is three cases, because the DSL can raise three kinds of thing:

```scheme
(define (describe-condition e)
  ;; A raised condition is a list of irritants, or an error object —
  ;; both render as the message the player can act on.
  (cond ((list? e) (join " " (map ->text e)))
        ((error-object? e) (error-object-message e))
        (else (->text e))))
```

## 11.3 The same rule, in content

`content/campaign.scm` refuses a bad challenge id the same way:

```scheme
(define (challenge-by-id id)
  ;; The challenge named `id`, or a raised condition naming the set —
  ;; never a silent miss. The conductor's guard turns one into a message.
  (let loop ((cs *challenges*))
    (cond ((null? cs)
           (raise (list "no challenge" id
                        (string-append "try one of: "
                                       (join-with ", " (challenge-ids))))))
          ((string=? (challenge-id (car cs)) id) (car cs))
          (else (loop (cdr cs))))))
```

Compare with the reflex this replaces: `(or (lookup id) default)`. A default
converts a typo into a silently wrong game. The raise converts it into a
sentence. **Silent defaults are how content rots** — the campaign that
quietly skips a level nobody can explain.
