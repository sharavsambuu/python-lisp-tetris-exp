;;; domain/modes.scm — (tetris modes)
;;;
;;; The four ways to play, as data. A *mode* is a closed variant — the set of
;;; ways a match can be scored and won — and a *mode config* is the record a
;;; menu hands to `new-game`: which mode, where the level starts, what the
;;; target is. Nothing here knows a key, a screen, or the host; the conductor
;;; reads a finished match and asks this library whether it was a win.
;;;
;;; The option parser is where a menu typo is refused by name — an unknown
;;; mode, an unknown option, or an out-of-range value is refused BY NAME —
;;; a condition raised with the valid set in the irritants. The conductor
;;; catches it with `guard` and shows the message; the tests assert the
;;; message names the fix.

(define-library (tetris modes)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (srfi 28)
          (srfi 89)
          (srfi 152)
          (tetris geometry) (tetris board))
  (export mode?
          mode-names
          mode-config?
          make-mode-config
          config-with
          config-mode
          config-starting-level
          config-target-lines
          config-time-limit
          config-cheese-rows
          default-config
          config-from
          config-mode-tag
          cheese-config?
          config-mode->name
          config-options
          mode-label
          cheese-board
          garbage-count
          victory?
          time-remaining
          clock-limit)

  (begin
    ;; The closed four. Every dispatch on a mode anywhere in the program is a
    ;; variant-match over exactly these; a fifth way to play is a diff here
    ;; and nothing else.
    (define-variant mode (marathon) (sprint) (ultra) (cheese) (survival) (zen))

    (define (mode-names) '(marathon sprint ultra cheese survival zen))

    ;; The match recipe: which mode, and the three knobs a menu may tune.
    ;; The defaults are the classic match: endless marathon from level 1.
    (define-record-type mode-config
      (make-mode-config mode starting-level target-lines time-limit cheese-rows)
      mode-config?
      (mode config-mode)
      (starting-level config-starting-level)
      (target-lines config-target-lines)
      (time-limit config-time-limit)
      (cheese-rows config-cheese-rows))

    ;; The updater, `game-with`'s little sibling: name only what changes.
    (define* (config-with c
                          (mode: m (config-mode c))
                          (starting-level: sl (config-starting-level c))
                          (target-lines: tl (config-target-lines c))
                          (time-limit: tl2 (config-time-limit c))
                          (cheese-rows: cr (config-cheese-rows c)))
      (make-mode-config m sl tl tl2 cr))

    ;; Every default is an *integer*: seconds, lines and levels are counted, not
    ;; measured, and an inexact default (120.0) leaked a decimal point into the
    ;; ultra's countdown — `time-remaining` subtracts whole seconds from it.
    (define (default-config)
      (make-mode-config (marathon) 1 40 120 10))

    ;; ---------------------------------------------------------------- ;;
    ;;  The option parser — where a menu typo is refused by name          ;;
    ;; ---------------------------------------------------------------- ;;

    ;; The knobs a menu may set, with their sane ranges. A *presentation*
    ;; guard, not a rule: the domain decides what a level means, but a menu
    ;; should not be able to ask for level 0 or 4000 rows of garbage.
    (define option-limits
      '((starting-level  (1 999))
        (target-lines    (1 999))
        (time-limit      (1 9999))
        (cheese-rows     (0 20))))

    (define (option-setter k)
      (case k
        ((starting-level) (lambda (c v) (config-with c starting-level: v)))
        ((target-lines)   (lambda (c v) (config-with c target-lines: v)))
        ((time-limit)     (lambda (c v) (config-with c time-limit: v)))
        ((cheese-rows)    (lambda (c v) (config-with c cheese-rows: v)))
        (else #f)))

    (define (unknown-mode-error name)
      (raise (list "unknown mode" name
                   (string-append "try one of: "
                                  (string-join (map symbol->string (mode-names))
                                               ", ")))))

    (define (mode-from-name name)
      (if (not (symbol? name))
          (unknown-mode-error name)
          (case name
            ((marathon) (marathon))
            ((sprint) (sprint))
            ((ultra) (ultra))
            ((cheese) (cheese))
            ((survival) (survival))
            ((zen) (zen))
            (else (unknown-mode-error name)))))

    ;; One option's value, checked against its bound. Out of range is a typo,
    ;; and a typo is named.
    (define (checked-option c k v)
      (let ((limits (assq k option-limits)))
        (cond ((not limits)
               (raise (list "unknown mode option" k
                            (string-append "try one of: "
                                           (string-join (map symbol->string
                                                             (map car option-limits))
                                                        ", ")))))
              ((not (number? v))
               (raise (list "mode option expects a number" k v)))
              (else
               (let ((lo (car (cadr limits))) (hi (cadr (cadr limits))))
                 (if (and (>= v lo) (<= v hi))
                     ((option-setter k) c v)
                     (raise (list "mode option out of range" k
                                  (format #f "between ~a and ~a" lo hi) v))))))))

    ;; A mode name and an options alist — `((starting-level 5) …)` — become
    ;; the config `new-game` starts from. Every refusal is a raised condition
    ;; naming the fix; the conductor's `guard` turns one into a message.
    (define (config-from name options)
      (let loop ((c (config-with (default-config) mode: (mode-from-name name)))
                 (opts options))
        (if (null? opts)
            c
            (let ((opt (car opts)))
              (if (not (and (pair? opt) (symbol? (car opt))))
                  (raise (list "mode option is not a (key value) pair" opt))
                  (loop (checked-option c (car opt) (cadr opt))
                        (cdr opts)))))))

    ;; The label a menu shows.
    (define (mode-label c)
      (variant-match (config-mode c)
        ((marathon) "marathon")
        ((sprint) "sprint")
        ((ultra) "ultra")
        ((cheese) "cheese")
        ((survival) "survival")
        ((zen) "zen")
        (else "unknown")))

    ;; The mode as a tag — the conductor's and the tests' way to ask which
    ;; way to play without importing the library's variant constructors.
    (define (config-mode-tag c)
      (variant-match (config-mode c)
        ((marathon) 'marathon)
        ((sprint) 'sprint)
        ((ultra) 'ultra)
        ((cheese) 'cheese)
        ((survival) 'survival)
        ((zen) 'zen)
        (else #f)))

    ;; Whether a match is a cheese dig — the question new-game and the
    ;; restart ask about their own recipe.
    (define (cheese-config? c)
      (eq? (config-mode-tag c) 'cheese))

    ;; The config's mode as the name the menus spell — the round trip a
    ;; replay takes: config -> name -> options -> config.
    (define (config-mode->name c)
      (variant-match (config-mode c)
        ((marathon) "marathon")
        ((sprint) "sprint")
        ((ultra) "ultra")
        ((cheese) "cheese")
        ((survival) "survival")
        ((zen) "zen")
        (else "marathon")))

    ;; The config's tunables as the options alist a fresh match takes —
    ;; everything a replay needs to be the same match again.
    (define (config-options c)
      (list (list 'starting-level (config-starting-level c))
            (list 'target-lines (config-target-lines c))
            (list 'time-limit (config-time-limit c))
            (list 'cheese-rows (config-cheese-rows c))))

    ;; ---------------------------------------------------------------- ;;
    ;;  Cheese seeding                                                    ;;
    ;; ---------------------------------------------------------------- ;;

    ;; The same Lehmer generator the bag owns, kept local: a cheese board is
    ;; seeded from the match's seed, so a seeded cheese match replays exactly.
    (define (mode-next-seed seed)
      (modulo (* seed 48271) 2147483647))

    ;; `rows` garbage rows at the bottom, each with one hole. The hole's
    ;; column is drawn off the generator — a fold, one row at a time.
    (define (cheese-board seed rows)
      (let loop ((i 0) (seed seed) (board (make-board)))
        (if (>= i rows)
            board
            (let* ((seed* (mode-next-seed seed))
                   (hole (modulo seed* matrix-width))
                   (y (- matrix-height 1 i))
                   (row (make-vector matrix-width 'g)))
              (vector-set! row hole #f)
              (vector-set! board y row)
              (loop (+ i 1) seed* board)))))

    ;; How much garbage is left — the number a cheese HUD shows and the win
    ;; condition watches. A fold over the settled grid.
    (define (garbage-count board)
      (let loop-y ((y 0) (n 0))
        (if (>= y matrix-height)
            n
            (loop-y (+ y 1)
                    (+ n (let loop-x ((x 0) (m 0))
                           (if (>= x matrix-width)
                               m
                               (loop-x (+ x 1)
                                       (if (eq? (board-ref board x y) 'g)
                                           (+ m 1)
                                           m)))))))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The win conditions                                                ;;
    ;; ---------------------------------------------------------------- ;;

    ;; A finished match is read, not asked twice: the mode dispatches, and
    ;; each way to play owns its own victory. The arguments are the reads the
    ;; pipeline already has in hand — the line count, the match clock, the
    ;; settled board, the recipe — so this stays a pure function of data.
    (define (victory? game-lines game-clock board config)
      (variant-match (config-mode config)
        ((sprint) (>= game-lines (config-target-lines config)))
        ((ultra) (>= game-clock (clock-limit config)))
        ((cheese) (= (garbage-count board) 0))
        (else #f)))

    ;; The countdown an ultra HUD shows, in whole seconds (never negative).
    (define (time-remaining game-clock config)
      (max 0 (- (config-time-limit config)
                (quotient game-clock 1000))))

    ;; The clock an ultra match runs against, in milliseconds.
    (define (clock-limit config) (* 1000 (config-time-limit config)))))
