;;; rules/scoring.scm — (tetris scoring)
;;;
;;; The score line: what a clear is worth, how levels grow, what a drop costs
;;; the gravity budget. Deliberately boring arithmetic — and a small showcase
;;; for SRFI 241's constant patterns, which let the award table read as the
;;; table it is.

(define-library (tetris scoring)
  (import (scheme base))
  (export line-points
          clear-points
          drop-points
          level-for
          combo-bonus
          b2b-points
          is-b2b?)

  (begin
    ;; The classic award, before the level multiplier.
    (define (line-points n)
      (match n
        (1 100)
        (2 300)
        (3 500)
        (4 800)
        (,_ 0)))

    ;; The award at the game's current level.
    (define (clear-points n level)
      (* (line-points n) level))

    ;; Soft drop: one point a row. Hard drop: two. The kind travels as a
    ;; symbol because the pipeline already knows which it ran.
    (define (drop-points kind rows)
      (* rows (if (eq? kind 'hard) 2 1)))

    ;; A level every ten lines, on top of the starting level.
    (define (level-for lines start-level)
      (+ start-level (quotient lines 10)))

    ;; The combo: every consecutive clear beyond the first pays 50 a link,
    ;; at the current level. `combo` is the count of *previous* consecutive
    ;; clears, so the first clear of a run pays nothing.
    (define (combo-bonus combo level)
      (* combo 50 level))

    ;; Back-to-back: a Tetris on the heels of a Tetris pays half again. The
    ;; arithmetic stays exact — three halves, floored — so a score is always
    ;; an integer the HUD can print without a decimal point.
    (define (b2b-points base)
      (quotient (* base 3) 2))

    ;; Whether a clear of `n` lines keeps a back-to-back chain alive: only a
    ;; Tetris does. A single or double breaks the chain silently.
    (define (is-b2b? n) (= n 4)))
)



