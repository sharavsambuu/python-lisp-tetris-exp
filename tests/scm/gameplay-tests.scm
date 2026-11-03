;;; tests/scm/gameplay-tests.scm — gameplay behavior, whole matches at a time.
;;;
;;; These run the REAL conductor loop (`arcade-step!`) against the fake
;;; host: keys are queued as events, frames advance a fake clock, and the
;;; assertions are about the match record and the shell's state — not about
;;; pixels. What is covered here is the *behavior* a player would notice:
;;; the input repeat's rhythm, a scoring chain, a sprint win steered by the
;;; built-in AI, the campaign ladder advancing on a win, and the way out
;;; after a game over.

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
(load "content/locale")
(load "presentation/view")
(load "conductor/arcade")

(load "testkit")   ; resolved through the pytest search paths
(load "fake-host")

;; The kit's recorder, sugared locally — define-syntax does not cross a
;; file boundary in this loader, so the two-line sugar lives with its users.
(define-syntax tk-check
  (syntax-rules ()
    ((_ label expr expected)
     (let ((actual expr) (wanted expected))
       (tk-record! label (equal? actual wanted) actual wanted)))))
(define-syntax tk-assert
  (syntax-rules ()
    ((_ label expr)
     (tk-record! label (if expr #t #f) expr #t))))

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

(tk-reset!)

;; --------------------------------------------------------------------- ;;
;;  helpers                                                                 ;;
;; --------------------------------------------------------------------- ;;

(define (screen) *screen*)
(define (phase) (tag-of (game-phase *st*)))

;; A fresh shell with the window open — the same ritual arcade-main does.
(define (boot-fresh!)
  (host-reset!)
  (open-window! window-width window-height "test")
  (boot!))

;; Boot the shell fresh and start a free-play match of one mode.
(define (boot-into! mode-name options)
  (boot-fresh!)
  (start-match! mode-name options 'free #f #f #f))

;; --------------------------------------------------------------------- ;;
;;  the input repeat — DAS/ARR as a player feels it                          ;;
;; --------------------------------------------------------------------- ;;

(tk-section "input repeat")

(boot-into! 'marathon '())
(tk-assert "a match is live" (phase-playing? *st*))

;; One tap of left is one column — no repeat sneaks in.
(let ((x0 (falling-x (game-active *st*))))
  (host-type! "left")
  (tk-check "a tap moves one column"
            (falling-x (game-active *st*)) (- x0 1)))

;; Holding left, from a fresh match so the repeat clock starts at zero.
;; The press frame fires one move and starts the clock; the pump lives in
;; the HOST (the reference edge's design): the delay is 150ms and the
;; interval 40ms. So: 8 frames (128ms) — one move, nothing more — then 4
;; more frames (192ms on the clock) — repeats fire. That is the whole DAS
;; contract, and it holds no matter which piece spawned (a wall would clamp
;; a naive "n columns" claim).
(boot-into! 'marathon '())
(let* ((x0 (falling-x (game-active *st*))))
  (host-press! "left")            ; the press is this frame's event
  (host-clock! 16 8)              ; 8 frames = 128ms, inside the delay
  (host-run-frames! 8)
  (let ((held-x (falling-x (game-active *st*))))
    (tk-check "the press moved one column, and no repeat has fired"
              (- x0 held-x) 1)
    (host-clock! 16 4)            ; 4 more frames = 192ms on the clock
    (host-run-frames! 4)
    (tk-check "past the delay, the repeat fires"
              (< (falling-x (game-active *st*)) held-x) #t)
    (host-release! "left")
    (host-run-frames! 1)          ; the release takes its own frame
    (tk-assert "the piece is still on the board" (game-active *st*))))

;; Soft drop rides the same pump as steering (the reference feel): a held
;; down-key repeats once the delay burns. Fourteen frames are 224ms —
;; gravity at level 1 would not have moved the piece at all, so several
;; rows of fall is the pump working.
(boot-into! 'marathon '())
(let* ((y0 (falling-y (game-active *st*))))
  (host-press! "down")
  (host-clock! 16 14)             ; 224ms of holding
  (host-run-frames! 14)
  (let ((moved (- (falling-y (game-active *st*)) y0)))
    (tk-assert "held soft drop fell faster than gravity" (>= moved 2))
    (tk-assert "soft drop did not teleport" (<= moved 5))
    (host-release! "down")
    (host-run-frames! 1)))

;; Gravity is the clock's work, not a player's move: an idle match falls
;; silent. Level 1 pulls a row every 900ms, so 1.92s of idle time is two
;; rows — enough to prove the descent happened, and that it said nothing.
(boot-into! 'marathon '())
(let ((y0 (falling-y (game-active *st*))))
  (host-clock! 16 120)            ; 120 frames = 1.92s: two level-1 ticks
  (host-run-frames! 120)
  (tk-assert "gravity did move the piece"
             (> (falling-y (game-active *st*)) y0))
  (tk-assert "an idle match is silent"
             (not (member "move" (host-sfx-names)))))

;; Shift swaps: the held piece takes the piece's place and a new piece
;; spawns; a second shift is refused (one swap per piece) and changes
;; nothing.
(boot-into! 'marathon '())
(let* ((first (falling-name (game-active *st*))))
  (host-type! "shift")
  (host-run-frames! 1)
  (tk-check "the swap kept the piece" (game-hold *st*) first)
  (tk-assert "a fresh piece spawned" (game-active *st*))
  (tk-assert "the swap is spent" (not (game-can-hold *st*)))
  (host-type! "shift")
  (host-run-frames! 1)
  (tk-check "the second shift was refused" (game-hold *st*) first))

;; A re-press starts a FRESH repeat clock. The stale milliseconds of the
;; last hold must not buy instant repeats on the next press — before the
;; fix, a second hold after 320ms of holding fired its repeats at once, and
;; the piece lurched several cells. Steering right on the re-press (the
;; piece sits at the left wall after the first hold, so one move is
;; guaranteed): the press plus the whole 144ms delay window must move the
;; piece exactly one column in total.
(boot-into! 'marathon '())
(let* ((x0 (falling-x (game-active *st*))))
  (host-press! "left")
  (host-clock! 16 20)             ; 320ms: delay burned, repeats flowing
  (host-run-frames! 20)
  (host-release! "left")
  (host-run-frames! 1)
  (tk-assert "the piece sits left of centre after the hold"
             (< (falling-x (game-active *st*)) x0))
  (let ((x1 (falling-x (game-active *st*))))   ; before the re-press lands
    (host-press! "right")
    (host-clock! 16 9)              ; the press frame + 8 frames = 144ms
    (host-run-frames! 9)
    (tk-check "a re-press moves exactly one column through the delay"
              (- (falling-x (game-active *st*)) x1) 1)
    (host-release! "right")
    (host-run-frames! 1)))

;; --------------------------------------------------------------------- ;;
;;  a scoring chain — a crafted double, applied through the pipeline         ;;
;; --------------------------------------------------------------------- ;;

(tk-section "scoring chain")

(boot-into! 'marathon '())
;; Craft the well: two rows ready to clear, with one hole each in column
;; two — and inject an I piece, vertical, so the test is deterministic.
;; A hard drop down column two completes both rows at once.
(let* ((hole 2)
       (b (let loop ((bd (game-board *st*)) (ys '(18 19)))
            (if (null? ys)
                bd
                (loop (board-place bd 'i
                                   (map (lambda (x) (cons x (car ys)))
                                        (filter (lambda (x) (not (= x hole)))
                                                (iota matrix-width))))
                      (cdr ys))))))
  (set! *st* (game-with *st*
                        board: b
                        active: (make-falling 'i 3 0 1))))
(tk-assert "the crafted rows are not full yet"
           (null? (full-rows (game-board *st*))))

;; Steer the injected piece into column two and slam.
(let drive ((i 0))
  (let* ((p (game-active *st*))
         (done (and (= (falling-x p) 0) (= (falling-rot p) 1))))
    (cond (done
           (set! *st* (result-unwrap-or (apply-command *st* (hard-drop)) *st*)))
          ((> i 8) (error "could not steer the crafted piece"))
          (else
           (if (not (= (falling-rot p) 1))
               (set! *st* (result-unwrap-or (apply-command *st* (rotate-cw)) *st*))
               (set! *st* (result-unwrap-or (apply-command *st* (left)) *st*)))
           (drive (+ i 1))))))

(tk-check "the double cleared both rows"
          (game-lines *st*) 2)
(tk-check "the double paid a real score" (> (game-score *st*) 0) #t)
;; This clear was applied directly, not through a painted frame, so the
;; journal still holds it.
(tk-assert "the journal announced the clear"
           (memq 'cleared (map tag-of (game-journal *st*))))

;; --------------------------------------------------------------------- ;;
;;  a sprint win, steered by the built-in AI, through the real loop          ;;
;; --------------------------------------------------------------------- ;;

(tk-section "sprint win by the AI")

(boot-into! 'sprint '((target-lines 2)))
(tk-check "the recipe took" (config-target-lines (game-config *st*)) 2)
(set! *ai* #t)
(reset-ai!)

;; The planner steers every piece; gravity (16ms frames) brings them down.
;; A two-line sprint should fall well inside 2400 frames.
(host-run-while-playing! 2400)
(tk-check "the AI finished the sprint" (phase) 'won)
(tk-check "the target was reached" (game-lines *st*) 2)
;; The journal is drained frame by frame (that is the effects rail), so the
;; victory is heard, not read: the speaker got its cue.
(tk-assert "the victory was announced"
           (member "victory" (host-sfx-names)))

;; RETURN at a win walks the ladder — but a free-play win has no ladder,
;; so it goes back to the title instead of anywhere strange.
(host-type! "return")
(tk-check "a free-play win returns to the title" (screen) 'title)

;; --------------------------------------------------------------------- ;;
;;  the campaign ladder — a win unlocks and starts the next level            ;;
;; --------------------------------------------------------------------- ;;

(tk-section "campaign ladder")

(boot-fresh!)
(host-type! "return")             ; title -> the campaign screen
(tk-check "enter opens the ladder" (screen) 'campaign)
(host-type! "return")             ; first challenge -> play
(tk-check "the level starts" (screen) 'play)
(tk-check "the match is live" (phase) 'playing)
(tk-check "the first level's recipe" (config-target-lines (game-config *st*)) 5)
(tk-check "the level key is the ladder's first rung" *playing-key* "ascent:1")

(set! *ai* #t)
(reset-ai!)
(host-run-while-playing! 2400)
(tk-check "the AI cleared the challenge" (phase) 'won)
(host-type! "return")
(tk-check "the win starts the next rung" (screen) 'play)
(tk-check "the next recipe" (config-target-lines (game-config *st*)) 10)
(tk-check "the next level key" *playing-key* "ascent:2")

;; --------------------------------------------------------------------- ;;
;;  the way out — top out, then leave                                        ;;
;; --------------------------------------------------------------------- ;;

(tk-section "game over")

(boot-into! 'marathon '())
(set! *ai* #f)
(reset-ai!)
;; Slam every piece without steering: a fat clock (1s per frame) drops a
;; row a frame, so the well fills in well under the budget.
(host-clock! 1000 2000)
(host-run-while-playing! 2000)
(tk-check "slamming tops the match out" (phase) 'over)
(tk-assert "the game over was announced"
           (member "over" (host-sfx-names)))

;; At a game over, RETURN goes back to the title (a loss ends the ladder).
(host-type! "return")
(tk-check "a game over returns to the title" (screen) 'title)

;; And ESC on the title closes the door: the loop asks to quit.
(host-type! "escape")
(tk-assert "escape on the title asks to quit" *host-quit?*)

(tk-report! "gameplay")

