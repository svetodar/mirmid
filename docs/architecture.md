# Architecture

mirmid is a single-process console harness: one executable reads settings,
talks to an OpenAI-compatible endpoint, executes tools and keeps a dialogue in
memory. There is no server component and no background worker; every turn runs
synchronously inside the process. The source is a set of Free Pascal units under
`src/` plus the program file `src/mirmid.lpr`.

This note describes the layers, the turn cycle, the tool registry, session
persistence, the MCP client and the planner. Plan-mode details are in
[planning.md](planning.md); the standalone Anthropic client is described in
[anthropic.md](anthropic.md).

## Layers

| Layer | Units | Responsibility |
| --- | --- | --- |
| Entry point | `src/mirmid.lpr` | Set the UTF-8 system code page, initialise ANSI console handling, call `mirmid.cli.Main` and return its exit code. |
| Presentation and configuration | `mirmid.cli`, `mirmid.config`, `mirmid.markdown`, `mirmid.version` | Parse the command line, resolve defaults -> INI -> environment -> CLI, run the REPL, render streamed markdown and the status line, own the session save cycle and start the planner and MCP servers. |
| Conversation | `mirmid.agent`, `mirmid.types` | Message history, system prompt, the model -> tools -> model turn loop, tool dispatch, context estimate and UI events. `mirmid.types` holds messages, tool calls, events and `TMirmidConfig`. |
| Model clients | `mirmid.llm`, `mirmid.anthropic` | OpenAI-compatible Chat Completions client (regular and SSE streaming, tools, usage, model list) and a standalone Anthropic Messages API client. |
| Transport | `mirmid.http`, `mirmid.tlsclient` | HTTP/1.1 over plain TCP or TLS 1.2, chunked decoding, streaming callbacks and transport retries. |
| Tools | `mirmid.tools`, `mirmid.toolbuiltin`, `mirmid.subagent`, `mirmid.httprequest`, `mirmid.media`, `mirmid.screen`, `mirmid.gui` | Registry, JSON schemas, the `[tools]` policy and the built-in handlers. |
| Planning | `mirmid.plan`, `mirmid.planner` | Plan model and rendering, the four planning phases, step retries and the `revise_plan` tool. |
| External tools | `mirmid.mcp` | MCP stdio transport, JSON-RPC 2.0 client, server manager and tool proxy. |
| Persistence | `mirmid.session` | Session JSON files and the context journal. |
| Support | `mirmid.json`, `mirmid.util`, `mirmid.summarize`, `mirmid.loopguard` | JSON helpers and repair, platform/UTF-8/process helpers, dialog summarisation, repeated-call detection. |

The main dependency direction is:

```text
src/mirmid.lpr
  -> mirmid.cli
       -> mirmid.agent -> mirmid.llm -> mirmid.http -> mirmid.tlsclient -> tls
       |      -> mirmid.tools -> mirmid.types
       |      -> mirmid.loopguard
       -> mirmid.planner -> mirmid.plan / mirmid.llm
       -> mirmid.mcp -> mirmid.tools
       -> mirmid.session / mirmid.summarize
       -> mirmid.config / mirmid.json / mirmid.util / mirmid.markdown
```

`mirmid.anthropic` sits beside `mirmid.llm` and uses `mirmid.http` directly.
Lower layers do not import `mirmid.cli` or `mirmid.agent`; `mirmid.types` has no
dependency on fpjson or networking, so every other unit can use it. Tools are
reached only through `mirmid.tools`: `mirmid.toolbuiltin` registers the
handlers, and the agent invokes them by name.

## Turn cycle

A user turn starts in `mirmid.cli` with `TAgent.AddUser`. In normal mode the CLI
calls `TAgent.RunTurn`; in plan mode it calls `TPlanner.RunPlannedTurn` instead
(see [planning.md](planning.md)). `RunTurn` is the core loop:

1. The history starts with the system message built by `TAgent.Reset`. It
   contains `[agent] system_prompt`, environment information (OS, date, time)
   and, for the root session only, the contents of `AGENTS.md`. Subagents use
   `SUBAGENT_SYSTEM_PROMPT` and never inherit the root instructions.
2. The loop guard is reset. A `TLLMClient` is created for the turn and the
   iteration counter starts at zero.
3. Each iteration requests the model, up to `[agent] max_steps` iterations
   (`0` means unlimited). An `aeContext` estimate is emitted at the start, after
   each answer and after each batch of tool results for the status line.
