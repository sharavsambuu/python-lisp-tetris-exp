"""host — the edge of the Scheme Tetris.

This package owns the *only* things a game needs Python for: the window, the
clock, the pixels, and the speaker. Everything else — the domain, the rules,
the pacing, the input policy, the screens — lives in ``scheme/`` and runs on
the shs Scheme DSL. The loop itself is a tail recursion in Scheme; Python
never advances the game.
"""
