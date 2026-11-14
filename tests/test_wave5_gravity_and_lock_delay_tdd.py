"""Wave 5 TDD tests: smoother gravity curve and 500ms lock delay."""

from pathlib import Path

from shslisp import load_lisp, make_env, run

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"


def _make_rules_env():
    env = make_env(search_paths=[SCHEME])
    for rel in [
        "core/rop.scm",
        "domain/geometry.scm",
        "domain/board.scm",
        "domain/bag.scm",
        "domain/modes.scm",
        "domain/game.scm",
        "rules/commands.scm",
        "rules/kicks.scm",
        "rules/scoring.scm",
        "policies/gravity.scm",
        "rules/pipeline.scm",
    ]:
        load_lisp(env, SCHEME / rel)
    return env


def test_t51_gravity_curve_is_smoother_while_preserving_endpoints():
    env = _make_rules_env()
    run("(import (tetris gravity))", env=env)
    assert run("(drop-interval 1)", env=env) == 900
    assert run("(drop-interval 999)", env=env) == 60
    # Level 10 should still give comfortable reaction time (> 350ms)
    assert run("(drop-interval 10)", env=env) > 350


def test_t52_grounded_piece_waits_500ms_lock_delay_before_locking():
    env = _make_rules_env()
    run(
        """
        (import (tetris result) (tetris game) (tetris modes)
                (tetris commands) (tetris rules))
        (define g0 (journal-drained (fresh-game seed: 1 mode: 'marathon)))
        ;; Drop piece until it touches the floor (drop-distance == 0)
        (define g-floor
          (journal-drained
           (let loop ((s g0))
             (if (= (drop-distance s) 0)
                 s
                 (loop (ok-value (step-time s 900)))))))
        """,
        env=env,
    )
    # After 250ms on the floor, piece is still active (same lock count = 0, no locked event)
    run("(define g-250 (ok-value (step-time g-floor 250)))", env=env)
    assert run("(null? (game-journal g-250))", env=env) is True
    assert run("(> (game-lock-ms g-250) 0)", env=env) is True

    # Shifting horizontally on the floor resets lock-ms to 0
    run("(define g-shifted (ok-value (apply-command g-250 (left))))", env=env)
    assert run("(= (game-lock-ms g-shifted) 0)", env=env) is True

    # Accumulating >= 500ms on the floor locks the piece
    run("(define g-500 (ok-value (step-time g-shifted 500)))", env=env)
    assert run("(memq 'locked (map tag-of (game-journal g-500)))", env=env) is not False
