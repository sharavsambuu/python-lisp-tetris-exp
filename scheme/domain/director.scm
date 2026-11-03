;;; domain/director.scm — (tetris director)
;;;
;;; The decision core of the director: the pure arithmetic that turns a
;;; pressure reading into a pace multiplier. No game state, no clock, no
;;; journal — exactly like (tetris plan) is the AI's pure arithmetic, this
;;; is the director's; the conductor owns the loop around it (when to ask,
;;; how often to speak, which match gets directed).
;;;
;;; The model is proportional with a dead band: while the pressure rides
;;; inside the band around the target, the director holds (pace 1 — the
;;; level's own curve, untouched). Outside the band, the error against the
;;; target moves the pace: an empty board heats the pace up (below 1 — the
;;; well falls faster), a stacked board cools it down (above 1 — the well
;;; falls slower), and the pace clamps to a range the player can feel but
;;; not fear. The multiplier is `paced-interval`'s input (tetris gravity).

(define-library (tetris director)
  (import (scheme base) (srfi 89))
  (export make-director
          director-target
          director-band
          director-gain
          director-low-pace
          director-high-pace
          pace-clamp
          director-pace)

  (begin
    ;; The knobs, as a value: the target pressure to hold, the half-width
    ;; of the hold band around it, how hard the error moves the pace, and
    ;; the pace range the player plays inside. Defaults are the shipped
    ;; feel; a caller can publish its own, per mode or per campaign.
    (define* (make-director (target: target 0.4)
                            (band: band 0.12)
                            (gain: gain 1.2)
                            (low-pace: low 0.5)
                            (high-pace: high 2.0))
      (list (cons 'target target)
            (cons 'band band)
            (cons 'gain gain)
            (cons 'low-pace low)
            (cons 'high-pace high)))

    (define (director-target d)    (cdr (assq 'target d)))
    (define (director-band d)      (cdr (assq 'band d)))
    (define (director-gain d)      (cdr (assq 'gain d)))
    (define (director-low-pace d)  (cdr (assq 'low-pace d)))
    (define (director-high-pace d) (cdr (assq 'high-pace d)))

    ;; The pace range is a hard contract: the director may bend the curve,
    ;; never leave the player's hands.
    (define (pace-clamp d m)
      (min (director-high-pace d) (max (director-low-pace d) m)))

    ;; One pace step: the interval multiplier the current pressure earns.
    ;; Inside the band, 1 — hold. Outside, the error against the target
    ;; moves the pace, clamped. Note the sign: pressure BELOW the target
    ;; is a player with room to spare, so the pace drops below 1 and the
    ;; well falls faster; pressure ABOVE it buys relief.
    (define (director-pace d pressure)
      (if (<= (abs (- pressure (director-target d))) (director-band d))
          1
          (pace-clamp d (- 1 (* (director-gain d)
                                (- (director-target d) pressure)))))))



)

