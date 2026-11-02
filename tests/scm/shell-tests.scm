;;; tests/scm/shell-tests.scm — the whole shell's screen transitions, in Scheme.
;;;
;;; The Python suite `test_menu_transitions.py` walks the same map through
;;; the REAL host (pygame events, real keymap); this one walks it through
;;; the fake host, so the conductor's transition table is checked twice —
;;; once against pygame's event shape, once against the fake's. The two
;;; suites disagree only where the hosts do, and that is the point.
;;;
;;; The map under test:
;;;
;;;   title ──enter──▶ campaign ──esc──▶ title
;;;     └──enter──▶ mode ──esc──▶ title; mode ──enter──▶ level ──esc──▶ title
;;;   play (live) ──esc──▶ paused ──esc──▶ title
;;;   play (over) ──esc/return──▶ title; ──r──▶ a fresh match, same recipe
;;;   play (won)  ──esc/return──▶ title; ──r──▶ a fresh match, same recipe
;;;   title ──esc──▶ quit
;;;
;;; The `r` checks are the regression fence for the replay bug: the replay
;;; hands `start-match!` a mode NAME that must cross back as a SYMBOL — a
;;; string here read as an unknown mode, and the guard dumped the player
;;; at the title with only a console message.

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
(load "presentation/view")
(load "conductor/arcade")

(load "testkit")
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

