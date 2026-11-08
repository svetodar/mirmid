unit mirmid.agent;
{ Цикл агента: запрос к модели, выполнение инструментов, повтор до финального
  текстового ответа или исчерпания лимита шагов. }

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
    FOnSubAgentEvent: TAgentEvent; { события субагентов (и их вложенных) }
    FOnModelCall: TModelCallEvent; { уведомление о каждом вызове модели
                                     (журнал процесса модели) }
    FSubAgentDepth: Integer;   { 0 — корневая сессия, >0 — субагент }
    FSessionBase: string;
    FLoopGuard: TLoopGuard; { детектор повторяющихся вызовов инструментов }
    { Поправка оценки контекста: последний usage.prompt_tokens минус оценка
      ContextTokens того же запроса. Провайдер (в стриме — благодаря
      stream_options.include_usage) сообщает точный размер запроса, поэтому
      оценка сдвигается на фактическую разницу; 0 — usage ещё не приходил. }
    FContextFix: Integer;
    function BuildContext: TToolContext;
    procedure Fire(Kind: TAgentEventKind; const Text: string);
    { Уведомляет обработчик OnModelCall о вызове модели, начатом в StartMs;
      без обработчика — ничего не делает. }
    procedure NotifyModelCall(const Resp: TLLMResponse; StartMs: QWord;
      const ErrText: string);
    procedure Append(const M: TMessage);
    procedure LLMDelta(const ContentDelta, ReasoningDelta: string);
    { Сообщает CLI новый размер контекста (aeContext) — базу строки статуса.
      Считается по истории после добавления ответа модели и результатов
      инструментов, поэтому база не отстаёт от реального контекста (в том
      числе когда ответ был последним в ходе). Без обработчика не считает:
      ContextTokens перебирает все сообщения и сериализует схемы. }
    procedure EmitContext;
  public
    constructor Create(const ACfg: TMirmidConfig; ARegistry: TToolRegistry);
    { Очищает диалог и добавляет системное сообщение. }
    procedure Reset;
    procedure AddUser(const Text: string);
    { Один ход пользователя: при необходимости выполняет инструменты. }
    function RunTurn(out FinalText: string; out Err: string): Boolean;
    property Messages: TMessages read FMsgs write FMsgs;
    { Текущая конфигурация агента. Запись позволяет менять модель, системную
      подсказку и режим рассуждений прямо во время сессии (REPL). }
    property Config: TMirmidConfig read FCfg write FCfg;
    { Глубина вложенности субагентов: 0 — корневая сессия, >0 — субагент.
      Задаётся перед запуском субагента инструментом subagent. }
    property SubAgentDepth: Integer read FSubAgentDepth write FSubAgentDepth;
    { База имён файлов вспомогательных сессий (субагенты, шаги плана);
      пусто — они не сохраняются. }
    property SessionBase: string read FSessionBase write FSessionBase;
    property OnEvent: TAgentEvent read FOnEvent write FOnEvent;
    property OnSubAgentEvent: TAgentEvent read FOnSubAgentEvent write FOnSubAgentEvent;
    { Уведомление о каждом вызове модели (запрос → ответ, длительность,
      ошибка). Используется журналом процесса модели и тестами; на ход не
      влияет. }
    property OnModelCall: TModelCallEvent read FOnModelCall write FOnModelCall;
    { Оценка текущего размера контекста (токены) по истории сообщений и
      схемам инструментов: вес текста (ASCII — 4 байта на токен, кириллица —
      2 символа на токен, CJK/эмодзи — символ на токен) плюс обёртки
      сообщений, вызовов инструментов и схем. }
    function ContextTokens: Integer;
  end;

const
  { Обёртка одного сообщения в Chat Completions (<|im_start|>role, ключи
    JSON, служебные переводы строк) сверх самого текста. }
  TokensPerMessage = 4;
  { Служебная часть результата инструмента (роль tool, tool_call_id, name). }
  TokensPerToolResult = 4;
  { JSON-обёртка вызова инструмента (id, type, function, ключи, кавычки)
    сверх имени и аргументов. }
  TokensPerToolCall = 12;
  { Обёртка схемы инструмента в запросе (type/function) сверх её JSON. }
  TokensPerToolSchema = 5;

