;;; bench-view.scm — measure the painter's hot paths on a full board.
;;;
;;; A standalone harness (run it through the interpreter with the budget
;;; raised), and the fixture `test_painter_keeps_up_with_a_full_board`
;;; loads it: it boots a match and crafts a completely full board, so the
;;; painter's worst case is one run() away.
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
(load "fake-host")

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (tetris game)
        (tetris duel) (tetris roster)
        (tetris board)
        (tetris geometry))

(host-reset!)
(open-window! window-width window-height "bench")
(boot!)
(start-match! 'marathon '() 'free #f #f #f)

;; A synthetic full board: every cell of every row occupied.
(set! *st*
      (game-with *st*
                 board:
                 (let row-loop ((bd (make-board)) (ys (iota matrix-height)))
                   (if (null? ys)
                       bd
                       (row-loop
                        (let cell-loop ((b bd) (xs (iota matrix-width)))
                          (if (null? xs)
                              b
                              (cell-loop (board-place b 'i
                                                      (list (cons (car xs)
                                                                  (car ys))))
                                         (cdr xs))))
                        (cdr ys))))))

(display "settled cells: ")
(display (length (board-cells (game-board *st*))))
(newline)
(display "stack-top: ")
(display (stack-top *st*))
(newline)
(display "danger-tint?: ")
(display (danger-tint? *st*))
(newline)

;; The duel's worst frame: BOTH boards full. The bench harness holds the
;; same full board on both sides of one duel, so a timing loop can draw
;; the two-board picture — the number that decided the layout (§ plan 5a)
;; and the batch painter.
(set! *duel* (make-duel *st* *st*))
(set! *persona* (car roster))
(display "duel cells: ")
(display (* 2 (length (board-cells (game-board *st*)))))
(newline)
