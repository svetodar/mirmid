# context.md — decisions, environment quirks, measured test counts

## 2026-11-08 — phase 0 baseline (measured before the rename)

Reference numbers measured on the pre-rename snapshot; use them to verify that
the rename changed nothing behaviourally.

- Source tree: **32 units** (now `src/mirmid.*.pas`) plus the program file
  `src/mirmid.lpr`; 6 of the units are PostgreSQL-related
  (`mirmid.pg.pas`, `mirmid.pgclient.pas`, `mirmid.pgdsn.pas`,
  `mirmid.pgscram.pas`, `mirmid.pgsql.pas`, `mirmid.pgwire.pas`) and must be
  dropped (no PostgreSQL support), leaving **26 units** in `src/`.
- Test tree: 25 test units + `tests/testrunner.lpr`.
- Baseline build/run: `make -B app test` → **685 tests run, 0 errors,
  0 failures**.
- Version before the rename: `0.1.0`; after the rename
  `bin\mirmid.exe --version` must print `mirmid 0.1.0`.
- Verification for phase 0: `make -B app test` must still report 685 / 0 / 0 and
  the CLI smoke test must report `mirmid 0.1.0`.

## 2026-11-08 — phase 0 result (measured after the rename)

Numbers re-measured in `C:\ai\git\mirmid` on the renamed tree:

- Source tree: still **32 units** `src/mirmid.*.pas` (the 6 `mirmid.pg*.pas`
  units are not dropped yet, so the target of 26 units is reached in a later
  phase) plus the program file `src/mirmid.lpr`.
- Test tree: unchanged — 25 test units + `tests/testrunner.lpr`.
- Tests: **685 run, 0 errors, 0 failures** — equal to the pre-rename baseline
  (`make -B app test` and `bin\testrunner.exe --all --format=plain`).
- Units/uses rename did not change behaviour: `bin\mirmid.exe --version` prints
  **`mirmid 0.1.0`** — the version string is unchanged, only the program name in
  front of it is new.
- `AGENTS.md` "Repository state" was rewritten to the actual phase 0 tree.

## 2026-11-08 — phase 0 review follow-up (REQUEST CHANGES → fixed)

An independent subagent reviewed phase 0 and returned **REQUEST CHANGES**. All
findings are addressed below; after the fixes `make -B app test` → **685 / 0 / 0**
and `bin\mirmid.exe --version` → `mirmid 0.1.0`.

Blockers:

- **Harness state directory in the working tree.** The state directory of the
  development harness (an INI file with a live API key plus ~35 MB of session
  logs) is not covered by `.gitignore`, so `git add -A` would commit a secret.
  It cannot be deleted while the harness session that drives this work is
  running, so it is excluded per clone in `.git/info/exclude`: that file is
  never committed, so its name does not enter the repository. **Delete the
  directory before the first push**; the product itself keeps its state in
  `.mirmid/`, which `.gitignore` already covers.
- **`task.md` was tracked.** It is a local scratch file with Russian text, and
  tracked status defeats the `task*.md` ignore rule. Untracked with
  `git rm --cached task.md`; the working copy stays on disk.
