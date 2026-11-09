# Roadmap

This note lists the work that the current tree shows as missing or unfinished.
It is deliberately narrow: every item points at the unit, symbol or setting that
makes the gap visible and has a closing condition that a test can check. Feature
ideas that no code currently promises are not listed here.

Snapshot: working tree of 2026-11-09. The build is green (`make -B app test`,
470 tests, 0 errors, 0 failures; see the latest dated entry in
[../context.md](../context.md)), the suite never touches the network, and
`bin/mirmid --version` reports `mirmid 0.1.0`. Nothing below blocks this state.

## How to read an entry

Each entry has the same three parts:

- **Evidence** - the code that shows the gap. Symbols are quoted instead of line
  numbers because the code moves; search for the name.
- **Work** - the smallest change that closes the gap, not a redesign.
- **Done when** - the observable result, usually a test or a measured behaviour.

An item without evidence does not belong in this file. When an item is closed,
delete it here and record the commit and the new test count in `context.md`.

## Priority

1. Context safety (section 1): a long session can lose history or exceed the
   model window.
2. Transport reliability (section 3): a transient provider failure ends a turn.
3. Provider coverage (section 2): the second client is tested but unreachable.
4. MCP coverage (section 4).
5. REPL ergonomics and platform parity (sections 5 and 6).
6. Hygiene (section 7): cheap, do it with any neighbouring change.

## 1. Context safety

### 1.1 Auto-summarisation fires at most once per process

**Evidence.** `TMirmidApp.CheckAutoSummarize` returns while
`FLastSummarizeEffective` is true. The flag is assigned in `DoSummarize` and
initialised only in the constructor, so nothing clears it when the new, shorter
session grows again.

**Effect.** After one successful summary, a long session silently approaches the
model window; only a manual `/summarize` helps.

**Work.** Clear the guard once the measured context is below the threshold
again, or store the context size at which the last summary was taken and compare
against it. Keep the original "do not summarise in a loop" property.

**Done when.** A test grows the context, summarises, grows it again and observes
a second summary request, while another test keeps a single summary when the
context stays above the threshold.

### 1.2 Summaries drop the recent tail and undercount tool calls

**Evidence.** `BuildSummarizedMessages` returns only the system prompt plus one
user message. `SummarizeSession` estimates tokens from `Role`, `Content` and
`Reasoning`, while `TAgent.ContextTokens` also counts the tool-call id, name and
arguments. In plan mode the plan is saved with the new session (`SaveSession` in
`DoSummarize`) but is not part of the rebuilt history.

**Effect.** The model continues without verbatim recent context (the latest file
contents, the last command output), and the reported saving is overstated for
tool-heavy turns.

**Work.** Retain the last N messages behind a setting, include a rendered plan
when plan mode is on, and reuse the agent estimator instead of a second one.

**Done when.** A test with assistant and tool messages keeps the tail and
reports the same estimate as `TAgent`.

### 1.3 Tool results enter the context unbounded

**Evidence.** `TAgent.RunTurn` appends `Outcome.Text` to an `mrTool` message
unchanged. `[agent] tool_output_lines` shortens the screen rendering only
(`mirmid.cli`). `shell` has its own byte cap (`shell_output_limit`),
`read_text_file` limits lines (400 by default) but not the length of a line, and
`read_media_file` can encode up to `MAX_MEDIA_BASE64` (256 KiB) of a file as
base64. Session files store the same text.

**Effect.** One large file, grep hit or media call can consume the window, and
it is re-sent on every following turn.

**Work.** Apply a shared per-result byte or token budget before the message is
appended, with an explicit truncation note that the model can see. Decide
whether the saved session keeps the full text or the truncated one.

**Done when.** A test appends an oversized result and asserts that the stored
message, the request body and the context estimate all obey the budget.

## 2. Provider coverage

### 2.1 The Anthropic client is not selectable

**Evidence.** `src/mirmid.anthropic.pas` implements request building and
validation, regular and streaming responses, tools and error mapping, and
`tests/test_anthropic.pas` covers it. No unit in `src/` imports it.
`TMirmidConfig` has one OpenAI-shaped `BaseUrl`, `ApiKey` and `Model`, `TAgent`
creates `mirmid.llm.TLLMClient`, and `README.md` states that the unit is not
wired into the agent loop yet.

**Work.** Add a provider switch (`[llm]` key plus a CLI option), translate
`TMessage` history into Anthropic `messages` with a top-level `system`, map
`tool_calls` to `tool_use`/`tool_result` blocks and back, and feed usage into
the status line.

**Done when.** A tool-using turn completes against a mock Anthropic endpoint and
the agent tests run for both clients.

### 2.2 One model for every role

**Evidence.** `mirmid.planner` creates a `TLLMClient` from the parent config in
the analysis, plan, step and report phases; `mirmid.summarize` does the same; a
subagent copies `Ctx.Cfg`. `[llm]` exposes a single `model` key.

**Work.** Optional planner, subagent and summariser model overrides that inherit
when empty, wired through `TMirmidConfig`, `LoadIni`, the `--init` sample and the
settings documentation.

