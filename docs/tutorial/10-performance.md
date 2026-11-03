# Chapter 10 — Performance in an interpreter

*The files it dissects: `host/pygame_host.py`, findings from cProfile on a
real session.*

> **Where you are.** The game works and is tested. Now the profiler tells you
> what 60fps actually costs in an interpreter — and which half of the budget
> is yours to fix.
>
> **By the end of this chapter you can** profile a real session by frame
> type, cache at the seam without leaking, and defend a step budget as a
> feature rather than a limit.
>
> **The running project.** You profile one Breakout frame, find its
> interpreter tax, and cache the one thing worth caching.

A Scheme game lives or dies by the same budget as any 60fps game: 16.67ms a
frame. But in an interpreter, the cost profile is alien — there is no malloc
storm, no SIMD; there is **per-node dispatch**, and it is everywhere. This
chapter records what profiling this game actually found, and the fixes that
mattered.

## 10.1 Measure before you tune — with the real loop

The profile that started the work: `python -m cProfile -m host --headless
--frames 900 --autostart --play`. Three numbers told the whole story:

1. **Text cost 8.8ms a frame.** Every `draw-text!` built a font *and* rendered
   a surface. The HUD draws ~10 strings a frame.
2. **Bot frames ran ~40ms.** At 25fps the game was playable; at 60 it was not.
3. **Quiet frames ran ~18ms** even after the fixes — the interpreter's
   per-node dispatch of the Scheme loop itself, which no host fix can remove.

The lesson: profile the *whole* session, not a benchmark harness — the real
loop's shape (quiet frames vs loud frames vs AI frames) is the data.

## 10.2 Cache at the seam, not in the algorithm

The 8.8ms became 0.02ms with two caches in the host's painter:

```python
#: Font cache: one font per size, built once. Rendered-text cache: the
#: surface for a (text, size, color) triple, bounded — the HUD draws the
#: same strings every frame, so a hit rate near 100% is the norm.
self._fonts: dict[int, pygame.font.Font] = {}
self._text_cache: dict[tuple, pygame.Surface] = {}
```

and the read path shows every decision:

```python
def _font(self, size: int) -> pygame.font.Font:
    """One Font per size, built once — never per call."""
    size = int(size)
    font = self._fonts.get(size)
    if font is None:
        font = pygame.font.Font(None, size)
        self._fonts[size] = font
    return font

def draw_text(self, x, y, s, size, rgb) -> None:
    color = tuple(int(c) for c in rgb)
    key = (str(s), int(size), color)
    surface = self._text_cache.get(key)
    if surface is None:
        if len(self._text_cache) > 256:
            self._text_cache.clear()  # the ticker's old numbers age out
        surface = self._font(size).render(str(s), True, color)
        self._text_cache[key] = surface
    self._require_display().blit(surface, (int(x), int(y)))
```

Three decisions in ten lines, each worth naming:

1. **The key is the full render input** — `(text, size, color)`. A cache
   keyed on text alone would paint the score in the wrong color the first
   time a second color appeared.
2. **The bound is a clear, not an LRU.** The score ticker produces a new
   string every frame it rolls (`"120"`, `"130"`, …), so old entries are
   garbage by definition. `clear()` at 256 is O(1) amortized and the working
   set — a dozen labels — is never at risk.
3. **The unbounded cache is the small one.** `_fonts` is keyed by size, and
   the game uses three sizes; it can never grow. Know which cache is bounded
   and *why*, or you will "fix" the wrong one.

The principle: **the seam is where frames burn.** A Scheme-side cache would
have been wrong — the expensive call is the Python one, so the cache belongs
next to it. Bound the cache (256 entries) so a long session can't leak.

## 10.3 The interpreter's tax, and how to stop paying interest

cProfile after the fixes showed the remaining cost is the interpreter's
per-node dispatch — `evaluate` walking the AST every frame. You cannot remove
it, but you can stop paying it *twice*:

- **Quiet frames are nearly free.** The dirty flag (chapter 6) means a frame
  where nothing happened costs a few comparisons. Guard everything expensive
  behind "did the world change."
- **Facts batch.** The journal is drained once per frame, not per event; the
  painter is called once per frame, not per cell. Ten small seams crossed
  once beat one seam crossed ten times.
