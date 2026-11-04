;;; conductor/effects.scm — the effects rail: the speaker, the screen awards.
;;;
;;; An edge module, like the rest of the conductor: it speaks to the host
;;; (the speaker) and to the view (flash, shake, beam, pop), so it lives at
;;; top level, outside the library fence. It is the one place a match's
;;; journal becomes sound and light: `drain-journal!` is the single drain,
;;; and every frame path in arcade.scm calls it.
;;;
;;; Two policies live here:
;;;
;;; * the speaker's routing table — which fact outranks which, one headline
;;;   sound a turn, the combo announcer riding on top;
;;; * the effects award table — what a clear or a slam is worth in flash
;;;   and shake.
;;;
;;; The pure match record knows neither: it journals facts, and this file
;;; decides what they are worth. One piece of edge state is fed from here:
;;; `*lock-count*` (owned by the AI, in arcade.scm) — a `(locked _)` fact
;;; bumps it, because a journal that drains would otherwise change length
;;; and restart the AI's search every frame.
;;;
;;; Load order (all the conductor's files share the interaction environment;
;;; cross-file calls resolve at run time, so this order is for the reader):
;;; effects → screens → input → arcade.

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (tetris result)
        (tetris game))

(begin
    ;; ---------------------------------------------------------------- ;;
    ;;  The speaker — which fact, which blip                               ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The edge owns the speaker primitive; the *policy* — which fact
    ;; outranks which — is a table here. One sound a turn: the loudest
    ;; fact wins, in the order the table reads. A player's command is
    ;; heard through the journal it journaled (a move, a rotation, a
    ;; lock); there is no second, per-command table — the keymap's tags
    ;; never matched its keys, and the journal has been the effects rail
    ;; all along.

    (define *sfx-fact*   ;; (fact-tag kind), loudest first
      '((game-over "over")
        (victory   "victory")
        (level-up  "level-up")
        (cleared   "clear")
        (restarted "start")))

    ;; A four-line clear headlines with the fanfare, not the plain blip —
    ;; the speaker's one escalation the *size* of the clear earns.
    (define (headline-kind tag ev fallback)
      (if (and (eq? tag 'cleared)
               (variant-match ev ((cleared rows) (= (length rows) 4))
                                (else #f)))
          "tetris"
          fallback))

    ;; The tier pitch a run's depth earns, capped so a ten-link run stays
    ;; a chord, not a siren.
    (define (combo-sfx n)
      (string-append "combo-" (number->string (max 2 (min 5 n)))))

    (define (sfx-journal! events)
      (let loop ((order *sfx-fact*))
        (if (null? order)
            (for-each sfx-event! events)
            (let ((hit (find (lambda (ev) (eq? (tag-of ev) (car (car order))))
                             events)))
              (if hit
                  (begin
                    (sfx! (headline-kind (car (car order)) hit
                                         (cadr (car order))))
                    ;; The combo announcer is the one overlay: a clear
                    ;; frame headlines with the clear, and the run's tier
                    ;; beep or the chain's opening rides on top of it.
                    (for-each (lambda (ev)
                                (variant-match ev
                                  ((combo n) (sfx! (combo-sfx n)))
                                  ((b2b) (sfx! "b2b"))
                                  (else #f)))
                              events))
                  (loop (cdr order)))))))

    ;; The per-event sounds that are not in the ranking (moves, rotations…)
    ;; still play — the ranking only decides the turn's *headline*.
    (define (sfx-event! ev)
      (variant-match ev
        ((moved) (sfx! "move"))
        ((rotated) (sfx! "rotate"))
        ((dropped _) (sfx! "drop"))
        ((locked _) (sfx! "lock"))
        ((hold-swapped) (sfx! "hold"))
        ;; The combo runs on top of the clear blip, like an announcer over
        ;; the SFX — this arm answers the frames with no ranked fact.
        ((combo n) (sfx! (combo-sfx n)))
        ((b2b) (sfx! "b2b"))
        (else #f)))

    ;; A *refusal* is the other half of a command's answer: `(err refusal)`,
    ;; which the railway's callers swallow so the block simply does not move.
    ;; The journal is for facts about the world, and a refused command changes
    ;; nothing in it — so the refusal is voiced here, at the edge, and only the
    ;; one a keypress caused: a wall is the game's own silence, but a spent hold
    ;; is a key the player meant and the game would not take. The tag names the
    ;; variant, so a refusal can be matched here without `(tetris rules)` having
    ;; to export its constructors across the fence.
    (define (refusal-sfx! r)
      (variant-match (err-reason r)
        ((hold-used) (sfx! "denied"))
        (else #f)))

    ;; Play the journal, then hand back the state with the paper trail
    ;; emptied: the journal is read exactly once, at the edge. A `(locked _)`
    ;; fact also bumps the edge-side lock counter — the AI's piece key reads
    ;; it, because a journal that drains would otherwise change length and
    ;; restart the search every frame.
    (define (drain-journal! st)
      (let ((events (reverse (game-journal st))))
        (for-each
         (lambda (ev)
           (variant-match ev ((locked _) (set! *lock-count* (+ *lock-count* 1))) (else #f)))
         events)
        (sfx-journal! events)
        (award-journal! events)
        (journal-drained st)))

    ;; ---------------------------------------------------------------- ;;
    ;;  The duel's drain — per side, before the exchange                  ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The duel's exchange drains both journals inside the pure value, so
    ;; the edge scans BEFORE the step: each side's facts award on that
    ;; side's rail — its own beam, its own garbage meter, its own lock
    ;; counter (each side's AI reads its own), with one headline sound
    ;; per side per frame. The garbage fact lands in the receiver's
    ;; journal: it hears the warning and wears the meter, and the thud
    ;; that follows is the attack's acknowledgement — warning, then
    ;; impact, so an attack never feels swallowed. The flash and the
    ;; shake answer the PLAYER's side only — one window, one veil.

    (define (duel-award! side events)
      (for-each
       (lambda (ev)
         (variant-match ev
           ((locked _)
            (if (eq? side 'right)
                (set! *r-lock-count* (+ *r-lock-count* 1))
                (set! *lock-count* (+ *lock-count* 1))))
           (else #f)))
       events)
      (sfx-journal! events)
      (for-each
       (lambda (ev)
         (variant-match ev
           ((garbage n)
            (sfx! "garbage-warn")
            (view-garbage! side n)
            (sfx! "thud"))
           (else #f)))
       events)
      (if (eq? side 'left)
          (award-journal! events)
          (for-each
           (lambda (ev)
             (variant-match ev
               ((cleared rows) (view-clear-beam! 'right rows))
               (else #f)))
           events)))

    ;; ---------------------------------------------------------------- ;;
    ;;  The effects award table — what a fact is worth on the screen       ;;
    ;; ---------------------------------------------------------------- ;;

    ;; A clear count's flash colour: four lines outshine two, white is the
    ;; anything-else answer.
    (define *clear-palette*
      '((1 (60 60 80))
        (2 (90 90 110))
        (3 (140 140 170))
        (4 (80 200 220))))

    (define *clear-flash-base-ms* 100)
    (define *clear-flash-per-line-ms* 50)
    (define *slam-shake-px* 2.5)
    (define *level-up-shake-px* 1.0)
    (define *shake-cap-px* 6.0)

    (define (fx-thud! px)
      (view-shake! (min *shake-cap-px* px)))

    (define (award-journal! events)
      (for-each
       (lambda (ev)
         (variant-match ev
           ((cleared rows)
            (let ((rgb (or (cadr (assq (length rows) *clear-palette*)) '(200 200 210))))
              (view-flash! rgb (+ *clear-flash-base-ms*
                                  (* (length rows) *clear-flash-per-line-ms*)))
              (fx-thud! (min 2.0 (* (length rows) 0.5)))
              ;; The beam: bars across the rows the clear took, burning as
              ;; long as the flash — the animation that reads "these rows
              ;; just left".
              (view-clear-beam! 'left rows)))
           ((dropped d)
            (if (>= d 6) (fx-thud! *slam-shake-px*) #f))
           ((hold-swapped) (view-hold-pulse!))
           ((combo n) (view-combo-pop! n))
           ((b2b) (view-b2b-pop!))
           ((level-up _) (view-flash! '(80 220 200) 170) (fx-thud! *level-up-shake-px*))
           ((victory) (view-flash! '(230 230 240) 220))
           ((game-over) (view-flash! '(160 40 40) 260))
           (else #f)))
       events))
)
