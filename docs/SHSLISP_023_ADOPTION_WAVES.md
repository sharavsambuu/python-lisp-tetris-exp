# `shslisp 0.2.3` Adoption Waves

This document tracks the wave-based adoption of `shslisp 0.2.3` features across `python-lisp-tetris-exp`.

## Wave 1 — Stdlib Cleanup & Host Error Tracebacks
- **T1.1 (`(srfi 152)`)**: Replace duplicated `join-with` helpers in `scheme/content/campaign.scm` and `scheme/domain/modes.scm` with `(import (srfi 152))` and `string-join`.
- **T1.2 (`(srfi 28)`)**: Import `(srfi 28)` (`format`) in `scheme/domain/modes.scm`, `scheme/content/campaign.scm`, and `scheme/conductor/screens.scm` to simplify multi-part `(string-append ... (number->string ...))` formatting.
- **T1.3 (`R-02` Tracebacks)**: Catch `LispError` in `host/pygame_host.py::main`, print `exc.format_traceback()` to `sys.stderr`, and exit with code `1` instead of leaking a Python stack trace.

## Wave 2 — Plugin CLI (`R-01`), Call Profiler (`R-03`), & `(srfi 125)` Lookup
- **T2.1 (`R-01` Plugin Entry)**: Expose `install(env)` in `host/pygame_host.py` (configuring a headless `PygameHost(headless=True)`) so `shs --plugin host.pygame_host:install` works directly for REPLs and headless scripts.
- **T2.2 (`R-03` Profiler)**: Add a `measure_calls` profiling helper in `host/pygame_host.py` (or `tests/`) to measure `(steps, counts)` on hot paths such as full-board rendering and AI planning.
- **T2.3 (`(srfi 125)`)**: Replace linear `assq` translation table `*lookup*` in `scheme/content/locale.scm` with a `(srfi 125)` hash table (`eq?` comparator) for O(1) `tr` lookups.

## Wave 3 — Standard `(srfi 64)` Test Runner
- **T3.1 (`(srfi 64)`)**: Back `tests/scm/testkit.scm` with `(srfi 64)` (`test-begin`, `test-end`, `test-assert`, `test-runner-current`, `test-runner-simple`) so all Scheme test suites report through the standard SRFI-64 runner while preserving existing suite contracts.

## Wave 4 — Documentation & Tutorial Alignment
- **T4.1 (Docs & Tutorials)**: Update `README.md`, `tests/README.md`, `docs/tutorial/README.md`, and tutorials `01`, `04`, `09`, `12`, `13` to reflect `(srfi 28)`, `(srfi 64)`, `(srfi 125)`, `(srfi 152)`, `host.pygame_host:install`, `LispError.format_traceback()`, and `profile_scheme()` (`measure_calls`).
