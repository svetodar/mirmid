unit mirmid.anthropic;
{ Anthropic Messages API client (POST /v1/messages).
  Supports the regular and the streaming (SSE) mode, tools, system prompt. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, mirmid.types, mirmid.tools;
const
  { Anthropic API version (anthropic-version header). }
  ANTHROPIC_API_VERSION = '2023-06-01';

type
  { Content block type in an Anthropic response. }
  { Model of a request to the Anthropic Messages API (POST /v1/messages).
    Follows the documentation: https://docs.anthropic.com/en/api/messages }
  TAnthropicRequest = record
    Model: string;              { required: model id, e.g. "claude-sonnet-4-20250514" }
    Messages: TMessages;        { required: message array (role + content) }
    MaxTokens: Integer;         { required: maximum number of tokens in the answer }
    System: string;             { optional: system prompt }
    Stream: Boolean;            { optional: true — SSE stream }
    Temperature: Double;        { optional: 0..1, 0 — not sent }
    TopP: Double;               { optional: 0..1, 0 — not sent }
    TopK: Integer;              { optional: 0 — not sent }
    StopSequences: array of string; { optional: stop sequences }
    Tools: TJSONArray;          { optional: tool schemas (nil — none) }
    ToolChoice: TJSONObject;    { optional: object with type ("auto"|"any"|"tool") and name }
    Metadata: TJSONObject;      { optional: object with a user_id field }
  end;

  TAnthropicBlockType = (abtText, abtToolUse, abtThinking, abtUnknown);

  { A single content block in the response. }
  TAnthropicContentBlock = record
    BlockType: TAnthropicBlockType;
    Text: string;           { abtText: text }
    ToolId: string;         { abtToolUse: call id }
    ToolName: string;       { abtToolUse: tool name }
    ToolInput: string;      { abtToolUse: JSON arguments (raw string) }
    Thinking: string;       { abtThinking: reasoning text }
    Signature: string;      { abtThinking: signature (extended thinking) }
  end;

  { Token usage in an Anthropic response. }
  TAnthropicUsage = record
    InputTokens: Integer;              { input_tokens }
    OutputTokens: Integer;             { output_tokens }
    CacheCreationInputTokens: Integer; { cache_creation_input_tokens }
    CacheReadInputTokens: Integer;     { cache_read_input_tokens }
  end;

  { Anthropic Messages API response (non-streaming mode).
    Follows: https://docs.anthropic.com/en/api/messages }
  TAnthropicResponse = record
    Id: string;             { "msg_..." }
    MsgType: string;          { always "message" }
    Role: string;           { always "assistant" }
    Model: string;
    Content: array of TAnthropicContentBlock;
    StopReason: string;     { "end_turn" | "max_tokens" | "stop_sequence" | "tool_use" }
    StopSequence: string;   { actual stop sequence (when stop_reason="stop_sequence") }
    Usage: TAnthropicUsage;
    ServiceTier: string;    { "standard" | "priority" (when set) }
  end;
  { Anthropic API error: type, message, HTTP status and the retryable flag.
    Response format: type "error" and an error object with the fields type and message. }
  TAnthropicError = record
    ErrorType: string;    { "authentication_error" | "rate_limit_error" | "api_error" | ... }
    Message: string;      { human-readable message }
    StatusCode: Integer;  { HTTP status (401, 429, 500, ...); 0 — could not connect }
    Retryable: Boolean;   { True for 429 and 5xx — the request may be retried }
  end;
  { List of request validation errors. }
  TAnthropicValidationErrors = array of string;

  { Middleware validator of the request parameters of /v1/messages.
    Called by the client before the HTTP request is sent and rejects invalid
    requests (400 invalid_request_error) without touching the network. }
  TAnthropicValidator = class
  public
    { Checks the required fields and the parameter ranges. Returns True when
      the request is valid; otherwise Errors holds the list of errors. }
    function Validate(const Req: TAnthropicRequest;
      out Errors: TAnthropicValidationErrors): Boolean;
    { Human-readable message for a list of errors (joined with "; "). }
    class function JoinErrors(const Errors: TAnthropicValidationErrors): string;
  end;

  { Anthropic stream delta: a piece of text or of tool_use arguments. }
  TAnthropicDeltaHandler = procedure(const TextDelta, ToolInputDelta: string) of object;

  { Accumulator of the Anthropic SSE stream. Collects content blocks, stop_reason, usage. }
  TAnthropicSSEAccumulator = class
  private
    FBlocks: array of TAnthropicContentBlock;
    FStopReason: string;
    FStopSequence: string;
    FUsage: TAnthropicUsage;
    FModel: string;
    FId: string;
    FDone: Boolean;
    FLineBuf: RawByteString;
    FOnDelta: TAnthropicDeltaHandler;
    procedure HandleEvent(const D: TJSONData);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    property Done: Boolean read FDone;
    property OnDelta: TAnthropicDeltaHandler read FOnDelta write FOnDelta;
    { Accepts a fragment of the SSE stream. Returns False when the stream is done. }
    function FeedChunk(const Chunk: RawByteString): Boolean;
    function Flush: Boolean;
    function FeedLine(const Line: string): Boolean;
    procedure Collect(out Resp: TAnthropicResponse);
  end;

  { Anthropic Messages API client. }
  TAnthropicClient = class
  private
    FApiKey: string;
    FBaseUrl: string;       { https://api.anthropic.com by default }
    FRequestTimeout: Integer; { ms; overall HTTP request timeout }
    FConnectTimeout: Integer; { ms; connect timeout }
    FAcc: TAnthropicSSEAccumulator;
    FValidator: TAnthropicValidator;
  public
    constructor Create(const AApiKey, ABaseUrl: string);
    destructor Destroy; override;
    { A single request to the Anthropic Messages API (regular mode). }
    function SendMessages(const Req: TAnthropicRequest;
      out Resp: TAnthropicResponse; out Err: string;
      out ErrJson: TJSONData): Boolean;
    { Request in the streaming mode (SSE). }
    function SendMessagesStream(const Req: TAnthropicRequest;
      const OnDelta: TAnthropicDeltaHandler;
      out Resp: TAnthropicResponse; out Err: string;
      out ErrJson: TJSONData): Boolean;
    { Accept a fragment of the SSE stream. Returns False once message_stop arrived. }
    function SSEChunk(const Chunk: RawByteString): Boolean;
    { Middleware: validation of the input parameters before the HTTP request is
      sent. Returns False when the request is rejected, Err/ErrJson are filled (400). }
    function ValidateRequest(const Req: TAnthropicRequest;
      out Err: string; out ErrJson: TJSONData): Boolean;
    property Accumulator: TAnthropicSSEAccumulator read FAcc;
  end;

{ Creates a request with sensible defaults. }
function MakeAnthropicRequest(const AModel: string; const AMsgs: TMessages;
  AMaxTokens: Integer): TAnthropicRequest;

{ Builds the JSON body of a request to /v1/messages from the TAnthropicRequest model. }
function BuildRequestJson(const Req: TAnthropicRequest): TJSONData;

{ Parses an Anthropic JSON response into TAnthropicResponse. }
function ParseResponse(const D: TJSONData): TAnthropicResponse;

{ Concatenates all text blocks of the response into a single string. }
function AnthropicResponseText(const R: TAnthropicResponse): string;
{ Parses an Anthropic JSON error body into TAnthropicError. If the body is not
  JSON or lacks the expected structure, the type and the message come from the status. }
function ParseError(const D: TJSONData; AStatusCode: Integer): TAnthropicError;

{ Builds the JSON error object returned to the calling code:
  type "error" and an error object with the fields type, message, status, retryable.
  The calling code must free the result. }
function BuildErrorJson(const E: TAnthropicError): TJSONObject;

{ Human-readable description of an error (for the Err field). }
function AnthropicErrorText(const E: TAnthropicError): string;

implementation

uses
  mirmid.http, mirmid.json, mirmid.util;

{--- MakeAnthropicRequest ---}

function MakeAnthropicRequest(const AModel: string; const AMsgs: TMessages;
  AMaxTokens: Integer): TAnthropicRequest;
begin
  Result.Model         := AModel;
  Result.Messages      := AMsgs;
  Result.MaxTokens     := AMaxTokens;
  Result.System        := '';
  Result.Stream        := False;
  Result.Temperature   := 0;
  Result.TopP          := 0;
  Result.TopK          := 0;
  SetLength(Result.StopSequences, 0);
  Result.Tools         := nil;
  Result.ToolChoice    := nil;
  Result.Metadata      := nil;
end;

{--- BuildRequestJson ---}

function BuildRequestJson(const Req: TAnthropicRequest): TJSONData;
var
  J: TJSONObject;
  JMsgs, JStopSeqs: TJSONArray;
  i: Integer;
  JMsg: TJSONObject;
begin
  J := TJSONObject.Create;

  { required }
  J.Add('model', Req.Model);
  J.Add('max_tokens', Req.MaxTokens);

  { messages }
  JMsgs := TJSONArray.Create;
  for i := 0 to High(Req.Messages) do
  begin
    JMsg := TJSONObject.Create;
    JMsg.Add('role', RoleName(Req.Messages[i].Role));
    JMsg.Add('content', Req.Messages[i].Content);
    JMsgs.Add(JMsg);
  end;
  J.Add('messages', JMsgs);

  { optional: system }
  if Req.System <> '' then
    J.Add('system', Req.System);

  { optional: stream }
  if Req.Stream then
    J.Add('stream', True);

  { optional: sampling params }
  if Req.Temperature > 0 then
    J.Add('temperature', Req.Temperature);
  if Req.TopP > 0 then
    J.Add('top_p', Req.TopP);
  if Req.TopK > 0 then
    J.Add('top_k', Req.TopK);

  { optional: stop_sequences }
  if Length(Req.StopSequences) > 0 then
  begin
    JStopSeqs := TJSONArray.Create;
    for i := 0 to High(Req.StopSequences) do
      JStopSeqs.Add(Req.StopSequences[i]);
    J.Add('stop_sequences', JStopSeqs);
  end;

  { optional: tools }
  if (Req.Tools <> nil) and (Req.Tools.Count > 0) then
    J.Add('tools', Req.Tools);

  { optional: tool_choice }
  if Req.ToolChoice <> nil then
    J.Add('tool_choice', Req.ToolChoice);

  { optional: metadata }
  if Req.Metadata <> nil then
    J.Add('metadata', Req.Metadata);

  Result := J;
end;

{--- ParseResponse ---}

function ParseResponse(const D: TJSONData): TAnthropicResponse;
var
  i: Integer;
  JBlocks: TJSONData;
  JBlock: TJSONData;
  JInput: TJSONData;
begin
  Result := Default(TAnthropicResponse);
  Result.Id           := JStr(D, 'id', '');
  Result.MsgType       := JStr(D, 'type', 'message');
  Result.Role         := JStr(D, 'role', 'assistant');
  Result.Model        := JStr(D, 'model', '');
  Result.StopReason   := JStr(D, 'stop_reason', '');
  Result.StopSequence := JStr(D, 'stop_sequence', '');
  Result.ServiceTier  := JStr(D, 'service_tier', '');

  JBlocks := D.FindPath('content');
  if (JBlocks <> nil) and (JBlocks is TJSONArray) then
  begin
    SetLength(Result.Content, JBlocks.Count);
    for i := 0 to JBlocks.Count - 1 do
    begin
      JBlock := JBlocks.Items[i];
      Result.Content[i].BlockType := abtUnknown;
      case JStr(JBlock, 'type', '') of
        'text': begin
          Result.Content[i].BlockType := abtText;
          Result.Content[i].Text := JStr(JBlock, 'text', '');
        end;
        'tool_use': begin
          Result.Content[i].BlockType := abtToolUse;
          Result.Content[i].ToolId := JStr(JBlock, 'id', '');
          Result.Content[i].ToolName := JStr(JBlock, 'name', '');
          JInput := JBlock.FindPath('input');
          if JInput <> nil then
            Result.Content[i].ToolInput := JInput.AsJSON;
        end;
        'thinking': begin
          Result.Content[i].BlockType := abtThinking;
          Result.Content[i].Thinking := JStr(JBlock, 'thinking', '');
          Result.Content[i].Signature := JStr(JBlock, 'signature', '');
        end;
      end;
    end;
  end;

  Result.Usage.InputTokens := JInt(D, 'usage.input_tokens', 0);
  Result.Usage.OutputTokens := JInt(D, 'usage.output_tokens', 0);
  Result.Usage.CacheCreationInputTokens := JInt(D, 'usage.cache_creation_input_tokens', 0);
  Result.Usage.CacheReadInputTokens := JInt(D, 'usage.cache_read_input_tokens', 0);
end;

{--- AnthropicResponseText ---}

function AnthropicResponseText(const R: TAnthropicResponse): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(R.Content) do
    if R.Content[i].BlockType = abtText then
    begin
      if Result <> '' then
        Result := Result + #10;
      Result := Result + R.Content[i].Text;
    end;
end;
{--- Anthropic API errors ---}

{ Anthropic error type by HTTP status (when the body did not provide its own). }
function ErrorTypeFromStatus(AStatusCode: Integer): string;
begin
  case AStatusCode of
    400: Result := 'invalid_request_error';
    401: Result := 'authentication_error';
    403: Result := 'permission_error';
    404: Result := 'not_found_error';
    429: Result := 'rate_limit_error';
  else
    Result := 'api_error';
  end;
end;

{ Human-readable message by HTTP status (when the body did not provide its own). }
function ErrorMessageFromStatus(AStatusCode: Integer): string;
begin
  case AStatusCode of
    400: Result := 'invalid request (400)';
    401: Result := 'invalid API key (401)';
    403: Result := 'insufficient permissions (403)';
    404: Result := 'not found (404)';
    429: Result := 'rate limit exceeded (429)';
  else
    if AStatusCode >= 500 then
      Result := Format('Anthropic server error (%d)', [AStatusCode])
    else
      Result := Format('Anthropic error (%d)', [AStatusCode]);
  end;
end;

function ParseError(const D: TJSONData; AStatusCode: Integer): TAnthropicError;
var
  ErrD: TJSONData;
  EType, EMsg: string;
begin
  Result.ErrorType  := '';
  Result.Message    := '';
  Result.StatusCode := AStatusCode;
  Result.Retryable  := (AStatusCode = 429) or (AStatusCode >= 500);

  { Anthropic: type "error" and an error object with the fields type and message. }
  ErrD := nil;
  if (D <> nil) and (D is TJSONObject) then
    ErrD := D.FindPath('error');
  if (ErrD <> nil) and (ErrD is TJSONObject) then
  begin
    EType := JStr(ErrD, 'type', '');
    EMsg  := JStr(ErrD, 'message', '');
    if EType <> '' then
      Result.ErrorType := EType;
    if EMsg <> '' then
      Result.Message := EMsg;
  end;

  { The body gave neither type nor message — derive them from the HTTP status. }
  if Result.ErrorType = '' then
    Result.ErrorType := ErrorTypeFromStatus(AStatusCode);
  if Result.Message = '' then
    Result.Message := ErrorMessageFromStatus(AStatusCode);
end;

function BuildErrorJson(const E: TAnthropicError): TJSONObject;
var
  JErr: TJSONObject;
begin
  JErr := TJSONObject.Create;
  JErr.Add('type', E.ErrorType);
  JErr.Add('message', E.Message);
  JErr.Add('status', E.StatusCode);
  JErr.Add('retryable', E.Retryable);

  Result := TJSONObject.Create;
  Result.Add('type', 'error');
  Result.Add('error', JErr);
end;

function AnthropicErrorText(const E: TAnthropicError): string;
begin
  Result := Format('Anthropic API: %s (HTTP %d)', [E.Message, E.StatusCode]);
  if E.ErrorType <> '' then
    Result := Result + ' [' + E.ErrorType + ']';
  if E.Retryable then
    Result := Result + ' (retryable)';
end;
{--- TAnthropicValidator (middleware for input parameter validation) ---}

class function TAnthropicValidator.JoinErrors(const Errors: TAnthropicValidationErrors): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Errors) do
  begin
    if i > 0 then
      Result := Result + '; ';
    Result := Result + Errors[i];
  end;
end;

function TAnthropicValidator.Validate(const Req: TAnthropicRequest;
  out Errors: TAnthropicValidationErrors): Boolean;
var
  i: Integer;
  PrevRole: TMessageRole;
  HasPrev: Boolean;
begin
  SetLength(Errors, 0);
  Result := True;

  { model: required field. }
  if Trim(Req.Model) = '' then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] := 'model: the required field is not set';
    Result := False;
  end;

  { max_tokens: required, positive. }
  if Req.MaxTokens <= 0 then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('max_tokens: must be positive (got %d)', [Req.MaxTokens]);
    Result := False;
  end;

  { messages: required, non-empty array. }
  if Length(Req.Messages) = 0 then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] := 'messages: required field, the array must not be empty';
    Result := False;
  end
  else
  begin
    HasPrev := False;
    PrevRole := mrUser;
    for i := 0 to High(Req.Messages) do
    begin
      { the system role is not allowed in messages (it goes into the system field). }
      if Req.Messages[i].Role = mrSystem then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: the role "system" is not allowed in messages (use the system field)', [i]);
        Result := False;
      end;

      { the tool role is not supported (content is a string). }
      if Req.Messages[i].Role = mrTool then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: the role "tool" is not supported', [i]);
        Result := False;
      end;

      { empty content. }
      if Trim(Req.Messages[i].Content) = '' then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: content must not be empty', [i]);
        Result := False;
      end;

      { the first message comes from the user. }
      if (i = 0) and (Req.Messages[i].Role <> mrUser) then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] := 'messages[0]: the first message must come from the user';
        Result := False;
      end;

      { alternation of the user/assistant roles. }
      if HasPrev and (Req.Messages[i].Role = PrevRole) then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: roles must alternate (user/assistant)', [i]);
        Result := False;
      end;

      PrevRole := Req.Messages[i].Role;
      HasPrev := True;
    end;
  end;

  { temperature: 0..1. }
  if (Req.Temperature > 0) and (Req.Temperature > 1) then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('temperature: must be in the range 0..1 (got %s)', [FloatToStr(Req.Temperature)]);
    Result := False;
  end;

  { top_p: 0..1. }
  if (Req.TopP > 0) and (Req.TopP > 1) then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('top_p: must be in the range 0..1 (got %s)', [FloatToStr(Req.TopP)]);
    Result := False;
  end;

  { top_k: >= 0. }
  if Req.TopK < 0 then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('top_k: must be non-negative (got %d)', [Req.TopK]);
    Result := False;
  end;