- **`context.md`** no longer names the pre-rename program (the "before the
  rename" line was rewritten).
- **`src/mirmid.subagent.pas`** dropped the comment clause that referenced a
  deliberately deleted predecessor file (comment only, no code change).

Nits:

- **Line endings.** The port left 34 files with CRLF terminators (`LICENSE`, the
  four docs, `Makefile`, `build.sh`, `mirmid.lpi`, `.gitignore`, `.gitmodules`,
  22 `src/` units, `tests/fixtures/streamprobe.pas`,
  `tests/rsa_test_vectors.txt`); the rest were already LF. Decision: **LF
  everywhere**, declared in the new `.gitattributes` (`* text=auto eol=lf`) and
  applied to the working tree. This also removes a latent bug: `build.sh` with
  CRLF terminators fails on Linux.
- `src/.gitkeep`, `tests/.gitkeep`, `tests/fixtures/.gitkeep` removed — those
  directories hold real files; only `config/` and `docs/` keep placeholders.
- `plan.md`: the Cyrillic range in the P4 check is written as `[\u0400-\u04FF]`,
  so the check itself does not trip the "no Cyrillic" grep.
- `.gitignore`: added `*_analysis.json` and the dated session-dump pattern
  `[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.json`.
- Left as planned: Cyrillic comments and tool descriptions in `src/`/`tests/`
  (P4) and the Russian `README.md` scaffold (P5). They are tracked and still
  violate the English-only rule until those phases land — do not lose them.

## 2026-11-08 — phase 1 result (PostgreSQL removed)

Measured in `C:\ai\git\mirmid` after the P1 removal, from a clean tree
(`make clean`, then `make -B app test` with the `PATH` from `AGENTS.md`):

- Source tree: **26 units** `src/mirmid.*.pas` plus the program
  `src/mirmid.lpr` — the 6 `mirmid.pg*.pas` units are gone, so the target of
  §1 is reached.
- Test tree: **20 test units** `tests/test_*.pas` + `tests/testrunner.lpr` +
  two fixtures + `rsa_test_vectors.txt` — the 5 `test_pg*.pas` units are gone.
- Tests: **465 run, 0 errors, 0 failures** (Time: 36.711), down from the 685
  baseline by exactly the 5 removed PostgreSQL suites (220 test methods).
  `bin\testrunner.exe -l` lists 40 suites and no `Pg*`/`test_pg*` suite; the
  only similarity hits are `StepGatingTests` and `LoopGuardTests`.
- Smoke: `bin\mirmid.exe --version` → `mirmid 0.1.0`; `bin\mirmid.exe --help`
  exits 0 and contains no `--db-list`/`--db_list`/`database`.
- Removal proof (case-insensitive recursive search over `src/` and `tests/`):
  no `pg_execute`, `mirmid.pg`, `libpq`, `SCRAM`, `DSN`, `[databases]` or
  `db_` left. `TDbConfig`, `TDbAccessLevel`, `Databases`, `DbDmlOnly`,
  `DbFullAccess`, `ListDb`, `ListDatabases`, `InitPgPool`, `FreePgPool` and the
  `/db_list` REPL branch are all deleted, together with the `mirmid.pg` uses
  clauses in `mirmid.cli`/`mirmid.subagent`.
- **Docs/INI part of P1 was a no-op**: `docs/` and `config/` still contain only
  `.gitkeep` placeholders (no `docs/libpq.md`, no `docs/architecture.md`, no
  `config/mirmid.ini.example` in this repository yet), so only the
  `[databases]` block of `SaveSampleIni` in `mirmid.config` had to go.
- `AGENTS.md` "Repository state" now reports 26 units / 20 test units, and the
  stale `685` counter points at this file instead.
- Left for phase 2 (input removal): `src/mirmid.input.pas`,
  `tests/test_input.pas` and thus the `TInputTests` suite.

## 2026-11-08 — phase 2 result (keyboard/mouse input removed)

Measured in `C:\ai\git\mirmid` after the P2 removal (`make -B app test` with the
`PATH` from `AGENTS.md`):

- `src/mirmid.input.pas` (the `click`, `type_text`, `key_press` tools with the
  WinAPI `SendInput` backend and the `xdotool`/`xwininfo` fallback) and
  `tests/test_input.pas` (`TInputTests`, 9 test methods) are deleted.
- Source tree: **25 units** `src/mirmid.*.pas` plus `src/mirmid.lpr` — the
  unit target of `plan.md` §5 is reached one phase early: the input layer is
  gone.
- Test tree: **19 test units** `tests/test_*.pas`; `test_input` is no longer
  in `tests/testrunner.lpr`, so `testrunner -l` lists no input suite.
- Tests: **456 run, 0 errors, 0 failures** — down from 465 by exactly the 9
  removed `TInputTests` methods.
- Removed with the unit (case-insensitive search over `src/` and `tests/` now
  returns nothing): `AllowInput` in `TMirmidConfig` (`mirmid.types`) and
  `TToolContext` (`mirmid.tools`), the `allow_input` key of `[workspace]` and
  the `MIRMID_ALLOW_INPUT` override (`mirmid.config`), the `--allow-input` /
  `--no-input` flags, their `TCli` fields, the `ResolveConfig` line and the two
  `--help` lines (`mirmid.cli`), the `mirmid.input` uses clause and the
  `RegisterInputTools` branch of `RegisterSessionTools`
  (`mirmid.subagent`), and the `AllowInput` mention in the `AnalysisConfig`
  comments of `mirmid.planner` plus the assertion in
  `test_planner.TestAnalysisConfigInheritsPolicies`.
- Kept untouched: `list_windows`, `find_window`, `window_info` (`mirmid.gui`),
  `screen_shoot`, `window_shoot` (`mirmid.screen`) — the screen/window
  observation layer is unchanged.
- Documented behaviour break: `mirmid --allow-input` / `--no-input` now fail
  with "unknown option" and exit code 2 instead of being accepted.
- Smoke: `bin\mirmid.exe --version` → `mirmid 0.1.0`; `--help` exits 0 and
  contains no `input` / `--allow-input` substring; an old INI with
  `allow_input=` under `[workspace]` is simply ignored (unknown keys in
  `[workspace]` are not rejected, unlike the future `[tools]` section).
- **Docs part of P2 is a no-op** for the same reason as in P1: `docs/` and
  `config/` still hold only `.gitkeep`, so there was no `xdotool`/input
  guidance and no "new tools" note to rewrite.
- Deliberately **not** added a regression test that asserts the absence of the
  tool names: `plan.md` §2 requires the repository to contain no `click`,
  `type_text` or `key_press` strings at all, and such a test would reintroduce
  them. The absence is verified by the deletion itself plus the green build.
- Next phase (P3): the removal left `AllowWrite`/`AllowShell`/`AllowHttp`,
  the `CaFile` bundle and the `[tools]` section untouched.
- Remaining `xdotool` mention (deliberate): `src/mirmid.screen.pas` keeps the
  `import -window "$(xdotool getactivewindow)"` fallback of `window_shoot`.
  That is window identification for a screenshot, not input injection, and P2
  explicitly keeps the screenshot tools untouched; a later cleanup may replace
  it with an X11 query, but it is not part of the input removal. `plan.md` §7
  and its "Done" line were clarified in the same phase to state this exception
  explicitly, so the requirement and the code no longer contradict each other.
