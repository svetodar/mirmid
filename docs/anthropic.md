# Anthropic Messages API client

`src/mirmid.anthropic.pas` is a client for the Anthropic Messages API
(`POST /v1/messages`): request building, parameter validation, regular and
streaming (SSE) responses, tool schemas, extended-thinking blocks and error
mapping. It is a **standalone library unit**: no other unit in `src/` references
it and the agent loop does not use it. This note records what the unit does
today and, in code terms, what keeps it from replacing the OpenAI-compatible
client in `src/mirmid.llm.pas`.

## Status: standalone, not wired into the agent

- The live `uses` chain is `mirmid.lpr` -> `mirmid.cli` -> `mirmid.agent` ->
  `mirmid.llm` -> `mirmid.http` -> `mirmid.tlsclient`. The actual reference to
  `mirmid.anthropic` exists only in `tests/test_anthropic.pas`. Nothing in
  `src/` lists it in a `uses` clause, so `bin/mirmid.exe` does not contain the
  unit; `bin/testrunner.exe` does, because `tests/testrunner.lpr` lists
  `test_anthropic`.
- There is no settings surface: `mirmid.config` reads `base_url`, `api_key`
  and `model` from `[llm]` and nothing else for the LLM side, and there is no
  `provider` key. No CLI flag and no environment variable select Anthropic.
- `TAnthropicClient` keeps its API key and base URL (default
  `https://api.anthropic.com`) in private fields; the only public property is
  `Accumulator`.
- The `Makefile` prerequisites use `$(wildcard $(SRC)/*.pas)`, but FPC compiles
  only the units reachable from `uses`, so adding or editing this unit does not
  change the application binary.

## Request model

`TAnthropicRequest` mirrors the documented `/v1/messages` body:

| Field | Required | Notes |
| --- | --- | --- |
| `Model` | yes | e.g. `claude-sonnet-4-20250514` |
| `Messages` | yes | `TMessages` from `mirmid.types` (role + content string) |
| `MaxTokens` | yes | becomes `max_tokens`, must be positive |
| `System` | no | top-level `system` string, sent when not empty |
| `Stream` | no | adds `"stream": true` to the body |
| `Temperature` | no | sent only when > 0; checked against 0..1 |
| `TopP` | no | sent only when > 0; checked against 0..1 |
| `TopK` | no | sent only when > 0; must be >= 0 |
| `StopSequences` | no | `stop_sequences` array, sent when non-empty |
| `Tools` | no | raw `TJSONArray`; sent as is when non-nil and non-empty |
| `ToolChoice` | no | raw `TJSONObject`; sent as is when non-nil |
| `Metadata` | no | raw `TJSONObject`; sent as is when non-nil |

`MakeAnthropicRequest(Model, Messages, MaxTokens)` fills the required fields and
sets `Stream := False`, all sampling parameters to `0`,
`StopSequences := nil`, `Tools`/`ToolChoice`/`Metadata := nil` - the "not sent"
state of `BuildRequestJson`.

`BuildRequestJson` produces the body in this order: `model`, `max_tokens`,
`messages` (one `{"role": ..., "content": ...}` object per message, `content`
is the plain `TMessage.Content` string), then the optional fields `system`,
`stream`, the sampling parameters, `stop_sequences`, `tools`, `tool_choice`
and `metadata`.

`RoleName` from `mirmid.types` supplies the OpenAI-style role names
(`user`/`assistant`/`system`/`tool`) - the message record is the OpenAI shape,
see "Why it is not wired" below.

## Validation middleware

`TAnthropicValidator.Validate` runs before any network I/O and collects every
problem instead of stopping at the first one. `TAnthropicClient.ValidateRequest`
turns the list into a synthetic `invalid_request_error` with HTTP status 400 and
`retryable = false`; both `SendMessages` and `SendMessagesStream` call it first,
so an invalid request is rejected without a socket being opened.

Checked rules:

- `model` - must not be blank.
- `max_tokens` - must be positive.
- `messages` - must not be empty; the first message must come from the user;
  `user`/`assistant` roles must alternate; `content` must not be blank; the
  `system` role is rejected (`use the system field`) and the `tool` role is
  rejected as unsupported.
- `temperature` and `top_p` - above 1 are rejected (0 means "not sent").
- `top_k` - negative is rejected.

Messages read as field-level sentences, e.g.
`messages[1]: roles must alternate (user/assistant)`; `JoinErrors` joins them
with `"; "` into the final message.

