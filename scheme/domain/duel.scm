;;; domain/duel.scm — (tetris duel)
;;;
;;; Two matches, one fight, as a pure value. A duel holds a left match, a
;;; right match, and a winner-or-not — nothing else. The fight happens in
;;; the *exchange*, a pure reduction that reads each side's journal through
;;; the attack table, cancels the two attacks against each other (the
;;; offset rule), and lands the net on the loser of the exchange as
;;; garbage. Nothing here mutates, so a whole duel — both wells, both bags,
;;; every hole column — is a value a replay can hold.
;;;
;;; The tables are data, exactly like the scoring policies (chapter 14):
;;; a clear's worth of rows, the combo's escalation, the per-mode diff.
;;; A new mode's duel rules are a change to a row, never an if.
;;;
;;; The win condition is the opponent's top-out: a side's phase flipping
;;; to over is the only way a duel ends, and it is read after every
;;; exchange. One game-over path per side, inherited from the pipeline.

(define-library (tetris duel)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (tetris result)
          (tetris geometry) (tetris board) (tetris bag) (tetris modes) (tetris game)
          (tetris rules))
  (export make-duel
          duel?
          duel-left
          duel-right
          duel-winner
          duel-over?
          duel-with-left
          duel-with-right
          attack-table-for
          attack-rows-for-clear
          combo-attack-rows
          b2b-attack-bonus
          journal-attack
          duel-exchange
          duel-advance
          duel-step)

  (begin
    (define-record-type duel
      (wrap-duel left right winner)
      duel?
      (left duel-left)
      (right duel-right)
      (winner duel-winner))

    ;; A duel is born undecided; once decided, it stays decided.
    (define (make-duel left right) (wrap-duel left right #f))

    (define (duel-with-left d m) (wrap-duel m (duel-right d) (duel-winner d)))
    (define (duel-with-right d m) (wrap-duel (duel-left d) m (duel-winner d)))

    (define (duel-over? d) (not (not (duel-winner d))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The attack table, as data                                        ;;
    ;; ---------------------------------------------------------------- ;;

    ;; Rows cleared in one lock → rows sent. A single sends nothing — a
    ;; fight kept alive by singles should not starve the defender into
    ;; the floor; a Tetris sends four. The table is the design doc, the
    ;; way the scoring table was.
    (define default-attack-table
      '((1 . 0) (2 . 1) (3 . 2) (4 . 4)))

    ;; The mode's flavor, by tag — the sprint's whole diff is one row:
    ;; nothing sends, because the race is against the target line, not
    ;; the opponent's stack. A mode that mutes garbage is a mode whose
    ;; table says so, not a mode with a flag.
    (define (attack-table-for mode-tag)
      (if (eq? mode-tag 'sprint)
          '((1 . 0) (2 . 0) (3 . 0) (4 . 0))
          default-attack-table))

    ;; A clear's worth of rows, read off a table. An entry that is not in
    ;; the table sends nothing: the closed table means a new clear size
    ;; is a decision, never a guess.
    (define (attack-rows-for-clear table n)
      (let ((row (assq n table)))
        (if row (cdr row) 0)))

    ;; The combo's escalation, as data: the run's length → extra rows.
    ;; The first clear of a run pays nothing (it already paid at the
    ;; table), the second opens the chain, and the table caps — a long
    ;; run is pressure, not a firing squad. The cap is a named value so
    ;; the test can pin the ceiling, not the contents.
    (define combo-attack-table
      '((2 . 1) (3 . 1) (4 . 2) (5 . 2) (6 . 3) (7 . 3) (8 . 4)))
    (define combo-attack-cap 4)

    (define (combo-attack-rows n)
      (cond ((< n 2) 0)
            ((> n 8) combo-attack-cap)
            (else (cdr (assq n combo-attack-table)))))

    ;; The chain's bonus: a Tetris on the heels of a Tetris sends one
    ;; extra row — the chain is worth more than its parts.
    (define b2b-attack-bonus 1)

    ;; ---------------------------------------------------------------- ;;
    ;;  Reading a side's journal                                          ;;
    ;; ---------------------------------------------------------------- ;;

    ;; What one side's unspent facts would send: each `(cleared rows)`
    ;; through the table, each `(combo n)` through the escalation, each
    ;; `(b2b)` at its bonus. Pure — the journal is read here, drained by
    ;; the exchange.
    (define (journal-attack table st)
      (let loop ((facts (game-journal st)) (acc 0))
        (if (null? facts)
            acc
            (variant-match (car facts)
              ((cleared rows)
               (loop (cdr facts)
                     (+ acc (attack-rows-for-clear table (length rows)))))
              ((combo n) (loop (cdr facts) (+ acc (combo-attack-rows n))))
              ((b2b) (loop (cdr facts) (+ acc b2b-attack-bonus)))
              (else (loop (cdr facts) acc))))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The exchange                                                      ;;
    ;; ---------------------------------------------------------------- ;;

    ;; Both journals are read, then drained — each fact is spent exactly
    ;; once — and the two attacks cancel against each other: the **offset
    ;; rule**. The defender's own pending clear is the cancellation: only
    ;; the net of a simultaneous exchange survives, and it lands on the
    ;; loser of the exchange, via receive-garbage — whose rules own the
    ;; holes, the stream, the ride. The drain happens BEFORE the delivery,
    ;; so the `(garbage n)` fact the exchange journals survives to be read
    ;; by the edge, the telemetry, and the next exchange.
    ;;
    ;; After the garbage lands, the win condition reads the phases: a side
    ;; whose match is over has topped out, and its opponent takes the
    ;; duel. A decided duel stays decided however often the exchange
    ;; reruns. If both sides are somehow down, the right's top-out
    ;; answers to the left — deterministic either way.
    (define (duel-exchange d)
      (let* ((l (duel-left d))
             (r (duel-right d))
             (la (journal-attack
                  (attack-table-for (config-mode-tag (game-config l))) l))
             (ra (journal-attack
                  (attack-table-for (config-mode-tag (game-config r))) r))
             (l0 (journal-drained l))
             (r0 (journal-drained r))
             (differ (- la ra)))
        (let* ((l1 (if (and (< differ 0) (not (phase-over? l0)))
                       (result-unwrap-or (receive-garbage l0 (- differ)) l0)
                       l0))
               (r1 (if (and (> differ 0) (not (phase-over? r0)))
                       (result-unwrap-or (receive-garbage r0 differ) r0)
                       r0))
               (d1 (duel-with-right (duel-with-left d l1) r1)))
          (cond ((duel-winner d) d1)
                ((phase-over? r1) (wrap-duel l1 r1 'left))
                ((phase-over? l1) (wrap-duel l1 r1 'right))
                (else d1)))))

    ;; One tick of the two worlds: both matches take `dt` of world time —
    ;; gravity, the clock, the victory checks, each on its own track — but
    ;; the exchange does NOT run here. The conductor needs to read the
    ;; journals gravity just wrote (a natural lock, a clear) before the
    ;; exchange drains them; `duel-step` composes the two for pure
    ;; self-play, where no edge is listening.
    ;;
    ;; The dt goes to both sides whole: the conductor calls this once a
    ;; frame, and the symmetry is the point.
    (define (duel-advance d dt)
      (let ((l (result-unwrap-or (step-time (duel-left d) dt) (duel-left d)))
            (r (result-unwrap-or (step-time (duel-right d) dt) (duel-right d))))
        (duel-with-right (duel-with-left d l) r)))

    ;; One full tick of the fight: advance, then exchange.
    (define (duel-step d dt)
      (duel-exchange (duel-advance d dt)))))

