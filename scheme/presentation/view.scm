;;; presentation/view.scm — the painter (an edge module, not a library).
;;;
;;; This module is deliberately NOT a define-library: it speaks to the host's
;;; painter primitives, and a library's closed scope — the same fence that
;;; keeps the pure domain airtight — would refuse it. The pure contexts under
;;; ``domain/`` and ``rules/`` are real R7RS libraries; the edge is the edge.
;;;
;;; This module knows the game's shape and the host's painter primitives, and
;;; nothing else about either: it reduces a game state to rectangles and
;;; text, one host call at a time. Layout lives here as an SRFI 88 keyword
;;; table — ``cell:``, ``board-x:`` … — because a layout is a named-options
;;; thing and keywords are this dialect's atoms.
;;;
;;; The conductor draws only when something happened (the dirty flag), so the
;;; cost of a quiet frame is a few comparisons, not two hundred rectangles.
;;;
;;; Public names: window-width, window-height, draw-game!.

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (srfi 26)
        (srfi 88)
        (tetris geometry) (tetris board) (tetris bag) (tetris modes) (tetris game)
        (tetris rules) (tetris commands))
  (begin
    ;; ---------------------------------------------------------------- ;;
    ;;  Layout and palette                                               ;;
    ;; ---------------------------------------------------------------- ;;

    (define layout
      (list (cons cell: 26)
            (cons board-x: 190)
            (cons board-y: 60)
            (cons left-x: 24)
            (cons right-x: 476)
            (cons panel-w: 140)))

    (define (lay k) (cdr (assq k layout)))

    (define window-width 640)
    (define window-height 640)

    (define colors
      (list (cons i: '(0 200 200))
            (cons o: '(210 200 40))
            (cons t: '(180 60 190))
            (cons s: '(60 200 60))
            (cons z: '(210 60 60))
            (cons j: '(60 90 220))
            (cons l: '(230 150 30))
            (cons g: '(120 120 132))
            (cons bg: '(16 16 22))
            (cons panel: '(32 32 44))
            (cons frame: '(110 110 135))
            (cons ghost: '(58 58 78))
            (cons text: '(232 232 232))
            (cons dim: '(150 150 165))
            (cons accent: '(90 220 200))
            (cons warn: '(240 120 90))))

    (define (color k) (cdr (assq k colors)))

    (define (piece-color name)
      (color (string->keyword (symbol->string name))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The effects rail — flash and shake, fed by the conductor           ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The conductor decides *what a fact is worth* (the award table is its
    ;; own); this module owns the decay and the paint. `view-fx-step!` runs
    ;; once a frame with the real dt, so a 60 fps run and a 144 fps run wear
    ;; a flash the same length.

    (define *shake-px* 0.0)
    (define *flash-rgb* #f)
    (define *flash-ms* 0)

    ;; The animation rail's own state: the score ticker's displayed value,
    ;; the line-clear beam (which rows, how long), the hold panel's swap
    ;; pulse, and the clock the danger pulse breathes on.
    (define *score-shown* 0)
    (define *beam-rows* '())
    (define *beam-ms* 0)
    (define *hold-pulse-ms* 0)
    (define *fx-t* 0.0)

    (define (view-shake! px)
      (set! *shake-px* (max *shake-px* px)))

    (define (view-flash! rgb ms)
      (set! *flash-rgb* rgb)
      (set! *flash-ms* (max *flash-ms* ms)))

    ;; The conductor awards a clear: the beam paints the cleared rows for as
    ;; long as the flash burns — one flash length per line, so a tetris's
    ;; bars outlast a single's.
    (define (view-clear-beam! rows)
      (set! *beam-rows* rows)
      (set! *beam-ms* (+ 120 (* 40 (length rows)))))

    (define (view-hold-pulse!)
      (set! *hold-pulse-ms* 150))

    ;; Mix two rgb lists: t=0 answers a, t=1 answers b, between — a blend.
    (define (mix-rgb a b t)
      (srfi-1:map (lambda (x y)
                    (exact (round (+ (* x (- 1 t)) (* y t)))))
                  a b))

    ;; The stack's top row — matrix-height (an empty well) is the ceiling.
    (define (stack-top st)
      (let loop ((cells (board-cells (game-board st))) (top matrix-height))
        (if (null? cells)
            top
            (loop (cdr cells)
                  (min top (cdr (car (car cells))))))))

    ;; Danger: a live piece with the stack four rows from the ceiling. Purely
    ;; presentational — the rules never read it.
    (define (danger-tint? st)
      (and (game-active st) (<= (stack-top st) 3)))

    ;; True while the rail still owes frames: a flash burning, a beam or
    ;; pulse decaying, the ticker short of the real score, or a danger pulse
    ;; breathing. The conductor repaints while this answers true, so an
    ;; animation finishes even though "nothing happened" in the match.
    (define (view-busy? st)
      (or (> *flash-ms* 0)
          (> *beam-ms* 0)
          (> *hold-pulse-ms* 0)
          (not (= *score-shown* (game-score st)))
          (danger-tint? st)))

    (define (view-fx-step! dt st)
      (set! *fx-t* (+ *fx-t* (/ dt 1000.0)))
      (set! *shake-px* (max 0.0 (* *shake-px* 0.85)))
      (if (and *flash-rgb* (> *flash-ms* 0))
          (set! *flash-ms* (max 0 (- *flash-ms* dt)))
          (set! *flash-rgb* #f))
      (if (> *beam-ms* 0)
          (set! *beam-ms* (max 0 (- *beam-ms* dt)))
          (set! *beam-rows* '()))
      (if (> *hold-pulse-ms* 0)
          (set! *hold-pulse-ms* (max 0 (- *hold-pulse-ms* dt)))
          #f)
      ;; The ticker chases the real score: an eighth of the gap per frame,
      ;; at least one, so a small gain still visibly rolls.
      (let ((target (game-score st)))
        (cond ((> *score-shown* target) (set! *score-shown* target))
              ((< *score-shown* target)
               (set! *score-shown*
                     (min target (+ *score-shown*
                                    (max 1 (quotient (- target *score-shown*) 8))))))
              (else #f))))

    (define (apply-fx!)
      (if (and *flash-rgb* (> *flash-ms* 0))
          (tint! *flash-rgb*)
          #f))

    (define (shake-offset) (exact (round *shake-px*)))

    ;; Grid coordinate -> pixel coordinate, as a pipeline: scale by the cell
    ;; size, then add the board origin — and the shake, so a thud moves the
    ;; whole well, not a rectangle here and there. SRFI 197 writes the data
    ;; flow in the order it runs.
    (define (px x) (chain x (* _ (lay cell:)) (+ (lay board-x:) _ (shake-offset))))
    (define (py y) (chain y (* _ (lay cell:)) (+ (lay board-y:) _ (shake-offset))))

    (define (cell-size) (- (lay cell:) 1))

    ;; Center a string of `size` in a span starting at `left`: half the
    ;; slack, then offset. (The chain placeholder substitutes at a step's
    ;; top level, so the slack is computed first.)
    (define (centered-x left width s size)
      (chain (quotient (- width (text-width s size)) 2)
             (+ left _)))

    ;; ---------------------------------------------------------------- ;;
    ;;  The pieces of the picture                                        ;;
    ;; ---------------------------------------------------------------- ;;

    (define (draw-cells! cells rgb)
      (let ((s (cell-size)))
        (for-each (lambda (p) (draw-rect! (px (car p)) (py (cdr p)) s s rgb))
                  cells)))

    (define (draw-board! st)
      (let ((s (cell-size)))
        (for-each
         (lambda (entry)
           (let ((pos (car entry)) (name (cdr entry)))
             (draw-rect! (px (car pos)) (py (cdr pos)) s s
                         (piece-color name))))
         (board-cells (game-board st)))))

    (define (draw-well!)
      (draw-frame! (- (lay board-x:) 2)
                   (- (lay board-y:) 2)
                   (+ (* matrix-width (lay cell:)) 3)
                   (+ (* matrix-height (lay cell:)) 3)
                   (color frame:)))

    (define (draw-ghost! st)
      (let ((cells (ghost-cells st)))
        (if (null? cells)
            #f
            (draw-cells! cells (color ghost:)))))

    ;; A side panel: a dim slab and a label — the one shape the hold slot and
    ;; the queue share.
    (define (draw-panel! left label)
      (draw-rect! left 40 (lay panel-w:) 200 (color panel:))
      (draw-text! (+ left 8) 48 label 20 (color dim:)))

    (define (draw-hold! st)
      (draw-panel! (lay left-x:) "HOLD")
      ;; A swap lights the panel's label up, then the pulse decays — the
      ;; player's eye lands where the state changed.
      (let ((t (min 1.0 (/ *hold-pulse-ms* 150))))
        (if (game-hold st)
            (draw-text! (+ (lay left-x:) 8) 76
                        (symbol->string (game-hold st)) 26
                        (mix-rgb (piece-color (game-hold st))
                                 (color accent:) t))
            (draw-text! (+ (lay left-x:) 8) 76 "-" 26 (color dim:)))))

    (define (draw-next! st)
      (draw-panel! (lay right-x:) "NEXT")
      (let loop ((names (bag-peek (game-bag st) 3)) (i 0))
        (if (null? names)
            #f
            (begin
              (draw-text! (+ (lay right-x:) 8) (+ 76 (* i 34))
                          (symbol->string (car names)) 26
                          (piece-color (car names)))
              (loop (cdr names) (+ i 1))))))

    (define (draw-stats! st)
      (let ((x (lay left-x:))
            (cfg (game-config st)))
        (draw-text! x 268 (mode-label cfg) 18 (color accent:))
        (draw-text! x 300 "SCORE" 18 (color dim:))
        ;; The ticker's value, not the record's — a big clear rolls up
        ;; instead of snapping, and the busy flag keeps frames coming
        ;; until it lands.
        (draw-text! x 324 (number->string *score-shown*) 28 (color text:))
        (draw-text! x 372 "LINES" 18 (color dim:))
        (draw-text! x 396 (number->string (game-lines st)) 28 (color text:))
        (draw-text! x 444 "LEVEL" 18 (color dim:))
        (draw-text! x 468 (number->string (game-level st)) 28 (color text:))
        ;; The mode's own gauge: each way to play shows the number it is
        ;; played against — the ultra's countdown, the sprint's target, the
        ;; cheese's remaining dig.
        (variant-match (config-mode cfg)
          ((ultra)
           (draw-text! x 530
                       (string-append "TIME "
                                      (number->string
                                       (time-remaining (game-clock st) cfg)))
                       22 (color warn:)))
          ((sprint)
           (draw-text! x 530
                       (string-append "TARGET "
                                      (number->string (game-lines st))
                                      "/"
                                      (number->string (config-target-lines cfg)))
                       22 (color accent:)))
          ((cheese)
           (draw-text! x 530
                       (string-append "GARBAGE "
                                      (number->string (garbage-count (game-board st))))
                       22 (color warn:)))
          (else #f))
        ;; The scoring chain, while it runs — under the NEXT panel.
        (let ((rx (+ (lay right-x:) 8)))
          (if (> (game-combo st) 0)
              (draw-text! rx 268
                          (string-append "COMBO x" (number->string (game-combo st)))
                          20 (color accent:))
              #f)
          (if (game-b2b st)
              (draw-text! rx 296 "BACK-TO-BACK" 18 (color warn:))
              #f))))

    (define (draw-hint! st)
      ;; The keys, as data — the first eight rows fit the panel; the well
      ;; covers the rest on the menus, where the overlays say it all.
      (let ((x (+ (lay right-x:) 8))
            (rows (take command->key 8)))
        (draw-text! x 330 "KEYS" 16 (color dim:))
        (let loop ((ls rows) (i 0))
          (if (null? ls)
              #f
              (begin
                (draw-text! x (+ 356 (* i 24))
                            (string-append (car (car ls))
                                           " "
                                           (car (cdr (car ls))))
                            16
                            (color dim:))
                (loop (cdr ls) (+ i 1)))))))

    (define (draw-overlay! lines)
      ;; The veil covers the whole window and every line centres in the
      ;; FULL width — a hint line is wider than the well, and centring in
      ;; the well alone would push it into the panels. The line height is
      ;; the type size plus breathing room, so a tall title and a small
      ;; hint each take the space their own type asks for.
      (draw-rect! 0 0 window-width window-height '(10 10 16))
      (let ((total (let sum ((ls lines) (h 0))
                     (if (null? ls)
                         h
                         (sum (cdr ls)
                              (+ h (car (cdr (car ls))) 14)))))
            (width window-width))
        (let loop ((ls lines)
                   (y (max 24 (quotient (- window-height total) 2))))
          (if (null? ls)
              #f
              (let* ((spec (car ls))
                     (s (car spec))
                     (size (car (cdr spec)))
                     (x (centered-x 0 width s size)))
                (if (> (string-length s) 0)
                    (draw-text! x y s size (color text:))
                    #f)
                (loop (cdr ls) (+ y size 14)))))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The whole picture, per phase                                     ;;
    ;; ---------------------------------------------------------------- ;;

    ;; Ghost visibility is the player's toggle (G), owned here because it is
    ;; presentation. The conductor flips it; the painter reads it.
    (define *show-ghost* #t)

    (define (show-ghost! on) (set! *show-ghost* on))
    (define (show-ghost?) *show-ghost*)

    (define (draw-playing-field! st)
      (draw-well!)
      ;; Danger breathes on the frame: a stack four rows from the ceiling
      ;; pulses the well's border toward warn, faster as the end nears.
      (if (danger-tint? st)
          (draw-frame! (- (lay board-x:) 2) (- (lay board-y:) 2)
                       (+ (* matrix-width (lay cell:)) 3)
                       (+ (* matrix-height (lay cell:)) 3)
                       (mix-rgb (color frame:) (color warn:)
                                (* 0.5 (+ 1.0 (sin (* 8 *fx-t*))))))
          #f)
      (draw-board! st)
      ;; The clear beam: bright bars across the rows the last clear took —
      ;; they decay with the flash, so a tetris burns longer than a single.
      (if (and (> *beam-ms* 0) (not (null? *beam-rows*)))
          (let ((w (* matrix-width (lay cell:))))
            (for-each (lambda (r)
                        (draw-rect! (lay board-x:) (py r)
                                    (- w 1) (cell-size) '(235 245 255)))
                      *beam-rows*))
          #f)
      (if (game-active st)
          (begin
            (if *show-ghost* (draw-ghost! st) #f)
            (draw-cells! (active-cells st)
                         (piece-color (falling-name (game-active st)))))
          #f))

    (define (draw-game! st)
      (clear-screen! (color bg:))
      (draw-hold! st)
      (draw-next! st)
      (draw-stats! st)
      (draw-hint! st)
      (variant-match (game-phase st)
        ((title)
         (draw-well!)
         (draw-board! st)
         (draw-overlay!
          (list (list "SCHEME TETRIS" 34)
                (list "shs-python-scheme-dsl" 18)
                (list "" 12)
                (list "RETURN to start" 22))))
        ((paused)
         (draw-playing-field! st)
         (draw-overlay!
          (list (list "PAUSED" 34)
                (list "P to resume" 20)
                (list "R to restart" 20)
                (list "ESC to menu" 20))))
        ((won)
         (draw-playing-field! st)
         (draw-overlay!
          (list (list "LEVEL CLEAR!" 34)
                (list (string-append "score "
                                     (number->string (game-score st))) 22)
                (list "RETURN onward" 20)
                (list "R to replay" 20)
                (list "ESC to menu" 20))))
        ((over)
         (draw-playing-field! st)
         (draw-overlay!
          (list (list "GAME OVER" 34)
                (list (string-append "score "
                                     (number->string (game-score st))) 22)
                (list (string-append "lines "
                                     (number->string (game-lines st))) 22)
                (list "R to play again" 20)
                (list "ESC to menu" 20))))
        ((playing)
         (draw-playing-field! st)))
      (apply-fx!)
      (present!))
)
