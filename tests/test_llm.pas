unit test_llm;
{ Тесты без сети: аккумулятор дельт (SSE) вместе с буферизацией частично
  пришедших JSON-строк, оценка размера контекста, разбор и форматирование
  списка моделей. }

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
    { usage в стриме: при stream_options.include_usage провайдер присылает
      его отдельным чанком с пустым choices (перед [DONE]). Плюс поведение
      без usage и после Reset — счётчики нулевые, а не залипшие. }
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

  { Регрессия к дефекту: JSON-блок, разрезанный между двумя сетевыми
    чанками, не должен теряться при разборе. Тест идёт через реальную точку
    входа TLLMClient.SSEChunk, а не через аккумулятор напрямую. }
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
    AssertTrue('первый чанк', Ac.FeedLine(MakeChunk('{"content":"Прив"}')));
    AssertTrue('второй чанк', Ac.FeedLine(MakeChunk('{"content":"ет!"}')));
    AssertTrue('чанк finish+usage', Ac.FeedLine(
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}],' +
      '"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'));
    AssertFalse('[DONE] завершает поток', Ac.FeedLine('data: [DONE]'));
    Ac.Collect(Resp);
    AssertEquals('текст склеен', 'Привет!', Resp.Content);
    AssertEquals('дельты переданы в UI', 'Привет!', FDeltaContent);
    AssertEquals('finish_reason', 'stop', Resp.FinishReason);
    AssertEquals('prompt_tokens', 10, Resp.PromptTokens);
    AssertEquals('completion_tokens', 5, Resp.CompletionTokens);
    AssertEquals('total_tokens', 15, Resp.TotalTokens);
  finally
    Ac.Free;
  end;
end;

{ usage при include_usage приходит отдельным чанком с пустым choices:
  ни текста, ни finish_reason в нём нет, только счётчики. }
procedure TSSEAccumulatorTests.TestUsageOnlyChunkEmptyChoices;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  FDeltaContent := '';
  Ac := TSSEAccumulator.Create;
  try
    Ac.OnDelta := @OnDelta;
    AssertTrue('чанк usage', Ac.FeedLine(
      'data: {"id":"chunk_usage","object":"chat.completion.chunk",' +
      '"choices":[],"usage":{"prompt_tokens":42,"completion_tokens":0,' +
      '"total_tokens":42}}'));
    Ac.Collect(Resp);
    AssertEquals('prompt_tokens', 42, Resp.PromptTokens);
    AssertEquals('completion_tokens', 0, Resp.CompletionTokens);
    AssertEquals('total_tokens', 42, Resp.TotalTokens);
    AssertEquals('текста нет', '', Resp.Content);
    AssertEquals('дельта не вызвана', '', FDeltaContent);
  finally
    Ac.Free;
  end;
end;

{ Реальный порядок потока: текст, finish_reason, usage-чанк, [DONE].
  usage не сбрасывает уже собранное, [DONE] его не теряет. Total при этом
  может отсутствовать — тогда остаётся 0 и это не ошибка. }
