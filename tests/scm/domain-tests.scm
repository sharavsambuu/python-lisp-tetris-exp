;;; tests/scm/domain-tests.scm — the pure domain, checked headlessly.
;;;
;;; Run by tests/test_scheme.py through `make_env(search_paths=[scheme])` —
;;; no pygame, no window, no speaker. Every failure raises, so the runner
;;; only has to check that this file loads; the last line prints when all of
;;; them held.
;;;
;;; The checks are the domain's own documentation: rotations are generated,
;;; so their invariants are verified; the bag is deterministic under a seed;
;;; and every refusal is matched by name, never by accident.

(load "core/rop")

(load "domain/geometry")
(load "domain/board")
(load "domain/bag")
(load "domain/modes")
(load "domain/game")
(load "domain/plan")

(load "rules/commands")
(load "rules/kicks")
(load "rules/scoring")
(load "policies/gravity")
(load "rules/pipeline")

(load "content/campaign")

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (srfi 26)
        (srfi 88)
        (tetris result)
        (tetris geometry) (tetris board) (tetris bag) (tetris modes) (tetris plan)
        (tetris game)
        (tetris commands) (tetris kicks) (tetris scoring) (tetris gravity)
        (tetris rules)
        (tetris campaign))

(define-syntax check
  (syntax-rules ()
    ((_ expr expected)
     (let ((actual expr) (wanted expected))
       (if (equal? actual wanted)
           #t
           (error "check failed" 'expr actual wanted))))))

(define (assert msg ok)
  (if ok #t (error "assert failed" msg)))

;; --------------------------------------------------------------------- ;;
;;  geometry — generated rotations, honest offsets                        ;;
;; --------------------------------------------------------------------- ;;

(check matrix-width 10)
(check matrix-height 20)
(check (length piece-names) 7)

;; Every piece, every rotation: four cells, none repeated.
(assert "every rotation has 4 distinct cells"
        (every (lambda (name)
                 (every (lambda (rot)
                          (let ((cells (piece-cells name rot)))
                            (and (= (length cells) 4)
                                 (= (length (delete-duplicates cells)) 4))))
                        (iota 4)))
               piece-names))

;; The I piece: a row in its box at spawn, a column one turn later.
(check (piece-cells 'i 0) '((0 . 1) (1 . 1) (2 . 1) (3 . 1)))
(check (piece-cells 'i 1) '((2 . 0) (2 . 1) (2 . 2) (2 . 3)))

;; The O piece never changes its cells: all four rotations agree, as sets.
(assert "O rotations identical"
        (let ((rots (map (cut piece-cells 'o <>) (iota 4))))
          (every (lambda (r) (lset= equal? r (car rots))) rots)))

;; Cells land where the offset says; shifting is pure.
(check (cells-at 'o 0 4 0) '((4 . 0) (5 . 0) (4 . 1) (5 . 1)))
(check (cells-shifted '((1 . 2)) -1 3) '((0 . 5)))

;; --------------------------------------------------------------------- ;;
;;  board — an immutable grid                                             ;;
;; --------------------------------------------------------------------- ;;

(define b0 (make-board))
(assert "a new board is empty" (board-empty? b0))
(assert "no full rows yet" (null? (full-rows b0)))

;; Fill the bottom row across all ten columns: full, then clear.
(define b1
  (board-place b0 'i (map (lambda (x) (cons x 19)) (iota matrix-width))))
(assert "the row is full now" (equal? (full-rows b1) '(19)))
(assert "the original board is untouched" (board-empty? b0))

(let-values (((b2 n) (board-clear b1)))
  (check n 1)
  (assert "cleared board is empty again" (board-empty? b2)))

;; Collision: walls refuse, the ceiling does not.
(assert "left wall is solid"
        (not (cells-fit? b0 '((0 . 0) (-1 . 0)))))
(assert "the floor is solid"
        (not (cells-fit? b0 '((0 . 20)))))
(assert "above the ceiling is free"
        (cells-fit? b0 '((0 . -1) (1 . -1))))

;; Column heights see the stack.
(check (column-heights (board-place b0 'o (cells-at 'o 0 4 18)))
       '#(0 0 0 0 2 2 0 0 0 0))

;; --------------------------------------------------------------------- ;;
;;  bag — randomness as a value                                           ;;
;; --------------------------------------------------------------------- ;;

(define bag (make-bag 42))
(assert "a fresh bag holds a full deal"
        (= 7 (length (delete-duplicates (bag-queue bag)))))

;; Seven draws answer all seven pieces, once each — and the state threads.
(let loop ((st bag) (drawn '()) (i 0))
  (if (= i 7)
      (assert "a bag deals all seven" (= 7 (length (delete-duplicates drawn))))
      (let-values (((piece st*) (bag-next st)))
        (loop st* (cons piece drawn) (+ i 1)))))

;; Determinism: the same seed, the same deal.
(check (bag-queue (make-bag 1234)) (bag-queue (make-bag 1234)))

;; The peek never differs from what the draws answer.
(let-values (((first-bag-draw st*) (bag-next (make-bag 7))))
  (check (car (bag-peek (make-bag 7) 3)) first-bag-draw))

;; --------------------------------------------------------------------- ;;
;;  game — the aggregate, its updater, its journal                        ;;
;; --------------------------------------------------------------------- ;;

(define g (new-game seed: 5 level: 2))
(assert "a new game is on the title screen" (phase-title? g))
(check (game-level g) 2)
(check (game-score g) 0)
(assert "a new game holds no piece" (not (game-active g)))

;; game-with names only what changed.
(check (game-score (game-with g score: 100)) 100)
(check (game-level (game-with g score: 100)) 2)

;; fresh-game is already falling, and says so in the journal.
(define gf (fresh-game seed: 5))
(assert "fresh-game is playing" (phase-playing? gf))
(assert "fresh-game holds a piece" (game-active gf))
(check (map tag-of (reverse (game-journal gf))) '(spawned))

;; Draining empties the journal and nothing else.
(check (game-journal (journal-drained gf)) '())
(check (game-score (journal-drained gf)) (game-score gf))

;; --------------------------------------------------------------------- ;;
;;  commands — the published vocabulary                                   ;;
;; --------------------------------------------------------------------- ;;

(assert "left maps to a command" (command? (key->command "left")))
(assert "x rotates cw" (eq? (tag-of (key->command "x")) 'rotate-cw))
(assert "z rotates ccw" (eq? (tag-of (key->command "z")) 'rotate-ccw))
(assert "space slams" (eq? (tag-of (key->command "space")) 'hard-drop))
(assert "an unmapped key is #f, not a guess" (not (key->command "f1")))
(check (command-name (left)) "left")

;; --------------------------------------------------------------------- ;;
;;  kicks — the SRS tables                                                ;;
;; --------------------------------------------------------------------- ;;

(check (kicks-for 'o 0 1) '((0 . 0)))
(check (length (kicks-for 'j 0 1)) 5)
(check (length (kicks-for 'i 0 1)) 5)
(check (car (kicks-for 'j 0 1)) '(0 . 0))

;; --------------------------------------------------------------------- ;;
;;  scoring — the award table                                             ;;
;; --------------------------------------------------------------------- ;;

(check (line-points 1) 100)
(check (line-points 2) 300)
(check (line-points 3) 500)
(check (line-points 4) 800)
(check (line-points 5) 0)
(check (clear-points 4 3) 2400)
(check (level-for 25 1) 3)
(check (drop-points 'hard 10) 20)
(check (drop-points 'soft 10) 10)

;; --------------------------------------------------------------------- ;;
;;  gravity — the pacing policy                                           ;;
;; --------------------------------------------------------------------- ;;

(assert "level 1 is the base interval" (= (drop-interval 1) 900))
(assert "the curve descends" (< (drop-interval 5) (drop-interval 1)))
(assert "the floor holds" (= (drop-interval 999) 60))

;; Banking: whole ticks come out, the remainder stays.
(let-values (((bank ticks) (advance-bank 880 100 900)))
  (check ticks 1)
  (check bank 80))
(let-values (((bank ticks) (advance-bank 880 40 900)))
  (check ticks 1)
  (check bank 20))
(let-values (((bank ticks) (advance-bank 880 10 900)))
  (check ticks 0)
  (check bank 890))

;; --------------------------------------------------------------------- ;;
;;  rules — the railway                                                   ;;
;; --------------------------------------------------------------------- ;;

;; Slide: the piece moves left, the journal says so.
(define g1 (ok-value (apply-command gf (left))))
(check (falling-x (game-active g1))
       (- (falling-x (game-active gf)) 1))
(check (tag-of (car (game-journal g1))) 'moved)

;; A wall is a named refusal — eleven lefts still leave the piece legal.
(define g-wall
  (let loop ((s gf) (i 0))
    (if (= i 11)
        s
        (loop (if (result-ok? (apply-command s (left)))
                  (ok-value (apply-command s (left)))
                  s)
              (+ i 1)))))
(check (falling-x (game-active g-wall)) 0)
(assert "the wall refuses"
        (result-err? (apply-command g-wall (left))))
(assert "the refusal is the wall"
        (eq? (tag-of (err-reason (apply-command g-wall (left)))) 'wall))

;; Rotation: x turns the piece clockwise.
(define g-rot (ok-value (apply-command gf (key->command "x"))))
(check (falling-rot (game-active g-rot)) 1)
(check (tag-of (car (game-journal g-rot))) 'rotated)

;; Hard drop: to the floor, locked, refilled, scored.
(define g-drop (ok-value (apply-command gf (hard-drop))))
(assert "a new piece spawned" (game-active g-drop))
(assert "the drop locked the old one"
        (not (equal? (falling-name (game-active gf))
                     (falling-name (game-active g-drop)))))
(let ((tags (map tag-of (reverse (game-journal g-drop)))))
  (assert "drop journal is spawn drop lock spawn"
          (equal? tags '(spawned dropped locked spawned))))
(assert "the drop scored 2 a row"
        (> (game-score g-drop) (game-score gf)))

;; Hold: park it, then refuse the second hold.
(define g-hold (ok-value (apply-command gf (hold-piece))))
(check (game-hold g-hold) (falling-name (game-active gf)))
(assert "hold can be used once"
        (result-err? (apply-command g-hold (hold-piece))))
(assert "the hold refusal names itself"
        (eq? (tag-of (err-reason (apply-command g-hold (hold-piece))))
             'hold-used))

;; Gravity: before the interval, nothing; at it, one row down.
(define g-t0 (ok-value (step-time gf 400)))
(check (falling-y (game-active g-t0)) (falling-y (game-active gf)))
(define g-t1 (ok-value (step-time gf 900)))
(check (falling-y (game-active g-t1)) (+ 1 (falling-y (game-active gf))))

;; A burst of commands: a refusal mid-burst does not cancel the rest.
(define g-burst
  (ok-value (apply-commands gf (list (left) (left) (left) (left) (left)
                                     (left) (left) (left) (left) (left)
                                     (rotate-cw)))))
(assert "the burst finished with a turn"
        (= (falling-rot (game-active g-burst)) 1))

;; The end of the game: hard-drop until the well fills.
(let loop ((s gf) (i 0))
  (cond ((phase-over? s)
         (assert "the journal announced the end"
                 (memq 'game-over (map tag-of (game-journal s))))
         (assert "the last piece is still on the board"
                 (not (board-empty? (game-board s)))))
        ((> i 40) (error "the game never ended"))
        (else (loop (ok-value (apply-command s (hard-drop))) (+ i 1)))))

;; The gates: a paused game refuses piece commands, by name.
(define g-paused (game-with gf phase: (paused)))
(assert "a paused game refuses"
        (result-err? (apply-command g-paused (left))))
(assert "the gate names itself"
        (eq? (tag-of (err-reason (apply-command g-paused (left))))
             'inactive))

;; --------------------------------------------------------------------- ;;
;;  the monad, pinned here too                                            ;;
;; --------------------------------------------------------------------- ;;

(define (halve n) (if (even? n) (ok (/ n 2)) (err "odd")))

;; left identity: (bind (pure x) f) == (f x)
(check (result-bind (ok 8) halve) (halve 8))
;; right identity: (bind m pure) == m
(check (result-bind (err "x") result-pure) (err "x"))
;; associativity: bind (bind m f) g == bind m (lambda (x) (bind (f x) g))
(check (result-bind (result-bind (ok 12) halve) halve)
       (result-bind (ok 12) (lambda (x) (result-bind (halve x) halve))))
;; short-circuit: the first refusal is the whole answer. (result-do stays
;; outside the check macro on purpose: a do-notation expansion inside
;; another macro's template is a hygiene corner this test avoids, not a
;; feature it hides.)
(define short-circuit
  (result-do (a <- (ok 1))
             (b <- (err "stop"))
             (ok (+ a b))))
(check short-circuit (err "stop"))
;; the fish composes arrows and short-circuits in one place
(check ((>=> halve halve) 8) (ok 2))
(check ((>=> halve halve) 7) (err "odd"))
;; collections traverse
(check (traverse-results halve '(8 4 2)) (ok '(4 2 1)))
(check (traverse-results halve '(8 3 2)) (err "odd"))
;; a raising computation joins the railway
(check (result-err? (attempt (lambda () (car '())))) #t)

;; --------------------------------------------------------------------- ;;
;;  modes — the four ways to play, as data                                ;;
;; --------------------------------------------------------------------- ;;

;; The config a menu hands to new-game: defaults, then named options.
(check (mode-label (default-config)) "marathon")
(check (config-starting-level (config-from 'sprint '())) 1)
(check (config-target-lines (config-from 'sprint '((target-lines 5)))) 5)
(check (config-time-limit (config-from 'ultra '((time-limit 30)))) 30)
(check (config-cheese-rows (config-from 'cheese '((cheese-rows 7)))) 7)
(check (tag-of (config-mode (config-from 'cheese '()))) 'cheese)

;; Validation refuses by name: mode, option, range — each names the fix.
(define (guard-tag thunk)
  (guard (e (#t (car e))) (thunk)))
(check (guard-tag (lambda () (config-from 'nope '()))) "unknown mode")
(check (guard-tag (lambda () (config-from 'sprint '((nope 5))))) "unknown mode option")
(check (guard-tag (lambda () (config-from 'cheese '((cheese-rows 400)))))
       "mode option out of range")
(check (guard-tag (lambda () (config-from 'sprint '((target-lines "x")))))
       "mode option expects a number")

;; A cheese board: `rows` garbage rows at the bottom, one hole each, seeded.
(define cb (cheese-board 42 5))
(check (garbage-count cb) 45)
(assert "the same seed replays the same board"
        (equal? (vector->list cb) (vector->list (cheese-board 42 5))))

;; Victory, per mode: the dispatch is the rule.
(assert "sprint wins on the target"
        (victory? 40 0 (make-board) (config-from 'sprint '((target-lines 40)))))
(assert "sprint does not win early"
        (not (victory? 39 0 (make-board) (config-from 'sprint '((target-lines 40))))))
(assert "ultra wins when the clock runs out"
        (victory? 0 60000 (make-board) (config-from 'ultra '((time-limit 60)))))
(assert "cheese wins when the dig is done"
        (victory? 0 0 (make-board) (config-from 'cheese '())))
(assert "cheese does not win mid-dig"
        (not (victory? 0 0 cb (config-from 'cheese '()))))
(assert "marathon never wins"
        (not (victory? 100 999999 (make-board) (default-config))))
(check (time-remaining 45000 (config-from 'ultra '((time-limit 60)))) 15)

;; --------------------------------------------------------------------- ;;
;;  scoring — combo, back-to-back                                         ;;
;; --------------------------------------------------------------------- ;;

(check (combo-bonus 0 1) 0)
(check (combo-bonus 2 3) 300)
(check (b2b-points 800) 1200)
(check (b2b-points 100) 150)
(assert "only a tetris keeps the chain"
        (and (is-b2b? 4) (not (is-b2b? 1)) (not (is-b2b? 2)) (not (is-b2b? 3))))

;; --------------------------------------------------------------------- ;;
;;  plan — the AI's pure arithmetic                                       ;;
;; --------------------------------------------------------------------- ;;

(check (bumpiness (vector 3 3 3 3 3 3 3 3 3 3)) 0)
(check (bumpiness (vector 0 5 0 5 0 5 0 5 0 5)) 45)
(assert "wells count what has to be filled"
        (= (wells-sum (vector 5 2 5 5 5 5 5 5 5 5) 20) 3))
(assert "a flat profile has no wells"
        (= (wells-sum (vector 3 3 3 3 3 3 3 3 3 3) 20) 0))
(assert "a placement that fills the well scores better"
        (let ((ws (weights 2.0 2.5 0.5 0.6))
              (hs (vector 4 6 6 6 6 6 6 6 6 6)))
          (> (placement-score ws hs (piece-cells 'o 0) 0 13 20)
             (placement-score ws hs (piece-cells 'o 0) 8 13 20))))

;; --------------------------------------------------------------------- ;;
;;  campaign — content as data, and the progress it carries               ;;
;; --------------------------------------------------------------------- ;;

(check (length (challenge-ids)) 9)
(check (challenge-title (challenge-by-id "one-minute")) "One Minute")
(check (challenge-mode (challenge-by-id "cheese-five")) 'cheese)
(check (length (campaign-levels (campaign-by-id "ascent"))) 8)
(assert "the campaign's levels are real challenges"
        (every (lambda (c) (member (challenge-id c) (challenge-ids)))
               (campaign-levels (campaign-by-id "ascent"))))
(assert "an unknown challenge refuses by name"
        (guard (e (#t (equal? (car e) "no challenge")))
          (challenge-by-id "nope") #f))

(define done0 '())
(define done1 (mark-done done0 (level-key "ascent" 1)))
(assert "a marked level is done" (level-done? done1 (level-key "ascent" 1)))
(assert "the original set is untouched" (not (level-done? done0 (level-key "ascent" 1))))
(assert "marking twice is a no-op"
        (equal? done1 (mark-done done1 (level-key "ascent" 1))))

;; --------------------------------------------------------------------- ;;
;;  the match record — modes ride along, wins are announced               ;;
;; --------------------------------------------------------------------- ;;

(assert "a cheese match starts buried"
        (= (garbage-count (game-board (fresh-game seed: 3 mode: 'cheese
                                                     options: '((cheese-rows 4)))))
           36))
(assert "a sprint match carries its target"
        (= (config-target-lines (game-config (fresh-game seed: 1 mode: 'sprint
                                                         options: '((target-lines 20)))))
           20))
(assert "the clock runs while the phase is live"
        (= (game-clock (ok-value (step-time (fresh-game seed: 7) 500))) 500))
(assert "the clock holds while paused"
        (= (game-clock (ok-value (step-time
                                  (game-with (fresh-game seed: 7) phase: (paused)) 500)))
           0))

;; A restart keeps the recipe: the replay is the same match again.
(let* ((g0 (fresh-game seed: 9 mode: 'sprint options: '((target-lines 3))))
       (g1 (ok-value (apply-command g0 (restart)))))
  (assert "a restart keeps the mode"
          (eq? (tag-of (config-mode (game-config g1))) 'sprint))
  (assert "a restart keeps the target"
          (= (config-target-lines (game-config g1)) 3))
  (assert "a restart resets the score" (= (game-score g1) 0))
  (assert "a restart announces itself"
          (memq 'restarted (map tag-of (game-journal g1)))))

;; A sprint match steered to its target is a won match, and the journal
;; said so. The steering is the one-ply planner doing its job in miniature:
;; score all forty placements with the pure probes, take the best, march
;; the piece there, slam — the same search the conductor's AI runs, minus
;; the frame budget.
(let loop ((s (fresh-game seed: 21 mode: 'sprint options: '((target-lines 2))))
           (i 0))
  (cond ((phase-won? s)
         (assert "the journal announced the victory"
                 (memq 'victory (map tag-of (game-journal s)))))
        ((phase-over? s) (error "the sprint match ended before its target"))
        ((> i 200) (error "the sprint match never finished"))
        (else
         (let* ((ws (weights 2.0 2.5 0.5 0.6))
                (p (game-active s))
                (name (falling-name p))
                (hts (column-heights (game-board s)))
                ;; Score every (x rot); the best placement wins.
                (best
                 (let scan ((x 0) (rot 0) (bx 3) (brot 0) (bscore -1000000))
                   (cond ((>= rot 4) (list bx brot))
                         ((>= x 10) (scan 0 (+ rot 1) bx brot bscore))
                         (else
                          (let ((ly (landing-y-at s x rot)))
                            (if (not ly)
                                (scan (+ x 1) rot bx brot bscore)
                                (let ((score (placement-score
                                              ws hts (piece-cells name rot)
                                              x ly matrix-height)))
                                  (scan (+ x 1) rot
                                        (if (> score bscore) x bx)
                                        (if (> score bscore) rot brot)
                                        (max score bscore)))))))))
                (bx (car best))
                (brot (cadr best))
                ;; March to (bx brot), then slam — one arrow per step.
                (steered
                 (let drive ((st s))
                   (let ((pp (game-active st)))
                     (cond ((not (= (falling-rot pp) brot))
                            (drive (result-unwrap-or (apply-command st (rotate-cw)) st)))
                           ((< (falling-x pp) bx)
                            (drive (result-unwrap-or (apply-command st (right)) st)))
                           ((> (falling-x pp) bx)
                            (drive (result-unwrap-or (apply-command st (left)) st)))
                           (else st)))))
                (s* (result-unwrap-or (apply-command steered (hard-drop)) steered)))
           (loop s* (+ i 1))))))




(display "all domain tests passed")
(newline)
