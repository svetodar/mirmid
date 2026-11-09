unit test_anthropic;
{ Tests of the Anthropic Messages API: validation, JSON request building,
  response parsing, errors, SSE streaming. No network: mock data. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.anthropic, mirmid.types;

type
  { Validation of required fields and parameter ranges. }
  TAnthropicValidatorTests = class(TTestCase)
  private
    FValidator: TAnthropicValidator;
    function ValidReq: TAnthropicRequest;
    function HasError(const Errors: array of string; const Sub: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestValidRequestPasses;
    procedure TestEmptyModel;
    procedure TestNonPositiveMaxTokens;
    procedure TestEmptyMessages;
    procedure TestFirstMessageNotUser;
    procedure TestRolesNotAlternating;
    procedure TestSystemRoleInMessages;
    procedure TestToolRoleInMessages;
    procedure TestEmptyContent;
    procedure TestTemperatureOutOfRange;
    procedure TestTopPOutOfRange;
    procedure TestTopKNegative;
    procedure TestJoinErrors;
  end;

  { The client rejects an invalid request before touching the network (400). }
  TAnthropicClientValidateTests = class(TTestCase)
  private
    FClient: TAnthropicClient;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestValidRequestAccepted;
    procedure TestInvalidRequestRejected400;
  end;

  { BuildRequestJson: building the JSON request body. }
  TBuildRequestJsonTests = class(TTestCase)
  published
    procedure TestMinimalRequest;
    procedure TestWithSystemPrompt;
    procedure TestWithStream;
    procedure TestWithSamplingParams;
    procedure TestWithStopSequences;
    procedure TestWithTools;
    procedure TestWithToolChoice;
    procedure TestWithMetadata;
    procedure TestOptionalFieldsOmitted;
    procedure TestMessagesStructure;
  end;

  { ParseResponse: parsing the JSON response. }
  TParseResponseTests = class(TTestCase)
  published
    procedure TestSimpleTextResponse;
    procedure TestToolUseResponse;
    procedure TestThinkingResponse;
    procedure TestMultipleBlocks;
    procedure TestUsageFields;
    procedure TestStopSequence;
    procedure TestServiceTier;
    procedure TestEmptyContent;
    procedure TestUnknownBlockType;
  end;

  { ParseError: parsing a JSON error. }
  TParseErrorTests = class(TTestCase)
  published
    procedure TestAuthError401;
    procedure TestRateLimit429;
    procedure TestServerError500;
    procedure TestInvalidRequest400;
    procedure TestNotFound404;
    procedure TestEmptyBody;
    procedure TestNonJsonBody;
    procedure TestRetryableFlag;
  end;

  { BuildErrorJson / AnthropicErrorText. }
  TErrorJsonTests = class(TTestCase)
  published
    procedure TestBuildErrorJsonStructure;
    procedure TestBuildErrorJsonRetryable;
    procedure TestErrorTextWithRetryable;
    procedure TestErrorTextWithoutRetryable;
  end;

  { AnthropicResponseText: joining the text blocks. }
  TResponseTextTests = class(TTestCase)
  published
    procedure TestSingleTextBlock;
    procedure TestMultipleTextBlocks;
    procedure TestIgnoresNonTextBlocks;
    procedure TestEmptyContent;
  end;

  { TAnthropicSSEAccumulator: parsing the SSE stream. }
  TSSEAccumulatorTests = class(TTestCase)
  private
    FAcc: TAnthropicSSEAccumulator;
    FDeltaText: string;
    FDeltaTool: string;
    procedure OnDelta(const TextDelta, ToolInputDelta: string);
    procedure FeedSSE(const Lines: array of string);
    function SSE(const Data: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestMessageStart;
    procedure TestTextBlock;
    procedure TestToolUseBlock;
    procedure TestThinkingBlock;
    procedure TestMessageDelta;
    procedure TestMessageStop;
    procedure TestFullStream;
    procedure TestChunkedFeed;
    procedure TestFlush;
    procedure TestReset;
    procedure TestDeltaCallback;
    procedure TestCollect;
  end;

  { TAnthropicClient.SSEChunk: feeding chunks through the client. }
  TClientSSEChunkTests = class(TTestCase)
  private
    FClient: TAnthropicClient;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFeedChunk;
    procedure TestFeedFullStream;
    procedure TestAccumulatorProperty;
  end;

implementation

uses
  SysUtils, fpjson, mirmid.json;

function ParseJSONSafe(const S: string; out D: TJSONData): Boolean;
var
  Err: string;
begin
  Result := ParseJSON(S, D, Err);
end;
{ --- TAnthropicValidatorTests --- }

function TAnthropicValidatorTests.ValidReq: TAnthropicRequest;
var
  Msgs: TMessages;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Result := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
end;

function TAnthropicValidatorTests.HasError(const Errors: array of string;
  const Sub: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Errors) do
    if Pos(Sub, Errors[i]) > 0 then
      Exit(True);
end;

procedure TAnthropicValidatorTests.SetUp;
begin
  FValidator := TAnthropicValidator.Create;
end;

procedure TAnthropicValidatorTests.TearDown;
begin
  FValidator.Free;
end;

procedure TAnthropicValidatorTests.TestValidRequestPasses;
var
  Errors: array of string;
begin
  AssertTrue('valid request is accepted', FValidator.Validate(ValidReq, Errors));
  AssertEquals('no errors', 0, Length(Errors));
end;

procedure TAnthropicValidatorTests.TestEmptyModel;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.Model := '   ';
  AssertFalse('empty model rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at model', HasError(Errors, 'model'));
end;

procedure TAnthropicValidatorTests.TestNonPositiveMaxTokens;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.MaxTokens := 0;
  AssertFalse('max_tokens=0 rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at max_tokens', HasError(Errors, 'max_tokens'));
end;

procedure TAnthropicValidatorTests.TestEmptyMessages;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  SetLength(Req.Messages, 0);
  AssertFalse('empty messages rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at messages', HasError(Errors, 'messages'));
end;

procedure TAnthropicValidatorTests.TestFirstMessageNotUser;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.Messages[0] := MakeMessage(mrAssistant, 'hello');
  AssertFalse('the first message from assistant rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at messages[0]', HasError(Errors, 'messages[0]'));
end;

procedure TAnthropicValidatorTests.TestRolesNotAlternating;
var
  Req: TAnthropicRequest;
  Msgs: TMessages;
  Errors: array of string;
begin
  SetLength(Msgs, 2);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Msgs[1] := MakeMessage(mrUser, 'one more');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  AssertFalse('two user messages in a row rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at alternation', HasError(Errors, 'alternate'));
end;

procedure TAnthropicValidatorTests.TestSystemRoleInMessages;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.Messages[0] := MakeMessage(mrSystem, 'you are an assistant');
  AssertFalse('system in messages rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at system', HasError(Errors, 'system'));
end;

procedure TAnthropicValidatorTests.TestToolRoleInMessages;
var
  Req: TAnthropicRequest;
  Msgs: TMessages;
  Errors: array of string;
begin
  SetLength(Msgs, 2);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Msgs[1] := MakeMessage(mrTool, 'result');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  AssertFalse('tool in messages rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at tool', HasError(Errors, 'tool'));
end;

procedure TAnthropicValidatorTests.TestEmptyContent;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.Messages[0] := MakeMessage(mrUser, '   ');
  AssertFalse('empty content rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at content', HasError(Errors, 'content'));
end;

procedure TAnthropicValidatorTests.TestTemperatureOutOfRange;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.Temperature := 1.5;
  AssertFalse('temperature>1 rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at temperature', HasError(Errors, 'temperature'));
end;

procedure TAnthropicValidatorTests.TestTopPOutOfRange;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.TopP := 2.0;
  AssertFalse('top_p>1 rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at top_p', HasError(Errors, 'top_p'));
end;

procedure TAnthropicValidatorTests.TestTopKNegative;
var
  Req: TAnthropicRequest;
  Errors: array of string;
begin
  Req := ValidReq;
  Req.TopK := -1;
  AssertFalse('top_k<0 rejected', FValidator.Validate(Req, Errors));
  AssertTrue('points at top_k', HasError(Errors, 'top_k'));
end;

procedure TAnthropicValidatorTests.TestJoinErrors;
var
  Errors: array of string;
begin
  SetLength(Errors, 0);
  AssertEquals('empty list', '', TAnthropicValidator.JoinErrors(Errors));
  SetLength(Errors, 2);
  Errors[0] := 'first';
  Errors[1] := 'second';
  AssertEquals('two errors joined', 'first; second',
    TAnthropicValidator.JoinErrors(Errors));
end;

{ --- TAnthropicClientValidateTests --- }

procedure TAnthropicClientValidateTests.SetUp;
begin
  FClient := TAnthropicClient.Create('test-key', '');
end;

procedure TAnthropicClientValidateTests.TearDown;
begin
  FClient.Free;
end;

procedure TAnthropicClientValidateTests.TestValidRequestAccepted;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  Err: string;
  ErrJson: TJSONData;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  AssertTrue('valid request accepted', FClient.ValidateRequest(Req, Err, ErrJson));
  AssertEquals('no error', '', Err);
  AssertTrue('ErrJson is empty', ErrJson = nil);
end;

procedure TAnthropicClientValidateTests.TestInvalidRequestRejected400;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  Err: string;
  ErrJson: TJSONData;
  JErr: TJSONData;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('', Msgs, 0);   { no model, max_tokens=0 }
  AssertFalse('invalid request rejected', FClient.ValidateRequest(Req, Err, ErrJson));
  AssertTrue('Err is set', Err <> '');
  AssertTrue('ErrJson created', ErrJson <> nil);
  AssertEquals('type error', 'error', JStr(ErrJson, 'type', ''));
  JErr := ErrJson.FindPath('error');
  AssertTrue('error object', JErr <> nil);
  AssertEquals('invalid_request_error', 'invalid_request_error', JStr(JErr, 'type', ''));
  AssertEquals('status 400', 400, JInt(JErr, 'status', 0));
  AssertFalse('not retryable', JBool(JErr, 'retryable', True));
  ErrJson.Free;
end;

{ --- TBuildRequestJsonTests --- }

procedure TBuildRequestJsonTests.TestMinimalRequest;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  J := BuildRequestJson(Req);
  try
    AssertEquals('model', 'claude-sonnet-4-20250514', JStr(J, 'model', ''));
    AssertEquals('max_tokens', 1024, JInt(J, 'max_tokens', 0));
    AssertTrue('messages present', J.FindPath('messages') <> nil);
    AssertEquals('messages length', 1, TJSONArray(J.FindPath('messages')).Count);
    AssertEquals('role', 'user', JStr(J, 'messages[0].role', ''));
    AssertEquals('content', 'hello', JStr(J, 'messages[0].content', ''));
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestWithSystemPrompt;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  Req.System := 'You are an assistant';
  J := BuildRequestJson(Req);
  try
    AssertEquals('system', 'You are an assistant', JStr(J, 'system', ''));
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestWithStream;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  Req.Stream := True;
  J := BuildRequestJson(Req);
  try
    AssertTrue('stream=true', JBool(J, 'stream', False));
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestWithSamplingParams;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  Req.Temperature := 0.7;
  Req.TopP := 0.9;
  Req.TopK := 40;
  J := BuildRequestJson(Req);
  try
    AssertEquals('temperature', 0.7, JFloat(J, 'temperature', 0), 0.01);
    AssertEquals('top_p', 0.9, JFloat(J, 'top_p', 0), 0.01);
    AssertEquals('top_k', 40, JInt(J, 'top_k', 0));
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestWithStopSequences;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
  A: TJSONArray;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  SetLength(Req.StopSequences, 2);
  Req.StopSequences[0] := '\n\n';
  Req.StopSequences[1] := 'STOP';
  J := BuildRequestJson(Req);
  try
    A := TJSONArray(J.FindPath('stop_sequences'));
    AssertTrue('stop_sequences present', A <> nil);
    AssertEquals('length', 2, A.Count);
    AssertEquals('first', '\n\n', A.Items[0].AsString);
    AssertEquals('second', 'STOP', A.Items[1].AsString);
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestWithTools;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
  Tools: TJSONArray;
  Tool: TJSONObject;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  Tools := TJSONArray.Create;
  Tool := TJSONObject.Create;
  Tool.Add('name', 'get_weather');
  Tool.Add('description', 'Get the weather');
  Tool.Add('input_schema', TJSONObject.Create(['type', 'object']));
  Tools.Add(Tool);
  Req.Tools := Tools;
  J := BuildRequestJson(Req);
  try
    AssertTrue('tools present', J.FindPath('tools') <> nil);
    AssertEquals('tools length', 1, TJSONArray(J.FindPath('tools')).Count);
    AssertEquals('tool name', 'get_weather',
      JStr(J, 'tools[0].name', ''));
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestWithToolChoice;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
  TC: TJSONObject;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  TC := TJSONObject.Create;
  TC.Add('type', 'auto');
  Req.ToolChoice := TC;
  J := BuildRequestJson(Req);
  try
    AssertEquals('tool_choice.type', 'auto', JStr(J, 'tool_choice.type', ''));
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestWithMetadata;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
  Meta: TJSONObject;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  Meta := TJSONObject.Create;
  Meta.Add('user_id', 'user-123');
  Req.Metadata := Meta;
  J := BuildRequestJson(Req);
  try
    AssertEquals('metadata.user_id', 'user-123', JStr(J, 'metadata.user_id', ''));
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestOptionalFieldsOmitted;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  J := BuildRequestJson(Req);
  try
    AssertTrue('no system', J.FindPath('system') = nil);
    AssertTrue('no stream', J.FindPath('stream') = nil);
    AssertTrue('no temperature', J.FindPath('temperature') = nil);
    AssertTrue('no top_p', J.FindPath('top_p') = nil);
    AssertTrue('no top_k', J.FindPath('top_k') = nil);
    AssertTrue('no stop_sequences', J.FindPath('stop_sequences') = nil);
    AssertTrue('no tools', J.FindPath('tools') = nil);
    AssertTrue('no tool_choice', J.FindPath('tool_choice') = nil);
    AssertTrue('no metadata', J.FindPath('metadata') = nil);
  finally
    J.Free;
  end;
end;

procedure TBuildRequestJsonTests.TestMessagesStructure;
var
  Msgs: TMessages;
  Req: TAnthropicRequest;
  J: TJSONData;
  A: TJSONArray;
begin
  SetLength(Msgs, 2);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  Msgs[1] := MakeMessage(mrAssistant, 'good day');
  Req := MakeAnthropicRequest('claude-sonnet-4-20250514', Msgs, 1024);
  J := BuildRequestJson(Req);
  try
    A := TJSONArray(J.FindPath('messages'));
    AssertEquals('length', 2, A.Count);
    AssertEquals('role[0]', 'user', JStr(A.Items[0], 'role', ''));
    AssertEquals('content[0]', 'hello', JStr(A.Items[0], 'content', ''));
    AssertEquals('role[1]', 'assistant', JStr(A.Items[1], 'role', ''));
    AssertEquals('content[1]', 'good day', JStr(A.Items[1], 'content', ''));
  finally
    J.Free;
  end;
end;

{ --- TParseResponseTests --- }

procedure TParseResponseTests.TestSimpleTextResponse;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_123","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[{"type":"text","text":"Grüße!"}],' +
    '"stop_reason":"end_turn",' +
    '"usage":{"input_tokens":10,"output_tokens":5}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('id', 'msg_123', R.Id);
    AssertEquals('type', 'message', R.MsgType);
    AssertEquals('role', 'assistant', R.Role);
    AssertEquals('model', 'claude-sonnet-4-20250514', R.Model);
    AssertEquals('stop_reason', 'end_turn', R.StopReason);
    AssertEquals('blocks', 1, Length(R.Content));
    AssertTrue('block text', R.Content[0].BlockType = abtText);
    AssertEquals('text', 'Grüße!', R.Content[0].Text);
    AssertEquals('input_tokens', 10, R.Usage.InputTokens);
    AssertEquals('output_tokens', 5, R.Usage.OutputTokens);
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestToolUseResponse;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_456","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[{"type":"tool_use","id":"toolu_1","name":"get_weather",' +
    '"input":{"city":"Moscow"}}],' +
    '"stop_reason":"tool_use",' +
    '"usage":{"input_tokens":20,"output_tokens":15}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('blocks', 1, Length(R.Content));
    AssertTrue('block tool_use', R.Content[0].BlockType = abtToolUse);
    AssertEquals('tool id', 'toolu_1', R.Content[0].ToolId);
    AssertEquals('tool name', 'get_weather', R.Content[0].ToolName);
    AssertTrue('tool input contains city',
      Pos('"city"', R.Content[0].ToolInput) > 0);
    AssertEquals('stop_reason', 'tool_use', R.StopReason);
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestThinkingResponse;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_789","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[{"type":"thinking","thinking":"Hmm, need to think about it...",' +
    '"signature":"sig_abc"}],' +
    '"stop_reason":"end_turn",' +
    '"usage":{"input_tokens":30,"output_tokens":25}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('blocks', 1, Length(R.Content));
    AssertTrue('block thinking', R.Content[0].BlockType = abtThinking);
    AssertEquals('thinking', 'Hmm, need to think about it...', R.Content[0].Thinking);
    AssertEquals('signature', 'sig_abc', R.Content[0].Signature);
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestMultipleBlocks;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_multi","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[' +
    '{"type":"thinking","thinking":"thinking about it","signature":"s1"},' +
    '{"type":"text","text":"Answer"},' +
    '{"type":"tool_use","id":"t1","name":"calc","input":{"a":1}}' +
    '],' +
    '"stop_reason":"tool_use",' +
    '"usage":{"input_tokens":50,"output_tokens":40}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('blocks', 3, Length(R.Content));
    AssertTrue('block 0 thinking', R.Content[0].BlockType = abtThinking);
    AssertTrue('block 1 text', R.Content[1].BlockType = abtText);
    AssertTrue('block 2 tool_use', R.Content[2].BlockType = abtToolUse);
    AssertEquals('text', 'Answer', R.Content[1].Text);
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestUsageFields;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_usage","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[{"type":"text","text":"ok"}],' +
    '"stop_reason":"end_turn",' +
    '"usage":{"input_tokens":100,"output_tokens":50,' +
    '"cache_creation_input_tokens":10,"cache_read_input_tokens":20}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('input', 100, R.Usage.InputTokens);
    AssertEquals('output', 50, R.Usage.OutputTokens);
    AssertEquals('cache_creation', 10, R.Usage.CacheCreationInputTokens);
    AssertEquals('cache_read', 20, R.Usage.CacheReadInputTokens);
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestStopSequence;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_stop","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[{"type":"text","text":"stop"}],' +
    '"stop_reason":"stop_sequence","stop_sequence":"' + #92 + 'n' + #92 + 'n",' +
    '"usage":{"input_tokens":5,"output_tokens":3}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('stop_reason', 'stop_sequence', R.StopReason);
    AssertEquals('stop_sequence', #10#10, R.StopSequence);
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestServiceTier;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_tier","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[{"type":"text","text":"ok"}],' +
    '"stop_reason":"end_turn","service_tier":"priority",' +
    '"usage":{"input_tokens":1,"output_tokens":1}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('service_tier', 'priority', R.ServiceTier);
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestEmptyContent;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_empty","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[],' +
    '"stop_reason":"end_turn",' +
    '"usage":{"input_tokens":1,"output_tokens":0}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('blocks', 0, Length(R.Content));
  finally
    D.Free;
  end;
end;

procedure TParseResponseTests.TestUnknownBlockType;
var
  D: TJSONData;
  R: TAnthropicResponse;
  S: string;
begin
  S := '{"id":"msg_unknown","type":"message","role":"assistant",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"content":[{"type":"unknown_type","data":"x"}],' +
    '"stop_reason":"end_turn",' +
    '"usage":{"input_tokens":1,"output_tokens":1}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    R := ParseResponse(D);
    AssertEquals('blocks', 1, Length(R.Content));
    AssertTrue('unknown type', R.Content[0].BlockType = abtUnknown);
  finally
    D.Free;
  end;
end;

{ --- TParseErrorTests --- }

procedure TParseErrorTests.TestAuthError401;
var
  D: TJSONData;
  E: TAnthropicError;
  S: string;
begin
  S := '{"type":"error","error":{"type":"authentication_error",' +
    '"message":"invalid x-api-key provided"}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    E := ParseError(D, 401);
    AssertEquals('type', 'authentication_error', E.ErrorType);
    AssertEquals('message', 'invalid x-api-key provided', E.Message);
    AssertEquals('status', 401, E.StatusCode);
    AssertFalse('not retryable', E.Retryable);
  finally
    D.Free;
  end;
end;

procedure TParseErrorTests.TestRateLimit429;
var
  D: TJSONData;
  E: TAnthropicError;
  S: string;
begin
  S := '{"type":"error","error":{"type":"rate_limit_error",' +
    '"message":"Rate limit reached"}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    E := ParseError(D, 429);
    AssertEquals('type', 'rate_limit_error', E.ErrorType);
    AssertEquals('status', 429, E.StatusCode);
    AssertTrue('retryable', E.Retryable);
  finally
    D.Free;
  end;
end;

procedure TParseErrorTests.TestServerError500;
var
  D: TJSONData;
  E: TAnthropicError;
  S: string;
begin
  S := '{"type":"error","error":{"type":"api_error",' +
    '"message":"Internal server error"}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    E := ParseError(D, 500);
    AssertEquals('type', 'api_error', E.ErrorType);
    AssertEquals('status', 500, E.StatusCode);
    AssertTrue('retryable', E.Retryable);
  finally
    D.Free;
  end;
end;

procedure TParseErrorTests.TestInvalidRequest400;
var
  D: TJSONData;
  E: TAnthropicError;
  S: string;
begin
  S := '{"type":"error","error":{"type":"invalid_request_error",' +
    '"message":"max_tokens must be positive"}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    E := ParseError(D, 400);
    AssertEquals('type', 'invalid_request_error', E.ErrorType);
    AssertEquals('status', 400, E.StatusCode);
    AssertFalse('not retryable', E.Retryable);
  finally
    D.Free;
  end;
end;

procedure TParseErrorTests.TestNotFound404;
var
  D: TJSONData;
  E: TAnthropicError;
  S: string;
begin
  S := '{"type":"error","error":{"type":"not_found_error",' +
    '"message":"Model not found"}}';
  D := nil;
  AssertTrue('JSON parsed', ParseJSONSafe(S, D));
  try
    E := ParseError(D, 404);
    AssertEquals('type', 'not_found_error', E.ErrorType);
    AssertEquals('status', 404, E.StatusCode);
    AssertFalse('not retryable', E.Retryable);
  finally
    D.Free;
  end;
end;

procedure TParseErrorTests.TestEmptyBody;
var
  E: TAnthropicError;
begin
  E := ParseError(nil, 503);
  AssertEquals('type from status', 'api_error', E.ErrorType);
  AssertEquals('status', 503, E.StatusCode);
  AssertTrue('retryable', E.Retryable);
  AssertTrue('message is not empty', E.Message <> '');
end;

procedure TParseErrorTests.TestNonJsonBody;
var
  E: TAnthropicError;
begin
  E := ParseError(nil, 401);
  AssertEquals('type from status', 'authentication_error', E.ErrorType);
  AssertEquals('status', 401, E.StatusCode);
  AssertFalse('not retryable', E.Retryable);
end;

procedure TParseErrorTests.TestRetryableFlag;
var
  E: TAnthropicError;
begin
  E := ParseError(nil, 429);
  AssertTrue('429 retryable', E.Retryable);
  E := ParseError(nil, 500);
  AssertTrue('500 retryable', E.Retryable);
  E := ParseError(nil, 503);
  AssertTrue('503 retryable', E.Retryable);
  E := ParseError(nil, 400);
  AssertFalse('400 not retryable', E.Retryable);
  E := ParseError(nil, 401);
  AssertFalse('401 not retryable', E.Retryable);
  E := ParseError(nil, 404);
  AssertFalse('404 not retryable', E.Retryable);
end;

{ --- TErrorJsonTests --- }

procedure TErrorJsonTests.TestBuildErrorJsonStructure;
var
  E: TAnthropicError;
  J: TJSONObject;
  JErr: TJSONData;
begin
  E.ErrorType := 'authentication_error';
  E.Message := 'invalid key';
  E.StatusCode := 401;
  E.Retryable := False;
  J := BuildErrorJson(E);
  try
    AssertEquals('type', 'error', JStr(J, 'type', ''));
    JErr := J.FindPath('error');
    AssertTrue('error object', JErr <> nil);
    AssertEquals('error.type', 'authentication_error', JStr(JErr, 'type', ''));
    AssertEquals('error.message', 'invalid key', JStr(JErr, 'message', ''));
    AssertEquals('error.status', 401, JInt(JErr, 'status', 0));
    AssertFalse('error.retryable', JBool(JErr, 'retryable', True));
  finally
    J.Free;
  end;
end;

procedure TErrorJsonTests.TestBuildErrorJsonRetryable;
var
  E: TAnthropicError;
  J: TJSONObject;
  JErr: TJSONData;
begin
  E.ErrorType := 'rate_limit_error';
  E.Message := 'too many requests';
  E.StatusCode := 429;
  E.Retryable := True;
  J := BuildErrorJson(E);
  try
    JErr := J.FindPath('error');
    AssertTrue('retryable=true', JBool(JErr, 'retryable', False));
  finally
    J.Free;
  end;
end;

procedure TErrorJsonTests.TestErrorTextWithRetryable;
var
  E: TAnthropicError;
begin
  E.ErrorType := 'rate_limit_error';
  E.Message := 'too many requests';
  E.StatusCode := 429;
  E.Retryable := True;
  AssertTrue('contains message', Pos('too many requests', AnthropicErrorText(E)) > 0);
  AssertTrue('contains status', Pos('429', AnthropicErrorText(E)) > 0);
  AssertTrue('contains type', Pos('rate_limit_error', AnthropicErrorText(E)) > 0);
  AssertTrue('contains "retryable"',
    Pos('retryable', AnthropicErrorText(E)) > 0);
end;

procedure TErrorJsonTests.TestErrorTextWithoutRetryable;
var
  E: TAnthropicError;
  T: string;
begin
  E.ErrorType := 'authentication_error';
  E.Message := 'bad key';
  E.StatusCode := 401;
  E.Retryable := False;
  T := AnthropicErrorText(E);
  AssertTrue('contains message', Pos('bad key', T) > 0);
  AssertTrue('contains status', Pos('401', T) > 0);
  AssertTrue('contains type', Pos('authentication_error', T) > 0);
  { The text must not carry the retry note. }
  AssertFalse('without the retry note',
    Pos('(retryable)', T) > 0);
end;

{ --- TResponseTextTests --- }

procedure TResponseTextTests.TestSingleTextBlock;
var
  R: TAnthropicResponse;
begin
  SetLength(R.Content, 1);
  R.Content[0].BlockType := abtText;
  R.Content[0].Text := 'Grüße!';
  AssertEquals('one block', 'Grüße!', AnthropicResponseText(R));
end;

procedure TResponseTextTests.TestMultipleTextBlocks;
var
  R: TAnthropicResponse;
begin
  SetLength(R.Content, 2);
  R.Content[0].BlockType := abtText;
  R.Content[0].Text := 'line 1';
  R.Content[1].BlockType := abtText;
  R.Content[1].Text := 'line 2';
  AssertEquals('two blocks', 'line 1' + #10 + 'line 2',
    AnthropicResponseText(R));
end;

procedure TResponseTextTests.TestIgnoresNonTextBlocks;
var
  R: TAnthropicResponse;
begin
  SetLength(R.Content, 3);
  R.Content[0].BlockType := abtThinking;
  R.Content[0].Thinking := 'thinking about it';
  R.Content[1].BlockType := abtText;
  R.Content[1].Text := 'answer';
  R.Content[2].BlockType := abtToolUse;
  R.Content[2].ToolName := 'tool';
  AssertEquals('text blocks only', 'answer', AnthropicResponseText(R));
end;

procedure TResponseTextTests.TestEmptyContent;
var
  R: TAnthropicResponse;
begin
  SetLength(R.Content, 0);
  AssertEquals('empty', '', AnthropicResponseText(R));
end;

{ --- TSSEAccumulatorTests --- }

procedure TSSEAccumulatorTests.OnDelta(const TextDelta, ToolInputDelta: string);
begin
  FDeltaText := FDeltaText + TextDelta;
  FDeltaTool := FDeltaTool + ToolInputDelta;
end;

function TSSEAccumulatorTests.SSE(const Data: string): string;
begin
  Result := 'data: ' + Data + #10#10;
end;

procedure TSSEAccumulatorTests.FeedSSE(const Lines: array of string);
var
  i: Integer;
  Chunk: string;
begin
  Chunk := '';
  for i := Low(Lines) to High(Lines) do
    Chunk := Chunk + SSE(Lines[i]);
  FAcc.FeedChunk(Chunk);
end;

procedure TSSEAccumulatorTests.SetUp;
begin
  FAcc := TAnthropicSSEAccumulator.Create;
  FDeltaText := '';
  FDeltaTool := '';
  FAcc.OnDelta := @OnDelta;
end;

procedure TSSEAccumulatorTests.TearDown;
begin
  FAcc.Free;
end;

procedure TSSEAccumulatorTests.TestMessageStart;
var
  R: TAnthropicResponse;
begin
  FAcc.FeedLine(SSE('{"type":"message_start","message":{"id":"msg_1",' +
    '"model":"claude-sonnet-4-20250514",' +
    '"usage":{"input_tokens":42}}}'));
  FAcc.Collect(R);
  AssertEquals('id', 'msg_1', R.Id);
  AssertEquals('model', 'claude-sonnet-4-20250514', R.Model);
  AssertEquals('input_tokens', 42, R.Usage.InputTokens);
end;

procedure TSSEAccumulatorTests.TestTextBlock;
var
  R: TAnthropicResponse;
begin
  FAcc.FeedLine(SSE('{"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"Grü"}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"ße!"}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_stop","index":0}'));
  FAcc.Collect(R);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertTrue('text block', R.Content[0].BlockType = abtText);
  AssertEquals('text', 'Grüße!', R.Content[0].Text);
end;

procedure TSSEAccumulatorTests.TestToolUseBlock;
var
  R: TAnthropicResponse;
begin
  FAcc.FeedLine(SSE('{"type":"content_block_start","index":0,' +
    '"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather"}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"input_json_delta","partial_json":"{' + #92 + '"city' + #92 + '":"}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"input_json_delta","partial_json":"' + #92 + '"Moscow' + #92 + '"}"}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_stop","index":0}'));
  FAcc.Collect(R);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertTrue('tool_use block', R.Content[0].BlockType = abtToolUse);
  AssertEquals('tool id', 'toolu_1', R.Content[0].ToolId);
  AssertEquals('tool name', 'get_weather', R.Content[0].ToolName);
  AssertTrue('input contains city', Pos('"city"', R.Content[0].ToolInput) > 0);
end;

procedure TSSEAccumulatorTests.TestThinkingBlock;
var
  R: TAnthropicResponse;
begin
  FAcc.FeedLine(SSE('{"type":"content_block_start","index":0,' +
    '"content_block":{"type":"thinking","thinking":""}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"thinking_delta","thinking":"Hmm..."}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_stop","index":0}'));
  FAcc.Collect(R);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertTrue('thinking block', R.Content[0].BlockType = abtThinking);
  AssertEquals('thinking', 'Hmm...', R.Content[0].Thinking);
end;

procedure TSSEAccumulatorTests.TestMessageDelta;
var
  R: TAnthropicResponse;
begin
  FAcc.FeedLine(SSE('{"type":"message_delta",' +
    '"delta":{"stop_reason":"end_turn","stop_sequence":null},' +
    '"usage":{"output_tokens":15}}'));
  FAcc.Collect(R);
  AssertEquals('stop_reason', 'end_turn', R.StopReason);
  AssertEquals('output_tokens', 15, R.Usage.OutputTokens);
end;

procedure TSSEAccumulatorTests.TestMessageStop;
begin
  FAcc.FeedLine(SSE('{"type":"message_stop"}'));
  AssertTrue('Done', FAcc.Done);
end;

procedure TSSEAccumulatorTests.TestFullStream;
var
  R: TAnthropicResponse;
  Lines: array[0..6] of string;
begin
  Lines[0] := '{"type":"message_start","message":{"id":"msg_full",' +
    '"model":"claude-sonnet-4-20250514","usage":{"input_tokens":10}}}';
  Lines[1] := '{"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}';
  Lines[2] := '{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"Grü"}}';
  Lines[3] := '{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"ße!"}}';
  Lines[4] := '{"type":"content_block_stop","index":0}';
  Lines[5] := '{"type":"message_delta","delta":{"stop_reason":"end_turn"},' +
    '"usage":{"output_tokens":5}}';
  Lines[6] := '{"type":"message_stop"}';
  FeedSSE(Lines);
  AssertTrue('Done', FAcc.Done);
  FAcc.Collect(R);
  AssertEquals('id', 'msg_full', R.Id);
  AssertEquals('model', 'claude-sonnet-4-20250514', R.Model);
  AssertEquals('stop_reason', 'end_turn', R.StopReason);
  AssertEquals('input_tokens', 10, R.Usage.InputTokens);
  AssertEquals('output_tokens', 5, R.Usage.OutputTokens);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertEquals('text', 'Grüße!', R.Content[0].Text);
end;

procedure TSSEAccumulatorTests.TestChunkedFeed;
var
  R: TAnthropicResponse;
  Chunk1, Chunk2: string;
begin
  { The SSE event is split into two chunks in the middle of a line. }
  Chunk1 := 'data: {"type":"content_block_start","index":0,"content_' +
    'block":{"type":"text","text":""}}' + #10;
  Chunk2 := #10 + 'data: {"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"hi"}}' + #10#10 +
    'data: {"type":"message_stop"}' + #10#10;
  FAcc.FeedChunk(Chunk1);
  FAcc.FeedChunk(Chunk2);
  AssertTrue('Done', FAcc.Done);
  FAcc.Collect(R);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertEquals('text', 'hi', R.Content[0].Text);
end;

procedure TSSEAccumulatorTests.TestFlush;
var
  R: TAnthropicResponse;
begin
  { The last line has no trailing line break. }
  FAcc.FeedChunk('data: {"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}' + #10#10 +
    'data: {"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"flush"}}');
  FAcc.Flush;
  FAcc.Collect(R);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertEquals('text', 'flush', R.Content[0].Text);
end;

procedure TSSEAccumulatorTests.TestReset;
var
  R: TAnthropicResponse;
begin
  FAcc.FeedLine(SSE('{"type":"message_start","message":{"id":"msg_a",' +
    '"model":"m1","usage":{"input_tokens":1}}}'));
  FAcc.FeedLine(SSE('{"type":"message_stop"}'));
  AssertTrue('Done after the first run', FAcc.Done);

  FAcc.Reset;
  AssertFalse('Done reset', FAcc.Done);

  FAcc.FeedLine(SSE('{"type":"message_start","message":{"id":"msg_b",' +
    '"model":"m2","usage":{"input_tokens":2}}}'));
  FAcc.FeedLine(SSE('{"type":"message_stop"}'));
  FAcc.Collect(R);
  AssertEquals('id after reset', 'msg_b', R.Id);
  AssertEquals('input_tokens', 2, R.Usage.InputTokens);
end;

procedure TSSEAccumulatorTests.TestDeltaCallback;
begin
  FDeltaText := '';
  FDeltaTool := '';
  FAcc.FeedLine(SSE('{"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"hello"}}'));
  AssertEquals('delta text', 'hello', FDeltaText);
  AssertEquals('delta tool is empty', '', FDeltaTool);
end;

procedure TSSEAccumulatorTests.TestCollect;
var
  R: TAnthropicResponse;
begin
  FAcc.FeedLine(SSE('{"type":"message_start","message":{"id":"msg_c",' +
    '"model":"claude-3","usage":{"input_tokens":7}}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}'));
  FAcc.FeedLine(SSE('{"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"ok"}}'));
  FAcc.FeedLine(SSE('{"type":"message_delta","delta":{"stop_reason":"end_turn"},' +
    '"usage":{"output_tokens":3}}'));
  FAcc.Collect(R);
  AssertEquals('id', 'msg_c', R.Id);
  AssertEquals('type', 'message', R.MsgType);
  AssertEquals('role', 'assistant', R.Role);
  AssertEquals('model', 'claude-3', R.Model);
  AssertEquals('stop_reason', 'end_turn', R.StopReason);
  AssertEquals('input', 7, R.Usage.InputTokens);
  AssertEquals('output', 3, R.Usage.OutputTokens);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertEquals('text', 'ok', R.Content[0].Text);
end;

{ --- TClientSSEChunkTests --- }

procedure TClientSSEChunkTests.SetUp;
begin
  FClient := TAnthropicClient.Create('test-key', '');
end;

procedure TClientSSEChunkTests.TearDown;
begin
  FClient.Free;
end;

procedure TClientSSEChunkTests.TestFeedChunk;
var
  R: TAnthropicResponse;
  Chunk: string;
begin
  Chunk := 'data: {"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}' + #10#10 +
    'data: {"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"chunk"}}' + #10#10 +
    'data: {"type":"message_stop"}' + #10#10;
  FClient.SSEChunk(Chunk);
  AssertTrue('Done', FClient.Accumulator.Done);
  FClient.Accumulator.Collect(R);
  AssertEquals('blocks', 1, Length(R.Content));
  AssertEquals('text', 'chunk', R.Content[0].Text);
end;

procedure TClientSSEChunkTests.TestFeedFullStream;
var
  R: TAnthropicResponse;
  Chunk: string;
begin
  Chunk :=
    'data: {"type":"message_start","message":{"id":"msg_client",' +
    '"model":"claude-sonnet-4-20250514","usage":{"input_tokens":5}}}' + #10#10 +
    'data: {"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}' + #10#10 +
    'data: {"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"world"}}' + #10#10 +
    'data: {"type":"content_block_stop","index":0}' + #10#10 +
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},' +
    '"usage":{"output_tokens":2}}' + #10#10 +
    'data: {"type":"message_stop"}' + #10#10;
  FClient.SSEChunk(Chunk);
  AssertTrue('Done', FClient.Accumulator.Done);
  FClient.Accumulator.Collect(R);
  AssertEquals('id', 'msg_client', R.Id);
  AssertEquals('model', 'claude-sonnet-4-20250514', R.Model);
  AssertEquals('stop_reason', 'end_turn', R.StopReason);
  AssertEquals('input', 5, R.Usage.InputTokens);
  AssertEquals('output', 2, R.Usage.OutputTokens);
  AssertEquals('text', 'world', R.Content[0].Text);
end;

procedure TClientSSEChunkTests.TestAccumulatorProperty;
begin
  AssertTrue('Accumulator is not nil', FClient.Accumulator <> nil);
  AssertFalse('Done initially', FClient.Accumulator.Done);
end;

initialization
  RegisterTest(TAnthropicValidatorTests);
  RegisterTest(TAnthropicClientValidateTests);
  RegisterTest(TBuildRequestJsonTests);
  RegisterTest(TParseResponseTests);
  RegisterTest(TParseErrorTests);
  RegisterTest(TErrorJsonTests);
  RegisterTest(TResponseTextTests);
  RegisterTest(TSSEAccumulatorTests);
  RegisterTest(TClientSSEChunkTests);

end.
