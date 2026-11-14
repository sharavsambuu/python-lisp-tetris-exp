# Chapter 23 — Content as data: campaigns and localization

> **Where you are.** You have built the game loop, the planner, the duel, and
> the persistent profile. This chapter looks at `scheme/content/campaign.scm`
> and `scheme/content/locale.scm` — how levels, challenges, and multiple
> languages live as pure data, with zero UI code touched when you add a level
> or a language.
>
> **By the end of this chapter you can** define data-driven campaign ladders,
> add a new locale column with partial-translation fallback, and back `tr` with
> an O(1) `(srfi 125)` hash table rebuilt only when the language changes.

---

## 23.1 Campaigns and challenges as data

In `scheme/content/campaign.scm`, a challenge is not a subclass or a hardcoded
branch in `screens.scm`. It is a small record-shaped alist holding an id,
title, mode, options, and goal:

```scheme
(define (challenge id title mode options goal)
  (list (list "id" id)
        (list "title" title)
        (list "mode" mode)
        (list "options" options)
        (list "goal" goal)))
```

When a player picks a rung in the campaign menu, `challenge-by-id` either
returns the matching challenge or raises a named condition listing the valid
ids (`string-join` from `(srfi 152)`):

```scheme
(define (challenge-by-id id)
  (let loop ((cs *challenges*))
    (cond ((null? cs)
           (raise (list "no challenge" id
                        (string-append "try one of: "
                                       (string-join (challenge-ids) ", ")))))
          ((string=? (challenge-id (car cs)) id) (car cs))
          (else (loop (cdr cs))))))
```

Progress keys stay decoupled from display titles via `(level-key campaign-id
index)` (`(format #f "~a:~a" campaign-id index)` via `(srfi 28)`), so renaming
a level title or translating it never orphans a player's saved `done` list.

## 23.2 The string map: one row per key, one column per locale

In `scheme/content/locale.scm`, every user-visible string is a row in
`*strings*`:

```scheme
(define locale-specs
  '((en "English")
    (mn "Монгол")))

(define *strings*
  '(
    (menu-free-play        "Free play"                       "Чөлөөт тоглоом")
    (menu-quit             "Quit"                            "Гарах")
    (hud-hold              "HOLD"                            "ХАДГАЛАХ")
    (hud-next              "NEXT"                            "ДАРААХ")
    ...))
```

Notice the two invariants:
1. **Keys are stable symbols**, never display strings (`(tr 'menu-quit)`).
2. **Partial translations ship cleanly**: if a locale column has `#f` (or is
   shorter than `locale-specs`), `rebuild-cache!` falls back to the English
   column (`cadr row`), never to a crash or an empty string.

## 23.3 O(1) reads via `(srfi 125)` hash tables

A frame repaint calls `tr` on every label, button, and HUD panel. Walking a
60-entry alist on every call would burn interpreter steps on every frame, so
`locale.scm` pays the rebuild cost **once per locale switch** and stores the
active column in a `(srfi 125)` hash table:

```scheme
(define *locale-index* 0)
(define *lookup* (make-hash-table eq?))

(define (rebuild-cache!)
  (let ((ht (make-hash-table eq?)))
    (srfi-1:for-each
     (lambda (row)
       (hash-table-set! ht
                        (car row)
                        (if (< (+ *locale-index* 1) (length row))
                            (or (list-ref row (+ *locale-index* 1))
                                (cadr row))
                            (cadr row))))
     *strings*)
    (set! *lookup* ht)))

(define (tr-or key default)
  (hash-table-ref/default *lookup* key default))
```

Because keys are symbols, `eq?` hashing is exact and `tr-or` is a single O(1)
table lookup.

---

✓ **Checkpoint.** You can add a new campaign rung or a new locale column in
`scheme/content/` without editing a single line of `view.scm` or `screens.scm`.

## Exercises

1. Add a third column `(ja "日本語")` to `locale-specs` and translate three
   keys, leaving the rest `#f`, and verify that `tr` falls back to English for
   the untranslated keys.
2. Add a new challenge to `scheme/content/campaign.scm` and confirm that
   `challenge-by-id` lists it automatically in its error message on a typo.
