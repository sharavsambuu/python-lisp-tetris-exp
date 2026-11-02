;;; domain/board.scm — (tetris board)
;;;
;;; The grid, and nothing but the grid. A board is an immutable value: a vector
;;; of rows, a row a vector of #f or a piece-name symbol. Nothing here mutates
;;; a board in place — "place" and "clear" answer a *new* board — because a
;;; whole session is a value you can hold, snapshot, and replay.
;;;
;;; Reads over the grid are folds (SRFI 1): full rows, column heights, the
;;; settled cells a painter wants. Collision knows the walls, the floor, and
;;; the *absence* of a ceiling: a cell above row 0 is free, which is what lets
;;; a piece spawn partly above the matrix.

(define-library (tetris board)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each)) (tetris geometry))
  (export make-board
          board?
          board-copy
          board-ref
          cell-free?
          cells-fit?
          board-place
          full-rows
          board-clear
          column-heights
          board-cells
          board-empty?)

  (begin
    (define (empty-row) (make-vector matrix-width #f))

    (define (make-board)
      ;; Distinct rows on purpose: `make-vector`'s fill would alias ONE
      ;; empty row across all twenty, and a future direct `vector-set!`
      ;; would write through every row at once. Writes still go through
      ;; `board-copy`, but the fresh value starts honest.
      (vector-map (lambda (_) (empty-row))
                  (make-vector matrix-height #f)))

    (define (board? v)
      (and (vector? v)
           (= (vector-length v) matrix-height)))

    ;; A new board sharing nothing: every row is copied too, so a placement
    ;; can never leak into a previous snapshot.
    (define (board-copy b)
      (vector-map (lambda (row) (vector-copy row)) b))

    (define (board-ref b x y)
      (vector-ref (vector-ref b y) x))

    ;; The one occupancy question every other read reduces to. Outside the
    ;; side walls or below the floor is *not* free; above the ceiling is.
    (define (cell-free? b x y)
      (cond ((or (< x 0) (>= x matrix-width)) #f)
            ((>= y matrix-height) #f)
            ((< y 0) #t)
            (else (not (board-ref b x y)))))

    (define (cells-fit? b cells)
      (every (lambda (c) (cell-free? b (car c) (cdr c))) cells))

    ;; The settled board with one piece merged in. Pure: rows are copied, the
    ;; input board is untouched.
    (define (board-place b name cells)
      (let ((fresh (board-copy b)))
        (for-each
         (lambda (c)
           (let ((x (car c)) (y (cdr c)))
             ;; Only settled rows take ink; above the ceiling and below the
             ;; floor there is nothing to write on.
             (if (and (>= y 0) (< y matrix-height))
                 (vector-set! (vector-ref fresh y) x name)
                 #f)))
         cells)
        fresh))

    ;; The indices of the full rows, oldest first — a fold that carries both
    ;; the index and the answer.
    (define (full-rows b)
      (reverse
       (cdr
        (fold (lambda (row acc)
                (let ((i (car acc)) (full (cdr acc)))
                  (if (every (lambda (cell) (not (eq? cell #f)))
                             (vector->list row))
                      (cons (+ i 1) (cons i full))
                      (cons (+ i 1) full))))
              (cons 0 '())
              (vector->list b)))))

    ;; The board with every full row collapsed away and empty rows added on
    ;; top. Answers two values: the new board, and how many rows went.
    (define (board-clear b)
      (let* ((full (full-rows b))
             (n (length full))
             (keep
              (fold (lambda (row acc)
                      (if (every (lambda (cell) (not (eq? cell #f)))
                                 (vector->list row))
                          acc
                          (cons row acc)))
                    '()
                    (vector->list b)))
             (fresh (make-board)))
        (let loop ((rows keep) (i (- matrix-height 1)))
          (if (null? rows)
              #t
              (begin
                (vector-set! fresh i (car rows))
                (loop (cdr rows) (- i 1)))))
        (values fresh n)))

    ;; The settled height of each column — the shape a score sees.
    (define (column-heights b)
      (let ((heights (make-vector matrix-width 0)))
        (let loop-y ((y 0))
          (if (< y matrix-height)
              (begin
                (let loop-x ((x 0))
                  (if (< x matrix-width)
                      (begin
                        ;; The first settled cell seen from the top is the
                        ;; column's height; later (lower) ones leave it be.
                        (if (and (not (eq? (board-ref b x y) #f))
                                 (= (vector-ref heights x) 0))
                            (vector-set! heights x (- matrix-height y))
                            #f)
                        (loop-x (+ x 1)))))
                (loop-y (+ y 1)))))
        heights))

    ;; The settled cells as (x . y . name)... no — as ((x y) . name) pairs the
    ;; painter can destructure: the board flattened into data.
    (define (board-cells b)
      (let loop-y ((y 0) (acc '()))
        (if (>= y matrix-height)
            (reverse acc)
            (let loop-x ((x 0) (acc acc))
              (if (>= x matrix-width)
                  (loop-y (+ y 1) acc)
                  (loop-x (+ x 1)
                          (let ((cell (board-ref b x y)))
                            (if (eq? cell #f)
                                acc
                                (cons (cons (cons x y) cell) acc)))))))))

    (define (board-empty? b)
      (every (lambda (row)
               (every (lambda (cell) (eq? cell #f)) (vector->list row)))
             (vector->list b)))))
