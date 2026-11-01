;;; tests/scm/fake-host.scm — the host, as data.
;;;
;;; The edge modules (presentation/view, conductor/arcade) speak to sixteen
;;; host primitives. This file DEFINES ALL SIXTEEN in Scheme, shadowing the
;;; Python ones the pytest harness installed, so the whole arcade loop runs
;;; in pure Scheme: no pygame, no SDL dummy driver, no seam. Every painter
;;; call is recorded in `*host-log*`, so UI behavior is asserted against a
;;; draw-call log instead of pixels — a layout tweak moves log entries, not
;;; test coordinates.
;;;
;;; The recording fakes answer exactly what the real host answers: poll
;;; events are alists keyed by the `type:`/`key:` keywords (the same shape
;;; pygame_host.py builds), an empty queue is the Scheme empty list, and
;;; `text-width` is the same length×size/2 measure the headless host uses.

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (srfi 88))

;; --------------------------------------------------------------------- ;;
;;  The host's state                                                       ;;
;; --------------------------------------------------------------------- ;;

(define *host-log* '())        ; newest first: (op arg ...)
(define *host-events* '())     ; queued event alists, oldest first
(define *host-ticks* '())      ; queued dt values, oldest first
(define *host-held* '())       ; ((name . #t) ...) — the bot's key state
(define *host-held-clock* '()) ; ((name . ms-remaining) ...) — the repeat pump
(define *host-das* 150)        ; the pump's cadence — the reference edge's
(define *host-arr* 40)
(define *host-quit?* #f)
(define *host-window* #f)      ; (w h) once opened
(define *host-boot-config* '())
(define *host-autostart* #f)
(define *host-presents* 0)

(define (host-reset!)
  (set! *host-log* '())
  (set! *host-events* '())
  (set! *host-ticks* '())
  (set! *host-held* '())
  (set! *host-held-clock* '())
  (set! *host-quit?* #f)
  (set! *host-window* #f)
  (set! *host-boot-config* '())
  (set! *host-autostart* #f)
  (set! *host-presents* 0))

(define (host-log! op . args)
  (set! *host-log* (cons (cons op args) *host-log*)))

;; --------------------------------------------------------------------- ;;
;;  The sixteen primitives                                                 ;;
;; --------------------------------------------------------------------- ;;

(define (open-window! w h title)
  (set! *host-window* (list w h))
  (host-log! 'window w h title))

(define (clear-screen! rgb) (host-log! 'clear rgb))

(define (draw-rect! x y w h rgb) (host-log! 'rect x y w h rgb))

(define (draw-frame! x y w h rgb) (host-log! 'frame x y w h rgb))

(define (draw-text! x y s size rgb) (host-log! 'text x y s size rgb))

(define (text-width s size)
  ;; Same honest measure the headless host uses: half the type size per
  ;; glyph. The real painter's font differs; the *fit* invariant does not.
  (* (string-length s) (quotient size 2)))

(define (present!)
  (set! *host-presents* (+ *host-presents* 1))
  (host-log! 'present))

(define (tint! rgb) (host-log! 'tint rgb))

(define (tick!)
  (let ((dt (if (null? *host-ticks*)
                16
                (let ((dt (car *host-ticks*)))
                  (set! *host-ticks* (cdr *host-ticks*))
                  dt))))
    ;; The same clamp the real host runs: a fat test clock must not bill a
    ;; 1000ms frame to the repeat pump — it would fire a burst of catch-up
    ;; repeats that floods the queue ahead of real presses.
    (set! dt (min dt 66))
    ;; The repeat pump: every held key's countdown burns this frame's dt,
    ;; and each one that lands at zero queues a ``key-repeat`` event and
    ;; re-arms — the same pump pygame_host.py runs, so the tests exercise
    ;; the real input shape end to end.
    (set! *host-held-clock*
          (srfi-1:map
           (lambda (entry)
             (let* ((name (car entry))
                    (remaining (- (cdr entry) dt)))
               (if (<= remaining 0)
                   (begin
                     (set! *host-events*
                           (append *host-events*
                                   (list (list (list type: 'key-repeat)
                                               (list key: name)))))
                     (cons name (+ remaining *host-arr*)))
                   (cons name remaining))))
           *host-held-clock*))
    dt))

(define (poll-events!)
  (if (null? *host-events*)
      '()
      (let ((ev (car *host-events*)))
        (set! *host-events* (cdr *host-events*))
        (list ev))))

(define (quit-requested?) *host-quit?*)

(define (boot-config) *host-boot-config*)

(define (held? name)
  (if (assq name *host-held*) #t #f))

(define (sfx! name) (host-log! 'sfx name))

(define (quit!) (set! *host-quit?* #t))

(define (autostart?) *host-autostart*)

;; --------------------------------------------------------------------- ;;
;;  Scripting the host                                                     ;;
;; --------------------------------------------------------------------- ;;

;; Queue one key-down: the alist shape the real host builds. A press also
;; seeds the repeat pump's countdown for that key — DAS starts at the press.
(define (host-press! key)
  (set! *host-events*
        (append *host-events*
                (list (list (list type: 'key-down) (list key: key)))))
  (set! *host-held-clock*
        (cons (cons key *host-das*)
              (filter (lambda (e) (not (string=? (car e) key)))
                      *host-held-clock*))))

(define (host-release! key)
  (set! *host-events*
        (append *host-events*
                (list (list (list type: 'key-up) (list key: key)))))
  (set! *host-held-clock*
        (filter (lambda (e) (not (string=? (car e) key)))
                *host-held-clock*)))

(define (host-queue-quit!)
  (set! *host-events*
        (append *host-events* (list (list (list type: 'quit))))))

;; The next n frames advance the clock by dt each (default 16).
(define (host-clock! dt n)
  (set! *host-ticks* (append *host-ticks* (make-list n dt))))

;; Hold a key down the way the bot does — the host's own key state.
(define (host-hold! name)
  (set! *host-held* (cons (cons name #t) *host-held*)))

(define (host-unhold! name)
  (set! *host-held* (filter (lambda (e) (not (eq? (car e) name))) *host-held*)))

;; Run the real loop for n frames.
(define (host-run-frames! n)
  (let loop ((i 0))
    (if (and (< i n) (not *host-quit?*))
        (begin (arcade-step!) (loop (+ i 1)))
        i)))

;; Run until the match leaves the playing phase (a win, a loss) or the
;; frame budget runs out — whichever comes first. A win ends the run at
;; once, so a good AI does not pay for the whole budget.
(define (host-run-while-playing! n)
  (let loop ((i 0))
    (if (and (< i n) (not *host-quit?*) (phase-playing? *st*))
        (begin (arcade-step!) (loop (+ i 1)))
        i)))

;; Press a key and give it one frame of the real loop.
(define (host-type! key)
  (host-press! key)
  (arcade-step!))

;; --------------------------------------------------------------------- ;;
;;  Reading the log                                                        ;;
;; --------------------------------------------------------------------- ;;

(define (host-ops op)
  ;; The log entries for one op, oldest first.
  (reverse (filter (lambda (e) (eq? (car e) op)) *host-log*)))

(define (host-texts)
  ;; Every (x y s size rgb) drawn since the last reset, oldest first.
  (map cdr (host-ops 'text)))

(define (host-text-strings)
  (map (lambda (t) (list-ref t 2)) (host-texts)))

(define (host-sfx-names)
  (map cadr (host-ops 'sfx)))

(define (host-frame-count) *host-presents*)

;; A painter call fits the window when its box is inside it. The veil and
;; the background are exactly window-sized, the well frame has a 2px lip —
;; every entry the log records must still land inside the window.
(define (host-fits-window? entry)
  (let* ((w (car *host-window*))
         (h (cadr *host-window*))
         (op (car entry))
         (a (cdr entry)))
    (cond ((eq? op 'text)
           (let ((x (list-ref a 0)) (y (list-ref a 1))
                 (s (list-ref a 2)) (size (list-ref a 3)))
             (and (>= x 0)
                  (>= y 0)
                  (<= (+ x (text-width s size)) w)
                  (<= (+ y size) h))))
          ((memq op '(rect frame))
           (let ((x (list-ref a 0)) (y (list-ref a 1))
                 (bw (list-ref a 2)) (bh (list-ref a 3)))
             (and (>= x 0) (>= y 0)
                  (<= (+ x bw) w) (<= (+ y bh) h))))
          ((eq? op 'clear) #t)
          (else #t))))

