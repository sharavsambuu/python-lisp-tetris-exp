# Chapter 24 — Debugging, profiling, and the plugin seam

> **Where you are.** You have a complete game running across the Python/Scheme
> seam. This chapter covers the `shslisp 0.2.3` tooling wired into
> `host/pygame_host.py` and `tests/scm/testkit.scm` so you can inspect errors,
> probe the host from the CLI, measure hot paths by procedure, and run Scheme
> suites against a standard test runner.
>
> **By the end of this chapter you can** launch a headless Tetris REPL with
> `shs --plugin`, read a multi-frame Scheme traceback, profile any Scheme
> expression with `measure_calls`, and read `(srfi 64)` test output.

---

## 24.1 The plugin seam (`--plugin host.pygame_host:install`)

`host/pygame_host.py` exposes `install(env, *, headless=True, **host_kwargs)`,
which configures `STEPS_BUDGET`, adds `scheme/` to `env.loader.search_paths`,
and installs a headless `PygameHost` into any `shslisp` environment.

That means you can drop straight into a REPL or run one-liners against the
real host primitives without writing custom Python bootstrap code:

```sh
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy python -m shslisp --plugin host.pygame_host:install -e "(autostart?)"
```

Or launch an interactive REPL with `--plugin host.pygame_host:install` (with no
`-e`) to load `domain/board.scm` and experiment with placements interactively.

## 24.2 Multi-frame Scheme tracebacks (`LispError.format_traceback`)

In `host/pygame_host.py::main()`, `load_lisp(env, SCHEME_DIR / "main.scm")`
catches `LispError` and prints `exc.format_traceback()` to `sys.stderr` before
returning exit code `1`:

```python
    except LispError as exc:
        print(exc.format_traceback(), file=sys.stderr)
        return 1
```

Instead of a raw Python stack trace pointing into `evaluator.py`, you see the
Scheme call frames (up to 32 frames, innermost first) with file, line, and
column from `read_all_located`.

## 24.3 Exact call-count profiling (`profile_scheme` / `measure_calls`)

Wall-clock timing tells you *that* a frame is slow; `shslisp.evaluator.measure_calls`
tells you *which Scheme procedure* spent the steps. `host/pygame_host.py`
wraps it as `profile_scheme(source, env=None, *, top=20)`:

```python
import host.pygame_host as ph

report = ph.profile_scheme(
    "(define (step-n n) (if (= n 0) 'ok (step-n (- n 1)))) (step-n 10)"
)
print(report["steps"], report["counts"])
```

The returned dict gives you:
- `result`: the evaluated Scheme value,
- `steps`: total interpreter steps consumed,
- `counts`: the top-N Scheme procedures sorted by call count.

Because instrumentation lives in the Python evaluator, you never have to
clutter `.scm` files with manual counters.

## 24.4 Standard `(srfi 64)` assertions in `testkit.scm`

`tests/scm/testkit.scm` keeps its `tk-reset!`, `tk-record!`, and `tk-report!`
contract while backing every check with `(srfi 64)` (`test-begin`,
`test-assert`, `test-end`, `test-runner-current`, `test-runner-simple`).
Existing suites (`ui-tests.scm`, `gameplay-tests.scm`, `shell-tests.scm`)
keep their collected failure-diff output while reporting through the standard
SRFI-64 runner.

---

✓ **Checkpoint.** You can open a headless Tetris REPL with `--plugin`, read a
Scheme traceback on error, and profile any hot path with `profile_scheme`.

## Exercises

1. Run `python -m shslisp --plugin host.pygame_host:install -e "(boot-config)"`
   with dummy SDL drivers and inspect the alist returned by the host.
2. Call `ph.profile_scheme` on a board-placement or `draw-board!` snippet and
   identify the top 5 most-called Scheme procedures.
