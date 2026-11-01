;;; rules/commands.scm — (tetris commands)
;;;
;;; The published language between the player and the rules: what a hand (or a
;;; script, or an AI) may ask a game to do. The set is closed and declared, so
;;; a transition that forgot a command is a named error, not a silent fall
;;; through.
;;;
;;; The keymap lives here too, because a keymap is just the vocabulary's
;;; spelling. It is written as an SRFI 241 match over the host's key names —
;;; string patterns match by equal?, so the table reads as data and an
;;; unmapped key answers #f (the conductor counts that as "not ours").

(define-library (tetris commands)
  (import (scheme base))
  (export command?
          left
          right
          down
          rotate-cw
          rotate-ccw
          hard-drop
          hold-piece
          restart
          command-name
          key->command
          command->key)

  (begin
    (define-variant command
      (left)
      (right)
      (down)
      (rotate-cw)
      (rotate-ccw)
      (hard-drop)
      (hold-piece)
      (restart))

    (define (command-name c)
      (variant-match c
        ((left) "left")
        ((right) "right")
        ((down) "down")
        ((rotate-cw) "rotate-cw")
        ((rotate-ccw) "rotate-ccw")
        ((hard-drop) "hard-drop")
        ((hold-piece) "hold")
        ((restart) "restart")
        (else "unknown")))

    ;; Host key name -> command, or #f when the key is not the game's. The
    ;; patterns are string literals (matched by equal?) and the catch-all is
    ;; SRFI 241's `,_` — a bare `_` would be a constant, matched by name.
    (define (key->command key)
      (match key
        ("left" (left))
        ("right" (right))
        ("down" (down))
        ("up" (rotate-cw))
        ("x" (rotate-cw))
        ("z" (rotate-ccw))
        ("space" (hard-drop))
        ("c" (hold-piece))
        ("r" (restart))
        (,_ #f)))

    ;; The inverse map, for the controls hint on the play screen: each row is
    ;; (key label). The *screen* keys (menu navigation, the AI and ghost
    ;; toggles) are the conductor's vocabulary, but a control table is one
    ;; table, wherever the keys are dispatched.
    (define command->key
      '(("left/right" "move")
        ("down" "soft drop")
        ("up / x" "rotate cw")
        ("z" "rotate ccw")
        ("space" "hard drop")
        ("c" "hold")
        ("p" "pause")
        ("a" "AI on/off")
        ("g" "ghost on/off")
        ("r" "restart")
        ("return" "select")
        ("esc" "back / menu"))))
)