;; Boot fresh and start a free-play match.
(define (boot-into! mode-name options)
  (boot-fresh!)
  (start-match! mode-name options 'free #f #f #f))

;; Slam pieces into the spawn column until top-out: no steering, a fat
;; clock so gravity drops a row a frame. The clamp caps the repeat pump's
;; share; gravity gets the honest (clamped) dt, and the well fills.
(define (play-until-over!)
  (host-clock! 1000 2000)
  (host-run-while-playing! 2000)
  (if (eq? (phase) 'over)
      #t
      (error "shell-tests: slamming never topped out")))

;; Force the other terminal phase: a victory with the match's recipe kept.
(define (win-now!)
  (set! *st* (game-with *st* phase: (won))))

;; --------------------------------------------------------------------- ;;
;;  the forward walks                                                       ;;
;; --------------------------------------------------------------------- ;;

(tk-section "forward walks")

(boot-fresh!)
(tk-check "boot lands on the title" (screen) 'title)

(host-tap! "return")
(tk-check "enter opens the campaign ladder" (screen) 'campaign)

(boot-fresh!)
(host-tap! "down")               ; the cursor to Free play
(host-tap! "return")
(tk-check "free play opens the mode list" (screen) 'mode)
(host-tap! "return")
(tk-check "a mode pick opens the level picker" (screen) 'level)
(host-tap! "return")
(tk-check "the level pick starts a match" (screen) 'play)
(tk-assert "the match is live" (eq? (phase) 'playing))

;; --------------------------------------------------------------------- ;;
;;  the back walks — ESC is "back one step" from every screen               ;;
;; --------------------------------------------------------------------- ;;

(tk-section "back walks")

(boot-fresh!)
(host-tap! "return")
(host-tap! "escape")
(tk-check "esc on the ladder goes back" (screen) 'title)

(boot-fresh!)
(host-tap! "down") (host-tap! "return")   ; -> mode
(host-tap! "escape")
(tk-check "esc on the mode screen goes back" (screen) 'title)

(boot-fresh!)
(host-tap! "down") (host-tap! "return") (host-tap! "return")  ; -> level
(host-tap! "escape")
(tk-check "esc on the level picker goes back" (screen) 'title)

(boot-into! 'marathon '())
(host-tap! "escape")
(tk-assert "esc in a live match pauses" (eq? (phase) 'paused))
(tk-check "a pause keeps the play screen" (screen) 'play)
(host-tap! "escape")
(tk-check "esc from a paused match goes back" (screen) 'title)

(boot-fresh!)
(host-tap! "escape")
(tk-assert "esc on the title asks to quit" *host-quit?*)

;; --------------------------------------------------------------------- ;;
;;  the finished match — a decision point with its own keymap               ;;
;; --------------------------------------------------------------------- ;;

(tk-section "a finished match")

(boot-into! 'marathon '())
(play-until-over!)
(tk-check "top-out keeps the play screen" (screen) 'play)
(host-tap! "escape")
(tk-check "esc after a game over reaches the title" (screen) 'title)

(boot-into! 'marathon '())
(play-until-over!)
(host-tap! "return")
(tk-check "return after a game over reaches the title" (screen) 'title)

;; The replay: r must start a FRESH match, not bounce to the title.
(boot-into! 'marathon '())
(play-until-over!)
(host-tap! "r")
(tk-check "r after a game over restarts" (screen) 'play)
(tk-assert "the replayed match is live" (eq? (phase) 'playing))

;; The other terminal phase: a win answers the same keys.
(boot-into! 'sprint '((target-lines 1)))
(win-now!)
(host-tap! "escape")
(tk-check "esc after a victory reaches the title" (screen) 'title)

(boot-into! 'sprint '((target-lines 1)))
(win-now!)
(host-tap! "return")
(tk-check "return after a victory reaches the title" (screen) 'title)

(boot-into! 'sprint '((target-lines 1)))
(win-now!)
(host-tap! "r")
(tk-check "r after a victory restarts" (screen) 'play)
(tk-assert "the replayed match is live" (eq? (phase) 'playing))
(tk-check "the replay kept its recipe"
          (config-target-lines (game-config *st*)) 1)

;; The result screen reads the journal exactly once: a terminal fact is
;; announced on the frame it lands and never again, however long the
;; result sits. The journal must actually DRAIN — a dropped
;; `drain-journal!` return value here repainted the screen and replayed
;; the victory every frame, machine-gun style.
(boot-into! 'sprint '((target-lines 1)))
(set! *st* (with-event (game-with *st* phase: (won)) (victory)))
(host-run-frames! 10)
(tk-check "the victory is heard exactly once"
          (count (cut string=? "victory" <>) (host-sfx-names)) 1)
(tk-assert "the result journal drained" (null? (game-journal *st*)))

;; The over screen's movers are return, r and escape (q quits — see above).
(boot-into! 'marathon '())
(play-until-over!)
(host-tap! "down") (host-tap! "space") (host-tap! "p") (host-tap! "left")
(tk-check "dead keys keep the over screen" (screen) 'play)
(tk-check "dead keys keep the over phase" (phase) 'over)

;; q is the quit key everywhere else (title, menus, live match) — the
;; decision points answer it too.
(boot-into! 'marathon '())
(host-tap! "escape")
(host-tap! "q")
(tk-assert "q on a paused match asks to quit" *host-quit?*)

(boot-into! 'marathon '())
(play-until-over!)
(host-tap! "q")
(tk-assert "q on the over screen asks to quit" *host-quit?*)

;; --------------------------------------------------------------------- ;;
;;  the paint, not just the decision                                        ;;
;; --------------------------------------------------------------------- ;;
;;
;; *screen* can be right while the window shows the old match: the leaving
;; frame used to repaint the result screen and SPEND the dirty flag, so the
;; title never painted — and a second ESC, landing on a logically-title
;; screen, quit the app. These checks read the fake host's draw log — the
;; frame the player actually sees, not the decision the conductor made.

(tk-section "the paint, not just the decision")

(boot-into! 'sprint '((target-lines 1)))
(win-now!)
(host-run-frames! 1)                      ; the result paints once
(define before-leave (length (host-ops 'text)))
(define before-leave-presents (host-frame-count))
(host-tap! "escape")
(tk-check "esc after a victory reaches the title" (screen) 'title)
(tk-assert "the leaving frame presents nothing"
           (= (host-frame-count) before-leave-presents))
(tk-assert "the leaving frame owes the title its paint" *dirty*)
(host-run-frames! 1)
(tk-assert "the next frame paints the title"
           (member "SCHEME TETRIS"
                   (list-tail (host-text-strings) before-leave)))
(tk-assert "the title's paint is paid" (not *dirty*))
(define quiet-presents (host-frame-count))
(host-run-frames! 3)
(tk-assert "idle frames on the title paint nothing"
           (= (host-frame-count) quiet-presents))

;; The same through RETURN, from the over screen.
(boot-into! 'marathon '())
(play-until-over!)
(define before-return (length (host-ops 'text)))
(host-tap! "return")
(tk-check "return after a game over reaches the title" (screen) 'title)
(tk-assert "return's leaving frame owes the paint too" *dirty*)
(host-run-frames! 1)
(tk-assert "the title painted after the over screen"
           (member "SCHEME TETRIS"
                   (list-tail (host-text-strings) before-return)))

;; --------------------------------------------------------------------- ;;
;;  effects belong to their match                                           ;;
;; --------------------------------------------------------------------- ;;

(tk-section "effects belong to their match")

(boot-into! 'marathon '())
(view-clear-beam! '(1 2 3 4))     ; the award, by hand: the unit under
(view-flash! '(255 255 0) 300)    ; test is the RESET, not the award
(tk-assert "the beam is burning" (> *beam-ms* 0))
(show-screen! 'title (title-menu))        ; leave within the flash window
(tk-assert "leaving to a menu douses the flash" (= *flash-ms* 0))
(tk-assert "leaving to a menu douses the beam" (= *beam-ms* 0))
(start-match! 'marathon '() 'free #f #f #f)
(tk-assert "a new match starts clean" (and (= *flash-ms* 0) (= *beam-ms* 0)))
(host-run-frames! 2)
(tk-check "the fresh match is live" (phase) 'playing)

;; --------------------------------------------------------------------- ;;
;;  a refused match leaves a healthy title                                  ;;
;; --------------------------------------------------------------------- ;;

(tk-section "a refused match leaves a healthy title")

(boot-fresh!)
(start-match! 'bogus '() 'free #f #f #f)
(tk-check "the refusal lands on the title" (screen) 'title)
(tk-assert "the title menu was rebuilt" (> (menu-count *menu*) 0))
(tk-assert "the title will paint" *dirty*)
(host-tap! "return")
(tk-check "return on the rebuilt title answers" (screen) 'campaign)

;; The cold-boot version: a bad --mode, the very first frames of the app.
(host-reset!)
(set! *host-boot-config* '((autostart . #t) (mode . "bogus")))
(open-window! window-width window-height "cold-refused")
(boot!)
(tk-check "a refused cold boot lands on the title" (screen) 'title)
(tk-assert "the cold-boot title has a menu" (> (menu-count *menu*) 0))
(host-tap! "return")
(tk-check "return on the cold-boot title answers" (screen) 'campaign)

;; --------------------------------------------------------------------- ;;
;;  menus honor held arrows                                                 ;;
;; --------------------------------------------------------------------- ;;

(tk-section "menus honor held arrows")

(boot-fresh!)
(host-type! "return")             ; title -> the ladder (8 rungs)
(tk-check "return opened the ladder" (screen) 'campaign)
(host-type! "down")               ; one move: the cursor to 1
(host-clock! 16 12)               ; twelve more frames of the held key:
(host-run-frames! 12)             ; DAS burns, then the repeats fire
(tk-assert "a held arrow moved the cursor more than once"
           (> (menu-cursor *menu*) 1))

;; One-shots stay one-shots: a held RETURN must not re-pick.
(boot-fresh!)
(host-type! "return")             ; title -> the ladder
(tk-check "return opened the ladder" (screen) 'campaign)
(host-clock! 16 12)
(host-run-frames! 12)
(tk-assert "a held return does not re-pick" (eq? (screen) 'campaign))

;; --------------------------------------------------------------------- ;;
;;  the campaign ladder from a won rung                                     ;;
;; --------------------------------------------------------------------- ;;

(tk-section "a won campaign rung")

(boot-fresh!)
(host-tap! "return") (host-tap! "return")   ; ladder -> first rung
(tk-check "the first rung starts" (screen) 'play)
(win-now!)
(host-tap! "return")
(tk-check "a won rung's return starts the next challenge" (screen) 'play)
(tk-assert "the next match is live" (eq? (phase) 'playing))

(boot-fresh!)
(host-tap! "return") (host-tap! "return")
(win-now!)
(host-tap! "escape")
(tk-check "esc on a won rung goes back" (screen) 'title)

;; --------------------------------------------------------------------- ;;
;;  the round trip — the shell still answers after a whole session          ;;
;; --------------------------------------------------------------------- ;;

(tk-section "round trip")

(boot-fresh!)
(host-tap! "down") (host-tap! "return") (host-tap! "return") (host-tap! "return")
(tk-check "the first match starts" (screen) 'play)
(play-until-over!)
(host-tap! "escape")
(tk-check "esc after game over reaches the title" (screen) 'title)
(host-tap! "down") (host-tap! "return")
(tk-check "the mode screen reopens" (screen) 'mode)
(host-tap! "return")
(tk-check "the level picker reopens" (screen) 'level)
(host-tap! "return")
(tk-check "a second match starts" (screen) 'play)
(tk-assert "the second match is live" (eq? (phase) 'playing))

(tk-report! "shell")
