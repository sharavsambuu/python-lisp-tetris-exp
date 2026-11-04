;;; conductor/input.scm — the key dispatch: events, keys, repeats.
;;;
;;; An edge module, like the rest of the conductor. The host pumps events;
;;; this file decides what each one means. Two doors:
;;;
;;; * `apply-event` — a polled event against a LIVE match: state in, state
;;;   out, held-key state left in the host. The repeats it honors are the
;;;   ones `repeat-able` allows (the host owns the repeat clock; see
;;;   policies/gravity.scm for the division of the feel).
;;; * `play-key!` / `dispatch-key!` — a keypress at a *decision point* (a
;;;   paused or finished match, or any menu screen), dispatched by screen.
;;;
;;; Match lifecycle calls (`start-match!`, `next-challenge`, `reset-ai!`)
;;; and the session state live in arcade.scm; the screens and their menus
;;; live in screens.scm — resolved at run time, one shared environment.

(import (scheme base)
        (srfi 88)
        (tetris result)
        (tetris game)
        (tetris modes)
        (tetris commands)
        (tetris campaign)
        (tetris rules))

(begin
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

    ;; A command's answer, taken down off the railway: the new state, or the old
    ;; one — voiced. The refusal is data the pipeline refused to act on, and the
    ;; edge still owes the player an answer; effects.scm owns which refusals are
    ;; worth a sound (a wall is not).
    ;;
    ;; A successful command also *repaints*. That is not tidiness: a repeat is
    ;; silent now (see the repeat arm below), so the journal can no longer be
    ;; the paint gate's only witness to a glide — the very trap chapter 16
    ;; names, one channel over (silence in the speaker forced a spokesman in
    ;; the paint gate, and the idle piece froze). The spokesman is `*dirty*`.
    (define (command-outcome r fallback)
      (if (result-ok? r)
          (begin (set! *dirty* #t) (ok-value r))
          (begin (refusal-sfx! r) fallback)))

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
                (sfx! "menu-move")
                (set! *dirty* #t)   ; the toggle must show at once
                st)
               ((string=? key "d")
                (set! *director* (not *director*))
                (set! *director-last* 0)   ; a fresh turn of the cooldown
                (sfx! "menu-move")
                (set! *dirty* #t)   ; the toggle must show at once
                st)
               ((string=? key "g")
                (show-ghost! (not (show-ghost?)))
                (sfx! "menu-move")
                (set! *dirty* #t)   ; the ghost must show at once
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
                      (command-outcome (apply-command st cmd) st)
                      st))))))
          ((key-repeat)
           ;; The host says a key is still down. Only the repeatable
           ;; commands glide, and a repeat is the pump's *tick*, not a moment:
           ;; the move happens and the wage is paid, but nothing is journaled
           ;; (a blip every 40ms is a buzz, not feedback — the press already
           ;; spoke, and the paint gate has its own spokesman now).
           (let ((key (cadr (assq key: ev))))
             (if (member key repeat-able)
                 (let ((cmd (key->command key)))
                   (if cmd
                       (command-outcome (apply-command st cmd loud: #f) st)
                       st))
                 st)))
          (else st))))

    (define (apply-events st evs)
      (if (null? evs)
          st
          (apply-events (apply-event st (car evs)) (cdr evs))))
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
                ;; The replay's own `(restarted)` fact is the sound: the drain
                ;; speaks it on the frame the fresh match first paints. Asking
                ;; for a blip here as well rang "start" twice for one press.
                (set! *st* (ok-value (apply-command *st* (restart))))
                (set! *settled* #f))
               ((string=? key "escape")
                (show-screen! 'title (title-menu))
                (sfx! "pause"))
               ((string=? key "q") (quit!))
               (else #f)))
        ;; A live match: the keymap owns it.
        (else
         (let ((cmd (key->command key)))
           (if cmd
               (begin
                 (set! *st* (command-outcome (apply-command *st* cmd) *st*))
                 (set! *dirty* #t))
               #f)))))

    (define (dispatch-key! key)
      (case *screen*
        ((title) (menu-key! key))
        ((campaign) (menu-key! key))
        ((versus) (menu-key! key))
        ((mode) (menu-key! key))
        ((level) (menu-key-with-level! key))
        ((play) (play-key! key))
        ((duel) (duel-key! key))
        (else #f)))

    ;; The host pumps key-repeat for held keys; the menus honor it for the
    ;; MOVEMENT keys only — a held RETURN must not start match after match,
    ;; and a held ESC must not fly back through every screen at once.
    (define (dispatch-repeat! key)
      (case *screen*
        ((title campaign versus mode)
         (if (or (string=? key "up") (string=? key "down"))
             (menu-key! key)
             #f))
        ((level)
         (if (member key '("left" "right" "up" "down"))
             (menu-key-with-level! key)
             #f))
        (else #f)))
)
