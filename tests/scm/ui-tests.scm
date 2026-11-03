;;; tests/scm/ui-tests.scm — the shell's screens, as the player sees them.
;;;
;;; The assertions are over the fake host's DRAW LOG, not pixels: which
;;; texts were painted, where, and whether every painter call fits the
;;; window. That keeps the contracts about *behavior* — the veil paints on
;;; pause, the ladder shows its levels, the cursor marks one entry — while
;;; staying honest about geometry: anything drawn outside the viewport is
;;; a bug, wherever the layout table moves next.

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
(load "content/locale")
(load "conductor/profile")
(load "presentation/view")
(load "conductor/effects")
(load "conductor/screens")
(load "conductor/input")
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
        (tetris game) (tetris duel) (tetris roster)
        (tetris commands) (tetris kicks) (tetris scoring) (tetris gravity)
        (tetris rules)
        (tetris campaign) (tetris locale))

(tk-reset!)

(define (screen) *screen*)
(define (phase) (tag-of (game-phase *st*)))

;; A fresh shell: the fake host wiped, the window opened (as arcade-main
;; does), the shell booted. The window matters — the fit invariant reads it.
(define (boot-fresh!)
  (host-reset!)
  (open-window! window-width window-height "test")
  (boot!))

;; The DSL has string-contains? but no prefix test; the cursor check wants
;; one, so here it is — the honest way, character by character.
(define (string-prefix? pre s)
  (and (<= (string-length pre) (string-length s))
       (let loop ((i 0))
         (or (= i (string-length pre))
             (and (char=? (string-ref pre i) (string-ref s i))
                  (loop (+ i 1)))))))

;; --------------------------------------------------------------------- ;;
;;  the title                                                                ;;
;; --------------------------------------------------------------------- ;;

(tk-section "title")

