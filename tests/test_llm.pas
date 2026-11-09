unit test_llm;
{ Network-free tests: the delta accumulator (SSE) together with buffering of
  partially received JSON lines, context size estimation, and parsing and
  formatting of the model list. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.llm;

type
  TSSEAccumulatorTests = class(TTestCase)
  private
    FDeltaContent, FDeltaReasoning: string;
    procedure OnDelta(const ContentDelta, ReasoningDelta: string);
  published
    procedure TestContentAndUsage;
    { usage in a stream: with stream_options.include_usage the provider sends
      it as a separate chunk with an empty choices array (before [DONE]).
      Plus the behaviour without usage and after Reset — the counters are
      zero, not stuck. }
    procedure TestUsageOnlyChunkEmptyChoices;
    procedure TestUsageArrivesBeforeDone;
    procedure TestUsageWithoutTotalTokens;
    procedure TestUsageZeroWhenAbsent;
    procedure TestResetClearsUsage;
    procedure TestReasoningAliases;
    procedure TestToolCallsByIndex;
    procedure TestDoneStopsStream;
    procedure TestMalformedChunkSkipped;
    procedure TestNonDataLinesIgnored;
    procedure TestPartialChunksReassembled;
    procedure TestPartialChunkSplitsUTF8Char;
    procedure TestPartialChunkSplitsCRLF;
    procedure TestPartialChunkTrailingLineFlushed;
    procedure TestPartialChunkDoneAcrossChunks;
  end;

  { Regression for the defect: a JSON block cut between two network chunks
    must not get lost during parsing. The test goes through the real entry
    point TLLMClient.SSEChunk rather than the accumulator directly. }
  TLLMClientSSEChunkTests = class(TTestCase)
  private
    FClient: TLLMClient;
    FDeltaContent, FDeltaReasoning: string;
    procedure OnDelta(const ContentDelta, ReasoningDelta: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestJsonSplitAcrossTwoChunks;
    procedure TestJsonSplitAtEveryByte;
    procedure TestToolCallArgsSplitAcrossChunks;
    procedure TestDoneSplitAcrossChunks;
    procedure TestTrailingLineSplitWithoutNewline;
  end;

  TContextEstimateTests = class(TTestCase)
  published
    procedure TestCountUTF8Chars;
    procedure TestAgentContextTokens;
  end;

  TModelListTests = class(TTestCase)
  published
    procedure TestNativeModelsUrl;
    procedure TestParseModelInfoNative;
    procedure TestParseModelInfoStandard;
    procedure TestParseModelInfoIdOnly;
    procedure TestEffectiveContext;
    procedure TestFormatModelsTable;
  end;

implementation

uses
  SysUtils, Classes, fpjson, jsonparser, mirmid.types, mirmid.agent;

{ --------------------------------------------------------------- SSE }

procedure TSSEAccumulatorTests.OnDelta(const ContentDelta, ReasoningDelta: string);
begin
  FDeltaContent := FDeltaContent + ContentDelta;
  FDeltaReasoning := FDeltaReasoning + ReasoningDelta;
end;

function MakeChunk(const DeltaJson: string): string;
begin
  Result := 'data: {"choices":[{"delta":' + DeltaJson + '}]}';
end;

procedure TSSEAccumulatorTests.TestContentAndUsage;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  FDeltaContent := '';
  FDeltaReasoning := '';
  Ac := TSSEAccumulator.Create;
  try
    Ac.OnDelta := @OnDelta;
    AssertTrue('first chunk', Ac.FeedLine(MakeChunk('{"content":"Grü"}')));
    AssertTrue('second chunk', Ac.FeedLine(MakeChunk('{"content":"ße!"}')));
    AssertTrue('finish+usage chunk', Ac.FeedLine(
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}],' +
      '"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'));
    AssertFalse('[DONE] ends the stream', Ac.FeedLine('data: [DONE]'));
    Ac.Collect(Resp);
    AssertEquals('text glued together', 'Grüße!', Resp.Content);
    AssertEquals('deltas passed to the UI', 'Grüße!', FDeltaContent);
    AssertEquals('finish_reason', 'stop', Resp.FinishReason);
    AssertEquals('prompt_tokens', 10, Resp.PromptTokens);
    AssertEquals('completion_tokens', 5, Resp.CompletionTokens);
    AssertEquals('total_tokens', 15, Resp.TotalTokens);
  finally
    Ac.Free;
  end;
