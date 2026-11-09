# Repository

This note maps the working tree: where each unit lives, what the build targets
do, how the fpcunit suite is assembled and which conventions hold for changes.
It complements [../README.md](../README.md) (user-facing usage, settings, CLI)
and [../AGENTS.md](../AGENTS.md) (rules for contributors); the runtime design is
described in [architecture.md](architecture.md).

## Top level

| Path | Contents |
| --- | --- |
| `src/` | The program `mirmid.lpr` and 25 `mirmid.*.pas` units. All code lives here. |
| `tests/` | 19 `test_*.pas` units, the runner `testrunner.lpr`, two fixture programs under `tests/fixtures/` and `rsa_test_vectors.txt`. |
| `config/` | Reference settings files: `mirmid.ini.example` (every section, full `[tools]` table) and `mcp.json.example`. |
| `docs/` | This note and the topic notes listed in [index.md](index.md). |
| `deps/tls` | Git submodule for the mandatory `tls` library (see `.gitmodules`), pinned by the gitlink committed in the tree (`git submodule status`); uninitialised in a fresh checkout, so the build falls back to `../tls` until `git submodule update --init deps/tls` is run. |
| `.mirmid/` | Local state written by the program: `mirmid.ini`, `mcp.json`, `sessions/`, `journal/`, `logs/`. Git-ignored; never commit it. |
| `bin/` | Build output: `mirmid`, `testrunner`, `fakemcp`, `streamprobe` (`.exe` on Windows) and `bin/win64/`. Git-ignored. |
| `build/` | Unit files: `build/lib` (application), `build/testlib` (tests and fixtures), `build/win64` (cross-build). Git-ignored. |

Root files:

| File | Purpose |
| --- | --- |
| `Makefile` | Every build target; the single source of truth for FPC flags and paths. |
| `build.sh` | Linux wrapper: environment checks, `gmkdir` shim, tls submodule sync, roots, `make app`, `make test`. |
| `mirmid.lpi` | Lazarus project: one unit (`src/mirmid.lpr`), search paths `src`, `deps/tls/src`, `../tls/src`, output `build/lib`, target `bin/mirmid`, `-O2`, DWARF3. |
| `.gitattributes` | `* text=auto eol=lf` - every text file is stored and checked out with LF. |
| `.gitignore` | Build output, local settings and state, secrets, session dumps, local task files. |
| `.gitmodules` | Declares `deps/tls` (the `tls` library submodule); its pinned revision is the gitlink in the tree. |
| `LICENSE` | Apache-2.0. |
| `README.md`, `AGENTS.md`, `context.md` | User documentation, contributor rules, dated decision log. |

## Source layout

`src/mirmid.lpr` is the whole program: it sets `DefaultSystemCodePage` to UTF-8,
enables ANSI handling in the Windows console and returns the exit code of
`mirmid.cli.Main`. Everything else is a unit named `mirmid.<area>`.

