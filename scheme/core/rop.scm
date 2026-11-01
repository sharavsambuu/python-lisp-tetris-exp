;;; core/rop.scm — (tetris result)
;;;
;;; The railway, as a library of our own. The DSL preloads its ROP prelude
;;; (``lisp/rope.scm``) into the interaction environment, but a ``define-library``
;;; is a closed scope: it sees only its imports. A domain that wants to speak
;;; in Results must therefore *import* the railway — so this context declares
;;; the same closed Result variant and re-exports the same vocabulary, spelled
;;; exactly as the prelude spells it (``lisp/rope.scm`` is the reference; the
;;; monad laws it pins are pinned here too by ``tests/test_scheme.py``).
;;;
;;; The one primitive is ``result-bind``: run the next arrow only on the
;;; success rail. Everything else — map, bimap, fold, the fish, the do-notation
;;; — is built on it, which is why there is exactly one place a short-circuit
;;; can live.

(define-library (tetris result)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each)))
  (export result?
          result-ok?
          result-err?
          ok
          err
          ok-value
          err-reason
          result-pure
          result-map
          result-map-err
          result-map2
          result-bind
          result-bimap
          result-fold
          result-unwrap
          result-unwrap-or
          result-unwrap-or-else
          result-expect
          result->list
          >=>
          pipe-results
          pipe-results-list
          sequence-results
          traverse-results
          ok-values
          err-reasons
          first-err
          count-errs
          attempt)

  (begin
    (define-variant result
      (ok value)
      (err reason))

    ;; The rails, asked one at a time. variant-match is the evaluator's own
    ;; dispatch, so it needs no import; the else arm keeps a non-Result value
    ;; from ever reading as a success.
    (define (result-ok? r)
      (variant-match r
        ((ok _) #t)
        ((err _) #f)
        (else #f)))

    (define (result-err? r)
      (variant-match r
        ((err _) #t)
        ((ok _) #f)
        (else #f)))

    ;; The functor: touch the success rail, leave a refusal alone.
    (define (result-map r f)
      (if (result-ok? r) (ok (f (ok-value r))) r))

    (define (result-map-err r f)
      (if (result-err? r) (err (f (err-reason r))) r))

    (define (result-map2 ra rb f)
      (if (result-err? ra)
          ra
          (if (result-err? rb) rb (ok (f (ok-value ra) (ok-value rb))))))

    ;; THE one primitive. Every short-circuit in the game flows through here.
    (define (result-bind r f)
      (if (result-ok? r) (f (ok-value r)) r))

    (define (result-bimap r on-ok on-err)
      (if (result-ok? r) (ok (on-ok (ok-value r))) (err (on-err (err-reason r)))))

    (define (result-fold r on-ok on-err)
      (if (result-ok? r) (on-ok (ok-value r)) (on-err (err-reason r))))

    (define (result-pure v) (ok v))

    ;; The ladder back off the rails.
    (define (result-unwrap r)
      (if (result-ok? r) (ok-value r) (error "unwrap of an err" (err-reason r))))

    (define (result-unwrap-or r default)
      (if (result-ok? r) (ok-value r) default))

    (define (result-unwrap-or-else r f)
      (if (result-ok? r) (ok-value r) (f (err-reason r))))

    (define (result-expect r message)
      (if (result-ok? r) (ok-value r) (error message (err-reason r))))

    (define (result->list r) (if (result-ok? r) (list (ok-value r)) '()))

    (define (result-tags) (variant-tags 'result))

    ;; Kleisli composition: two arrows A -> Result become one.
    (define (>=> f g)
      (lambda (x) (result-bind (f x) g)))

    (define (pipe-results-list x steps)
      (fold (lambda (step acc) (result-bind acc step)) (ok x) steps))

    (define (pipe-results x . steps) (pipe-results-list x steps))

    ;; Collections of Results.
    (define (sequence-results rs)
      (let loop ((rs rs) (acc '()))
        (cond ((null? rs) (ok (reverse acc)))
              ((result-err? (car rs)) (car rs))
              (else (loop (cdr rs) (cons (ok-value (car rs)) acc))))))

    (define (traverse-results f xs) (sequence-results (map f xs)))

    (define (ok-values rs) (map ok-value (filter result-ok? rs)))
    (define (err-reasons rs) (map err-reason (filter result-err? rs)))
    (define (first-err rs) (find result-err? rs))
    (define (count-errs rs) (count result-err? rs))

    ;; A raising computation joins the railway.
    (define (attempt thunk)
      (guard (e (#t (err e)))
        (ok (thunk))))

    ;; The do-notation: reads imperative, is result-bind all the way down.
    ;;
    ;; Deliberately NOT exported: a define-syntax macro defined in one
    ;; library scope cannot expand in another (its template identifiers
    ;; carry this library marks). Inside this library result-do works;
    ;; everywhere else, the preloaded lisp/rope.scm result-do is the same
    ;; sugar over the same tags and answers the same values.
    (define-syntax result-do
      (syntax-rules (<-)
        ((_ (name <- expr) rest ...)
         (result-bind expr (lambda (name) (result-do rest ...))))
        ((_ expr) expr)))) 
)
