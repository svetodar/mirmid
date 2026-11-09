# mirmid

mirmid is a console, open-source AI-agent harness written in Free Pascal
(3.2.2). It talks to any OpenAI-compatible chat-completions endpoint, calls
tools on its own (files, shell, network, screen, windows, MCP servers), keeps an
interactive REPL and stores sessions on disk. It builds either with GNU make
(`Makefile`) or with Lazarus (`mirmid.lpi`).

License: Apache-2.0.

## Features

- **OpenAI-compatible client** (`POST /chat/completions`): streaming (SSE),
  `tool_calls`, `reasoning_content` / `reasoning_effort`, usage reporting and
  model listing (`--list-models`).
- **Tool registry with per-tool switches.** Every built-in tool is enabled or
  disabled in the `[tools]` section of the INI file; a disabled tool is neither
  sent to the model nor allowed to run.
- **Built-in tools**: file listing/reading/editing, copying, `grep`, Pascal
  interface reader, shell, HTTP request, subagents, media information,
  screenshots, window observation and plan revision (see the table below).
- **Plan mode** (`--plan`): the agent writes a plan, executes it step by step in
  separate sub-sessions and prints a final report; `revise_plan` lets it change
  the plan while working.
- **Subagents**: a nested agent session with its own context that returns only
  the result of the work.
- **MCP (Model Context Protocol)** over stdio/JSON-RPC 2.0: external tool
  servers from `mcp.json`, registered as `mcp__<server>__<tool>`.
- **Sessions** in `.mirmid/sessions` with a context journal, automatic
  summarisation near the context limit and a loop guard against repeated tool
  calls.
- **Interactive REPL** with streamed markdown rendering, a context/token status
  line and optional reasoning and tool output.
- **Anthropic Messages API client** (`src/mirmid.anthropic.pas`): request
  validation, regular and streaming responses, tools and errors. It is a
  standalone unit and is not wired into the agent loop yet.

## Requirements

- Free Pascal 3.2.2 (x86_64) and GNU make; Lazarus 4.0 is optional.
- The `tls` library (Pascal TLS client and crypto) is mandatory. The Makefile
  picks the first directory containing `src/*.pas` among `deps/tls` (declared
  in `.gitmodules`) and `../tls`; `TLS_DIR` overrides the choice. To fetch it
  separately: `git clone https://github.com/svetodar/tls.git ../tls`.
- Linux: `fpc`, `make`, `git` and the usual build tools. Window observation
  needs `xwininfo`/`xprop` from `x11-utils`; screenshots need one of `grim`,
  `scrot`, ImageMagick `import`, `gnome-screenshot` or `spectacle`.
- Windows: Free Pascal 3.2.2 x86_64-win64 and GNU make on `PATH` (the FPC
  distribution ships `gmkdir`; Git for Windows provides the Unix tools used by
  the Makefile).

## Build and test

Both flows expect the tls checkout to be in place (see Requirements).

### Windows (cmd.exe)

```bat
set "PATH=C:\lazarus\fpc\3.2.2\bin\x86_64-win64;C:\Program Files\Git\usr\bin;%PATH%"
cd /d C:\path\to\mirmid
make app
make test
```

The result is `bin\mirmid.exe`; units go to `build\lib`.

### Linux

```bash
./build.sh                                  # gmkdir shim, roots, app, tests
```

`build.sh` checks `fpc` and `make`, installs the `gmkdir` shim, syncs the tls
checkout, builds the root resource, then runs `make app` and `make test`. To
run the suite manually on a machine without `gmkdir`:

```bash
PATH="$PWD/build/.shim:$PATH" make test
```

If the tls checkout is not under `deps/tls`, point the build at it:

```bash
TLS_DIR=../tls ./build.sh
```

### Other make targets

| Target | Purpose |
| --- | --- |
| `make` / `make all` | build the application (same as `make app`) |
| `make app` | build `bin/mirmid` (`bin\mirmid.exe` on Windows) |
| `make test` | build and run the fpcunit suite (no network access) |
| `make run ARGS="..."` | run the built binary with arguments |
| `make lazbuild` | build through `mirmid.lpi` with `lazbuild` |
| `make roots` | rebuild the embedded TLS root resource |
| `make tls-dir` | print the selected tls directory (used by `build.sh`) |
| `make win64` | cross-build `bin/win64/mirmid.exe` (needs win64 FPC units) |
| `make clean` | remove build output |