| Unit | Responsibility |
| --- | --- |
| `mirmid.cli` | Command line, settings resolution, REPL, streamed markdown rendering, status line, session save cycle; starts the planner and MCP servers. |
| `mirmid.config` | INI parsing, the `[tools]` policy, environment overrides, the `--init` sample. |
| `mirmid.markdown` | Markdown parsing used by the terminal renderer. |
| `mirmid.version` | Program name and version. |
| `mirmid.agent` | Message history, system prompt, the model -> tools -> model turn loop, tool dispatch, context estimate, UI events. |
| `mirmid.types` | Shared types: messages, tool calls, events, `TMirmidConfig`. |
| `mirmid.llm` | OpenAI-compatible Chat Completions client: regular and SSE streaming, `tool_calls`, usage, model list. |
| `mirmid.anthropic` | Anthropic Messages API client. Standalone unit; the agent loop does not use it yet (see [anthropic.md](anthropic.md)). |
| `mirmid.http` | HTTP/1.1 transport over plain TCP or TLS, chunked decoding, streaming callbacks, transport retries. |
| `mirmid.tlsclient` | Thin wrapper over the `tls` library and the embedded -> OS trust-store selection. |
| `mirmid.tools` | Tool registry, JSON schemas, `[tools]` enable/disable policy, dispatch and exception containment. |
| `mirmid.toolbuiltin` | File and shell tools; `RegisterBuiltinTools` is the only place where built-in tools are registered. |
| `mirmid.subagent` | The `subagent` tool: a nested agent session with its own context. |
| `mirmid.httprequest` | The `http_request` tool. |
| `mirmid.media` | `read_media_file`: media kind, MIME type, size, image dimensions. |
| `mirmid.screen` | `screen_shoot` and `window_shoot`. |
| `mirmid.gui` | Window observation: `list_windows`, `find_window`, `window_info`. |
| `mirmid.plan` | Plan data model, JSON (de)serialisation, `revise_plan` tool, rendering and report. |
| `mirmid.planner` | The four planning phases, step sub-sessions, retry budgets, final report (see [planning.md](planning.md)). |
| `mirmid.mcp` | MCP stdio transport, JSON-RPC 2.0 client, server manager and tool proxy. |
| `mirmid.session` | Session JSON files and the context journal. |
| `mirmid.summarize` | Automatic context summarisation near the limit. |
| `mirmid.loopguard` | Detector of repeated tool calls. |
| `mirmid.json` | JSON helpers and repair of malformed model output. |
| `mirmid.util` | Platform helpers, UTF-8 handling, number/locale conversion, `RunProcess`. |

Dependency direction (details in [architecture.md](architecture.md)):

```text
src/mirmid.lpr -> mirmid.cli -> mirmid.agent -> mirmid.llm -> mirmid.http -> mirmid.tlsclient -> tls
                                     |-> mirmid.tools -> mirmid.types
                                     |-> mirmid.loopguard
                     mirmid.cli -> mirmid.planner -> mirmid.plan
                     mirmid.cli -> mirmid.mcp -> mirmid.tools
                     mirmid.cli -> mirmid.session / mirmid.summarize
                     mirmid.cli -> mirmid.config / mirmid.json / mirmid.util

tests/testrunner.lpr -> test_anthropic -> mirmid.anthropic -> mirmid.http
  (standalone: no unit in src/ uses mirmid.anthropic; see anthropic.md)
```

Lower layers never import `mirmid.cli` or `mirmid.agent`, and tools are reached
only through `mirmid.tools`. Keep it that way: a direct call from a unit to a
tool handler would bypass the `[tools]` policy.

## Build targets

The `Makefile` owns flags and paths:

- `FPCFLAGS = -O2 -gl -Fusrc $(TLSFLAGS)`; unit output goes to `build/lib`
  (`build/testlib` for the suite) and executables to `bin/`.
- `TLS_DIR` is the first directory containing `src/*.pas` among `deps/tls` and
  `../tls`; `TLS_DIR=<path>` overrides it. Selection is by presence of units, so
  an empty uninitialised submodule cannot shadow a working checkout.
- `ROOTSRES` is `$(TLS_DIR)/src/tlsroots.res`, built by the `roots` goal of the
  tls library itself (`rootsgen` + `fpcres`, override `FPCRES=`).
- `GMKDIR` is `gmkdir -p`, falling back to `mkdir -p` on Unix.

| Target | What it does |
| --- | --- |
| `make` / `make all` / `make app` | Build `bin/mirmid` (`bin\mirmid.exe` on Windows); units go to `build/lib`. Prerequisites: all `src/*.pas`, the tls units and the roots resource. |
| `make test` | Build `bin/testrunner`, `bin/fakemcp`, `bin/streamprobe`, then run `bin/testrunner --all --format=plain`. |
| `make run ARGS="..."` | Build the app and run it with the given arguments. |
| `make lazbuild` | Build through `mirmid.lpi` with `lazbuild`. |
| `make roots` | Rebuild the embedded trust-root resource; fails when no tls checkout exists. |
| `make tls-dir` | Print the selected tls directory (used by `build.sh`, no duplicated logic). |
| `make win64` | Cross-build `bin/win64/mirmid.exe` with `-Twin64` (needs the FPC win64 units). |
| `make clean` | Remove `build/` and `bin/` plus stray `.o`/`.ppu` files in `src/` and `tests/`. |

