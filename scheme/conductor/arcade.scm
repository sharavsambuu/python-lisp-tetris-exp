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
        (tetris duel) (tetris roster)
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
          ;; The host's --seed steers the FIRST match of the session and
          ;; then expires: a pinned seed is a test's handle and a replay
          ;; wish, never a session-long sentence — without this, every
          ;; match after the first re-dealt the same opening forever.
          (set! *seed* #f)
          (set! *st* (fresh-game seed: seed mode: mode-name options: options))
          (set! *origin* origin)
          (set! *challenge* challenge)
          (set! *playing-key* key)
          (set! *playing-index* index)
          (set! *dirty* #t)
          (set! *settled* #f)
          (set! *screen* 'play)
          (set! *director-last* 0)   ; the cooldown restarts with the match
          (set! *lock-count* 0)      ; the AI's piece key is per match
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
    ;;  The duel — the human's side and a persona's, one fight            ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The player is the left match; the persona drives the right through
    ;; the same one-ply search the solo AI runs (one AI at a time, so the
    ;; search state is shared; the weights, the placement budget — the
    ;; persona's speed knob — and the lock counter travel with the side).
    ;; The window re-opens wide for the fight and back for everything
    ;; else: two full-size wells do not fit 640, and the menus keep their
    ;; proven layout.

    (define *duel* #f)
    (define *persona* #f)
    (define *duel-paused* #f)
    ;; The leash — the duel director (stage 6). The probe is the
    ;; closeness gap between the sides; the actuators touch only the
    ;; AI's side: its placement budget (*r-throttle*, the persona's
    ;; speed knob's multiplier) and its gravity (*r-pace*). The band is
    ;; the persona's own knob unless the profile holds a tuned one —
    ;; the roster promised the leash, the memory remembers the tuning.
    (define *leash* #f)
    (define *r-throttle* 1)
    (define *r-pace* 1)
    (define *leash-last* 0)          ;; the duel clock of the last adjustment
    ;; Slower and quieter than the solo director (1000 ms, 0.05): visible
    ;; rubber-banding is the fastest way to kill a versus mode.
    (define *leash-cooldown* 2000)
    (define *leash-threshold* 0.03)

    (define (start-duel! persona)
      (guard (e (#t
                 (show-screen! 'title (title-menu))
                 (display "duel refused: ")
                 (display (describe-condition e))
                 (newline)))
        (set! *persona* persona)
        (set! *duel* (make-duel
                      (fresh-game seed: (or *seed* (new-seed))
                                  mode: 'marathon options: '())
                      (fresh-game seed: (new-seed)
                                  mode: 'marathon options: '())))
        ;; The same expiry as a solo match: --seed steers the first
        ;; duel's left side, then the session deals fresh again.
        (set! *seed* #f)
        (set! *r-lock-count* 0)
        (set! *lock-count* 0)
        (let* ((id (symbol->string (persona-id persona)))
               ;; The profile can be absent (a boot that refused every
               ;; document): a missing memory defaults the shelf, it
               ;; never refuses the fight.
               (leashes (if *profile*
                            (profile-ref *profile* "leashes" '())
                            '()))
               (entry (assoc id leashes))
               (band (if entry (cdr entry) (persona-band persona))))
          (set! *leash* (make-leash band: band))
          (set! *r-throttle* 1)
          (set! *r-pace* 1)
          (set! *leash-last* 0))
        (set! *duel-paused* #f)
        (set! *settled* #f)
        (set! *screen* 'duel)
        (set! *dirty* #t)
        (reset-ai!)
        (view-reset!)
        (open-window! duel-window-width window-height "Scheme Tetris — duel")
        (sfx! "start")))

    (define (close-duel!)
      (set! *duel* #f)
      (set! *persona* #f)
      (set! *duel-paused* #f)   ; a forfeit leaves the flag set otherwise
      (set! *leash* #f)
      (set! *r-throttle* 1)
      (set! *r-pace* 1)
      (open-window! window-width window-height "Scheme Tetris — shs DSL")
      (show-screen! 'title (title-menu)))

    ;; The player's keys, minus the ones the duel answers itself (the
    ;; pause, the quit) and the solo-only controls: the AI toggle
    ;; (`a`) resets the shared search state the persona is using, the
    ;; pacing director (`d`) belongs to free play, and restart (`r`)
    ;; would clear only the player's half while the opponent keeps
    ;; playing — and leave the leash's clock ahead of the fresh match,
    ;; so the duel director stops correcting. In the duel these keys
    ;; are inert; the steering keys are everything else.
    (define (duel-events st evs)
      (apply-events st
                    (srfi-1:filter
                     (lambda (ev)
                       (let ((type (cadr (assq type: ev))))
                         (case type
                           ((quit) #f)
                           ((key-down)
                            (let ((k (cadr (assq key: ev))))
                              (not (or (string=? k "escape")
                                       (string=? k "p")
                                       (string=? k "a")
                                       (string=? k "d")
                                       (string=? k "r")))))
                           (else #t))))
                     evs)))

    (define (duel-key! key)
      (cond ((and (not (duel-over? *duel*)) *duel-paused*)
             (cond ((string=? key "p")
                    ;; The painter reads the LEFT match's phase for its
                    ;; veil; the two pause flags move together or the
                    ;; paused duel paints as if it were still live.
                    (set! *duel*
                          (duel-with-left *duel*
                            (game-with (duel-left *duel*) phase: (playing))))
                    (set! *duel-paused* #f)
                    (set! *dirty* #t)
                    (sfx! "pause"))
                   ;; A forfeit is a loss: the fight happened, and the
                   ;; record keeps it. Force the left side's top-out, let
                   ;; the exchange decide, settle, leave.
                   ((string=? key "escape")
                    (set! *duel*
                          (duel-with-left *duel*
                            (game-with (duel-left *duel*) phase: (over))))
                    (set! *duel* (duel-exchange *duel*))
                    (settle-duel!)
                    (close-duel!))
                   ((string=? key "q") (quit!))
                   (else #f)))
            ((duel-over? *duel*)
             (cond ((or (string=? key "return") (string=? key "escape"))
                    ;; The result is final: a scripted or forced terminal
                    ;; state may reach frame entry before the frame's settle
                    ;; has run. Settle before the state disappears, or the
                    ;; record is lost on the way out.
                    (if *settled* #f (settle-duel!))
                    (close-duel!)
                    (sfx! "menu-select"))
                   ((string=? key "q") (quit!))
                   (else #f)))
            (else
             (cond ((or (string=? key "escape") (string=? key "p"))
                    (set! *duel*
                          (duel-with-left *duel*
                            (game-with (duel-left *duel*) phase: (paused))))
                    (set! *duel-paused* #t)
                    (set! *dirty* #t)
                    (sfx! "pause"))
                   ((string=? key "q") (quit!))
                   (else #f)))))

    ;; A decided duel writes its record once: the per-persona tally in the
    ;; profile, the ladder's advance on a win over the rung it points at,
    ;; and the result sound. The ladder is strict — the roster's order is
    ;; the order you face them.
    (define (settle-duel!)
      (set! *settled* #t)
      (set! *dirty* #t)
      (let ((won (eq? (duel-winner *duel*) 'left)))
        (if *profile*
            (let* ((id (symbol->string (persona-id *persona*)))
                   (records (profile-ref *profile* "records" '()))
                   (entry (assoc id records))
                   (old (if entry (cdr entry) '()))
                   (wins (profile-ref old "wins" 0))
                   (losses (profile-ref old "losses" 0))
                   (margin (profile-ref old "margin" 0))
                   (diff (- (game-lines (duel-left *duel*))
                            (game-lines (duel-right *duel*))))
                   (ladder (profile-ref *profile* "ladder" 0))
                   (rank (let loop ((ls (persona-ids)) (i 0))
                           (cond ((null? ls) 0)
                                 ((eq? (car ls) (persona-id *persona*)) i)
                                 (else (loop (cdr ls) (+ i 1)))))))
              (set! *profile*
                    (profile-set *profile* "records"
                                 (cons (cons id
                                             (list (cons "wins"
                                                         (if won (+ wins 1) wins))
                                                   (cons "losses"
                                                         (if won losses (+ losses 1)))
                                                   (cons "margin"
                                                         (if won (max margin diff) margin))))
                                       (srfi-1:filter
                                        (lambda (e) (not (equal? (car e) id)))
                                        records))))
              (if (and won (= rank ladder) (< ladder (length (persona-ids))))
                  (set! *profile* (profile-set *profile* "ladder" (+ ladder 1)))
                  #f)
              ;; The leash retunes itself, one step at a time: a win
              ;; tightens the band (a harder re-fight), a loss loosens
              ;; it — the homeostat's slow outer loop, across sessions.
              ;; The band is the only knob the outcome touches, and it
              ;; rides the profile's "leashes" shelf, so the tuning
              ;; survives the restart. Clamped: never zero, never loose
              ;; enough to stop caring.
              (let* ((old-band (leash-band *leash*))
                     (new-band (min 0.25
                                    (max 0.01
                                         (+ old-band
                                            (if won -0.01 0.01))))))
                (set! *profile*
                      (profile-set *profile* "leashes"
                                   (cons (cons id new-band)
                                         (srfi-1:filter
                                          (lambda (e)
                                            (not (equal? (car e) id)))
                                          (profile-ref *profile*
                                                       "leashes" '()))))))
              (profile-save!))
            #f)
        (sfx! (if won "victory" "over"))))

    ;; One leash step. The cooldown gates BEFORE the probe: the gap
    ;; costs two `pressure` reads (~17 ms measured — the interpreter's
    ;; cell walks), and the leash speaks at most twice a second, so
    ;; the reads ride the cadence instead of the frame. When the
    ;; cooldown expires and the change is under the threshold, the
    ;; clock still advances: a slow drift waits for the next tick of
    ;; the cadence, and the frames between stay free.
    (define (duel-direct!)
      (if (and *leash*
               (phase-playing? (duel-left *duel*))
               (phase-playing? (duel-right *duel*)))
          (let ((clock (game-clock (duel-left *duel*))))
            (if (>= (- clock *leash-last*) *leash-cooldown*)
                (let* ((gap (duel-gap (game-lines (duel-left *duel*))
                                      (game-lines (duel-right *duel*))
                                      (pressure (duel-left *duel*))
                                      (pressure (duel-right *duel*))))
                       (m (leash-throttle *leash* gap)))
                  (set! *leash-last* clock)
                  (if (>= (abs (- m *r-throttle*)) *leash-threshold*)
                      (begin
                        (set! *r-throttle* m)
                        (set! *r-pace* (leash-pace *leash* m)))
                      #f))
                #f))
          #f))

    ;; The result fact belongs to the settle: it plays the duel's one
    ;; game-over/victory sound. Awarding the same fact on the per-side rail
    ;; would speak it twice. Everything else — a command, a lock gravity
    ;; produced, a clear — is the rail's.
    (define (duel-awardable? ev)
      (variant-match ev
        ((game-over) #f)
        ((victory) #f)
        (else #t)))

    (define (duel-frame)
      (let* ((dt (tick!))
             (evs (poll-events!)))
        (view-fx-step! dt (duel-left *duel*))
        ;; Keys can LEAVE the fight (the result's RETURN/ESC, a pause's
        ;; forfeit), and `close-duel!` answers no duel at all. A poll may
        ;; carry several events, so the loop stops the moment the screen
        ;; changes — touching `*duel*` after that is the crash.
        (let loop ((rest evs))
          (if (or (null? rest) (not (eq? *screen* 'duel)))
              #f
              (begin
                (let ((type (cadr (assq type: (car rest)))))
                  (case type
                    ((quit) (quit!))
                    ((key-down)
                     (duel-key! (cadr (assq key: (car rest)))))
                    (else #f)))
                (loop (cdr rest)))))
        (if (not (eq? *screen* 'duel))
            #f
            (begin
              (if (and (not *duel-paused*) (not (duel-over? *duel*)))
                  (begin
                    ;; The player's keys land before this frame's gravity;
                    ;; the leash reads the gap and maybe re-budgets the AI;
                    ;; the persona's AI takes its one step at the throttled
                    ;; budget; then the world moves — both sides, whole dt,
                    ;; the AI's gravity carrying its handicap.
                    (duel-direct!)
                    (set! *duel*
                          (duel-with-left *duel*
                            (duel-events (duel-left *duel*) evs)))
                    (if (phase-playing? (duel-right *duel*))
                        (set! *duel*
                              (duel-with-right *duel*
                                (ai-step-match! (duel-right *duel*)
                                                (persona-weights *persona*)
                                                ;; The solo path triples its
                                                ;; budget when the future is
                                                ;; priced (160 scorings in ~9
                                                ;; frames); the duel must pay
                                                ;; the same triple or a slow
                                                ;; persona never finishes the
                                                ;; search before the piece
                                                ;; lands and falls straight.
                                                (min 3
                                                     (max 1
                                                          (quotient
                                                           (* (persona-speed *persona*)
                                                              *r-throttle*)
                                                           2)))
                                                *r-lock-count*)))
                        #f)
                    (set! *duel*
                          (duel-with-right *duel*
                            (game-with (duel-right *duel*) pace: *r-pace*)))
                    ;; Advance and exchange are separate calls on purpose:
                    ;; the edge reads both journals AFTER gravity has
                    ;; written this frame's locks and clears, but BEFORE
                    ;; the exchange drains them. A natural lock used to be
                    ;; drained in the same call that produced it, so it
                    ;; never reached the sound and beam rails.
                    (set! *duel* (duel-advance *duel* dt))
                    (duel-award! 'left
                                 (srfi-1:filter
                                  duel-awardable?
                                  (reverse (game-journal (duel-left *duel*)))))
                    (duel-award! 'right
                                 (srfi-1:filter
                                  duel-awardable?
                                  (reverse (game-journal (duel-right *duel*)))))
                    (set! *duel* (duel-exchange *duel*)))
                  #f)
              ;; Settle once, whatever route the terminal state arrived by:
              ;; it can land inside the frame above, or already sit decided
              ;; at frame entry — a route that must not skip the record.
              (if (and (duel-over? *duel*) (not *settled*))
                  (settle-duel!)
                  #f)
              (if (or *dirty*
                      ;; The world moved: a live duel repaints every frame —
                      ;; the right well falls and steers whether or not the
                      ;; player's side is animating, and a repaint gate that
                      ;; only watched the LEFT side's effects froze the
                      ;; opponent's board on screen between the player's own
                      ;; events. Cached boards make the frame cheap; the
                      ;; gate's job is only to spare the paused and decided
                      ;; screens.
                      (and (not *duel-paused*) (not (duel-over? *duel*)))
                      (view-busy? (duel-left *duel*)))
                  (begin
                    (draw-duel! *duel* *persona*)
                    (set! *dirty* #f))
                  #f)))))

    ;; ---------------------------------------------------------------- ;;
    ;;  The AI — plan (frame-budgeted), then steer one step                ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The search cannot clone the world, so the domain lends it pure probes
    ;; — `landing-row/hts` and `column-heights` — and the planner scores the
    ;; 40 placements from the *shape they would leave*, never rebuilding the
    ;; board. Even so the enumeration is more than one frame should pay at
    ;; once, so the search is a stepper: each call scores a few placements
    ;; and answers the symbol `pending` until it is done. The board's
    ;; settled columns do not move while a piece is airborne, so scoring
    ;; across frames is scoring the same board.
    ;;
    ;; The stepper has three phases. Pass A scores the forty placements of
    ;; the falling piece into a cached score vector. Pass B — the
    ;; lookahead, on unless `--no-lookahead` says otherwise — prices the
    ;; FUTURE: the top few candidates each get the next piece swept
    ;; against the board their placement would truly leave (clears
    ;; collapsed away), and the joint — the final two-piece board, priced
    ;; once in the heuristic's own currency — picks the plan. A candidate
    ;; whose own fall leaves little room (a low drop distance) skips
    ;; pass B — a piece about to land needs the fast 1-ply answer, not a
    ;; deep one. Selection reads the cached vectors, so killing one
    ;; candidate never re-scores another.

    (define *best-per-frame* 6)  ;; placements scored per call

    ;; The lookahead's knobs: how many top candidates get their future
    ;; priced, and how many rows of fall a piece needs before the future
    ;; is worth its budget.
    (define *ai-lookahead* #t)
    (define *lookahead-k* 2)
    (define *lookahead-floor* 6)

    (define *search-key* #f)     ;; piece key (lock count + kind) the search opened for
    (define *search-board* #f)   ;; the board identity the cache was read from
    (define *search-phase* 'sweep) ;; sweep | futures | done
    (define *search-i* 40)       ;; next placement index to score (40 = settled)
    (define *search-scores* #f)  ;; the pass-A score per placement (#f = refused)
    (define *search-hts* #f)     ;; the settled profile, as a vector
    (define *search-rows* 20)
    (define *search-shapes* #f)  ;; the four cell lists, one per rotation
    (define *search-shapes2* #f) ;; the same, for the NEXT piece (pass B)
    (define *search-bounds2* #f) ;; each next-shape's (dx-min . dx-max)
    (define *search-ply2?* #f)   ;; does this piece's future get priced?
    (define *search-dead* #f)    ;; placements steering proved unreachable
    (define *search-dead-stamp* 0)
    (define *search-cands-stamp* -1)
    (define *search-elite* '())  ;; the top-K indices selection reads
    (define *search-cands* '())  ;; elite indices still missing their future
    (define *search-p2-j* 0)     ;; next response index inside the head candidate
    (define *search-p2-best* #f) ;; the head candidate's best joint so far
    (define *search-futures* #f) ;; the joint score per elite index
    (define *search-profs* #f)   ;; each elite index's collapsed post-clear profile
    (define *search-holes1* #f)  ;; the holes each elite placement buried
    (define *search-attack1* #f) ;; the rows each elite placement completed

    (define (reset-ai!)
      (set! *search-key* #f)
      (set! *search-board* #f)
      (set! *search-phase* 'sweep)
      (set! *search-i* 40)
      (set! *search-scores* #f)
      (set! *search-hts* #f)
      (set! *search-rows* 20)
      (set! *search-shapes* #f)
      (set! *search-shapes2* #f)
      (set! *search-bounds2* #f)
      (set! *search-ply2?* #f)
      (set! *search-dead* #f)
      (set! *search-dead-stamp* 0)
      (set! *search-cands-stamp* -1)
      (set! *search-elite* '())
      (set! *search-cands* '())
      (set! *search-futures* #f)
      (set! *search-profs* #f)
      (set! *search-holes1* #f)
      (set! *search-attack1* #f)
      ;; The plan belongs to the piece it was made for. A toggle or a new
      ;; match must not inherit the last board's answer.
      (set! *plan-key* #f)
      (set! *plan-board* #f)
      (set! *plan-ready* #f)
      (set! *plan-slam?* #f)
      (set! *plan-x* 3)
      (set! *plan-rot* 0))

    (define (best-placement st ws budget locks)
      (if (not (game-active st))
          #f
          (let ((key (list locks (falling-name (game-active st)))))
            (when (or (not (equal? key *search-key*))
                      (not (eq? (game-board st) *search-board*)))
              (search-reset! st key))
            (when (and (eq? *search-phase* 'futures)
                       *search-ply2?*
                       (not *search-shapes2*))
              (build-next-shapes! st))
            ;; A death in the steering changed the dead list after the
            ;; candidates were picked: re-pick from the CACHED scores —
            ;; no placement is scored twice for a steering refusal — and
            ;; price any newcomer's future.
            (when (and (not (eq? *search-phase* 'sweep))
                       (not (= *search-dead-stamp* *search-cands-stamp*)))
              (pick-candidates!))
            (case *search-phase*
              ((sweep)
               (if (score-sweep! st ws budget)
                   (begin
                     (pick-candidates!)
                     (if (eq? *search-phase* 'done)
                         (finish!)
                         'pending))
                   'pending))
              ((futures)
               (if (eq? (price-futures! st ws budget) 'done)
                   (finish!)
                   'pending))
              (else (finish!))))))

    ;; A fresh piece (or a board moved under it): the search opens again.
    ;; The settled columns, the shapes, the score vector — read or built
    ;; once, not forty times a frame. Whether the future gets priced is
    ;; decided here, once: a piece already near its landing spends its
    ;; frames steering, not speculating.
    (define (search-reset! st key)
      (set! *search-i* 0)
      (set! *search-phase* 'sweep)
      (set! *search-scores* (make-vector 40 #f))
      (set! *search-dead* (make-vector 40 #f))
      (set! *search-dead-stamp* 0)
      (set! *search-futures* (make-vector 40 #f))
      (set! *search-profs* (make-vector 40 #f))
      (set! *search-holes1* (make-vector 40 #f))
      (set! *search-attack1* (make-vector 40 #f))
      (set! *search-elite* '())
      (set! *search-cands* '())
      (set! *search-shapes2* #f)
      (set! *search-bounds2* #f)
      (set! *search-hts* (column-heights (game-board st)))
      (set! *search-rows* matrix-height)
      (set! *search-shapes*
            (map (lambda (rot) (piece-cells (falling-name (game-active st)) rot))
                 (list 0 1 2 3)))
      (set! *search-ply2?*
            (and *ai-lookahead*
                 (>= (drop-distance st) *lookahead-floor*)))
      (set! *search-board* (game-board st))
      (set! *search-key* key))

    ;; Pass A: score placements into the vector until the budget is spent
    ;; (#f = still working) or the sweep is complete (#t). Refused and dead
    ;; placements cost only the crossing — they do not spend the budget.
    (define (score-sweep! st ws budget)
      (let loop ((scored 0) (i *search-i*))
        (cond ((>= i 40)
               (set! *search-i* i)
               #t)
              ((>= scored budget)
               (set! *search-i* i)
               #f)
              ((vector-ref *search-dead* i)
               (loop scored (+ i 1)))
              (else
               (let* ((rot (quotient i 10))
                      (x (remainder i 10))
                      (shape (list-ref *search-shapes* rot))
                      (p (game-active st))
                      ;; The heights form: the precondition still asks
                      ;; the real board (a wall kick can refuse a
                      ;; column), but the landing row reads off the
                      ;; cached columns — no per-row cell lists, no
                      ;; allocations, forty times a piece.
                      (ly (if (shape-fits-at? (game-board st)
                                              shape x (falling-y p))
                              (landing-row/hts shape x (falling-y p)
                                               *search-hts* *search-rows*)
                              #f)))
                 (if (not ly)
                     (loop scored (+ i 1))
                     (let ((score (placement-score ws *search-hts*
                                                   shape
                                                   x ly *search-rows*)))
                       (vector-set! *search-scores* i score)
                       (loop (+ scored 1) (+ i 1)))))))))

    ;; The board a candidate would truly leave, with the placement's own
    ;; ledger: the collapsed post-clear profile, the holes it buried, the
    ;; rows it completed. Built once per elite candidate, then cached —
    ;; the future's arithmetic reads all three.
    (define (candidate-profile i)
      (or (vector-ref *search-profs* i)
          (let* ((rot (quotient i 10))
                 (x (remainder i 10))
                 (shape (list-ref *search-shapes* rot))
                 (ly (landing-row/hts shape x 0 *search-hts* *search-rows*))
                 (raised (raised-profile *search-hts* shape x ly *search-rows*))
                 (prof (collapsed-profile raised
                                          (completed-rows *search-hts* raised))))
            (vector-set! *search-profs* i prof)
            (vector-set! *search-holes1* i
                         (new-holes *search-hts* shape x ly *search-rows*))
            (vector-set! *search-attack1* i
                         (completed-rows *search-hts* raised))
            prof)))

    ;; The future's judgment, in the heuristic's own currency: the FINAL
    ;; board — this placement's collapse carrying the response piece —
    ;; priced exactly as the planner prices a leaf, with this
    ;; placement's holes and clears carried into the ledger. Priced once,
    ;; on the true final board: the additive form (own score + response
    ;; score) double-counts the level reward and re-pays height the
    ;; placement already banked.
    (define (joint-score ws i shape2 x2 ly2)
      (let* ((prof (candidate-profile i))
             (raised2 (raised-profile prof shape2 x2 ly2 *search-rows*))
             (attack2 (completed-rows prof raised2))
             (final (collapsed-profile raised2 attack2))
             (holes2 (new-holes prof shape2 x2 ly2 *search-rows*)))
        (- (+ (* (w-cleared ws) (min-of final))
              (* (w-attack ws)
                 (+ (vector-ref *search-attack1* i) attack2)))
           (+ (* (w-holes ws)
                 (+ (vector-ref *search-holes1* i) holes2))
              (* (w-bumpiness ws) (bumpiness final))
              (* (w-wells ws) (wells-sum final *search-rows*))
              (* (w-roof ws) (roofline final))))))

    ;; The leaf the candidate alone leaves — the joint's answer when the
    ;; response piece has no legal placement anywhere. Same currency, so
    ;; a candidate with a priced future and one without compare fairly.
    (define (leaf-score ws i)
      (let ((prof (candidate-profile i)))
        (- (+ (* (w-cleared ws) (min-of prof))
              (* (w-attack ws) (vector-ref *search-attack1* i)))
           (+ (* (w-holes ws) (vector-ref *search-holes1* i))
              (* (w-bumpiness ws) (bumpiness prof))
              (* (w-wells ws) (wells-sum prof *search-rows*))
              (* (w-roof ws) (roofline prof))))))

    ;; The top-K scored, still-eligible placements, by score. Their
    ;; indices are the selection's domain; the ones without a priced
    ;; future become the pass-B work list.
    (define (pick-candidates!)
      (set! *search-cands-stamp* *search-dead-stamp*)
      (let extract ((n 0) (elite '()) (used '()))
        (if (or (>= n *lookahead-k*) (>= (length used) 40))
            (begin
              (set! *search-elite* (reverse elite))
              (if *search-ply2?*
                  (let ((work (filter (lambda (i)
                                        (not (vector-ref *search-futures* i)))
                                      (reverse elite))))
                    (set! *search-cands* work)
                    (set! *search-p2-j* 0)
                    (set! *search-p2-best* #f)
                    (set! *search-phase*
                          (if (null? work) 'done 'futures)))
                  (begin
                    (set! *search-cands* '())
                    (set! *search-phase* 'done))))
            (let scan ((i 0) (bi #f) (bs #f))
              (cond ((>= i 40)
                     (if bi
                         (extract (+ n 1) (cons bi elite) (cons bi used))
                         (begin
                           (set! *search-elite* (reverse elite))
                           (set! *search-cands* '())
                           (set! *search-phase* 'done))))
                    ((and (vector-ref *search-scores* i)
                          (not (vector-ref *search-dead* i))
                          (not (member i used))
                          (or (not bs)
                              (> (vector-ref *search-scores* i) bs)))
                     (scan (+ i 1) i (vector-ref *search-scores* i)))
                    (else (scan (+ i 1) bi bs)))))))

    ;; Pass B: the head candidate's joint, budgeted — the next piece's
    ;; forty placements swept against the candidate's collapsed profile,
    ;; each priced as the final board it would leave. Refused responses
    ;; (out of bounds, poking out of the well) cost only the crossing. A
    ;; candidate with NO legal response keeps its own leaf as the joint:
    ;; the future taught it nothing, and the comparison stays fair.
    (define (price-futures! st ws budget)
      (if (null? *search-cands*)
          'done
          (let ((i (car *search-cands*)))
            (let loop ((scored 0) (j *search-p2-j*))
              (cond ((>= j 40)
                     (vector-set! *search-futures* i
                                  (or *search-p2-best* (leaf-score ws i)))
                     (set! *search-cands* (cdr *search-cands*))
                     (set! *search-p2-j* 0)
                     (set! *search-p2-best* #f)
                     (if (null? *search-cands*) 'done 'pending))
                    ((>= scored budget)
                     (set! *search-p2-j* j)
                     'pending)
                    (else
                     (let* ((rot2 (quotient j 10))
                            (x2 (remainder j 10))
                            (bounds (list-ref *search-bounds2* rot2)))
                       (if (and (>= (+ x2 (car bounds)) 0)
                                (<= (+ x2 (cdr bounds))
                                    (- (vector-length *search-hts*) 1)))
                           (let* ((shape2 (list-ref *search-shapes2* rot2))
                                  (ly2 (landing-row/hts shape2 x2 0
                                                        (candidate-profile i)
                                                        *search-rows*)))
                             (if (< ly2 0)
                                 (loop scored (+ j 1))
                                 (let ((s2 (joint-score ws i shape2
                                                        x2 ly2)))
                                   (when (or (not *search-p2-best*)
                                             (> s2 *search-p2-best*))
                                     (set! *search-p2-best* s2))
                                   (loop (+ scored 1) (+ j 1)))))
                           (loop scored (+ j 1))))))))))

    ;; The plan. With the future priced, the best JOINT over the elite —
    ;; the final two-piece board each candidate leads to, priced once in
    ;; the heuristic's own currency. Without it, the best raw score,
    ;; exactly as the one-ply planner always chose. #f when nothing is
    ;; eligible: every placement refused or killed.
    (define (finish!)
      (let ((pick (if *search-ply2?*
                      (lambda (i) (vector-ref *search-futures* i))
                      (lambda (i) (vector-ref *search-scores* i)))))
        (let loop ((rest *search-elite*) (best #f))
          (if (null? rest)
              (if best (list (car best) (cadr best)) #f)
              (let* ((i (car rest))
                     (v (pick i)))
                (loop (cdr rest)
                      (if (or (not best) (> v (caddr best)))
                          (list (remainder i 10) (quotient i 10) v)
                          best)))))))

    ;; The next piece's shapes and their lateral bounds — pass B sweeps
    ;; them against pure profiles, so the bounds check is the planner's
    ;; own (the real board never sees the response piece).
    (define (build-next-shapes! st)
      (let ((n2 (car (bag-peek (game-bag st) 1))))
        (set! *search-shapes2*
              (map (lambda (rot) (piece-cells n2 rot)) (list 0 1 2 3)))
        (set! *search-bounds2*
              (map (lambda (shape)
                     (let loop ((cs shape) (lo 100) (hi -100))
                       (if (null? cs)
                           (cons lo hi)
                           (let ((dx (car (car cs))))
                             (loop (cdr cs) (min lo dx) (max hi dx))))))
                   *search-shapes2*))))

    ;; Plan state, then steering: one plan per piece, one command a frame.
    (define *plan-key* #f)
    (define *plan-board* #f)  ;; the board the ready plan was made for
    (define *plan-ready* #f)
    (define *plan-slam?* #f)  ;; no placement anywhere: end this piece
    (define *plan-x* 3)
    (define *plan-rot* 0)
    (define *lock-count* 0)   ;; edge-side counter, fed by the journal
    (define *r-lock-count* 0) ;; the duel's right side keeps its own

    ;; One step toward the plan. A rotation takes the SHORTER way around
    ;; (CW when that is within two steps, CCW otherwise) and tries the
    ;; other direction when the first refuses — a tight slot does not
    ;; care which way the hand came from. A refused step answers #f: the
    ;; caller kills the plan, it never hard-drops a healthy piece.
    ;;
    ;; The slides are QUIET (`loud: #f`): this is the machine's hand, and one
    ;; column a frame is a tick, not a gesture — the same rule the host's repeat
    ;; pump keeps for the player's held keys. The rotate and the slam keep their
    ;; voices: they are one-shot facts of this piece's life, and a watcher who
    ;; pressed `a` should hear the AI *decide*, not hear it *glide*.
    (define (steer-to st x rot)
      (let* ((p (game-active st))
             (px (falling-x p))
             (pr (falling-rot p)))
        (cond ((not (= pr rot))
               (let* ((dcw (modulo (- rot pr) 4))
                      (cw? (<= dcw 2)))
                 (let ((r (apply-command st
                                         (if cw? (rotate-cw) (rotate-ccw)))))
                   (if (result-ok? r)
                       (ok-value r)
                       (let ((r2 (apply-command st
                                                (if cw?
                                                    (rotate-ccw)
                                                    (rotate-cw)))))
                         (if (result-ok? r2) (ok-value r2) #f))))))
              ((< px x)
               (let ((r (apply-command st (right) loud: #f)))
                 (if (result-ok? r) (ok-value r) #f)))
              ((> px x)
               (let ((r (apply-command st (left) loud: #f)))
                 (if (result-ok? r) (ok-value r) #f)))
              (else (ai-drop st)))))

    (define (ai-drop st)
      (let ((r (apply-command st (hard-drop))))
        (if (result-ok? r) (ok-value r) st)))

    ;; The steering proved the plan's target unreachable from where
    ;; gravity has let the piece fall to (a ledge slid under it, a kick
    ;; refused). The target dies — skipped by every later selection for
    ;; this piece, without spending the score budget — and the search
    ;; re-plans around it. The old steering hard-dropped here instead:
    ;; the planner's right answer executed as a buried hole.
    (define (kill-plan!)
      (when *search-dead*
        (vector-set! *search-dead* (+ (* *plan-rot* 10) *plan-x*) #t)
        (set! *search-dead-stamp* (+ *search-dead-stamp* 1)))
      (set! *plan-ready* #f))

    ;; One AI step against an ARBITRARY match, answering the new match:
    ;; the solo path drives the player's board, the duel drives the
    ;; persona's. One AI runs at a time — the player is human in a duel —
    ;; so the search state above stays shared; the lock count and the
    ;; weights and the placement budget travel with the side.
    (define (best-1ply-score b hts rows name ws)
      (let ((sy spawn-y))
        (let rot-loop ((r 0) (best #f))
          (if (>= r 4)
              best
              (let ((shape (piece-cells name r)))
                (let x-loop ((xs '(2 5 7)) (best* best))
                  (if (null? xs)
                      (rot-loop (+ r 1) best*)
                      (let ((x (car xs)))
                        (if (not (shape-fits-at? b shape x sy))
                            (x-loop (cdr xs) best*)
                            (let* ((ly (landing-row/hts shape x sy hts rows))
                                   (sc (and ly (placement-score ws hts shape x ly rows)))
                                   (next-best (if (and sc (or (not best*) (> sc best*))) sc best*)))
                              (x-loop (cdr xs) next-best)))))))))))

    (define (ai-should-hold? st ws cur-best)
      (and (game-can-hold st)
           cur-best
           (< cur-best 0.5)
           *search-hts*
           (let ((alt (or (game-hold st) (car (bag-peek (game-bag st) 1)))))
             (and alt
                  (not (eq? alt (falling-name (game-active st))))
                  (let ((alt-best (best-1ply-score (game-board st)
                                                   *search-hts*
                                                   *search-rows*
                                                   alt
                                                   ws)))
                    (and alt-best (> alt-best (+ cur-best 1.5))))))))

    (define (ai-step-match! st ws budget locks)
      (let ((key (list locks
                       (if (game-active st) (falling-name (game-active st)) #f)))
            (held-now? #f))
        (when (or (not (equal? key *plan-key*))
                  (not (eq? (game-board st) *plan-board*)))
          (set! *plan-key* key)
          (set! *plan-board* (game-board st))
          (set! *plan-ready* #f)
          (set! *plan-slam?* #f))
        (when (not *plan-ready*)
          (let ((plan (best-placement st ws budget locks)))
            (when (not (eq? plan 'pending))
              (let* ((cur-idx (and plan (+ (* (cadr plan) 10) (car plan))))
                     (cur-best (and cur-idx (vector-ref *search-scores* cur-idx))))
                (if (ai-should-hold? st ws cur-best)
                    (set! held-now? #t)
                    ;; #f: every placement is refused or dead — the piece has
                    ;; nowhere good to go, and the fastest kind thing is the
                    ;; slam that brings the next one.
                    (if plan
                        (begin
                          (set! *plan-x* (car plan))
                          (set! *plan-rot* (cadr plan))
                          (set! *plan-ready* #t))
                        (set! *plan-slam?* #t)))))))
        (cond (held-now?
               (result-unwrap-or (apply-command st (hold-piece)) st))
              (*plan-slam?* (ai-drop st))
              (*plan-ready*
               (or (steer-to st *plan-x* *plan-rot*)
                   (begin (kill-plan!) st)))
              (else st))))

    (define (ai-step!)
      (when (and *ai* (phase-playing? *st*) (game-active *st*))
        ;; The lookahead's price is not wall time — the budget bounds the
        ;; frame either way — it is LATENCY: a plan that needs 160
        ;; scorings at 6 a frame lands ~27 frames into a piece's life,
        ;; and a race feels that. With the future priced, the solo AI
        ;; spends its budget three times as fast: the plan lands in ~9
        ;; frames — the one-ply plan's own cadence — for triple the
        ;; per-frame interpreter cost, which the frame budget has the
        ;; headroom for and the race cannot feel.
        (set! *st* (ai-step-match! *st* *weights*
                                   (if *ai-lookahead*
                                       (* 3 *best-per-frame*)
                                       *best-per-frame*)
                                   *lock-count*))))
    ;; One director step: read the pressure, ask the core for a pace, and
    ;; speak only when there is something to say — a change past the
    ;; threshold, after the cooldown. The decision is journaled like any
    ;; other fact, so a match's record carries the director's side of the
    ;; story too.
    ;; One director step. The cooldown gates BEFORE the probe — same
    ;; discipline as the duel's leash: the pressure read is a cell
    ;; walk, and the director speaks at most once a second, so the
    ;; read rides the cadence, not the frame.
    (define (direct! st)
      (if (>= (- (game-clock st) *director-last*) *director-cooldown*)
          (let ((m (director-pace *director-config* (pressure st))))
            (set! *director-last* (game-clock st))
            (if (>= (abs (- m (game-pace st))) 0.05)
                (with-event (game-with st pace: m) (paced m))
                st))
          st))

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
      (cond ((eq? *screen* 'play) (play-step!))
            ((eq? *screen* 'duel) (duel-frame))
            (else (menu-step!))))

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
              (locale (opt 'locale))
              (duel (opt 'duel)))
          (if seed (set! *seed* seed) #f)
          (if ai (set! *ai* #t) #f)
          (if director (set! *director* #t) #f)
          ;; The lookahead is on by default; the flag carried #f to turn
          ;; it off. assq, not opt: an absent key and a #f value must
          ;; not be the same answer here.
          (let ((entry (assq 'lookahead cfg)))
            (if entry (set! *ai-lookahead* (cdr entry)) #f))
          (if locale (set-locale! (string->symbol locale)) #f)
          (cond (duel
                 ;; A --duel persona name boots straight into the fight.
                 (let ((p (persona-by-id (string->symbol duel))))
                   (if p
                       (start-duel! p)
                       (begin
                         (display "unknown persona: ")
                         (display duel)
                         (newline)
                         (show-screen! 'title (title-menu))))))
                ((and autostart mode)
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