end;

{--- TAnthropicSSEAccumulator ---}

constructor TAnthropicSSEAccumulator.Create;
begin
  inherited Create;
  FLineBuf := '';
  FDone := False;
end;

destructor TAnthropicSSEAccumulator.Destroy;
begin
  FBlocks := nil;
  inherited Destroy;
end;

procedure TAnthropicSSEAccumulator.Reset;
begin
  FBlocks := nil;
  FStopReason := '';
  FStopSequence := '';
  FUsage := Default(TAnthropicUsage);
  FModel := '';
  FId := '';
  FDone := False;
  FLineBuf := '';
end;

procedure TAnthropicSSEAccumulator.HandleEvent(const D: TJSONData);
var
  EType: string;
  JMsg, JDelta, JBlock: TJSONData;
  i: Integer;
  LastIdx: Integer;
begin
  EType := JStr(D, 'type', '');
  case EType of
    'message_start':
    begin
      JMsg := D.FindPath('message');
      if JMsg <> nil then
      begin
        FId := JStr(JMsg, 'id', '');
        FModel := JStr(JMsg, 'model', '');
        FUsage.InputTokens := JInt(JMsg, 'usage.input_tokens', 0);
        FUsage.CacheCreationInputTokens := JInt(JMsg, 'usage.cache_creation_input_tokens', 0);
        FUsage.CacheReadInputTokens := JInt(JMsg, 'usage.cache_read_input_tokens', 0);
      end;
    end;
    'content_block_start':
    begin
      { New content block: text, tool_use or thinking. }
      SetLength(FBlocks, Length(FBlocks) + 1);
      LastIdx := Length(FBlocks) - 1;
      FBlocks[LastIdx].BlockType := abtUnknown;
      JBlock := D.FindPath('content_block');
      if JBlock <> nil then
      begin
        case JStr(JBlock, 'type', '') of
          'text':
            FBlocks[LastIdx].BlockType := abtText;
          'tool_use':
          begin
            FBlocks[LastIdx].BlockType := abtToolUse;
            FBlocks[LastIdx].ToolId := JStr(JBlock, 'id', '');
            FBlocks[LastIdx].ToolName := JStr(JBlock, 'name', '');
          end;
          'thinking':
            FBlocks[LastIdx].BlockType := abtThinking;
        end;
      end;
    end;
    'content_block_delta':
    begin
      JDelta := D.FindPath('delta');
      if JDelta <> nil then
      begin
        LastIdx := Length(FBlocks) - 1;
        case JStr(JDelta, 'type', '') of
          'text_delta':
            begin
              if LastIdx >= 0 then
                FBlocks[LastIdx].Text := FBlocks[LastIdx].Text + JStr(JDelta, 'text', '');
              if FOnDelta <> nil then
                FOnDelta(JStr(JDelta, 'text', ''), '');
            end;
          'input_json_delta':
            { tool_use arguments arrive as JSON fragments. }
            if LastIdx >= 0 then
              FBlocks[LastIdx].ToolInput :=
                FBlocks[LastIdx].ToolInput + JStr(JDelta, 'partial_json', '');
          'thinking_delta':
            if LastIdx >= 0 then
              FBlocks[LastIdx].Thinking :=
                FBlocks[LastIdx].Thinking + JStr(JDelta, 'thinking', '');
        end;
      end;
    end;
    'content_block_stop':
      ;   { block finished — the data is already collected }
    'message_delta':
    begin
      JDelta := D.FindPath('delta');
      if JDelta <> nil then
      begin
        FStopReason := JStr(JDelta, 'stop_reason', '');
        FStopSequence := JStr(JDelta, 'stop_sequence', '');
      end;
      FUsage.OutputTokens := JInt(D, 'usage.output_tokens', 0);
    end;
    'message_stop':
      FDone := True;
  end;
