# Chapter 20 — The profile

*The files it dissects: `host/pygame_host.py` (the seam's new pair),
`scheme/conductor/profile.scm`, and the save points in
`scheme/conductor/arcade.scm`.*

> **Where you are.** The duel has opponents (chapter 19) — and every
> restart forgets them. The ladder, the bests, the rungs won: all of it
> dies with the process. This chapter gives the game a memory.
>
> **By the end of this chapter you can** grow a seam that was designed
> to be closed, put a file format at the edge without letting it leak
> inward, write a document that fails the way your conditions chapter
> taught, and know which of your tests must never touch the real file.
>
> **The running project.** Breakout saves its high scores: a write at
> every settled game, a read at boot, and a corrupt file that costs a
> console note — never a crash.

Chapter 1 made a promise that sounds like a vow of poverty: the seam
stays *closed* — sixteen names, and adding a seventeenth has to earn
its place. This chapter is the story of two names earning theirs. The
game grew a memory, and a memory is a *boundary* concern: the file
lives in Python's world (paths, bytes, atomic renames), the *meaning*
lives in Scheme's (what progress is, when it is final, what a corrupt
document costs). Neither side should own both halves.

```python
("read-profile", self.read_profile),
("write-profile!", self.write_profile),
```

The seam is now eighteen names, and the rule that governed it did not
change: one name, one narrow job, no kitchen sink. `read-profile`
answers the document or an empty list; `write-profile!` takes the
document and answers whether the bytes landed. Everything else —
versioning, validation, what the fields mean — is on the Scheme side
of the line.

## 20.1 The document crosses as an alist

The same move as `boot-config` (chapter 1): a JSON object on Python's
side is an alist on Scheme's side, and neither builds a marshaller.

```scheme
(("version" . 1)
 ("locale"  . "en")
 ("done"    . (("ascent:1" . #t) ...))
 ("bests"   . (("sprint" . 123) ...))
 ("ladder"  . 0)
 ("records" . (("wall" . (("wins" . 1) ("losses" . 0) ("margin" . 42))) ...))
 ("leashes" . (("wall" . (("pace" . 1.2) ...)) ...)))
```

Two contract decisions are worth their paragraphs. First, the keys are
**strings, not symbols** — `boot-config`'s keys are a fixed CLI
vocabulary that `assq` matches; a profile's keys are *data* (persona
ids, level keys, mode labels), and JSON objects are string-keyed by
nature, so `assoc` it is. Second, the shapes convert **at the
boundary**: the campaign library's `assoc` contract holds proper
two-element lists (`("sprint" 123)`), the document holds dotted pairs
(`("sprint" . 123)`), and `conductor/profile.scm` owns the four-line
conversion in both directions. Neither side learns the other's shape —
the discipline chapter 11 named, applied to a file.

Versioning is a field, present from day one: `"version" . 1`. It costs
one `cons` now and buys the guard a hook the day the format moves.

## 20.2 The failure posture is the feature

A save file is an actuator pointed at the player's past. The posture
is the conditions chapter's, applied to the disk — every failure is a
value the session runs on:

- **Missing file** = first boot. Quietly: nobody's first launch is an
  error.
- **Corrupt file** = a console note, a fresh profile. The Python side
  catches the JSON error and prints; the Scheme side *also* guards,
  because the two layers fail differently — Python owns the bytes,
  Scheme owns the meaning:

```scheme
(define (profile-load!)
  ;; Boot: read, validate, restore. A missing file is a first boot
  ;; (quiet — nobody's first launch is an error); a corrupt or foreign
  ;; document is a fresh start with a note.
  (set! *profile-readonly* #f)
  (let ((doc (guard (e (#t
                         (profile-note "unreadable; starting fresh")
                         'corrupt))
                (read-profile))))
    ...))
```

- **A document from a newer build** is the subtle one. It is not
  corrupt — it is *not ours*. Boot fresh, yes, but never save over it:
  losing one session's progress is honest; silently clobbering a file
  this build cannot read is not. The `*profile-readonly*` flag turns
  every later save into a refusal until the build that owns the format
  arrives.

