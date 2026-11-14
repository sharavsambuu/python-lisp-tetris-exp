"""Wave 3 TDD tests: (srfi 64) backing for tests/scm/testkit.scm."""

from pathlib import Path

import pytest

from shslisp import load_lisp, make_env, run
from shslisp.errors import LispError

ROOT = Path(__file__).resolve().parent.parent
TESTS_SCM = ROOT / "tests" / "scm"


def test_t31_testkit_uses_srfi_64_runner():
    src = (TESTS_SCM / "testkit.scm").read_text(encoding="utf-8")
    assert "(srfi 64)" in src
    assert "test-assert" in src
    assert "test-begin" in src
    assert "test-end" in src

    env = make_env(search_paths=[TESTS_SCM])
    load_lisp(env, TESTS_SCM / "testkit.scm")

    run('(tk-reset!) (tk-record! "ok-1" #t 1 1) (tk-report! "wave3-pass")', env=env)

    with pytest.raises(LispError):
        run(
            '(tk-reset!) (tk-record! "bad-1" #f 2 1) (tk-report! "wave3-fail")',
            env=env,
        )
