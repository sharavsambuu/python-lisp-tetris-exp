;;; domain/bag.scm — (tetris bag)
;;;
;;; The randomizer as a *value*. Guideline Tetris deals from a 7-bag: shuffle
;;; all seven pieces, deal them out, shuffle again. A bag state is a pair:
;;; the queue of pieces still to deal, and the generator's seed. Every draw
;;; answers a piece and a new state; nothing here mutates, so a game's whole
;;; random future is a value the tests can hold and steer.
;;;
;;; The PRNG is a Lehmer generator, deliberately owned by the domain: seeding
;;; it is how a test says "deal me exactly this match".

(define-library (tetris bag)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each)) (tetris geometry))
  (export make-bag
          bag-queue
          bag-next
          bag-peek
          bag-refill-from)

  (begin
    (define modulus 2147483647)          ; 2^31 - 1, a Lehmer-friendly prime
    (define multiplier 48271)            ; the Lehmer generator's multiplier

    ;; One step of the generator.
    (define (next-seed seed)
      (modulo (* seed multiplier) modulus))

    ;; An integer in [0 n), from one generator step.
    (define (random-below seed n)
      (modulo (next-seed seed) n))

    ;; A shuffle expressed as a fold: walk the list, taking each pick from a
    ;; position drawn off the generator, building the shuffled bag on the way.
    (define (shuffle xs seed)
      (let loop ((items xs) (seed seed) (acc '()))
        (if (null? items)
            (values acc seed)
            (let* ((seed* (next-seed seed))
                   (i (modulo seed* (length items)))
                   (picked (list-ref items i))
                   (rest (append (take items i) (drop items (+ i 1)))))
              (loop rest seed* (cons picked acc))))))

    ;; A freshly shuffled bag, appended behind whatever is still waiting:
    ;; a refill never jumps the queue the current deal is already in.
    (define (bag-refill-from queue seed)
      (let-values (((fresh seed*) (shuffle piece-names seed)))
        (values (append queue fresh) seed*)))

    ;; A bag state with one full shuffled bag waiting.
    (define (make-bag seed)
      (let-values (((queue seed*) (bag-refill-from '() seed)))
        (cons queue seed*)))

    ;; One draw: the head of the queue, and the state with the queue one
    ;; shorter — topped back up to a full bag the moment it runs low, so a
    ;; peek never sees past a shuffle that has not happened yet.
    (define (bag-next st)
      (let* ((queue (car st))
             (seed (cdr st))
             (piece (car queue))
             (rest (cdr queue)))
        (if (>= (length rest) (length piece-names))
            (values piece (cons rest seed))
            (let-values (((rest* seed*) (bag-refill-from rest seed)))
              (values piece (cons rest* seed*))))))

    ;; The next n piece names, without consuming them. A peek into the future.
    (define (bag-peek st n)
      (take (car st) n))

    (define (bag-queue st) (car st))))
