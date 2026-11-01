;;; domain/geometry.scm — (tetris geometry)
;;;
;;; The purest context in the game: piece shapes, rotations, and nothing else.
;;; A piece is *data* — a name symbol from the closed seven — and every read
;;; this library exports is a total function from names and offsets to cells.
;;; There is no board here: collision is (tetris board)'s job, and this file
;;; must never need one.
;;;
;;; Shapes are the SRS spawn orientations, in a bounding box (4 wide for I, 3
;;; for everything else). The four rotations are *generated* — one fold per
;;; piece, rotating each cell CW in its box — so no rotation table can drift
;;; from the spawn shape it came from.

(define-library (tetris geometry)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (srfi 26)
          (srfi 88))
  (export matrix-width
          matrix-height
          piece-names
          piece-name?
          spawn-x
          spawn-y
          spawn-x-for
          piece-box
          piece-cells
          cells-at
          cells-shifted)

  (begin
    (define matrix-width 10)
    (define matrix-height 20)

    ;; The spawn column/row. x = 3 puts every piece's box just left of center,
    ;; which is where the guideline puts it; the O piece's 2-wide box sits one
    ;; column right of the others so its cells still land on 4 and 5.
    (define spawn-x 3)
    (define spawn-y 0)

    (define (spawn-x-for name) (if (eq? name 'o) 4 spawn-x))

    ;; The closed seven, in bag order.
    (define piece-names '(i o t s z j l))

    (define (piece-name? v)
      (and (symbol? v) (memq v piece-names) #t))

    ;; Spawn shapes: name -> (keyword . cells), cells as (x . y) in the box.
    ;; The keywords are SRFI 88 objects — self-evaluating, so the table reads
    ;; like a literal and assq finds entries without quoting.
    (define spawn-shapes
      (list (cons 'i: '((0 . 1) (1 . 1) (2 . 1) (3 . 1)))
            (cons 'o: '((0 . 0) (1 . 0) (0 . 1) (1 . 1)))
            (cons 't: '((1 . 0) (0 . 1) (1 . 1) (2 . 1)))
            (cons 's: '((1 . 0) (2 . 0) (0 . 1) (1 . 1)))
            (cons 'z: '((0 . 0) (1 . 0) (1 . 1) (2 . 1)))
            (cons 'j: '((0 . 0) (0 . 1) (1 . 1) (2 . 1)))
            (cons 'l: '((2 . 0) (0 . 1) (1 . 1) (2 . 1)))))

    (define (shape-of name)
      (let ((entry (assq (string->keyword (symbol->string name))
                         spawn-shapes)))
        (if entry (cdr entry) (error "geometry: unknown piece name" name))))

    ;; The bounding box each piece rotates in. O spins in a 3 box but all four
    ;; of its rotations are the same cells, which the generator produces
    ;; anyway.
    (define (piece-box name)
      (cond ((eq? name 'i) 4)
            ((eq? name 'o) 2)
            (else 3)))

    ;; One CW rotation in an n box: (x y) -> (n-1-y x). Our y grows downward,
    ;; so this is the screen-honest spelling of the SRS turn.
    (define (rotated-cell n cell)
      (cons (- (- n 1) (cdr cell)) (car cell)))

    (define (all-rotations name)
      (let ((n (piece-box name)))
        (let loop ((r 0) (cells (shape-of name)) (acc '()))
          (if (= r 4)
              (reverse acc)
              (loop (+ r 1)
                    (map (cut rotated-cell n <>) cells)
                    (cons cells acc))))))

    ;; name -> vector of 4 rotation cell-lists, computed once at load. The
    ;; alist keeps the names so the lookup is by piece, the vector index by
    ;; rotation.
    (define rotation-table
      (map (lambda (name)
             (cons name (list->vector (all-rotations name))))
           piece-names))

    ;; (piece-cells name rot) — the piece's cells in its box at one rotation.
    (define (piece-cells name rot)
      (vector-ref (cdr (assq name rotation-table)) (modulo rot 4)))

    ;; (cells-at name rot ox oy) — those cells dropped onto the matrix.
    (define (cells-at name rot ox oy)
      (map (lambda (c) (cons (+ ox (car c)) (+ oy (cdr c))))
           (piece-cells name rot)))

    ;; (cells-shifted cells dx dy) — a placement's cells moved by a delta.
    (define (cells-shifted cells dx dy)
      (map (lambda (c) (cons (+ dx (car c)) (+ dy (cdr c)))) cells))))
