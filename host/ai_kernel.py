"""Fast Python AI placement kernel for Scheme Tetris.

Mirrors ``scheme/domain/geometry.scm`` and ``scheme/domain/plan.scm`` exactly,
replacing thousands of interpreted Scheme loops per piece with ~0.2 ms of
native Python arithmetic. Policy (weights, lookahead toggle, hold threshold,
steering, and pacing) remains in Scheme.
"""

from __future__ import annotations

MATRIX_WIDTH = 10
MATRIX_HEIGHT = 20

_SPAWN_SHAPES = {
    "i": ((0, 1), (1, 1), (2, 1), (3, 1)),
    "o": ((0, 0), (1, 0), (0, 1), (1, 1)),
    "t": ((1, 0), (0, 1), (1, 1), (2, 1)),
    "s": ((1, 0), (2, 0), (0, 1), (1, 1)),
    "z": ((0, 0), (1, 0), (1, 1), (2, 1)),
    "j": ((0, 0), (0, 1), (1, 1), (2, 1)),
    "l": ((2, 0), (0, 1), (1, 1), (2, 1)),
}


def _build_rotations() -> dict[str, tuple[tuple[tuple[int, int], ...], ...]]:
    table = {}
    for name, cells in _SPAWN_SHAPES.items():
        n = 4 if name == "i" else (2 if name == "o" else 3)
        rots = []
        cur = cells
        for _ in range(4):
            rots.append(cur)
            cur = tuple((n - 1 - y, x) for (x, y) in cur)
        table[name] = tuple(rots)
    return table


_ROTATIONS = _build_rotations()


def _column_heights(board) -> list[int]:
    heights = [0] * MATRIX_WIDTH
    for col in range(MATRIX_WIDTH):
        for r in range(MATRIX_HEIGHT):
            if board[r][col] is not False:
                heights[col] = MATRIX_HEIGHT - r
                break
    return heights


def _shape_fits_at(board, shape, ox: int, oy: int) -> bool:
    for cx, cy in shape:
        x = ox + cx
        y = oy + cy
        if x < 0 or x >= MATRIX_WIDTH or y >= MATRIX_HEIGHT:
            return False
        if y >= 0 and board[y][x] is not False:
            return False
    return True


def _landing_row_hts(shape, ox: int, oy: int, heights: list[int]) -> int:
    ly = MATRIX_HEIGHT
    for cx, cy in shape:
        x = ox + cx
        if x < 0 or x >= MATRIX_WIDTH:
            return -1
        cand = MATRIX_HEIGHT - heights[x] - 1 - cy
        if cand < ly:
            ly = cand
    return ly if ly >= oy else -1


def _raised_profile(heights: list[int], shape, x: int, ly: int) -> list[int]:
    hs = heights[:]
    for cx, cy in shape:
        col = x + cx
        h = MATRIX_HEIGHT - (ly + cy)
        if h > hs[col]:
            hs[col] = h
    return hs


def _new_holes(heights: list[int], shape, x: int, ly: int) -> int:
    low = [-1] * MATRIX_WIDTH
    for cx, cy in shape:
        col = x + cx
        r = ly + cy
        if r > low[col]:
            low[col] = r
    total = 0
    for i in range(MATRIX_WIDTH):
        rlo = low[i]
        if rlo >= 0:
            top = MATRIX_HEIGHT - heights[i]
            gap = top - rlo - 1
            if gap > 0:
                total += gap
    return total


def _bumpiness(hs: list[int]) -> int:
    return sum(abs(hs[i] - hs[i + 1]) for i in range(MATRIX_WIDTH - 1))


def _wells_sum(hs: list[int]) -> int:
    total = 0
    for i in range(MATRIX_WIDTH):
        left = MATRIX_HEIGHT if i == 0 else hs[i - 1]
        right = MATRIX_HEIGHT if i == MATRIX_WIDTH - 1 else hs[i + 1]
        d = min(left, right) - hs[i]
        if d > 0:
            total += d * (d + 1) // 2
    return total


def _score_profile(ws, prof: list[int], holes: int, attack: int) -> float:
    w_cleared, w_holes, w_bump, w_wells, w_attack, w_roof = ws
    cleared = min(prof)
    roof = max(prof)
    return (w_cleared * cleared + w_attack * attack) - (
        w_holes * holes
        + w_bump * _bumpiness(prof)
        + w_wells * _wells_sum(prof)
        + w_roof * roof
    )


