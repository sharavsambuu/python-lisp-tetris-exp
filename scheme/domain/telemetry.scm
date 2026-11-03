;;; domain/telemetry.scm — (tetris telemetry)
;;;
;;; The match's vital signs, as pure probes: what a director (or any
;;; observer) can read off a game value without touching it. Every probe
;;; answers a number in a documented range, so a decision can be arithmetic
;;; on them — and the tests can pin the ranges.
;;;
;;; `pressure` is the one number the director regulates: a blend of the
;;; stack's mean and peak heights, normalized by the well's height. An
;;; empty board reads 0, a full board 1. The peak's minority share keeps
;;; one tall column visible in an otherwise flat stack — the shape that
;;; actually ends matches, and the thing an average alone would hide.

(define-library (tetris telemetry)
  (import (scheme base)
          (tetris geometry) (tetris board) (tetris game))
  (export stack-mean
          stack-peak
          stack-wells
          pressure
          in-band?)

  (begin
    (define (heights st) (column-heights (game-board st)))

    ;; The stack's mean height, in rows (0 .. matrix-height).
    (define (stack-mean st)
      (let* ((hs (heights st))
             (n (vector-length hs)))
        (let loop ((i 0) (sum 0))
          (if (= i n)
              (/ sum n)
              (loop (+ i 1) (+ sum (vector-ref hs i)))))))

    ;; The tallest column, in rows.
    (define (stack-peak st)
      (let ((hs (heights st)))
        (let loop ((i 1) (m (vector-ref hs 0)))
          (if (>= i (vector-length hs))
              m
              (loop (+ i 1) (max m (vector-ref hs i)))))))

    ;; Columns strictly lower than both neighbours — the gaps an average
    ;; cannot see. The edge columns read the frame as a full-height wall,
    ;; the same convention well-depth uses.
    (define (stack-wells st)
      (let* ((hs (heights st))
             (n (vector-length hs))
             (wall (+ matrix-height 1)))
        (let loop ((i 0) (w 0))
          (if (>= i n)
              w
              (let* ((h (vector-ref hs i))
                     (left (if (= i 0) wall (vector-ref hs (- i 1))))
                     (right (if (= i (- n 1)) wall (vector-ref hs (+ i 1)))))
                (loop (+ i 1)
                      (if (and (< h left) (< h right)) (+ w 1) w)))))))

    ;; The regulated number: 2/3 the mean, 1/3 the peak, over the well's
    ;; height. 0 = empty, 1 = full.
    (define (pressure st)
      (/ (+ (* 2 (stack-mean st)) (stack-peak st))
         (* 3 matrix-height)))

    ;; Is the pressure inside the band a director is holding?
    (define (in-band? st low high)
      (let ((p (pressure st)))
        (and (>= p low) (<= p high)))))
)