(boot-fresh!)
(tk-check "boot lands on the title" (screen) 'title)
(tk-check "boot opened the window" *host-window* (list window-width window-height))
(tk-assert "the window is square and roomy"
           (and (> (car *host-window*) 500) (= (car *host-window*) (cadr *host-window*))))

;; The title paints: a veil over the whole window, the game's name, and
;; one entry per campaign plus free play and quit.
(draw-screen!)
(tk-assert "the title is painted"
           (member "SCHEME TETRIS" (host-text-strings)))
(tk-assert "the veil covers the whole window"
           (any (lambda (e)
                  (and (eq? (car e) 'rect)
                       (= (list-ref e 1) 0) (= (list-ref e 2) 0)
                       (= (list-ref e 3) window-width)
                       (= (list-ref e 4) window-height)))
                *host-log*))
(tk-assert "the ladder is on the menu"
           (any (lambda (s) (string-contains? s "The Ascent")) (host-text-strings)))
(tk-assert "free play is on the menu"
           (any (lambda (s) (string-contains? s "Free play")) (host-text-strings)))

;; The cursor marks exactly one entry, and it is the first.
(tk-check "exactly one cursor line"
          (length (filter (lambda (s) (string-prefix? ">" s)) (host-text-strings))) 1)

;; Nothing painted outside the viewport — the fit invariant for the frame.
(tk-assert "every painter call fits the window"
           (every host-fits-window? *host-log*))

;; The language setting: two downs from the top land on LANGUAGE; RETURN
;; cycles to Mongolian and the next repaint speaks it. A second RETURN
;; cycles back — the setting is a two-way door. A fresh boot afterwards
;; puts the cursor back where the later sections expect it.
;; The title's rows: the ladder, VERSUS, free play, language, quit — the
;; language row is two downs past the ladder now.
(host-type! "down")
(host-type! "down")
(host-type! "down")
(host-type! "return")
(draw-screen!)
(tk-assert "the menu speaks Mongolian after the toggle"
           (any (lambda (s) (string-contains? s "Монгол")) (host-text-strings)))
(tk-assert "mongolian keeps the title"
           (member "SCHEME TETRIS" (host-text-strings)))
(tk-assert "the mongolian frame's painter calls fit"
           (every host-fits-window? *host-log*))
;; The HUD speaks Mongolian too, and the panels do not move: the painter
;; scales the type until every label fits its budget — a sprint match
;; exercises the widest gauge (ЗОРИЛТ) and the keys panel rows.
(start-match! 'sprint (list (list 'target-lines 5)) 'free #f #f #f)
(draw-game! *st*)
(tk-assert "the mongolian HUD's painter calls fit"
           (every host-fits-window? *host-log*))
(boot-fresh!)
(host-type! "down")
(host-type! "down")
(host-type! "down")
(host-type! "return")
(draw-screen!)
(tk-assert "a second toggle answers English"
           (any (lambda (s) (string-contains? s "English")) (host-text-strings)))
(boot-fresh!)

;; --------------------------------------------------------------------- ;;
;;  the ladder (campaign screen)                                             ;;
;; --------------------------------------------------------------------- ;;

(tk-section "campaign ladder")

(host-type! "return")
(tk-check "enter opens the ladder" (screen) 'campaign)
(draw-screen!)
(tk-assert "the ladder names the campaign"
           (any (lambda (s) (string-contains? s "The Ascent")) (host-text-strings)))
(tk-assert "each level is listed"
           (every (lambda (ch)
                    (any (lambda (s) (string-contains? s (challenge-title ch)))
                         (host-text-strings)))
                  (campaign-levels *campaign*)))
(tk-assert "the ladder's every painter call fits"
           (every host-fits-window? *host-log*))

;; Down then enter picks the second challenge: Ten Lines.
(host-type! "down")
(host-type! "return")
(tk-check "the second challenge starts" (screen) 'play)
(tk-check "its recipe is ten lines" (config-target-lines (game-config *st*)) 10)

;; --------------------------------------------------------------------- ;;
;;  the live match's HUD                                                     ;;
;; --------------------------------------------------------------------- ;;

(tk-section "play HUD")

(boot-fresh!)
(start-match! 'marathon '() 'free #f #f #f)
(draw-game! *st*)
(for-each (lambda (label)
            (tk-assert (string-append "the HUD shows " label)
                       (member label (host-text-strings))))
          '("SCORE" "LINES" "LEVEL" "KEYS"))
(tk-assert "the next queue is announced"
           (any (lambda (s) (string-contains? s "NEXT")) (host-text-strings)))
(tk-assert "the hold box is announced"
           (any (lambda (s) (string-contains? s "HOLD")) (host-text-strings)))
(tk-assert "the HUD's every painter call fits"
           (every host-fits-window? *host-log*))
;; The panels draw the pieces themselves: mini shape cells (13-15px squares,
;; the board's are 25px) on the panels' side of the well — the queue as real
;; pieces, not spellings of them.
(tk-assert "the next queue paints real shape cells"
           (any (lambda (e)
                  (and (eq? (car e) 'rect)
                       (< (list-ref e 3) 20)
                       (>= (list-ref e 1) 400)))
                *host-log*))
(host-tap! "c")
(draw-game! *st*)
(tk-assert "a swap paints the held piece's shape"
           (any (lambda (e)
                  (and (eq? (car e) 'rect)
                       (< (list-ref e 3) 20)
                       (< (list-ref e 1) 190)))
                *host-log*))

;; The batched board list is (x y w h r g b) per settled cell. The builder
;; pushed x before y, so the final reverse handed the host (y x …): every
;; settled cell painted at (row, column) instead of (column, row). A
;; horizontal I read as a vertical one — the whole board turned ninety
;; degrees. Pin one bottom-left cell's exact pixel, on both duel origins.
(let* ((b (board-place (make-board) 'i '((0 . 19))))
       (g (game-with (fresh-game seed: 1) board: b active: #f))
       (cell (lay cell:))
       (x (lay board-x:))
       (y (+ (lay board-y:) (* 19 cell)))
       (flat (build-board-rects! g x))
       (rgb (piece-color 'i)))
  (tk-check "a settled cell paints at its own column and row"
            (list (list-ref flat 0) (list-ref flat 1))
            (list x y))
  (tk-check "the batch entry keeps the (x y w h r g b) order"
            (list (list-ref flat 2) (list-ref flat 3)
                  (list-ref flat 4) (list-ref flat 5) (list-ref flat 6))
            (list (- cell 1) (- cell 1)
                  (car rgb) (cadr rgb) (caddr rgb)))
  (tk-check "the duel's settled cell keeps the right well's origin"
            (list (list-ref (build-board-rects! g (lay duel-board-x:)) 0)
                  (list-ref (build-board-rects! g (lay duel-board-x:)) 1))
            (list (lay duel-board-x:) y)))

;; --------------------------------------------------------------------- ;;
;;  an idle piece still falls                                             ;;
;; --------------------------------------------------------------------- ;;

;; The regression: gravity journals nothing — a blip per tick would be a
;; machine gun — and the paint gate once read only the journal. So with no
;; keys pressed the piece froze on screen while the world advanced under
;; it, and the next keypress made it jump to where it had long belonged.
(tk-section "idle fall")

(boot-fresh!)
(start-match! 'marathon '() 'free #f #f #f)
(draw-game! *st*)
(host-clock! 16 4)
(host-run-frames! 4)      ; burn the start's dirty flag: a quiet board now
(let ((y-before (falling-y (game-active *st*)))
      (frames-before (host-frame-count)))
  (host-clock! 16 70)                  ; ~1.1s idle: level 1 drops at 900ms
  (host-run-frames! 70)
  (tk-assert "idle gravity moved the piece"
             (> (falling-y (game-active *st*)) y-before))
  (tk-assert "the idle fall repainted the screen"
             (> (host-frame-count) frames-before)))

;; --------------------------------------------------------------------- ;;
;;  the combo pop — the run announces itself                                ;;
;; --------------------------------------------------------------------- ;;

;; Tetris-battle drama: a run of clears pops a big announcement over the
;; well and raises the speaker's pitch per link. Two crafted singles, then
;; two frames: the first drains the journal (the facts arm the popup and
;; the tier beep), the second paints what they armed.
(tk-section "combo pop")

(boot-fresh!)
(start-match! 'marathon '() 'free #f #f #f)
(set! *ai* #f)
(define (result-unwrap-or r default)
  (if (result-ok? r) (ok-value r) default))
(let craft ((i 0))
  (if (< i 2)
      (begin
        (let* ((b (let loop ((bd (make-board)) (ys '(19)))
                    (if (null? ys)
                        bd
                        (loop (board-place bd 'i
                                           (map (lambda (x) (cons x (car ys)))
                                                (filter (lambda (x) (not (= x 2)))
                                                        (iota matrix-width))))
                              (cdr ys))))))
          (set! *st* (game-with *st* board: b active: (make-falling 'i 3 0 1))))
        (let drive ((j 0))
          (let* ((p (game-active *st*))
                 (done (and (= (falling-x p) 0) (= (falling-rot p) 1))))
            (cond (done
                   (set! *st* (result-unwrap-or (apply-command *st* (hard-drop)) *st*)))
                  ((> j 8) (error "could not steer the crafted piece"))
                  (else
                   (if (not (= (falling-rot p) 1))
                       (set! *st* (result-unwrap-or (apply-command *st* (rotate-cw)) *st*))
                       (set! *st* (result-unwrap-or (apply-command *st* (left)) *st*)))
                   (drive (+ j 1))))))
        (craft (+ i 1)))
      #f))
(host-clock! 16 2)
(host-run-frames! 2)
(tk-assert "the combo popup announced the run"
           (any (lambda (s) (string-contains? s "x2 COMBO")) (host-text-strings)))
(tk-assert "the popup painted big, not HUD-small"
           (any (lambda (e)
                  (and (eq? (car e) 'text)
                       (string-contains? (list-ref (cdr e) 2) "x2 COMBO")
                       (> (list-ref (cdr e) 3) 24)))
                *host-log*))
(tk-assert "the run raised the speaker's pitch"
           (member "combo-2" (host-sfx-names)))
(boot-fresh!)

;; --------------------------------------------------------------------- ;;
;;  the b2b pop and the new-best badge                                      ;;
;; --------------------------------------------------------------------- ;;

(tk-section "b2b pop and new best")

;; Craft `ys` rows, each holed in column two, and drop a vertical I into
;; the hole — the deterministic way to clear exactly those rows.
(define (craft-rows! ys)
  (let* ((b (let loop ((bd (make-board)) (cur ys))
              (if (null? cur)
                  bd
                  (loop (board-place bd 'i
                                     (map (lambda (x) (cons x (car cur)))
                                          (filter (lambda (x) (not (= x 2)))
                                                  (iota matrix-width))))
                        (cdr cur))))))
    (set! *st* (game-with *st* board: b active: (make-falling 'i 3 0 1))))
  (let drive ((j 0))
    (let* ((p (game-active *st*))
           (done (and (= (falling-x p) 0) (= (falling-rot p) 1))))
      (cond (done
             (set! *st* (result-unwrap-or (apply-command *st* (hard-drop)) *st*)))
            ((> j 8) (error "could not steer the crafted piece"))
            (else
             (if (not (= (falling-rot p) 1))
                 (set! *st* (result-unwrap-or (apply-command *st* (rotate-cw)) *st*))
                 (set! *st* (result-unwrap-or (apply-command *st* (left)) *st*)))
             (drive (+ j 1)))))))

;; A tetris opens the b2b chain: the popup pops in the chain's own color
;; and the speaker answers in kind.
(boot-fresh!)
(start-match! 'marathon '() 'free #f #f #f)
(set! *ai* #f)
(craft-rows! '(16 17 18 19))
(host-clock! 16 2)
(host-run-frames! 2)
(tk-assert "the chain's opening popped"
           (any (lambda (s) (string-contains? s "BACK-TO-BACK"))
                (host-text-strings)))
(tk-assert "the chain's opening beeped"
           (member "b2b" (host-sfx-names)))

;; A free-play match that beats the session's best wears the badge on its
;; result screen and plays the little fanfare.
(boot-fresh!)
(start-match! 'sprint '((target-lines 1)) 'free #f #f #f)
(set! *ai* #f)
(craft-rows! '(19))
(host-clock! 16 2)
(host-run-frames! 2)
(tk-assert "the new best wears its badge"
           (any (lambda (s) (string-contains? s "NEW BEST"))
                (host-text-strings)))
(tk-assert "the new best played its fanfare"
           (member "record" (host-sfx-names)))
(boot-fresh!)

;; --------------------------------------------------------------------- ;;
;;  pausing paints the veil — the bug this suite exists to keep dead         ;;
;; --------------------------------------------------------------------- ;;

(tk-section "pause veil")

(boot-fresh!)
(start-match! 'marathon '() 'free #f #f #f)
(host-clock! 16 4)
(host-run-frames! 4)                 ; a few live frames first
(let ((before (host-frame-count)))
  (host-type! "p")
  (tk-check "P pauses" (phase) 'paused)
  (tk-check "pausing repainted the frame" (> (host-frame-count) before) #t))
(tk-assert "the pause veil says PAUSED"
           (any (lambda (s) (string-contains? s "PAUSED")) (host-text-strings)))
(tk-assert "the pause veil offers the way out"
           (any (lambda (s) (string-contains? s "P to resume")) (host-text-strings)))
(tk-assert "the paused frame's painter calls fit"
           (every host-fits-window? *host-log*))

(host-type! "p")
(tk-check "P resumes" (phase) 'playing)
(host-type! "escape")
(tk-check "escape pauses too" (phase) 'paused)
(host-type! "escape")
(tk-check "escape again leaves for the title" (screen) 'title)

;; --------------------------------------------------------------------- ;;
;;  the duel paints two wells, and its veil covers the whole wide window     ;;
;; --------------------------------------------------------------------- ;;

(tk-section "duel layout")

(boot-fresh!)
(start-duel! (persona-by-id 'wall))
(tk-check "the duel re-opened the wide window" *host-window*
          (list duel-window-width window-height))
(set! *host-log* '())
(draw-duel! *duel* *persona*)
(tk-check "both wells show a next queue"
          (length (filter (lambda (s) (string=? s "NEXT"))
                          (host-text-strings)))
          2)
;; The keys panel is the solo table's first eight rows; in the duel the
;; AI toggle is inert, so advertising it would lie. The fight gets its own
;; row list (steering + pause), never the solo toggles.
(tk-assert "the duel's hint does not advertise the solo AI toggle"
           (not (any (lambda (s) (string-contains? s "AI"))
                     (host-text-strings))))
;; The duel is the tightest layout: the player's hint column ends where
;; the opponent's well begins. Mongolian's longer labels must shrink into
;; that column, never paint across the right board — the same fitting law
;; the solo HUD obeys, with half the horizontal room.
(set-locale! 'mn)
(set! *host-log* '())
(draw-duel! *duel* *persona*)
(tk-assert "the mongolian duel's painter calls fit"
           (every host-fits-window? *host-log*))
(tk-assert "the duel hint stays out of the opponent's well"
           (every (lambda (t)
                    (let ((x (list-ref t 0)) (y (list-ref t 1))
                          (s (list-ref t 2)) (size (list-ref t 3)))
                      (or (< y 330)
                          (< x (+ (lay right-x:) 8))
                          (<= (+ x (text-width s size))
                              (lay duel-board-x:)))))
                  (host-texts)))
(set-locale! 'en)
(tk-assert "the duel's painter calls fit its wide window"
           (every host-fits-window? *host-log*))
;; The pause veil is the full window's, not the solo 640's — the opponent's
;; half used to stay undimmed and the text centred over the left well. The
;; key path is part of the test: a separate `*duel-paused*` flag that never
;; touched the match's phase left the "PAUSED" arm dead.
(host-tap! "p")
(tk-assert "P pauses the duel" *duel-paused*)
(set! *host-log* '())
(set! *dirty* #t)
(host-run-frames! 1)
(tk-assert "the paused veil covers the whole duel window"
           (any (lambda (e)
                  (and (eq? (car e) 'rect)
                       (= (list-ref e 1) 0) (= (list-ref e 2) 0)
                       (= (list-ref e 3) duel-window-width)
                       (= (list-ref e 4) window-height)))
                *host-log*))
(close-duel!)
(tk-check "leaving the duel restores the window" *host-window*
          (list window-width window-height))

;; --------------------------------------------------------------------- ;;
;;  the whole round trip, drawn                                              ;;
;; --------------------------------------------------------------------- ;;

(tk-section "round trip")

(boot-fresh!)
;; title -> ladder -> play -> pause -> title -> mode -> level -> play
(host-type! "return")
(host-type! "return")
(tk-check "the ladder started a match" (screen) 'play)
(host-type! "escape")
(host-type! "escape")
(tk-check "two escapes land on the title" (screen) 'title)
(host-type! "down")                   ; the ladder, Versus, then Free play
(host-type! "down")
(host-type! "return")
(tk-check "free play opens the mode list" (screen) 'mode)
(tk-assert "the mode list names the ways to play"
           (every (lambda (name)
                    (any (lambda (s) (string-contains? s name))
                         (host-text-strings)))
                  (map symbol->string (mode-names))))
(host-type! "return")
(tk-check "a mode opens the level picker" (screen) 'level)
(host-type! "return")
(tk-check "a level starts the match" (screen) 'play)
(tk-check "the match is live" (phase) 'playing)

(tk-report! "ui")