## Transport

Both entry points post to `JoinUrl(BaseUrl, '/v1/messages')` through
`mirmid.http` - the same transport (`mirmid.tlsclient`, embedded root store,
OS store fallback) the LLM client uses.

- `SendMessages` calls `HttpRequestEx` with these headers:
  `Content-Type: application/json; charset=utf-8`,
  `Accept: application/json`, `x-api-key: <key>` (Anthropic does not use
  `Authorization: Bearer`) and `anthropic-version: 2023-06-01`
  (`ANTHROPIC_API_VERSION`).
- `SendMessagesStream` calls `HttpRequestStreamEx` with the same headers minus
  `Accept` and passes `@SSEChunk` as the chunk callback.
- Timeouts are private fields with fixed defaults: overall request 1 800 000 ms,
  connect 10 000 ms. No INI key feeds them and the caller cannot change them
  today; `[llm] timeout` and `connect_timeout` configure the OpenAI-compatible
  client only.

Both functions return `False` with `Err` (a human-readable text) and `ErrJson`
(a `type: "error"` object, see below) on failure; `True` with a parsed
`TAnthropicResponse` on success.

## Response model

`TAnthropicResponse` holds `Id`, `MsgType`, `Role`, `Model`, `Content` (array of
`TAnthropicContentBlock`), `StopReason`, `StopSequence`, `Usage` and
`ServiceTier`. `ParseResponse` fills every field defensively: missing keys give
empty strings and zeros, and unknown block types become `abtUnknown` instead of
failing the whole response.

| Block type | Fields filled |
| --- | --- |
| `text` -> `abtText` | `Text` |
| `tool_use` -> `abtToolUse` | `ToolId`, `ToolName`, `ToolInput` (the `input` object re-serialised as a JSON string) |
| `thinking` -> `abtThinking` | `Thinking`, `Signature` |
| anything else -> `abtUnknown` | none |

`TAnthropicUsage` reads `input_tokens`, `output_tokens`,
`cache_creation_input_tokens` and `cache_read_input_tokens`.
`StopReason` is kept as the raw string (`end_turn`, `max_tokens`,
`stop_sequence`, `tool_use`, ...). `AnthropicResponseText` concatenates the
`abtText` blocks with a line feed and ignores `tool_use` and `thinking` blocks.

## Streaming

`TAnthropicSSEAccumulator` owns the stream state and is reachable from the
client as `Accumulator`, so another transport or a test can drive it:

- `FeedChunk` appends raw bytes to a line buffer, splits on `#10`, and stops
  accepting data once `Done` is set; `FeedLine` strips a leading `data:`,
  trims, skips empty lines and silently drops invalid JSON; `Flush` processes a
  trailing line without a newline; `Reset` clears the state before a new stream;
  `Collect` copies the accumulated blocks, `stop_reason`, `usage` and id into a
  `TAnthropicResponse`.

Handled events:

| Event | Effect |
| --- | --- |
| `message_start` | id, model, input/cache token counters |
| `content_block_start` | appends a block (`text`, `tool_use` with id and name, `thinking`) |
| `content_block_delta` | `text_delta` appends text and fires `OnDelta`; `input_json_delta` appends `partial_json` to `ToolInput`; `thinking_delta` appends `Thinking` |
| `content_block_stop` | no-op |
| `message_delta` | `stop_reason`, `stop_sequence`, `output_tokens` |
| `message_stop` | sets `Done` |

`OnDelta` has the signature `(TextDelta, ToolInputDelta: string)` but only text
deltas are passed: tool arguments are accumulated in the block and never
forwarded as deltas. `ping` and `error` events have no branch and are dropped.

`SendMessagesStream` validates the request, resets the accumulator, streams,
flushes the tail line and then requires `Done`; without `message_stop` it fails
with `the server closed the connection before the response completed (no
message_stop)`. A server that reports a mid-stream failure through an `error`
event therefore looks like a truncated stream.

## Errors

`ParseError` reads `error.type` and `error.message` from the body and falls back
to the HTTP status when the body is not the expected JSON:

| Status | Type | Retryable |
| --- | --- | --- |
| 400 | `invalid_request_error` | no |
| 401 | `authentication_error` | no |
| 403 | `permission_error` | no |
| 404 | `not_found_error` | no |
| 429 | `rate_limit_error` | yes |
| >= 500 | `api_error` | yes |
| 0 (no response) | `connection_error` | yes |