`make test` does not rebuild `bin/mirmid`. After changing `src/`, run
`make -B app test` so the binary and the suite are both fresh. A running
`mirmid.exe` cannot be overwritten on Windows — rename it first.

## Quick start

```bash
bin/mirmid --init                 # writes .mirmid/mirmid.ini
# edit base_url, model and api_key in .mirmid/mirmid.ini
bin/mirmid --list-models          # optional: query the provider
bin/mirmid "Find the TODOs in src and summarise them"
bin/mirmid -i                     # interactive REPL
```

`--init` writes a documented sample file. Use `config/mirmid.ini.example` as a
reference and `config/mcp.json.example` for MCP servers. Run `mirmid --help`
for the complete option list.

## Settings

Settings are read in this order, each layer overriding the previous one:

1. built-in defaults;
2. `<workdir>/.mirmid/mirmid.ini` (or the file given with `-c/--config`);
3. `MIRMID_*` environment variables;
4. command-line options.

`--workdir` changes the working directory of the tools and the root of the
`.mirmid` directory; the default is the current directory.

Boolean keys: `[tools]` keys and `MIRMID_*` variables accept `1`/`0`,
`true`/`false`, `yes`/`no` and `on`/`off`; `stream`, `plan`, `verbose` and
`[mcp] enabled` accept only `1` (on) or `0` (off), and any other value reads
as off. Only a line starting with `;` is a comment; `#` is not.

### `.mirmid` layout

```
.mirmid/
  mirmid.ini                 settings
  mcp.json                   MCP server descriptions
  sessions/
    <session-id>.json        saved dialogue (and plan, when present)
    <id>_analysis.json       plan mode: preliminary analysis
    <id>_step_<step>.json    plan mode: one step sub-session
    <id>_sub_<n>.json        subagent sub-session
  journal/
    <session-id>.jsonl       context journal of the saved session
  logs/
    <base>.jsonl             model call log (analysis, plan, step, report)
```

Auxiliary `*_analysis`, `*_step_*` and `*_sub_*` sessions are hidden from
`--list-sessions`. File tools refuse to enter `.mirmid`. Sessions are not saved
with `--no-session`; `-s/--session ID` continues an existing session or creates
one with that identifier.

### `[llm]`

| Key | Meaning |
| --- | --- |
| `base_url` | base URL of the OpenAI-compatible API (default `http://127.0.0.1:1234/v1`) |
| `api_key` | API key literally, or `&NAME` to read environment variable `NAME` |
| `model` | model name |
| `temperature` | sampling temperature (default `0.1`) |
| `max_tokens` | maximum answer tokens (default `32768`) |
| `reasoning` | `reasoning_effort`: `none`, `minimal`, `low`, `medium`, `high`; empty — not sent |
| `stream` | `1`/`0`, stream the answer over SSE (default `1`) |
| `context_window` | model context size in tokens (default `128000`) |
| `timeout` | HTTP request timeout in seconds (default `1800`) |
| `connect_timeout` | connection timeout in seconds (default `10`) |

`api_key` is expanded only with the `&` prefix. The expanded value is never
written back to the INI file.

### `[agent]`

| Key | Meaning |
| --- | --- |
| `max_steps` | limit of model → tools iterations per turn; `0` — unlimited |
| `plan` | `1`/`0`, plan mode: plan → steps → report (default off) |
| `plan_step_max_steps` | iteration budget of one plan step; `0` — unlimited |
| `plan_step_fix_attempts` | retries of a step after an abnormal result (default `1`) |
| `plan_max_step` | maximum number of steps in the plan; `0` — unlimited |
| `system_prompt` | system prompt of the root session |
| `verbose` | `1`/`0`, verbose output |
| `tool_output_lines` | maximum tool output lines on screen, the middle is cut (default `9`, `0` — no limit) |
| `summarize_threshold_percent` | auto-summarisation threshold as % of the context (default `90`, `0` — off) |
| `summarize_threshold_tokens` | absolute threshold in tokens; `0` — use the percentage |
| `summarize_min_saving_percent` | minimum context reduction for a useful summary (default `50`) |
| `summarize_min_saving_tokens` | absolute minimum reduction; `0` — use the percentage |
| `loop_warn` | warn after N identical tool calls in a row (default `3`, `0` — off) |
| `loop_stop` | stop the turn after N identical tool calls (default `5`, `0` — off) |