procedure TSSEAccumulatorTests.TestUsageArrivesBeforeDone;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('текст', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
    AssertTrue('finish_reason', Ac.FeedLine(
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'));
    AssertTrue('usage-чанк', Ac.FeedLine(
      'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":3}}'));
    AssertFalse('[DONE] завершает поток', Ac.FeedLine('data: [DONE]'));
    Ac.Collect(Resp);
    AssertEquals('текст сохранён', 'ok', Resp.Content);
    AssertEquals('finish_reason сохранён', 'stop', Resp.FinishReason);
    AssertEquals('prompt_tokens', 100, Resp.PromptTokens);
    AssertEquals('completion_tokens', 3, Resp.CompletionTokens);
  finally
    Ac.Free;
  end;
end;

{ Провайдер прислал usage без total_tokens (бывает в стриме): prompt и
  completion заполнены, total остаётся 0 как «не сообщён». }
procedure TSSEAccumulatorTests.TestUsageWithoutTotalTokens;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('usage без total', Ac.FeedLine(
      'data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}'));
    Ac.Collect(Resp);
    AssertEquals('prompt_tokens', 7, Resp.PromptTokens);
    AssertEquals('completion_tokens', 2, Resp.CompletionTokens);
    AssertEquals('total_tokens не сообщён', 0, Resp.TotalTokens);
  finally
    Ac.Free;
  end;
end;

{ Без usage (провайдер не поддержал include_usage) все счётчики нулевые:
  агент должен понять, что точный размер запроса неизвестен. }
procedure TSSEAccumulatorTests.TestUsageZeroWhenAbsent;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('текст', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
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

{ Аккумулятор переиспользуется (живёт в TLLMClient), поэтому Reset обязан
  обнулять и usage прежнего потока, иначе счётчики «залипнут». }
procedure TSSEAccumulatorTests.TestResetClearsUsage;
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
begin
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('usage первого потока', Ac.FeedLine(
      'data: {"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":9,' +
      '"total_tokens":59}}'));
    Ac.Reset;
    AssertTrue('второй поток: текст', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
    Ac.Collect(Resp);
    AssertEquals('prompt_tokens сброшен', 0, Resp.PromptTokens);
    AssertEquals('completion_tokens сброшен', 0, Resp.CompletionTokens);
    AssertEquals('total_tokens сброшен', 0, Resp.TotalTokens);
    AssertEquals('текст второго потока', 'ok', Resp.Content);
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
      Ac.FeedLine(MakeChunk('{"reasoning_content":"дум"}')));
    AssertTrue('алиас reasoning',
      Ac.FeedLine(MakeChunk('{"reasoning":"аюк"}')));
    Ac.Collect(Resp);
    AssertEquals('размышления склеены', 'думаюк', Resp.Reasoning);
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
    AssertTrue('id и name', Ac.FeedLine(
      'data: {"choices":[{"delta":{"tool_calls":[' +
      '{"index":0,"id":"call_1","function":{"name":"shell","arguments":""}}]}}]}'));
    AssertTrue('аргументы первой части', Ac.FeedLine(
      'data: {"choices":[{"delta":{"tool_calls":[' +
      '{"index":0,"function":{"arguments":"{\"command\":\"ls\"}"}}]}}]}'));
    AssertTrue('второй вызов (index 1)', Ac.FeedLine(
      'data: {"choices":[{"delta":{"tool_calls":[' +
      '{"index":1,"id":"call_2","function":{"name":"file_list","arguments":"{}"}}]}}]}'));
    Ac.Collect(Resp);
    AssertEquals('два вызова', 2, Length(Resp.ToolCalls));
    AssertEquals('id первого', 'call_1', Resp.ToolCalls[0].Id);
    AssertEquals('имя первого', 'shell', Resp.ToolCalls[0].Name);
    AssertEquals('аргументы склеены', '{"command":"ls"}', Resp.ToolCalls[0].Arguments);
    AssertEquals('имя второго', 'file_list', Resp.ToolCalls[1].Name);
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
    AssertFalse('после DONE строки игнорируются',
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
    AssertTrue('битый чанк пропускается', Ac.FeedLine('data: {не json'));
    AssertTrue('поток продолжается', Ac.FeedLine(MakeChunk('{"content":"ok"}')));
    Ac.Collect(Resp);
    AssertEquals('текст сохранён', 'ok', Resp.Content);
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
    AssertTrue('пустая строка', Ac.FeedLine(''));
    AssertTrue('комментарий SSE', Ac.FeedLine(': keepalive'));
    AssertTrue('чанк после комментариев', Ac.FeedLine(MakeChunk('{"content":"hi"}')));
    Ac.Collect(Resp);
    AssertEquals('текст сохранён', 'hi', Resp.Content);
  finally
    Ac.Free;
  end;
end;

{ --- Регрессия: сетевой чанк может разрезать JSON-строку на части --- }

{ Кормит поток кусками ровно по PartSize байт. Возврат False — FeedChunk
  сообщил о завершении потока ([DONE]). }
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
  PART_SIZES: array[0..5] of Integer = (1, 2, 3, 4, 7, 0);  { 0 — весь поток }
var
  Ac: TSSEAccumulator;
  Resp: TLLMResponse;
  Stream: RawByteString;
  I, PartSize: Integer;
begin
  { JSON-строка приходит кусками произвольного размера. Проверяем нарезку
    на всех границах, включая «по одному байту». }
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
      AssertTrue(Format('поток разобран (куски по %d байт)', [PartSize]),
        FeedInParts(Ac, Stream, PartSize));
      Ac.Collect(Resp);
      AssertEquals(Format('текст (куски по %d байт)', [PartSize]),
        'Hello, world', Resp.Content);
      AssertEquals(Format('finish_reason (куски по %d байт)', [PartSize]),
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
  { Буквы кириллицы занимают по два байта: при подаче по одному байту
    граница чанка попадает внутрь символа UTF-8. }
  Stream := MakeChunk('{"content":"Привет, мир!"}') + #10;
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('разрезание по байтам', FeedInParts(Ac, Stream, 1));
    Ac.Collect(Resp);
    AssertEquals('UTF-8 не повреждён', 'Привет, мир!', Resp.Content);
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
  { В SSE строки разделяются CRLF, при этом граница чанка может пройти
    между #13 и #10. }
  Stream := 'data: {"choices":[{"delta":{"content":"a"}}]}' + #13#10 +
            'data: {"choices":[{"delta":{"content":"b"}}]}' + #13#10;
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('поток с CRLF', FeedInParts(Ac, Stream, 1));
    Ac.Collect(Resp);
    AssertEquals('текст склеен', 'ab', Resp.Content);
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
  { Последняя строка потока может не иметь завершающего #10: до Flush она
    остаётся в буфере. }
  Stream := MakeChunk('{"content":"tail"}');
  Ac := TSSEAccumulator.Create;
  try
    AssertTrue('поток без завершающего перевода строки',
      FeedInParts(Ac, Stream, 1));
    Ac.Collect(Resp);
    AssertEquals('до Flush строка не разобрана', '', Resp.Content);
    AssertTrue('Flush разбирает остаток', Ac.Flush);
    Ac.Collect(Resp);
    AssertEquals('текст после Flush', 'tail', Resp.Content);
  finally
    Ac.Free;
  end;
end;

procedure TSSEAccumulatorTests.TestPartialChunkDoneAcrossChunks;
var
  Ac: TSSEAccumulator;
  Stream: RawByteString;
begin
  { Маркер [DONE] распознаётся, даже если приходит по кускам. }
  Stream := 'data: {"choices":[{"delta":{"content":"x"}}]}' + #10 +
            'data: [DONE]' + #10;
  Ac := TSSEAccumulator.Create;
  try
    AssertFalse('[DONE] обнаружен', FeedInParts(Ac, Stream, 1));
    AssertTrue('поток завершён', Ac.Done);
  finally
    Ac.Free;
  end;
end;

{ --- Регрессия: TLLMClient.SSEChunk (обработчик HttpRequestStream).
  Существующие тесты дёргают TSSEAccumulator.FeedChunk напрямую, поэтому
  сама точка входа SSEChunk ими не покрывалась. --- }

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

{ Граница сетевого чанка проходит внутри JSON-объекта первой дельты. Раньше
  такой JSON не разбирался, и текст терялся. }
procedure TLLMClientSSEChunkTests.TestJsonSplitAcrossTwoChunks;
var
  Resp: TLLMResponse;
begin
  AssertTrue('первый фрагмент', FClient.SSEChunk(
    'data: {"choices":[{"delta":{"content":"Hello, "}}]}' + #10 +
    'data: {"choices":[{"delta":{"cont'));
  AssertTrue('второй фрагмент (продолжение JSON)', FClient.SSEChunk(
    'ent":"world"}}]}' + #10 +
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}' + #10));
  FClient.Accumulator.Collect(Resp);
  AssertEquals('JSON собран из двух чанков', 'Hello, world', Resp.Content);
  AssertEquals('дельты отданы в UI', 'Hello, world', FDeltaContent);
  AssertEquals('finish_reason', 'stop', Resp.FinishReason);
end;

{ JSON разрезается на каждом байте, включая границы CRLF и символов UTF-8. }
procedure TLLMClientSSEChunkTests.TestJsonSplitAtEveryByte;
var
  Stream: RawByteString;
  Resp: TLLMResponse;
  I: Integer;
  Ok: Boolean;
begin
  Stream :=
    'data: {"choices":[{"delta":{"content":"Привет, "}}]}' + #13#10 +
    'data: {"choices":[{"delta":{"reasoning_content":"дум"}}]}' + #13#10 +
    'data: {"choices":[{"delta":{"content":"мир!"}}]}' + #13#10 +
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}' + #13#10;
  Ok := True;
  for I := 1 to Length(Stream) do
    if not FClient.SSEChunk(Copy(Stream, I, 1)) then
      Ok := False;
  AssertTrue('поток не завершился раньше [DONE]', Ok);
  FClient.Accumulator.Collect(Resp);
  AssertEquals('текст не повреждён', 'Привет, мир!', Resp.Content);
  AssertEquals('размышления не повреждены', 'дум', Resp.Reasoning);
  AssertEquals('UI получил полный текст', 'Привет, мир!', FDeltaContent);
  AssertEquals('finish_reason', 'stop', Resp.FinishReason);
end;

{ Аргументы tool_calls склеиваются из дельт, даже если JSON разрезан между
  чанками. }
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
  { Разрезаем внутри JSON второй строки, уже после завершённой первой. }
  Split := Pos(#10, Stream) + 20;
  AssertTrue('первый фрагмент', FClient.SSEChunk(Copy(Stream, 1, Split)));
  AssertTrue('второй фрагмент', FClient.SSEChunk(Copy(Stream, Split + 1, MaxInt)));
  FClient.Accumulator.Collect(Resp);
  AssertEquals('один вызов', 1, Length(Resp.ToolCalls));
  AssertEquals('id', 'call_1', Resp.ToolCalls[0].Id);
  AssertEquals('имя', 'shell', Resp.ToolCalls[0].Name);
  AssertEquals('аргументы собраны', '{"command":"ls"}', Resp.ToolCalls[0].Arguments);
end;

{ Маркер [DONE] распознаётся, даже если разрезан между чанками. }
procedure TLLMClientSSEChunkTests.TestDoneSplitAcrossChunks;
begin
  AssertTrue('чанк с началом [DONE]', FClient.SSEChunk(
    'data: {"choices":[{"delta":{"content":"x"}}]}' + #10 + 'data: [DO'));
  AssertFalse('[DONE] распознан по частям', FClient.SSEChunk('NE]' + #10));
  AssertTrue('поток завершён', FClient.Accumulator.Done);
end;

{ Последняя строка потока без завершающего #10 разбирается только Flush; при
  этом её JSON пришёл разрезанным между чанками. }
procedure TLLMClientSSEChunkTests.TestTrailingLineSplitWithoutNewline;
var
  Resp: TLLMResponse;
begin
  AssertTrue('первый фрагмент', FClient.SSEChunk('data: {"choices":[{"delta":{"con'));
  AssertTrue('второй фрагмент без #10', FClient.SSEChunk('tent":"tail"}}]}'));
  FClient.Accumulator.Collect(Resp);
  AssertEquals('до Flush строка не разобрана', '', Resp.Content);
  AssertTrue('Flush разбирает остаток', FClient.Accumulator.Flush);
  FClient.Accumulator.Collect(Resp);
  AssertEquals('текст после Flush', 'tail', Resp.Content);
  AssertEquals('UI получил текст', 'tail', FDeltaContent);
end;

{ --------------------------------------------------------------- контекст }

procedure TContextEstimateTests.TestCountUTF8Chars;
begin
  AssertEquals('ASCII', 5, CountUTF8Chars('hello'));
  AssertEquals('кириллица UTF-8', 3, CountUTF8Chars('кот'));
  AssertEquals('смешанная строка', 6, CountUTF8Chars('aбвгдe'));
  AssertEquals('пустая строка', 0, CountUTF8Chars(''));
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
    AssertTrue('есть базовый контекст (системная подсказка)', Before > 0);
    Agent.AddUser('Небольшой вопрос.');
    After := Agent.ContextTokens;
    AssertTrue('контекст растёт с сообщением', After > Before);
  finally
    Agent.Free;
  end;
end;

{ --------------------------------------------------------------- модели }

function MakeJson(const S: string): TJSONData;
begin
  Result := GetJSON(S);
end;

procedure TModelListTests.TestNativeModelsUrl;
begin
  AssertEquals('с суффиксом /v1', 'http://127.0.0.1:1234/api/v0/models',
    NativeModelsUrl('http://127.0.0.1:1234/v1'));
  AssertEquals('с хвостовым слэшем', 'http://127.0.0.1:1234/api/v0/models',
    NativeModelsUrl('http://127.0.0.1:1234/v1/'));
  AssertEquals('без /v1', 'http://127.0.0.1:1234/api/v0/models',
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
  AssertEquals('тип', 'llm', M.Kind);
  AssertEquals('max_context_length', 32768, M.ContextLength);
  AssertEquals('loaded_context_length', 8192, M.LoadedContextLength);
  AssertEquals('state', 'loaded', M.State);
  AssertTrue('есть детали', M.Details);
end;

procedure TModelListTests.TestParseModelInfoStandard;
var
  M: TModelInfo;
begin
  M := ParseModelInfo(MakeJson('{"id":"deepseek-chat","context_window":65536}'));
  AssertEquals('id', 'deepseek-chat', M.Id);
  AssertEquals('context_window', 65536, M.ContextLength);
  AssertEquals('типа нет', '', M.Kind);
  AssertTrue('есть детали', M.Details);
end;

procedure TModelListTests.TestParseModelInfoIdOnly;
var
  M: TModelInfo;
begin
  M := ParseModelInfo(MakeJson('{"id":"gpt-x"}'));
  AssertEquals('id', 'gpt-x', M.Id);
  AssertFalse('деталей нет', M.Details);
end;

procedure TModelListTests.TestEffectiveContext;
var
  M: TModelInfo;
begin
  M.Id := 'm';
  M.ContextLength := 32768;
  M.LoadedContextLength := 8192;
  AssertEquals('минимум из двух', 8192, EffectiveContext(M));
  M.LoadedContextLength := 0;
  AssertEquals('только максимум', 32768, EffectiveContext(M));
  M.ContextLength := 0;
  AssertEquals('ничего не сообщено', 0, EffectiveContext(M));
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
    AssertEquals('три строки', 3, L.Count);
    AssertEquals('заголовок', 'MODEL    TYPE  CONTEXT  STATE', L[0]);
    AssertEquals('строка с деталями', 'a-model  llm   32768    loaded', L[1]);
    AssertEquals('строка без деталей', 'b        -     -        -', L[2]);
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
