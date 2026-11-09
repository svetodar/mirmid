unit mirmid.agent;
{ Agent loop: a request to the model, tool execution, repeat until the final
  text answer or the step limit is exhausted. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mirmid.types, mirmid.tools, mirmid.loopguard, mirmid.llm;

type
  TAgent = class
  private
    FCfg: TMirmidConfig;
    FRegistry: TToolRegistry;
    FMsgs: TMessages;
    FOnEvent: TAgentEvent;
    FOnSubAgentEvent: TAgentEvent; { events of subagents (and their nested ones) }
    FOnModelCall: TModelCallEvent; { notification about every model call
                                     (model process log) }
    FSubAgentDepth: Integer;   { 0 — root session, >0 — subagent }
    FSessionBase: string;
    FLoopGuard: TLoopGuard; { repeated tool call detector }
    { Context estimate correction: the last usage.prompt_tokens minus the
      ContextTokens estimate of the same request. The provider (in a stream —
      thanks to stream_options.include_usage) reports the exact request size,
      so the estimate is shifted by the actual difference; 0 — usage has not
      arrived yet. }
    FContextFix: Integer;
    function BuildContext: TToolContext;
    procedure Fire(Kind: TAgentEventKind; const Text: string);
    { Notifies the OnModelCall handler about the model call started at StartMs;
      without a handler it does nothing. }
    procedure NotifyModelCall(const Resp: TLLMResponse; StartMs: QWord;
      const ErrText: string);
    procedure Append(const M: TMessage);
    procedure LLMDelta(const ContentDelta, ReasoningDelta: string);
    { Reports the new context size (aeContext) to the CLI — the base of the
      status line. It is computed from the history after the model answer and
      the tool results were added, so the base does not lag behind the real
      context (including the case when the answer was the last one in the
      turn). Without a handler it computes nothing: ContextTokens walks all
      messages and serialises the schemas. }
    procedure EmitContext;
  public
    constructor Create(const ACfg: TMirmidConfig; ARegistry: TToolRegistry);
    { Clears the dialog and adds the system message. }
    procedure Reset;
    procedure AddUser(const Text: string);
    { One user turn: runs tools when needed. }
    function RunTurn(out FinalText: string; out Err: string): Boolean;
    property Messages: TMessages read FMsgs write FMsgs;
    { Current agent configuration. Writing allows changing the model, the
      system prompt and the reasoning mode right during the session (REPL). }
    property Config: TMirmidConfig read FCfg write FCfg;
    { Subagent nesting depth: 0 — root session, >0 — subagent.
      Set before the subagent is started by the subagent tool. }
    property SubAgentDepth: Integer read FSubAgentDepth write FSubAgentDepth;
    { Base name of the auxiliary session files (subagents, plan steps);
      empty — they are not saved. }
    property SessionBase: string read FSessionBase write FSessionBase;
    property OnEvent: TAgentEvent read FOnEvent write FOnEvent;
    property OnSubAgentEvent: TAgentEvent read FOnSubAgentEvent write FOnSubAgentEvent;
    { Notification about every model call (request → answer, duration,
      error). Used by the model process log and the tests; it does not affect
      the turn. }
    property OnModelCall: TModelCallEvent read FOnModelCall write FOnModelCall;
    { Estimate of the current context size (tokens) from the message history
      and the tool schemas: text weight (ASCII — 4 bytes per token, Cyrillic —
      2 characters per token, CJK/emoji — one character per token) plus the
      wrappers of messages, tool calls and schemas. }
    function ContextTokens: Integer;
  end;

const
  { Wrapper of one message in Chat Completions (<|im_start|>role, JSON keys,
    service newlines) on top of the text itself. }
  TokensPerMessage = 4;
  { Service part of a tool result (role tool, tool_call_id, name). }
  TokensPerToolResult = 4;
  { JSON wrapper of a tool call (id, type, function, keys, quotes) on top of
    the name and the arguments. }
  TokensPerToolCall = 12;
  { Wrapper of a tool schema in the request (type/function) on top of its JSON. }
  TokensPerToolSchema = 5;

{ Number of Unicode characters in a UTF-8 string. }
function CountUTF8Chars(const S: string): Integer;

{ Text weight in quarter tokens: ASCII — 1 (4 bytes per token), two-byte
  UTF-8 (Cyrillic, Greek) — 2 (2 characters per token), three- and four-byte
  (CJK, emoji) — 4 (one character per token). }
function TextQuarterTokens(const S: string): Int64;

{ Token estimate of one message together with the wrapper: role, content,
  reasoning, tool name/id, arguments and tool call ids plus TokensPerMessage
  (for a tool result — also TokensPerToolResult). }
function MessageTokens(const M: TMessage): Integer;

implementation

uses
  fpjson, mirmid.json, mirmid.util;
constructor TAgent.Create(const ACfg: TMirmidConfig; ARegistry: TToolRegistry);
begin
  inherited Create;
  FCfg := ACfg;
  FRegistry := ARegistry;
  SetLength(FMsgs, 0);
  FSubAgentDepth := 0;
  FOnModelCall := nil;
  FSessionBase := '';
  FLoopGuard := TLoopGuard.Create(FCfg.LoopWarn, FCfg.LoopStop);
  Reset;
end;

procedure TAgent.Reset;
var
  SP, AgentsMd: string;
begin
  SetLength(FMsgs, 0);
  FContextFix := 0; { a new session — the previous usage does not apply to it }
  if FCfg.SystemPrompt <> '' then
  begin
    SP := FCfg.SystemPrompt;
    { Add environment information: OS, date, time. }
    if EnvironmentInfo <> '' then
      SP := SP + #10#10 + EnvironmentInfo;
    { Project instructions from AGENTS.md — for the main (root) session only:
      subagents work with their own system prompt. }
    if FSubAgentDepth = 0 then
    begin
      AgentsMd := ReadAgentsMd(FCfg.WorkDir);
      if AgentsMd <> '' then
        SP := SP + #10#10 + 'Project instructions (AGENTS.md):' + #10 + AgentsMd;
    end;
    Append(MakeMessage(mrSystem, SP));
  end;
end;

procedure TAgent.Append(const M: TMessage);
var
  N: Integer;
begin
  N := Length(FMsgs);
  SetLength(FMsgs, N + 1);
  FMsgs[N] := M;
end;

procedure TAgent.AddUser(const Text: string);
begin
  Append(MakeMessage(mrUser, Text));
end;
procedure TAgent.EmitContext;
var
  N: Integer;
begin
  if not Assigned(FOnEvent) then
    Exit;
  { History estimate plus the correction from the real usage.prompt_tokens. }
  N := ContextTokens + FContextFix;
  if N < 0 then
    N := 0;
  Fire(aeContext, IntToStr(N));
end;

procedure TAgent.Fire(Kind: TAgentEventKind; const Text: string);
begin
  if Assigned(FOnEvent) then
    FOnEvent(Kind, Text);
end;

{ Model call notification: a snapshot of the request (FMsgs at the moment of
  the call) and the answer. The handler writes the model process log; StartMs
  is the start time of the call (TicksMs), the duration is computed here. }
procedure TAgent.NotifyModelCall(const Resp: TLLMResponse; StartMs: QWord;
  const ErrText: string);
begin
  if not Assigned(FOnModelCall) then
    Exit;
  FOnModelCall(FMsgs, Resp, Int64(TicksMs - StartMs), ErrText);
end;

{ Model stream delta → events for the UI. }
procedure TAgent.LLMDelta(const ContentDelta, ReasoningDelta: string);
begin
  if ReasoningDelta <> '' then
    Fire(aeStreamReasoning, ReasoningDelta);
  if ContentDelta <> '' then
    Fire(aeStreamText, ContentDelta);
end;

function CountUTF8Chars(const S: string): Integer;
var
  I, N: Integer;
begin
  Result := 0;
  N := Length(S);
  for I := 1 to N do
    if (Byte(S[I]) and $C0) <> $80 then   { character start, not a continuation }
      Inc(Result);
end;

{ Text weight in quarter tokens. The "4 bytes per token" estimate holds for
  ASCII, while Cyrillic occupies two bytes per character in UTF-8 and BPE
  tokenizers fit roughly 2 characters per token — therefore the weight is
  computed from the length of the leading byte, not from the character count.
  Weights: ASCII — 1, two-byte UTF-8 (Cyrillic, Greek, Latin with diacritics)
  — 2, three- and four-byte (CJK, emoji) — 4 (one character per token). }
function TextQuarterTokens(const S: string): Int64;
var
  I, N, W: Integer;
  B: Byte;
begin
  Result := 0;
  N := Length(S);  { Length of the string — UTF-8 bytes }
  I := 1;
  while I <= N do
  begin
    B := Byte(S[I]);
    if B < $80 then
      W := 1
    else if (B and $E0) = $C0 then
      W := 2
    else if (B and $F0) = $E0 then
      W := 3
    else
      W := 4;
    if W = 1 then
      Inc(Result)
    else if W = 2 then
      Inc(Result, 2)
    else
      Inc(Result, 4);  { CJK and emoji — about one character per token }
    { A truncated multibyte tail must not swallow the neighbouring characters. }
    if I + W > N + 1 then
      Break;
    Inc(I, W);
  end;
end;

{ Token estimate of one message: weight of the role, text, reasoning, tool
  name/id and tool calls plus the message wrapper. }
function MessageTokens(const M: TMessage): Integer;
var
  I: Integer;
  Q: Int64;
begin
  Q := TextQuarterTokens(RoleName(M.Role) + M.Content + M.Reasoning +
    M.Name + M.ToolCallId);
  for I := Low(M.ToolCalls) to High(M.ToolCalls) do
    Q := Q + TextQuarterTokens(M.ToolCalls[I].Id + M.ToolCalls[I].Name +
      M.ToolCalls[I].Arguments) + Int64(TokensPerToolCall) * 4;
  Result := Integer((Q + 3) div 4) + TokensPerMessage;
  if M.Role = mrTool then
    Inc(Result, TokensPerToolResult);
end;

{ Estimate of the current context size (tokens): the message history plus the
  tool schemas. The text is weighted by TextQuarterTokens, every message gets
  the Chat Completions wrapper, every tool call/schema gets the JSON wrapper. }
function TAgent.ContextTokens: Integer;
var
  I: Integer;
  Q: Int64;
  Arr: TJSONArray;
begin
  Q := 0;
  for I := Low(FMsgs) to High(FMsgs) do
    Inc(Q, MessageTokens(FMsgs[I]));
  if (FRegistry <> nil) and (FRegistry.Count > 0) then
  begin
    Arr := TJSONArray.Create;
    try
      FRegistry.BuildRequestTools(Arr);
      Q := Q + (TextQuarterTokens(Arr.AsJSON) + 3) div 4 +
        Int64(FRegistry.Count) * TokensPerToolSchema;
    finally
      Arr.Free;
    end;
  end;
  Result := Integer(Q);
end;

{ Command text from the JSON arguments of the shell tool (empty if unparsable). }
function ShellCommandFromArgs(const ArgsJson: string): string;
var
  D: TJSONData;
  Err: string;
begin
  Result := '';
  if Trim(ArgsJson) = '' then Exit('');
  if not ParseJSONRepair(ArgsJson, D, Err) then Exit('');
  try
    Result := JStr(D, 'command', '');
  finally
    D.Free;
  end;
end;

function TAgent.BuildContext: TToolContext;
begin
  Result := MakeToolContext(FCfg);
  Result.SubAgentDepth := FSubAgentDepth;
  Result.SessionBase := FSessionBase;
  { The registry is available to the tools: subagent reuses it in order not to
    start the same MCP servers again. }
  Result.Registry := FRegistry;
  Result.OnSubAgentEvent := FOnSubAgentEvent;
end;

function TAgent.RunTurn(out FinalText: string; out Err: string): Boolean;
var
  LLM: TLLMClient;
  Resp: TLLMResponse;
  AM, TM: TMessage;
  Outcome: TToolOutcome;
  Step, I: Integer;
  Ctx: TToolContext;
  ShowText: string;
  LoopAction: TLoopAction;
  LoopText: string;
  StartMs: QWord; { model call start time (for the elapsed_ms log field) }
begin
  FinalText := '';
  Err := '';
  Result := False;
  FLoopGuard.Reset; { a new turn — reset the repeat counters }
  Ctx := BuildContext;
  LLM := TLLMClient.Create(FCfg);
  try
    Step := 0;
    { MaxSteps = 0 — no limit. }
    while (FCfg.MaxSteps <= 0) or (Step < FCfg.MaxSteps) do
    begin
      Inc(Step);
      if FCfg.MaxSteps > 0 then
        Fire(aeStep, Format('step %d/%d', [Step, FCfg.MaxSteps]))
      else
        Fire(aeStep, Format('step %d', [Step]));

      { Size of the requested context — the base of the CLI status line: the
        answer tokens are added to it as the stream goes. For a subagent this
        is its own history and system prompt (the event arrives in the common
        handler of the parent). The history at the entry to the turn serves as
        the base of the first step; in the following iterations it has already
        been updated after the answer and the added tool results, so a repeated
        recomputation of the history (with tool schemas) would be superfluous. }
      if Step = 1 then
        EmitContext;

      { Model call: remember the start so that the log (OnModelCall) gets the
        duration — the same for a stream and a plain request. }
      StartMs := TicksMs;
      if FCfg.Stream then
      begin
        { Streaming output: text and reasoning deltas go to the UI as they
          arrive, the result goes to Resp. }
        Fire(aeStreamStart, '');
        if not LLM.ChatStream(FMsgs, FRegistry, @LLMDelta, Resp, Err) then
        begin
          { Close the stream before the error: the UI must get a start/end pair. }
          Fire(aeStreamEnd, '');
          { A failed call also goes to the log: the reason of the failure is in
            the error field of the record. }
          NotifyModelCall(Resp, StartMs, Err);
          Fire(aeError, Err);
          Exit(False);
        end;
        Fire(aeStreamEnd, '');
        NotifyModelCall(Resp, StartMs, '');
      end
      else
      begin
        if not LLM.Chat(FMsgs, FRegistry, Resp, Err) then
        begin
          NotifyModelCall(Resp, StartMs, Err);
          Fire(aeError, Err);
          Exit(False);
        end;
        NotifyModelCall(Resp, StartMs, '');
        if Resp.Reasoning <> '' then
          Fire(aeReasoning, Resp.Reasoning);
      end;

      { The actual request size (usage.prompt_tokens) refers to the history
        BEFORE the answer was added, so the estimate correction is taken here
        while the answer is not yet in FMsgs. Later EmitContext adds it to the
        estimate — and the status line shows the context size not only roughly
        estimated but also verified against the provider. }
      if Resp.PromptTokens > 0 then
        FContextFix := Resp.PromptTokens - ContextTokens;

      { A stream with stream_options.include_usage delivers usage in a separate
        chunk; some providers have no total_tokens in this case, so the event
        is shown for any non-empty field. }
      if (Resp.PromptTokens > 0) or (Resp.CompletionTokens > 0) or
        (Resp.TotalTokens > 0) then
        Fire(aeUsage, Format('tokens: prompt=%d, completion=%d, total=%d',
          [Resp.PromptTokens, Resp.CompletionTokens, Resp.TotalTokens]));

      AM := MakeMessage(mrAssistant, Resp.Content);
      AM.Reasoning := Resp.Reasoning;
      AM.ToolCalls := Resp.ToolCalls;
      Append(AM);

      { The answer is now in the history: the base is recomputed from it right
        away so that the status line does not depend on the rough estimate from
        the stream deltas and includes the answer even when it is the last one
        in the turn (there will be no next aeContext before a new request). }
      EmitContext;

      if Length(Resp.ToolCalls) = 0 then
      begin
        FinalText := Resp.Content;
        Fire(aeAssistant, Resp.Content);
        Exit(True);
      end;

      for I := 0 to High(Resp.ToolCalls) do
      begin
        if (Resp.ToolCalls[I].Name = 'shell') then
        begin
          { For shell show only the command text, without JSON. }
          ShowText := ShellCommandFromArgs(Resp.ToolCalls[I].Arguments);
          if ShowText <> '' then
            Fire(aeShellCommand, ShowText)
          else
            Fire(aeToolCall, Resp.ToolCalls[I].Name + ' ' +
              Resp.ToolCalls[I].Arguments);
        end
        else
        begin
          ShowText := Resp.ToolCalls[I].Name;
          if Resp.ToolCalls[I].Arguments <> '' then
            ShowText := ShowText + ' ' + Resp.ToolCalls[I].Arguments;
          Fire(aeToolCall, ShowText);
        end;

        Outcome := FRegistry.Invoke(Resp.ToolCalls[I].Name,
          Resp.ToolCalls[I].Arguments, Ctx);

        TM := MakeMessage(mrTool, Outcome.Text);
        TM.ToolCallId := Resp.ToolCalls[I].Id;
        TM.Name := Resp.ToolCalls[I].Name;
        if Outcome.IsError and (Pos('ERROR', Outcome.Text) <> 1) then
          TM.Content := 'ERROR: ' + Outcome.Text;
        Append(TM);

        { Loop-guard: check of repeated tool calls. }
        LoopAction := FLoopGuard.Feed(Resp.ToolCalls[I].Name,
          Resp.ToolCalls[I].Arguments, TM.Content, LoopText);
        if LoopAction = laWarn then
        begin
          { Synthetic user message: the model has to change its approach. }
          Append(MakeMessage(mrUser, LoopText));
          Fire(aeLoopWarning, LoopText);
        end;

        Fire(aeToolResult, TM.Content);

        if LoopAction = laStop then
        begin
          { Loop: stop the turn with an error. }
          Err := LoopText;
          Fire(aeError, LoopText);
          Exit(False);
        end;
      end;

      { The tool results (and possibly the synthetic loop-guard message) are
        added to the history: the next request already goes with them, so the
        status line base is recomputed — otherwise the step counters would lag
        by the whole volume of the tool output. }
      EmitContext;
    end;
    Err := Format('step limit reached (%d): the model did not finish the answer', [FCfg.MaxSteps]);
    Fire(aeError, Err);
    Result := False;
  finally
    LLM.Free;
  end;
end;

end.
