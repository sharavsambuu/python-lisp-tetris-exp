;;; conductor/arcade.scm — the conductor: session state, match lifecycle,
;;; the AI, the loop.
;;;
;;; Like the view, this file speaks to the host (the window, the clock, the
;;; event pump, the speaker), so it lives at top level, outside the library
;;; fence. The pure contexts it drives are the libraries under ``domain/``,
;;; ``rules/`` and ``content/`` — the conductor may call them; they may not
;;; know it.
;;;
;;; The conductor is four files, one shared interaction environment, loaded
;;; in this order (cross-file calls resolve at run time):
;;;
;;;   conductor/effects.scm   the journal drain: sounds and screen effects
;;;   conductor/screens.scm   the menu values, the screens, the menu input
;;;   conductor/input.scm     the key dispatch: events, keys, repeats
;;;   conductor/arcade.scm    this file — the state they all share, the
;;;                           match lifecycle, the AI, the frame loop
;;;
;;; The product around one match, campaign-first with free play kept:
;;;
;;;   title ──enter──▶ campaign ──enter──▶ play      (a level ladder)
;;;     └────enter──▶ mode ──enter──▶ level ──enter──▶ play   ("Free play")
;;;
;;; Escape means "back one step" (screens.scm); from a live match it *pauses*
;;; instead, so leaving a match takes a second escape. The AI lives here —
;;; its pure arithmetic is ``(tetris plan)``, its frame-budgeted search and
;;; its steering are edge code, because a plan that costs frames is a
;;; scheduling decision.
;;;
;;; Public names: arcade-main.
(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
        (srfi 26)
        (srfi 88)
        (tetris result)
        (tetris geometry) (tetris board) (tetris bag) (tetris modes) (tetris game)
        (tetris plan) (tetris telemetry) (tetris director) (tetris campaign) (tetris locale)
        (tetris commands) (tetris gravity) (tetris rules))
  (begin
    ;; ---------------------------------------------------------------- ;;
    ;;  The session — the edge's own state, never inside a match record    ;;
    ;; ---------------------------------------------------------------- ;;

    (define *screen* 'title)   ;; title | campaign | mode | level | play
    ;; The raw menu shape — `(entries cursor)` — until boot! builds the real
    ;; one (make-menu lives in screens.scm; the conductor's files share one
    ;; interaction environment).
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
    ;; Five dials now: attack prices the rows a placement completes — the
    ;; term the roster's personas lean on. A persona's weights replace
    ;; this value wholesale when the versus screens arrive (stage 5).
    (define *weights* (weights 2.0 2.5 0.5 0.6 1.0))

    ;; The director the "D" key turns on. Its decision core is the pure
    ;; arithmetic of (tetris director); the edge owns the loop around it —
    ;; on/off, the knobs, and the cooldown memory (the clock reading of
    ;; the last adjustment, so the pace speaks slowly, not every frame).
    (define *director* #f)
    (define *director-config* (make-director))
    (define *director-last* 0)
    (define *director-cooldown* 1000)  ;; ms of match clock between adjustments
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
          (set! *director-last* 0)   ; the cooldown restarts with the match
          (reset-ai!)
          (view-reset!)
          (sfx! "start"))))

    (define (describe-condition e)
      ;; A raised condition is a list of irritants, or an error object —
      ;; both render as the message the player can act on.
      (cond ((list? e) (join " " (map ->text e)))
            ((error-object? e) (error-object-message e))
            (else (->text e))))
    ;; A finished match: free play records a best, a campaign level marks
    ;; its rung done. Both are edge state — the match record stays a value.
    (define (settle-match! st)
      (let ((label (mode-label (game-config st))))
        ;; The best is FREE PLAY's scoreboard: a campaign's score is the
        ;; rung's, and recording it here leaked ladder wins (and ladder
        ;; losses) into the mode list the title decorates.
        (if (eq? *origin* 'free)
            (let ((prev (best-for *bests* label)))
              (set! *bests* (record-best *bests* label (game-score st)))
              ;; A beaten best is worth a moment: the result overlay wears
              ;; its badge, and the speaker has its own little fanfare.
              (if (and (> (game-score st) 0) (> (game-score st) prev))
                  (begin (view-new-best!) (sfx! "record"))
                  #f))
            #f)
        (if (and (eq? *origin* 'campaign)
                 *playing-key*
                 (phase-won? st))
            (begin
              (set! *done* (mark-done *done* *playing-key*))
              #t)
            #f)
        ;; The settle is the save point: the outcome is final, so the
        ;; disk is worth exactly one write.
        (profile-sync-progress!)
        (profile-save!)))

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
    ;; One director step: read the pressure, ask the core for a pace, and
    ;; speak only when there is something to say — a change past the
    ;; threshold, after the cooldown. The decision is journaled like any
    ;; other fact, so a match's record carries the director's side of the
    ;; story too.
    (define (direct! st)
      (let ((m (director-pace *director-config* (pressure st))))
        (if (and (>= (- (game-clock st) *director-last*) *director-cooldown*)
                 (>= (abs (- m (game-pace st))) 0.05))
            (begin
              (set! *director-last* (game-clock st))
              (with-event (game-with st pace: m) (paced m)))
            st)))

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
        (when *director* (set! *st* (direct! *st*)))
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

    ;; Gravity is silent by design: a fall journals nothing, or the speaker
    ;; would blip once per tick — so the journal cannot tell the paint gate
    ;; that the world moved while the player idled. Time moved the *visible*
    ;; world when the active piece changed (it fell, or a lock spawned the
    ;; next shape) or the clock crossed a whole second (the ultra's HUD
    ;; counts in them). Everything else time can cause — a lock, a clear, a
    ;; victory — journals, and the journal check upstream catches it.
    (define (piece-fields p)
      (if p
          (list (falling-name p) (falling-x p) (falling-y p) (falling-rot p))
          '()))

    ;; step-time answers a Result; the loop lives below the railway, so this
    ;; little stair takes it down: state, plus whether time changed anything
    ;; the screen could show.
    (define (step-time-v st dt)
      (let ((r (step-time st dt)))
        (if (result-ok? r)
            (let ((st* (ok-value r)))
              (values st*
                      (or (not (equal? (piece-fields (game-active st))
                                       (piece-fields (game-active st*))))
                          (not (= (quotient (game-clock st) 1000)
                                  (quotient (game-clock st*) 1000))))))
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
            (begin (profile-save!) (quit!) #f)
            (begin
              (arcade-step!)
              (loop))))))

    ;; The host's boot config — the CLI as an alist: `((mode . "sprint")
    ;; (level . 5) (seed . 7) (ai . #t) (autostart . #t) (locale . "mn"))`.
    ;; A mode on the command line starts a free-play match straight away; a
    ;; bare autostart boots into the classic marathon; a locale starts the
    ;; session in that language (the menu setting can change it after).
    ;; `boot-config` is a host primitive the smoke tests drive.
    (define (boot!)
      ;; The memory loads first: the profile restores the session's
      ;; progress. A locale on the command line still wins over the
      ;; saved one — a flag is a wish the player made just now.
      (profile-load!)
      (let ((cfg (boot-config)))
        (define (opt k) (let ((e (assq k cfg))) (if e (cdr e) #f)))
        (let ((seed (opt 'seed))
              (mode (opt 'mode))
              (level (opt 'level))
              (ai (opt 'ai))
              (director (opt 'director))
              (autostart (opt 'autostart))
              (locale (opt 'locale)))
          (if seed (set! *seed* seed) #f)
          (if ai (set! *ai* #t) #f)
          (if director (set! *director* #t) #f)
          (if locale (set-locale! (string->symbol locale)) #f)
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