**Done when.** Config tests cover inheritance and overrides, and planner tests
assert which model each phase requests.

### 2.3 Prompt caching is read but never requested

**Evidence.** `TAnthropicUsage` parses `cache_creation_input_tokens` and
`cache_read_input_tokens`, yet `BuildRequestJson` emits no `cache_control`
blocks, so those counters can only be zero.

**Work.** Mark the system prompt and, when useful, the last tool schema with
cache breakpoints behind a setting, and write the counters into the model-call
log.

**Done when.** A built request contains the breakpoints and a two-call test
shows a cache read on the second call.

### 2.4 Messages are text-only

**Evidence.** `TMessage.Content` is a string and `MessagesToJSONArray` emits
role/content pairs. `read_media_file` returns a description plus optional base64
text, so even an image reaches the model as text.

**Work.** Either add content-part arrays (`image_url`, `input_audio`) with a
per-provider capability check, or record in README that media is metadata only.
Choose one; a half-implemented part is worse than the current contract.

**Done when.** The chosen behaviour is covered by a test and stated in README.

## 3. Transport and interruption

### 3.1 Rate limits and server errors are not retried

**Evidence.** The header comment of `mirmid.http` says only transport failures
repeat, and `HttpRequest` returns 4xx/5xx to `TLLMClient.Chat`, which turns them
into `Err` and ends the turn. `TAnthropicError.Retryable` already marks 429 and
5xx, but nothing consumes the flag, and `Retry-After` is not read anywhere in
`src/`.

**Work.** Bounded retry with backoff and jitter, honouring `Retry-After`, only
before the first streamed delta. Non-retryable 4xx stay immediate.

**Done when.** Fixture tests cover 429 with and without `Retry-After`, 503, 400
and a stream that fails after the first delta without duplicating text.

### 3.2 Streaming requests do not follow redirects

**Evidence.** `HttpRequest` and `HttpRequestEx` follow 3xx up to
`MAX_REDIRECTS`; `HttpRequestStream` and `HttpRequestStreamEx` contain no
redirect loop. A base URL that redirects (http to https, a gateway) works with
`--no-stream` and fails in the default streamed mode.

**Work.** Follow redirects for streaming too, but only before the first body
chunk.

**Done when.** A fixture redirects once and both modes reach the same endpoint.

### 3.3 Every request opens a fresh connection

**Evidence.** `mirmid.http` writes `Connection: close` for every request. There
is no keep-alive pool, no `Accept-Encoding`, no proxy handling, and no way to
add headers from settings: `HttpRequestEx` exists, but only `mirmid.anthropic`
passes headers and they are hard-coded.

**Work**, each part independently testable: connection reuse for sequential
requests to one host, gzip decoding, proxy support, and an extra-headers
setting for gateways.

**Done when.** An instrumented test counts one handshake for two requests and a
gzip fixture decodes to the expected body.

### 3.4 A turn cannot be cancelled

**Evidence.** There is no signal handler in `src/`; the REPL blocks in
`ReadLn`; an in-flight request is bounded only by `[llm] timeout` (1800 s by
default) and a command by `[workspace] shell_timeout`. Stopping the process
loses the turn and its save.

**Work.** A cancellation token checked by the stream callback, the HTTP read
loop and the tool runner. SIGINT or Ctrl+C sets it; the turn ends with a normal
event and the session is saved.

**Done when.** A fixture delays a response, the test cancels mid-request, and
the saved session and the exit path are asserted.

## 4. MCP

### 4.1 stdio is the only transport

**Evidence.** `TMCPTransport` has a single implementation, `TStdioTransport`.
`mcp.json` parsing reports a `url` entry as unsupported, and README says the
same.

**Work.** An HTTP/SSE transport behind the same abstract class.

**Done when.** A local HTTP fixture serves a JSON-RPC session and `test_mcp`
runs one tool call over each transport.

### 4.2 Tools are the only capability

**Evidence.** `TMCPClient` implements `initialize`, `tools/list` and
`tools/call`. There is no resources or prompts surface and no handler for
server notifications.

**Work.** Expose resources (list/read) and prompts (list/get), as tools or as
CLI commands. Fix the naming scheme and document it before implementing.

**Done when.** A fixture exposes one resource and one prompt, and both are
reachable from a session.

### 4.3 The tool list is fetched once

**Evidence.** Tools are registered in `TMCPManager.AddServer` and
`LoadFromFile`; no `notifications/tools/list_changed` is handled, so a server
that changes its tools needs a restart.

**Work.** Refresh one server's slice of the registry on notification, keeping
name de-duplication and leaving built-in tools under the `[tools]` policy.

**Done when.** A fixture removes a tool, the next request no longer offers it,
and a stale call is refused.

## 5. REPL and tool execution

### 5.1 No line editing or command history

**Evidence.** The REPL reads with `ReadLn(Input, Line)`. `/history` prints only
`Length(FAgent.Messages)`, and no command history is stored under `.mirmid`.

**Work.** A small line editor with persisted history, or at minimum commands
whose names match their output (`/history` for the count, a separate command for
the transcript) and a help text that says so.