`BuildErrorJson` produces `{"type":"error","error":{"type","message","status",
"retryable"}}` - the same envelope shape the API itself uses - and
`AnthropicErrorText` renders `Anthropic API: <message> (HTTP <status>)`, plus
`[<type>]` and `(retryable)` when they apply. The client never retries on its
own; retrying is left to the caller, and no caller exists yet.

## Tests

`tests/test_anthropic.pas` registers nine classes: `TAnthropicValidatorTests`,
`TAnthropicClientValidateTests`, `TBuildRequestJsonTests`,
`TParseResponseTests`, `TParseErrorTests`, `TErrorJsonTests`,
`TResponseTextTests`, `TSSEAccumulatorTests` and `TClientSSEChunkTests`. They
cover the validation rules, the produced JSON body, response and error parsing,
the error envelope and text, and SSE events fed chunk by chunk. The suite never
touches the network: the client is built as
`TAnthropicClient.Create('test-key', '')` and only `ValidateRequest`/`SSEChunk`
are called. Run it with `make test` (see [repository.md](repository.md)).

## Why it is not wired into the agent

Each item points at code that would have to change; this is the input for the
work described in [roadmap.md](roadmap.md).

1. **Message model mismatch.** `mirmid.types.TMessage` is the OpenAI
   Chat Completions record (`ToolCalls`, `ToolCallId`, `Reasoning`), and
   `BuildRequestJson` writes only `role` and a `content` string. Anthropic needs
   assistant `tool_use` blocks and user `tool_result` blocks; the validator
   rejects both `mrTool` and `mrSystem` because of the same limitation.
2. **Tool schema shape.** `TToolRegistry.BuildRequestTools` emits OpenAI
   entries `{type: "function", function: {name, description, parameters}}`,
   while Anthropic wants `{name, description, input_schema}`. `Req.Tools` is a
   raw `TJSONArray`, so there is neither a conversion nor a test for it.
3. **No configuration surface.** No `provider` key, no Anthropic base URL, key
   or model in `[llm]`; `mirmid.cli` constructs `TLLMClient` from the
   OpenAI-compatible settings only.
4. **No thinking controls on the request side.** Response parsing keeps
   `thinking` blocks and their `signature`, but `TAnthropicRequest` has no
   thinking budget or type field, so extended thinking cannot be requested.
5. **Incomplete SSE error handling.** `ping` and `error` events are ignored (see
   Streaming), which hides server-side failures in the middle of a stream.
6. **Hard-coded timeouts.** The 1 800 000/10 000 ms defaults are private fields;
   the `[llm] timeout` and `[llm] connect_timeout` settings (seconds) reach only
   the LLM client.

## Using the unit today

```pascal
var
  Client: TAnthropicClient;
  Req: TAnthropicRequest;
  Resp: TAnthropicResponse;
  Err: string;
  ErrJson: TJSONData;
  Msgs: TMessages;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'Hello');   { one user message }
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  Req.System := 'You are a careful assistant.';
  Client := TAnthropicClient.Create(GetEnvironmentVariable('ANTHROPIC_API_KEY'), '');
  try
    if Client.SendMessages(Req, Resp, Err, ErrJson) then
      WriteLn(AnthropicResponseText(Resp))
    else
    begin
      WriteLn(Err);
      ErrJson.Free;   { the caller frees the error object }
    end;
  finally
    Client.Free;
  end;
end;
```

This snippet is illustrative: no binary in the repository performs such a call,
and doing it for real needs a network connection and a key, which the test
suite must never require.

## Rules when changing the unit

- Keep it a leaf client: `uses` in the interface is `SysUtils, Classes, fpjson,
  mirmid.types, mirmid.tools`; the implementation adds `mirmid.http`,
  `mirmid.json` and `mirmid.util`. It must not depend on `mirmid.agent`,
  `mirmid.cli`, `mirmid.config` or `mirmid.session`.
- No network in tests: feed `FeedChunk`/`SSEChunk` from string literals, as the
  existing classes do.
- Every new response field or event needs a test in `tests/test_anthropic.pas`
  and, when visible to users, an update of this note and of the feature bullet
  in `README.md`.
- If the unit ever becomes reachable from the agent loop, the status section
  above, `README.md` and `architecture.md` must be updated in the same change.
