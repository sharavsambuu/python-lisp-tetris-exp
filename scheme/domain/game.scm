;;; domain/game.scm — (tetris game)
;;;
;;; The aggregate. A game is one record: phase, board, the falling piece, the
;;; hold slot, the bag, the score line — plus the *journal*, the newest-first
;;; list of events this state has produced. The journal is data ("journal as
;;; data"): the conductor reads it to play sounds, the tests read it to assert
;;; what happened, and nothing outside this file invents events.
;;;
;;; Two closed vocabularies live here:
;;;
;;;   phase — title / playing / paused / won / over
;;;   event — everything a transition can announce
;;;
;;; `won` is distinct from `over` on purpose: a sprint finished, an ultra
;;; clocked out, and a cheese dug through are *victories* — the conductor
;;; reads the phase to walk a campaign ladder, and a game over must never
;;; read as a win.

(define-library (tetris game)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (srfi 89)
          (tetris geometry) (tetris board) (tetris bag) (tetris modes))
  (export phase?
          make-falling
          falling?
          falling-name
          falling-x
          falling-y
          falling-rot
          event?
          make-game
          game?
          game-phase
          game-board
          game-active
          game-hold
          game-can-hold
          game-bag
          game-score
          game-lines
          game-level
          game-bank
          game-config
          game-combo
          game-b2b
          game-clock
          game-pace
          game-journal
          game-with
          phase-playing?
          phase-over?
          phase-won?
          phase-paused?
          phase-title?
          phase-live?
          title
          playing
          paused
          won
          over
          spawned
          locked
          dropped
          moved
          rotated
          hold-swapped
          hold-refused
          cleared
          scored
          combo
          b2b
          level-up
          victory
          restarted
          paced
          game-over
          with-event
          with-events
          journal-drained
          new-game
          fresh-game)

  (begin
    ;; The phases, as one closed set. Every dispatch on phase anywhere in the
    ;; program is a variant-match over exactly these five cases.
    (define-variant phase (title) (playing) (paused) (won) (over))

    ;; Phase questions, answered by dispatch and never by reaching into a
    ;; tag: the library scope sees only its imports, and the matcher is the
    ;; evaluator's own.
    (define (phase-playing? s)
      (variant-match (game-phase s)
        ((playing) #t)
        (else #f)))

    (define (phase-over? s)
      (variant-match (game-phase s)
        ((over) #t)
        (else #f)))

    (define (phase-won? s)
      (variant-match (game-phase s)
        ((won) #t)
        (else #f)))

    (define (phase-paused? s)
      (variant-match (game-phase s)
        ((paused) #t)
        (else #f)))

    (define (phase-title? s)
      (variant-match (game-phase s)
        ((title) #t)
        (else #f)))

    ;; A match that is still going: the gate every live-match transition
    ;; shares. A won or over match is a result to read, not a world to steer.
    (define (phase-live? s)
      (variant-match (game-phase s)
        ((playing) #t)
        (else #f)))

    ;; A falling piece: its name, where its box sits, which rotation. Position
    ;; is the box origin, so a piece's cells are geometry's business.
    (define-record-type falling
      (make-falling name x y rot)
      falling?
      (name falling-name)
      (x falling-x)
      (y falling-y)
      (rot falling-rot))

    ;; The journal's vocabulary — one closed set, named in the docstring.
    ;; `level-up` and `victory` are the progression facts: the speaker and
    ;; the effects read them, the campaign ladder reads the phase they
    ;; accompany.
    (define-variant event (spawned what)
                          (locked what)
                          (dropped distance)
                          (moved)
                          (rotated)
                          (hold-swapped)
                          (hold-refused)
                          (cleared rows)
                          (scored points)
                          (combo n)
                          (b2b)
                          (level-up n)
                          (victory)
                          (restarted)
                          (paced n)
                          (game-over))

    ;; The aggregate, as one flat record. `config` is the match recipe the
    ;; game plays under; `combo` and `b2b` are the scoring chain's state;
    ;; `clock` is the milliseconds the match has been live (an ultra's fuel
    ;; gauge, and every mode's stopwatch); `pace` is the multiplier the
    ;; director bends the gravity curve by — 1 plays the curve untouched,
    ;; below 1 falls faster, above 1 falls slower. A field of the record on
    ;; purpose: the pacing a match plays under is part of the match's
    ;; value, so a replay replays the director's decisions too.
    (define-record-type game
      (make-game phase board active hold can-hold bag score lines level bank
                 config combo b2b clock pace journal)
      game?
      (phase game-phase)
      (board game-board)
      (active game-active)
      (hold game-hold)
      (can-hold game-can-hold)
      (bag game-bag)
      (score game-score)
      (lines game-lines)
      (level game-level)
      (bank game-bank)
      (config game-config)
      (combo game-combo)
      (b2b game-b2b)
      (clock game-clock)
      (pace game-pace)
      (journal game-journal))

    ;; The updater: every field defaults to the current value. A transition
    ;; says what changed and nothing more.
    (define* (game-with s
                        (phase: p (game-phase s))
                        (board: b (game-board s))
                        (active: a (game-active s))
                        (hold: h (game-hold s))
                        (can-hold: c (game-can-hold s))
                        (bag: g (game-bag s))
                        (score: sc (game-score s))
                        (lines: ln (game-lines s))
                        (level: lv (game-level s))
                        (bank: bk (game-bank s))
                        (config: cf (game-config s))
                        (combo: co (game-combo s))
                        (b2b: bb (game-b2b s))
                        (clock: cl (game-clock s))
                        (pace: pc (game-pace s))
                        (journal: j (game-journal s)))
      (make-game p b a h c g sc ln lv bk cf co bb cl pc j))

    ;; Journal one event, newest first.
    (define (with-event s ev)
      (game-with s journal: (cons ev (game-journal s))))

    ;; Journal several, preserving their order.
    (define (with-events s evs)
      (game-with s journal: (append (reverse evs) (game-journal s))))

    ;; The state as seen after the consumer has read the journal: the paper
    ;; trail is emptied without touching a single other field.
    (define (journal-drained s)
      (game-with s journal: '()))

    ;; A new game under a match recipe. The optional keyword parameters are
    ;; the whole difficulty surface of the game: the seed (a test's handle on
    ;; the future), the starting level, the mode, and the mode's own options
    ;; — `((target-lines 20) …)` — validated by (tetris modes), which will
    ;; raise a named condition on a typo rather than guess.
    ;;
    ;; A cheese match starts differently: its board is seeded with garbage
    ;; rows, from the match's own seed, so a seeded cheese match replays.
    (define* (new-game (seed: seed 20261101)
                       (level: start-level #f)
                       (mode: mode-name 'marathon)
                       (options: options '()))
      (let* ((config (config-from mode-name options))
             (level (if start-level
                        start-level
                        (config-starting-level config)))
             (b (if (cheese-config? config)
                    (cheese-board seed (config-cheese-rows config))
                    (make-board))))
        (let-values (((queue seed*) (make-bag-into seed)))
          (make-game (title)
                     b
                     #f
                     #f
                     #t
                     (cons queue seed*)
                     0
                     0
                     level
                     0
                     config
                     0
                     #f
                     0
                     1
                     '()))))

    ;; A game that is already falling: what the conductor boots into, and what
    ;; the tests use to skip the title screen.
    (define (fresh-game . args)
      (let ((g (apply new-game args)))
        (let-values (((piece bag) (bag-next (game-bag g))))
          (let* ((name piece)
                 (p (make-falling name (spawn-x-for name) spawn-y 0)))
            (game-with (game-with g
                                  phase: (playing)
                                  active: p
                                  bag: bag
                                  journal: '())
                       journal: (list (spawned name)))))))

    ;; make-bag plumbing: the seed in, a queue plus the next seed out.
    (define (make-bag-into seed)
      (let ((st (make-bag seed)))
        (values (bag-queue st) (cdr st)))))
)
