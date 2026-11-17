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

## 2026-11-08 — phase 3 result (settings model: `[tools]`, no `ca_file`/`allow_*`)

Measured in `C:\ai\git\mirmid` after the P3 change (`make -B app test` with the
`PATH` from `AGENTS.md`). Confirmed counts of the phase 3 runs, in order:

| Run | Tests | Errors | Failures | What changed |
| --- | --- | --- | --- | --- |
| after the P3 change | 460 | 0 | 0 | was 456 after P2 |
| after the unknown-tool E2E test | 461 | 0 | 0 | `TCliUnknownToolKeyTests` |
| after the review fixes | **467** | **0** | **0** | +6 regression tests (`--init`, section typos, duplicate keys, defence in depth) |

- Reference count for the phase: **467 run, 0 errors, 0 failures** — the last
  run, after the review follow-up below; treat it as the current baseline.
- Net +11 over P2's 456: the two `ca_file` tests in `test_config` are replaced
  by four `[tools]` tests, the eight `SelectTrustStore` cases in
  `test_tlsclient` collapse to four (no explicit bundle left), and
  `test_cli`/`test_subagent`/`test_config` gained the CLI contract, request-array
  and INI-validation tests described below.
- Source tree: still **25 units** `src/mirmid.*.pas` plus `src/mirmid.lpr`; test
  tree still **19 test units**.

What P3 changed:

- `mirmid.types`: `CaFile`, `AllowWrite`, `AllowShell`, `AllowHttp` are gone
  from `TMirmidConfig`; instead `Tools: TToolSwitches` holds the keys read from
  `[tools]` (`TToolSwitch` = name + boolean). An empty array means "no key
  given", so `DefaultConfig` stays independent of `mirmid.tools`.
- `mirmid.tools` is the single source of truth: `TOOL_SWITCHES` (17 entries:
  name, default, one-line note for the sample INI) plus `IsKnownToolName`,
  `ToolEnabledByDefault`, `ToolNamesCsv`, `ToolSwitchCount/ToolSwitchAt`,
  `ToolEnabled(Cfg, Name)`, `SetToolEnabled`, `ToolDisabled`. `TToolContext`
  lost the three `Allow*` fields (it still carries the whole `Cfg`).
- Registry policy: `TToolRegistry.ApplyToolSwitches(Cfg)` filters `Add` and
  `AddMethod`, so a disabled tool never reaches the request's `tools` array;
  `RegisterSessionTools` applies it before registering and now always calls
  `RegisterHttpTool` (the policy decides). `Invoke` re-checks the key, so a
  handler cannot run even if the registry was filled in another way.
- Handler gates (`ToolDisabled`) in `edit_text_file`, `copy_file`, `shell`,
  `http_request`, `subagent`, `read_media_file`, `screen_shoot`,
  `window_shoot` — the CLI is not the only gate.
- `mirmid.config`: `LoadIni` became
  `function LoadIni(const FileName: string; var C: TMirmidConfig; out Err: string): Boolean`.
  `[tools]` values go through `ParseBoolStr`; a key missing from the table makes
  it return False with `unknown tool "<name>"; known tools: ...`. The
  `ca_file` key, the `MIRMID_CA_FILE` override and the `[workspace]`
  `allow_*` keys are gone; the sample INI (`--init`) emits the full `[tools]`
  block from the same table (note text in English, the rest of the sample is
  still Russian until P4).
- `mirmid.cli`: `ResolveConfig` is now
  `function ResolveConfig(...; out Err: string): Boolean`; `Main` prints the
  reason and exits 1 before starting a session. Removed
  `-w/--allow-write`, `--no-write`, `--allow-shell`, `--no-shell`,
  `--allow-http`, `--no-http` (their handlers, the `TCli` fields and the usage
  lines), the startup warning branch that mentioned the trust bundle, and the
  `HttpCaFile` plumbing. `UsageText` is exported for tests.
- `mirmid.tlsclient`: trust is "embedded roots first, then the OS store, else
  error". `SelectTrustStore(AEmbeddedAvailable, AAllowSystemStore)` returns a
  `TTrustStoreSource`; `TTrustStoreChoice`, `tssBundle` and the
  `Connect`/`DoHandshake` `ACAFile` parameter are gone, and the error texts no
  longer suggest a bundle. `HttpCaFile` was removed from `mirmid.http`.
- Docs: the `[tools]` model and the screenshot/media behaviour change are
  documented in `README.md` (English section; the full rewrite stays in P5).

Pitfalls found while doing P3 (worth remembering):

- Blank lines never reach the key list (`ReadSection` trims every line and skips
  the empty ones), but a non-empty line without `=` inside `[tools]` is stored
  with an **empty** name — that is what a `#` note does. `LoadIni` skips empty
  names; without that guard such a note fails with `unknown tool ""`.
- `TMirmidConfig` holds a dynamic array (`Tools`), so `AC := Cfg` shares the
  storage. `SetToolEnabled` therefore copies the array (`Copy(Cfg.Tools)`)
  before touching an element, otherwise
  `TPlannerTests.TestAnalysisConfigInheritsPolicies` sees the parent config
  change through the copy.