4. With `stream=1` the request goes through `TLLMClient.ChatStream` and the
   deltas are rendered as they arrive (`aeStreamStart`, text/reasoning deltas,
   `aeStreamEnd`). Otherwise `TLLMClient.Chat` performs a single request. Both
   POST to `<base_url>/chat/completions`; the stream asks for
   `stream_options.include_usage` so the exact prompt size is known.
5. The assistant message is appended to the history with its content, reasoning
   and tool calls. If there are no tool calls, the content is the final text and
   the turn succeeds.
6. Each tool call is executed in order through `TToolRegistry.Invoke`. The
   result becomes a `mrTool` message with the call id and the tool name. A tool
   failure is data for the model, not an exception: handlers return text starting
   with `ERROR: ` and the registry catches unexpected exceptions.
7. The loop guard (`TLoopGuard`) inspects every call. Repeating the same call
   with the same result is a strong signal; the same call with a changing result
   is treated as polling with higher fixed thresholds. A warning adds a
   synthetic user message (`aeLoopWarning`), a stop ends the turn with an error.
8. When the step limit is reached the turn fails with
   `step limit reached (<n>): the model did not finish the answer`. A model or
   transport error also fails the turn; the CLI still saves the session.

Tool calls and results are emitted as events (`aeToolCall`, `aeShellCommand`,
`aeToolResult`). The CLI decides what to print: by default the final answer,
errors, loop warnings and status lines are visible, while reasoning and tool
output require `--show-reasoning`. Streamed text is rendered as markdown and the
context status line is redrawn below it.

The context estimate in `TAgent.ContextTokens` walks the message history and
the registered tool schemas. Text is weighted as four ASCII bytes per token,
two characters per token for two-byte UTF-8 scripts and one character per token
for three- or four-byte scripts; every message, tool result, tool call and tool
schema adds a fixed wrapper. Provider usage (`prompt_tokens`) corrects the
estimate, and the correction is carried into the status line.

Subagents reuse the same agent loop with a separate `TAgent`, their own system
prompt and a clean history. They receive the parent's limits and, when the
context already has one, the parent's registry (so MCP servers are not started
again). Nesting is limited to `MAX_SUBAGENT_DEPTH` (3); the final answer is the
tool result, and an empty answer is reported as an error.

## Tools

`TToolRegistry` stores tool names, descriptions, JSON schemas and handlers. A
handler is a plain function or a method (the latter keeps state, for example the
MCP client). `BuildRequestTools` copies the schemas into the `tools` array of the
request; nothing outside the registry can add a tool to the request.

The single source of truth for the built-in tool set is `TOOL_SWITCHES` in
`mirmid.tools`: 17 entries with the key name, the default value and one comment
line. The table drives the `[tools]` section of the INI file, the unknown-key
error and the sample `mirmid --init` output. Read-only inspection tools default
to `1`; tools that write files, run commands, open connections, start a session
or capture the screen default to `0`.

The policy is applied in both directions:

- `ApplyToolSwitches` marks the registry's policy source. `Add` and `AddMethod`
  silently skip a built-in tool whose key is `0`, so the schema never reaches
  the model. MCP names (`mcp__<server>__<tool>`) are not in the table and are
  governed by `[mcp]` instead.
- Every sensitive handler repeats the check with `ToolEnabled(Ctx.Cfg, name)`
  and returns `ERROR: tool "<name>" is disabled`. This matters because subagents,
  plan steps and MCP calls share the same registry and may be built without the
  CLI.

`TToolRegistry.Invoke` parses the raw arguments with the JSON repair helper,
rejects non-object arguments, refuses unknown names and converts an exception
into an `ERROR: ` result. The argument parsing deliberately accepts the small
syntax repairs that models produce; the schema remains the contract.

Registration order is:

- `RegisterSessionTools` applies the `[tools]` policy, then registers the
  built-in file and shell tools (`RegisterBuiltinTools`), media information,
  screenshots, GUI window observation (`RegisterGuiTools`), `subagent` and
  `http_request`.
- `mirmid.cli` creates the planner in plan mode and registers `revise_plan`
  through `RegisterRevisePlanTool`.
- `TMCPManager.LoadFromFile` adds the tools of each connected MCP server as
  method handlers.

The built-in tool table in [README.md](../README.md) lists every name, default
and purpose; `TOOL_SWITCHES` is the authority when the two disagree.

## Sessions and the context journal

