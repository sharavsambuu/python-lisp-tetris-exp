;;; rules/pipeline.scm — (tetris rules)
;;;
;;; The transition layer, and the file the whole port exists to show. Every
;;; command a game receives is run through a *railway*: each step is a Kleisli
;;; arrow — state in, ``(ok state')`` or ``(err refusal)`` out — and the steps
;;; compose with the fish operator ``>=>``. There is no orchestrating if/else:
;;; the pipeline *is* the control flow, and it short-circuits in exactly one
;;; place, inside ``result-bind``.
;;;
;;; A refusal is data. The closed ``refusal`` variant names every way the game
;;; can say no — a wall, a hold already spent, a command with no game under
;;; it — so a caller can match on the reason instead of catching a bomb.
;;;
;;; Gravity and keys meet here on equal terms: a held key's command and a due
;;; gravity tick go through the same arrows, so there is exactly one lock
;;; path, one spawn path, one game-over path.

(define-library (tetris rules)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (srfi 26)
          (tetris result)
          (tetris geometry) (tetris board) (tetris bag) (tetris modes) (tetris game)
          (tetris commands) (tetris kicks) (tetris scoring) (tetris gravity))
  (export refusal?
          apply-command
          apply-commands
          step-time
          drop-distance
          landing-y-at
          ghost-cells
          active-cells
          lock-and-spawn
          lock-active
          spawn-piece
          restart-match
          check-victory
          soft-fall
          playing?)

  (begin
    ;; The closed set of ways the game says no.
    (define-variant refusal (wall) (hold-used) (inactive) (unknown-command))

    ;; A game that can take a falling-piece command: the right phase *and* a
    ;; piece under gravity. This gate is the first arrow on every such track.
    (define (falling state)
      (if (and (phase-playing? state) (game-active state))
          (ok state)
          (err (inactive))))

    (define (playing? state)
      (and (phase-playing? state) (game-active state)))

    (define (fits-at? state name rot x y)
      (cells-fit? (game-board state) (cells-at name rot x y)))

    ;; ------------------------------------------------------------------ ;;
    ;;  Pure probes — reads the view and the tests need, no transitions    ;;
    ;; ------------------------------------------------------------------ ;;

    ;; How many rows the active piece can still fall.
    (define (drop-distance state)
      (let ((p (game-active state)))
        (if (not p)
            0
            (let loop ((d 1))
              (if (fits-at? state
                            (falling-name p) (falling-rot p)
                            (falling-x p) (+ (falling-y p) d))
                  (loop (+ d 1))
                  (- d 1))))))

    ;; Where the piece would land, as cells — the ghost's shadow.
    (define (ghost-cells state)
      (let ((p (game-active state)))
        (if (not p)
            '()
            (cells-at (falling-name p) (falling-rot p)
                      (falling-x p)
                      (+ (falling-y p) (drop-distance state))))))

    ;; Where the piece is right now.
    (define (active-cells state)
      (let ((p (game-active state)))
        (if (not p)
            '()
            (cells-at (falling-name p) (falling-rot p)
                      (falling-x p) (falling-y p)))))

    ;; ------------------------------------------------------------------ ;;
    ;;  The arrows                                                         ;;
    ;; ------------------------------------------------------------------ ;;

    ;; Slide by (dx dy), or refuse on a wall.
    (define (try-shift state dx dy)
      (let* ((p (game-active state))
             (nx (+ dx (falling-x p)))
             (ny (+ dy (falling-y p))))
        (if (fits-at? state (falling-name p) (falling-rot p) nx ny)
            (ok (with-event
                 (game-with state
                            active: (make-falling (falling-name p) nx ny
                                                  (falling-rot p)))
                 (moved)))
            (err (wall)))))

    ;; Rotate with SRS kicks: try each nudge in the table's order, and the
    ;; first that fits is the turn. Every nudge refused is a named refusal —
    ;; the caller decides it is just a wall.
    (define (try-rotate state dir)
      (let* ((p (game-active state))
             (name (falling-name p))
             (from (falling-rot p))
             (to (modulo (+ from dir) 4)))
        (let loop ((ks (kicks-for name from to)))
          (if (null? ks)
              (err (wall))
              (let* ((k (car ks))
                     (nx (+ (falling-x p) (car k)))
                     (ny (+ (falling-y p) (cdr k))))
                (if (fits-at? state name to nx ny)
                    (ok (with-event
                         (game-with state
                                    active: (make-falling name nx ny to))
                         (rotated)))
                    (loop (cdr ks))))))))

    ;; Fall n rows, scoring the drop. The kind ('soft or 'hard) names the
    ;; price a row carries — read from the mode's policy, so a race's fall
    ;; is free where a marathon's is worth a point.
    (define (fall-n state d kind)
      (let* ((p (game-active state))
             (p* (make-falling (falling-name p) (falling-x p)
                               (+ (falling-y p) d) (falling-rot p)))
             (rate (if (eq? kind 'hard)
                       (policy-hard-row (policy-of state))
                       (policy-soft-row (policy-of state)))))
        (ok (with-event
             (game-with state
                        active: p*
                        score: (+ (game-score state) (* d rate)))
             (dropped d)))))



    ;; The match's scoring flavor — the mode's policy, read off the recipe.
    ;; One record construction per scored step; the policy is tiny data.
    (define (policy-of state)
      (scoring-policy-for (config-mode-tag (game-config state))))

    ;; How many of the cleared rows carried garbage — the dig's harvest,
    ;; read off the board *before* the clear erased it. A row counts when
    ;; it held at least one garbage cell: cheese pays for the garbage the
    ;; clear lifted, whatever else shared the row.
    (define (garbage-rows-in rows board)
      (let loop ((ys rows) (n 0))
        (if (null? ys)
            n
            (loop (cdr ys)
                  (+ n (if (let loop-x ((x 0))
                             (cond ((>= x matrix-width) #f)
                                   ((eq? (board-ref board x (car ys)) 'g) #t)
                                   (else (loop-x (+ x 1)))))
                           1
                           0))))))

    ;; One pull of descent: down a row, or — if the floor is there — the
    ;; lock track. `loud?` decides whether the move is journaled: a
    ;; player's soft-drop keypress is a fact worth a blip, but gravity is
    ;; the clock's work, and an idle match should be silent. The same flag
    ;; prices the fall: **gravity never pays** — the soft-drop row rate is
    ;; the *player's* wage, and the clock earns nothing in any mode.
    (define (fall-by-one state loud?)
      (let* ((p (game-active state))
             (ny (+ (falling-y p) 1)))
        (if (fits-at? state (falling-name p) (falling-rot p)
                      (falling-x p) ny)
            (let ((s* (game-with state
                                 active: (make-falling (falling-name p)
                                                       (falling-x p) ny
                                                       (falling-rot p))
                                 score: (+ (game-score state)
                                           (if loud?
                                               (policy-soft-row
                                                (policy-of state))
                                               0)))))
              (ok (if loud? (with-event s* (moved)) s*)))
            (lock-and-spawn state))))

    ;; The soft-drop key's arrow: the shared descent, announced.
    (define (soft-fall state)
      (fall-by-one state #t))

    ;; Merge the active piece into the board, collapse any full rows, and
    ;; re-level. One arrow: lock is a single indivisible fact of the domain.
    ;;
    ;; The scoring chain lives here because it is a *rule*: a clear pays its
    ;; table award at the level it happened at, a Tetris on the heels of a
    ;; Tetris pays half again, and every clear beyond the first in a run pays
    ;; the combo. A sterile lock breaks the combo chain — silently, the way
    ;; the reference counts it.
    (define (lock-active state)
      (let* ((p (game-active state))
             (cells (cells-at (falling-name p) (falling-rot p)
                              (falling-x p) (falling-y p)))
             (b* (board-place (game-board state) (falling-name p) cells))
             (s1 (with-event
                  (game-with state board: b* active: #f can-hold: #t)
                  (locked (falling-name p)))))
        ;; The rows go into the journal *as rows* — the edge's animation
        ;; paints where they were, so the fact must say where, not how many.
        (let* ((rows (full-rows (game-board s1))))
          (let-values (((b2 n) (board-clear (game-board s1))))
          (let ((s2 (game-with s1 board: b2)))
            (if (= n 0)
                (ok (game-with s2 combo: 0))
                (let* ((lines* (+ (game-lines s1) n))
                       ;; The level climbs from the *config's* starting
                       ;; level, not the current one — a level is a pure
                       ;; function of the line count, so it can never
                       ;; compound on itself.
                       (level* (level-for lines*
                                          (config-starting-level
                                           (game-config s1))))
                       ;; The mode's flavor scales the classic table —
                       ;; the race's clear pays double, the score attack's
                       ;; chains double — and cheese's harvest pays its
                       ;; dig rate on every cleared row that carried
                       ;; garbage.
                       (pol (policy-of s1))
                       (base (scale-points (clear-points n (game-level s1))
                                           (policy-clear-mult pol)))
                       (awarded (if (game-b2b s1)
                                    ;; The b2b half-step travels as halves:
                                    ;; three halves floored, four if the
                                    ;; mode's chains pay double.
                                    (quotient (* base
                                                 (policy-b2b-halves pol))
                                              2)
                                    base))
                       (bonus (scale-points
                               (combo-bonus (game-combo s1) (game-level s1))
                               (policy-combo-mult pol)))
                       (dug (* (policy-garbage-row pol)
                               (garbage-rows-in rows (game-board s1))))
                       (points (+ awarded bonus dug))
                       (s3 (game-with s2
                                      lines: lines*
                                      score: (+ (game-score s2) points)
                                      level: level*
                                      combo: (+ (game-combo s1) 1)
                                      b2b: (is-b2b? n))))
                  (ok (with-events
                       (if (> level* (game-level s2))
                           (with-event s3 (level-up level*))
                           s3)
                       (list (cleared rows) (scored points)))))))))))

    ;; Draw the next piece. The one way a game ends: a spawn that does not
    ;; fit. That is not a refusal — it is the over phase, announced in the
    ;; journal like any other fact.
    (define (spawn-piece state)
      (let-values (((name bag) (bag-next (game-bag state))))
        (let ((p (make-falling name (spawn-x-for name) spawn-y 0)))
          (if (cells-fit? (game-board state)
                          (cells-at name 0 (spawn-x-for name) spawn-y))
              (ok (with-event (game-with state active: p bag: bag)
                              (spawned name)))
              (ok (with-event (game-with state active: p bag: bag phase: (over))
                              (game-over)))))))

    ;; The lock track: three arrows composed with the fish. Locking *then*
    ;; spawning *then* asking whether the mode's win condition just fired —
    ;; and nothing in between — is what makes top-out and victory honest.
    (define (lock-and-spawn state)
      ((>=> lock-active (>=> spawn-piece check-victory)) state))

    ;; The mode's win condition, read after every lock. A sprint's target
    ;; reached, a cheese board dug clean, an ultra clock run out — each is a
    ;; phase change to `won`, announced in the journal like any other fact.
    (define (check-victory state)
      (if (and (phase-playing? state)
               (victory? (game-lines state) (game-clock state)
                         (game-board state) (game-config state)))
          (ok (with-event (game-with state phase: (won)) (victory)))
          (ok state)))

    ;; Slam the piece to its ghost and lock in the same breath. A zero
    ;; distance still locks — the pipeline does not care how far it fell.
    (define (hard-drop! state)
      (let ((d (drop-distance state)))
        (if (= d 0)
            (lock-and-spawn state)
            (result-bind (fall-n state d 'hard) lock-and-spawn))))

    ;; Park the current piece and pick up the hold slot — or refuse when the
    ;; hold was already spent on this piece.
    (define (hold-swap state)
      (if (not (game-can-hold state))
          (err (hold-used))
          (let ((cur (falling-name (game-active state))))
            (if (game-hold state)
                (let ((name (game-hold state)))
                  (ok (with-event
                       (game-with state
                                  active: (make-falling name
                                                        (spawn-x-for name)
                                                        spawn-y 0)
                                  hold: cur
                                  can-hold: #f)
                       (hold-swapped))))
                (let-values (((name bag) (bag-next (game-bag state))))
                  (ok (with-event
                       (game-with state
                                  active: (make-falling name
                                                        (spawn-x-for name)
                                                        spawn-y 0)
                                  hold: cur
                                  can-hold: #f
                                  bag: bag)
                       (hold-swapped))))))))


    ;; ------------------------------------------------------------------ ;;
    ;;  Gravity — the clock's arrow                                        ;;
    ;; ------------------------------------------------------------------ ;;

    ;; Run the ticks the bank paid for, stopping the moment the phase changes
    ;; under us (a lock can end the game mid-burst).
    (define (gravity-ticks state n)
      (let loop ((s state) (i 0))
        (if (or (>= i n) (not (playing? s)))
            (ok s)
            (result-bind (fall-by-one s #f) (cut loop <> (+ i 1))))))

    ;; One frame of world time. The bank is updated even when no tick is due,
    ;; so nothing accumulates out of sight — and the match's clock runs while
    ;; the phase is live, because an ultra is a race against exactly this
    ;; number. The ultra's zero crosses into a victory here, on the clock's
    ;; own track, the same way a sprint's target does on the lock's.
    (define (step-time state dt)
      (if (not (playing? state))
          (ok state)
          (let-values (((bank ticks)
                        (advance-bank (game-bank state)
                                      dt
                                      (drop-interval (game-level state)))))
            (result-bind
             (if (= ticks 0)
                 (ok state)
                 (result-map (gravity-ticks state ticks)
                             (cut game-with <> bank: bank)))
             (lambda (s)
               (check-victory
                (game-with s clock: (+ (game-clock s) dt) bank: bank)))))))

    ;; A restart keeps the recipe and the random stream: the config is the
    ;; match's own, the bag continues where it was — a replay is a new board
    ;; dealt from the same future, which is what makes a seeded match's
    ;; replay differ from its original only in the player's hands. A cheese
    ;; board re-seeds from the bag's generator, so the dig is fresh.
    (define (restart-match state)
      (let* ((config (game-config state))
             (seed (cdr (game-bag state)))
             (board (if (cheese-config? config)
                        (cheese-board seed (config-cheese-rows config))
                        (make-board))))
        (let-values (((name bag*) (bag-next (game-bag state))))
          (let ((p (make-falling name (spawn-x-for name) spawn-y 0)))
            (with-event
             (game-with state
                        phase: (playing)
                        board: board
                        active: p
                        hold: #f
                        can-hold: #t
                        bag: bag*
                        score: 0
                        lines: 0
                        level: (config-starting-level config)
                        bank: 0
                        combo: 0
                        b2b: #f
                        clock: 0
                        journal: '())
             (restarted))))))

    ;; Where the piece would land if it were at column `x` in rotation `rot`
    ;; — the AI's pure probe. `#f` when that placement does not even fit at
    ;; the piece's current height (a rotation into a wall), which is how the
    ;; planner tells an impossible placement from a bad one.
    (define (landing-y-at state x rot)
      (let* ((p (game-active state))
             (name (falling-name p)))
        (if (not (fits-at? state name rot x (falling-y p)))
            #f
            (let loop ((y (falling-y p)))
              (if (fits-at? state name rot x (+ y 1))
                  (loop (+ y 1))
                  y)))))

    ;; ------------------------------------------------------------------ ;;
    ;;  The dispatcher — every command onto its track                      ;;
    ;; ------------------------------------------------------------------ ;;

    ;; One command, one railway. Movement commands pass the falling gate
    ;; first; restart is always welcome; the closed command set means the
    ;; else arm is a named refusal, never a guess.
    (define (apply-command state cmd)
      (variant-match cmd
        ((left)       ((>=> falling (cut try-shift <> -1 0)) state))
        ((right)      ((>=> falling (cut try-shift <> 1 0)) state))
        ((down)       ((>=> falling soft-fall) state))
        ((rotate-cw)  ((>=> falling (cut try-rotate <> 1)) state))
        ((rotate-ccw) ((>=> falling (cut try-rotate <> -1)) state))
        ((hard-drop)  ((>=> falling hard-drop!) state))
        ((hold-piece) ((>=> falling hold-swap) state))
        ((restart)    (ok (restart-match state)))
        (else         (err (unknown-command)))))

    ;; A burst of commands: fold them through, and on a refusal *keep the
    ;; last good state and go on* — a wall does not cancel the rest of the
    ;; frame's input. The railway runs per command; the fold runs always.
    (define (apply-commands state cmds)
      (fold (lambda (cmd acc)
              (let ((r (result-bind acc (cut apply-command <> cmd))))
                (if (result-ok? r) r acc)))
            (ok state)
            cmds))))