end;

function TAnthropicSSEAccumulator.FeedLine(const Line: string): Boolean;
var
  D: TJSONData;
  S: string;
begin
  Result := True;
  S := Line;
  if S = '' then Exit;
  if Copy(S, 1, 5) = 'data:' then
    Delete(S, 1, 5);
  S := Trim(S);
  if S = '' then Exit;
  try
    D := GetJSON(S);
    if D <> nil then
    begin
      HandleEvent(D);
      D.Free;
    end;
  except
    { damaged chunk — skipped }
  end;
  Result := not FDone;
end;

function TAnthropicSSEAccumulator.FeedChunk(const Chunk: RawByteString): Boolean;
var
  P: Integer;
  Line: string;
begin
  FLineBuf := FLineBuf + Chunk;
  Result := True;
  while True do
  begin
    P := Pos(#10, FLineBuf);
    if P = 0 then Break;
    Line := Copy(FLineBuf, 1, P - 1);
    Delete(FLineBuf, 1, P);
    if not FeedLine(Line) then
    begin
      Result := False;
      Break;
    end;
  end;
end;

function TAnthropicSSEAccumulator.Flush: Boolean;
begin
  Result := FeedLine(FLineBuf);
  FLineBuf := '';
end;

procedure TAnthropicSSEAccumulator.Collect(out Resp: TAnthropicResponse);
begin
  Resp := Default(TAnthropicResponse);
  Resp.Id := FId;
  Resp.MsgType := 'message';
  Resp.Role := 'assistant';
  Resp.Model := FModel;
  Resp.StopReason := FStopReason;
  Resp.StopSequence := FStopSequence;
  Resp.Usage := FUsage;
  Resp.Content := FBlocks;
end;

{--- TAnthropicClient ---}

constructor TAnthropicClient.Create(const AApiKey, ABaseUrl: string);
begin
  inherited Create;
  FApiKey := AApiKey;
  if ABaseUrl = '' then
    FBaseUrl := 'https://api.anthropic.com'
  else
    FBaseUrl := ABaseUrl;
  FRequestTimeout := 1800000;
  FConnectTimeout := 10000;
  FAcc := TAnthropicSSEAccumulator.Create;
  FValidator := TAnthropicValidator.Create;
end;

destructor TAnthropicClient.Destroy;
begin
  FAcc.Free;
  FValidator.Free;
  inherited Destroy;
end;
function TAnthropicClient.ValidateRequest(const Req: TAnthropicRequest;
  out Err: string; out ErrJson: TJSONData): Boolean;
var
  VErrors: TAnthropicValidationErrors;
  AE: TAnthropicError;
begin
  Err := '';
  ErrJson := nil;
  SetLength(VErrors, 0);
  if FValidator.Validate(Req, VErrors) then
  begin
    Result := True;
    Exit;
  end;
  AE.ErrorType  := 'invalid_request_error';
  AE.Message    := TAnthropicValidator.JoinErrors(VErrors);
  AE.StatusCode := 400;
  AE.Retryable  := False;
  Err := AnthropicErrorText(AE);
  ErrJson := BuildErrorJson(AE);
  Result := False;
end;

function TAnthropicClient.SendMessages(const Req: TAnthropicRequest;
  out Resp: TAnthropicResponse; out Err: string;
  out ErrJson: TJSONData): Boolean;
var
  Body: TJSONData;
  BodyStr, Url: string;
  HR: THttpResult;
  D, ErrD: TJSONData;
  AE: TAnthropicError;
  Headers: array[0..3] of string;
begin
  Result := False;
  Err := '';
  ErrJson := nil;
  Resp := Default(TAnthropicResponse);
  { Middleware: validation of the input parameters before touching the network. }
  if not ValidateRequest(Req, Err, ErrJson) then
    Exit;

  { The request body is built from the TAnthropicRequest model (step 2). }
  Body := BuildRequestJson(Req);
  try
    BodyStr := Body.AsJSON;
  finally
    Body.Free;
  end;

  { Anthropic Messages API endpoint: POST <base>/v1/messages.
    Anthropic uses x-api-key (not Authorization: Bearer) and
    requires the anthropic-version header. }
  Url := JoinUrl(FBaseUrl, '/v1/messages');
  Headers[0] := 'Content-Type: application/json; charset=utf-8';
  Headers[1] := 'Accept: application/json';
  Headers[2] := 'x-api-key: ' + FApiKey;
  Headers[3] := 'anthropic-version: ' + ANTHROPIC_API_VERSION;
  HR := HttpRequestEx('POST', Url, BodyStr, Headers,
    FRequestTimeout, FConnectTimeout);

  { Non-2xx or a connection failure: parse the Anthropic JSON error and
    return it (401 — invalid key, 429 — rate limit, 500 — server). }
  if not HR.Ok then
  begin
    D := nil;
    if HR.StatusCode = 0 then
    begin
      { Connection not established: there is no HTTP response, status 0. }
      AE.ErrorType  := 'connection_error';
      AE.Message    := Trim(HR.Error);
      AE.StatusCode := 0;
      AE.Retryable  := True;
    end
    else
    begin
      if Trim(HR.Body) <> '' then
        ParseJSON(HR.Body, D, Err);
      AE := ParseError(D, HR.StatusCode);
    end;
    if D <> nil then
      D.Free;
    Err := AnthropicErrorText(AE);
    ErrJson := BuildErrorJson(AE);
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
    { Anthropic returns errors as type "error" and an error object (type, message). }
    ErrD := D.FindPath('error');
    if (ErrD <> nil) and (not (ErrD is TJSONNull)) then
    begin
      AE := ParseError(D, HR.StatusCode);
      Err := AnthropicErrorText(AE);
      ErrJson := BuildErrorJson(AE);
      Exit;
    end;
    Resp := ParseResponse(D);
    Result := True;
  finally
    D.Free;
  end;
end;

function TAnthropicClient.SendMessagesStream(const Req: TAnthropicRequest;
  const OnDelta: TAnthropicDeltaHandler;
  out Resp: TAnthropicResponse; out Err: string;
  out ErrJson: TJSONData): Boolean;
var
  Body: TJSONData;
  BodyStr, Url: string;
  Code: Integer;
  StatusText: string;
  Headers: array[0..3] of string;
  AE: TAnthropicError;
  D: TJSONData;
  ErrBody: string;
  P: Integer;
begin
  Result := False;
  Err := '';
  ErrJson := nil;
  Resp := Default(TAnthropicResponse);
  { Middleware: validation of the input parameters before touching the network. }
  if not ValidateRequest(Req, Err, ErrJson) then
    Exit;

  FAcc.Reset;
  FAcc.OnDelta := OnDelta;

  Body := BuildRequestJson(Req);
  try
    BodyStr := Body.AsJSON;
  finally
    Body.Free;
  end;

  Url := JoinUrl(FBaseUrl, '/v1/messages');
  Headers[0] := 'Content-Type: application/json; charset=utf-8';
  Headers[1] := 'x-api-key: ' + FApiKey;
  Headers[2] := 'anthropic-version: ' + ANTHROPIC_API_VERSION;

  if not HttpRequestStreamEx('POST', Url, BodyStr, Headers,
    FRequestTimeout, FConnectTimeout, @SSEChunk, Code, StatusText, Err) then
  begin
    { Connection error or non-2xx status: parse the JSON error. }
    if Code = 0 then
    begin
      AE.ErrorType  := 'connection_error';
      AE.Message    := Trim(Err);
      AE.StatusCode := 0;
      AE.Retryable  := True;
    end
    else
    begin
      { Err contains "HTTP <status> <text>\n<body>" — extract the JSON body. }
      ErrBody := Err;
      P := Pos('{', ErrBody);
      if P > 0 then
        ErrBody := Copy(ErrBody, P, MaxInt);
      D := nil;
      if Trim(ErrBody) <> '' then
        ParseJSON(ErrBody, D, Err);
      AE := ParseError(D, Code);
      if D <> nil then
        D.Free;
    end;
    Err := AnthropicErrorText(AE);
    ErrJson := BuildErrorJson(AE);
    Exit;
  end;

  { Timeout in the middle of the stream: the 2xx status arrived, but Err is set. }
  if Err <> '' then
    Exit(False);

  { The last line may lack the terminating newline. }
  FAcc.Flush;
  if not FAcc.Done then
  begin
    Err := 'the server closed the connection before the response completed (no message_stop)';
    Exit(False);
  end;
  FAcc.Collect(Resp);
  Result := True;
end;

function TAnthropicClient.SSEChunk(const Chunk: RawByteString): Boolean;
begin
  Result := FAcc.FeedChunk(Chunk);
end;

end.