The root dialogue lives in memory as `TMessages`. After a turn the CLI calls
`SaveCurrentSession` from a `finally` block, so the file is written even when the
model call failed or the turn raised an exception. `SaveSessionWithJournal`
writes the JSON file and then appends one journal record; a journal failure is
reported separately and does not lose the session file. `--no-session` skips
both writes (`prSkipped`).

Sessions are stored in `<workdir>/.mirmid/sessions`:

- `<id>.json` is the main session. `-s/--session ID` continues an existing
  session or creates one with that id; `--list-sessions` lists the main files.
- Schema 2 contains `schema`, `id`, `model`, `updated`, `messages` and `plan`
  (an object or `null`). Schema 1 files without `plan` still load.
- Auxiliary sessions have their own suffixes and are hidden from
  `--list-sessions`: `<id>_analysis.json` (preliminary analysis),
  `<id>_step_<step>.json` and `<id>_step_<step>_try<N>.json` (plan steps and
  retries), and `<id>_sub_<n>.json` (subagents).

The context journal lives in `<workdir>/.mirmid/journal/<id>.jsonl`. One line is
written per save with the time, `operation=Flash`, the full `context` estimate
and the `part` contributed by messages added since the previous record. The CLI
tracks the last journalled message index, so a resumed session starts a new
record without recounting the loaded history.

File tools refuse to enter `.mirmid`. Planner model-call logs are separate from
sessions: `mirmid.planner` writes request/response records to
`<workdir>/.mirmid/logs/<session-base>.jsonl` (`plan.jsonl` when the session
base is empty) with a phase label (`analysis`, `plan`, `step sN`, `report`,
revision attempts). A log write failure is reported as an event but never fails
a turn.

Summarisation is a CLI action, not an agent one. After a successful turn
`CheckAutoSummarize` compares `TAgent.ContextTokens` with the configured
threshold (percentage of the effective context or an absolute token count) and
calls `SummarizeSession` when the limit is crossed. The summary request uses the
model and writes a new session: system prompt plus the summary as a user message.
The plan, when present, is carried over and the auxiliary session base follows
the new id. The result reports the token reduction; a reduction below the
configured minimum is a warning. The same flow is available manually as
`/summarize`, and it is unavailable under `--no-session`.

## MCP

`mirmid.mcp` implements the stdio transport only: the server is a child process
and the client exchanges one JSON object per line over its stdin/stdout.
stderr is drained so a chatty server cannot block. The client offers protocol
version `2024-11-05`, performs the `initialize` /
`notifications/initialized` handshake, fetches `tools/list` and calls
`tools/call`.

Servers are described in `mcp.json`, in the Claude Desktop-compatible shape:

```json
{
  "mcpServers": {
    "server-name": {
      "command": "executable",
      "args": ["..."],
      "env": {"NAME": "value"},
      "cwd": "/work",
      "enabled": true,
      "timeout": 60
    }
  }
}
```

`command` is required; `args`, `env`, `cwd`, `enabled` and `timeout` are
optional. A description with a `url` and no `command` is reported as an
unsupported HTTP transport. The default path is `$MIRMID_MCP_CONFIG`, then
`<workdir>/.mirmid/mcp.json`; `--mcp-config` overrides it. `--no-mcp` disables
the connection, `--mcp-timeout` changes the default answer timeout and
`--list-mcp` prints the tools of each server.

Every exposed tool is registered as `mcp__<server>__<tool>`. Invalid characters
in both components are replaced with `_`, the full name is limited to 64
characters and duplicates receive a numeric suffix. Calls go through the same
registry and the same turn loop as built-in tools; the handler forwards the
arguments to the server and returns its text or its error. A connection or
handshake failure of one server becomes a warning and does not prevent other
servers from loading. The manager owns the clients and is created and freed by
the CLI with the rest of the session.

## Planner

Plan mode is enabled by `--plan` or `[agent] plan=1`. The CLI creates a
`TPlanner` and registers `revise_plan`; both the planner and the plan are part of
the session state. `TPlanner.RunPlannedTurn` runs four phases:

1. **Preliminary analysis.** A separate agent with the analyst system prompt
   studies the task and the environment. The prompt requires read-only work, but
   the tool switches are inherited unchanged, so the user's enabled tools remain
   available. The analysis session is saved as `<id>_analysis.json`; a failure is
   reported and the plan is built without the analysis.