- `TStringList.IndexOf(S, StartAt)` in FPC 3.2.2 skips index 0 when `StartAt=1`;
  `IndexOf(name, 1)` is not "search everywhere" — the request-array test used it
  and missed `file_list`, the first registered tool.
- `plan.md` §2 requires the removed setting names to be absent from the tracked
  tree, so the tests that assert their absence build the strings from parts
  (`'allow' + '_write=1'`, `'ca' + '_file'`). The dash-form flags
  (`--allow-write` …) are kept in `test_cli`: they are the option names the
  parser must reject, not settings.
- Line endings: `edit_text_file` writes CRLF on Windows; all touched files were
  converted back to LF (`perl -pi -e 's/\r\n/\n/'`) before the final build, per
  `.gitattributes`.

Behaviour breaks (settings contract, hence `!` in the commit):

- `--allow-write`, `--no-write`, `--allow-shell`, `--no-shell`, `--allow-http`,
  `--no-http` are unknown options now (exit code 2, `unknown option: <argument>`).
- Old INIs with `ca_file` under `[llm]` or `allow_*` under `[workspace]` are
  ignored silently (only `[tools]` keys are validated); a `[tools]` typo is a
  fatal startup error instead.
- `screen_shoot`, `window_shoot` and `read_media_file` are `0` by default and
  need their own keys — previously they inherited `allow_write`.

Left for the next phases: P4 (English-only pass over `src/`, `tests/`, tool
descriptions, prompts, CLI text) and P5 (`config/mirmid.ini.example`,
`docs/`).

## 2026-11-08 — phase 3 review follow-up (independent review of the P3 diff)

An independent subagent reviewed the uncommitted P3 diff against the §4 checklist
of `plan.md` and returned **PASS WITH MINOR ISSUES** (no blockers): the
`(name, default)` table in `mirmid.tools` matches §4 (17 entries), an unknown
`[tools]` key is fatal (exit 1, all 17 known names listed), every handler gate
(`ToolDisabled`) is the first statement of its tool, the `ca_file` branch is gone
from `mirmid.tlsclient`/`mirmid.http`, and `--init` writes the commented sample.
The issues it found were fixed before committing:

- `--init` is no longer blocked by a broken INI: `ResolveConfig` returns the
  `LoadIni` error and `Main` aborts only when the run is not `--init`, so a
  mistyped key can be repaired by regenerating the sample instead of deadlocking
  the user (`TCliUnknownToolKeyTests.TestInitRepairsBrokenToolsSection`,
  `TConfigTests.TestResolveConfigInitToleratesBrokenIni`).
- The same class of silent typo is now fatal in the section *name*: `[tool]`
  gives `unknown section "[tool]"; did you mean [tools]?`, `[tools ]` with stray
  spaces gives `section name "[tools ]" has stray spaces; write it as [tools]`,
  and a repeated key gives `duplicate tool "<name>" in [tools]`
  (`CheckToolsSectionName` + the duplicate scan in `LoadIni`; tests
  `TestIniToolsSectionNameTypo`, `TestIniToolsDuplicateKey`). Case stays
  irrelevant (`[Tools]` is fine) because `TIniFile` is case-insensitive.