- **Vectors over lists in hot math** (chapter 8's profile): one `vector-copy`
  plus one `vector-set!` versus allocating a fresh ten-list per cell.

## 10.4 The step budget is a feature

The interpreter's step budget is a hang detector scoped to one root
evaluation — and a game session *is* one root evaluation (`arcade-main`'s
tail loop), so the naive fixes are both wrong: leave it at 5M and an honest
session dies two minutes in; raise it to a session-length 2e9 and the
detector never fires again. The fix that keeps both properties: **the host
resets the counter once per frame.** `tick!` is the one primitive the
conductor calls on every frame path, so it is the honest frame boundary —
and `FRAME_STEPS_BUDGET` (5M) now reads as "steps one frame may spend." An
honest frame costs a few thousand steps; an endless loop in a frame dies
loudly, mid-game, with a `LispBudgetError`.

```python
def tick(self) -> int:
    """One frame: hold ~60 fps, answer the elapsed milliseconds.

    Also the frame boundary for the interpreter's step budget — the
    counter is reset here, once per frame, so ``FRAME_STEPS_BUDGET``
    reads as "steps one frame may spend" and the hang detector still
    detects hangs (see :func:`_reset_frame_budget`).
    """
    _reset_frame_budget()
    dt = self.clock.tick(60)
```

The test that pins the shape — a long session must outlive the old per-form
budget many times over, and the detector must still fire on a real endless
loop:

```python
def test_long_session_outlives_the_default_step_budget():
    """A real play session is ONE top-level form that runs for millions of
    honest steps — the interpreter's per-form 5M hang detector used to kill
    it about two minutes into a game, and a session-length 2e9 rubber
    stamp fixed the crash by disabling the detector. The budget is per
    frame now (`tick!` resets the counter); this runs enough frames to
    blow past the old per-form budget many times over and must exit clean.
    """
    r = run_host("--frames", "2500", "--autostart", "--play", timeout=240)
    assert r.returncode == 0, r.stderr[-2000:]
    assert "LispBudgetError" not in r.stderr, r.stderr[-2000:]
```

One honesty note: the reset reaches into the pinned DSL's thread-local
internals (`_local.budget.steps`), because there is no public handle yet.
The getattr chain degrades to the old session-length semantics rather than
crashing if the internals move — and if you own the DSL, expose a public
`reset_steps()` so the underscore can go away.

But keep the budget *on*: `LispBudgetError` ("an endless loop?") is exactly
what caught the journal-drain bug in chapter 6 — a runaway loop that a
silently-raised ceiling would have hidden as a hang.

## 10.5 The remaining gap, honestly

After everything, quiet frames run ~18ms — above the 16.67ms budget for true
60fps. The cost is the interpreter's per-node dispatch, distributed across the
whole loop; the next wins would be structural (fewer forms per frame, or a
bytecode compiler for the DSL), not another cache. **Know which half of your
budget is yours to fix.** The host is now cheap; the interpreter is the
platform, and platforms are earned, not micro-tuned.

## 10.6 A checklist for DSL game performance

1. Profile the real loop first; name the frame types (quiet / loud / AI).
2. Cache at the seam; bound every cache.
3. Batch crossings of the boundary — once per frame, not per fact.
4. Make quiet frames provably cheap (the dirty flag + `view-busy?`).
5. Prefer in-place-on-a-copy (vectors) over rebuilding (lists) in hot math.
6. Keep the step budget as a hang detector — per frame (reset it at the
   frame boundary), never a session-length rubber stamp.
7. Clamp dt at the clock, so a stall costs frames, not a rerun of history.

## Exercises

0. ⟡ **Running project.** Profile one Breakout frame type-by-type — quiet
   (ball between bricks), loud (a brick just broke), AI. Cache whatever the
   profile says is hot, bound the cache, and write down the number that
   justified it.
1. Re-run the cProfile yourself and produce the frame-type table (quiet /
   loud / AI) for `--frames 900 --autostart --play`. Compare with the numbers
   above; explain any drift.
2. Add a hit-rate counter to the text cache and log it every 300 frames.
   Justify the bound of 256 with the measured working set.
3. Find the single most-called Scheme procedure in the profile and make it
   one step cheaper. Measure honestly — did the frame time move?

---

✓ **Checkpoint.** You can profile a session by frame type, cache at the seam
  with a bound, and say exactly which half of the 16.67ms budget is yours.

*Next: [Bounded contexts](11-bounded-contexts.md) — DDD that the language
enforces, with the fence that proves it.*