2. **Plan.** A direct model request (with the task and the analysis) must return
   only JSON steps. A parse failure gets one retry; the parsed plan is truncated
   to `[agent] plan_max_step` when that limit is set. The planner fires
   `aePlan`, saves the session and, in interactive mode, ends the turn with the
   rendered plan so the steps run on the next user instruction.
3. **Steps.** While the plan has a pending step, the planner starts a fresh
   `TAgent` for it. The step system prompt contains the task, the current plan
   and the step description; the step budget is `plan_step_max_steps` and the
   agent runs one level deeper than the parent. Each step session is saved as
   `<id>_step_<step>.json`. A regular answer marks the step done and stores a
   truncated result; a failed turn, an empty answer or a final text starting
   with `ERROR: ` marks it failed and the failure reason goes into the next
   attempt. The number of attempts is `1 + plan_step_fix_attempts`. When all
   attempts fail, the model is asked whether to revise the plan or stop; a
   revision uses the same `revise_plan` handler and a stop ends the turn with
   `aeError`.
4. **Report.** `BuildPlanReport` creates a deterministic summary, then a direct
   model request rewrites it into the final answer. A failed report request
   leaves the deterministic summary in place and does not fail the turn. The CLI
   appends the report as an assistant message to the main session.

An incomplete plan (pending or in-progress steps) is resumed on the next turn
without repeating analysis or planning. `revise_plan` applies `add`, `remove`,
`reorder` and `skip` operations in order; when an operation is invalid, the
operations before it stay applied and the error names the failing operation.
Any plan change triggers `OnPlanChanged`, which saves the session.
The exact prompts, statuses and operation schemas are documented in
[planning.md](planning.md).

## Model transport and clients

`mirmid.http` is a small HTTP/1.1 client with its own framing. It supports GET
and POST with a JSON body and reports 4xx/5xx responses as status and body
instead of raising. Chunked bodies are decoded by `TBodyDecoder`, and streaming
requests deliver body chunks to a callback. Transport failures (DNS, connect,
reset before a response) are retried up to three times with 1/2/4 second pauses;
HTTP statuses are returned immediately, and a stream is retried only before the
first body chunk.

`mirmid.tlsclient` provides one transport abstraction for a single HTTP
connection: plain TCP for `http` and TLS 1.2 for `https`. Trust comes from the
embedded root snapshot (`tls.roots`) first and from the operating system store
second (Windows); when neither is available the connection fails with an
explicit error. There is no external certificate bundle setting.

`mirmid.llm` builds the Chat Completions request: model, messages, tool schemas,
temperature, `max_tokens`, optional `reasoning_effort` and stream options. It
parses regular responses and SSE streams (content, `reasoning_content`,
`tool_calls`, `finish_reason`, usage) and can list models. The model list is also
used by the CLI to learn the host context window; the effective context is the
minimum of the setting and the host value.

`mirmid.anthropic` is a complete Messages API client (request validation, text
and tool-use blocks, thinking blocks, SSE accumulation, error mapping), but the
agent loop does not use it yet: normal turns go through `mirmid.llm`. Its
interface and scope are covered in [anthropic.md](anthropic.md).

## Working with the code

- **A new built-in tool:** add an entry to `TOOL_SWITCHES` with its default and
  note, register the handler from `RegisterBuiltinTools` (or
  `RegisterSessionTools` for session-level tools), guard the handler with
  `ToolEnabled`, and update the table in [README.md](../README.md) and
  `config/mirmid.ini.example`. Tests must cover the key set, the default and the
  disabled-tool refusal.
- **A change to the loop:** edit `mirmid.agent` and its tests; keep the event
  contract (`aeStep`, `aeToolCall`, `aeToolResult`, `aeContext`, `aeError`)
  stable, because the CLI status line and the planner rely on it.
- **A change to persistence:** edit `mirmid.session`, keep schema 1 readable and
  keep auxiliary suffixes (`_sub_`, `_step_`, `_analysis`) outside
  `--list-sessions`.
- **An MCP change:** edit `mirmid.mcp`, keep `mcp.json` compatible with the
  documented shape and keep server failures non-fatal.
- **A planning change:** edit `mirmid.plan` and `mirmid.planner`, then update
  [planning.md](planning.md).

The invariants that apply to every layer are the project rules: English only,
LF line endings in tracked files, tool failures as `ERROR: ` text, tests without
network access, and no local state in the repository. When this note and a unit
disagree, the unit is right; fix the note in the same change.
