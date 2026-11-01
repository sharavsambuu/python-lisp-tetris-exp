# Chapter 9 — Performance in an interpreter

*The files it dissects: `host/pygame_host.py`, findings from cProfile on a
real session.*

A Scheme game lives or dies by the same budget as any 60fps game: 16.67ms a
frame. But in an interpreter, the cost profile is alien — there is no malloc
storm, no SIMD; there is **per-node dispatch**, and it is everywhere. This
chapter records what profiling this game actually found, and the fixes that
mattered.

## 9.1 Measure before you tune — with the real loop

The profile that started the work: `python -m cProfile -m host --headless
--frames 900 --autostart --play`. Three numbers told the whole story:

1. **Text cost 8.8ms a frame.** Every `draw-text!` built a font *and* rendered
   a surface. The HUD draws ~10 strings a frame.
2. **Bot frames ran ~40ms.** At 25fps the game was playable; at 60 it was not.
3. **Quiet frames ran ~18ms** even after the fixes — the interpreter's
   per-node dispatch of the Scheme loop itself, which no host fix can remove.

The lesson: profile the *whole* session, not a benchmark harness — the real
loop's shape (quiet frames vs loud frames vs AI frames) is the data.

## 9.2 Cache at the seam, not in the algorithm

The 8.8ms became 0.02ms with two caches in the host's painter:

```python
#: Font cache: one font per size, built once. Rendered-text cache: the
#: surface for a (text, size, color) triple, bounded — the HUD draws the
#: same strings every frame, so a hit rate near 100% is the norm.
self._fonts: dict[int, pygame.font.Font] = {}
self._text_cache: dict[tuple, pygame.Surface] = {}
```

The principle: **the seam is where frames burn.** A Scheme-side cache would
have been wrong — the expensive call is the Python one, so the cache belongs
next to it. Bound the cache (256 entries) so a long session can't leak.

## 9.3 The interpreter's tax, and how to stop paying interest

cProfile after the fixes showed the remaining cost is the interpreter's
per-node dispatch — `evaluate` walking the AST every frame. You cannot remove
it, but you can stop paying it *twice*:

- **Quiet frames are nearly free.** The dirty flag (chapter 5) means a frame
  where nothing happened costs a few comparisons. Guard everything expensive
  behind "did the world change."
- **Facts batch.** The journal is drained once per frame, not per event; the
  painter is called once per frame, not per cell. Ten small seams crossed
  once beat one seam crossed ten times.
- **Vectors over lists in hot math** (chapter 7's profile): one `vector-copy`
  plus one `vector-set!` versus allocating a fresh ten-list per cell.

## 9.4 The step budget is a feature

The DSL raises its step ceiling for a game session — a painted frame costs
~1k honest steps, so the interpreter's default hang detector would kill a
match two minutes in. The test that pins it:

```python
def test_long_session_outlives_the_default_step_budget():
    """A real play session is ONE top-level form that runs for millions of
    honest steps — the interpreter's 5M hang detector used to kill it about
    two minutes into a game. The host now raises the ceiling; this runs
    enough frames to blow past the old budget and must exit clean."""
    r = run_host("--frames", "2500", "--autostart", "--play", timeout=240)
    assert r.returncode == 0, r.stderr[-2000:]
    assert "LispBudgetError" not in r.stderr, r.stderr[-2000:]
```

But keep the budget *on*: `LispBudgetError` ("an endless loop?") is exactly
what caught the journal-drain bug in chapter 5 — a runaway loop that a
silently-raised ceiling would have hidden as a hang.

## 9.5 The remaining gap, honestly

After everything, quiet frames run ~18ms — above the 16.67ms budget for true
60fps. The cost is the interpreter's per-node dispatch, distributed across the
whole loop; the next wins would be structural (fewer forms per frame, or a
bytecode compiler for the DSL), not another cache. **Know which half of your
budget is yours to fix.** The host is now cheap; the interpreter is the
platform, and platforms are earned, not micro-tuned.

## 9.6 A checklist for DSL game performance

1. Profile the real loop first; name the frame types (quiet / loud / AI).
2. Cache at the seam; bound every cache.
3. Batch crossings of the boundary — once per frame, not per fact.
4. Make quiet frames provably cheap (the dirty flag + `view-busy?`).
5. Prefer in-place-on-a-copy (vectors) over rebuilding (lists) in hot math.
6. Keep the step budget as a hang detector, raised but not disabled.
7. Clamp dt at the clock, so a stall costs frames, not a rerun of history.

## Exercises

1. Re-run the cProfile yourself and produce the frame-type table (quiet /
   loud / AI) for `--frames 900 --autostart --play`. Compare with the numbers
   above; explain any drift.
2. Add a hit-rate counter to the text cache and log it every 300 frames.
   Justify the bound of 256 with the measured working set.
3. Find the single most-called Scheme procedure in the profile and make it
   one step cheaper. Measure honestly — did the frame time move?

---

*Next: [Bounded contexts](10-bounded-contexts.md) — DDD that the language
enforces, with the fence that proves it.*
