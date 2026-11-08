unit mirmid.llm;
{ Клиент OpenAI-совместимого Chat Completions API. }

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
    { Точный размер запроса в токенах из usage ответа (0 — провайдер usage не
      прислал). Для стрима приходит отдельным чанком только при
      stream_options.include_usage. }
    PromptTokens: Integer;
    CompletionTokens: Integer;
    TotalTokens: Integer;
  end;

  { Дельта стрима модели: часть текста ответа и/или размышлений. }
  TLLMDeltaHandler = procedure(const ContentDelta, ReasoningDelta: string) of object;

  { Уведомление о выполненном вызове модели (журнал процесса модели): снимок
    запроса, ответ, длительность вызова в мс и текст ошибки (пусто — вызов
    удался). При ошибке Resp может быть частичным (оборванный стрим) или
    пустым. Обработчик не влияет на ход: он только записывает данные. }
  TModelCallEvent = procedure(const Msgs: TMessages; const Resp: TLLMResponse;
    ElapsedMs: Int64; const ErrText: string) of object;

  { Аккумулятор одного потока ответа модели (SSE). Собирает content,
    reasoning_content, tool_calls (по index из дельт), finish_reason и usage. }
  TSSEAccumulator = class
  private
    FContent, FReasoning: string;
    FToolCalls: array of TToolCall;
    FFinishReason: string;
    FPromptTokens, FCompletionTokens, FTotalTokens: Integer;
    FDone: Boolean;
    FLineBuf: RawByteString;   { хвост строки, ещё не завершённый #10 }
    FOnDelta: TLLMDeltaHandler;
    procedure AccumulateDelta(const D: TJSONData);
    procedure AccumulateUsage(const D: TJSONData);
  public
    constructor Create;
    destructor Destroy; override;
    { Сбрасывает состояние и буфер для разбора нового потока. }
    procedure Reset;
    { Поток завершён (получен [DONE]). }
    property Done: Boolean read FDone;
    { Вызывается на каждой дельте с непустым content и/или reasoning. }
    property OnDelta: TLLMDeltaHandler read FOnDelta write FOnDelta;
    { Принимает произвольный фрагмент SSE-потока. Сетевой чанк может
      разрезать JSON-строку в любом месте, поэтому незавершённый хвост
      (без #10) буферизуется до следующего вызова или Flush. Возврат
      False — поток завершён ([DONE]). }
    function FeedChunk(const Chunk: RawByteString): Boolean;
    { Отправляет на разбор остаток буфера (последняя строка без #10). }
    function Flush: Boolean;
    { Разбирает одну SSE-строку (с префиксом "data:"). Возврат False —
      поток завершён ([DONE]). Повреждённые чанки пропускаются. }
    function FeedLine(const Line: string): Boolean;
    { Записывает накопленное в Resp. }
    procedure Collect(out Resp: TLLMResponse);
  end;

  { Одна запись списка моделей: id и необязательные детали, которые
    сообщает провайдер (LM Studio — нативный /api/v0/models, DeepSeek —
    поля в стандартном /models). }
  TModelInfo = record
    Id: string;
    ContextLength: Integer;       { 0 — не сообщён }
    LoadedContextLength: Integer; { 0 — не сообщён }
    Kind: string;                 { тип модели (type) }
    State: string;                { состояние загрузки }
    Details: Boolean;             { провайдер сообщил что-то сверх id }
  end;

  { Список моделей. }
  TModelList = array of TModelInfo;

  TLLMClient = class
  private
    FCfg: TMirmidConfig;
    FAcc: TSSEAccumulator;   { аккумулятор SSE-потока (живёт вместе с клиентом) }
  public
    constructor Create(const ACfg: TMirmidConfig);
    destructor Destroy; override;
    { Один запрос к модели. При успехе Result=True и заполнен Resp. }
    function Chat(const Msgs: TMessages; Registry: TToolRegistry;
      out Resp: TLLMResponse; out Err: string): Boolean;
    { Запрос в потоковом режиме (SSE): дельты передаются в OnDelta по мере
      поступления, итог — в Resp. }
    function ChatStream(const Msgs: TMessages; Registry: TToolRegistry;
      const OnDelta: TLLMDeltaHandler; out Resp: TLLMResponse; out Err: string): Boolean;
    { Список моделей: если провайдер сообщает детали (контекст, тип,
      состояние) — таблица, иначе только идентификаторы. }
    function ListModels(out Text: string; out Err: string): Boolean;
    { Список моделей как TModelList (без форматирования). }
    function FetchModelList(out Models: TModelList; out Err: string): Boolean;
    { Принять фрагмент SSE-потока (сетевой чанк) в аккумулятор. Сетевой
      чанк может разрезать JSON-строку в любом месте: незавершённый хвост
      буферизуется до следующего вызова или Flush. Возврат False — получен
      [DONE]. Это обработчик HttpRequestStream; доступен и для тестов. }
    function SSEChunk(const Chunk: RawByteString): Boolean;
    { Аккумулятор текущего потока: OnDelta, Flush, Collect. Состояние
      сбрасывается в начале ChatStream. Открыт для тестов буферизации. }
    property Accumulator: TSSEAccumulator read FAcc;
  end;

{ URL нативного списка моделей LM Studio (/api/v0/models на том же хосте). }
function NativeModelsUrl(const BaseUrl: string): string;

{ Разбирает одну запись списка моделей — нативного или стандартного. }
function ParseModelInfo(Item: TJSONData): TModelInfo;

{ Эффективный контекст: минимум из сообщённых провайдером значений.
  0 — провайдер не сообщил ни одного значения. }
function EffectiveContext(const M: TModelInfo): Integer;

{ Человекочитаемая таблица моделей с выровненными колонками. }
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
  { У разных провайдеров поле называется reasoning_content или reasoning. }
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

  { tool_calls собираются по index: id/name приходят один раз,
    arguments склеиваются из дельт. }
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

{ Принимает произвольный фрагмент SSE-потока и разбирает все завершённые
  строки. JSON-строка может прийти по частям: хвост без #10 остаётся в
  буфере до следующего вызова или Flush. }
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
      Exit(False);   { [DONE] — чтение можно останавливать }
  end;
end;

{ Отправляет на разбор остаток буфера: последняя строка потока может не
  иметь завершающего #10. Возврат False — поток завершён ([DONE]). }
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
  { Комменты и пустые события SSE не содержат данных. }
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
    Exit(True);   { повреждённый чанк пропускаем }
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
  { Буферизацией неполных строк занимается аккумулятор: сетевой чанк может
    разрезать JSON-строку в произвольном месте (см. FeedChunk). }
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
    Err := 'не задана модель (--model или model= в mirmid.ini)';
    Exit;
  end;

  O := TJSONObject.Create;
  try
    O.Add('model', FCfg.Model);
    O.Add('temperature', FCfg.Temperature);
    O.Add('max_tokens', FCfg.MaxTokens);
    O.Add('stream', True);
    { Просим прислать usage и для потока: без include_usage провайдер не
      присылает prompt_tokens, и точный размер запроса остаётся неизвестным
      (CLI показывает лишь оценку ContextTokens). Приходит отдельным чанком
      перед [DONE] — его разбирает TSSEAccumulator.AccumulateUsage. }
    SO := TJSONObject.Create;
    SO.Add('include_usage', True);
    O.Add('stream_options', SO);
    { Режим рассуждений задаётся только явно: без него провайдер использует
      своё значение по умолчанию. }
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

  { Аккумулятор живёт вместе с клиентом: сбрасываем его перед новым потоком. }
  FAcc.Reset;
  FAcc.OnDelta := OnDelta;
  Url := JoinUrl(FCfg.BaseUrl, '/chat/completions');
  if not HttpRequestStream('POST', Url, FCfg.ApiKey, Body,
    FCfg.RequestTimeout, FCfg.ConnectTimeout, @SSEChunk, Code, StatusText, Err) then
    Exit(False);
  { Таймаут в середине потока: 2xx-статус уже получен (Result=True),
    но Err заполнен — считаем запрос неудавшимся. }
  if Err <> '' then
    Exit(False);
  { Последняя строка может не иметь завершающего перевода строки. }
  FAcc.Flush;
  if not FAcc.Done then
  begin
    { Сервер закрыл соединение, не прислав [DONE]: ответ оборван. }
    Err := 'соединение с сервером разорвано до завершения ответа (не получен [DONE])';
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
    Err := 'не задана модель (--model или model= в mirmid.ini)';
    Exit;
  end;

  O := TJSONObject.Create;
  try
    O.Add('model', FCfg.Model);
    O.Add('temperature', FCfg.Temperature);
    O.Add('max_tokens', FCfg.MaxTokens);
    O.Add('stream', False);
    { Режим рассуждений задаётся только явно: без него провайдер использует
      своё значение по умолчанию. }
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
    Err := 'не удалось разобрать ответ API: ' + Err;
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      Err := 'ответ API не является JSON-объектом';
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
      Err := 'в ответе нет choices[0].message';
      Exit;
    end;
    if not (MsgD is TJSONObject) then
    begin
      Err := 'choices[0].message не является объектом';
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

{ --------------------------------------------------------------- модели }

function NativeModelsUrl(const BaseUrl: string): string;
var
  B: string;
begin
  B := Trim(BaseUrl);
  while (B <> '') and (B[Length(B)] = '/') do
    Delete(B, Length(B), 1);
  { Базовый URL в настройках оканчивается на /v1; нативный API живёт
    на том же хосте без этого суффикса. }
  if (Length(B) >= Length('/v1')) and
     (Copy(B, Length(B) - Length('/v1') + 1, Length('/v1')) = '/v1') then
    B := Copy(B, 1, Length(B) - Length('/v1'));
  Result := B + '/api/v0/models';
end;

{ Первое из путей, присутствующее и приводимое к int; 0 — ни одного. }
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
  { Имена полей у провайдеров разные: LM Studio отдаёт type /
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
  { Провайдер отдаёт теоретический максимум модели и/или контекст, с
    которым модель загружена; реально доступен меньший из них. }
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
  { Сортировка без учёта регистра. }
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

{ GET списка моделей: разбор поля data, отбрасывание записей без id. }
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
      Err := 'в ответе нет списка data';
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
  { Сначала пробуем расширенный эндпоинт провайдера (LM Studio
    /api/v0/models: контекст, тип, состояние); если его нет —
    стандартный /models. Ошибки первого запроса не фатальны. }
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
  { Расширенные поля есть только у части провайдеров: если их нет
    ни у одной модели, печатаем привычные id, а не пустую таблицу. }
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
