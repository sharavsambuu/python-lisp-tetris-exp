;;; conductor/screens.scm — the menu values, the screens, the menu input.
;;;
;;; An edge module, like the rest of the conductor: the screens paint through
;;; the view and the host, and the menus speak the locale. The *content* —
;;; the campaigns and the challenges they are built from — is data in
;;; ``(tetris campaign)``; a new campaign is a diff to a list, not to this
;;; file.
;;;
;;; Three layers, top to bottom:
;;;
;;; * the menu *value* — a cursor over labelled choices, functional on
;;;   purpose (`menu-move` answers a new menu);
;;; * the screens — which menu each screen shows, and how it paints;
;;; * the menu input — what a key means on each screen. The shell's whole
;;;   decision table is `choose!`.
;;;
;;; A level selection ends in one call, `(start-match! ...)` — defined in
;;; arcade.scm, resolved at run time (the conductor's files share one
;;; interaction environment). Escape means "back one step"; `back!` is the
;;; whole of that rule.

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (srfi 88)
        (tetris campaign)
        (tetris locale)
        (tetris modes))

(begin
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
    ;;  The screens                                                        ;;
    ;; ---------------------------------------------------------------- ;;

    ;; Content translates at the edge by its id: the campaign/challenge
    ;; libraries stay locale-blind, and the locale map owns the spellings.
    ;; `tr-or` answers the content's own string until a translation lands.
    (define (campaign-title-tr c)
      (tr-or (string->symbol (string-append "campaign-"
                                            (campaign-id c)))
             (campaign-title c)))
    (define (challenge-title-tr ch)
      (tr-or (string->symbol (string-append "challenge-"
                                            (challenge-id ch)))
             (challenge-title ch)))
    (define (challenge-goal-tr ch)
      (tr-or (string->symbol (string-append "goal-"
                                            (challenge-id ch)))
             (challenge-goal ch)))
    ;; A mode *symbol* ("free play picked sprint") in the locale's spelling.
    (define (mode-name-tr m)
      (tr-or (string->symbol (string-append "mode-" (symbol->string m)))
             (symbol->string m)))

    ;; The title: the campaigns, free play, the language setting, and the
    ;; door out. The label decoration is a level count, read from the
    ;; content; the language row's label re-reads the live locale, so the
    ;; menu itself speaks the language it is about to switch to.
    (define (title-menu)
      (make-menu
       (append
        (map (lambda (c)
               (list (string-append (campaign-title-tr c)
                                    "  ("
                                    (number->string
                                     (length (campaign-levels c)))
                                    " "
                                    (tr 'menu-levels-word)
                                    ")")
                     (cons 'campaign c)))
             (campaigns))
        (list (list (tr 'menu-free-play) '(free-play))
              (list (string-append (tr 'menu-language)
                                   ": "
                                   (locale-label (current-locale)))
                    '(language))
              (list (tr 'menu-quit) '(quit))))))

    ;; The campaign ladder: each rung shows its title, and a checkmark when
    ;; this session has already won it.
    (define (campaign-menu camp)
      (make-menu
       (map (lambda (ch i)
              (let ((key (level-key (campaign-id camp) i)))
                (list (string-append (number->string i) ". "
                                     (challenge-title-tr ch)
                                     (if (level-done? *done* key)
                                         (tr 'menu-done-mark)
                                         ""))
                      (cons 'challenge ch))))
            (campaign-levels camp)
            (iota (length (campaign-levels camp)) 1))))

    ;; Free play: the four ways to play, in the locale's spelling, with the
    ;; session's best beside the one that has one. The values are the mode
    ;; *symbols* the domain's config-from spells; the BESTS TABLE stays
    ;; keyed by the domain's English label, so a locale switch cannot
    ;; orphan a score.
    (define (mode-menu)
      (make-menu
       (map (lambda (m)
              (let ((best (best-for *bests* (symbol->string m))))
                (list (if (> best 0)
                          (string-append (mode-name-tr m)
                                         "  "
                                         (tr 'menu-best)
                                         " "
                                         (number->string best))
                          (mode-name-tr m))
                      (cons 'mode m))))
            (mode-names))))

    ;; The level picker: one entry, moved with the arrows — the *value* is
    ;; the number itself, so the label and the truth cannot drift apart.
    (define (level-menu)
      (make-menu (list (list (tr-fmt 'menu-level-n *level*)
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
         (menu-overlay *menu* "SCHEME TETRIS" (tr 'hint-title)))
        ((campaign)
         (menu-overlay *menu*
                       (campaign-title-tr *campaign*)
                       (string-append (challenge-goal-tr
                                       (cdr (menu-selected *menu*)))
                                      "   "
                                      (tr 'hint-esc-back))))
        ((mode)
         (menu-overlay *menu* (tr 'title-free-play) (tr 'hint-mode)))
        ((level)
         (menu-overlay *menu*
                       (string-append (tr 'title-starting-level)
                                      " — "
                                      (mode-name-tr *mode*))
                       (tr 'hint-level)))
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
          ((language)
           ;; The setting IS the entry: RETURN cycles the locale, the menu
           ;; rebuilds (its labels are now in the new locale), and the
           ;; cursor stays on the language row so a second RETURN cycles
           ;; back. `menu-set` clamps, so the rebuild cannot walk the
           ;; cursor off the end.
           (cycle-locale!)
           (profile-record-locale!)
           (set! *menu* (menu-set (make-menu (menu-entries (title-menu)))
                                  (menu-cursor *menu*)))
           (sfx! "menu-move")
           (set! *dirty* #t))
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
)
