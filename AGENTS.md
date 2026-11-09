# mirmid — agent instructions

Console, open-source AI-agent harness written in **Free Pascal 3.2.2** and built
either with GNU make (`Makefile`) or with **Lazarus 4.0** (`mirmid.lpi`). The
agent talks to any OpenAI-compatible endpoint (`POST /chat/completions`, plus the
Anthropic Messages API), calls tools on its own (files, shell, screen, MCP),
keeps an interactive REPL and stores sessions on disk.

This file is read into the system prompt of the root session on every reset, so
keep it short: environment quirks, decisions and pitfalls go to
[context.md](context.md), user-facing documentation goes to [README.md](README.md).
License: Apache-2.0.

## Ground rules

- **English only.** Code, comments, unit and tool descriptions, docs, commit
  messages, CLI output, examples. No Russian text anywhere in the repository;
  translate existing fragments whenever you touch a file.
- The project is standalone: do not reference any upstream, predecessor or
  sibling project, its author or its repository in code, docs or commit
  messages.
- **No PostgreSQL support.** No `pg_*` units, no `pg_execute` tool, no
  `[databases]` section, no SQL client/wire/SCRAM code.
- **No keyboard/mouse input.** No `click`, `type_text`, `key_press` tools and no
  code that injects input events. Window observation (`list_windows`,
  `find_window`, `window_info`) and screenshots stay.
- **No `ca_file`, `allow_write`, `allow_shell`, `allow_http`, `allow_input`
  settings.** Access to every tool is granted per tool in the `[tools]` section
  of the INI file (see below). HTTPS trust: embedded root store first, then the
  OS store; nothing else is configurable.
- Never commit secrets, local INI files, sessions or build artefacts.

## Repository state (2026-11-08, after the phase 2 input removal)

The tree is no longer a docs-only scaffold: it builds and passes its suite
(`make -B app test` -> 0 errors / 0 failures; the reference test count is the
latest dated entry in `context.md`).

- `src/` — 25 `mirmid.*.pas` units plus the program `src/mirmid.lpr`.
- `tests/` — 19 `test_*.pas` units, `testrunner.lpr`, `fixtures/fakemcp.pas`,
  `fixtures/streamprobe.pas`, `rsa_test_vectors.txt`.
- `Makefile`, `build.sh`, `mirmid.lpi`, `.gitmodules` — the last one declares the
  `deps/tls` submodule (`https://github.com/svetodar/tls.git`) but it is not
  initialised yet, so the build currently falls back to `../tls`.
- `config/` and `docs/` — placeholders (`.gitkeep`) only.
- `bin/` and `build/` are git-ignored artefacts produced by `make app` and
  `make test`.
- `.gitattributes` — text files are stored and checked out with LF
  (`* text=auto eol=lf`); keep it that way so `build.sh` stays runnable on Linux
  and no file drifts back to CRLF.

Nothing of this cleanup is committed yet — everything is still untracked or
modified in the working tree, so `git status` is the source of truth.

## Build and test

Windows (cmd.exe; `fpc`, `make` and the Unix tools are not in `PATH`):

```bat
set "PATH=C:\lazarus\fpc\3.2.2\bin\x86_64-win64;C:\Program Files\Git\usr\bin;%PATH%"
cd /d C:\ai\git\mirmid
make app     rem -> bin\mirmid.exe, units in build\lib
make test    rem -> bin\testrunner.exe --all --format=plain
```

Linux (Debian 13; `fpc`, `make`, `lazbuild` are already in `PATH`):

```bash
./build.sh                                  # gmkdir shim + deps + roots + app + test
PATH="$PWD/build/.shim:$PATH" make test     # same, manually
```

Also: `make clean`, `make lazbuild` (via `mirmid.lpi`), `make run ARGS=...`,
`make win64` (cross-build, needs FPC win64 units).

- **`make test` does not build `bin/mirmid.exe`** — after touching `src/` run
  `make app` too, otherwise you verify a stale binary.
- Tests spawn external fixtures (`bin/fakemcp`, `bin/streamprobe`, built by the
  `test` target); run `testrunner` from `bin/`.
- The **tls** library (Pascal TLS client + crypto, `https://github.com/svetodar/tls`)
  is mandatory: the directory is picked by the presence of units (`deps/tls`
  submodule, then `../tls`, override with `TLS_DIR`); an empty uninitialised
  submodule must not shadow a working checkout.
- Embedded trust roots (`tls.roots`) are generated from
  `$(TLS_DIR)/src/tlsroots.res` by the library's own `roots` goal
  (`rootsgen` + `fpcres`); the resource is a prerequisite of the binaries, so a
  clean clone builds it. Without the resource (or with `-dTLS_NO_EMBEDDED_ROOTS`)
  trust falls back to the OS store.
- A running `bin/mirmid.exe` cannot be overwritten (link error 5) — first
  `move /y bin\mirmid.exe bin\mirmid.exe.old`.

## Verification before you report back

1. `make -B app test` (or `./build.sh`): **0 errors, 0 failures**. The current
   reference test count is recorded in `context.md` (latest dated entry).
2. Smoke: `bin/mirmid.exe --version` (`mirmid 0.1.0`) and `--help`.
3. E2E against a live provider only when network/LLM/TLS code changed, manually
   (`--no-session --no-stream`); the test suite never touches the network.
4. Hand the diff to a separate subagent for an independent review.

## Target layout