{ Число Unicode-символов в UTF-8-строке. }
function CountUTF8Chars(const S: string): Integer;

{ Вес текста в четвертях токена: ASCII — 1 (4 байта на токен),
  двухбайтовый UTF-8 (кириллица, греческий) — 2 (2 символа на токен),
  трёх- и четырёхбайтовый (CJK, эмодзи) — 4 (символ на токен). }
function TextQuarterTokens(const S: string): Int64;

{ Оценка токенов одного сообщения вместе с обёрткой: роль, содержимое,
  reasoning, имя/id инструмента, аргументы и id вызовов инструментов плюс
  TokensPerMessage (для результата инструмента — ещё TokensPerToolResult). }
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
  FContextFix := 0; { новая сессия — прежний usage к ней не относится }
  if FCfg.SystemPrompt <> '' then
  begin
    SP := FCfg.SystemPrompt;
    { Добавляем сведения об окружении: ОС, дата, время. }
    if EnvironmentInfo <> '' then
      SP := SP + #10#10 + EnvironmentInfo;
    { Инструкции проекта из AGENTS.md — только для основной (корневой)
      сессии: субагенты работают со своей системной подсказкой. }
    if FSubAgentDepth = 0 then
    begin
      AgentsMd := ReadAgentsMd(FCfg.WorkDir);
      if AgentsMd <> '' then
        SP := SP + #10#10 + 'Инструкции проекта (AGENTS.md):' + #10 + AgentsMd;
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
  { Оценка истории плюс поправка по фактическому usage.prompt_tokens. }
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

{ Уведомление о вызове модели: снимок запроса (FMsgs на момент вызова) и
  ответ. Обработчик пишет журнал процесса модели; StartMs — момент начала
  вызова (TicksMs), длительность считается здесь. }
procedure TAgent.NotifyModelCall(const Resp: TLLMResponse; StartMs: QWord;
  const ErrText: string);
begin
  if not Assigned(FOnModelCall) then
    Exit;
  FOnModelCall(FMsgs, Resp, Int64(TicksMs - StartMs), ErrText);
end;

{ Дельта стрима модели → события для UI. }
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
    if (Byte(S[I]) and $C0) <> $80 then   { начало символа, не продолжение }
      Inc(Result);
end;

{ Вес текста в четвертях токена. Оценка «4 байта на токен» верна для ASCII,
  а кириллица в UTF-8 занимает два байта на символ и у BPE-токенизаторов
  укладывается примерно в 2 символа на токен — поэтому вес считается по
  длине ведущего байта, а не по числу символов. Веса: ASCII — 1, двухбайтовый
  UTF-8 (кириллица, греческий, латиница с диакритикой) — 2, трёх- и
  четырёхбайтовый (CJK, эмодзи) — 4 (символ на токен). }
function TextQuarterTokens(const S: string): Int64;
var
  I, N, W: Integer;
  B: Byte;
begin
  Result := 0;
  N := Length(S);  { Length строки — байты UTF-8 }
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
      Inc(Result, 4);  { CJK и эмодзи — примерно символ на токен }
    { Обрезанный многобайтовый хвост не должен съедать соседние символы. }
    if I + W > N + 1 then
      Break;
    Inc(I, W);
  end;
end;

{ Оценка токенов одного сообщения: вес роли, текста, reasoning, имени/id
  инструмента и вызовов инструментов плюс обёртка сообщения. }
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

{ Оценка текущего размера контекста (токены): история сообщений плюс схемы
  инструментов. Текст взвешивается TextQuarterTokens, к каждому сообщению
  добавляется обёртка Chat Completions, к каждому вызову/схеме инструмента —
  обёртка JSON. }
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

{ Текст команды из JSON-аргументов shell-инструмента (пусто, если не разобрать). }
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
  { Реестр доступен инструментам: subagent переиспользует его, чтобы не
    запускать одни и те же MCP-серверы повторно. }
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
  StartMs: QWord; { момент начала вызова модели (для elapsed_ms журнала) }