Operational notes:

- `make test` does not rebuild `bin/mirmid`; after changing `src/` run
  `make -B app test` so the binary and the suite are both fresh.
- On Windows a running `mirmid.exe` cannot be overwritten (link error 5) -
  rename it first.
- The roots resource is a prerequisite of the application, the runner and the
  win64 build, so a clean clone builds it automatically. An older tls checkout
  without the `tls.roots` unit links no resource and needs no roots step.
- `build.sh` checks `fpc` and `make`, installs the `gmkdir` shim over
  `mkdir -p` when the tool is missing, fast-forwards a clean `deps/tls`
  submodule to the revision pinned by the committed gitlink (no network), warns
  when the checkout is outdated or dirty, then runs `roots`, `make app` and
  `make test`. It treats a generated `tlsroots.res` as success even when
  `rootsgen` returns an error (known race in tls).

## Test suite

`tests/testrunner.lpr` is a `consoletestrunner` program that registers the `test_*.pas`
units and runs them; the `test` target invokes it as
`bin/testrunner --all --format=plain`. The reference result is **470 run,
0 errors, 0 failures** (see the latest dated entry in
[../context.md](../context.md)); keep that count current when tests are added.

| Test unit | Covers |
| --- | --- |
| `test_anthropic` | Request validation and JSON building, response and block parsing, errors, SSE streaming (mock data). |
| `test_cli` | CLI event formatting and status lines, including UTF-8 boundary regressions. |
| `test_config` | INI loading/saving, `[tools]` policy, environment overrides, API-key resolution. |
| `test_gui` | `list_windows`, `find_window`, `window_info`; window-dependent checks are skipped when headless. |
| `test_http` | Chunked transfer decoding, including chunk boundaries that split `data:` lines. |
| `test_json` | JSON helpers and message serialisation. |
| `test_llm` | SSE delta accumulator with partial JSON lines, context estimation, model-list parsing. |
| `test_loopguard` | Repeated-call detection thresholds and warnings. |
| `test_markdown` | Markdown parsing and rendering helpers. |
| `test_mcp` | Tool names, JSON-RPC client over a fake transport, server manager, `mcp.json` parsing, integration with `bin/fakemcp`. |
| `test_media` | `read_media_file`, `screen_shoot`, `window_shoot`; screenshot checks are skipped without a desktop. |
| `test_plan` | Plan JSON round trip, validation, step operations, answer parsing, rendering, report, prompts. |
| `test_planner` | `revise_plan` operations (add/remove/reorder/skip), invalid operations, partial application, events, step/report text. |
| `test_session` | Session schema 2 with the plan field, round trip, schema 1 compatibility, invalid plan data. |
| `test_stream` | `TStreamPrinter` regressions through `bin/streamprobe`: indentation, wrapping, status lines, blank lines. |
| `test_subagent` | `subagent` and `http_request`: registration, policy and early argument checks. |
| `test_tlsclient` | Trust-store selection and the embedded root snapshot (needs the roots resource; excluded with `-dTLS_NO_EMBEDDED_ROOTS`). |
| `test_tools` | Built-in tools and access policy, including the file-tool contract (`read_text_file` header, `edit_text_file` hash). |
| `test_util` | Line wrapping and the other `mirmid.util` helpers. |

Fixtures:

