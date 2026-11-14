"""Wave 1 TDD tests: (srfi 152), (srfi 28), and LispError.format_traceback()."""

from pathlib import Path
import sys

import pytest

from shslisp import load_lisp, make_env, run
from shslisp.errors import LispError

ROOT = Path(__file__).resolve().parent.parent
SCHEME = ROOT / "scheme"


def _make_domain_env():
    env = make_env(search_paths=[SCHEME])
    load_lisp(env, SCHEME / "domain" / "geometry.scm")
    load_lisp(env, SCHEME / "domain" / "board.scm")
    load_lisp(env, SCHEME / "domain" / "modes.scm")
    load_lisp(env, SCHEME / "content" / "campaign.scm")
    return env


def test_t11_modes_and_campaign_use_srfi_152_instead_of_join_with():
    modes_src = (SCHEME / "domain" / "modes.scm").read_text(encoding="utf-8")
    campaign_src = (SCHEME / "content" / "campaign.scm").read_text(encoding="utf-8")

    assert "(srfi 152)" in modes_src
    assert "(srfi 152)" in campaign_src
    assert "(define (join-with" not in modes_src
    assert "(define (join-with" not in campaign_src

    env = _make_domain_env()
    run("(import (tetris modes) (tetris campaign))", env=env)
    err = run("(guard (e (#t e)) (config-from 'bogus '()))", env=env)
    assert err[0] == "unknown mode"
    assert "marathon, sprint, ultra, cheese" in err[2]
    assert run('(level-key "ascent" 3)', env=env) == "ascent:3"


def test_t12_modes_and_screens_use_srfi_28_format():
    modes_src = (SCHEME / "domain" / "modes.scm").read_text(encoding="utf-8")
    screens_src = (SCHEME / "conductor" / "screens.scm").read_text(encoding="utf-8")
    campaign_src = (SCHEME / "content" / "campaign.scm").read_text(encoding="utf-8")

    assert "(srfi 28)" in modes_src
    assert "(srfi 28)" in screens_src
    assert "(srfi 28)" in campaign_src

    env = _make_domain_env()
    run("(import (tetris modes))", env=env)
    err = run("(guard (e (#t e)) (config-from 'marathon '((starting-level 1000))))", env=env)
    assert err[0] == "mode option out of range"
    assert err[2] == "between 1 and 999"


def test_t13_pygame_host_main_prints_lisp_traceback_and_returns_1(monkeypatch, capsys):
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    import host.pygame_host as ph

    def _boom(env, path):
        run("(define (inner-fail) (/ 1 0)) (define (outer-fail) (inner-fail)) (outer-fail)", env=env)

    monkeypatch.setattr("shslisp.load_lisp", _boom)
    rc = ph.main(["--headless", "--frames", "1"])
    captured = capsys.readouterr()

    assert rc == 1
    assert "Scheme traceback" in captured.err
    assert "division by zero" in captured.err.lower()