**Done when.** History survives a restart and `/help` matches the implemented
commands.

### 5.2 Tool calls are strictly sequential

**Evidence.** `TAgent.RunTurn` loops over `Resp.ToolCalls` and calls
`FRegistry.Invoke` one at a time; there is no worker pool.

**Effect.** Several independent reads cost the sum of their latencies, and a
slow command delays every following call.

**Work.** Bounded parallel execution for handlers declared free of side effects,
with results returned in the original call order.

**Done when.** Two slow read-only tools finish in about the time of one and the
transcript keeps request order.

## 6. Platform parity and verification

### 6.1 Unix window and screen tools depend on external programs

**Evidence.** `mirmid.gui` shells out to `xwininfo` and `xprop`. `mirmid.screen`
tries `grim`, `scrot`, ImageMagick `import`, `gnome-screenshot` and `spectacle`,
and the `import` path for a window also calls `xdotool`. `CaptureToBuffer`
returns False on Unix because GDI capture is Windows-only.

**Effect.** No Wayland-native observation and no capture when none of the
utilities is installed; a window snapshot can fail even with ImageMagick
present.

**Work.** Either native X11/Wayland capture, or an explicit capability check
with an actionable error and a documented dependency list.

**Done when.** A headless test asserts the exact capability error and README
lists the dependency actually used.

### 6.2 Platform paths are skipped, not asserted

**Evidence.** `test_gui` skips without `DISPLAY` or `xwininfo`; `test_media`
skips a real capture without a desktop; the suite never touches the network by
design.

**Effect.** The Unix branches of the GUI and screen code have no automated
proof; a regression appears only on a desktop.

**Work.** Keep the skip but assert the failure text on every skipped branch.
`list_windows` and `find_window` already check it; `window_info` exits without
asserting, and the real-capture tests for `screen_shoot` and `window_shoot` skip
without checking the tool's capability message. Add those assertions.

**Done when.** Every skip is paired with an assertion on the returned `ERROR: `
text.

## 7. Hygiene

### 7.1 A duplicated `[tools]` section is not diagnosed

**Evidence.** `LoadIni` rejects duplicate keys inside `[tools]` and a mistyped
section name, but not a second `[tools]` section. `TIniFile.ReadSection('tools',
...)` returns the keys of one section only, so keys of the duplicate section are
silently ignored and the "unknown key aborts startup" rule does not apply to
them.

**Work.** Scan the section headers in the same pass that checks the `[tools]`
spelling and reject a repeated section name, or merge the copies before
validation.

**Done when.** A test writes two `[tools]` sections, the second with an unknown
key, and startup fails with a message naming the repeated section.

## Order and rough size

| Order | Item | Why now | Size |
| --- | --- | --- | --- |
| 1 | 1.1 auto-summarisation guard | data loss in long sessions | S |
| 2 | 3.2 streaming redirects | the default mode fails where `--no-stream` works | S |
| 3 | 3.1 429/5xx retry | a rate limit kills a turn | S |
| 4 | 7.1 duplicate `[tools]` section | a typo can silently leave tools unexamined | S |
| 5 | 1.3 tool-result budget | protects the window and the session files | M |
| 6 | 1.2 summary tail and estimate | quality of long sessions | M |
| 7 | 2.1 Anthropic wiring | unlocks the second provider | L |
| 8 | 2.2 per-role models | cost and latency control | M |
| 9 | 3.3 connection reuse and proxy | latency and deployment behind a gateway | M |
| 10 | 3.4 cancellation | user control over a running turn | M |
| 11 | 4.1 MCP HTTP transport | servers that do not ship a stdio command | M |
| 12 | 4.3 tool-list refresh | correctness for dynamic servers | S |
| 13 | 4.2 MCP resources and prompts | completeness against the protocol | L |
| 14 | 5.1 REPL history | daily usability | M |
| 15 | 5.2 parallel tool calls | latency of independent calls | M |
| 16 | 2.3 prompt caching | cost on long system prompts | S |
| 17 | 2.4 message parts | multimodal models | L |
| 18 | 6.1 and 6.2 Unix parity | removes hidden dependencies and skipped paths | L |

Sizes are rough: S is a contained change with one or two tests, M touches a unit
and its settings or fixtures, L changes a contract between units.

## What is deliberately absent

- Features excluded by the project rules: no database client, no keyboard or
  mouse input injection, no per-capability permission switches and no custom
  trust-anchor file setting. These are decisions, not gaps.
- Speculative work with no code anchor (a plugin API, a web interface, model
  routing heuristics). Listing it would make this file a wish list.
- Work already scheduled in the documentation phase itself (the reference
  configuration examples and this note). It is scheduled in the local
  `plan.md`, which is not part of the repository; the dated results live in
  `context.md`.

## Keeping this list honest

- Add an item only together with an **Evidence** line and a testable closing
  condition.
- When an item is fixed, record the commit and the new test count in
  `context.md`, then delete the item here.
- If an item turns out to be a design decision, move the reasoning to
  `context.md` and remove it from this file.
- The code is the source of truth: when a unit and this note disagree, fix the
  note in the same change that touches the behaviour.
