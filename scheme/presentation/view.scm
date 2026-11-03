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
        (tetris duel) (tetris roster)
        (tetris rules) (tetris commands) (tetris locale))
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
            (cons panel-w: 140)
            ;; The duel's right well starts clear of the player's NEXT
            ;; panel (476 + 140 = 616): the frame's 2px lip begins at 622.
            (cons duel-board-x: 624)
            (cons duel-panel-x: 896)))

    ;; `lay` and `color` are assq walks over constant tables — and they
    ;; are called per cell, per shape, per text, on every repaint:
    ;; ~1.5k walks a duel frame, measured. One-entry memos: the hot
    ;; keys repeat within a frame (cell:, board-x:, text:), and a miss
    ;; is the walk the code always paid. The tables never change, so
    ;; the memos never go stale.
    (define *lay-memo* (cons #f #f))
    (define (lay k)
      (if (eq? (car *lay-memo*) k)
          (cdr *lay-memo*)
          (let ((v (cdr (assq k layout))))
            (set-car! *lay-memo* k)
            (set-cdr! *lay-memo* v)
            v)))

    (define *color-memo* (cons #f #f))
    (define (color k)
      (if (eq? (car *color-memo*) k)
          (cdr *color-memo*)
          (let ((v (cdr (assq k colors))))
            (set-car! *color-memo* k)
            (set-cdr! *color-memo* v)
            v)))

    ;; The piece's color is a string->keyword conversion plus the walk,
    ;; paid per settled cell on a board rebuild — the memo keeps the
    ;; last name, and piece names cluster (four cells of one piece).
    (define *piece-color-memo* (cons #f #f))
    (define (piece-color name)
      (if (eq? (car *piece-color-memo*) name)
          (cdr *piece-color-memo*)
          (let ((v (color (string->keyword (symbol->string name)))))
            (set-car! *piece-color-memo* name)
            (set-cdr! *piece-color-memo* v)
            v)))

    (define window-width 640)
    (define window-height 640)

    ;; The duel's window: two full-size wells and their panels do not fit
    ;; 640 — measured before this layout was committed (§ plan 5a): one
    ;; full board painted through `draw-rect!` crossings cost ~27ms, so
    ;; two boards needed the batch painter AND the wider window. The
    ;; conductor re-opens the window when a duel starts and when it ends;
    ;; solo play and the menus keep the original 640.
    (define duel-window-width 1088)

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

    ;; The mode's display name: the domain's label is the stable *key* (the
    ;; bests table is keyed by it), the locale map owns the spelling shown.
    (define (mode-title label)
      (tr-or (string->symbol (string-append "mode-" label)) label))

    ;; The keys panel translates by the English label it already has: the
    ;; table in commands.scm is a *rules* library and cannot know locales,
    ;; so the painter keys the translation off the label — "soft drop"
    ;; becomes the symbol `key-soft-drop`. Run once per repaint, not per
    ;; key: a two-fold over an eight-row list is noise, but it does not
    ;; belong in the inner loop either.
    (define (key-label-key label)
      (string->symbol
       (string-append
        "key-"
        (list->string
         (map (lambda (ch) (if (char=? ch #\space) #\- ch))
              (string->list label))))))

    ;; A locale's spellings differ in length, and the panels do not move —
    ;; so the TYPE scales, never the text: shrink the size until the
    ;; string fits its budget (floored at 10, so a pathological string
    ;; degrades to small type, not to nothing). `text-width` is one
    ;; cached-font measurement; the loop runs only while the string still
    ;; overflows, and only on frames that paint it.
    (define (fit-size s size max-w)
      (if (or (<= size 10) (<= (text-width s size) max-w))
          size
          (fit-size s (- size 1) max-w)))

    ;; `draw-text!` with a width budget: the type scales to fit, the
    ;; position and the string stay as asked.
    (define (draw-text-fit! x y s size rgb max-w)
      (draw-text! x y s (fit-size s size max-w) rgb))

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
    ;; The popup rail: a run or a chain announcing itself over the well —
    ;; which kind ('combo, with the run's depth in *combo-n*, or 'b2b) and
    ;; how long the pop still owes.
    (define *pop-ms* 0)
    (define *pop-kind* #f)
    (define *combo-n* 0)
    ;; The result screen's badge: this match beat the session's best.
    (define *new-best* #f)
    ;; The duel's per-side rails: the right board's clear beam, and the
    ;; garbage meters — how many rows just landed on each side, and how
    ;; long the warning still owes. The flash and the shake stay shared:
    ;; one window, one veil.
    (define *beam-r-rows* '())
    (define *beam-r-ms* 0)
    (define *garbage-l-ms* 0)
    (define *garbage-l-n* 0)
    (define *garbage-r-ms* 0)
    (define *garbage-r-n* 0)

    (define (view-shake! px)
      (set! *shake-px* (max *shake-px* px)))

    (define (view-flash! rgb ms)
      (set! *flash-rgb* rgb)
      (set! *flash-ms* (max *flash-ms* ms)))

    ;; The conductor awards a combo run: the popup pops in big, escalates
    ;; with the run's length, and fades — a five-link run shouts louder
    ;; and longer than a two. The b2b chain's opening gets the same stage,
    ;; in its own color; a rarer moment overwrites a commoner one.
    (define *combo-pop-ms* 900)
    (define (view-combo-pop! n)
      (set! *pop-kind* 'combo)
      (set! *combo-n* n)
      (set! *pop-ms* (+ *combo-pop-ms* (* 100 (min 4 (- n 1))))))
    (define (view-b2b-pop!)
      (set! *pop-kind* 'b2b)
      (set! *pop-ms* 1100))
    (define (view-new-best!)
      (set! *new-best* #t))

    ;; The conductor awards a clear: the beam paints the cleared rows for as
    ;; long as the flash burns — one flash length per line, so a tetris's
    ;; bars outlast a single's. The duel names the side: each board wears
    ;; its own beam.
    (define (view-clear-beam! side rows)
      (if (eq? side 'right)
          (begin (set! *beam-r-rows* rows)
                 (set! *beam-r-ms* (+ 120 (* 40 (length rows)))))
          (begin (set! *beam-rows* rows)
                 (set! *beam-ms* (+ 120 (* 40 (length rows)))))))

    ;; Incoming garbage, acknowledged: the meter under the receiving
    ;; side's well shows the count while it decays.
    (define (view-garbage! side n)
      (if (eq? side 'right)
          (begin (set! *garbage-r-n* n) (set! *garbage-r-ms* 900))
          (begin (set! *garbage-l-n* n) (set! *garbage-l-ms* 900))))

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
      (set! *beam-r-rows* '())
      (set! *beam-r-ms* 0)
      (set! *garbage-l-ms* 0)
      (set! *garbage-l-n* 0)
      (set! *garbage-r-ms* 0)
      (set! *garbage-r-n* 0)
      (set! *hold-pulse-ms* 0)
      (set! *pop-ms* 0)
      (set! *pop-kind* #f)
      (set! *new-best* #f)
      (set! *danger-paint-ms* 0)
      ;; The caches: keyed by board identity, but a menu between matches
      ;; must not answer a stale list against a reused layout.
      (set! *board-rects-cache* '())
      (set! *stack-top-cache* '())
      (set! *heights-cache* '()))

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
    ;; The first occupied row, cached against the board's identity for
    ;; the same reason the rect list is: `stack-top` walks cells, and
    ;; `view-busy?` asks it every frame. A miss is a board change; a
    ;; hit is a list walk of four entries.
    (define *stack-top-cache* '())

    (define (cached-stack-top st)
      (let ((b (game-board st)))
        (let hit ((entries *stack-top-cache*))
          (cond ((null? entries)
                 (let ((top (stack-top st)))
                   (set! *stack-top-cache*
                         (cons (cons b top)
                               (if (> (length *stack-top-cache*) 4)
                                   (cdr *stack-top-cache*)
                                   *stack-top-cache*)))
                   top))
                ((eq? (car (car entries)) b) (cdr (car entries)))
                (else (hit (cdr entries)))))))

    (define (danger-tint? st)
      (and (game-active st) (<= (cached-stack-top st) 3)))

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
          (> *beam-r-ms* 0)
          (> *garbage-l-ms* 0)
          (> *garbage-r-ms* 0)
          (> *hold-pulse-ms* 0)
          (> *pop-ms* 0)
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
      (if (> *beam-r-ms* 0)
          (set! *beam-r-ms* (max 0 (- *beam-r-ms* dt)))
          (set! *beam-r-rows* '()))
      (if (> *garbage-l-ms* 0)
          (set! *garbage-l-ms* (max 0 (- *garbage-l-ms* dt)))
          #f)
      (if (> *garbage-r-ms* 0)
          (set! *garbage-r-ms* (max 0 (- *garbage-r-ms* dt)))
          #f)
      (if (> *hold-pulse-ms* 0)
          (set! *hold-pulse-ms* (max 0 (- *hold-pulse-ms* dt)))
          #f)
      (set! *pop-ms* (max 0 (- *pop-ms* dt)))
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

    (define (draw-cells-at! cells rgb ox)
      (let ((s (cell-size)))
        (for-each (lambda (p) (draw-rect! (+ ox (* (car p) (lay cell:)) (shake-offset))
                                          (py (cdr p)) s s rgb))
                  cells)))

    (define (draw-cells! cells rgb)
      (draw-cells-at! cells rgb (lay board-x:)))

    ;; The board, batched: one `draw-rects!` crossing for every settled
    ;; cell. Measured before the duel's layout was committed — 200 cells
    ;; as 200 `draw-rect!` crossings cost ~27ms (the crossing overhead,
    ;; not the paint); batched, ~2ms. The duel doubled the board count,
    ;; and a two-board worst case at the old rate was an 18fps frame.
    ;;
    ;; The batch bought the crossing; the *build* was the next tax: the
    ;; flat list is ~200 interpreted iterations per board per repaint,
    ;; and a duel repaints every frame. Boards are immutable values that
    ;; change only on a lock, a clear, or garbage — so the flat list is
    ;; cached against the board's identity (`eq?`, never `equal?`: a
    ;; deep compare would cost more than the rebuild), plus the origin
    ;; and the shake, which change the pixels without changing the
    ;; board. A hit is one host crossing; a miss is the rebuild, and
    ;; misses are the game's events, not the frames.
    ;;
    ;; The capacity has to hold BOTH duel origins at every shake offset
    ;; the decay can round to (0..6): 14 entries. It held five once, and
    ;; a duel during a slam thrashed — adding the left board's new offset
    ;; evicted the right board's, so every frame of the shake rebuilt
    ;; both full boards (~53ms measured). Capacity is the geometry of the
    ;; key, not a round number.
    (define *board-rects-cache-cap* 16)
    (define *board-rects-cache* '())

    (define (build-board-rects! st ox)
      (let* ((cell (lay cell:))
             (s (- cell 1))
             (oy (+ (lay board-y:) (shake-offset))))
        (let loop ((entries (board-cells (game-board st))) (acc '()))
          (if (null? entries)
              (reverse acc)
              (let* ((e (car entries))
                     (pos (car e))
                     (rgb (piece-color (cdr e)))
                     (x (+ ox (* (car pos) cell) (shake-offset)))
                     (y (+ oy (* (cdr pos) cell))))
                ;; Push each entry BACKWARDS — (b g r h w y x) — so the
                ;; final `reverse` restores both the cell order and the
                ;; field order to (x y w h r g b). Pushing x before y here
                ;; transposed every settled cell: a horizontal I painted as
                ;; a vertical one, the whole board rotated ninety degrees.
                (loop (cdr entries)
                      (cons (caddr rgb)
                            (cons (cadr rgb)
                                  (cons (car rgb)
                                        (cons s (cons s (cons y (cons x acc)))))))))))))

    (define (board-rects! st ox)
      (let ((b (game-board st)) (sh (shake-offset)))
        (let hit ((entries *board-rects-cache*))
          (cond ((null? entries)
                 (let ((flat (build-board-rects! st ox)))
                   (set! *board-rects-cache*
                         (cons (list b ox sh flat)
                               (if (>= (length *board-rects-cache*)
                                       *board-rects-cache-cap*)
                                   (cdr *board-rects-cache*)
                                   *board-rects-cache*)))
                   flat))
                ((and (eq? (car (car entries)) b)
                      (= (cadr (car entries)) ox)
                      (= (caddr (car entries)) sh))
                 (cadddr (car entries)))
                (else (hit (cdr entries)))))))

    (define (draw-board-at! st ox)
      (draw-rects! (board-rects! st ox)))

    (define (draw-board! st)
      (draw-board-at! st (lay board-x:)))

    (define (draw-well-at! ox)
      (draw-frame! (- ox 2)
                   (- (lay board-y:) 2)
                   (+ (* matrix-width (lay cell:)) 3)
                   (+ (* matrix-height (lay cell:)) 3)
                   (color frame:)))

    (define (draw-well!)
      (draw-well-at! (lay board-x:)))

    ;; The ghost, from cached column heights: the drop scan costs ~3 ms
    ;; of interpreted calls and runs every frame on every board — the
    ;; O(cells) form reads the landing row off the heights, and the
    ;; heights are cached against the board's identity (a miss is a
    ;; lock, a clear, or garbage; a hit is an eq? test).
    (define *heights-cache* '())

    (define (cached-heights st)
      (let ((b (game-board st)))
        (let hit ((entries *heights-cache*))
          (cond ((null? entries)
                 (let ((hts (column-heights b)))
                   (set! *heights-cache*
                         (cons (cons b hts)
                               (if (> (length *heights-cache*) 4)
                                   (cdr *heights-cache*)
                                   *heights-cache*)))
                   hts))
                ((eq? (car (car entries)) b) (cdr (car entries)))
                (else (hit (cdr entries)))))))

    (define (draw-ghost-at! st ox)
      (let ((cells (ghost-cells/hts st (cached-heights st))))
        (if (null? cells)
            #f
            (draw-cells-at! cells (color ghost:) ox))))

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
        (draw-text! x 268 (mode-title (mode-label cfg)) 18 (color accent:))
        (draw-text! x 300 (tr 'hud-score) 18 (color dim:))
        ;; The ticker's value, not the record's — a big clear rolls up
        ;; instead of snapping, and the busy flag keeps frames coming
        ;; until it lands.
        (draw-text! x 324 (number->string *score-shown*) 28 (color text:))
        (draw-text! x 372 (tr 'hud-lines) 18 (color dim:))
        (draw-text! x 396 (number->string (game-lines st)) 28 (color text:))
        (draw-text! x 444 (tr 'hud-level) 18 (color dim:))
        (draw-text! x 468 (number->string (game-level st)) 28 (color text:))
        ;; The mode's own gauge: each way to play shows the number it is
        ;; played against — the ultra's countdown, the sprint's target, the
        ;; cheese's remaining dig.
        (variant-match (config-mode cfg)
          ((ultra)
           (draw-text-fit! x 530
                           (tr-fmt 'hud-time
                                   (time-remaining (game-clock st) cfg))
                           22 (color warn:)
                           (- window-width x 8)))
          ((sprint)
           (draw-text-fit! x 530
                           (tr-fmt 'hud-target
                                   (game-lines st)
                                   (config-target-lines cfg))
                           22 (color accent:)
                           (- window-width x 8)))
          ((cheese)
           (draw-text-fit! x 530
                           (tr-fmt 'hud-garbage
                                   (garbage-count (game-board st)))
                           22 (color warn:)
                           (- window-width x 8)))
          (else #f))
        ;; The scoring chain, while it runs — under the NEXT panel.
        (let ((rx (+ (lay right-x:) 8)))
          (if (> (game-combo st) 0)
              (draw-text-fit! rx 268
                              (tr-fmt 'hud-combo (game-combo st))
                              20 (color accent:)
                              (- window-width rx 8))
              #f)
          (if (game-b2b st)
              (draw-text-fit! rx 296 (tr 'hud-b2b) 18 (color warn:)
                              (- window-width rx 8))
              #f))))

    ;; The duel's keys: the match controls the player actually owns there.
    ;; The solo-only rows (the AI and pacing-director toggles, restart) are
    ;; inert during a fight, so advertising them would lie — the same reason
    ;; the event filter drops them before they reach the left match.
    (define duel-command->key
      '(("left/right" "move")
        ("down" "soft drop")
        ("up / x" "rotate cw")
        ("z" "rotate ccw")
        ("space" "hard drop")
        ("shift / c" "hold")
        ("g" "ghost on/off")
        ("p" "pause")))

    (define (draw-hint! st . maybe-rows)
      ;; The keys, as data — the first eight rows fit the panel; the well
      ;; covers the rest on the menus, where the overlays say it all. The
      ;; labels translate at display time (key-label-key); the key column
      ;; stays the host's key names in every locale. The duel passes its
      ;; own row list (`duel-command->key`) so the panel never advertises a
      ;; control the fight ignores — and its own width: the player's panel
      ;; ends where the opponent's well begins, so a long Mongolian label
      ;; must shrink, not paint across the right board.
      (let ((x (+ (lay right-x:) 8))
            (duel-rows? (not (null? maybe-rows)))
            (rows (take (if (null? maybe-rows)
                            command->key
                            (car maybe-rows))
                        8)))
        (draw-text! x 330 (tr 'hud-keys) 16 (color dim:))
        (let loop ((ls rows) (i 0))
          (if (null? ls)
              #f
              (begin
                (draw-text-fit! x (+ 356 (* i 24))
                                (string-append (car (car ls))
                                               " "
                                               (tr-or (key-label-key
                                                       (car (cdr (car ls))))
                                                      (car (cdr (car ls)))))
                                16
                                (color dim:)
                                (if duel-rows?
                                    (- (lay duel-board-x:) x 8)
                                    (- window-width x 8)))
                (loop (cdr ls) (+ i 1)))))))

    (define (draw-overlay-sized! width height lines)
      ;; The veil covers the whole window and every line centres in the
      ;; FULL width — a hint line is wider than the well, and centring in
      ;; the well alone would push it into the panels. The line height is
      ;; the type size plus breathing room, so a tall title and a small
      ;; hint each take the space their own type asks for.
      (draw-rect! 0 0 width height '(10 10 16))
      (let ((total (let sum ((ls lines) (h 0))
                     (if (null? ls)
                         h
                         (sum (cdr ls)
                              (+ h (car (cdr (car ls))) 14)))))
            (w width))
        (let loop ((ls lines)
                   (y (max 24 (quotient (- height total) 2))))
          (if (null? ls)
              #f
              (let* ((spec (car ls))
                     (s (car spec))
                     (size (car (cdr spec)))
                     (x (centered-x 0 w s size)))
                (if (> (string-length s) 0)
                    (draw-text-fit! x y s size (color text:) (- w 16))
                    #f)
                (loop (cdr ls) (+ y size 14)))))))

    ;; The solo screens keep the 640px window's shape. The duel passes its
    ;; own width: the window is 1088 there, and a veil that stopped at 640
    ;; left the opponent's half undimmed and the text centred over the
    ;; player's well alone.
    (define (draw-overlay! lines)
      (draw-overlay-sized! window-width window-height lines))

    ;; ---------------------------------------------------------------- ;;
    ;;  The whole picture, per phase                                     ;;
    ;; ---------------------------------------------------------------- ;;

    ;; Ghost visibility is the player's toggle (G), owned here because it is
    ;; presentation. The conductor flips it; the painter reads it.
    (define *show-ghost* #t)

    (define (show-ghost! on) (set! *show-ghost* on))
    (define (show-ghost?) *show-ghost*)

    (define (draw-playing-field! st ox side)
      (draw-well-at! ox)
      ;; Danger breathes on the frame: a stack four rows from the ceiling
      ;; pulses the well's border toward warn, faster as the end nears.
      ;; Painting re-arms the repaint gate (see `view-busy?`): the pulse
      ;; is sampled at ~15 fps, and the frames between are free.
      (if (danger-tint? st)
          (begin
            (set! *danger-paint-ms* 66)
            (draw-frame! (- ox 2) (- (lay board-y:) 2)
                         (+ (* matrix-width (lay cell:)) 3)
                         (+ (* matrix-height (lay cell:)) 3)
                         (mix-rgb (color frame:) (color warn:)
                                  (* 0.5 (+ 1.0 (sin (* 8 *fx-t*)))))))
          #f)
      (draw-board-at! st ox)
      ;; The clear beam: bright bars across the rows the last clear took —
      ;; they decay with the flash, so a tetris burns longer than a single.
      ;; Each side wears its own beam.
      (let* ((beam-rows (if (eq? side 'right) *beam-r-rows* *beam-rows*))
             (beam-ms (if (eq? side 'right) *beam-r-ms* *beam-ms*)))
        (if (and (> beam-ms 0) (not (null? beam-rows)))
            (let ((w (* matrix-width (lay cell:))))
              (for-each (lambda (r)
                          (draw-rect! ox (py r)
                                      (- w 1) (cell-size) '(235 245 255)))
                        beam-rows))
            #f))
      (if (game-active st)
          (begin
            (if *show-ghost* (draw-ghost-at! st ox) #f)
            (draw-cells-at! (active-cells st)
                            (piece-color (falling-name (game-active st)))
                            ox))
          #f)
      ;; The garbage meter, under the well: what just landed on this side,
      ;; while the warning burns.
      (let* ((g-ms (if (eq? side 'right) *garbage-r-ms* *garbage-l-ms*))
             (g-n (if (eq? side 'right) *garbage-r-n* *garbage-l-n*)))
        (if (and (> g-ms 0) (> g-n 0))
            (draw-text-fit! ox
                            (+ (lay board-y:) (* matrix-height (lay cell:)) 12)
                            (tr-fmt 'hud-garbage g-n)
                            20 (color warn:)
                            (- duel-window-width ox 8))
            #f))
      ;; The popup, over everything — the PLAYER's runs only: one
      ;; headline per side, and the opponent's combos read through their
      ;; beam and the garbage they send, not through text over their
      ;; well. Pops in big during the first fifth of its life, then fades
      ;; toward the veil's dark. The combo's type escalates with the run
      ;; — a five-link combo shouts larger than a two — so the size
      ;; itself reads how deep the run is; the b2b chain wears its own
      ;; color at its own size.
      (if (and (eq? side 'left) (> *pop-ms* 0))
          (let* ((total (if (eq? *pop-kind* 'b2b)
                            1100
                            (+ *combo-pop-ms* (* 100 (min 4 (- *combo-n* 1))))))
                 (t (- 1.0 (/ *pop-ms* total)))
                 (pop (max 0.0 (- 1.0 (* t 5.0))))
                 (base (if (eq? *pop-kind* 'b2b)
                           24
                           (+ 20 (* 6 (min 4 (- *combo-n* 1))))))
                 (size (min 44 (exact (round (* base (+ 1.0 (* 0.6 pop)))))))
                 (s (if (eq? *pop-kind* 'b2b)
                        (tr 'popup-b2b)
                        (tr-fmt 'popup-combo *combo-n*)))
                 (hot (if (eq? *pop-kind* 'b2b) (color warn:) (color accent:)))
                 (rgb (mix-rgb '(16 16 24) hot (max 0.0 (- 1.0 (* t t)))))
                 (x (centered-x (lay board-x:)
                                (* matrix-width (lay cell:))
                                s size)))
            (draw-text! x (+ (lay board-y:) (cell-size) 4) s size rgb))
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
                (list (tr 'overlay-return-start) 22))))
        ((paused)
         (draw-playing-field! st (lay board-x:) 'left)
         (draw-overlay!
          (list (list (tr 'overlay-paused) 34)
                (list (tr 'overlay-p-resume) 20)
                (list (tr 'overlay-r-restart) 20)
                (list (tr 'overlay-esc-menu) 20))))
        ((won)
         (draw-playing-field! st (lay board-x:) 'left)
         (draw-overlay!
          (append (list (list (tr 'overlay-level-clear) 34)
                        (list (tr-fmt 'overlay-score (game-score st)) 22))
                  (if *new-best*
                      (list (list (tr 'overlay-new-best) 20))
                      '())
                  (list (list (tr 'overlay-return-onward) 20)
                        (list (tr 'overlay-r-replay) 20)
                        (list (tr 'overlay-esc-menu) 20)))))
        ((over)
         (draw-playing-field! st (lay board-x:) 'left)
         (draw-overlay!
          (append (list (list (tr 'overlay-game-over) 34)
                        (list (tr-fmt 'overlay-score (game-score st)) 22)
                        (list (tr-fmt 'overlay-lines (game-lines st)) 22))
                  (if *new-best*
                      (list (list (tr 'overlay-new-best) 20))
                      '())
                  (list (list (tr 'overlay-r-again) 20)
                        (list (tr 'overlay-esc-menu) 20)))))
        ((playing)
         (draw-playing-field! st (lay board-x:) 'left)))
      (apply-fx!)
      (present!))

    ;; ---------------------------------------------------------------- ;;
    ;;  The duel — two wells, one fight, on one window                    ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The left board is the player's: hold, stats, keys, the popup — the
    ;; whole solo picture, at the solo origin. The right board is the
    ;; persona's: a next-only panel (the AI does not hold), a name plate
    ;; so the fight has a face, and the same field at the duel origin.
    ;; The rails are per side (beam, meter); the flash and the shake are
    ;; the window's — one veil, one thud.

    (define (draw-opponent! st persona)
      (let* ((ox (lay duel-board-x:))
             (px (lay duel-panel-x:)))
        (draw-panel! px "NEXT")
        (let ((cx (+ px (quotient (lay panel-w:) 2))))
          (let loop ((names (bag-peek (game-bag st) 3)) (i 0))
            (if (null? names)
                #f
                (begin
                  (draw-preview! (car names)
                                 cx
                                 (+ 80 (* i 52))
                                 preview-mini-next
                                 (piece-color (car names)))
                  (loop (cdr names) (+ i 1))))))
        ;; The name plate: who you are fighting, and their line count —
        ;; the one number a duel reads at a glance. The count lives in
        ;; the NEXT panel under the previews, not at the well's origin:
        ;; painted there it landed INSIDE the opponent's board and the
        ;; falling cells drew over it.
        (draw-text-fit! ox 26
                        (persona-name persona)
                        22 (color accent:)
                        (- duel-window-width ox 8))
        (draw-text-fit! px 212
                        (tr-fmt 'hud-lines (game-lines st))
                        18 (color dim:)
                        (- duel-window-width px 8))
        (draw-playing-field! st ox 'right)))

    (define (draw-duel! duel persona)
      (clear-screen! (color bg:))
      (let ((l (duel-left duel)))
        ;; The player's side is the whole solo picture: HOLD and NEXT both
        ;; tell them what the opponent's AI already knows.
        (draw-hold! l)
        (draw-next! l)
        (draw-stats! l)
        (draw-hint! l duel-command->key)
        (draw-playing-field! l (lay board-x:) 'left))
      (draw-opponent! (duel-right duel) persona)
      (variant-match (game-phase (duel-left duel))
        ((paused)
         (draw-overlay-sized!
          duel-window-width window-height
          (list (list (tr 'overlay-paused) 34)
                (list (tr 'overlay-p-resume) 20)
                (list (tr 'overlay-esc-forfeit) 20))))
        (else
         (if (duel-over? duel)
             (let* ((won (eq? (duel-winner duel) 'left))
                    (headline (if won
                                  (tr 'overlay-duel-won)
                                  (tr-fmt 'overlay-duel-lost
                                          (persona-name persona)))))
               (draw-overlay-sized!
                duel-window-width window-height
                (append (list (list headline 34)
                              (list (tr-fmt 'overlay-score
                                            (game-score (duel-left duel)))
                                    22)
                              (list (tr-fmt 'overlay-lines
                                            (game-lines (duel-left duel)))
                                    22))
                        (list (list (tr 'overlay-return-menu) 20)))))
             #f)))
      (apply-fx!)
      (present!))
)
