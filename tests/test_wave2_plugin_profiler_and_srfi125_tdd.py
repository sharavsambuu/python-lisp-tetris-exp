"""Wave 2 TDD tests: R-01 --plugin CLI, R-03 measure_calls profiler, and (srfi 125) locale lookup."""

import os
from pathlib import Path
import subprocess
import sys

from shslisp import load_lisp, make_env, run

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"


def test_t21_shs_plugin_cli_installs_headless_pygame_host():
    env_vars = os.environ.copy()
    env_vars["SDL_VIDEODRIVER"] = "dummy"
    env_vars["SDL_AUDIODRIVER"] = "dummy"
    env_vars["PYTHONPATH"] = str(ROOT)

    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "shslisp",
            "--plugin",
            "host.pygame_host:install",
            "-e",
            "(autostart?)",
        ],
        cwd=str(ROOT),
        env=env_vars,
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip().splitlines()[-1] == "#f"


def test_t22_profile_scheme_returns_steps_and_call_counts():
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    import host.pygame_host as ph

    report = ph.profile_scheme(
        "(define (step-n n) (if (= n 0) 'ok (step-n (- n 1)))) (step-n 10)"
    )
    assert report["steps"] > 0
    assert "step-n" in report["counts"]
    assert report["counts"]["step-n"] == 11


def test_t23_locale_uses_srfi_125_hash_table_for_tr_lookup():
    locale_src = (SCHEME / "content" / "locale.scm").read_text(encoding="utf-8")
    assert "(srfi 125)" in locale_src
    assert "make-hash-table" in locale_src

    env = make_env(search_paths=[SCHEME])
    load_lisp(env, SCHEME / "content" / "locale.scm")
    run("(import (tetris locale))", env=env)

    assert run("(tr 'menu-quit)", env=env) == "Quit"
    assert run("(tr 'hud-hold)", env=env) == "HOLD"
    assert run("(tr 'hud-next)", env=env) == "NEXT"
    assert run("(set-locale! 'mn)", env=env) is True
    assert run("(tr 'menu-quit)", env=env) == "Гарах"
    assert run("(tr 'hud-hold)", env=env) == "ХАДГАЛАХ"
    assert run("(tr 'hud-next)", env=env) == "ДАРААХ"
    assert run("(tr 'menu-locked)", env=env) == "  [түгжээтэй]"
    assert run("(tr-fmt 'hud-target 12 40)", env=env) == "ЗОРИЛТ 12/40"
    assert run('(tr-or \'missing-key "fallback")', env=env) == "fallback"