end;

{ with include_usage the usage arrives as a separate chunk with an empty
  choices array: no text, no finish_reason, only the counters. }
procedure TSSEAccumulatorTests.TestUsageOnlyChunkEmptyChoices;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  FDeltaContent := '';
  Ac := TSSEAccumulator.Create;
  try
    Ac.OnDelta := @OnDelta;
    AssertTrue('usage chunk', Ac.FeedLine(
      'data: {"id":"chunk_usage","object":"chat.completion.chunk",' +
      '"choices":[],"usage":{"prompt_tokens":42,"completion_tokens":0,' +
      '"total_tokens":42}}'));
    Ac.Collect(Resp);
    AssertEquals('prompt_tokens', 42, Resp.PromptTokens);
    AssertEquals('completion_tokens', 0, Resp.CompletionTokens);
    AssertEquals('total_tokens', 42, Resp.TotalTokens);
    AssertEquals('no text', '', Resp.Content);
    AssertEquals('delta not fired', '', FDeltaContent);
  finally
    Ac.Free;
  end;
end;

{ The real stream order: text, finish_reason, usage chunk, [DONE].
  usage does not drop what is already collected, and [DONE] does not lose it.
  Total may be absent — then it stays 0, which is not an error. }
procedure TSSEAccumulatorTests.TestUsageArrivesBeforeDone;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('text', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
    AssertTrue('finish_reason', Ac.FeedLine(
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'));
    AssertTrue('usage chunk', Ac.FeedLine(
      'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":3}}'));
    AssertFalse('[DONE] ends the stream', Ac.FeedLine('data: [DONE]'));
    Ac.Collect(Resp);
    AssertEquals('text kept', 'ok', Resp.Content);
    AssertEquals('finish_reason kept', 'stop', Resp.FinishReason);
    AssertEquals('prompt_tokens', 100, Resp.PromptTokens);
    AssertEquals('completion_tokens', 3, Resp.CompletionTokens);
  finally
    Ac.Free;
  end;
end;

{ The provider sent usage without total_tokens (this happens in a stream):
  prompt and completion are filled in, total stays 0 as "not reported". }
procedure TSSEAccumulatorTests.TestUsageWithoutTotalTokens;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('usage without total', Ac.FeedLine(
      'data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}'));
    Ac.Collect(Resp);
    AssertEquals('prompt_tokens', 7, Resp.PromptTokens);
    AssertEquals('completion_tokens', 2, Resp.CompletionTokens);
    AssertEquals('total_tokens not reported', 0, Resp.TotalTokens);
  finally
    Ac.Free;
  end;
end;

{ Without usage (the provider did not honour include_usage) all counters are
  zero: the agent must understand that the exact request size is unknown. }
procedure TSSEAccumulatorTests.TestUsageZeroWhenAbsent;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('text', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
    AssertTrue('finish_reason', Ac.FeedLine(
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'));
    Ac.Collect(Resp);
    AssertEquals('prompt_tokens', 0, Resp.PromptTokens);
    AssertEquals('completion_tokens', 0, Resp.CompletionTokens);
    AssertEquals('total_tokens', 0, Resp.TotalTokens);
  finally
    Ac.Free;
  end;
end;

{ The accumulator is reused (it lives in TLLMClient), so Reset must zero the
  usage of the previous stream too, otherwise the counters get stuck. }
procedure TSSEAccumulatorTests.TestResetClearsUsage;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('usage of the first stream', Ac.FeedLine(
      'data: {"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":9,' +
      '"total_tokens":59}}'));
    Ac.Reset;
    AssertTrue('second stream: text', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
    Ac.Collect(Resp);
    AssertEquals('prompt_tokens reset', 0, Resp.PromptTokens);
    AssertEquals('completion_tokens reset', 0, Resp.CompletionTokens);
    AssertEquals('total_tokens reset', 0, Resp.TotalTokens);
    AssertEquals('text of the second stream', 'ok', Resp.Content);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestReasoningAliases;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  FDeltaContent := '';
  FDeltaReasoning := '';
  Ac := TSSEAccumulator.Create;
  try
    Ac.OnDelta := @OnDelta;
    AssertTrue('reasoning_content',
      Ac.FeedLine(MakeChunk('{"reasoning_content":"thin"}')));
    AssertTrue('reasoning alias',
      Ac.FeedLine(MakeChunk('{"reasoning":"king"}')));
    Ac.Collect(Resp);
    AssertEquals('reasoning glued together', 'thinking', Resp.Reasoning);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestToolCallsByIndex;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('id and name', Ac.FeedLine(
      'data: {"choices":[{"delta":{"tool_calls":[' +
      '{"index":0,"id":"call_1","function":{"name":"shell","arguments":""}}]}}]}'));
    AssertTrue('arguments of the first part', Ac.FeedLine(
      'data: {"choices":[{"delta":{"tool_calls":[' +
      '{"index":0,"function":{"arguments":"{\"command\":\"ls\"}"}}]}}]}'));
    AssertTrue('second call (index 1)', Ac.FeedLine(
      'data: {"choices":[{"delta":{"tool_calls":[' +
      '{"index":1,"id":"call_2","function":{"name":"file_list","arguments":"{}"}}]}}]}'));
    Ac.Collect(Resp);
    AssertEquals('two calls', 2, Length(Resp.ToolCalls));
    AssertEquals('id of the first', 'call_1', Resp.ToolCalls[0].Id);
    AssertEquals('name of the first', 'shell', Resp.ToolCalls[0].Name);
    AssertEquals('arguments glued together', '{"command":"ls"}', Resp.ToolCalls[0].Arguments);
    AssertEquals('name of the second', 'file_list', Resp.ToolCalls[1].Name);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestDoneStopsStream;
var
  Ac: TSSEAccumulator;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('[DONE]', not Ac.FeedLine('data: [DONE]'));
    AssertFalse('lines after DONE are ignored',
      Ac.FeedLine(MakeChunk('{"content":"x"}')));
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestMalformedChunkSkipped;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('broken chunk is skipped', Ac.FeedLine('data: {not json'));
    AssertTrue('stream continues', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
    Ac.Collect(Resp);
    AssertEquals('text kept', 'ok', Resp.Content);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestNonDataLinesIgnored;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('empty line', Ac.FeedLine(''));
    AssertTrue('SSE comment', Ac.FeedLine(': keepalive'));
    AssertTrue('chunk after the comments', Ac.FeedLine(MakeChunk('{"content":"hi"}')));
    Ac.Collect(Resp);
    AssertEquals('text kept', 'hi', Resp.Content);
  finally
    Ac.Free;
  end;
end;

{ --- Regression: a network chunk may cut a JSON line into pieces --- }

{ Feeds the stream in pieces of exactly PartSize bytes. A False result means
  FeedChunk reported the end of the stream ([DONE]). }
function FeedInParts(Ac: TSSEAccumulator; const S: RawByteString;
  PartSize: Integer): Boolean;
var
  I, N: Integer;
begin
  Result := True;
  N := Length(S);
  I := 1;
  while I <= N do
  begin
    if not Ac.FeedChunk(Copy(S, I, PartSize)) then
      Exit(False);
    Inc(I, PartSize);
  end;
end;

procedure TSSEAccumulatorTests.TestPartialChunksReassembled;
const
  PART_SIZES: array[0..5] of Integer = (1, 2, 3, 4, 7, 0);  { 0 — whole stream }
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
  Stream: RawByteString;
  I, PartSize: Integer;
begin
  { The JSON line arrives in pieces of an arbitrary size. We check every
    cutting boundary, including "one byte at a time". }
  Stream :=
    'data: {"choices":[{"delta":{"content":"Hello, "}}]}' + #10 +
    'data: {"choices":[{"delta":{"content":"world"}}]}' + #10 +
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}' + #10;
  for I := Low(PART_SIZES) to High(PART_SIZES) do
  begin
    PartSize := PART_SIZES[I];
    if PartSize = 0 then
      PartSize := Length(Stream);
    Ac := TSSEAccumulator.Create;
    try
      AssertTrue(Format('stream parsed (pieces of %d bytes)', [PartSize]),
        FeedInParts(Ac, Stream, PartSize));
      Ac.Collect(Resp);
      AssertEquals(Format('text (pieces of %d bytes)', [PartSize]),
        'Hello, world', Resp.Content);
      AssertEquals(Format('finish_reason (pieces of %d bytes)', [PartSize]),
        'stop', Resp.FinishReason);
    finally
      Ac.Free;
    end;
  end;
end;

procedure TSSEAccumulatorTests.TestPartialChunkSplitsUTF8Char;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
  Stream: RawByteString;
begin
  { The letters of "grüße" take two bytes each, so feeding one byte at a time
    puts a chunk boundary inside a UTF-8 character. }
  Stream := MakeChunk('{"content":"Grüße, Welt!"}') + #10;
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('splitting by bytes', FeedInParts(Ac, Stream, 1));
    Ac.Collect(Resp);
    AssertEquals('UTF-8 not corrupted', 'Grüße, Welt!', Resp.Content);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestPartialChunkSplitsCRLF;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
  Stream: RawByteString;
begin
  { In SSE lines are separated by CRLF, and a chunk boundary may pass between
    #13 and #10. }
  Stream := 'data: {"choices":[{"delta":{"content":"a"}}]}' + #13#10 +
            'data: {"choices":[{"delta":{"content":"b"}}]}' + #13#10;
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('stream with CRLF', FeedInParts(Ac, Stream, 1));
    Ac.Collect(Resp);
    AssertEquals('text glued together', 'ab', Resp.Content);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestPartialChunkTrailingLineFlushed;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
  Stream: RawByteString;
begin
  { The last line of the stream may have no terminating #10: until Flush it
    stays in the buffer. }
  Stream := MakeChunk('{"content":"tail"}');
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('stream without a terminating newline',
      FeedInParts(Ac, Stream, 1));
    Ac.Collect(Resp);
    AssertEquals('line not parsed before Flush', '', Resp.Content);
    AssertTrue('Flush parses the remainder', Ac.Flush);
    Ac.Collect(Resp);
    AssertEquals('text after Flush', 'tail', Resp.Content);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestPartialChunkDoneAcrossChunks;
var
  Ac: TSSEAccumulator;
  Stream: RawByteString;
begin
  { The [DONE] marker is recognised even when it arrives in pieces. }
  Stream := 'data: {"choices":[{"delta":{"content":"x"}}]}' + #10 +
            'data: [DONE]' + #10;
  Ac := TSSEAccumulator.Create;
  try
    AssertFalse('[DONE] detected', FeedInParts(Ac, Stream, 1));
    AssertTrue('stream finished', Ac.Done);
  finally
    Ac.Free;
  end;
end;

{ --- Regression: TLLMClient.SSEChunk (the HttpRequestStream handler).
  The existing tests drive TSSEAccumulator.FeedChunk directly, so the SSEChunk
  entry point itself was not covered by them. --- }

procedure TLLMClientSSEChunkTests.SetUp;
var
  Cfg: TMirmidConfig;
begin
  FDeltaContent := '';
  FDeltaReasoning := '';
  Cfg := DefaultConfig;
  Cfg.Model := 'test-model';
  FClient := TLLMClient.Create(Cfg);
  FClient.Accumulator.OnDelta := @OnDelta;
end;

procedure TLLMClientSSEChunkTests.TearDown;
begin
  FClient.Free;
end;

procedure TLLMClientSSEChunkTests.OnDelta(const ContentDelta, ReasoningDelta: string);
begin
  FDeltaContent := FDeltaContent + ContentDelta;
  FDeltaReasoning := FDeltaReasoning + ReasoningDelta;
end;

{ The network chunk boundary passes inside the JSON object of the first delta.
  Such JSON used to be unparsed and the text was lost. }
procedure TLLMClientSSEChunkTests.TestJsonSplitAcrossTwoChunks;
var
  Resp: TLLMResponse;
begin
  AssertTrue('first fragment', FClient.SSEChunk(
    'data: {"choices":[{"delta":{"content":"Hello, "}}]}' + #10 +
    'data: {"choices":[{"delta":{"cont'));
  AssertTrue('second fragment (JSON continuation)', FClient.SSEChunk(
    'ent":"world"}}]}' + #10 +
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}' + #10));
  FClient.Accumulator.Collect(Resp);
  AssertEquals('JSON assembled from two chunks', 'Hello, world', Resp.Content);
  AssertEquals('deltas handed to the UI', 'Hello, world', FDeltaContent);
  AssertEquals('finish_reason', 'stop', Resp.FinishReason);
end;

{ The JSON is cut at every byte, including CRLF boundaries and UTF-8
  character boundaries. }
procedure TLLMClientSSEChunkTests.TestJsonSplitAtEveryByte;
var
  Stream: RawByteString;
  Resp: TLLMResponse;
  I: Integer;
  Ok: Boolean;
begin
  Stream :=
    'data: {"choices":[{"delta":{"content":"Grüße, "}}]}' + #13#10 +
    'data: {"choices":[{"delta":{"reasoning_content":"thin"}}]}' + #13#10 +
    'data: {"choices":[{"delta":{"content":"Welt!"}}]}' + #13#10 +
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}' + #13#10;
  Ok := True;
  for I := 1 to Length(Stream) do
    if not FClient.SSEChunk(Copy(Stream, I, 1)) then
      Ok := False;
  AssertTrue('stream did not end before [DONE]', Ok);
  FClient.Accumulator.Collect(Resp);
  AssertEquals('text not corrupted', 'Grüße, Welt!', Resp.Content);
  AssertEquals('reasoning not corrupted', 'thin', Resp.Reasoning);
  AssertEquals('UI received the full text', 'Grüße, Welt!', FDeltaContent);
  AssertEquals('finish_reason', 'stop', Resp.FinishReason);
end;

{ The tool_calls arguments are glued together from the deltas even when the
  JSON is cut between chunks. }
procedure TLLMClientSSEChunkTests.TestToolCallArgsSplitAcrossChunks;
var
  Stream: RawByteString;
  Resp: TLLMResponse;
  Split: Integer;
begin
  Stream :=
    'data: {"choices":[{"delta":{"tool_calls":[' +
    '{"index":0,"id":"call_1","function":{"name":"shell","arguments":""}}]}}]}' + #10 +
    'data: {"choices":[{"delta":{"tool_calls":[' +
    '{"index":0,"function":{"arguments":"{\"command\":\"ls\"}"}}]}}]}' + #10;
  { Cut inside the JSON of the second line, after the first one is complete. }
  Split := Pos(#10, Stream) + 20;
  AssertTrue('first fragment', FClient.SSEChunk(Copy(Stream, 1, Split)));
  AssertTrue('second fragment', FClient.SSEChunk(Copy(Stream, Split + 1, MaxInt)));
  FClient.Accumulator.Collect(Resp);
  AssertEquals('one call', 1, Length(Resp.ToolCalls));
  AssertEquals('id', 'call_1', Resp.ToolCalls[0].Id);
  AssertEquals('name', 'shell', Resp.ToolCalls[0].Name);
  AssertEquals('arguments assembled', '{"command":"ls"}', Resp.ToolCalls[0].Arguments);
end;

{ The [DONE] marker is recognised even when it is cut between chunks. }
procedure TLLMClientSSEChunkTests.TestDoneSplitAcrossChunks;
begin
  AssertTrue('chunk with the start of [DONE]', FClient.SSEChunk(
    'data: {"choices":[{"delta":{"content":"x"}}]}' + #10 + 'data: [DO'));
  AssertFalse('[DONE] recognised in parts', FClient.SSEChunk('NE]' + #10));
  AssertTrue('stream finished', FClient.Accumulator.Done);
end;

{ The last line of the stream without a terminating #10 is parsed only by
  Flush, and its JSON arrived cut between chunks. }
procedure TLLMClientSSEChunkTests.TestTrailingLineSplitWithoutNewline;
var
  Resp: TLLMResponse;
begin
  AssertTrue('first fragment', FClient.SSEChunk('data: {"choices":[{"delta":{"con'));
  AssertTrue('second fragment without #10', FClient.SSEChunk('tent":"tail"}}]}'));
  FClient.Accumulator.Collect(Resp);
  AssertEquals('line not parsed before Flush', '', Resp.Content);
  AssertTrue('Flush parses the remainder', FClient.Accumulator.Flush);
  FClient.Accumulator.Collect(Resp);
  AssertEquals('text after Flush', 'tail', Resp.Content);
  AssertEquals('UI received the text', 'tail', FDeltaContent);
end;

{ --------------------------------------------------------------- context }

procedure TContextEstimateTests.TestCountUTF8Chars;
begin
  AssertEquals('ASCII', 5, CountUTF8Chars('hello'));
  AssertEquals('multi-byte UTF-8', 5, CountUTF8Chars('grüße'));
  AssertEquals('mixed string', 6, CountUTF8Chars('aäöüßz'));
  AssertEquals('empty string', 0, CountUTF8Chars(''));
end;

procedure TContextEstimateTests.TestAgentContextTokens;
var
  Cfg: TMirmidConfig;
  Agent: TAgent;
  Before, After: Integer;
begin
  Cfg := DefaultConfig;
  Agent := TAgent.Create(Cfg, nil);
  try
    Before := Agent.ContextTokens;
    AssertTrue('there is a base context (system prompt)', Before > 0);
    Agent.AddUser('A short question.');
    After := Agent.ContextTokens;
    AssertTrue('context grows with the message', After > Before);
  finally
    Agent.Free;
  end;
end;

{ --------------------------------------------------------------- models }

function MakeJson(const S: string): TJSONData;
begin
  Result := GetJSON(S);
end;

procedure TModelListTests.TestNativeModelsUrl;
begin
  AssertEquals('with the /v1 suffix', 'http://127.0.0.1:1234/api/v0/models',
    NativeModelsUrl('http://127.0.0.1:1234/v1'));
  AssertEquals('with a trailing slash', 'http://127.0.0.1:1234/api/v0/models',
    NativeModelsUrl('http://127.0.0.1:1234/v1/'));
  AssertEquals('without /v1', 'http://127.0.0.1:1234/api/v0/models',
    NativeModelsUrl('http://127.0.0.1:1234'));
end;

procedure TModelListTests.TestParseModelInfoNative;
var
  M: TModelInfo;
begin
  M := ParseModelInfo(MakeJson('{"id":"qwen3-8b","type":"llm",' +
    '"max_context_length":32768,"loaded_context_length":8192,' +
    '"state":"loaded"}'));
  AssertEquals('id', 'qwen3-8b', M.Id);
  AssertEquals('type', 'llm', M.Kind);
  AssertEquals('max_context_length', 32768, M.ContextLength);
  AssertEquals('loaded_context_length', 8192, M.LoadedContextLength);
  AssertEquals('state', 'loaded', M.State);
  AssertTrue('details present', M.Details);
end;

procedure TModelListTests.TestParseModelInfoStandard;
var
  M: TModelInfo;
begin
  M := ParseModelInfo(MakeJson('{"id":"deepseek-chat","context_window":65536}'));
  AssertEquals('id', 'deepseek-chat', M.Id);
  AssertEquals('context_window', 65536, M.ContextLength);
  AssertEquals('no type', '', M.Kind);
  AssertTrue('details present', M.Details);
end;

procedure TModelListTests.TestParseModelInfoIdOnly;
var
  M: TModelInfo;
begin
  M := ParseModelInfo(MakeJson('{"id":"gpt-x"}'));
  AssertEquals('id', 'gpt-x', M.Id);
  AssertFalse('no details', M.Details);
end;

procedure TModelListTests.TestEffectiveContext;
var
  M: TModelInfo;
begin
  M.Id := 'm';
  M.ContextLength := 32768;
  M.LoadedContextLength := 8192;
  AssertEquals('minimum of the two', 8192, EffectiveContext(M));
  M.LoadedContextLength := 0;
  AssertEquals('only the maximum', 32768, EffectiveContext(M));
  M.ContextLength := 0;
  AssertEquals('nothing reported', 0, EffectiveContext(M));
end;

procedure TModelListTests.TestFormatModelsTable;
var
  Models: array of TModelInfo;
  L: TStringList;
begin
  SetLength(Models, 2);
  Models[0] := ParseModelInfo(MakeJson('{"id":"a-model","type":"llm",' +
    '"max_context_length":32768,"state":"loaded"}'));
  Models[1] := ParseModelInfo(MakeJson('{"id":"b"}'));
  L := TStringList.Create;
  try
    L.Text := FormatModelsTable(Models);
    AssertEquals('three lines', 3, L.Count);
    AssertEquals('header', 'MODEL    TYPE  CONTEXT  STATE', L[0]);
    AssertEquals('line with details', 'a-model  llm   32768    loaded', L[1]);
    AssertEquals('line without details', 'b        -     -        -', L[2]);
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TSSEAccumulatorTests);
  RegisterTest(TLLMClientSSEChunkTests);
  RegisterTest(TContextEstimateTests);
  RegisterTest(TModelListTests);

end.