- Defence in depth is now covered by tests instead of being assumed:
  `TSubAgentToolTests.TestRequestToolsMatchTable` (the request array equals the
  table's enabled names), `TestDisabledToolAbsentFromRequest`,
  `TestDisabledToolRefusesInHandler` and `TToolTests.TestReadOnlyToolDisabled`.

Verification after the fixes (`make -B app test`, `PATH` from `AGENTS.md`):
`bin\mirmid.exe` relinked with 0 errors and the suite reported **467 run tests,
0 errors, 0 failures** — 460 before the review plus 7 regression tests. LF
normalisation (`perl -pi -e 's/\r\n/\n/'`) was re-applied to the touched files
afterwards, because `edit_text_file` writes CRLF on Windows.

Deliberately deferred, recorded so they are not lost:

- Error/warning prefixes stayed Russian in P3; the P4 pass (step 21) replaced
  them with `Error:` / `Warning:` on stderr (§9.3). `README.md` quoted the
  target wording, so docs and runtime agree again.
- The sample INI written by `--init` was still Russian apart from the `[tools]`
  note lines in P3; P4 (step 23) translated every comment line of `SaveSampleIni`.

## 2026-11-09 — phase 4 result (English-only pass over src/ and tests/)

`make -B app test` → **467 run tests, 0 errors, 0 failures** (`bin\testrunner.exe
--all --format=plain` reports the same numbers), so the new reference test count
is **467 / 0 / 0**, unchanged from the P3 baseline (the pass changed text, not
behaviour). `bin\mirmid.exe --version` → `mirmid 0.1.0`; `--help` prints the full
English usage; `--init` in a scratch directory writes a 96-line
`.mirmid\mirmid.ini` with English section/comment lines and 0 Cyrillic lines.

Scope: 49 tracked files touched — 26 in `src/` (all 25 units plus
`mirmid.lpr`), 21 in `tests/` (19 `test_*.pas` + 2 fixtures) and `README.md`.
The pre-pass scan (`git ls-files -z | xargs -0 grep -lP
"[\x{0400}-\x{04FF}]"`) found 48 such files; only `context.md` was left, and its
two remaining Cyrillic lines were fixed in this step (the P3 notes above).

Decisions worth keeping:

- **Answer language is neutral.** `DEFAULT_SYSTEM_PROMPT` and
  `SUBAGENT_SYSTEM_PROMPT` now say "reply in the same language the user writes
  in" instead of naming Russian, so the harness no longer hard-codes a locale.
- **CLI prefixes are `Error:` / `Warning:`**, not the `ERROR: ` form quoted in
  plan §9.3: the tool-result convention keeps `ERROR: ` (set by the handlers in
  `mirmid.tool*`), while the human-facing stderr prefixes in `mirmid.cli`
  (`WriteError`, `WriteWarning`) start with a single capital letter. Both
  spellings are now consistent across code, tests and `README.md`.
- **`PluralNoun` is gone** from `mirmid.plan`: `Summary` is built as
  `"3/5 done, 1 failed, 1 skipped"`, which needs no plural forms.
- **`IsRetryableNetErrorText` was re-keyed** to the translated transport texts
  (`could not connect`, `no response`), so a retry decision does not silently
  stop matching after the translation.
- Renamed runtime texts that tests assert on were moved in the same commit as
  the tests: loop guard (`loop detected: %d identical calls of %s`), file tool
  summary (`[mirmid] file: %s | size: %d bytes | lines: %d | hash: %s`),
  `file changed: ... lines removed: N, inserted: M ...`, planner sub-session
  labels (`analysis`, `step sN`), `Task:`/`Plan:`/`Summary:` report headings,
  `Environment: OS ...` and the `[plan]`/`[analysis]`/`[loop]` event tags.
- **Cyrillic test data was replaced, not deleted.** Where a test needs
  multi-byte UTF-8 it now uses Latin with diacritics (`grüße`, `Grüße!`,
  `äöüßéè` as 12 bytes / 6 columns in `test_util`), which keeps the byte/column
  arithmetic and the SSE chunk split (`Grü` + `ße!`) meaningful. Non-ASCII
  typography (`—`, `→`, `│`, `…`, `≈`) is kept on purpose: it is layout, not
  language.
- `grep -P` on the Cyrillic block only works with `LC_ALL=C.UTF-8` in Git
  Bash; without it the pattern is rejected as invalid in a non-UTF-8 locale.

Line endings: `edit_text_file` writes CRLF on Windows, so 23 of the 49 touched
files came back with CRLF and were normalised to LF (`perl -pi -e
's/\r\n/\n/'`) before the final build, per `.gitattributes`
(`* text=auto eol=lf`).

Left for P5: `config/mirmid.ini.example`, `config/mcp.json.example` and
`docs/` (placeholder `.gitkeep` files today).

## 2026-11-09 — phase 5 result (documentation and example configs)

Scope: `README.md` rewritten from the scaffold (purpose, feature list,
Windows/Linux build, the settings sections including the full `[tools]` table,
the `.mirmid` layout, MCP and the license); `docs/` replaced its placeholder
with `index.md` (69 lines) plus the topic notes `architecture.md` (322),
`planning.md` (261), `anthropic.md` (267), `repository.md` (224) and
`roadmap.md` (381) — the counts are `wc -l` at the phase commit `a8f09b3`;
`config/` replaced its placeholder with `mirmid.ini.example` (134 lines) and
`mcp.json.example` (25 lines / 430 bytes); `AGENTS.md` now describes the
phase 5 tree and the standalone Anthropic client.
`docs/.gitkeep` and `config/.gitkeep` are deleted; no placeholders remain.

Verification (all commands run in `C:\ai\git\mirmid` on 2026-11-09):

- `make -B app test` → **467 tests run, 0 errors, 0 failures**, exit code 0 —
  the documentation pass changed no code, so the P4 reference count stands.
- `bin\mirmid.exe --version` → `mirmid 0.1.0`; `--help` prints the full usage
  (Model/Agent/Tools/MCP/Sessions, `--init`, `--list-mcp`, `--plan`), exit 0.
- `--init` in the git-ignored scratch dir `build/p5-init` wrote
  `.mirmid\mirmid.ini` with **46 `section.key` pairs**; compared against
  `config/mirmid.ini.example` the key sets, their order and all 46 values are
  identical (only comments differ), so the example matches what `--init`
  emits, as the settings rule requires.
- `config/mcp.json.example` is strict JSON (no comments): two independent
  parsers (`node -e "JSON.parse(...)"` and PowerShell `ConvertFrom-Json`)
  return one root key `mcpServers` with the `filesystem` and `memory` entries;
  the file is valid UTF-8.
- No Cyrillic: `LC_ALL=C.UTF-8 git grep -nP '[\u0400-\u04FF]'` over the
  tracked tree returns exit 1 (no matches); the same check over the new
  `docs/*.md` and `config/*.example` also finds nothing.
- No removed feature is described as existing. A case-insensitive search still
  finds the excluded names only in the ground rules of `AGENTS.md`, in this
  historical log and in the rejection tests of `tests/test_cli.pas`; the new
  docs and examples do not mention them as capabilities.
- Line endings: every new and edited file is LF; 5 files came back with CRLF
  from `edit_text_file` (`README.md`, `AGENTS.md`, `docs/anthropic.md`,
  `docs/roadmap.md`, `config/mirmid.ini.example`) and were normalised with
  `perl -pi -e 's/\r\n/\n/'`, per `.gitattributes`.
- Encoding: `docs/planning.md`, `docs/architecture.md`, `docs/anthropic.md`,
  `docs/repository.md`, `docs/roadmap.md` and both examples are pure ASCII;
  `README.md`, `AGENTS.md` and `docs/index.md` are UTF-8 and keep non-ASCII
  typography (em dash, arrows, ellipsis) on purpose — layout, not a locale.

Open observations for the remaining P5 steps:

- `plan.md` is still untracked and must stay out of the commit, as must any
  `task*.md` scratch file; `git status` is the source of truth for the file
  list of the commit.
- Independent review of the P5 diff returned **changes required**; the findings
  are fixed and the whole P5 change set, follow-up included, is committed as
  `a8f09b3 docs: rewrite the README and add topic notes and config examples`.
  (The earlier wording said the commit was still pending; corrected in P6.)
- `deps/tls` is still an uninitialised submodule in this checkout, so the build
  falls back to `../tls`; `repository.md` and `README.md` document the
  `TLS_DIR` override and the embedded-roots `roots` goal.
- `mirmid.anthropic` remains a standalone unit: `README.md`, `AGENTS.md` and
  `docs/anthropic.md` all say it is not called by the CLI, the agent loop, the
  planner or the subagent, so any change there is covered by unit tests only.

## 2026-11-09 — phase 5 review follow-up (documentation findings fixed)

An independent subagent reviewed the P5 diff and returned **changes required**
(3 blocking, 12 non-blocking findings: two wrong claims in the INI header and
one wrong file pointer). All are fixed; the change set is documentation and
examples only, so the suite stays at **467 / 0 / 0**.

Blocking findings:

- `config/mirmid.ini.example` promised `true/false/yes/no/on/off` for every
  Boolean key and `#` comments. `TCustomIniFile.ReadBool` reads only `1` as
  true (`CharToBool`, `inifiles.pp`) for `llm.stream`, `agent.plan`,
  `agent.verbose` and `mcp.enabled`, and `Comment` is `;` only: a `#` line with
  `=` inside `[tools]` is a tool key and aborts startup. The header, the
  `[tools]` note and `README.md` now state the exact rules.
- `docs/repository.md` "Where to add what" sent a new `[tools]` key to
  `mirmid.config.pas`. The registry is `TOOL_SWITCHES` in `mirmid.tools.pas`;
  `mirmid.config` only validates it and writes the sample (`SaveSampleIni`).
  Defaults belong to `DefaultConfig` in `mirmid.types.pas`.

Non-blocking findings fixed in the same pass:

- Dependency graphs in `docs/index.md` and `docs/repository.md`, and the status
  bullet in `docs/anthropic.md`, mark `mirmid.anthropic` as standalone instead
  of an edge from `mirmid.agent`; `docs/architecture.md` splits
  `RegisterBuiltinTools` from `RegisterGuiTools`.
- `README.md` `.mirmid` layout gained `logs/`; `AGENTS.md` lists
  `journal/*.jsonl`. The make-target lists in `README.md`, `docs/index.md` and
  `docs/repository.md` now all include `make`/`all` and `tls-dir`.
- `docs/repository.md` notes that `deps/tls` is uninitialised in a fresh
  checkout and that units, not the executable, go to `build/lib`; the
  `build.sh` description in `README.md` matches the script.
- `docs/anthropic.md` says the client timeouts are fixed private fields fed by
  no INI key (the `[llm]` timeouts belong to the OpenAI client) and gives the
  real `BuildRequestJson` field order.
- `docs/planning.md` states that its ASCII `-` stands for the em dash
  (`U+2014`) in the planner texts it quotes.
- `docs/repository.md` phrases the excluded features without repeating the
  literal forbidden names; this entry narrows the earlier "no forbidden strings"
  claim to "no removed feature is described as existing".
- New roadmap item 7.2: a duplicated `[tools]` section is not diagnosed because
  `TIniFile.ReadSection` reads one section, so the "unknown key aborts startup"
  rule has a blind spot.

## 2026-11-09 — phase 6 result (hand-off hygiene, verification, new baseline)

Scope: a pass over the repository state left by P0-P5 — no feature work. 16
tracked files change (`.gitignore`, `README.md`, `config/mirmid.ini.example`,
this log, `docs/repository.md`, `docs/roadmap.md`, four `src/` units and six
`tests/` files — five test units plus the `streamprobe` fixture) plus the
`deps/tls` gitlink that was missing from the index.

Verification (all commands run in `C:\ai\git\mirmid` on 2026-11-09):

- `make -B app test` → **470 tests run, 0 errors, 0 failures**, exit code 0.
  The new reference count is **470 / 0 / 0**, three more than the P4/P5 count of
  467, which is exactly the number of regression tests added in this phase:
  `TestSampleIniCommentPrefix` and `TestCommentPrefixIsSemicolon`
  (`tests/test_config.pas`), `TestHelpListsConnectionAndInteractiveFlags`
  (`tests/test_cli.pas`). `docs/repository.md` and `docs/roadmap.md` were
  updated to the same number.
- `bin\mirmid.exe --version` → `mirmid 0.1.0`; `--help` → exit 0, full English
  usage with the corrected `Tools:` block. A `[\u0400-\u04FF]` scan of the whole
  help output finds nothing; only em dashes and `→` stay, as everywhere else.
- `--init` in a scratch directory outside the tree writes a 96-line
  `.mirmid\mirmid.ini` whose key set is **46 `section.key` pairs**
  (`[llm]` 10, `[agent]` 14, `[tools]` 17, `[workspace]` 2, `[mcp]` 3), and
  `comm`/`diff` against `config/mirmid.ini.example` show no difference in the
  key set, the order or the values — only the comment wording differs.
- No Cyrillic in the tracked tree: `LC_ALL=C.UTF-8 git grep -nP
  '[\u0400-\u04FF]'` → exit 1, confirmed by an independent perl scan of every
  tracked working-tree file. No removed feature is named as a capability: the
  strings of the excluded features and settings do not occur in `src/`,
  `tests/`, `config/`, `docs/` or `README.md`.
- Every edited file is LF (scan of the tracked tree for `\r\n` → no hits), per
  `.gitattributes`.

Decisions worth keeping:

- **`deps/tls` is now a real gitlink.** `.gitmodules`, the `Makefile`,
  `build.sh` (it fast-forwards a clean submodule to the revision pinned in the
  index) and three documents all already assumed a submodule; only the index
  entry was missing. It is registered at `0f6ee94`, the revision the local
  `../tls` checkout is on (= `refs/heads/main` upstream), so
  `git submodule status` now prints `-0f6ee94… deps/tls` (the leading `-` means
  "not initialised in this checkout", which stays true). The alternative —
  weakening the wording to "a plain directory" — would have contradicted the
  build scripts. A fresh clone still needs `git submodule update --init
  deps/tls`; `README.md` and `docs/repository.md` now name both that command and
  the `../tls` fallback.
- **`SaveSampleIni` writes `;` comments, not `#`.** The parser treats only a
  line whose first non-blank character is `;` as a comment, so the old `#` lines
  contradicted the documented format — and a `#` note containing `=` inside
  `[tools]` would have been read as an unknown tool key and aborted startup
  after `--init`. All 24 comment lines of the generated sample were rewritten;
  the two new tests pin both halves of the rule (`#`-prefixed notes never
  appear, every generated line parses as a comment or a known key/value).
- **Stale permission-model comment removed** above `TPlanner.AnalysisPhase`
  (`src/mirmid.planner.pas`): it claimed the deleted `--allow-*` flags still
  apply. It now says tool access is inherited from the parent session through
  `[tools]` and that read-only behaviour comes from the analyst prompt.
  `docs/roadmap.md` item 7.1 ("a removed permission model survives in a code
  comment") is deleted with it, and the priority table was renumbered — the
  duplicate-`[tools]`-section item added in the P5 follow-up is now **7.1**.
- **`.gitignore` cleaned up:** the legacy `.subag/` line is gone (that directory
  is covered per clone by `.git/info/exclude`, so its name no longer enters the
  repository), the obsolete comment about moved OpenSSL sources is gone, and
  `plan.md` joined `task*.md` — the local scratch plan can no longer be staged
  by `git add -A`.
- **Wording of the Boolean rule was too strict.** `#` was already documented as
  "not a comment", but "only a line starting with `;`" missed the leading-blank
  case, and an empty value keeps the default instead of reading as off.
  `README.md` and the header of `config/mirmid.ini.example` now say "only a line
  whose first non-blank character is `;`" and "an empty value keeps the
  default".
- **`--help` now lists every accepted option.** `--connect-timeout` (10 s
  default) and `--interactive` were parsed but undocumented; the `Tools:` block
  of the usage text also had one line of broken indentation. The new test parses
  the help output and then builds a CLI object from those exact forms, so a help
  line for a dead flag cannot pass.
- **No references to local scratch files.** `task1.md`/`task2.md` were quoted in
  comments throughout `src/` and `tests/`, naming files that are not part of the
  repository; the notes were kept and the file names dropped, and the fixture
  line `[read] task1.md` became `[read] notes.md` (asserted in two tests).
  `git grep 'task[12]\.md'` is now empty. `docs/roadmap.md` likewise stopped
  saying the work is tracked in `plan.md` and points to this dated log instead.

Pitfalls re-confirmed:

- `edit_text_file` writes CRLF on Windows: eight files came back with CRLF and
  were normalised with `perl -pi -e 's/\r\n/\n/'` before the build. Check, do
  not assume.
- The Linux path still cannot be exercised here. WSL2 runs Debian trixie and
  even offers `fpc 3.2.2` as a package, but the distro has **no egress** (IPv4
  timeouts, IPv6 "could not connect", curl exit 124/7) while Windows fetches the
  same URL with HTTP 200, and no FPC/Lazarus is pre-installed (`/usr/lib/fpc`,
  `ppcx64` absent, no proxy variables), so `apt-get install fpc` cannot run
  either. Decision: the Windows `make -B app test` run stays the verification
  path; `build.sh`/`make test` on Linux remain unverified in this checkout and
  are documented as such, not claimed as passing.
- `grep`, `wc`, `comm`, `perl` and `make` are not in the default `PATH` of
  `cmd.exe`: the `C:\Program Files\Git\usr\bin` prefix from `AGENTS.md` is
  needed even for read-only checks.
- A running `bin\mirmid.exe` still blocks the link step (error 5 → `move /y
  bin\mirmid.exe bin\mirmid.exe.old`).

E2E: with `src/` changed, one manual run was made against a live
OpenAI-compatible endpoint from a temporary directory outside the repository
(`--no-session --no-stream`): exit 0, one tool round-trip (`exist_file` → "file
exists") and a single-sentence English answer, so transport and TLS work. The
test suite itself still never touches the network.

Review: two independent subagents read the whole diff (docs/config layer and
src/tests layer). No blockers; their findings — the stale `task1.md`/`task2.md`
references, the undocumented options, the imprecise Boolean-comment wording and
the roadmap's pointer to an untracked file — are the fixes listed above, each
covered by a test where behaviour is at stake.

Left open after P6 (unchanged or newly noted): roadmap item 7.1 (a duplicated
`[tools]` section is still not diagnosed), the remaining roadmap items, and
`deps/tls` still being uninitialised in this checkout. `mirmid.anthropic`
remains a standalone unit, untouched by this phase.

## 2026-11-13 — step summary line, one analysis answer, one-line status

Scope: stop the status line from lying about a step that produced nothing and
from wrapping in a narrow terminal, and make sure the analysis answer is printed
exactly once. Ten tracked files change: `src/mirmid.cli.pas`,
`src/mirmid.util.pas`, `tests/fixtures/streamprobe.pas`, `tests/test_planner.pas`,
`tests/test_stream.pas`, `tests/test_util.pas`, plus `docs/architecture.md`,
`docs/planning.md`, `docs/repository.md` and `docs/roadmap.md`.

Verification (all commands run in `C:\ai\git\mirmid` on 2026-11-13):

- `make -B app test` → **473 tests run, 0 errors, 0 failures**, exit code 0.
  The new reference count is **473 / 0 / 0**, three more than the P6 count of
  470: `TestTruncateVisiblePlain` and `TestTruncateVisibleAnsi`
  (`tests/test_util.pas`) and `TestLongStatusTruncatedToOneLine`
  (`tests/test_stream.pas`). `docs/repository.md` and `docs/roadmap.md` were
  updated to the same number.
- `bin\mirmid.exe --version` → `mirmid 0.1.0`, `--help` → exit 0; the diff does
  not touch the usage text, so the option list is unchanged.
- Every edited file is LF (perl scan for `\r` → no hits), per `.gitattributes`.

What changed:

- **A step with hidden text now shows a summary instead of a bare status.**
  `FormatStepEndBrief` (width `STEP_BRIEF_MAX = 120` visible columns, built on
  `VisibleLen`/`TruncateVisible`) takes the status up to the `' — '` separator
  plus the first non-empty line of the step result. `aeStepEnd` picks the full
  `FormatStepEnd` when `StepTextVisible`, the brief when `StepBriefVisible`
  (both `--show-step-result` and `--show-reasoning` off) and `FormatStepEndStatus`
  otherwise; `StepBriefVisible` is the predicate for the middle case.
- **The analysis answer is printed once.** `InAnalysisSubSession` is true for a
  sub-session started with the label `analysis` at `FSubAgentDepth = 1`. In that
  state `aeAssistant` does not print the text and `aeStreamText` refreshes the
  status instead of feeding tokens to the content, so the only output is the
  planner's own `aeAnalysis` event with the `[analysis]` tag. Nested subagents and
  `step sN` sessions are not affected.
- **The status line can no longer wrap.** `PrintStatus` prints
  `TruncateVisible(Status, ContentWidth - 1)`; `TruncateVisible` in
  `src/mirmid.util.pas` counts columns exactly like `VisibleLen` (an ANSI
  sequence is 0, `IsWideCP` is 2, `IsZeroWidthCP` is 0) and closes an open SGR
  with a reset, so a long step name or tool call is cut instead of being wrapped
  onto a second row that the next redraw then only half erases.
- **Coverage.** `TestStepEndResultGating` in `tests/test_planner.pas` was
  rewritten for the brief (status plus first non-empty line, LF and CRLF splits,
  cut at exactly 120 columns with an ellipsis, and no brief when the step text is
  shown). The new `long-status` scenario in `tests/fixtures/streamprobe.pas`
  draws a status wider than the terminal, and `TestLongStatusTruncatedToOneLine`
  runs it with `COLUMNS=40` and checks that the tail marker reaches neither the
  raw output nor the screen.

Pitfalls re-confirmed:

- **The new test caught a real bug in `TruncateVisible`:** an SGR sequence that
  started after the cut point was appended to the result. Fixed minimally — at
  the cut, `Keep`/`HasAnsi` roll back to the previous byte position. A truncation
  helper is worth a test with a coloured string whose escape lands on the
  boundary, not only one whose escape fits.
- `edit_text_file` writes CRLF on Windows again: the six edited files came back
  with CRLF and were normalised with `perl -pi -e 's/\r\n/\n/'` before the build
  (the diffstat fell from a whole-file rewrite to 514 insertions / 34 deletions).
- A stray empty file named `0)` (a shell-redirect artefact) appeared in the
  working tree during the work and shows up as `?? 0)` in `git status`; it must be
  deleted before the commit and must never be staged.
- `perl` and `make` are still not in the default `PATH` of `cmd.exe`; the
  `C:\Program Files\Git\usr\bin` prefix from `AGENTS.md` is required.

## 2026-11-13 — markdown tables wrapped to the terminal width

Scope: a markdown table used to be drawn at its natural width, so in a narrow
terminal (or under the `||` subagent prefix) the frames ran past the edge and a
status redraw could only half erase them. Tables are now wrapped by words inside
the visible content width. Five tracked files change: `src/mirmid.markdown.pas`,
`src/mirmid.cli.pas`, `tests/test_markdown.pas`, `tests/test_stream.pas` and
`tests/fixtures/streamprobe.pas` (1479 insertions / 54 deletions).

Verification (all commands run in `C:\ai\git\mirmid` on 2026-11-13):

- `make -B app test` → **482 tests run, 0 errors, 0 failures**, exit code 0.
  The new reference count is **482 / 0 / 0**, nine more than the previous 473;
  the nine are listed under "Coverage" below.
- `bin\mirmid.exe --version` → `mirmid 0.1.0`; `--help` → exit code 0 with the
  full option list (the usage text is untouched).
- All five edited files are LF (`git ls-files --eol` → `i/lf w/lf` for each),
  per `.gitattributes`; `git status` holds no untracked leftovers.

What changed:

- **The renderers gained an optional width.** `RenderMarkdownCore`,
  `RenderMarkdown` and `RenderTable` in `src/mirmid.markdown.pas` take a trailing
  `MaxWidth: Integer = 0`. `0` reproduces the old behaviour (natural width), so
  every existing caller still compiles and renders as before; `> 0` limits and
  wraps the visible line width. `StripMarkdown` stays unlimited.
- **Column widths are distributed, not guessed.** `RenderTable` still measures
  the natural widths from `VisibleLen(StripMarkdown(cell))`, then computes the
  content budget as `MaxWidth - 3 * NCols - 1` (clamped to at least `NCols`) —
  that is `'| '` + `' |'` per column plus the closing border. Only when the
  natural sum exceeds the budget, `CollectTableStats` (visible text volume per
  column plus the longest word, capped by the new `TABLE_MAX_WORD = 20`) feeds
  `DistributeTableWidths`, which gives every column at least room for its
  longest word and shares the remainder in proportion to the text volume,
  never above the natural width. A narrow table keeps its natural widths, so
  short columns are not padded out to fill the terminal.
- **Cells wrap by words.** `WrapTableCell(Text, Width, ForceBreak)` splits on
  spaces and tabs, measures each piece through `StripMarkdown`, and cuts only at
  `MarkdownBreakSafe` boundaries, so an open `**bold**` or `code` span is never
  cut mid-markup. A word longer than `TABLE_MAX_WORD` is always force-broken by
  `BreakTableWord` (`TruncateVisible` prefix; a character wider than the limit
  gets a line of its own); `ForceBreak` also breaks shorter words, which is what
  `RenderTable` asks for when even the word minimums do not fit the budget, so
  such a table still fits `MaxWidth` instead of growing past it. If a piece still
  cannot be placed (an unbreakable markup span), the column is widened: exposing
  markup is worse than one wide cell.
- **Rows became multi-line blocks.** Each record is rendered as a list of
  physical lines per cell, the height of the row is the tallest cell, short
  cells are top-aligned and padded, and the border is drawn per physical line.
  A final safety pass runs `TruncateVisible(Line, MaxWidth)` over every physical
  line, so nothing can run past the edge and an unfinished SGR is closed instead
  of leaking into the next line.
- **The CLI passes real widths.** In `src/mirmid.cli.pas`: `ShowTable` calls
  `RenderTable(Lines, True, ContentWidth)` (the old "wider than the terminal"
  check stays as a safety net), `EmitGroup` calls
  `RenderMarkdown(G, 1, ContentWidth)`, and `TMirmidApp.OnAgentEvent` computes
  `AvailWidth := TermWidth() - VisibleLen(Pfx)` clamped to a minimum of 1, which
  feeds the three static `RenderMarkdown(Text, 1, AvailWidth)` calls
  (`aeReport`, `aeAnalysis`, `aeAssistant`).

Independent review (a separate subagent reviewed this diff before the commit) and
the fixes it produced:

- **Markers inside a word are literal.** `MarkdownBreakSafe` used to toggle the
  italic flag on every `*`/`_`, so `foo_bar` or `2*3` made every later break point
  "unsafe" and the whole cell came out on one overflowing line. It now opens and
  closes a span with the same rules as `RenderInlineBody` (a marker opens only at
  a word start and closes only after a non-space), so a mid-word marker no longer
  blocks wrapping; `TestBreakSafe` pins the four new cases.
- **A squeezed table now really fits.** When the sum of the word minima exceeded
  the budget, `DistributeTableWidths` split the budget by volume but the wrapper
  refused to break words up to `TABLE_MAX_WORD`, so the widen pass grew the
  columns again and the drawn table could be much wider than `MaxWidth` (and not
  monotone in `MaxWidth`). `RenderTable` detects that case and passes
  `ForceBreak = True` to `WrapTableCell`, so the words are cut to the assigned
  width and the frames stay inside the limit; the default `ForceBreak = False`
  keeps `WrapTableCell` behaviour for every other caller.
- **A wide character at a one-column limit no longer stops the break.**
  `TruncateVisible` cannot fit a double-width character into one column, so
  `BreakTableWord` used to return the whole word; it now emits one whole
  character per piece.
- **A squeezed column keeps one character.** The old volume split could give a
  column width 0 and the later clamp to 1 pushed the table past `MaxWidth` (a
  fuzz run found 127 of 3000 ordinary tables one or more columns too wide).
  `DistributeTableWidths` now reserves one character for every non-empty column
  before the volume split, so the widths still add up to the budget.
- **Forced breaks are ANSI- and marker-safe.** `BreakTableWord` again accounts
  for the `ESC[0m` that `TruncateVisible` appends when it cuts coloured text (the
  cut bytes, not the piece length, drive the remainder) and `MarkdownBreakSafe`
  skips ANSI sequences, so the `[` of an SGR code is not taken for a link
  bracket; a cut between the two characters of a doubled marker (`**`, `__`,
  `~~`, two backticks) is refused, so a forced break cannot print the marker.

Coverage:

- `tests/test_markdown.pas` (uses gained `Classes` and `StrUtils`):
  `TestTableCellWordWrap` (2×2 table at `MaxWidth = 20` wraps by words and
  top-aligns, plus `WrapTableCell('alpha beta gamma', 6)`), `TestTableLongWordBreak`
  (20-column cap, force-break and continuation gluing), `TestTableWrapWideChars`
  (CJK and emoji columns), `TestTableWrapInlineMarkup` (open `**bold**` and
  `code` spans survive; exact output at `MaxWidth = 12`),
  `TestTableWidthsProportional` (6/11 split at a content budget of 17, both
  column orders), `TestTableSqueezedForceBreak` (an 18-column word stays whole
  at a 6-column width by default, is cut into 6+6+6 on `ForceBreak`, the drawn
  table fits `MaxWidth = 10`, a doubled `~~` marker is never split, a two-column
  squeezed table at `MaxWidth = 12` never overshoots it, and a 22-column CJK word
  at width 1 gives one character per piece) and `TestTableNoMaxWidth` (the
  default `0` and a generous 80 give the natural nine-line output of a
  five-record table).
- `tests/test_stream.pas`: `SimulateTerminal` now parses full CSI sequences
  (`ESC '[' 0x20–0x3F final 0x40–0x7E`: SGR skipped, `ESC[nK` erases to the end
  of the line, `ESC[nA` moves up and `ESC[nB` down by `n` with `Count = 0`
  treated as 1), the new `TestTableFitsTerminalWidth` runs the probe with
  `COLUMNS = 40` and checks that no cell text stays on one line, that the frame
  fills exactly 38 visible columns under the `||` prefix, and the exact
  simulated screen, and `TestTableRedrawShrinks` verifies that a table which
  becomes two lines shorter while streaming is erased down to its new bottom
  border (`table-shrink` scenario).
- `tests/fixtures/streamprobe.pas`: a `table` scenario (after `long-status`)
  streams a paragraph, a three-column table wider than the terminal line by
  line, and a closing paragraph; `table-shrink` streams a table whose height
  shrinks while the last row arrives.

Pitfalls re-confirmed:

- `edit_text_file` wrote CRLF again on Windows: the edited files came back with
  CRLF and were normalised with `sed -i 's/\r$//'` before the build. Check
  `git ls-files --eol` after every edit, do not assume.
- The terminal model in `tests/test_stream.pas` skipped only two-byte escape
  sequences, so the colour parameters of the table frames (`ESC[38;2;…m`)
  landed in the screen text. A test that asserts a coloured table needs a real
  CSI parser first — fix the model, then write the expectation.
- The emulator must support every cursor movement the printer emits. It knew
  `ESC[nA` but not `ESC[nB` (the erase pass after a shorter redraw moves down and
  clears), so the cursor stayed put, a later `ESC[10A` clamped to the top row and
  `TestTableRedrawShrinks` showed the table over the paragraph. Add the cursor
  opcodes before trusting a screen assertion.
- Wide characters make width arithmetic easy to get wrong: the column budget
  has to be counted in visible columns (`VisibleLen`) everywhere, including in
  the test expectations (`IsWideCP` counts 2).

Left open: `docs/architecture.md` (table rendering and `ContentWidth`) and the
test counter (482) in `docs/repository.md` and `docs/roadmap.md` are updated in
the same change; `deps/tls` is still uninitialised in this checkout.
