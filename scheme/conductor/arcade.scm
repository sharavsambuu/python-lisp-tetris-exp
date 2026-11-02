;;; conductor/arcade.scm — the conductor (an edge module, not a library).
;;;
;;; Like the view, this file speaks to the host (the window, the clock, the
;;; event pump, the speaker), so it lives at top level, outside the library
;;; fence. The pure contexts it drives are the libraries under ``domain/``,
;;; ``rules/`` and ``content/`` — the conductor may call them; they may not
;;; know it.
;;;
;;; The product around one match, campaign-first with free play kept:
;;;
;;;   title ──enter──▶ campaign ──enter──▶ play      (a level ladder)
;;;     └────enter──▶ mode ──enter──▶ level ──enter──▶ play   ("Free play")
;;;
;;; Escape means "back one step": a campaign and the mode/level screens
;;; return to the title, and the title quits. From a live match it *pauses*
;;; instead, so leaving a match takes a second escape — a stray keypress
;;; should cost a keypress, not a game. The current screen is one symbol,
;;; and `back!` is the whole of the rule.
;;;
;;; The *content* — the campaigns and the challenges ("modes") they are
;;; built from — is data in ``(tetris campaign)``, so a new campaign is a
;;; diff to a list, not to this file. A level selection ends in one call:
;;;
;;;   (start-match! challenge-or-config)
;;;
;;; This file also owns the two edge policies the match record must not
;;; know about: the speaker's routing table, and the effects award table
;;; (what a clear or a slam is worth in flash and shake). The AI lives here
;;; too — its pure arithmetic is ``(tetris plan)``, its frame-budgeted
;;; search and its steering are edge code, because a plan that costs frames
;;; is a scheduling decision. Held-key repeat (DAS/ARR) is the HOST's
;;; pump: it fires ``key-repeat`` events on its own clock, and this file
;;; only decides which commands may repeat.
;;;
;;; Public names: arcade-main.

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (srfi 26)
        (srfi 88)
        (tetris result)
        (tetris geometry) (tetris board) (tetris bag) (tetris modes) (tetris game)
        (tetris plan) (tetris campaign)
        (tetris commands) (tetris gravity) (tetris rules))
  (begin
    ;; ---------------------------------------------------------------- ;;
    ;;  The session — the edge's own state, never inside a match record    ;;
    ;; ---------------------------------------------------------------- ;;

    (define *screen* 'title)   ;; title | campaign | mode | level | play
    ;; The raw menu shape — `(entries cursor)` — until boot! builds the real
    ;; one (make-menu is defined below; top-level defines run in order).
    (define *menu* (list '() 0))
    (define *mode* 'marathon) ;; the free-play mode the player picked (a symbol)
    (define *level* 1)         ;; the free-play level a match starts on
    (define *bests* '())       ;; ((label score) ...) — this session's bests
    (define *campaign* #f)     ;; the campaign whose levels the screen shows
    (define *challenge* #f)    ;; the challenge the live match was built from
    (define *origin* 'free)    ;; free | campaign
    (define *playing-key* #f)  ;; the campaign level key being played, if any
    (define *playing-index* #f)
    (define *done* '())        ;; the campaign levels already won
    (define *ai* #f)           ;; does Lisp play? (A toggles)
    (define *st* (new-game))   ;; the live match, when there is one
    (define *dirty* #t)        ;; does the screen need paint?

    ;; How far up the level ladder *free play* offers. A design choice, not
    ;; a rule: the domain's progression keeps going, this is just how high a
    ;; cold start is worth offering.
    (define *level-count* 10)

    (define (new-seed)
      (+ 1 (modulo (current-jiffy) 1000000007)))

    ;; The seed the host handed us (--seed), or the clock's.
    (define *seed* #f)

    ;; The AI the "A" key turns on. The same search as the one-ply library,
    ;; so watching the arcade play is watching that arithmetic again.
    (define *weights* (weights 2.0 2.5 0.5 0.6))

    ;; ---------------------------------------------------------------- ;;
    ;;  The speaker — which fact, which blip                               ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The edge owns the speaker primitive; the *policy* — which fact
    ;; outranks which — is a table here. One sound a turn: the loudest
    ;; fact wins, in the order the table reads. A player's command is
    ;; heard through the journal it journaled (a move, a rotation, a
    ;; lock); there is no second, per-command table — the keymap's tags
    ;; never matched its keys, and the journal has been the effects rail
    ;; all along.

    (define *sfx-fact*   ;; (fact-tag kind), loudest first
      '((game-over "over")
        (victory   "victory")
        (level-up  "level-up")
        (cleared   "clear")
        (restarted "start")))

    (define (sfx-journal! events)
      (let loop ((order *sfx-fact*))
        (if (null? order)
            (for-each sfx-event! events)
            (let ((hit (find (lambda (ev) (eq? (tag-of ev) (car (car order))))
                             events)))
              (if hit
                  (sfx! (cadr (car order)))
                  (loop (cdr order)))))))

    ;; The per-event sounds that are not in the ranking (moves, rotations…)
    ;; still play — the ranking only decides the turn's *headline*.
    (define (sfx-event! ev)
      (variant-match ev
        ((moved) (sfx! "move"))
        ((rotated) (sfx! "rotate"))
        ((dropped _) (sfx! "drop"))
        ((locked _) (sfx! "lock"))
        ((hold-swapped) (sfx! "hold"))
        ((hold-refused) (sfx! "denied"))
        (else #f)))

    ;; Play the journal, then hand back the state with the paper trail
    ;; emptied: the journal is read exactly once, at the edge. A `(locked _)`
    ;; fact also bumps the edge-side lock counter — the AI's piece key reads
    ;; it, because a journal that drains would otherwise change length and
    ;; restart the search every frame.
    (define (drain-journal! st)
      (let ((events (reverse (game-journal st))))
        (for-each
         (lambda (ev)
           (variant-match ev ((locked _) (set! *lock-count* (+ *lock-count* 1))) (else #f)))
         events)
        (sfx-journal! events)
        (award-journal! events)
        (journal-drained st)))

    ;; ---------------------------------------------------------------- ;;
    ;;  The effects award table — what a fact is worth on the screen       ;;
    ;; ---------------------------------------------------------------- ;;

    ;; A clear count's flash colour: four lines outshine two, white is the
    ;; anything-else answer.
    (define *clear-palette*
      '((1 (60 60 80))
        (2 (90 90 110))
        (3 (140 140 170))
        (4 (80 200 220))))

    (define *clear-flash-base-ms* 100)
    (define *clear-flash-per-line-ms* 50)
    (define *slam-shake-px* 2.5)
    (define *level-up-shake-px* 1.0)
    (define *shake-cap-px* 6.0)

    (define (fx-thud! px)
      (view-shake! (min *shake-cap-px* px)))

    (define (award-journal! events)
      (for-each
       (lambda (ev)
         (variant-match ev
           ((cleared rows)
            (let ((rgb (or (cadr (assq (length rows) *clear-palette*)) '(200 200 210))))
              (view-flash! rgb (+ *clear-flash-base-ms*
                                  (* (length rows) *clear-flash-per-line-ms*)))
              (fx-thud! (min 2.0 (* (length rows) 0.5)))
              ;; The beam: bars across the rows the clear took, burning as
              ;; long as the flash — the animation that reads "these rows
              ;; just left".
              (view-clear-beam! rows)))
           ((dropped d)
            (if (>= d 6) (fx-thud! *slam-shake-px*) #f))
           ((hold-swapped) (view-hold-pulse!))
           ((hold-refused) (fx-thud! 1.0))
           ((level-up _) (view-flash! '(80 220 200) 170) (fx-thud! *level-up-shake-px*))
           ((victory) (view-flash! '(230 230 240) 220))
           ((game-over) (view-flash! '(160 40 40) 260))
           (else #f)))
       events))

    ;; ---------------------------------------------------------------- ;;
    ;;  The match — start, finish, the ladder walk                         ;;
    ;; ---------------------------------------------------------------- ;;

    ;; Start a match from a mode name + options, from the seed the host
    ;; handed us (--seed) or the clock's. A typo in the mode or the options
    ;; raises a named condition; the guard at the call site shows the
    ;; message instead of dying.
    (define (start-match! mode-name options origin challenge key index)
      (guard (e (#t
                 ;; The refusal must leave a HEALTHY title: the menu value
                 ;; rebuilt, the flag dirty. Only assigning the symbol here
                 ;; froze whatever screen the player was on — and, on a cold
                 ;; boot with a bad --mode, left the never-built empty menu,
                 ;; whose first RETURN crashed.
                 (show-screen! 'title (title-menu))
                 (display "match refused: ")
                 (display (describe-condition e))
                 (newline)))
        (let ((seed (or *seed* (new-seed))))
          (set! *st* (fresh-game seed: seed mode: mode-name options: options))
          (set! *origin* origin)
          (set! *challenge* challenge)
          (set! *playing-key* key)
          (set! *playing-index* index)
          (set! *dirty* #t)
          (set! *settled* #f)
          (set! *screen* 'play)
          (reset-ai!)
          (view-reset!)
          (sfx! "start"))))

    (define (describe-condition e)
      ;; A raised condition is a list of irritants, or an error object —
      ;; both render as the message the player can act on.
      (cond ((list? e) (join " " (map ->text e)))
            ((error-object? e) (error-object-message e))
            (else (->text e))))

    (define (->text v)
      (cond ((string? v) v)
            ((symbol? v) (symbol->string v))
            ((number? v) (number->string v))
            (else ".")))

    (define (join sep xs)
      (let loop ((xs xs) (acc ""))
        (cond ((null? xs) acc)
              ((null? (cdr xs)) (string-append acc (->text (car xs))))
              (else (loop (cdr xs) (string-append acc (->text (car xs)) sep))))))

    ;; A finished match: free play records a best, a campaign level marks
    ;; its rung done. Both are edge state — the match record stays a value.
    (define (settle-match! st)
      (let ((label (mode-label (game-config st))))
        ;; The best is FREE PLAY's scoreboard: a campaign's score is the
        ;; rung's, and recording it here leaked ladder wins (and ladder
        ;; losses) into the mode list the title decorates.
        (if (eq? *origin* 'free)
            (set! *bests* (record-best *bests* label (game-score st)))
            #f)
        (if (and (eq? *origin* 'campaign)
                 *playing-key*
                 (phase-won? st))
            (begin
              (set! *done* (mark-done *done* *playing-key*))
              #t)
            #f)))

    ;; The level a won campaign match hands the player: the next rung of the
    ;; ladder, or #f when the ladder is finished.
    (define (next-challenge)
      (if (and *campaign* *playing-index*)
          (let ((levels (campaign-levels *campaign*))
                (next (+ *playing-index* 1)))
            (if (<= next (length levels))
                (list-ref levels (- next 1))
                #f))
          #f))

    ;; ---------------------------------------------------------------- ;;
    ;;  Menus — a cursor over labelled choices: data, and text             ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; A menu is not a widget, it is a *value*: a list of (label value)
    ;; entries and an index. Functional on purpose: `menu-move` returns a
    ;; new menu rather than editing one.

    (define (make-menu entries) (list entries 0))
    (define (menu-entries m) (car m))
    (define (menu-cursor m) (cadr m))
    (define (menu-count m) (length (menu-entries m)))
    (define (menu-at m i) (list-ref (menu-entries m) i))
    (define (menu-selected m)
      ;; The selected entry's *value* — the thing a screen acts on. The
      ;; label may carry decoration (a done-mark, a best); the value stays
      ;; the bare thing.
      (cadr (menu-at m (menu-cursor m))))
    (define (menu-label m)
      (car (menu-at m (menu-cursor m))))
    (define (menu-move m delta)
      (let ((n (menu-count m)))
        (if (= n 0)
            m
            (let* ((raw (+ (menu-cursor m) delta))
                   (i (cond ((< raw 0) (- n 1))
                            ((>= raw n) 0)
                            (else raw))))
              (list (menu-entries m) i)))))
    (define (menu-set m i)
      (if (and (>= i 0) (< i (menu-count m)))
          (list (menu-entries m) i)
          m))

    ;; The menu as the lines the overlay draws: the cursor marked, the
    ;; labels padded to the widest so the cursor column does not wander.
    (define (spaces n)
      (if (<= n 0) "" (string-append " " (spaces (- n 1)))))

    (define (menu-width entries)
      (let loop ((rest entries) (widest 0))
        (if (null? rest)
            widest
            (loop (cdr rest)
                  (max widest (string-length (->text (car (car rest)))))))))

    (define (menu-lines m)
      (let ((entries (menu-entries m))
            (cursor (menu-cursor m))
            (width (menu-width (menu-entries m))))
        (let build ((rest entries) (i 0) (acc '()))
          (if (null? rest)
              (reverse acc)
              (let* ((entry (car rest))
                     (label (->text (car entry)))
                     (row (string-append (if (= i cursor) "> " "  ")
                                         label
                                         (spaces (- width (string-length label))))))
                (build (cdr rest) (+ i 1) (cons row acc)))))))

    ;; A screen's text as overlay specs: (string size) pairs.
    (define (menu-overlay m title hint)
      (append (list (list title 30) (list "" 12))
              (map (lambda (s) (list s 22)) (menu-lines m))
              (if (string=? hint "")
                  '()
                  (list (list "" 12) (list hint 18)))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The AI — plan (frame-budgeted), then steer one step                ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The search cannot clone the world, so the domain lends it pure probes
    ;; — `landing-y-at` and `column-heights` — and the planner scores the 40
    ;; placements from the *shape they would leave*, never rebuilding the
    ;; board. Even so the enumeration is more than one frame should pay at
    ;; once, so the search is a stepper: each call scores a few placements
    ;; and answers the symbol `pending` until it is done. The board's
    ;; settled columns do not move while a piece is airborne, so scoring
    ;; across frames is scoring the same board.

    (define *best-per-frame* 6)  ;; placements scored per call

    (define *search-key* #f)     ;; piece key (lock count + kind) the search opened for
    (define *search-i* 40)       ;; next placement index to score (40 = settled)
    (define *search-bx* 3)
    (define *search-brot* 0)
    (define *search-best* -1000000000)
    (define *search-hts* #f)     ;; the settled profile, as a vector
    (define *search-rows* 20)
    (define *search-shapes* #f)  ;; the four cell lists, one per rotation

    (define (reset-ai!)
      (set! *search-key* #f)
      (set! *search-i* 40)
      (set! *search-bx* 3)
      (set! *search-brot* 0)
      (set! *search-best* -1000000000)
      (set! *search-hts* #f)
      (set! *search-rows* 20)
      (set! *search-shapes* #f))

    (define (best-placement st ws)
      (let ((key (piece-key st)))
        (when (not (equal? key *search-key*))
          (set! *search-i* 0)
          (set! *search-bx* 3)
          (set! *search-brot* 0)
          (set! *search-best* -1000000000)
          ;; The settled board and the shapes are fixed for this piece's
          ;; whole life — read them once, not four times a frame.
          (set! *search-hts* (column-heights (game-board st)))
          (set! *search-rows* matrix-height)
          (set! *search-shapes*
                (map (lambda (rot) (piece-cells (falling-name (game-active st)) rot))
                     (list 0 1 2 3)))
          (set! *search-key* key))
        (let loop ((scored 0) (i *search-i*))
          (cond ((>= i 40)
                 (set! *search-i* i)
                 (list *search-bx* *search-brot*))
                ((>= scored *best-per-frame*)
                 (set! *search-i* i)
                 'pending)
                (else
                 (let* ((rot (quotient i 10))
                        (x (remainder i 10))
                        (ly (landing-y-at st x rot)))
                   (if (not ly)
                       ;; Refused placements cost only the crossing: they do
                       ;; not spend the frame's score budget.
                       (loop scored (+ i 1))
                       (let ((score (placement-score ws *search-hts*
                                                     (list-ref *search-shapes* rot)
                                                     x ly *search-rows*)))
                         (when (> score *search-best*)
                           (set! *search-best* score)
                           (set! *search-bx* x)
                           (set! *search-brot* rot))
                         (loop (+ scored 1) (+ i 1))))))))))

    ;; Plan state, then steering: one plan per piece, one command a frame.
    (define *plan-key* #f)
    (define *plan-ready* #f)
    (define *plan-x* 3)
    (define *plan-rot* 0)
    (define *lock-count* 0)   ;; edge-side counter, fed by the journal

    (define (piece-key st)
      ;; The identity of the piece a plan belongs to: the lock count *and*
      ;; the kind. A count alone is not enough: a hold swaps the active
      ;; piece without locking one, so the key would stay the same and the
      ;; plan would steer the new piece with the old piece's shape.
      (list *lock-count*
            (if (game-active st) (falling-name (game-active st)) #f)))

    (define (steer-to! st x rot)
      (let* ((p (game-active st))
             (px (falling-x p)))
        (cond ((not (= (falling-rot p) rot))
               (let ((r (apply-command st (rotate-cw))))
                 (if (result-ok? r) (set! *st* (ok-value r)) (ai-drop! st))))
              ((< px x)
               (let ((r (apply-command st (right))))
                 (if (result-ok? r) (set! *st* (ok-value r)) (ai-drop! st))))
              ((> px x)
               (let ((r (apply-command st (left))))
                 (if (result-ok? r) (set! *st* (ok-value r)) (ai-drop! st))))
              (else (ai-drop! st)))))

    (define (ai-drop! st)
      (let ((r (apply-command st (hard-drop))))
        (if (result-ok? r) (set! *st* (ok-value r)) #f)))

    (define (ai-step!)
      (when (and *ai* (phase-playing? *st*) (game-active *st*))
        (let ((key (piece-key *st*)))
          (when (not (equal? key *plan-key*))
            (set! *plan-key* key)
            (set! *plan-ready* #f))
          (when (not *plan-ready*)
            (let ((plan (best-placement *st* *weights*)))
              (when (not (eq? plan 'pending))
                (set! *plan-x* (car plan))
                (set! *plan-rot* (cadr plan))
                (set! *plan-ready* #t))))
          (when *plan-ready*
            (steer-to! *st* *plan-x* *plan-rot*)))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The screens                                                        ;;
    ;; ---------------------------------------------------------------- ;;

    ;; The title: the campaigns, free play, and the door out. The label
    ;; decoration is a level count, read from the content.
    (define (title-menu)
      (make-menu
       (append
        (map (lambda (c)
               (list (string-append (campaign-title c)
                                    "  ("
                                    (number->string
                                     (length (campaign-levels c)))
                                    " levels)")
                     (cons 'campaign c)))
             (campaigns))
        (list (list "Free play" '(free-play))
              (list "Quit" '(quit))))))

    ;; The campaign ladder: each rung shows its title, and a checkmark when
    ;; this session has already won it.
    (define (campaign-menu camp)
      (make-menu
       (map (lambda (ch i)
              (let ((key (level-key (campaign-id camp) i)))
                (list (string-append (number->string i) ". "
                                     (challenge-title ch)
                                     (if (level-done? *done* key) " [x]" ""))
                      (cons 'challenge ch))))
            (campaign-levels camp)
            (iota (length (campaign-levels camp)) 1))))

    ;; Free play: the four ways to play, one canonical spelling each, with
    ;; the session's best beside the one that has one. The values are the
    ;; mode *symbols* the domain's config-from spells.
    (define (mode-menu)
      (make-menu
       (map (lambda (m)
              (let ((best (best-for *bests* (symbol->string m))))
                (list (if (> best 0)
                          (string-append (symbol->string m)
                                         "  best " (number->string best))
                          (symbol->string m))
                      (cons 'mode m))))
            (mode-names))))

    ;; The level picker: one entry, moved with the arrows — the *value* is
    ;; the number itself, so the label and the truth cannot drift apart.
    (define (level-menu)
      (make-menu (list (list (string-append "Level " (number->string *level*))
                             (cons 'level *level*)))))

    (define (show-screen! screen menu)
      (set! *screen* screen)
      (set! *menu* menu)
      (view-reset!)   ; menus wear no match's flash or beam
      (set! *dirty* #t))

    (define (back!)
      (case *screen*
        ((title) (quit!))
        (else (show-screen! 'title (title-menu)))))

    ;; The screen's own text, as overlay specs — the biggest type on the
    ;; window, centred line by line.
    (define (screen-overlay)
      (case *screen*
        ((title)
         (menu-overlay *menu* "SCHEME TETRIS" "UP/DOWN MOVE   RETURN PICK   Q QUIT"))
        ((campaign)
         (menu-overlay *menu*
                       (campaign-title *campaign*)
                       (string-append (challenge-goal (cdr (menu-selected *menu*)))
                                      "   ESC: BACK")))
        ((mode)
         (menu-overlay *menu* "FREE PLAY — SELECT MODE" "RETURN: CHOOSE   ESC: BACK"))
        ((level)
         (menu-overlay *menu*
                       (string-append "STARTING LEVEL — " (symbol->string *mode*))
                       "LEFT/RIGHT: STEP   UP/DOWN: SKIP 5   RETURN: PLAY"))
        (else '())))

    (define (draw-screen!)
      (clear-screen! (color bg:))
      (draw-well!)
      (draw-panel! (lay left-x:) "SCHEME")
      (draw-panel! (lay right-x:) "TETRIS")
      (draw-overlay!
       (append (list (list "" 10)) (screen-overlay)))
      (apply-fx!)
      (present!))

    ;; ---------------------------------------------------------------- ;;
    ;;  Menu input                                                         ;;
    ;; ---------------------------------------------------------------- ;;

    ;; Menu keys are *strings* — the edge reports them by name — so the
    ;; dispatch is string=?, never `case` (whose eqv? would compare the
    ;; strings' identities, and two spellings of "down" are not one key).
    (define (menu-key! key)
      (cond ((string=? key "up")
             (set! *menu* (menu-move *menu* -1)) (sfx! "menu-move") (set! *dirty* #t))
            ((string=? key "down")
             (set! *menu* (menu-move *menu* 1)) (sfx! "menu-move") (set! *dirty* #t))
            ((string=? key "return") (choose!))
            ((string=? key "escape") (back!) (sfx! "pause"))
            ((string=? key "q") (quit!))
            (else #f)))

    ;; What the selected entry *means*, per screen — the whole of the
    ;; shell's decisions, in one dispatch. A challenge's ladder position is
    ;; its index in the campaign, so the level key a win writes is the same
    ;; key the ladder screen read.
    (define (choose!)
      (let ((sel (menu-selected *menu*)))
        (case (car sel)
          ((campaign)
           (set! *campaign* (cdr sel))
           (show-screen! 'campaign (campaign-menu (cdr sel)))
           (sfx! "menu-select"))
          ((challenge)
           ;; The ladder position: the menu stored the level object itself,
           ;; so the same object is the answer — find it with a walk, not
           ;; list-index (whose eq? can never match two alist values).
           (let* ((ch (cdr sel))
                  (idx (let find ((ls (campaign-levels *campaign*)) (i 0))
                         (cond ((null? ls) 0)
                               ((eq? (car ls) ch) i)
                               (else (find (cdr ls) (+ i 1)))))))
             (start-match! (challenge-mode ch) (challenge-options ch)
                           'campaign ch
                           (level-key (campaign-id *campaign*) (+ idx 1))
                           (+ idx 1))))
          ((free-play) (show-screen! 'mode (mode-menu)) (sfx! "menu-select"))
          ((mode)
           (set! *mode* (cdr sel))
           (show-screen! 'level (level-menu))
           (sfx! "menu-select"))
          ((level)
           (start-match! *mode*
                         (list (list 'starting-level *level*))
                         'free #f #f #f))
          ((quit) (quit!))
          (else #f))))

    ;; The level picker's arrows: left/right step, up/down skip five — and
    ;; the menu re-renders because the label carries the number.
    (define (level-step! delta)
      (set! *level* (max 1 (min *level-count* (+ *level* delta))))
      (set! *menu* (level-menu))
      (set! *dirty* #t))

    (define (menu-key-with-level! key)
      (cond ((string=? key "left")  (level-step! -1))
            ((string=? key "right") (level-step! 1))
            ((string=? key "up")    (level-step! 5))
            ((string=? key "down")  (level-step! -5))
            (else (menu-key! key))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The play screen — one frame of live match                          ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The order is the discipline: events first (a key press lands *before*
    ;; the gravity of the frame it happened in), then the AI's one step,
    ;; then the repeat policy, then gravity, then the draw. A frame draws
    ;; only when something happened.

    ;; The keys a *held* key may repeat — one-shots (rotate, hard drop,
    ;; hold, restart) stay one per physical press. The host pumps the
    ;; repeats; this table is only the conductor's "which repeats mean
    ;; anything" decision.
    (define repeat-able '("left" "right" "down"))

    ;; One polled event against the live match. This runs ONLY while the
    ;; phase is playing — a paused or finished match is a *decision point*,
    ;; and its keys go through `play-key!` instead. The state after the
    ;; event is the answer; held-key state lives in the host.
    (define (apply-event st ev)
      (let ((type (cadr (assq type: ev))))
        (case type
          ((quit)
           (quit!)
           st)
          ((key-down)
           (let ((key (cadr (assq key: ev))))
             (cond
               ;; The toggles: the AI and the ghost are the player's.
               ((string=? key "a")
                (set! *ai* (not *ai*))
                (reset-ai!)
                st)
               ((string=? key "g")
                (show-ghost! (not (show-ghost?)))
                st)
               ;; Escape from a live match pauses rather than leaves — a
               ;; stray keypress should cost a keypress, not a game.
               ((string=? key "escape")
                (sfx! "pause")
                (set! *dirty* #t)   ; the veil must paint this frame
                (game-with st phase: (paused)))
               ((string=? key "p")
                (sfx! "pause")
                (set! *dirty* #t)   ; the veil must paint this frame
                (game-with st phase: (paused)))
               ((string=? key "q")
                (quit!)
                st)
               ;; Everything else goes through the keymap, once. The
               ;; blip, if any, is the journal's — the frame's drain
               ;; speaks for the move.
               (else
                (let ((cmd (key->command key)))
                  (if cmd
                      (let ((r (apply-command st cmd)))
                        (if (result-ok? r) (ok-value r) st))
                      st))))))
          ((key-repeat)
           ;; The host says a key is still down. Only the repeatable
           ;; commands glide; one-shots ignore their repeats, and repeats
           ;; are deliberately silent — 25 blips a second is a machine
           ;; gun, not feedback.
           (let ((key (cadr (assq key: ev))))
             (if (member key repeat-able)
                 (let ((cmd (key->command key)))
                   (if cmd
                       (let ((r (apply-command st cmd)))
                         (if (result-ok? r) (ok-value r) st))
                       st))
                 st)))
          (else st))))

    (define (apply-events st evs)
      (if (null? evs)
          st
          (apply-events (apply-event st (car evs)) (cdr evs))))

    ;; One frame of the live match. The order is the discipline: events
    ;; first (a key press lands *before* the gravity of the frame it
    ;; happened in) — and the state the events produced is SAVED, or the
    ;; player's keys would land in a discarded world — then the AI's one
    ;; step, then gravity, then the draw. A frame draws only when something
    ;; happened — and `*dirty*` is read HERE, after the events, on purpose:
    ;; a pause keypress sets it mid-frame, and the veil must paint this
    ;; frame. Held-key repeats arrived in this frame's events, pumped by
    ;; the host on its own clock.
    (define (play-frame st)
      (let* ((dt (tick!))
             (evs (poll-events!)))
        (set! *st* (apply-events st evs))
        (ai-step!)
        (let-values (((st* time-moved) (step-time-v *st* dt)))
          (set! *st* st*)
          (view-fx-step! dt *st*)
          (let* ((anything (or *dirty* time-moved
                               (view-busy? *st*)
                               (not (null? (game-journal *st*))))))
            ;; The drained state is the state: `drain-journal!` answers the
            ;; record with the paper trail cleared, and losing that value
            ;; would re-count every old fact on every frame — the journal
            ;; must actually drain.
            (if anything
                (begin
                  (draw-game! *st*)
                  (set! *st* (drain-journal! *st*)))
                #f)))))

    ;; step-time answers a Result; the loop lives below the railway, so this
    ;; little stair takes it down: state, plus whether time did anything.
    (define (step-time-v st dt)
      (let ((r (step-time st dt)))
        (if (result-ok? r)
            (values (ok-value r)
                    (not (null? (game-journal (ok-value r)))))
            (values st #f))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The loop                                                           ;;
    ;; ---------------------------------------------------------------- ;;

    ;; A terminal match settles itself once: the best is recorded, the
    ;; campaign rung is marked, and the flag keeps the settle from repeating
    ;; every frame the result sits on screen.
    (define *settled* #t)

    ;; A terminal or paused match is a *decision point*, not a frame to
    ;; simulate: pump its keys through `play-key!`, keep the effects
    ;; decaying, and repaint when something changed.
    (define (result-step!)
      (let ((dt (tick!))
            (evs (poll-events!)))
        (view-fx-step! dt *st*)
        (let loop ((rest evs))
          (if (null? rest)
              #f
              (let ((type (cadr (assq type: (car rest)))))
                (case type
                  ((quit) (quit!))
                  ((key-down)
                   (play-key! (cadr (assq key: (car rest)))))
                  (else #f))
                (loop (cdr rest)))))
        (if (eq? *screen* 'play)
            ;; Still the match's screen: paint it, and the drain speaks
            ;; for it.
            (if (or *dirty* (view-busy? *st*) (not (null? (game-journal *st*))))
                (begin
                  (draw-game! *st*)
                  ;; The drained state is the state — the live path's own
                  ;; discipline. Dropping this value left the terminal fact
                  ;; in the journal forever: the result screen repainted and
                  ;; replayed its sound every frame.
                  (set! *st* (drain-journal! *st*))
                  (set! *dirty* #f))
                #f)
            ;; A key LEFT the match this frame (ESC/RETURN to the title):
            ;; the journal still drains — `drain-journal!` is the one place
            ;; facts become sounds and effects, and a fact must not depend
            ;; on which screen comes next — but the PAINT is the new
            ;; screen's job. `*dirty*` stays set, so the menu paints the
            ;; title on the very next frame. Painting the old match here
            ;; and clearing the flag left the player staring at GAME OVER
            ;; on a screen that believed it was the title.
            (begin
              (set! *st* (drain-journal! *st*))
              #f))))

    (define (play-step!)
      (if (phase-playing? *st*)
          (begin
            (play-frame *st*)
            (set! *dirty* (quit-requested?)))
          (result-step!))
      ;; Settle once, whatever route the terminal state arrived by: it can
      ;; land inside the frame above, or already sit terminal at frame
      ;; entry (a scripted or restored match) — a route that used to skip
      ;; the settle entirely, so no best was recorded and no rung marked.
      (if (or (phase-over? *st*) (phase-won? *st*))
          (if *settled*
              #f
              (begin
                (set! *settled* #t)
                (set! *dirty* #t)
                (settle-match! *st*)))
          (set! *settled* #f)))

    ;; The key a live match answers, by phase: steering keys while it runs,
    ;; the onward keys once it is a result.
    (define (play-key! key)
      (cond
        ;; From a live match, escape pauses rather than leaves — a stray
        ;; keypress should cost a keypress, not a game.
        ((and (string=? key "escape") (phase-playing? *st*))
         (set! *st* (game-with *st* phase: (paused)))
         (sfx! "pause"))
        ;; A result is a decision point: onward, again, or out.
        ((or (phase-over? *st*) (phase-won? *st*))
         (cond ((string=? key "return")
                (if (phase-won? *st*)
                    (let ((next (next-challenge)))
                      (if next
                          (start-match! (challenge-mode next)
                                        (challenge-options next)
                                        'campaign next
                                        (level-key (campaign-id *campaign*)
                                                   (+ 1 *playing-index*))
                                        (+ 1 *playing-index*))
                          (show-screen! 'title (title-menu))))
                    (show-screen! 'title (title-menu))))
               ((string=? key "r")
                ;; The replay round trip: config -> name -> options -> config.
                ;; `config-mode->name` spells the name the *menus* use — a
                ;; string — but `start-match!` validates against the domain's
                ;; closed symbol set, so the name crosses back as a symbol.
                ;; A raw string here reads as an unknown mode and the guard
                ;; dumps the player at the title with only a console message.
                (start-match! (string->symbol (config-mode->name (game-config *st*)))
                              (config-options (game-config *st*))
                              *origin* *challenge* *playing-key* *playing-index*))
               ((string=? key "escape")
                (show-screen! 'title (title-menu))
                (sfx! "pause"))
               ((string=? key "q") (quit!))
               (else #f)))
        ;; A paused match: resume, replay, or leave.
        ((phase-paused? *st*)
         (cond ((string=? key "p")
                (set! *st* (game-with *st* phase: (playing)))
                (set! *dirty* #t)   ; back to the live picture at once
                (sfx! "pause"))
               ((string=? key "r")
                (set! *st* (ok-value (apply-command *st* (restart))))
                (set! *settled* #f)
                (sfx! "start"))
               ((string=? key "escape")
                (show-screen! 'title (title-menu))
                (sfx! "pause"))
               ((string=? key "q") (quit!))
               (else #f)))
        ;; A live match: the keymap owns it.
        (else
         (let ((cmd (key->command key)))
           (if cmd
               (let ((r (apply-command *st* cmd)))
                 (if (result-ok? r) (set! *st* (ok-value r)) #f)
                 (set! *dirty* #t))
               #f)))))

    (define (dispatch-key! key)
      (case *screen*
        ((title) (menu-key! key))
        ((campaign) (menu-key! key))
        ((mode) (menu-key! key))
        ((level) (menu-key-with-level! key))
        ((play) (play-key! key))
        (else #f)))

    ;; The host pumps key-repeat for held keys; the menus honor it for the
    ;; MOVEMENT keys only — a held RETURN must not start match after match,
    ;; and a held ESC must not fly back through every screen at once.
    (define (dispatch-repeat! key)
      (case *screen*
        ((title campaign mode)
         (if (or (string=? key "up") (string=? key "down"))
             (menu-key! key)
             #f))
        ((level)
         (if (member key '("left" "right" "up" "down"))
             (menu-key-with-level! key)
             #f))
        (else #f)))

    (define (menu-step!)
      (let ((dt (tick!))
            (evs (poll-events!)))
        (view-fx-step! dt *st*)
        (let loop ((rest evs))
          (if (null? rest)
              #f
              (let ((type (cadr (assq type: (car rest)))))
                (case type
                  ((quit) (quit!))
                  ((key-down)
                   (dispatch-key! (cadr (assq key: (car rest)))))
                  ((key-repeat)
                   (dispatch-repeat! (cadr (assq key: (car rest)))))
                  (else #f))
                (loop (cdr rest)))))
        (if (and *dirty* (not (eq? *screen* 'play)))
            (begin
              (draw-screen!)
              (set! *dirty* (quit-requested?)))
            ;; A pick started a match this frame: the screen is the match's
            ;; now, and the live path paints it — its `*dirty*` is still
            ;; set. Painting the menu shape here flashed one frame of
            ;; empty shell between the menus and the board.
            #f)))

    (define (arcade-step!)
      (if (eq? *screen* 'play)
          (play-step!)
          (menu-step!)))

    (define (arcade-main)
      (open-window! window-width window-height "Scheme Tetris — shs DSL")
      (boot!)
      (let loop ()
        (if (quit-requested?)
            (begin (quit!) #f)
            (begin
              (arcade-step!)
              (loop))))))

    ;; The host's boot config — the CLI as an alist: `((mode . "sprint")
    ;; (level . 5) (seed . 7) (ai . #t) (autostart . #t))`. A mode on the
    ;; command line starts a free-play match straight away; a bare autostart
    ;; boots into the classic marathon. `boot-config` is a host primitive
    ;; the smoke tests drive.
    (define (boot!)
      (let ((cfg (boot-config)))
        (define (opt k) (let ((e (assq k cfg))) (if e (cdr e) #f)))
        (let ((seed (opt 'seed))
              (mode (opt 'mode))
              (level (opt 'level))
              (ai (opt 'ai))
              (autostart (opt 'autostart)))
          (if seed (set! *seed* seed) #f)
          (if ai (set! *ai* #t) #f)
          (cond ((and autostart mode)
                 (set! *mode* (string->symbol mode))
                 (set! *level* (or level 1))
                 (start-match! *mode*
                               (list (list 'starting-level *level*))
                               'free #f #f #f))
                (autostart
                 ;; A bare --autostart is the classic marathon — but a
                 ;; --level next to it is still a wish the player made,
                 ;; not a flag to drop.
                 (start-match! 'marathon
                               (if level
                                   (list (list 'starting-level level))
                                   '())
                               'free #f #f #f))
                (else
                 (if mode
                     (begin
                       (display "--mode ignored without --autostart: ")
                       (display mode)
                       (newline))
                     #f)
                 (show-screen! 'title (title-menu)))))))

