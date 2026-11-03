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
          director-pace
          make-leash
          leash-band
          leash-gain
          leash-pace-gain
          leash-low-throttle
          leash-high-throttle
          leash-scale
          duel-gap
          closeness
          leash-throttle
          leash-pace)

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
                                (- (director-target d) pressure))))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The duel's leash — the closeness homeostat                        ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The solo director regulates one player's pressure. The duel's
    ;; director regulates the GAP between two sides, and its ethical wall
    ;; is absolute: the actuators touch only the AI — its placement
    ;; budget (the throttle) and its gravity (the pace). Never the
    ;; player's garbage, never the player's pieces, never the player's
    ;; gravity. The probe is a closeness differential: a signed gap in
    ;; "lines equivalent" — lines cleared plus four lines' worth of
    ;; board pressure per side — normalized against the scale of a
    ;; blowout. Zero is a knife's edge; one is a blowout. The band
    ;; around zero is the fun zone, and its width is the persona's own
    ;; knob (the roster's leash: tighter band, harder rung).
    ;;
    ;; The same discipline as the solo core: pure arithmetic, no state,
    ;; no clock. The conductor owns the loop — how often to ask, when to
    ;; speak, which match gets bent.

    ;; The knobs, as a value. The band is the hold zone around a knife's
    ;; edge (a fraction of the blowout scale); the gain is how hard the
    ;; error outside the band moves the AI's budget; the pace gain is
    ;; the damped second actuator; the throttles are the range the AI's
    ;; budget may swing in; the scale is how many lines-equivalent a
    ;; full blowout reads.
    (define* (make-leash (band: band 0.06)
                         (gain: gain 2.0)
                         (pace-gain: pace-gain 0.5)
                         (low-throttle: low 0.6)
                         (high-throttle: high 1.6)
                         (scale: scale 8))
      (list (cons 'band band)
            (cons 'gain gain)
            (cons 'pace-gain pace-gain)
            (cons 'low low)
            (cons 'high high)
            (cons 'scale scale)))

    (define (leash-band l)           (cdr (assq 'band l)))
    (define (leash-gain l)           (cdr (assq 'gain l)))
    (define (leash-pace-gain l)      (cdr (assq 'pace-gain l)))
    (define (leash-low-throttle l)   (cdr (assq 'low l)))
    (define (leash-high-throttle l)  (cdr (assq 'high l)))
    (define (leash-scale l)          (cdr (assq 'scale l)))

    ;; The probe, raw: a signed gap in lines-equivalent. Positive means
    ;; the LEFT side — the player — is ahead, so the AI is behind and
    ;; will be boosted; negative means the AI is running away and will
    ;; be reeled in. Pressure weighs four lines a side: a full board is
    ;; as urgent as a four-line deficit, because both end the same way.
    (define (duel-gap ll lr pl pr)
      (- (+ ll (* 4 pl)) (+ lr (* 4 pr))))

    ;; The probe, normalized: 0 at a knife's edge, 1 at the blowout
    ;; scale. Every band is a fraction of this.
    (define (closeness l gap)
      (min 1 (/ (abs gap) (leash-scale l))))

    ;; One throttle step: inside the band, hold — the AI's own speed
    ;; knob, untouched. Outside, the normalized error past the band
    ;; moves the multiplier in the gap's direction, clamped to the
    ;; leash's range. The error is normalized by the usable span (the
    ;; distance from the band edge to the blowout) so the gain means
    ;; the same thing at any band width.
    (define (leash-throttle l gap)
      (let ((c (closeness l gap)) (band (leash-band l)))
        (if (<= c band)
            1
            (let* ((e (/ (- c band) (- 1 band)))
                   (m (if (> gap 0)
                          (+ 1 (* (leash-gain l) e))
                          (- 1 (* (leash-gain l) e)))))
              (min (leash-high-throttle l)
                   (max (leash-low-throttle l) m))))))

    ;; The quiet actuator: the same move, damped, on the AI's gravity.
    ;; The budget is how many placements the AI may score a frame; the
    ;; pace is how fast its well falls. Both bend, neither breaks —
    ;; and both bend the AI only.
    (define (leash-pace l throttle)
      (+ 1 (* (leash-pace-gain l) (- throttle 1)))))



)

