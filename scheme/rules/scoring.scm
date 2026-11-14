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
          is-b2b?
          scoring-policy
          scoring-policy?
          scoring-policy-for
          policy-soft-row
          policy-hard-row
          policy-clear-mult
          policy-combo-mult
          policy-b2b-halves
          policy-garbage-row
          scale-points)

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

  ;; ---------------------------------------------------------------- ;;
  ;;  The per-mode flavor                                              ;;
  ;; ---------------------------------------------------------------- ;;
  ;;
  ;; The four ways to play do not score the same way, and they should not:
  ;; a race is not a score attack, and a dig is not a race. A *scoring
  ;; policy* is the mode's whole flavor as one record — what a
  ;; player-caused drop pays a row, what a clear, a combo link and a
  ;; back-to-back are multiplied by, and what a dug garbage row pays flat.
  ;; The primitives above stay the shared arithmetic; the policy only
  ;; scales and gates them, so every mode's score is still built from the
  ;; same classic table.
  ;;
  ;; One principle crosses all four modes: **gravity never pays.** The
  ;; clock's work is not the player's skill — a match idled to the floor
  ;; earns nothing, in any mode. (The pipeline enforces this with the same
  ;; `loud?` flag that keeps gravity's silence.)
  (begin
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

    ;; The mode's flavor, by tag. A fifth way to play is a case here and
    ;; nothing else.
    ;;
    ;; - marathon — the classic: soft +1, hard +2, the plain table, and a
    ;;   back-to-back Tetris at three halves (the same discipline
    ;;   `b2b-points` keeps: halves, floored, always an integer).
    ;; - sprint — the race: points are the tiebreak of *speed*, so falling
    ;;   pays nothing and a clear pays double. You sprint on lines.
    ;; - ultra — the score attack: everything pays, and chains pay double —
    ;;   combo links ×2, and a Tetris on a Tetris pays four halves (×2),
    ;;   not three.
    ;; - cheese — the dig: falling is free; the harvest pays. Every cleared
    ;;   row that carried garbage pays 200 flat, on top of the clear.
    (define (scoring-policy-for mode-tag)
      (case mode-tag
        ((marathon) (make-scoring-policy 1 2 1 1 3 0))
        ((sprint)   (make-scoring-policy 0 0 2 1 3 0))
        ((ultra)    (make-scoring-policy 1 2 1 2 4 0))
        ((cheese)   (make-scoring-policy 0 0 1 1 3 200))
        ((survival) (make-scoring-policy 1 2 1 1 3 0))
        ((zen)      (make-scoring-policy 0 0 1 1 3 0))
        (else (scoring-policy-for 'marathon))))

    ;; Scale an award by a policy multiplier. The multipliers are plain
    ;; integers, so a score is always an integer the HUD can print without
    ;; a decimal point — the b2b half-steps travel as halves instead.
    (define (scale-points base mult)
      (* base mult)))
)