The write itself is atomic — tmp file, then `os.replace` — because the
game can die mid-write, and the file on disk must be either the old
document or the new one, never half of each. And the write is guarded
on the Scheme side too: a full disk is a console note, never a dead
frame. *The game outranks its memory.*

## 20.3 Save points, not save discipline

When does the memory write? The temptation is "whenever state changes"
— which, in a frame loop, means per frame, and means the disk becomes
the hottest actuator in the game. The answer is the same bounded-
channel thinking as the director's cooldown (chapter 17): the save is
wired to **call sites**, not to discipline.

There are exactly three, and each is a moment where something is
*final*:

1. **The settle** — a match ended, the best is recorded, the rung is
   marked. The outcome is final; the disk is worth one write.
2. **The locale cycle** — rare, deliberate, and lost otherwise.
3. **The quit path** — the loop's last word before the window closes.

Never per frame. The per-frame budget (chapter 13) would catch a
save-per-frame as a slowdown, but the honest fix is upstream: a save
point is a *semantic* moment, and there are only three of them.

## 20.4 Growing a closed seam is a broadcast edit

The scar this stage earned is architectural, and it is the price of
the closure chapter 1 was so proud of. The seam is "one declared list"
— **in the real host**. But the tests keep four stand-ins of the same
vocabulary: the Scheme fake host, and three Python test harnesses that
install their own primitive tables. Growing the seam by two names
meant touching all five files, and the one that was missed failed not
at edit time but at *boot time* — `unbound symbol: profile-load!` —
twenty minutes later, in a suite that had nothing to do with profiles.

Two smaller stings, same hour: the shared interaction environment
rejected `(srfi 1)`'s `map` under its own name (the collision the
other conductor files already rename around — the fence's import
conventions are load-bearing in *every* new edge file), and the first
*real* save printed `unsupported profile value: list` — the DSL folds
`(cons key a-list)` into the proper list `(key <a-list…>)`, so the
document's entries arrive at the seam with two faces and the
converter must accept both. Unit tests with hand-built data passed
while the real boot failed; the smoke test that drives the actual
save path is what caught it. That is the trade working
as designed: a closed seam makes growth *loud*. An open seam would
have made it silent.

The corollary worth writing down: **a test that loads the conductor
must never touch the real profile file.** The harnesses that boot the
real host now point `profile_path` into pytest's tmp dir — a test that
settles a match writes a profile, and no test should write into the
player's config dir.

## 20.5 Pitfalls, one each

- **Marshalling creep.** The moment Python "helpfully" interprets a
  field (a date, a score cap, a default), the format has two owners
  and the version field has one. Python moves bytes; Scheme means
  them. The tmp-then-rename is the only opinion this side keeps.
- **Saving on the way out only.** A crash loses everything since the
  last save. The settle is the save point precisely because matches
  are short and outcomes are final — if your game grows long
  unsaved stretches, the save points, not the crash handling, are
  wrong.
- **A test with a real path.** The default profile path is the
  player's. Any harness that boots the conductor must override it, or
  the suite becomes the thing that corrupts the progress it is trying
  to protect.

✓ **Checkpoint.** You can add a seam primitive without guilt (and
know the broadcast it costs), put a versioned document at the edge
with the meaning on the script side, name your save points as semantic
moments, and make every failure a value the session runs on.

## Exercises

0. ⟡ **Running project.** Give Breakout its scoreboard file: write at
   every settled game, read at boot, one `version` field, and a test
   that corrupts the file and proves the game boots anyway.
1. The profile converts the campaign's proper-list shapes at the
   boundary. Suppose instead the campaign library switched to dotted
   pairs everywhere. What would shrink? What would the `assoc` call
   sites pay? Write the ten-line diff in your head and decide which
   shape *should* own the library.
2. `--profile` is a flag the CLI owns. Who else might want to set the
   path — a portable install, a second account, a test runner? Sketch
   the precedence order (flag > env var > platform default) and write
   the two-line test for the middle link.
3. The `*profile-readonly*` posture refuses saves under a newer
   document. The alternative is a merge: keep the fields this build
   understands, preserve the rest. Argue both sides in a comment —
   then decide which one you would defend to a player who lost
   progress, and why the answer differs for a save *editor*.