### `[workspace]`

| Key | Meaning |
| --- | --- |
| `shell_timeout` | shell command timeout in seconds (default `60`, `0` — no limit) |
| `shell_output_limit` | maximum shell output in bytes (default `65536`, `0` — no limit) |

### `[mcp]`

| Key | Meaning |
| --- | --- |
| `enabled` | `1`/`0`, connect servers from `mcp.json` (default `1`) |
| `config` | path to `mcp.json`; empty — `<workdir>/.mirmid/mcp.json` |
| `timeout` | MCP server response timeout in seconds (default `60`) |

### Environment variables

`MIRMID_BASE_URL`, `MIRMID_API_KEY`, `MIRMID_MODEL`, `MIRMID_TEMPERATURE`,
`MIRMID_REASONING`, `MIRMID_STREAM`, `MIRMID_PLAN`, `MIRMID_CONTEXT_WINDOW`,
`MIRMID_MCP`, `MIRMID_MCP_CONFIG`, `MIRMID_MCP_TIMEOUT`.

### `[tools]`

Every built-in tool has one key, `1` (enabled) or `0` (disabled). The key set
below is the registry: an unknown key is a startup error.

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

| Tool | Default | What it does |
| --- | --- | --- |
| `file_list` | `1` | read-only: list files and directories |
| `exist_file` | `1` | read-only: check whether a path exists |
| `read_text_file` | `1` | read-only: read a text file with its hash header |
| `read_pascal_interface` | `1` | read-only: read the interface section of a Pascal unit |
| `grep` | `1` | read-only: search a substring in text files |
| `list_windows` | `1` | read-only: list open windows |
| `find_window` | `1` | read-only: find a window by title or class |
| `window_info` | `1` | read-only: window details and child controls |
| `edit_text_file` | `0` | writes files: create a file or replace a line range |
| `copy_file` | `0` | writes files: copy a file |
| `shell` | `0` | runs commands in the system shell |
| `http_request` | `0` | performs an HTTP request |
| `subagent` | `0` | runs a separate agent session |
| `read_media_file` | `0` | reads media metadata (image, audio, video) |
| `screen_shoot` | `0` | writes an image: capture the whole screen |
| `window_shoot` | `0` | writes an image: capture the active window |
| `revise_plan` | `1` | plan revision while plan mode is on |

Rules:

- Read-only inspection defaults to `1`; tools that write files, run commands,
  open connections, spawn a session or capture the screen default to `0`.
- A disabled tool is absent from the request `tools` array **and** its handler
  refuses to run, because subagents, plan steps and MCP share the registry.
- An unknown key aborts startup with `Error: unknown tool "<name>"; known
  tools: ...` (exit code 1), and a duplicate key is rejected as well — a typo
  never falls back to a default.
- `mcp__<server>__<tool>` entries are governed by the `[mcp]` section, not by
  per-tool keys.

## MCP

mirmid starts MCP servers as child processes and talks JSON-RPC 2.0 over their
stdin/stdout. Servers are described in `.mirmid/mcp.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/work"],
      "env": {"LOG_LEVEL": "info"},
      "cwd": "/work",
      "enabled": true,
      "timeout": 60
    }
  }
}
```

`command` is required; `args`, `env`, `cwd`, `enabled` and `timeout` are
optional. An HTTP `url` is reported as unsupported. Tools of a server appear in
the registry as `mcp__<server>__<tool>` and are called through the same
registry as built-in tools. Use `--mcp-config FILE`, `--no-mcp`, `--mcp-timeout
SEC` and `--list-mcp` to control them from the command line.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Documentation

- [docs/index.md](docs/index.md) — documentation entry point
- [docs/architecture.md](docs/architecture.md) — layers, turn loop, tools, sessions, MCP
- [docs/planning.md](docs/planning.md) — plan mode, `revise_plan`, step budgets
- [docs/anthropic.md](docs/anthropic.md) — the Anthropic Messages API client unit
- [docs/repository.md](docs/repository.md) — source tree, build targets, tests
- [docs/roadmap.md](docs/roadmap.md) — known gaps and next tasks
- [AGENTS.md](AGENTS.md) — contribution and verification rules
