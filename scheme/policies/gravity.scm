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
          paced-interval
          advance-bank)

  (begin
    ;; Milliseconds per gravity tick. Level 1 starts at 900ms and the curve
    ;; tightens by 45ms a level until it hits the 60ms floor.
    ;;
    ;; A note on the feel this policy lives inside: the held-key repeat
    ;; cadence (DAS delay/interval) is deliberately NOT here — the host's
    ;; pump owns it (``REPEAT_DELAY_MS``/``REPEAT_INTERVAL_MS`` in
    ;; ``host/pygame_host.py``), because the repeat must be exactly periodic
    ;; in time, immune to frame jitter, in a way a Scheme-side frame timer
    ;; is not. This file owns the gravity curve; the host owns the repeat
    ;; clock; the conductor's ``repeat-able`` table (``conductor/input.scm``)
    ;; decides which keys repeat. Tune the three together.

    ;; The curve's floor, shared with the paced interval below.
    (define curve-floor 60)

    (define* (drop-interval level (base: base 900) (step: step 45) (floor: floor-ms curve-floor))
      (max floor-ms (- base (* step (- level 1)))))

    ;; The level's interval under a pace multiplier — the one knob the
    ;; director turns. The pace bends the curve (below 1 falls faster,
    ;; above 1 falls slower) and the floor still holds: a director can
    ;; never pace the well faster than one row a tick.
    (define (paced-interval level pace)
      (max curve-floor (* pace (drop-interval level))))

    ;; One frame of banking: add the frame's dt to the bank, and answer the
    ;; new bank together with how many whole ticks it now pays for. The
    ;; remainder stays banked — no milliseconds are lost at level changes.
    (define (advance-bank bank dt interval)
      (let* ((owed (+ bank dt))
             (ticks (quotient owed interval)))
        (values (- owed (* ticks interval)) ticks))))
)
