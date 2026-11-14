;;; content/roster.scm — (tetris roster)
;;;
;;; The opponents, as content. A *persona* is a name, a title, and three
;;; knobs a duel can read: the planner's weight vector (its style — what
;;; it rewards and what it refuses to pay for), the speed knob (its
;;; strength — placements scored per frame; the conductor's search
;;; budget spends exactly this), and the band (the leash the duel
;;; director will hold it by — tighter means a harder rung, stage 6).
;;;
;;; Content, not code, per the campaign's law: a new opponent is a diff
;;; to the list below and nothing else. Names and titles are mutable
;;; flavor; the ids are load-bearing (the ladder, the save file, and the
;;; locale table all key on them — keep them stable).
;;;
;;; The honesty this file signs: one-ply personas differ in *style*, not
;;; *strength*. The ladder's difficulty comes from the speed knob and
;;; the director's band; the weights make the opponents feel different,
;;; and the seeded sweep in the domain suite is what makes "feel
;;; different" a measured claim.

(define-library (tetris roster)
  (import (scheme base)
          (srfi 89)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (tetris plan))
  (export make-persona
          persona?
          persona-id
          persona-name
          persona-title
          persona-weights
          persona-speed
          persona-band
          roster
          persona-ids
          persona-by-id)

  (begin
    (define-record-type persona
      (mk-persona id name title weights speed band)
      persona?
      (id persona-id)
      (name persona-name)
      (title persona-title)
      (weights persona-weights)
      (speed persona-speed)
      (band persona-band))

    ;; Required keywords, so a persona cannot be written half-specified.
    (define* (make-persona (id: id) (name: name) (title: title)
                           (weights: weights) (speed: speed) (band: band))
      (mk-persona id name title weights speed band))

    ;; The first roster. The weight vector is (cleared holes bumpiness
    ;; wells attack) — the planner's five dials, in its own order.
    (define roster
      (list
       ;; Waits, buries nothing, forgives nothing — a fortress that hopes
       ;; you make the mistake first.
       (make-persona id: 'wall
                     name: "The Wall"
                     title: "waited for your mistake"
                     weights: (weights 2.0 3.6 1.2 1.5 0.8 0.8)
                     speed: 8
                     band: 0.10)
       ;; Fast and filthy: rows now, holes be damned, dig never.
       (make-persona id: 'blitz
                     name: "Blitz"
                     title: "does not dig, does not care"
                     weights: (weights 1.4 1.6 0.5 0.4 2.8 0.6)
                     speed: 16
                     band: 0.18)
       ;; The default weights, the slowest clock, the tightest leash —
       ;; the long game, played patiently.
       (make-persona id: 'scholar
                     name: "The Scholar"
                     title: "played the long game"
                     weights: (weights 2.2 2.8 0.6 0.7 1.6 0.9)
                     speed: 5
                     band: 0.06)
       ;; Whatever you bring, it returns — mid dials, mid clock.
       (make-persona id: 'mirror
                     name: "The Mirror"
                     title: "whatever you do, back at you"
                     weights: (weights 2.0 2.6 0.8 0.8 2.0 0.8)
                     speed: 12
                     band: 0.14)))

    (define (persona-ids) (map persona-id roster))

    ;; One lookup, by the load-bearing id. Unknown ids answer #f — the
    ;; caller (a menu, a ladder walk, a save file being restored) decides
    ;; what a missing opponent means.
    (define (persona-by-id id)
      (find (lambda (p) (eq? (persona-id p) id)) roster))))
