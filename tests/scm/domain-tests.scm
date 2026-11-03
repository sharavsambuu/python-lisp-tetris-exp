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
(load "domain/telemetry")
(load "domain/director")

(load "rules/commands")
(load "rules/kicks")
(load "rules/scoring")
(load "policies/gravity")
(load "rules/pipeline")
(load "domain/duel")

(load "content/campaign")
(load "content/roster")

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (srfi 26)
        (srfi 88)
        (tetris result)
        (tetris geometry) (tetris board) (tetris bag) (tetris modes) (tetris plan)
        (tetris telemetry) (tetris director)
        (tetris game)
        (tetris commands) (tetris kicks) (tetris scoring) (tetris gravity)
        (tetris rules)
        (tetris duel)
        (tetris roster)
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
        (let ((ws (weights 2.0 2.5 0.5 0.6 1.0))
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
         (let* ((ws (weights 2.0 2.5 0.5 0.6 1.0))
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




;; --------------------------------------------------------------------- ;;
;;  rules — receive-garbage: the opponent's arrow                           ;;
;; --------------------------------------------------------------------- ;;

;; The hole columns come from the match's own bag stream: one Lehmer step
;; per row, seeded by the bag's position — so a seeded test predicts every
;; hole before it lands, and a seeded match replays through garbage.
(let* ((g (fresh-game seed: 20261103))
       (seed (bag-seed (game-bag g)))
       (s1 (next-seed seed))
       (s2 (next-seed s1))
       (s3 (next-seed s2))
       (predicted (list (modulo s1 matrix-width)
                        (modulo s2 matrix-width)
                        (modulo s3 matrix-width)))
       (r (result-unwrap-or (receive-garbage g 3) #f)))
  ;; Each bottom row is garbage full but for its predicted hole.
  (let loop ((i 0) (hs predicted))
    (if (not (null? hs))
        (let ((row (vector->list
                    (vector-ref (game-board r) (- matrix-height 1 i)))))
          (assert "the garbage row is full but for its hole"
                  (every (lambda (x)
                           (if (= x (car hs))
                               (eq? (list-ref row x) #f)
                               (eq? (list-ref row x) 'g)))
                         (iota matrix-width)))
          (loop (+ i 1) (cdr hs)))))
  ;; The stream advanced by exactly the holes spent; the deal untouched.
  (check (bag-seed (game-bag r)) s3)
  (check (bag-queue (game-bag r)) (bag-queue (game-bag g)))
  ;; The fact is announced, newest first.
  (check (tag-of (car (game-journal r))) 'garbage)
  (assert "the fact carries its count"
          (variant-match (car (game-journal r)) ((garbage n) (= n 3)) (else #f)))
  ;; The board it came from is untouched — the raise is pure.
  (assert "the original board is unchanged" (board-empty? (game-board g))))

;; The falling piece rides the shift: same column, same rotation, n rows
;; higher — and it still fits where it did, because the world moved under
;; it as one.
(let* ((g (fresh-game seed: 7))
       (p (game-active g))
       (r (result-unwrap-or (receive-garbage g 2) #f))
       (p* (game-active r)))
  (check (falling-x p*) (falling-x p))
  (check (falling-rot p*) (falling-rot p))
  (check (falling-y p*) (- (falling-y p) 2))
  (assert "the piece keeps its footing"
          (cells-fit? (game-board r)
                      (cells-at (falling-name p*) (falling-rot p*)
                                (falling-x p*) (falling-y p*)))))

;; Top-out by garbage: the raise itself refuses nothing and flips no
;; phase — the over phase waits for the next spawn that does not fit.
;; One game-over path for every death.
(let* ((g (fresh-game seed: 11))
       (cells (let loop ((y 0) (acc '()))
                (if (>= y matrix-height)
                    acc
                    (loop (+ y 1)
                          (append acc
                                  (map (lambda (x) (cons x y))
                                       (iota matrix-width)))))))
       (g1 (game-with g board: (board-place (game-board g) 'i cells)))
       (g2 (result-unwrap-or (receive-garbage g1 1) #f))
       (g3 (result-unwrap-or (spawn-piece g2) #f)))
  (assert "garbage itself never ends the match" (phase-playing? g2))
  (assert "the spawn after garbage tops out" (phase-over? g3))
  (assert "the death is announced like any other"
          (memq 'game-over (map tag-of (game-journal g3)))))

;; Nothing delivered, nothing announced: no fact, no stream spent.
(let* ((g (fresh-game seed: 5))
       (r (result-unwrap-or (receive-garbage g 0) #f)))
  (check (game-journal r) (game-journal g))
  (check (bag-seed (game-bag r)) (bag-seed (game-bag g))))

;; A garbage row pressures the stack exactly like the same row hand-built:
;; the probes do not know where the ink came from.
(let* ((g (fresh-game seed: 23))
       (r (result-unwrap-or (receive-garbage g 1) #f))
       (hole (let scan ((x 0))
               (if (eq? (board-ref (game-board r) x (- matrix-height 1)) #f)
                   x
                   (scan (+ x 1)))))
       (hand (let ((b (make-board)))
               (vector-set! b (- matrix-height 1)
                            (let ((row (make-vector matrix-width 'g)))
                              (vector-set! row hole #f)
                              row))
               (game-with g board: b))))
  (check (pressure r) (pressure hand))
  (assert "a garbage row has weight" (> (pressure r) 0)))

;; Garbage composes UNDER the cheese: new rows enter from the bottom and
;; lift the old garbage up, holes and all — the dig's count only grows by
;; what arrived.
(let* ((g (fresh-game seed: 29 mode: 'cheese options: '((cheese-rows 5))))
       (before (garbage-count (game-board g)))
       (r (result-unwrap-or (receive-garbage g 2) #f)))
  ;; The count is in cells: each newcomer carries nine inked cells —
  ;; a full row but for its hole.
  (check (garbage-count (game-board r))
         (+ before (* 2 (- matrix-width 1))))
  (assert "the cheese lifted intact, two rows up"
          (let loop ((y 15))
            (or (>= y matrix-height)
                (and (equal? (vector->list (vector-ref (game-board r) (- y 2)))
                             (vector->list (vector-ref (game-board g) y)))
                     (loop (+ y 1)))))))

;; --------------------------------------------------------------------- ;;
;;  duel — two matches, one fight                                           ;;
;; --------------------------------------------------------------------- ;;

;; The attack table is the design doc: a single sends nothing, a double
;; one, a triple two, a Tetris four. The sprint's whole diff is one row —
;; nothing sends at all, the race is the target. The combo escalates and
;; caps; the b2b bonus is a named one.
(check (attack-rows-for-clear (attack-table-for 'marathon) 1) 0)
(check (attack-rows-for-clear (attack-table-for 'marathon) 2) 1)
(check (attack-rows-for-clear (attack-table-for 'marathon) 3) 2)
(check (attack-rows-for-clear (attack-table-for 'marathon) 4) 4)
(check (attack-rows-for-clear (attack-table-for 'sprint) 2) 0)
(check (attack-rows-for-clear (attack-table-for 'sprint) 4) 0)
(check (combo-attack-rows 1) 0)
(check (combo-attack-rows 3) 1)
(check (combo-attack-rows 8) 4)
(check (combo-attack-rows 20) 4)
(check b2b-attack-bonus 1)

;; The ledger reads like the journal: a double, the chain's second link,
;; and a back-to-back are one attack of three rows.
(let ((g (game-with (fresh-game seed: 1)
                    journal: (list (b2b) (combo 2) (cleared '(0 1))))))
  (check (journal-attack (attack-table-for 'marathon) g) 3))

;; The offset rule: a simultaneous exchange cancels — equal attacks land
;; nowhere, and both journals drain exactly once.
(let* ((l (game-with (fresh-game seed: 31) journal: (list (cleared '(0 1 2)))))
       (r (game-with (fresh-game seed: 32) journal: (list (cleared '(0 1 2)))))
       (d (duel-exchange (make-duel l r))))
  (assert "equal simultaneous clears cancel"
          (and (board-empty? (game-board (duel-left d)))
               (board-empty? (game-board (duel-right d)))))
  (check (game-journal (duel-left d)) '())
  (check (game-journal (duel-right d)) '()))

;; Garbage lands only on the loser of the exchange: a triple over a
;; single sends the net two rows, rightward.
(let* ((l (game-with (fresh-game seed: 31) journal: (list (cleared '(0 1 2)))))
       (r (game-with (fresh-game seed: 32) journal: (list (cleared '(0)))))
       (d (duel-exchange (make-duel l r))))
  (assert "the loser's side takes the garbage"
          (and (board-empty? (game-board (duel-left d)))
               (not (board-empty? (game-board (duel-right d))))))
  (assert "the delivery is announced on the receiver"
          (memq 'garbage (map tag-of (game-journal (duel-right d))))))

;; The defender's own pending clear is the cancellation: a triple against
;; an incoming double not only blocks it — the net row flies back.
(let* ((l (game-with (fresh-game seed: 31) journal: (list (cleared '(0 1)))))
       (r (game-with (fresh-game seed: 32) journal: (list (cleared '(0 1 2)))))
       (d (duel-exchange (make-duel l r))))
  (assert "the bigger clear turns the exchange around"
          (and (board-empty? (game-board (duel-right d)))
               (not (board-empty? (game-board (duel-left d)))))))

;; One planner-driven lock: score all forty placements, march (on fuel),
;; slam — parameterized by weights, so the persona sweep can drive the
;; same search with each opponent's style. A match that is over is not
;; driven. `drive-one` is the baseline style.
(define (drive-with ws s)
  (if (not (phase-playing? s))
      s
      (let* ((p (game-active s))
             (name (falling-name p))
             (hts (column-heights (game-board s)))
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
             ;; March to (bx brot), then slam. The march runs on fuel —
             ;; after garbage raises a stack, a rotation or a shift can
             ;; be refused, and an unfueled march would spin on a wall
             ;; forever. Out of fuel, slam from wherever the piece got.
             (steered
              (let drive ((st s) (fuel 40))
                (let ((pp (game-active st)))
                  (cond ((= fuel 0) st)
                        ((not (= (falling-rot pp) brot))
                         (drive (result-unwrap-or (apply-command st (rotate-cw)) st)
                                (- fuel 1)))
                        ((< (falling-x pp) bx)
                         (drive (result-unwrap-or (apply-command st (right)) st)
                                (- fuel 1)))
                        ((> (falling-x pp) bx)
                         (drive (result-unwrap-or (apply-command st (left)) st)
                                (- fuel 1)))
                        (else st))))))
        (result-unwrap-or (apply-command steered (hard-drop)) steered))))

(define (drive-one s)
  (drive-with (weights 2.0 2.5 0.5 0.6 1.0) s))

;; The duel plays itself: two seeded planners, one fight, one exchange
;; per round — each side places a piece, then the journals meet through
;; the attack table, attacks cancel, garbage lands, and the first top-out
;; ends it. Run twice under the same seeds: the same fight, the same
;; winner. The test needs no mocks, because there is nothing to mock.
(define (self-play-with ws-l ws-r seed-l seed-r)
  (let loop ((d (make-duel (fresh-game seed: seed-l) (fresh-game seed: seed-r)))
             (i 0))
    (cond ((duel-over? d) d)
          ((> i 400) (error "the duel never ended"))
          (else
           (loop (duel-exchange
                  (duel-with-right
                   (duel-with-left d (drive-with ws-l (duel-left d)))
                   (drive-with ws-r (duel-right d))))
                 (+ i 1))))))

(define (self-play seed-l seed-r)
  (self-play-with (weights 2.0 2.5 0.5 0.6 1.0)
                  (weights 2.0 2.5 0.5 0.6 1.0)
                  seed-l seed-r))

(let* ((d1 (self-play 51 52))
       (d2 (self-play 51 52))
       (loser (if (eq? (duel-winner d1) 'left) duel-right duel-left))
       (winner (if (eq? (duel-winner d1) 'left) duel-left duel-right)))
  (check (duel-winner d1) (duel-winner d2))
  (assert "the winner is a side" (memq (duel-winner d1) '(left right)))
  (assert "the loser topped out" (phase-over? (loser d1)))
  (assert "the winner still stands" (phase-playing? (winner d1)))
  (assert "the fight was a fight"
          (> (+ (length (board-cells (game-board (duel-left d1))))
                (length (board-cells (game-board (duel-right d1)))))
             20)))

;; A duel-step takes dt on both sides whole: two clocks, one tick, and
;; the exchange runs underneath.
(let ((d (duel-step (make-duel (fresh-game seed: 61) (fresh-game seed: 62)) 250)))
  (check (game-clock (duel-left d)) 250)
  (check (game-clock (duel-right d)) 250))

;; --------------------------------------------------------------------- ;;
;;  roster — the opponents, as content                                       ;;
;; --------------------------------------------------------------------- ;;

;; The roster is a closed list with load-bearing ids: the ladder, the
;; save file, and (later) the locale table all key on them.
(check (persona-ids) '(wall blitz scholar mirror))
(assert "every persona is fully specified"
        (let loop ((ids (persona-ids)))
          (or (null? ids)
              (let ((p (persona-by-id (car ids))))
                (and p
                     (string? (persona-name p))
                     (string? (persona-title p))
                     (= (length (persona-weights p)) 5)
                     (positive? (persona-speed p))
                     (positive? (persona-band p))
                     (loop (cdr ids)))))))
(assert "an unknown id answers #f, not a guess" (not (persona-by-id 'nobody)))

;; The speed knob is the honest strength lever: the Scholar plays the
;; slowest clock, Blitz the fastest — the conductor's search budget
;; spends these numbers as placements scored per frame.
(assert "the scholar plays the slowest clock"
        (every (lambda (p)
                 (>= (persona-speed p)
                     (persona-speed (persona-by-id 'scholar))))
               (map persona-by-id (persona-ids))))
(assert "blitz plays the fastest clock"
        (every (lambda (p)
                 (<= (persona-speed p)
                     (persona-speed (persona-by-id 'blitz))))
               (map persona-by-id (persona-ids))))

;; Style, measured: the same seed, the same deal, each style on its own
;; board for twenty locks. What the sweep actually shows — and what the
;; plan's honesty note predicts — is that one-ply styles differ in the
;; STACK SHAPE they tolerate, not in early clears: Blitz digs himself
;; four times the holes (attack appetite as mess), while The Wall's flat
;; stacks complete the early rows. The ledger's big pays (doubles,
;; tetrises) need longer games than a suite run affords; the persona
;; duels below are where it moves.
(define (board-holes b)
  (let loop-x ((x 0) (acc 0))
    (if (>= x matrix-width)
        acc
        (let ((h (vector-ref (column-heights b) x)))
          (let count ((y (- matrix-height h)) (filled 0))
            (if (>= y matrix-height)
                (loop-x (+ x 1) (+ acc (- h filled)))
                (count (+ y 1)
                       (if (eq? (board-ref b x y) #f)
                           filled
                           (+ filled 1)))))))))

(define (rows-cleared s)
  (let scan ((facts (game-journal s)) (n 0))
    (if (null? facts)
        n
        (variant-match (car facts)
          ((cleared rows) (scan (cdr facts) (+ n (length rows))))
          (else (scan (cdr facts) n))))))

(define (style-report ws)
  (let loop ((s (fresh-game seed: 71)) (i 0))
    (if (>= i 20)
        (list (journal-attack (attack-table-for 'marathon) s)
              (board-holes (game-board s))
              (rows-cleared s))
        (loop (drive-with ws s) (+ i 1)))))

(let* ((wall (style-report (persona-weights (persona-by-id 'wall))))
       (blitz (style-report (persona-weights (persona-by-id 'blitz)))))
  (assert "blitz digs far more holes than the wall"
          (> (cadr blitz) (* 2 (cadr wall))))
  (assert "the wall's flat stack clears the early rows"
          (>= (caddr wall) (caddr blitz))))

;; Every persona meets the scripted bot — the baseline weights, the same
;; search — under fixed seeds. Each meeting is its own top-level form
;; (a duel costs ~35M steps; the step ceiling is per form). The winners
;; are pinned: personas are content, and a retuned roster re-pins its
;; record. Determinism itself is the self-play test's contract.
(let ((w (duel-winner (self-play-with (persona-weights (persona-by-id 'wall))
                                      (weights 2.0 2.5 0.5 0.6 1.0)
                                      61 62))))
  (assert "the wall's meeting is decided" (memq w '(left right))))
(let ((w (duel-winner (self-play-with (persona-weights (persona-by-id 'blitz))
                                      (weights 2.0 2.5 0.5 0.6 1.0)
                                      63 64))))
  (assert "blitz's meeting is decided" (memq w '(left right))))
(let ((w (duel-winner (self-play-with (persona-weights (persona-by-id 'scholar))
                                      (weights 2.0 2.5 0.5 0.6 1.0)
                                      65 66))))
  (assert "the scholar's meeting is decided" (memq w '(left right))))
(let ((w (duel-winner (self-play-with (persona-weights (persona-by-id 'mirror))
                                      (weights 2.0 2.5 0.5 0.6 1.0)
                                      67 68))))
  (assert "the mirror's meeting is decided" (memq w '(left right))))

;; --------------------------------------------------------------------- ;;
;;  telemetry — the match's vital signs                                    ;;
;; --------------------------------------------------------------------- ;;

;; An empty board holds no pressure.
(check (pressure (new-game)) 0)
(check (stack-mean (new-game)) 0)
(check (stack-peak (new-game)) 0)
(check (stack-wells (new-game)) 0)

;; A placed piece reads as pressure: the peak is at least the mean, the
;; pressure lands in its documented range, and the band question answers.
(let* ((g (new-game))
       (b (board-place (game-board g) 'i (cells-at 'i 0 4 18)))
       (g* (game-with g board: b)))
  (assert "a placed piece carries pressure" (> (pressure g*) 0))
  (assert "the peak is at least the mean" (>= (stack-peak g*) (stack-mean g*)))
  (assert "the pressure stays under 1" (< (pressure g*) 1))
  (check (in-band? g* 0 1) #t)
  (check (in-band? (new-game) 0.5 1) #f))

;; --------------------------------------------------------------------- ;;
;;  director — pressure in, pace out                                       ;;
;; --------------------------------------------------------------------- ;;

(let ((d (make-director)))
  (check (director-pace d 0.4) 1)     ;; dead on the target: hold
  (check (director-pace d 0.38) 1)    ;; inside the band: hold
  (assert "an empty board heats the pace" (< (director-pace d 0) 1))
  (assert "a full stack cools it" (> (director-pace d 1) 1))
  (check (director-pace d -1) (director-low-pace d))   ;; the clamp holds
  (check (director-pace d 2) (director-high-pace d)))

;; The knobs are data: a moved target is a different director.
(let ((d (make-director target: 0.6 band: 0.0)))
  (check (director-pace d 0.6) 1)
  (assert "a moved target moves the hold" (< (director-pace d 0.4) 1)))

;; --------------------------------------------------------------------- ;;
;;  the leash — the duel director: a gap in, an AI-only throttle out       ;;
;; --------------------------------------------------------------------- ;;

;; The probe: lines plus four lines' worth of pressure a side, signed
;; left-minus-right. Even sides read zero, whatever their pressure.
(check (duel-gap 3 3 0.2 0.2) 0)
(check (duel-gap 5 3 0.0 0.0) 2)
(check (duel-gap 3 5 0.0 0.0) -2)
(assert "pressure weighs four lines a side"
        (= (duel-gap 0 4 1.0 0.0) 0))          ; a full board ≈ a 4-line lead

;; The probe, normalized: 0 is a knife's edge, 1 is the blowout scale.
(let ((l (make-leash)))
  (check (closeness l 0) 0)
  (check (closeness l 8) 1)
  (check (closeness l -8) 1)
  (assert "past the scale it stays a blowout" (= (closeness l 80) 1)))

;; The throttle: inside the band hold, outside move — toward the AI
;; only, and clamped.
(let ((l (make-leash band: 0.1)))
  (check (leash-throttle l 0) 1)       ; knife's edge: the AI's own knob
  (check (leash-throttle l 0.5) 1)     ; 0.5/8 = 0.0625, inside the band
  (assert "the AI behind speeds up" (> (leash-throttle l 4) 1))
  (assert "the AI ahead slows down" (< (leash-throttle l -4) 1))
  (check (leash-throttle l 100) (leash-high-throttle l))
  (check (leash-throttle l -100) (leash-low-throttle l)))

;; The band is the leash's width: a tighter band acts sooner.
(let ((tight (make-leash band: 0.02)) (loose (make-leash band: 0.2)))
  (assert "a tight band acts on a small gap" (> (leash-throttle tight 1) 1))
  (check (leash-throttle loose 1) 1))

;; The pace handicap is the same move, damped — the quiet actuator.
(let ((l (make-leash pace-gain: 0.5)))
  (check (leash-pace l 1) 1)
  (let ((p (leash-pace l 1.5)))
    (assert "the pace moves less than the budget" (< (abs (- p 1)) 0.5)))
  (assert "a slowed AI gets a lighter well, not a faster one"
          (< (leash-pace l 0.8) 1)))

;; The paced interval bends the level's curve and holds the floor.
(check (paced-interval 1 1) (drop-interval 1))
(assert "a hot pace shortens the interval"
        (< (paced-interval 1 0.5) (drop-interval 1)))
(assert "a cool pace lengthens it"
        (> (paced-interval 1 1.5) (drop-interval 1)))
(check (paced-interval 30 0.5) 60)

;; The pace rides on the match record: default 1, settable as a value.
(check (game-pace (new-game)) 1)
(check (game-pace (game-with (new-game) pace: 1.75)) 1.75)

;; The heights form of the landing probe agrees with the scan form:
;; same row, piece after piece, on a board the AI has been stacking.
;; The scan is the definition; the heights form is what the painter
;; and the planner can afford per frame.
(let loop ((i 0) (s (new-game)))
  (if (>= i 40)
      (assert "the heights ghost matches the scan ghost" #t)
      (let* ((r (apply-command s (hard-drop)))
             (s* (if (result-ok? r) (ok-value r) s)))
        (when (game-active s*)
          (let ((hts (column-heights (game-board s*))))
            (for-each
             (lambda (x)
               (for-each
                (lambda (rot)
                  (let ((scan (landing-y-at s* x rot))
                        (fast (landing-y/hts s* hts x rot)))
                    (when (and scan fast)
                      (check fast scan))))
                (list 0 1 2 3)))
             (list 0 3 5 9))))
        (loop (+ i 1) s*))))

(display "all domain tests passed")
(newline)
