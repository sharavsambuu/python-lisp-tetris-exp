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
          w-attack
          w-roof
          min-of
          roofline
          bumpiness
          well-depth
          wells-sum
          raise-copy
          raised-profile
          raised-heights
          new-holes
          completed-rows
          placement-score)

  (begin
    ;; Weights: (cleared holes bumpiness wells attack [roof]). `cleared` is
    ;; the height of the *lowest* column after the placement — keeping the
    ;; roofline low is what keeps the game alive; the next three are
    ;; penalties; `attack` prices the rows a placement completes *now* —
    ;; the style term that makes a Blitz out of the same forty placements.
    ;; `roof`, an optional sixth dial, penalizes the *tallest* column: the
    ;; term that says a mountain in any one lane is a death sentence no
    ;; matter how even the rest of the top is. A five-argument call stays
    ;; a five-dial list — the pinned persona shape — and reads roof 0.
    (define (weights cleared holes bumpiness wells attack . roof)
      (if (null? roof)
          (list cleared holes bumpiness wells attack)
          (list cleared holes bumpiness wells attack (car roof))))

    (define (w-cleared ws)   (list-ref ws 0))
    (define (w-holes ws)     (list-ref ws 1))
    (define (w-bumpiness ws) (list-ref ws 2))
    (define (w-wells ws)     (list-ref ws 3))
    (define (w-attack ws)    (list-ref ws 4))
    ;; Five-dial weight lists (old personas, test drivers) read 0.
    (define (w-roof ws)
      (if (> (length ws) 5) (list-ref ws 5) 0))

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

    ;; The raised profile in ONE allocation: copy once, raise each block's
    ;; column in place. `raised-heights` above answers the same vector but
    ;; pays a copy per cell — the planner calls this forty times a piece,
    ;; and the garbage the copies feed the collector is the difference
    ;; between a quiet frame and a hitch.
    (define (raised-profile heights cells x ly rows)
      (let ((out (vector-copy heights)))
        (let loop ((cs cells))
          (if (null? cs)
              out
              (let* ((c (car cs))
                     (col (+ x (car c)))
                     (h (- rows (+ ly (cdr c)))))
                (if (> h (vector-ref out col))
                    (vector-set! out col h))
                (loop (cdr cs)))))))

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

    ;; The rows this placement completes outright. A row is complete when
    ;; every column reaches it, so the count is exactly the rise of the
    ;; profile's minimum — before the clear collapses anything, which the
    ;; planner does not model. The duel's attack table prices these events
    ;; upstream; here they are counted, so a style can prefer them.
    (define (completed-rows heights raised)
      (- (min-of raised) (min-of heights)))

    ;; Higher is better. One allocation per call (the raised profile);
    ;; the roof term prices the tallest column when the weights carry a
    ;; sixth dial.
    (define (placement-score ws heights cells x ly rows)
      (let* ((raised (raised-profile heights cells x ly rows))
             (cleared (min-of raised))
             (holes (new-holes heights cells x ly rows))
             (attack (completed-rows heights raised)))
        ;; The shape of the judgment: rewards on one side, penalties on
        ;; the other. `attack` is the persona's appetite — a high weight
        ;; buys rows this piece, at the price the penalties name.
        (- (+ (* (w-cleared ws) cleared)
              (* (w-attack ws) attack))
           (+ (* (w-holes ws) holes)
              (* (w-bumpiness ws) (bumpiness raised))
              (* (w-wells ws) (wells-sum raised rows))
              (* (w-roof ws) (roofline raised)))))))
)
