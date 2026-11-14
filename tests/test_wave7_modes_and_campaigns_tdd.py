"""Wave 7 TDD tests: survival & zen modes, dig-master & speed-demon campaigns."""

from pathlib import Path

from shslisp import load_lisp, make_env, run

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"


def _make_wave7_env():
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
        "content/campaign.scm",
        "content/locale.scm",
    ]:
        load_lisp(env, SCHEME / rel)
    return env


def test_t71_survival_and_zen_modes_are_registered_and_playable():
    env = _make_wave7_env()
    run("(import (tetris result) (tetris game) (tetris modes) (tetris commands) (tetris rules) (tetris locale))", env=env)

    names = run("(mode-names)", env=env)
    assert "survival" in [str(x) for x in names]
    assert "zen" in [str(x) for x in names]

    # Survival rises a garbage row after 8000ms
    run("(define gs (fresh-game seed: 1 mode: 'survival))", env=env)
    run("(define gs2 (ok-value (step-time gs 8000)))", env=env)
    assert run("(memq 'garbage (map tag-of (game-journal gs2)))", env=env) is not False

    # Zen mode never ends in game-over when hard-dropping repeatedly
    run(
        """
        (define gz
          (let loop ((s (fresh-game seed: 1 mode: 'zen)) (i 0))
            (if (>= i 45)
                s
                (loop (ok-value (apply-command s (hard-drop))) (+ i 1)))))
        """,
        env=env,
    )
    assert run("(phase-playing? gz)", env=env) is True

    # Mongolian labels exist
    run("(set-locale! 'mn)", env=env)
    assert run("(tr 'mode-survival)", env=env) == "тэсвэр"
    assert run("(tr 'mode-zen)", env=env) == "чөлөөт дадлага"


def test_t72_new_campaigns_dig_master_and_speed_demon_exist():
    env = _make_wave7_env()
    run("(import (tetris campaign) (tetris locale))", env=env)

    assert run('(campaign-id (campaign-by-id "dig-master"))', env=env) == "dig-master"
    assert run('(campaign-id (campaign-by-id "speed-demon"))', env=env) == "speed-demon"
    run("(set-locale! 'mn)", env=env)
    assert run("(tr 'campaign-dig-master)", env=env) == "Газар ухагч"
    assert run("(tr 'campaign-speed-demon)", env=env) == "Хурдны сорилт"