begin
  FinalText := '';
  Err := '';
  Result := False;
  FLoopGuard.Reset; { новый ход — сброс счётчиков повторов }
  Ctx := BuildContext;
  LLM := TLLMClient.Create(FCfg);
  try
    Step := 0;
    { MaxSteps = 0 — без ограничений. }
    while (FCfg.MaxSteps <= 0) or (Step < FCfg.MaxSteps) do
    begin
      Inc(Step);
      if FCfg.MaxSteps > 0 then
        Fire(aeStep, Format('шаг %d/%d', [Step, FCfg.MaxSteps]))
      else
        Fire(aeStep, Format('шаг %d', [Step]));

      { Размер запрашиваемого контекста — база строки статуса CLI: к ней
        прибавляются токены ответа по мере стрима. У субагента это его
        собственная история и системная подсказка (событие приходит в общий
        обработчик родителя). Базой первого шага служит история на входе в
        ход; в следующих итерациях её уже обновили после ответа и добавления
        результатов инструментов, поэтому повторный пересчёт истории (со
        схемами инструментов) был бы лишним. }
      if Step = 1 then
        EmitContext;

      { Вызов модели: засекаем начало, чтобы журнал (OnModelCall) получил
        длительность — одинаково для стрима и обычного запроса. }
      StartMs := TicksMs;
      if FCfg.Stream then
      begin
        { Потоковый вывод: дельты текста и размышлений уходят в UI по мере
          поступления, итог — в Resp. }
        Fire(aeStreamStart, '');
        if not LLM.ChatStream(FMsgs, FRegistry, @LLMDelta, Resp, Err) then
        begin
          { Стрим закрываем до ошибки: UI должен получить пару start/end. }
          Fire(aeStreamEnd, '');
          { Неудачный вызов тоже попадает в журнал: причина отказа —
            в поле error записи. }
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

      { Фактический размер запроса (usage.prompt_tokens) относится к истории
        ДО добавления ответа, поэтому поправка оценки снимается здесь, пока
        ответ ещё не в FMsgs. Дальше EmitContext прибавляет её к оценке — и
        строка статуса показывает не только примерный, но и сверенный с
        провайдером размер контекста. }
      if Resp.PromptTokens > 0 then
        FContextFix := Resp.PromptTokens - ContextTokens;

      { Стрим с stream_options.include_usage отдаёт usage отдельным чанком;
        у некоторых провайдеров при этом нет total_tokens, поэтому событие
        показываем при любом непустом поле. }
      if (Resp.PromptTokens > 0) or (Resp.CompletionTokens > 0) or
        (Resp.TotalTokens > 0) then
        Fire(aeUsage, Format('токены: prompt=%d, completion=%d, total=%d',
          [Resp.PromptTokens, Resp.CompletionTokens, Resp.TotalTokens]));

      AM := MakeMessage(mrAssistant, Resp.Content);
      AM.Reasoning := Resp.Reasoning;
      AM.ToolCalls := Resp.ToolCalls;
      Append(AM);

      { Ответ уже в истории: база сразу пересчитывается по ней, чтобы строка
        статуса не зависела от грубой оценки по дельтам стрима и включала
        ответ даже тогда, когда он последний в ходе (следующего aeContext
        перед новым запросом не будет). }
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
          { Для shell показываем только текст команды, без JSON. }
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

        { Loop-guard: проверка повторяющихся вызовов инструментов. }
        LoopAction := FLoopGuard.Feed(Resp.ToolCalls[I].Name,
          Resp.ToolCalls[I].Arguments, TM.Content, LoopText);
        if LoopAction = laWarn then
        begin
          { Синтетическое user-сообщение: модель должна сменить подход. }
          Append(MakeMessage(mrUser, LoopText));
          Fire(aeLoopWarning, LoopText);
        end;

        Fire(aeToolResult, TM.Content);

        if LoopAction = laStop then
        begin
          { Цикл: останавливаем ход с ошибкой. }
          Err := LoopText;
          Fire(aeError, LoopText);
          Exit(False);
        end;
      end;

      { Результаты инструментов (и, возможно, синтетическое сообщение
        loop-guard) добавлены в историю: следующий запрос идёт уже с ними,
        поэтому база строки статуса пересчитывается — иначе счётчики шага
        отставали бы на весь объём вывода инструментов. }
      EmitContext;
    end;
    Err := Format('достигнут предел шагов (%d): модель не завершила ответ', [FCfg.MaxSteps]);
    Fire(aeError, Err);
    Result := False;
  finally
    LLM.Free;
  end;
end;

end.
