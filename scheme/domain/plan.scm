;;; domain/plan.scm — (tetris plan)
;;;
;;; Arithmetic on a ten-column height profile: the questions a placement
;;; evaluator asks about the shape a piece would leave. No game state, no
;;; hooks, no commands — the purest layer of the AI, and the file that lets
;;; the conductor's planner score forty placements a piece without ever
;;; rebuilding a board.
;;;
;;; `heights` is a *vector* — the stack height of each column (0 = empty,
;;; `rows` = full) — because the planner scores forty placements per piece
;;; and a raise of a list profile allocates a new ten-list per cell; on the
;;; vector the same raise is one `vector-copy` plus one `vector-set!`, both
;;; single interpreter steps. The shape's cells stay little `(dx . dy)`
;;; pairs — four of them — and the profile stays 0-based-indexed, with
;;; `rows` passed in rather than hard-coded.
;;;
;;; The term order is the reference implementation's, term for term: the
;;; same weights choose the same placement.

(define-library (tetris plan)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (tetris geometry))
  (export weights
          w-cleared
          w-holes
          w-bumpiness
          w-wells
          min-of
          roofline
          bumpiness
          well-depth
          wells-sum
          raise-copy
          raised-heights
          new-holes
          placement-score)

  (begin
    ;; Weights: (cleared holes bumpiness wells). `cleared` is the height of
    ;; the *lowest* column after the placement — keeping the roofline low is
    ;; what keeps the game alive; the other three are penalties. They are
    ;; data, so a caller can publish its own.
    (define (weights cleared holes bumpiness wells)
      (list cleared holes bumpiness wells))

    (define (w-cleared ws)   (list-ref ws 0))
    (define (w-holes ws)     (list-ref ws 1))
    (define (w-bumpiness ws) (list-ref ws 2))
    (define (w-wells ws)     (list-ref ws 3))

    ;; The smallest column height — the *cleared* height of a profile.
    (define (min-of v)
      (let loop ((i 1) (m (vector-ref v 0)))
        (if (>= i (vector-length v))
            m
            (loop (+ i 1) (min m (vector-ref v i))))))

    ;; The tallest column — how high the next piece has to climb.
    (define (roofline v)
      (let loop ((i 1) (m (vector-ref v 0)))
        (if (>= i (vector-length v))
            m
            (loop (+ i 1) (max m (vector-ref v i))))))

    ;; Total rise between neighbouring columns — a flat top clears rows.
    (define (bumpiness v)
      (let ((n (vector-length v)))
        (let loop ((i 1) (b 0))
          (if (>= i n)
              b
              (loop (+ i 1)
                    (+ b (abs (- (vector-ref v (- i 1)) (vector-ref v i)))))))))

    ;; A column lower than both neighbours is a well; its depth is what has
    ;; to be filled. This is the term that saves an AI: every placement adds
    ;; four cells, so the *sum* of heights is the same wherever the piece
    ;; lands — nothing in it rewards filling a low column. The well term
    ;; does, and without it one early gap becomes an unfillable tomb.
    (define (well-depth heights i rows)
      (let* ((n (vector-length heights))
             (h (vector-ref heights i))
             (left (if (= i 0) rows (vector-ref heights (- i 1))))
             (right (if (= i (- n 1)) rows (vector-ref heights (+ i 1)))))
        (if (and (< h left) (< h right))
            (- (min left right) h)
            0)))

    (define (wells-sum heights rows)
      (let ((n (vector-length heights)))
        (let loop ((i 0) (s 0))
          (if (>= i n)
              s
              (loop (+ i 1) (+ s (well-depth heights i rows)))))))

    ;; One copy of the profile with column `col` raised to at least `h`.
    (define (raise-copy hs col h)
      (let ((out (vector-copy hs)))
        (vector-set! out col (max (vector-ref out col) h))
        out))

    ;; Each block of the piece raises its own column. `cells` are `(dx . dy)`
    ;; pairs from the piece origin, with y increasing *downward*, so a
    ;; block's height in its column is `rows - y`.
    (define (raised-heights heights cells x ly rows)
      (let loop ((cs cells) (hs heights))
        (if (null? cs)
            hs
            (let* ((c (car cs))
                   (col (+ x (car c)))
                   (h (- rows (+ ly (cdr c)))))
              (loop (cdr cs) (raise-copy hs col h))))))

    ;; Holes this placement buries: in each column the piece touches, the
    ;; gap between the piece's lowest block and the top of the existing
    ;; stack. (Holes already in the stack cost the same for every placement,
    ;; so only the *new* ones matter.) The piece scans once into a
    ;; lowest-row-per-column vector.
    (define (new-holes heights cells x ly rows)
      (let ((n (vector-length heights))
            (low (make-vector (vector-length heights) -1)))
        (let fill ((cs cells))
          (if (null? cs)
              #f
              (let* ((c (car cs))
                     (col (+ x (car c)))
                     (r (+ ly (cdr c))))
                (vector-set! low col (max (vector-ref low col) r))
                (fill (cdr cs)))))
        (let loop ((i 0) (n2 0))
          (if (>= i n)
              n2
              (let ((rlo (vector-ref low i)))
                (if (< rlo 0)
                    (loop (+ i 1) n2)
                    (let ((top (- rows (vector-ref heights i))))
                      (loop (+ i 1) (+ n2 (max 0 (- top rlo 1)))))))))))

    ;; Higher is better.
    (define (placement-score ws heights cells x ly rows)
      (let* ((raised (raised-heights heights cells x ly rows))
             (cleared (min-of raised))
             (holes (new-holes heights cells x ly rows)))
        (- (* (w-cleared ws) cleared)
           (+ (* (w-holes ws) holes)
              (* (w-bumpiness ws) (bumpiness raised))
              (* (w-wells ws) (wells-sum raised rows)))))))
)
