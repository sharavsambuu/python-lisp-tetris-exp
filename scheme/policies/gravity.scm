;;; policies/gravity.scm — (tetris gravity)
;;;
;;; The pacing policy: how fast the world pulls, and how a frame's spare
;;; milliseconds bank toward the next pull. This is a *policy*, not a rule —
;;; the rules say what a gravity tick does, this file says when one is due —
;;; and its two knobs are keyword parameters, so a mode could carry its own
;;; curve without touching the rules.

(define-library (tetris gravity)
  (import (scheme base) (srfi 89))
  (export drop-interval
          advance-bank
          das-delay
          das-rate
          soft-rate)

  (begin
    ;; Milliseconds per gravity tick. Level 1 starts at 900ms and the curve
    ;; tightens by 70ms a level until it hits the 60ms floor.
    (define* (drop-interval level (base: base 900) (step: step 70) (floor: floor-ms 60))
      (max floor-ms (- base (* step (- level 1)))))

    ;; One frame of banking: add the frame's dt to the bank, and answer the
    ;; new bank together with how many whole ticks it now pays for. The
    ;; remainder stays banked — no milliseconds are lost at level changes.
    (define (advance-bank bank dt interval)
      (let* ((owed (+ bank dt))
             (ticks (quotient owed interval)))
        (values (- owed (* ticks interval)) ticks)))

    ;; Input-repeat policy, in milliseconds: how long a held key waits before
    ;; it starts repeating, and how fast it repeats after that. Steering is
    ;; tuned for a modern feel — a short delay (140ms) and a fast ARR (30ms,
    ;; two cells a frame at 60fps once it fires). Soft drop is its own animal:
    ;; it should answer the instant it is pressed and crawl faster than
    ;; gravity, so the conductor gives it zero delay and this rate.
    (define* (das-delay (ms: ms 140)) ms)
    (define* (das-rate (ms: ms 30)) ms)
    (define* (soft-rate (ms: ms 25)) ms))
)