| File | Role |
| --- | --- |
| `tests/fixtures/fakemcp.pas` | Minimal MCP server over stdio (JSON-RPC 2.0, one object per line) with `echo`, `boom` (tool error) and `fail` (JSON-RPC error); built as `bin/fakemcp` and used by `test_mcp`. |
| `tests/fixtures/streamprobe.pas` | Runs one `TStreamPrinter` scenario (selected by argument) and writes raw ANSI output; built as `bin/streamprobe` and checked by `test_stream` through a small terminal model. |
| `tests/rsa_test_vectors.txt` | NIST CAVP data for `RSADP`/`RSASP1`, kept as reference material; no test unit loads it today. |

Test rules:

- The suite never touches the network and does not depend on environment
  variables that are not set by the test itself; model and MCP traffic uses mock
  data or local fixtures.
- Tests locate fixtures next to the runner executable (`ParamStr(0)`), so run
  `testrunner` from `bin/` or through `make test`.
- Environment-dependent checks (windows, screenshots) must skip, not fail, on a
  headless machine; a missing `bin/streamprobe` also skips the stream checks.
- Add a unit as `tests/test_<area>.pas` and list it in `uses` of
  `tests/testrunner.lpr`; then run `make test` and record the new count in
  `context.md`.

## Conventions

- **English only.** Code, comments, docs, commit messages, CLI output and
  examples. No Russian text anywhere in the repository.
- Pascal units are named `mirmid.<area>` and every unit starts with
  `{$mode objfpc}{$H+}`.
- Tool failures are returned as text starting with `ERROR: `; successful
  results are plain UTF-8 text.
- Before editing a file, read it and pass the returned `hash` to
  `edit_text_file`; change the smallest possible line range.
- File tools must refuse to enter `.mirmid`; local settings, sessions and logs
  are never committed.
- No database client, no keyboard/mouse input injection and no
  per-capability permission switches. Access to a tool is granted per tool in
  the `[tools]` section; an unknown key is a startup error.
- Commits follow Conventional Commits in English, for example
  `feat(tools): add [tools] section to mirmid.ini`,
  `fix(http): decode chunked transfer-encoding`,
  `docs(repository): describe the test layout`.
- Decisions, environment quirks, measured test counts and mistakes go into
  `context.md` with a date and the verification result; user-visible behaviour
  changes also update `README.md`.
- Text files stay LF (`.gitattributes`); do not let an editor write CRLF into
  `build.sh` or any source file.

FPC pitfalls worth repeating while editing this tree:

- Path options take the value glued: `-Fusrc -FUbuild/lib -FEbin`.
- Parse numbers with `DotToFloat`/`FloatToDotStr`; `StrToFloatDef('0.7')`
  silently returns the default on a comma-decimal locale.
- Never cut UTF-8 by bytes; use `TruncateUTF8`/`SanitizeUTF8`.
- Do not pass raw non-ASCII literals to `TJSONObject.Add`; build strings through
  the JSON layer.
- `TProcess`/`RunProcess` must be non-interactive (new session on Unix,
  `CloseInput` after start), otherwise `shell` hangs until the timeout.
- In `uses ... Windows` the RTL shadows `SysUtils.GetEnvironmentVariable` and
  `FindFirst`/`FindNext`/`FindClose`; qualify such calls.

## Where to add what

| Change | Touch |
| --- | --- |
| New built-in tool | Handler and `RegisterBuiltinTools` in `mirmid.toolbuiltin.pas` (or its own unit), schema and dispatch plus the `[tools]` entry in `TOOL_SWITCHES` in `mirmid.tools.pas`, the `--init` sample in `SaveSampleIni` (`mirmid.config.pas`), `config/mirmid.ini.example`, `README.md`, `AGENTS.md`, tests in `tests/test_tools.pas`. |
| New setting | `TMirmidConfig` and its default in `DefaultConfig` (`mirmid.types.pas`), parsing in `mirmid.config.pas`, `--init` sample, `config/mirmid.ini.example`, `README.md` table, `tests/test_config.pas`. |
| New model client | A unit beside `mirmid.llm`/`mirmid.anthropic`, its own test unit, a note under `docs/` linked from `docs/index.md`. |
| New documentation note | File under `docs/`, an entry in the map of `docs/index.md`, cross-links from the related notes. |
