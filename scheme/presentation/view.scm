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
;;; Public names: window-width, window-height, draw-game!, view-reset!.

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
    ;; pulse, the clock the danger pulse breathes on — and the danger
    ;; repaint gate: the pulse is a slow sine, so the frames it costs are
    ;; spent at ~15 fps, not once per frame of the match.
    (define *score-shown* 0)
    (define *beam-rows* '())
    (define *beam-ms* 0)
    (define *hold-pulse-ms* 0)
    (define *fx-t* 0.0)
    (define *danger-paint-ms* 0)

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

    ;; A new screen is a clean slate: effects belong to the match that
    ;; earned them. Without this reset, a clear's beam outlived its match
    ;; and painted itself over the next board, and a flash burned through
    ;; the menu that came after. Called when a match starts and when the
    ;; shell shows a menu screen.
    (define (view-reset!)
      (set! *shake-px* 0.0)
      (set! *flash-rgb* #f)
      (set! *flash-ms* 0)
      (set! *score-shown* 0)
      (set! *beam-rows* '())
      (set! *beam-ms* 0)
      (set! *hold-pulse-ms* 0)
      (set! *danger-paint-ms* 0))

    ;; Mix two rgb lists: t=0 answers a, t=1 answers b, between — a blend.
    (define (mix-rgb a b t)
      (srfi-1:map (lambda (x y)
                    (exact (round (+ (* x (- 1 t)) (* y t)))))
                  a b))

    ;; The stack's top row — matrix-height (an empty well) is the ceiling.
    ;; A direct scan with an early exit, not a flatten-and-fold: this runs
    ;; every frame inside `view-busy?`, and building a full board's cell
    ;; list to learn what the first row already knew cost ~12ms a call.
    (define (stack-top st)
      (let ((b (game-board st)))
        (let loop-y ((y 0))
          (if (>= y matrix-height)
              matrix-height
              (let loop-x ((x 0))
                (cond ((>= x matrix-width) (loop-y (+ y 1)))
                      ((board-ref b x y) y)
                      (else (loop-x (+ x 1)))))))))

    ;; Danger: a live piece with the stack four rows from the ceiling. Purely
    ;; presentational — the rules never read it.
    (define (danger-tint? st)
      (and (game-active st) (<= (stack-top st) 3)))

    ;; True while the rail still owes frames: a flash burning, a beam or
    ;; pulse decaying, the ticker short of the real score, or a danger
    ;; pulse whose paint gate has expired. The conductor repaints while
    ;; this answers true, so an animation finishes even though "nothing
    ;; happened" in the match. The danger arm is gated: a full repaint
    ;; every frame just to breathe a border cost more than the match
    ;; itself on a full board — the gate buys it back at ~15 fps, and
    ;; `draw-playing-field!` re-arms the gate when it paints.
    (define (view-busy? st)
      (or (> *flash-ms* 0)
          (> *beam-ms* 0)
          (> *hold-pulse-ms* 0)
          (not (= *score-shown* (game-score st)))
          (and (danger-tint? st) (<= *danger-paint-ms* 0))))

    (define (view-fx-step! dt st)
      (set! *fx-t* (+ *fx-t* (/ dt 1000.0)))
      (set! *shake-px* (max 0.0 (* *shake-px* 0.85)))
      (set! *danger-paint-ms* (max 0 (- *danger-paint-ms* dt)))
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

    ;; Grid coordinate -> pixel coordinate: scale by the cell size, then
    ;; add the board origin — and the shake, so a thud moves the whole
    ;; well, not a rectangle here and there. Plain arithmetic ON PURPOSE:
    ;; these run once per settled cell per repaint, and a `chain` step
    ;; costs its macro expansion on every call — ~0.7ms against ~0.03ms
    ;; here. In an inner loop that is the difference between a frame and
    ;; a slideshow; `chain` keeps the one-shot pipelines (see centered-x).
    (define (px x) (+ (lay board-x:) (* x (lay cell:)) (shake-offset)))
    (define (py y) (+ (lay board-y:) (* y (lay cell:)) (shake-offset)))

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
      ;; The hot path: one call per settled cell per repaint. The layout
      ;; reads and the shake are hoisted out of the loop — the body is one
      ;; multiply, two adds, and the seam crossing.
      (let* ((cell (lay cell:))
             (s (- cell 1))
             (ox (+ (lay board-x:) (shake-offset)))
             (oy (+ (lay board-y:) (shake-offset))))
        (for-each
         (lambda (entry)
           (let ((pos (car entry)) (name (cdr entry)))
             (draw-rect! (+ ox (* (car pos) cell))
                         (+ oy (* (cdr pos) cell))
                         s s (piece-color name))))
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

    ;; ---------------------------------------------------------------- ;;
    ;;  Panel previews — real pieces, not spellings                      ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The HOLD and NEXT panels draw the piece itself: the same spawn cells
    ;; the board paints, at a smaller scale. The per-piece data is derived
    ;; once at load — the same discipline as geometry's `rotation-table`:
    ;; each piece's spawn cells normalized to a 0-anchored bounding box,
    ;; paired with the box width so centering is one quotient per repaint,
    ;; never a min/max scan per cell (§13.3: pay per epoch, not per frame).
    ;; A preview is at most 4 cells and there are four of them, so a
    ;; repaint pays ≤16 seam crossings here — a rounding error beside
    ;; `draw-board!`'s two hundred.
    (define preview-mini-hold 16)        ; the hold slot's cell size
    (define preview-mini-next 14)        ; the queue slots' cell size

    (define preview-shapes
      (map
       (lambda (name)
         (let* ((cells (piece-cells name 0))
                (min-x (let scan ((ls cells) (m 10))
                         (if (null? ls) m (scan (cdr ls) (min m (car (car ls)))))))
                (min-y (let scan ((ls cells) (m 10))
                         (if (null? ls) m (scan (cdr ls) (min m (cdr (car ls)))))))
                (max-x (let scan ((ls cells) (m 0))
                         (if (null? ls) m (scan (cdr ls) (max m (car (car ls)))))))
                (norm (map (lambda (c)
                             (cons (- (car c) min-x) (- (cdr c) min-y)))
                           cells)))
           (cons name (cons (+ (- max-x min-x) 1) norm))))
       piece-names))

    ;; One mini piece: its normalized spawn cells at `mini` px, centered on
    ;; the panel midline `cx`, top edge at `y`, in `rgb`. Plain arithmetic
    ;; and hoisted reads — the panels repaint on every repaint, and a
    ;; `chain` or a per-cell `lay` in this loop would be §13.2 all over
    ;; again (the board paid 289ms for exactly that once).
    (define (draw-preview! name cx y mini rgb)
      (let* ((entry (cdr (assq name preview-shapes)))
             (w (car entry))
             (cells (cdr entry))
             (s (- mini 1))
             (x (- cx (quotient (* w mini) 2))))
        (for-each (lambda (c)
                    (draw-rect! (+ x (* (car c) mini))
                                (+ y (* (cdr c) mini))
                                s s rgb))
                  cells)))

    (define (draw-hold! st)
      (draw-panel! (lay left-x:) "HOLD")
      ;; The held piece itself, in its own color, centered in the slot —
      ;; and a swap lights the *shape* up, then the pulse decays, so the
      ;; player's eye lands where the state changed.
      (let ((name (game-hold st)))
        (if name
            (draw-preview! name
                           (+ (lay left-x:) (quotient (lay panel-w:) 2))
                           96
                           preview-mini-hold
                           (if (> *hold-pulse-ms* 0)
                               (mix-rgb (piece-color name)
                                        (color accent:)
                                        (min 1.0 (/ *hold-pulse-ms* 150)))
                               (piece-color name)))
            #f)))

    (define (draw-next! st)
      (draw-panel! (lay right-x:) "NEXT")
      ;; The queue as three real pieces, each centered on the panel's
      ;; midline — the same cells the board will spawn, in the colors it
      ;; will spawn them in. The midline read is hoisted; the loop body is
      ;; one table lookup, one quotient and four seam crossings.
      (let ((cx (+ (lay right-x:) (quotient (lay panel-w:) 2))))
        (let loop ((names (bag-peek (game-bag st) 3)) (i 0))
          (if (null? names)
              #f
              (begin
                (draw-preview! (car names)
                               cx
                               (+ 80 (* i 52))
                               preview-mini-next
                               (piece-color (car names)))
                (loop (cdr names) (+ i 1)))))))

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
      ;; Painting re-arms the repaint gate (see `view-busy?`): the pulse
      ;; is sampled at ~15 fps, and the frames between are free.
      (if (danger-tint? st)
          (begin
            (set! *danger-paint-ms* 66)
            (draw-frame! (- (lay board-x:) 2) (- (lay board-y:) 2)
                         (+ (* matrix-width (lay cell:)) 3)
                         (+ (* matrix-height (lay cell:)) 3)
                         (mix-rgb (color frame:) (color warn:)
                                  (* 0.5 (+ 1.0 (sin (* 8 *fx-t*)))))))
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