```
src/mirmid.lpr             program entry point
src/mirmid.cli.pas         CLI, REPL, markdown rendering, status line
src/mirmid.agent.pas       turn loop (model -> tools -> model), events
src/mirmid.llm.pas         OpenAI-compatible client (streaming, tool_calls)
src/mirmid.anthropic.pas   Anthropic Messages API client
src/mirmid.http.pas        HTTP/1.1 transport
src/mirmid.tlsclient.pas   thin wrapper over the tls library
src/mirmid.tools.pas       registry, schemas, dispatch, enable/disable policy
src/mirmid.toolbuiltin.pas file and shell tools
src/mirmid.subagent.pas    the `subagent` tool (nested agent session)
src/mirmid.httprequest.pas the `http_request` tool
src/mirmid.media.pas       `read_media_file`
src/mirmid.screen.pas      `screen_shoot`, `window_shoot`
src/mirmid.gui.pas         window observation (`list_*`, `find_*`, `window_info`)
src/mirmid.mcp.pas         MCP stdio client (JSON-RPC 2.0)
src/mirmid.config.pas      INI parsing, `[tools]` section, env overrides
src/mirmid.session.pas     session persistence (JSON)
src/mirmid.json.pas        JSON helpers
src/mirmid.types.pas       shared types (UTF-8 defaults)
src/mirmid.util.pas        platform helpers, number/locale, UTF-8, RunProcess
src/mirmid.markdown.pas    markdown rendering
src/mirmid.plan.pas        plan data model, `revise_plan` tool
src/mirmid.planner.pas     plan -> steps -> report driver
src/mirmid.summarize.pas   context auto-summarisation
src/mirmid.loopguard.pas   repeated-call detector
src/mirmid.version.pas     program name and version
tests/                     fpcunit suite (testrunner.lpr) + fixtures
config/                    mirmid.ini.example, mcp.json.example
docs/                      architecture and topic notes
.mirmid/                   local settings, sessions, logs (git-ignored)
```

Layering: `mirmid.lpr` -> `mirmid.cli` -> `mirmid.agent` -> `mirmid.llm` /
`mirmid.anthropic` -> `mirmid.http` -> `mirmid.tlsclient`. Tools are registered
in one place (`RegisterBuiltinTools` in `mirmid.toolbuiltin`) and reached only
through `mirmid.tools`.

## Settings model

All local state lives in `./.mirmid`: `mirmid.ini`, `mcp.json`,
`sessions/*.json`, `logs/*.jsonl`. Auxiliary sessions of subagents and plan
steps use the suffixes `*_sub_<n>.json`, `*_step_<id>.json`, `*_analysis.json`
and are hidden from `--list-sessions`. File tools must refuse to enter
`.mirmid`.

Every built-in tool is switched on or off in the INI file — one key per tool,
`1`/`0`:

```ini
[tools]
file_list=1
exist_file=1
read_text_file=1
read_pascal_interface=1
grep=1
list_windows=1
find_window=1
window_info=1
edit_text_file=0
copy_file=0
shell=0
http_request=0
subagent=0
read_media_file=0
screen_shoot=0
window_shoot=0
revise_plan=1
```

Rules for the `[tools]` section:

- The set of keys is the tool registry: read-only inspection tools default to
  `1`, everything that writes files, runs shell commands, opens network
  connections or captures the screen defaults to `0`.
- A disabled tool must be fully absent for the model: its schema is not sent in
  the `tools` array, and the handler still refuses to run if called (subagents
  and MCP reuse the same registry, so the check belongs to the tool, not to the
  CLI).
- An unknown key is a startup error (`Error: unknown tool "<name>"; known
  tools: ...` on stderr, exit code 1) — a typo must never silently disable or
  enable something.
- `mcp__<server>__<tool>` entries are governed by the `[mcp]` section, not by
  per-tool keys.

## Conventions

- Pascal units are named `mirmid.<area>`; `{$mode objfpc}{$H+}` in every unit.
- Tool failures come back as text prefixed with `ERROR: `; results are plain
  UTF-8 text.
- Before editing a file, read it and pass the returned `hash` to
  `edit_text_file`; change the smallest possible range.
- Commits: Conventional Commits in English, e.g. `feat(tools): add [tools]
  section to mirmid.ini`, `fix(http): decode chunked transfer-encoding`,
  `docs(context): record tls roots build`.
- Decisions, environment quirks, measured test counts and mistakes go into
  `context.md` with a date and the verification result; user-visible behaviour
  changes also update `README.md`.

## Common pitfalls (details in context.md)

- FPC path options take the value **glued**: `-Fusrc -FUbuild/lib -FEbin`; with a
  space FPC treats the value as another source file.
- `gmkdir` needs `-p`; on Linux it may be missing — use the `build/.shim` shim.
- Parse numbers with `DotToFloat`/`FloatToDotStr`: on a comma-decimal locale
  `StrToFloatDef('0.7')` silently returns the default (`temperature`, etc.).
- Never cut UTF-8 by bytes — `TruncateUTF8`/`SanitizeUTF8`; count multi-byte
  separators by `Length`.
- Do not pass raw non-ASCII literals to `TJSONObject.Add`; build strings through
  the JSON layer.
- `TProcess`/`RunProcess` must be non-interactive (new session on Unix,
  `CloseInput` after start), otherwise `shell` hangs until the timeout.
- Tests: no network, no dependency on host environment variables, skip
  `xwininfo`/`xprop` checks in headless mode.
- In `uses ... Windows` the RTL names `GetEnvironmentVariable`,
  `FindFirst`/`FindNext`/`FindClose` shadow `SysUtils` — qualify such calls.

## Workflow

1. Read `context.md` (sections for your topic) and the relevant units first —
   decisions and past mistakes are already recorded there.
2. Delegate small independent tasks (environment probing, coding, tests) to
   subagents: they have the same tools and rights.
3. Change code minimally and add a regression test for every bug you fix.
4. Run the build and the test suite, update `context.md` (and `README.md` when
   behaviour changes), then report back with the facts from the commands.