def _sweep_1ply(board, heights: list[int], name: str, oy: int, ws) -> list[tuple[float, int, int, int]]:
    rots = _ROTATIONS[name]
    results = []
    for rot in range(4):
        shape = rots[rot]
        for x in range(MATRIX_WIDTH):
            if not _shape_fits_at(board, shape, x, oy):
                continue
            ly = _landing_row_hts(shape, x, oy, heights)
            if ly < 0:
                continue
            raised = _raised_profile(heights, shape, x, ly)
            h_min = min(heights)
            attack = min(raised) - h_min
            holes = _new_holes(heights, shape, x, ly)
            sc = _score_profile(ws, raised, holes, attack)
            results.append((sc, x, rot, ly))
    return results


def _weights_tuple(weights) -> tuple[float, float, float, float, float, float]:
    # shslisp record or vector/sequence: extract the 6 numeric weights.
    if hasattr(weights, "fields"):
        vals = list(weights.fields.values())
    else:
        vals = list(weights)
    while len(vals) < 6:
        vals.append(0.0)
    return tuple(float(v) for v in vals[:6])


def host_best_placement(
    board,
    cur_name,
    cur_y,
    next_name,
    hold_name,
    can_hold,
    weights,
    lookahead_k,
):
    """Return ``[x, rot, hold?]`` for the best placement, or ``False`` if none."""
    cur = str(cur_name)
    if cur not in _ROTATIONS:
        return False
    ws = _weights_tuple(weights)
    raw_rows = board.items if hasattr(board, "items") else board
    grid = [row.items if hasattr(row, "items") else row for row in raw_rows]
    heights = _column_heights(grid)
    oy = int(cur_y)
    cands = _sweep_1ply(grid, heights, cur, oy, ws)
    if not cands:
        return False

    cands.sort(key=lambda item: item[0], reverse=True)
    best_1ply_sc, best_x, best_rot, _ = cands[0]

    # Hold check: if hold is available and the held/next piece beats cur by > 1.5
    if can_hold:
        alt = str(hold_name) if hold_name is not False else (str(next_name) if next_name is not False else "")
        if alt and alt != cur and alt in _ROTATIONS:
            alt_cands = _sweep_1ply(grid, heights, alt, 0, ws)
            if alt_cands:
                alt_best = max(item[0] for item in alt_cands)
                if alt_best > best_1ply_sc + 1.5:
                    return [0, 0, True]

    k = int(lookahead_k)
    nxt = str(next_name) if next_name is not False else ""
    if k > 0 and nxt in _ROTATIONS:
        nxt_rots = _ROTATIONS[nxt]
        best_joint = None
        h_min = min(heights)
        for _, cx, crot, cly in cands[:k]:
            shape1 = _ROTATIONS[cur][crot]
            raised1 = _raised_profile(heights, shape1, cx, cly)
            attack1 = min(raised1) - h_min
            holes1 = _new_holes(heights, shape1, cx, cly)
            prof1 = [max(0, h - attack1) for h in raised1] if attack1 > 0 else raised1

            p2_best = None
            for r2 in range(4):
                shape2 = nxt_rots[r2]
                xs2 = [c[0] for c in shape2]
                min_cx, max_cx = min(xs2), max(xs2)
                for x2 in range(-min_cx, MATRIX_WIDTH - max_cx):
                    ly2 = _landing_row_hts(shape2, x2, 0, prof1)
                    if ly2 < 0:
                        continue
                    raised2 = _raised_profile(prof1, shape2, x2, ly2)
                    attack2 = min(raised2) - min(prof1)
                    holes2 = _new_holes(prof1, shape2, x2, ly2)
                    final = [max(0, h - attack2) for h in raised2] if attack2 > 0 else raised2
                    sc2 = _score_profile(ws, final, holes1 + holes2, attack1 + attack2)
                    if p2_best is None or sc2 > p2_best:
                        p2_best = sc2
            joint = p2_best if p2_best is not None else _score_profile(ws, prof1, holes1, attack1)
            if best_joint is None or joint > best_joint:
                best_joint = joint
                best_x = cx
                best_rot = crot

    return [best_x, best_rot, False]
