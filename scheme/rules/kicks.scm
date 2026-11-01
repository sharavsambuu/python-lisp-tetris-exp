;;; rules/kicks.scm — (tetris kicks)
;;;
;;; SRS wall kicks: when a rotation does not fit, the rule set offers a short
;;; ordered list of nudges to try. The tables are the canonical SRS ones,
;;; transcribed once, with the y axis flipped to match the screen (our rows
;;; grow downward, the SRS paper's grow up).
;;;
;;; An O piece needs no nudges — its four rotations are the same cells — and
;;; the I piece owns its own, wider table. Anything else uses the JLSTZ table.

(define-library (tetris kicks)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each)))
  (export kicks-for)

  (begin
    ;; JLSTZ, y already flipped to screen coordinates (down is positive).
    (define jlstz-kicks
      (list (cons (cons 0 1)  '((0 . 0) (-1 . 0) (-1 . -1) (0 . 2) (-1 . 2)))
            (cons (cons 1 0)  '((0 . 0) (1 . 0) (1 . 1) (0 . -2) (1 . -2)))
            (cons (cons 1 2)  '((0 . 0) (1 . 0) (1 . 1) (0 . -2) (1 . -2)))
            (cons (cons 2 1)  '((0 . 0) (-1 . 0) (-1 . -1) (0 . 2) (-1 . 2)))
            (cons (cons 2 3)  '((0 . 0) (1 . 0) (1 . -1) (0 . 2) (1 . 2)))
            (cons (cons 3 2)  '((0 . 0) (-1 . 0) (-1 . 1) (0 . -2) (-1 . -2)))
            (cons (cons 3 0)  '((0 . 0) (-1 . 0) (-1 . 1) (0 . -2) (-1 . -2)))
            (cons (cons 0 3)  '((0 . 0) (1 . 0) (1 . -1) (0 . 2) (1 . 2)))))

    ;; I, same flip.
    (define i-kicks
      (list (cons (cons 0 1)  '((0 . 0) (-2 . 0) (1 . 0) (-2 . 1) (1 . -2)))
            (cons (cons 1 0)  '((0 . 0) (2 . 0) (-1 . 0) (2 . -1) (-1 . 2)))
            (cons (cons 1 2)  '((0 . 0) (-1 . 0) (2 . 0) (-1 . -2) (2 . 1)))
            (cons (cons 2 1)  '((0 . 0) (1 . 0) (-2 . 0) (1 . 2) (-2 . -1)))
            (cons (cons 2 3)  '((0 . 0) (2 . 0) (-1 . 0) (2 . -1) (-1 . 2)))
            (cons (cons 3 2)  '((0 . 0) (-2 . 0) (1 . 0) (-2 . 1) (1 . -2)))
            (cons (cons 3 0)  '((0 . 0) (1 . 0) (-2 . 0) (1 . 2) (-2 . -1)))
            (cons (cons 0 3)  '((0 . 0) (-1 . 0) (2 . 0) (-1 . -2) (2 . 1)))))

    ;; (kicks-for name from to) — the nudges to try, in order. An O piece
    ;; still "rotates", it just never leaves its cells; a rotation back onto
    ;; itself (from = to) needs no nudge at all.
    (define (kicks-for name from to)
      (cond ((eq? name 'o) '((0 . 0)))
            ((= from to) '((0 . 0)))
            ((eq? name 'i)
             (let ((entry (assoc (cons from to) i-kicks)))
               (if entry (cdr entry) '((0 . 0)))))
            (else
             (let ((entry (assoc (cons from to) jlstz-kicks)))
               (if entry (cdr entry) '((0 . 0))))))))
)
