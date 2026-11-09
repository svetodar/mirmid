unit mirmid.llm;
{ Client of the OpenAI-compatible Chat Completions API. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, mirmid.types, mirmid.tools;

type
  TLLMResponse = record
    Content: string;
    Reasoning: string;
    ToolCalls: array of TToolCall;
    FinishReason: string;
    { Exact request size in tokens from the response usage (0 — the provider
      did not send usage). In a stream it arrives as a separate chunk only with
      stream_options.include_usage. }
    PromptTokens: Integer;
    CompletionTokens: Integer;
    TotalTokens: Integer;
  end;

  { Model stream delta: a piece of the answer text and/or of the reasoning. }
  TLLMDeltaHandler = procedure(const ContentDelta, ReasoningDelta: string) of object;

  { Notification about a completed model call (the model process journal):
    request snapshot, response, call duration in ms and the error text (empty —
    the call succeeded). On error Resp may be partial (interrupted stream) or
    empty. The handler does not affect the flow: it only records data. }
  TModelCallEvent = procedure(const Msgs: TMessages; const Resp: TLLMResponse;
    ElapsedMs: Int64; const ErrText: string) of object;

  { Accumulator of one model response stream (SSE). Collects content,
    reasoning_content, tool_calls (by index from the deltas), finish_reason and usage. }
  TSSEAccumulator = class
  private
    FContent, FReasoning: string;
    FToolCalls: array of TToolCall;
    FFinishReason: string;
    FPromptTokens, FCompletionTokens, FTotalTokens: Integer;
    FDone: Boolean;
    FLineBuf: RawByteString;   { tail of a line not yet terminated by #10 }
    FOnDelta: TLLMDeltaHandler;
    procedure AccumulateDelta(const D: TJSONData);
    procedure AccumulateUsage(const D: TJSONData);
  public
    constructor Create;
    destructor Destroy; override;
    { Resets the state and the buffer for parsing a new stream. }
    procedure Reset;
    { The stream is done ([DONE] received). }
    property Done: Boolean read FDone;
    { Called for every delta with a non-empty content and/or reasoning. }
    property OnDelta: TLLMDeltaHandler read FOnDelta write FOnDelta;
    { Accepts an arbitrary fragment of the SSE stream. A network chunk may cut
      a JSON line anywhere, so the incomplete tail (without #10) is buffered
      until the next call or Flush. Returns False when the stream is done
      ([DONE]). }
    function FeedChunk(const Chunk: RawByteString): Boolean;
    { Sends the rest of the buffer (the last line without #10) to the parser. }
    function Flush: Boolean;
    { Parses one SSE line (with the "data:" prefix). Returns False when the
      stream is done ([DONE]). Damaged chunks are skipped. }
    function FeedLine(const Line: string): Boolean;
    { Writes the accumulated data into Resp. }
    procedure Collect(out Resp: TLLMResponse);
  end;

  { One entry of the model list: id and the optional details the provider
    reports (LM Studio — the native /api/v0/models, DeepSeek — fields in the
    standard /models). }
  TModelInfo = record
    Id: string;
    ContextLength: Integer;       { 0 — not reported }
    LoadedContextLength: Integer; { 0 — not reported }
    Kind: string;                 { model type (type) }
    State: string;                { load state }
    Details: Boolean;             { the provider reported something beyond the id }
  end;

  { Model list. }
  TModelList = array of TModelInfo;

  TLLMClient = class
  private
    FCfg: TMirmidConfig;
    FAcc: TSSEAccumulator;   { SSE stream accumulator (lives with the client) }
  public
    constructor Create(const ACfg: TMirmidConfig);
    destructor Destroy; override;
    { One request to the model. On success Result=True and Resp is filled. }
    function Chat(const Msgs: TMessages; Registry: TToolRegistry;
      out Resp: TLLMResponse; out Err: string): Boolean;
    { Request in the streaming mode (SSE): the deltas are passed to OnDelta as
      they arrive, the result goes into Resp. }
    function ChatStream(const Msgs: TMessages; Registry: TToolRegistry;
      const OnDelta: TLLMDeltaHandler; out Resp: TLLMResponse; out Err: string): Boolean;
    { Model list: when the provider reports details (context, type, state) —
      a table, otherwise only the identifiers. }
    function ListModels(out Text: string; out Err: string): Boolean;
    { Model list as TModelList (without formatting). }
    function FetchModelList(out Models: TModelList; out Err: string): Boolean;
    { Accept a fragment of the SSE stream (a network chunk) into the
      accumulator. A network chunk may cut a JSON line anywhere: the incomplete
      tail is buffered until the next call or Flush. Returns False once [DONE]
      arrived. This is the HttpRequestStream handler; also available to tests. }
    function SSEChunk(const Chunk: RawByteString): Boolean;
    { Accumulator of the current stream: OnDelta, Flush, Collect. The state is
      reset at the start of ChatStream. Open for buffering tests. }
    property Accumulator: TSSEAccumulator read FAcc;
  end;

{ URL of the native LM Studio model list (/api/v0/models on the same host). }
function NativeModelsUrl(const BaseUrl: string): string;

{ Parses one model list entry — native or standard. }
function ParseModelInfo(Item: TJSONData): TModelInfo;

{ Effective context: the minimum of the values reported by the provider.
  0 — the provider reported none of them. }
function EffectiveContext(const M: TModelInfo): Integer;

{ Human-readable model table with aligned columns. }
function FormatModelsTable(const Models: TModelList): string;

implementation

uses
  mirmid.http, mirmid.json;

constructor TLLMClient.Create(const ACfg: TMirmidConfig);
begin
  inherited Create;
  FCfg := ACfg;
  FAcc := TSSEAccumulator.Create;
end;

destructor TLLMClient.Destroy;
begin
  FAcc.Free;
  inherited Destroy;
end;

{ --------------------------------------------------------------- SSE }

procedure TSSEAccumulator.Reset;
begin
  FContent := '';
  FReasoning := '';
  SetLength(FToolCalls, 0);
  FFinishReason := '';
  FPromptTokens := 0;
  FCompletionTokens := 0;
  FTotalTokens := 0;
  FDone := False;
  FLineBuf := '';
end;

constructor TSSEAccumulator.Create;
begin
  inherited Create;
  FOnDelta := nil;
  Reset;
end;

destructor TSSEAccumulator.Destroy;
begin
  inherited Destroy;
end;

procedure TSSEAccumulator.AccumulateUsage(const D: TJSONData);
var
  U: TJSONData;
begin
  U := nil;
  try
    U := D.FindPath('usage');
  except
    U := nil;
  end;
  if (U = nil) or not (U is TJSONObject) then
    Exit;
  FPromptTokens := JInt(U, 'prompt_tokens', FPromptTokens);
  FCompletionTokens := JInt(U, 'completion_tokens', FCompletionTokens);
  FTotalTokens := JInt(U, 'total_tokens', FTotalTokens);
end;

procedure TSSEAccumulator.AccumulateDelta(const D: TJSONData);
var
  Content, Reasoning, Finish: string;
  Arr: TJSONArray;
  Item: TJSONData;
  I, Idx: Integer;
  TC: TToolCall;
begin
  Content := JStr(D, 'choices[0].delta.content', '');
  { Providers name the field differently: reasoning_content or reasoning. }
  Reasoning := JStr(D, 'choices[0].delta.reasoning_content', '');
  if Reasoning = '' then
    Reasoning := JStr(D, 'choices[0].delta.reasoning', '');
  Finish := JStr(D, 'choices[0].finish_reason', '');

  if Content <> '' then
    FContent := FContent + Content;
  if Reasoning <> '' then
    FReasoning := FReasoning + Reasoning;
  if Finish <> '' then
    FFinishReason := Finish;

  { tool_calls are collected by index: id/name arrive once, the arguments are
    concatenated from the deltas. }
  Arr := nil;
  Item := D.FindPath('choices[0].delta.tool_calls');
  if (Item <> nil) and (Item is TJSONArray) then
    Arr := TJSONArray(Item);
  if Arr <> nil then
  begin
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.Items[I];
      if not (Item is TJSONObject) then
        Continue;
      Idx := JInt(Item, 'index', 0);
      while Length(FToolCalls) <= Idx do
        SetLength(FToolCalls, Length(FToolCalls) + 1);
      TC := FToolCalls[Idx];
      if JStr(Item, 'id', '') <> '' then
        TC.Id := JStr(Item, 'id', '');
      if JStr(Item, 'function.name', '') <> '' then
        TC.Name := TC.Name + JStr(Item, 'function.name', '');
      TC.Arguments := TC.Arguments + JStr(Item, 'function.arguments', '');
      FToolCalls[Idx] := TC;
    end;
  end;

  if (Content <> '') or (Reasoning <> '') then
    if Assigned(FOnDelta) then
      FOnDelta(Content, Reasoning);
end;

{ Accepts an arbitrary fragment of the SSE stream and parses all complete
  lines. A JSON line may arrive in parts: the tail without #10 stays in the
  buffer until the next call or Flush. }
function TSSEAccumulator.FeedChunk(const Chunk: RawByteString): Boolean;
var
  P: Integer;
  L: string;
begin
  Result := True;
  FLineBuf := FLineBuf + Chunk;
  while Pos(#10, FLineBuf) > 0 do
  begin
    P := Pos(#10, FLineBuf);
    L := Copy(FLineBuf, 1, P - 1);
    Delete(FLineBuf, 1, P);
    if not FeedLine(L) then
      Exit(False);   { [DONE] — reading may stop }
  end;
end;

{ Sends the rest of the buffer to the parser: the last line of the stream may
  lack the terminating #10. Returns False when the stream is done ([DONE]). }
function TSSEAccumulator.Flush: Boolean;
begin
  Result := True;
  if FLineBuf = '' then
    Exit;
  Result := FeedLine(FLineBuf);
  FLineBuf := '';
end;

function TSSEAccumulator.FeedLine(const Line: string): Boolean;
var
  L, Payload: string;
  D: TJSONData;
  Err: string;
begin
  Result := True;
  if FDone then
    Exit(False);
  L := Line;
  while (Length(L) > 0) and (L[Length(L)] = #13) do
    Delete(L, Length(L), 1);
  if Trim(L) = '' then
    Exit(True);
  { SSE comments and empty events carry no data. }
  if Pos('data:', L) <> 1 then
    Exit(True);
  Payload := Trim(Copy(L, 6, MaxInt));
  if Payload = '[DONE]' then
  begin
    FDone := True;
    Result := False;
    Exit;
  end;
  if not ParseJSON(Payload, D, Err) then
    Exit(True);   { damaged chunk — skipped }
  try
    if D is TJSONObject then
    begin
      AccumulateUsage(D);
      AccumulateDelta(D);
    end;
  finally
    D.Free;
  end;
end;

procedure TSSEAccumulator.Collect(out Resp: TLLMResponse);
begin
  Resp.Content := FContent;
  Resp.Reasoning := FReasoning;
  Resp.ToolCalls := FToolCalls;
  Resp.FinishReason := FFinishReason;
  Resp.PromptTokens := FPromptTokens;
  Resp.CompletionTokens := FCompletionTokens;
  Resp.TotalTokens := FTotalTokens;
end;

function TLLMClient.SSEChunk(const Chunk: RawByteString): Boolean;
begin
  { Partial lines are buffered by the accumulator: a network chunk may cut a
    JSON line at any position (see FeedChunk). }
  Result := FAcc.FeedChunk(Chunk);
end;

function TLLMClient.ChatStream(const Msgs: TMessages; Registry: TToolRegistry;
  const OnDelta: TLLMDeltaHandler; out Resp: TLLMResponse; out Err: string): Boolean;
var
  O: TJSONObject;
  SO: TJSONObject;
  ToolsArr: TJSONArray;
  Body, Url: string;
  Code: Integer;
  StatusText: string;
begin
  Result := False;
  Err := '';
  Resp.Content := '';
  Resp.Reasoning := '';
  Resp.FinishReason := '';
  Resp.PromptTokens := 0;
  Resp.CompletionTokens := 0;
  Resp.TotalTokens := 0;
  SetLength(Resp.ToolCalls, 0);

  if FCfg.Model = '' then
  begin
    Err := 'model is not set (--model or model= in mirmid.ini)';
    Exit;
  end;

  O := TJSONObject.Create;
  try
    O.Add('model', FCfg.Model);
    O.Add('temperature', FCfg.Temperature);
    O.Add('max_tokens', FCfg.MaxTokens);
    O.Add('stream', True);
    { Ask for usage in a stream too: without include_usage the provider does
      not send prompt_tokens and the exact request size stays unknown (the CLI
      shows only an estimate, ContextTokens). It arrives as a separate chunk
      before [DONE] — parsed by TSSEAccumulator.AccumulateUsage. }
    SO := TJSONObject.Create;
    SO.Add('include_usage', True);
    O.Add('stream_options', SO);
    { The reasoning mode is set only explicitly: without it the provider uses
      its own default. }
    if FCfg.Reasoning <> '' then
      O.Add('reasoning_effort', FCfg.Reasoning);
    O.Add('messages', MessagesToJSONArray(Msgs));
    if (Registry <> nil) and (Registry.Count > 0) then
    begin
      ToolsArr := TJSONArray.Create;
      Registry.BuildRequestTools(ToolsArr);
      O.Add('tools', ToolsArr);
      O.Add('tool_choice', 'auto');
    end;
    Body := O.AsJSON;
  finally
    O.Free;
  end;

  { The accumulator lives with the client: reset it before a new stream. }
  FAcc.Reset;
  FAcc.OnDelta := OnDelta;
  Url := JoinUrl(FCfg.BaseUrl, '/chat/completions');
  if not HttpRequestStream('POST', Url, FCfg.ApiKey, Body,
    FCfg.RequestTimeout, FCfg.ConnectTimeout, @SSEChunk, Code, StatusText, Err) then
    Exit(False);
  { Timeout in the middle of the stream: the 2xx status already arrived
    (Result=True) but Err is set — the request is treated as failed. }
  if Err <> '' then
    Exit(False);
  { The last line may lack the terminating newline. }
  FAcc.Flush;
  if not FAcc.Done then
  begin
    { The server closed the connection without sending [DONE]: the answer is cut. }
    Err := 'the server closed the connection before the response completed (no [DONE])';
    Exit(False);
  end;
  FAcc.Collect(Resp);
  Result := True;
end;

function TLLMClient.Chat(const Msgs: TMessages; Registry: TToolRegistry;
  out Resp: TLLMResponse; out Err: string): Boolean;
var
  O: TJSONObject;
  ToolsArr: TJSONArray;
  Body, Url: string;
  HR: THttpResult;
  D, MsgD, ErrD: TJSONData;
  AM: TMessage;
begin
  Result := False;
  Err := '';
  Resp.Content := '';
  Resp.Reasoning := '';
  Resp.FinishReason := '';
  Resp.PromptTokens := 0;
  Resp.CompletionTokens := 0;
  Resp.TotalTokens := 0;
  SetLength(Resp.ToolCalls, 0);

  if FCfg.Model = '' then
  begin
    Err := 'model is not set (--model or model= in mirmid.ini)';
    Exit;
  end;

  O := TJSONObject.Create;
  try
    O.Add('model', FCfg.Model);
    O.Add('temperature', FCfg.Temperature);
    O.Add('max_tokens', FCfg.MaxTokens);
    O.Add('stream', False);
    { The reasoning mode is set only explicitly: without it the provider uses
      its own default. }
    if FCfg.Reasoning <> '' then
      O.Add('reasoning_effort', FCfg.Reasoning);
    O.Add('messages', MessagesToJSONArray(Msgs));
    if (Registry <> nil) and (Registry.Count > 0) then
    begin
      ToolsArr := TJSONArray.Create;
      Registry.BuildRequestTools(ToolsArr);
      O.Add('tools', ToolsArr);
      O.Add('tool_choice', 'auto');
    end;
    Body := O.AsJSON;
  finally
    O.Free;
  end;

  Url := JoinUrl(FCfg.BaseUrl, '/chat/completions');
  HR := HttpRequest('POST', Url, FCfg.ApiKey, Body, FCfg.RequestTimeout, FCfg.ConnectTimeout);
  if not HR.Ok then
  begin
    Err := Trim(HR.Error);
    if Trim(HR.Body) <> '' then
      Err := Err + sLineBreak + Trim(HR.Body);
    Exit;
  end;

  if not ParseJSON(HR.Body, D, Err) then
  begin
    Err := 'failed to parse the API response: ' + Err;
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      Err := 'the API response is not a JSON object';
      Exit;
    end;
    ErrD := D.FindPath('error');
    if (ErrD <> nil) and (not (ErrD is TJSONNull)) then
    begin
      Err := JStr(D, 'error.message', D.AsJSON);
      Exit;
    end;
    MsgD := D.FindPath('choices[0].message');
    if MsgD = nil then
    begin
      Err := 'the response has no choices[0].message';
      Exit;
    end;
    if not (MsgD is TJSONObject) then
    begin
      Err := 'choices[0].message is not an object';
      Exit;
    end;

    AM := JSONToMessage(TJSONObject(MsgD));
    Resp.Content := AM.Content;
    Resp.Reasoning := AM.Reasoning;
    Resp.ToolCalls := AM.ToolCalls;
    Resp.FinishReason := JStr(D, 'choices[0].finish_reason', '');
    Resp.PromptTokens := JInt(D, 'usage.prompt_tokens', 0);
    Resp.CompletionTokens := JInt(D, 'usage.completion_tokens', 0);
    Resp.TotalTokens := JInt(D, 'usage.total_tokens', 0);
    Result := True;
  finally
    D.Free;
  end;
end;

{ --------------------------------------------------------------- models }

function NativeModelsUrl(const BaseUrl: string): string;
var
  B: string;
begin
  B := Trim(BaseUrl);
  while (B <> '') and (B[Length(B)] = '/') do
    Delete(B, Length(B), 1);
  { The base URL from the settings ends with /v1; the native API lives on the
    same host without that suffix. }
  if (Length(B) >= Length('/v1')) and
     (Copy(B, Length(B) - Length('/v1') + 1, Length('/v1')) = '/v1') then
    B := Copy(B, 1, Length(B) - Length('/v1'));
  Result := B + '/api/v0/models';
end;

{ The first of the paths that exists and converts to int; 0 — none. }
function FirstIntOf(D: TJSONData; const Paths: array of string): Integer;
var
  I: Integer;
  X: TJSONData;
begin
  Result := 0;
  if D = nil then
    Exit;
  for I := Low(Paths) to High(Paths) do
  begin
    X := nil;
    try
      X := D.FindPath(Paths[I]);
    except
      X := nil;
    end;
    if (X = nil) or (X is TJSONNull) then
      Continue;
    if X is TJSONNumber then
      Result := X.AsInteger
    else
      Result := StrToIntDef(X.AsString, 0);
    Exit;
  end;
end;

function ParseModelInfo(Item: TJSONData): TModelInfo;
begin
  Result.Id := '';
  Result.ContextLength := 0;
  Result.LoadedContextLength := 0;
  Result.Kind := '';
  Result.State := '';
  Result.Details := False;
  if (Item = nil) or not (Item is TJSONObject) then
    Exit;
  { Providers use different field names: LM Studio returns type /
    max_context_length / state, DeepSeek — context_window. }
  Result.Id := JStr(Item, 'id', '');
  Result.ContextLength := FirstIntOf(Item,
    ['max_context_length', 'context_window', 'context_length']);
  Result.LoadedContextLength := JInt(Item, 'loaded_context_length', 0);
  Result.Kind := JStr(Item, 'type', '');
  Result.State := JStr(Item, 'state', '');
  Result.Details := (Result.ContextLength <> 0) or
    (Result.LoadedContextLength <> 0) or (Result.Kind <> '') or
    (Result.State <> '');
end;

function EffectiveContext(const M: TModelInfo): Integer;
begin
  { The provider reports the theoretical maximum of the model and/or the context
    the model is loaded with; the smaller of the two is really available. }
  Result := 0;
  if M.ContextLength > 0 then
    Result := M.ContextLength;
  if (M.LoadedContextLength > 0) and
     ((Result = 0) or (M.LoadedContextLength < Result)) then
    Result := M.LoadedContextLength;
end;

procedure ModelRow(const M: TModelInfo; out Row: array of string);
begin
  Row[0] := M.Id;
  Row[1] := M.Kind;
  if Row[1] = '' then
    Row[1] := '-';
  Row[2] := IntToStr(EffectiveContext(M));
  if Row[2] = '0' then
    Row[2] := '-';
  Row[3] := M.State;
  if Row[3] = '' then
    Row[3] := '-';
end;

function FormatModelsTable(const Models: TModelList): string;
const
  NCOLS = 4;
  HEADERS: array[0..NCOLS - 1] of string = ('MODEL', 'TYPE', 'CONTEXT', 'STATE');
var
  L: TStringList;
  Widths: array[0..NCOLS - 1] of Integer;
  Row: array[0..NCOLS - 1] of string;
  I, J: Integer;
  Line: string;
begin
  L := TStringList.Create;
  try
    for J := 0 to NCOLS - 1 do
      Widths[J] := Length(HEADERS[J]);
    for I := Low(Models) to High(Models) do
    begin
      ModelRow(Models[I], Row);
      for J := 0 to NCOLS - 1 do
        if Length(Row[J]) > Widths[J] then
          Widths[J] := Length(Row[J]);
    end;
    Line := '';
    for J := 0 to NCOLS - 1 do
    begin
      Line := Line + HEADERS[J] +
        StringOfChar(' ', Widths[J] - Length(HEADERS[J]));
      if J < NCOLS - 1 then
        Line := Line + '  ';
    end;
    L.Add(TrimRight(Line));
    for I := Low(Models) to High(Models) do
    begin
      ModelRow(Models[I], Row);
      Line := '';
      for J := 0 to NCOLS - 1 do
      begin
        Line := Line + Row[J] +
          StringOfChar(' ', Widths[J] - Length(Row[J]));
        if J < NCOLS - 1 then
          Line := Line + '  ';
      end;
      L.Add(TrimRight(Line));
    end;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function CompareModelIds(const A, B: TModelInfo): Integer;
var
  LA, LB: string;
begin
  { Case-insensitive sorting. }
  LA := LowerCase(A.Id);
  LB := LowerCase(B.Id);
  if LA < LB then
    Result := -1
  else if LA > LB then
    Result := 1
  else if A.Id < B.Id then
    Result := -1
  else if A.Id > B.Id then
    Result := 1
  else
    Result := 0;
end;

procedure SortModels(var Models: array of TModelInfo);
var
  I, J: Integer;
  T: TModelInfo;
begin
  for I := 1 to High(Models) do
  begin
    T := Models[I];
    J := I - 1;
    while (J >= 0) and (CompareModelIds(Models[J], T) > 0) do
    begin
      Models[J + 1] := Models[J];
      Dec(J);
    end;
    Models[J + 1] := T;
  end;
end;

{ GET of the model list: parse the data field, drop entries without an id. }
function FetchModels(const Url, ApiKey: string; TimeoutMs, ConnectMs: Integer;
  out Models: TModelList; out Err: string): Boolean;
var
  HR: THttpResult;
  D, DataD: TJSONData;
  Arr: TJSONArray;
  I, N: Integer;
begin
  Result := False;
  Err := '';
  SetLength(Models, 0);
  HR := HttpRequest('GET', Url, ApiKey, '', TimeoutMs, ConnectMs);
  if not HR.Ok then
  begin
    Err := Trim(HR.Error);
    if Trim(HR.Body) <> '' then
      Err := Err + sLineBreak + Trim(HR.Body);
    Exit;
  end;
  if not ParseJSON(HR.Body, D, Err) then
    Exit;
  try
    DataD := nil;
    if D is TJSONObject then
      DataD := D.FindPath('data');
    if not (DataD is TJSONArray) then
    begin
      Err := 'the response has no data list';
      Exit;
    end;
    Arr := TJSONArray(DataD);
    SetLength(Models, Arr.Count);
    N := 0;
    for I := 0 to Arr.Count - 1 do
    begin
      Models[I] := ParseModelInfo(Arr.Items[I]);
      if Models[I].Id <> '' then
      begin
        if N <> I then
          Models[N] := Models[I];
        Inc(N);
      end;
    end;
    SetLength(Models, N);
    Result := True;
  finally
    D.Free;
  end;
end;

function TLLMClient.FetchModelList(out Models: TModelList; out Err: string): Boolean;
begin
  if not FetchModels(NativeModelsUrl(FCfg.BaseUrl), FCfg.ApiKey,
      60000, FCfg.ConnectTimeout, Models, Err) then
    if not FetchModels(JoinUrl(FCfg.BaseUrl, '/models'), FCfg.ApiKey,
        60000, FCfg.ConnectTimeout, Models, Err) then
      Exit(False);
  Result := True;
end;

function TLLMClient.ListModels(out Text: string; out Err: string): Boolean;
var
  Models: TModelList;
  HasDetails: Boolean;
  I: Integer;
  L: TStringList;
begin
  Result := False;
  Text := '';
  Err := '';
  { First try the extended provider endpoint (LM Studio /api/v0/models:
    context, type, state); if it is missing — the standard /models. Errors of
    the first request are not fatal. }
  if not FetchModels(NativeModelsUrl(FCfg.BaseUrl), FCfg.ApiKey,
      60000, FCfg.ConnectTimeout, Models, Err) then
    if not FetchModels(JoinUrl(FCfg.BaseUrl, '/models'), FCfg.ApiKey,
        60000, FCfg.ConnectTimeout, Models, Err) then
      Exit;
  if Length(Models) = 0 then
  begin
    Result := True;
    Exit;
  end;
  SortModels(Models);
  { The extended fields exist only with some providers: if no model has them,
    print the usual ids instead of an empty table. }
  HasDetails := False;
  for I := Low(Models) to High(Models) do
    if Models[I].Details then
    begin
      HasDetails := True;
      Break;
    end;
  if HasDetails then
    Text := FormatModelsTable(Models)
  else
  begin
    L := TStringList.Create;
    try
      for I := Low(Models) to High(Models) do
        L.Add(Models[I].Id);
      Text := L.Text;
    finally
      L.Free;
    end;
  end;
  Result := True;
end;

end.
