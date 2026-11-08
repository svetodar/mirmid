unit mirmid.planner;
{ Планировщик режима планирования: четыре фазы (анализ → план → шаги →
  отчёт), подциклы шагов и инструмент пересмотра плана revise_plan.
  План живёт в родительской сессии; сессии шагов сохраняются в файлы
  <база>_step_<id>.json, сессия предварительного анализа — в
  <база>_analysis.json (по аналогии с основной сессией). }

{$mode objfpc}{$H+}

interface

uses
  fpjson, mirmid.types, mirmid.plan, mirmid.tools, mirmid.agent, mirmid.llm;

const
  REVISE_PLAN_TOOL_NAME = 'revise_plan';
  { Длина результата шага в плане (символы). }
  PLAN_STEP_RESULT_MAX = 500;

type
  { План изменился — сохранить сессию. }
  TPlanChangedEvent = procedure of object;

  TPlanner = class
  private
    FCfg: TMirmidConfig;
    FRegistry: TToolRegistry;   { реестр родительской сессии, не владеем }
    FPlan: TPlan;
    FOnEvent: TAgentEvent;
    FOnPlanChanged: TPlanChangedEvent;
    FSubAgentDepth: Integer;
    FSessionBase: string;
    FLogDir: string;             { каталог логов процесса модели:
                                    <WorkDir>/.mirmid/logs }
    FLogPhase: string;           { метка текущей фазы для журнала:
                                    analysis, plan, report, step sN }
    FInteractive: Boolean;       { интерактивный режим: после фазы плана ход
                                    завершается, шаги — по указанию пользователя }
    FPlanTask: string;           { задача, по которой построен текущий план
                                    (для возобновления шагов и отчёта) }
    FAnalyzing: Boolean;         { идёт предварительный анализ: revise_plan
                                    недоступен, чтобы не менять план }
    procedure Fire(Kind: TAgentEventKind; const Text: string);
    { Дописывает в журнал процесса модели пару «запрос → ответ» текущей
      фазы (время, фаза, запрос, ответ, usage; при ошибке вызова — её текст).
      Сбой записи не прерывает фазу: журнал — вспомогательный артефакт,
      ошибка уходит событием aeError. Пустой FLogDir — журнал отключён. }
    procedure LogModelCall(const Phase: string; const Msgs: TMessages;
      const Resp: TLLMResponse; ElapsedMs: Int64; const ErrText: string);
    { Обработчик OnModelCall агента фазы: пишет вызов модели в журнал с
      меткой текущей фазы (FLogPhase). Подключается к агенту анализа и
      агентам шагов плана. }
    procedure AgentModelCall(const Msgs: TMessages; const Resp: TLLMResponse;
      ElapsedMs: Int64; const ErrText: string);
    { Прямой вызов модели фазы (план, отчёт) через TLLMClient.Chat с записью
      пары «запрос → ответ» в журнал процесса модели. Метка фазы — Phase
      (plan, report); неудачный вызов тоже попадает в журнал (поле error).
      Результат и Err — как у Chat. }
    function ChatLogged(LLM: TLLMClient; const Phase: string;
      const Msgs: TMessages; out Resp: TLLMResponse; out Err: string): Boolean;
    { Сохраняет сессию фазы анализа в файл <SessionBase>_analysis.json (по
      аналогии с сессией шага); при пустом SessionBase — не сохраняет. }
    procedure SaveAnalysisSession(const Msgs: TMessages);
    { Фаза 0 — предварительный анализ: отдельный агент только для чтения
      изучает задачу и возвращает структурированный анализ. }
    function AnalysisPhase(const History: TMessages; out Analysis: string;
      out Err: string): Boolean;
    function PlanPhase(const Task: string; const History: TMessages;
      const Analysis: string; out Err: string): Boolean;
    { Один шаг плана. FixHint — причина неудачи предыдущей попытки (пусто —
      первая попытка): попадает в подсказку шага (StepPrompt), чтобы модель
      исправила ситуацию. TryNum/MaxTries — номер попытки (с 1) и предел
      попыток (1 + Cfg.PlanStepFixAttempts): попадают в метку записи журнала
      процесса модели, чтобы попытки шага различались по номеру. Решение о
      повторе принимает RunPlannedTurn. }
    function RunStep(const Step: TPlanStep; const Task, FixHint: string;
      TryNum, MaxTries: Integer; out Err: string): Boolean;
    { Решение по шагу, не исправленному за все попытки: спросить модель,
      менять ли план или прекращать работу. Ответ модели — JSON-объект с
      полями decision/ops/reason: decision = revise — пересмотр плана
      (operations применяются тем же обработчиком, что и инструмент
      revise_plan — HandleRevisePlan: валидация, событие aePlan и сохранение
      сессии там же), decision = stop или невнятный ответ означают остановку
      хода. Возвращает True, если план изменён и работу можно продолжать;
      False — ход надо остановить, StopReason — причина для aeError. }
    function ReviseAfterStepFailure(const Step: TPlanStep;
      const Task, Reason: string; out StopReason: string): Boolean;
    function ReportPhase(const Task: string; out Report: string; out Err: string): Boolean;
  public
    constructor Create(const ACfg: TMirmidConfig; ARegistry: TToolRegistry);
    destructor Destroy; override;
    { Текущий план (nil, пока фаза плана не завершена). Запись плана
      передаёт владение планировщику (загрузка сессии, тесты). }
    property Plan: TPlan read FPlan write FPlan;
    property OnEvent: TAgentEvent read FOnEvent write FOnEvent;
    property OnPlanChanged: TPlanChangedEvent read FOnPlanChanged write FOnPlanChanged;
    property SubAgentDepth: Integer read FSubAgentDepth write FSubAgentDepth;
    { База имён файлов сессий шагов плана (id основной сессии);
      пусто — сессии шагов не сохраняются. }
    property SessionBase: string read FSessionBase write FSessionBase;
    { Каталог логов процесса модели (<WorkDir>/.mirmid/logs): сюда фазы
      планировщика пишут журнал запросов/ответов. Заполняется в конструкторе
      по WorkDir конфига; пусто — логи не пишутся. }
    property LogDir: string read FLogDir write FLogDir;
    { Интерактивный режим: после построения плана RunPlannedTurn не переходит
      к шагам и отчёту, а завершает ход — продолжение выполняет пользователь
      следующим указанием (при этом неполный план возобновляется с текущего
      pending-шага). }
    property Interactive: Boolean read FInteractive write FInteractive;
    { Один ход в режиме планирования: план → шаги → отчёт.
      History — история основной сессии, включая текущую задачу как
      последнее user-сообщение. }
    function RunPlannedTurn(const Task: string; const History: TMessages;
      out FinalText: string; out Err: string): Boolean;
    { Обработчик инструмента revise_plan. Публичный, чтобы его можно было
      привязать к реестру как метод (RegisterRevisePlanTool). }
    function HandleRevisePlan(const Args: TJSONObject; const Ctx: TToolContext): TToolOutcome;
    { Сохраняет сессию попытки шага (по аналогии с основной сессией) в файл
      <SessionBase>_step_<Step.Id>.json, а для повторных попыток —
      <SessionBase>_step_<Step.Id>_try<N>.json (N — номер попытки с 1), чтобы
      попытки не затирали друг друга; при пустом SessionBase — не сохраняет. }
    procedure SaveStepSession(const Step: TPlanStep; const Msgs: TMessages;
      TryNum: Integer);
  end;

{ Регистрирует инструмент пересмотра плана в реестре (привязан к
  текущему плану планировщика). }
procedure RegisterRevisePlanTool(R: TToolRegistry; P: TPlanner);

{ Конфиг агента фазы анализа: копия конфига родительской сессии с системной
  подсказкой аналитика (PLANNER_ANALYSIS_PROMPT). Политики доступа
  (AllowWrite/AllowShell/AllowHttp) и прочие настройки наследуются
  как есть: анализ работает с теми же правами, что и остальные фазы —
  иначе явно включённые пользователем флаги (`--allow-shell` и др.) молча
  игнорировались, а инструмент отвечал «запустите с --allow-shell».
  Требование «только на чтение» задаёт сама подсказка аналитика. }
function AnalysisConfig(const Parent: TMirmidConfig): TMirmidConfig;
{ Текст события aeStepEnd: «s1: done — результат» (результат — только если
  непустой). Сам результат печатает CLI и только по --show-step-result /
  --show-reasoning; по умолчанию от шага остаётся статус без результата.
  Экспортируется для тестов контракта события. }
function StepEndText(const Step: TPlanStep): string;
{ Подсказка шага с причиной неудачи предыдущей попытки: при непустом FixHint
  к BuildStepPrompt добавляются причина (усечённая) и требование исправить
  ситуацию, а не повторять неудачное действие. При пустом FixHint результат
  совпадает с BuildStepPrompt. Экспортируется для тестов повторов шага. }
function StepPrompt(const Task, PlanRender, StepDesc, FixHint: string): string;
{ Предел попыток выполнения шага плана: 1 + Cfg.PlanStepFixAttempts
  (первая попытка плюс повторы исправления по причине неудачи); отсутствие
  повторов (0) — одна попытка, отрицательное значение вырождается в неё же.
  Экспортируется для тестов политики повторов шага. }
function StepMaxTries(const Cfg: TMirmidConfig): Integer;

{ --- Классификация нештатного результата шага --- }
{ Префикс текста ошибки инструмента (соглашение проекта): результат шага,
  начинающийся с него, считается неудачей, а не результатом. }
const
  STEP_ERROR_PREFIX = 'ERROR:';

type
  { Класс результата шага плана: sfNone — штатный результат, остальное —
    повод для повторной попытки (Cfg.PlanStepFixAttempts):
    sfTurn — RunTurn вернул False (Err — причина отказа),
    sfEmpty — ход завершён, но ответ пуст,
    sfError — ответ шага начинается с «ERROR:» (ошибка инструмента стала
      финальным текстом шага). }
  TStepFailure = (sfNone, sfTurn, sfEmpty, sfError);

{ Классификация результата шага по трём признакам: успех хода, текст ответа
  и Err. Пустой (или пробельный) ответ и текст с префиксом ERROR: — нештатный
  результат даже при RunTurn=True: шаг не дал результата. }
function ClassifyStepResult(TurnOk: Boolean; const FinalText,
  Err: string): TStepFailure;
{ Имя класса нештатной ситуации для журнала и строки статуса:
  ok / turn / empty / error. }
function StepFailureName(Kind: TStepFailure): string;
{ Причина нештатного результата — текст для промпта повторной попытки и
  результата шага в плане. Для sfNone — пустая строка. }
function StepFailureReason(Kind: TStepFailure; const FinalText,
  Err: string): string;

{ --- Журнал процесса модели (jsonl) ---
  Каталог журнала: <WorkDir>/.mirmid/logs — рядом с сессиями, но отдельно
  от них (ListSessions и *.json сессий не затрагиваются). }
function ModelLogDir(const WorkDir: string): string;
{ Файл журнала <Dir>/<Id>.jsonl; пустой Id — <Dir>/plan.jsonl. }
function ModelLogFile(const Dir, Id: string): string;
{ Дописывает в <Dir>/<Id>.jsonl одну запись о вызове модели: время, фаза,
  запрос (сообщения), ответ, размышления, tool_calls, finish_reason и usage.
  CallErr <> '' — вызов модели завершился ошибкой, её текст пишется в поле
  error (ответ при этом может быть частичным).
  ElapsedMs < 0 — длительность не пишется; пустой Dir — журнал отключён
  (Result=True, файл не создаётся). Возвращает False и Err при сбое записи:
  решение о реакции принимает вызывающий (ход из-за журнала не падает).
  Экспортируется для тестов. }
function AppendModelLog(const Dir, Id, Phase: string; const Msgs: TMessages;
  const Resp: TLLMResponse; ElapsedMs: Int64; const CallErr: string;
  out Err: string): Boolean;

implementation

uses
  SysUtils, mirmid.json, mirmid.session, mirmid.util;

{ Усечение результата шага до PLAN_STEP_RESULT_MAX символов (аналог
  Shorten из mirmid.cli.pas; юнит CLI из планировщика не импортируется). }
function ShortenStepResult(const S: string): string;
begin
  if Length(S) <= PLAN_STEP_RESULT_MAX then
    Exit(S);
  { TruncateUTF8 не разрезает многобайтовый символ: «битые» байты затем
    попадают в запрос к API и сервер отвечает HTTP 400. }
  Result := TruncateUTF8(S, PLAN_STEP_RESULT_MAX) + '…';
end;
{ Добавляет сообщение в историю (конструктор массивов [..] для TMessage
  недоступен: в записи есть динамическое поле ToolCalls). }
procedure AppendMsg(var Msgs: TMessages; const M: TMessage);
var
  N: Integer;
begin
  N := Length(Msgs);
  SetLength(Msgs, N + 1);
  Msgs[N] := M;
end;

function ModelLogDir(const WorkDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(WorkDir) + '.mirmid' + PathDelim + 'logs';
end;

function ModelLogFile(const Dir, Id: string): string;
begin
  if Id = '' then
    Result := IncludeTrailingPathDelimiter(Dir) + 'plan.jsonl'
  else
    Result := IncludeTrailingPathDelimiter(Dir) + Id + '.jsonl';
end;

{ Значения строк — через переменные: fpjson сам экранирует строки, а прямой
  литерал в аргументе Add рискует двойным перекодированием. Содержимое
  ответа и запроса проходит SanitizeUTF8 (MessageToJSON делает это сам):
  «битые» байты из ответа модели иначе сделали бы строку журнала нечитаемой. }
function AppendModelLog(const Dir, Id, Phase: string; const Msgs: TMessages;
  const Resp: TLLMResponse; ElapsedMs: Int64; const CallErr: string;
  out Err: string): Boolean;
var
  O, Usage, Call: TJSONObject;
  Calls: TJSONArray;
  S: string;
  I: Integer;
begin
  Err := '';
  { Пустой каталог — журнал отключён: файл не создаётся. }
  if Dir = '' then
    Exit(True);
  O := TJSONObject.Create;
  try
    S := NowStamp;
    O.Add('time', S);
    O.Add('phase', Phase);
    if ElapsedMs >= 0 then
      O.Add('elapsed_ms', ElapsedMs);
    O.Add('request', MessagesToJSONArray(Msgs));
    S := SanitizeUTF8(Resp.Content);
    O.Add('response', S);
    { Неудачный вызов модели: причина отказа рядом с (возможно частичным)
      ответом. }
    if CallErr <> '' then
    begin
      S := SanitizeUTF8(CallErr);
      O.Add('error', S);
    end;
    if Resp.Reasoning <> '' then
    begin
      S := SanitizeUTF8(Resp.Reasoning);
      O.Add('reasoning', S);
    end;
    if Resp.FinishReason <> '' then
    begin
      S := Resp.FinishReason;
      O.Add('finish_reason', S);
    end;
    if Length(Resp.ToolCalls) > 0 then
    begin
      Calls := TJSONArray.Create;
      for I := 0 to High(Resp.ToolCalls) do
      begin
        Call := TJSONObject.Create;
        Call.Add('name', Resp.ToolCalls[I].Name);
        S := SanitizeUTF8(Resp.ToolCalls[I].Arguments);
        Call.Add('arguments', S);
        Calls.Add(Call);
      end;
      O.Add('tool_calls', Calls);
    end;
    Usage := TJSONObject.Create;
    Usage.Add('prompt', Resp.PromptTokens);
    Usage.Add('completion', Resp.CompletionTokens);
    Usage.Add('total', Resp.TotalTokens);
    O.Add('usage', Usage);
    S := O.AsJSON + sLineBreak;
    Result := AppendTextFile(ModelLogFile(Dir, Id), S, Err);
  finally
    O.Free;
  end;
end;

{ Конфиг агента фазы анализа: копия конфига родительской сессии с системной
  подсказкой аналитика. Политики доступа (AllowWrite/AllowShell/AllowHttp)
  и прочие настройки наследуются как есть — анализ работает с теми же
  правами, что и остальные фазы: иначе явно включённые пользователем
  флаги (`--allow-shell` и др.) молча игнорировались, а инструмент отвечал
  «запустите с --allow-shell». Требование «только на чтение» задаёт подсказка
  PLANNER_ANALYSIS_PROMPT. }
function AnalysisConfig(const Parent: TMirmidConfig): TMirmidConfig;
begin
  Result := Parent;
  Result.SystemPrompt := PLANNER_ANALYSIS_PROMPT;
end;

{ Текст события aeStepEnd: «s1: done — результат» (результат — только
  если непустой). }
function StepEndText(const Step: TPlanStep): string;
begin
  Result := Step.Id + ': ' + PlanStatusName(Step.Status);
  if Step.Result <> '' then
    Result := Result + ' — ' + Step.Result;
end;

{ Подсказка шага с причиной неудачи предыдущей попытки. Причина усекается:
  «простыня» ответа или ошибки инструмента иначе раздувает системную подсказку
  каждой следующей попытки. Модель должна устранить причину, а не повторять
  неудачное действие; если шаг уже выполнен — подтвердить результат. }
function StepPrompt(const Task, PlanRender, StepDesc, FixHint: string): string;
begin
  Result := BuildStepPrompt(Task, PlanRender, StepDesc);
  if Trim(FixHint) = '' then
    Exit;
  Result := Result + LineEnding + LineEnding +
    'Предыдущая попытка этого шага завершилась неудачно: ' +
    ShortenStepResult(Trim(FixHint)) + LineEnding +
    'Устрани причину неудачи и выполни шаг заново. Не повторяй то же самое ' +
    'действие, которое привело к неудаче; если шаг уже выполнен, кратко ' +
    'подтверди результат.';
end;

{ Предел попыток шага: первая попытка + повторы исправления. Отрицательное
  значение настройки (например, из INI) не должно отменять первую попытку. }
function StepMaxTries(const Cfg: TMirmidConfig): Integer;
begin
  Result := 1 + Cfg.PlanStepFixAttempts;
  if Result < 1 then
    Result := 1;
end;

{ Классификация результата шага. Порядок проверок важен: отказ хода
  перекрывает остальные признаки (при RunTurn=False текст ответа может быть
  каким угодно), затем — пустой/пробельный ответ, затем текст с префиксом
  ошибки инструмента. Сравнение префикса — по уже обрезанной строке: модели
  иногда предваряют ответ переводом строки. }
function ClassifyStepResult(TurnOk: Boolean; const FinalText,
  Err: string): TStepFailure;
var
  S: string;
begin
  if not TurnOk then
    Exit(sfTurn);
  S := Trim(FinalText);
  if S = '' then
    Exit(sfEmpty);
  if Pos(STEP_ERROR_PREFIX, S) = 1 then
    Exit(sfError);
  Result := sfNone;
end;

{ Имя класса нештатной ситуации (для журнала процесса модели и отладки). }
function StepFailureName(Kind: TStepFailure): string;
begin
  case Kind of
    sfTurn:  Result := 'turn';
    sfEmpty: Result := 'empty';
    sfError: Result := 'error';
  else
    Result := 'ok';
  end;
end;

{ Причина нештатного результата — текст, который получит модель в промпте
  повторной попытки и который попадёт в результат шага плана. Err хода может
  быть пустым (редкий случай) — тогда причина формулируется по классу. }
function StepFailureReason(Kind: TStepFailure; const FinalText,
  Err: string): string;
begin
  case Kind of
    sfTurn:
      if Trim(Err) <> '' then
        Result := 'ход завершился неудачей: ' + Trim(Err)
      else
        Result := 'ход завершился неудачей без указания причины';
    sfEmpty:
      Result := 'ответ модели пуст: шаг не вернул результата';
    sfError:
      Result := 'шаг завершился ошибкой инструмента: ' +
        ShortenStepResult(Trim(FinalText));
  else
    Result := '';
  end;
end;

{ Максимальный числовой суффикс среди id шагов (sN); 0, если таких нет. }
function MaxStepNum(const Plan: TPlan): Integer;
var
  I, N: Integer;
begin
  Result := 0;
  for I := 0 to High(Plan.Steps) do
  begin
    if (Length(Plan.Steps[I].Id) > 1) and (Plan.Steps[I].Id[1] = 's') then
    begin
      N := StrToIntDef(Copy(Plan.Steps[I].Id, 2, MaxInt), 0);
      if N > Result then
        Result := N;
    end;
  end;
end;

{ Добавляет шаг в план: в конец, затем (если AfterId непуст) переставляет
  его после шага с этим id. Возвращает id нового шага.
  Авто-id sN из AddStep может столкнуться с существующим после удалений
  шагов — в этом случае присваивается свободный id. }
function AddStepAfter(Plan: TPlan; const Desc, AfterId: string;
  out NewId: string; out Err: string): Boolean;
var
  Idx, AIdx, I, K: Integer;
  Order: array of string;
begin
  Result := False;
  NewId := '';
  Err := '';
  Idx := Plan.AddStep(Desc);
  NewId := Plan.Steps[Idx].Id;
  if Plan.FindStep(NewId) <> Idx then
  begin
    { Столкновение id: присваиваем свободный sN. }
    Plan.Steps[Idx].Id := 's' + IntToStr(MaxStepNum(Plan) + 1);
    NewId := Plan.Steps[Idx].Id;
  end;
  if AfterId <> '' then
  begin
    AIdx := Plan.FindStep(AfterId);
    if AIdx < 0 then
    begin
      Err := 'неизвестный шаг "' + AfterId + '" для add.after';
      Exit(False);
    end;
    { Новый порядок: все шаги кроме нового, новый вставлен после AfterId.
      Новый шаг в конце плана, поэтому позиция AfterId в Order совпадает
      с его позицией в плане. }
    SetLength(Order, Length(Plan.Steps) - 1);
    K := 0;
    for I := 0 to High(Plan.Steps) do
      if Plan.Steps[I].Id <> NewId then
      begin
        Order[K] := Plan.Steps[I].Id;
        Inc(K);
      end;
    SetLength(Order, Length(Order) + 1);
    for I := High(Order) downto AIdx + 1 do
      Order[I] := Order[I - 1];
    Order[AIdx + 1] := NewId;
    if not Plan.Reorder(Order) then
    begin
      Err := 'внутренняя ошибка: не удалось переставить новый шаг';
      Exit(False);
    end;
  end;
  Result := True;
end;

constructor TPlanner.Create(const ACfg: TMirmidConfig; ARegistry: TToolRegistry);
begin
  inherited Create;
  FCfg := ACfg;
  FRegistry := ARegistry;
  FPlan := nil;
  FOnEvent := nil;
  FOnPlanChanged := nil;
  FSubAgentDepth := 0;
  FSessionBase := '';
  FLogDir := ModelLogDir(FCfg.WorkDir);
  FLogPhase := '';
  FInteractive := False;
  FPlanTask := '';
  FAnalyzing := False;
end;

destructor TPlanner.Destroy;
begin
  FPlan.Free;
  inherited Destroy;
end;

procedure TPlanner.SaveStepSession(const Step: TPlanStep; const Msgs: TMessages;
  TryNum: Integer);
var
  Err: string;
begin
  if FSessionBase = '' then
    Exit;
  { Имя файла с номером попытки: иначе повтор шага затёр бы сессию прошлой
    попытки и было бы не видно, чем она закончилась. }
  SaveSession(SessionDir(FCfg.WorkDir),
    StepSessionIdTry(FSessionBase, Step.Id, TryNum), FCfg.Model, Msgs, nil, Err);
end;
{ Сессия фазы анализа: <база сессии>_analysis.json — рядом с сессиями
  шагов (<база>_step_<id>.json). Сохраняется по аналогии с основной
  сессией; пустой SessionBase — сессии не сохраняются. }
procedure TPlanner.SaveAnalysisSession(const Msgs: TMessages);
var
  Err: string;
begin
  if FSessionBase = '' then
    Exit;
  SaveSession(SessionDir(FCfg.WorkDir), AnalysisSessionId(FSessionBase),
    FCfg.Model, Msgs, nil, Err);
end;


procedure TPlanner.Fire(Kind: TAgentEventKind; const Text: string);
begin
  if Assigned(FOnEvent) then
    FOnEvent(Kind, Text);
end;

{ Запись пары «запрос → ответ» в журнал процесса модели. Сбой записи
  (нет прав, диск занят) не прерывает ход: журнал — вспомогательный
  артефакт, поэтому ошибка уходит событием aeError, а фаза продолжается.
  Исключение тоже гасится: AppendTextFile возвращает ошибку строкой, но
  O.AsJSON на неожиданных данных мог бы бросить. }
procedure TPlanner.LogModelCall(const Phase: string; const Msgs: TMessages;
  const Resp: TLLMResponse; ElapsedMs: Int64; const ErrText: string);
var
  Err: string;
begin
  if FLogDir = '' then
    Exit;
  try
    if not AppendModelLog(FLogDir, FSessionBase, Phase, Msgs, Resp, ElapsedMs,
      ErrText, Err)
    then
      Fire(aeError, 'журнал модели: ' + Err);
  except
    on E: Exception do
      Fire(aeError, 'журнал модели: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ Обработчик OnModelCall агента фазы (анализ, шаг плана): пишет вызов в
  журнал с меткой текущей фазы FLogPhase. Своей логики у него нет — вся
  работа в LogModelCall, чтобы одинаково вести себя во всех фазах. }
procedure TPlanner.AgentModelCall(const Msgs: TMessages;
  const Resp: TLLMResponse; ElapsedMs: Int64; const ErrText: string);
begin
  LogModelCall(FLogPhase, Msgs, Resp, ElapsedMs, ErrText);
end;

{ Прямой вызов Chat фазы плана/отчёта с записью в журнал процесса модели.
  Длительность считается по TicksMs вокруг вызова; запись — в finally, чтобы
  в журнал попал и неудачный вызов (Err тогда непустой, Resp — частичный). }
function TPlanner.ChatLogged(LLM: TLLMClient; const Phase: string;
  const Msgs: TMessages; out Resp: TLLMResponse; out Err: string): Boolean;
var
  StartMs: QWord;
begin
  StartMs := TicksMs;
  try
    Result := LLM.Chat(Msgs, nil, Resp, Err);
  finally
    LogModelCall(Phase, Msgs, Resp, Int64(TicksMs - StartMs), Err);
  end;
end;

{ Фаза 0 — предварительный анализ: отдельный агент изучает задачу и её
  окружение и возвращает текст анализа. Права — как у родительской сессии
  (AnalysisConfig): флаги `--allow-*` действуют и здесь, а «только на чтение»
  требует подсказка аналитика. План строится уже на основе анализа. }
function TPlanner.AnalysisPhase(const History: TMessages;
  out Analysis: string; out Err: string): Boolean;
var
  Cfg: TMirmidConfig;
  A: TAgent;
  Msgs: TMessages;
  I: Integer;
  LabelText: string;
  SubSession: Boolean;
begin
  Result := False;
  Err := '';
  Analysis := '';
  { Бюджет анализа — общий для агента (FCfg.MaxSteps); шаги используют
    отдельный бюджет PlanStepMaxSteps. }
  Cfg := AnalysisConfig(FCfg);
  { Метка под-сессии анализа в строке статуса: «анализ». }
  LabelText := 'анализ';
  SubSession := False;
  A := TAgent.Create(Cfg, FRegistry);
  try
    A.SubAgentDepth := FSubAgentDepth + 1;
    { Журнал процесса модели: каждая пара «запрос → ответ» этой фазы пишется
      в <WorkDir>/.mirmid/logs/<база>.jsonl с меткой phase=analysis. Подключён
      всегда: пустой FLogDir отключает запись внутри LogModelCall. }
    FLogPhase := 'analysis';
    A.OnModelCall := @AgentModelCall;
    { События анализа идут в обработчик родителя (строка статуса как у
      субагента); вход и выход из под-сессии отмечаются отдельными событиями
      с меткой «анализ», чтобы UI не угадывал фазу по тексту. Без обработчика
      события не нужны: они только для UI. Результат анализа по-прежнему
      приходит событием aeAnalysis. }
    if Assigned(FOnEvent) then
    begin
      A.OnEvent := @Fire;
      { Флаг до Fire: если обработчик события упадёт, finally всё равно
        пошлёт aeSubSessionEnd и снимет счётчики/метку анализа. }
      SubSession := True;
      Fire(aeSubSessionStart, LabelText);
    end;
    { Контекст диалога: история родительской сессии без системного сообщения. }
    Msgs := A.Messages;
    for I := 0 to High(History) do
      if History[I].Role <> mrSystem then
        AppendMsg(Msgs, History[I]);
    A.Messages := Msgs;
    FAnalyzing := True;
    try
      Result := A.RunTurn(Analysis, Err);
    finally
      FAnalyzing := False;
    end;
    { Лог сессии анализа (по аналогии с сессией шага): сохраняется и при
      неудачном ходе — в файле видно, на чём агент остановился. }
    SaveAnalysisSession(A.Messages);
    if Result then
      Fire(aeAnalysis, Analysis);
  finally
    { Выход из под-сессии анализа — и при падении: иначе метка и счётчики
      анализа остались бы в строке статуса следующей фазы. }
    if SubSession then
      Fire(aeSubSessionEnd, LabelText);
    A.Free;
  end;
end;

{ Фаза 1 — план: запрос к модели, разбор, одна повторная попытка при
  неудаче разбора. Запрос включает результаты предварительного анализа. }
function TPlanner.PlanPhase(const Task: string; const History: TMessages;
  const Analysis: string; out Err: string): Boolean;
var
  LLM: TLLMClient;
  Msgs: TMessages;
  Resp: TLLMResponse;
  P: TPlan;
  I: Integer;
begin
  Result := False;
  Err := '';
  { Запрос: системная подсказка + история без системного сообщения
    (текущая задача уже — последнее user-сообщение) + запрос плана,
    в который включён предварительный анализ. }
  FLogPhase := 'plan';
  Msgs := nil;
  AppendMsg(Msgs, MakeMessage(mrSystem, PLANNER_SYSTEM_PROMPT));
  for I := 0 to High(History) do
    if History[I].Role <> mrSystem then
      AppendMsg(Msgs, History[I]);
  AppendMsg(Msgs, MakeMessage(mrUser, BuildPlanPrompt(Task, Analysis)));
  LLM := TLLMClient.Create(FCfg);
  try
    { Журнал процесса модели: запрос плана (и повтор после неудачного
      разбора — отдельной записью с тем же phase=plan). }
    if not ChatLogged(LLM, 'plan', Msgs, Resp, Err) then
      Exit(False);
    P := ParsePlanFromText(Resp.Content, Err);
    if P = nil then
    begin
      { Одна повторная попытка: неудачный ответ модели и user-сообщение
        об ошибке. }
      AppendMsg(Msgs, MakeMessage(mrAssistant, Resp.Content));
      AppendMsg(Msgs, MakeMessage(mrUser,
        'предыдущий ответ не был корректным JSON: ' + Err +
        '; верни только JSON'));
      if not ChatLogged(LLM, 'plan', Msgs, Resp, Err) then
        Exit(False);
      P := ParsePlanFromText(Resp.Content, Err);
      if P = nil then
        Exit(False);
    end;
    if FPlan <> nil then
      FPlan.Free;
    FPlan := P;
    { Ограничение числа шагов в плане (plan_max_step > 0). }
    if FPlan.Truncate(FCfg.PlanMaxStep) > 0 then
      Fire(aeError, 'план усекается: превышен лимит шагов (' +
        IntToStr(FCfg.PlanMaxStep) + ')');
    Fire(aePlan, FPlan.Render);
    if Assigned(FOnPlanChanged) then
      FOnPlanChanged;
    Result := True;
  finally
    LLM.Free;
  end;
end;

{ Фаза 2 — один шаг: подцикл в новом TAgent. Результат классифицируется
  (ClassifyStepResult): штатный ответ — done с усечённым результатом;
  отказ хода, пустой ответ и текст с префиксом «ERROR:» — failed с причиной
  (StepFailureReason). FixHint — причина неудачи предыдущей попытки: попадает
  в подсказку шага (StepPrompt), чтобы модель исправила ситуацию, а не
  повторяла неудачное действие. Решение о повторе принимает RunPlannedTurn
  по значению Cfg.PlanStepFixAttempts. }
function TPlanner.RunStep(const Step: TPlanStep; const Task, FixHint: string;
  TryNum, MaxTries: Integer; out Err: string): Boolean;
var
  Cfg: TMirmidConfig;
  A: TAgent;
  FinalText: string;
  StepBase: string;
  LabelText: string;
  SubSession: Boolean;
  TurnOk: Boolean;
  Fail: TStepFailure;
  Res: TLLMResponse;
begin
  Result := False;
  Err := '';
  { Конфиг — копия родительского: подсказка шага (с причиной неудачи прошлой
    попытки) и бюджет шага. }
  Cfg := FCfg;
  Cfg.SystemPrompt := StepPrompt(Task, FPlan.Render, Step.Description, FixHint);
  Cfg.MaxSteps := FCfg.PlanStepMaxSteps;
  { База имени файла сессии попытки шага: <база сессии>_step_<id>, у повторов
    — с номером попытки (<база>_step_<id>_try<N>). Её же наследуют субагенты
    внутри шага, поэтому их файлы тоже различаются по попыткам. }
  StepBase := StepSessionIdTry(FSessionBase, Step.Id, TryNum);
  { Метка под-сессии шага в строке статуса: «шаг sN». }
  LabelText := 'шаг ' + Step.Id;
  SubSession := False;
  A := TAgent.Create(Cfg, FRegistry);
  try
    A.SubAgentDepth := FSubAgentDepth + 1;
    { Журнал процесса модели шага: записи этой фазы получают метку
      phase=step <id> в том же файле <база>.jsonl, что и остальные фазы. }
    FLogPhase := 'step ' + Step.Id;
    A.OnModelCall := @AgentModelCall;
    { События шага идут в обработчик родителя (строка статуса как у
      субагента); вход и выход из под-сессии отмечаются отдельными событиями
      с меткой, чтобы UI не угадывал фазу по тексту. Без обработчика события
      не нужны: они только для UI. }
    if Assigned(FOnEvent) then
    begin
      A.OnEvent := @Fire;
      { Флаг до Fire: если обработчик события упадёт, finally всё равно
        пошлёт aeSubSessionEnd и снимет счётчики/метку шага. }
      SubSession := True;
      Fire(aeSubSessionStart, LabelText);
    end;
    if FSessionBase <> '' then
      A.SessionBase := StepBase;
    A.AddUser(Step.Description);
    TurnOk := A.RunTurn(FinalText, Err);
    Fail := ClassifyStepResult(TurnOk, FinalText, Err);
    { Класс результата виден в журнале процесса модели отдельной записью
      (phase=step sN try K/M result: <класс>, response — причина): по ней
      видно, какая попытка шага чем закончилась и сколько попыток разрешено
      (PlanStepFixAttempts). Сбой записи не мешает ходу. }
    Res := Default(TLLMResponse);
    Res.Content := StepFailureReason(Fail, FinalText, Err);
    LogModelCall(Format('step %s try %d/%d result: %s',
      [Step.Id, TryNum, MaxTries, StepFailureName(Fail)]), nil, Res, -1, '');
    if Fail = sfNone then
    begin
      FPlan.SetStatus(Step.Id, psDone, ShortenStepResult(FinalText));
      Result := True;
    end
    else
    begin
      { Причина нештатной ситуации — в результат шага: её видно в плане и
        событиях aeStepEnd, а повторная попытка (RunPlannedTurn) передаёт её
        модели в промпте. }
      Err := StepFailureReason(Fail, FinalText, Err);
      FPlan.SetStatus(Step.Id, psFailed, Err);
    end;
    { Лог сессии попытки шага (по аналогии с основной сессией): у повторов имя
      файла содержит номер попытки, поэтому попытки не затирают друг друга. }
    SaveStepSession(Step, A.Messages, TryNum);
  finally
    { Выход из под-сессии — и при падении шага: иначе метка и счётчики шага
      остались бы в строке статуса следующего шага. }
    if SubSession then
      Fire(aeSubSessionEnd, LabelText);
    A.Free;
  end;
end;

{ Подсказка на решение по шагу, исчерпавшему попытки: изменить план или
  прекратить работу. Ответ — только JSON-объект (поля decision/ops/reason),
  чтобы разбор не зависел от формулировок модели. }
const
  STEP_REVISE_PROMPT =
    'Ты — планировщик. Шаг плана не удался после всех попыток исправления. ' +
    'Реши, что делать дальше, и верни только JSON-объект: ' +
    '{"decision":"revise","ops":[<операции>],"reason":"почему"} — изменить ' +
    'план (операции: {"op":"add","description":"...","after":"s2"}, ' +
    '{"op":"remove","id":"s3"}, {"op":"reorder","order":["s1","s2"]}, ' +
    '{"op":"skip","id":"s4"}), либо ' +
    '{"decision":"stop","reason":"почему"} — прекратить работу. ' +
    'Не повторяй тот же шаг без изменения подхода.';

{ Решение по исчерпанному шагу. Неудача самого решения (нет ответа модели,
  не разобрался JSON, ops отклонён) трактуется как остановка хода: продолжать
  без понятного плана нельзя. }
function TPlanner.ReviseAfterStepFailure(const Step: TPlanStep;
  const Task, Reason: string; out StopReason: string): Boolean;
var
  LLM: TLLMClient;
  Msgs: TMessages;
  Resp: TLLMResponse;
  Err, Phase, Decision, Why: string;
  D, Ops: TJSONData;
  Args: TJSONObject;
  Ctx: TToolContext;
  Outcome: TToolOutcome;
begin
  Result := False;
  StopReason := 'шаг ' + Step.Id + ' не выполнен: ' + Reason;
  Phase := 'step ' + Step.Id + ' revise';
  FLogPhase := Phase;
  Msgs := nil;
  AppendMsg(Msgs, MakeMessage(mrSystem, STEP_REVISE_PROMPT));
  AppendMsg(Msgs, MakeMessage(mrUser,
    'Задача:' + LineEnding + Task + LineEnding + LineEnding +
    'Текущий план:' + LineEnding + FPlan.Render + LineEnding + LineEnding +
    'Неудачный шаг ' + Step.Id + ': ' + Step.Description + LineEnding +
    'Причина неудачи за все попытки: ' + Reason));
  LLM := TLLMClient.Create(FCfg);
  try
    if not ChatLogged(LLM, Phase, Msgs, Resp, Err) then
    begin
      StopReason := StopReason + '; решение о плане не получено: ' + Err;
      Exit;
    end;
  finally
    LLM.Free;
  end;
  D := nil;
  if not ParseJSONRepair(Resp.Content, D, Err) or not (D is TJSONObject) then
  begin
    if D <> nil then
      D.Free;
    StopReason := StopReason + '; не удалось разобрать решение модели';
    Exit;
  end;
  try
    Decision := LowerCase(Trim(JStr(D, 'decision', '')));
    Why := Trim(JStr(D, 'reason', ''));
    if Decision <> 'revise' then
    begin
      if Why <> '' then
        StopReason := StopReason + '; ' + Why;
      Exit;
    end;
    Ops := nil;
    try
      Ops := D.FindPath('ops');
    except
      Ops := nil;
    end;
    if not (Ops is TJSONArray) then
    begin
      StopReason := StopReason + '; решение revise без операций над планом';
      Exit;
    end;
    { Операции применяет тот же обработчик, что и инструмент revise_plan:
      валидация, событие aePlan и сохранение сессии — в одном месте.
      Контекст инструментов не нужен (HandleRevisePlan его не читает), но
      заполняется как у шага, чтобы поведение совпадало с вызовом модели. }
    Args := TJSONObject.Create;
    try
      Args.Add('ops', Ops.Clone);
      Ctx := Default(TToolContext);
      Ctx.WorkDir := FCfg.WorkDir;
      Ctx.Cfg := FCfg;
      Ctx.Registry := FRegistry;
      Ctx.SubAgentDepth := FSubAgentDepth;
      Ctx.SessionBase := FSessionBase;
      Ctx.OnSubAgentEvent := FOnEvent;
      Outcome := HandleRevisePlan(Args, Ctx);
    finally
      Args.Free;
    end;
    if Outcome.IsError then
    begin
      StopReason := StopReason + '; пересмотр плана не удался: ' + Outcome.Text;
      Exit;
    end;
    Result := True;
  finally
    D.Free;
  end;
end;

{ Фаза 3 — отчёт: детерминированная сводка + один финальный запрос модели.
  При неудаче запроса Report не меняется (детерминированная сводка); ход
  не считается неудачным. }
function TPlanner.ReportPhase(const Task: string; out Report: string; out Err: string): Boolean;
var
  LLM: TLLMClient;
  Msgs: TMessages;
  Resp: TLLMResponse;
begin
  Result := False;
  Err := '';
  Report := BuildPlanReport(FPlan, Task);
  { Фаза отчёта тоже не идёт через агента: прямой Chat в журнал процесса
    модели с меткой phase=report. }
  FLogPhase := 'report';
  Msgs := nil;
  AppendMsg(Msgs, MakeMessage(mrSystem, REPORT_SYSTEM_PROMPT));
  AppendMsg(Msgs, MakeMessage(mrUser, Report));
  LLM := TLLMClient.Create(FCfg);
  try
    if ChatLogged(LLM, 'report', Msgs, Resp, Err) then
    begin
      Report := Resp.Content;
      Err := '';
      Result := True;
    end;
  finally
    LLM.Free;
  end;
  Fire(aeReport, Report);
end;

{ Один ход в режиме планирования: план → шаги → отчёт. }
function TPlanner.RunPlannedTurn(const Task: string; const History: TMessages;
  out FinalText: string; out Err: string): Boolean;
var
  I: Integer;
  Step: TPlanStep;
  StepErr: string;             { причина неудачи шага (Err последней попытки) }
  StepOk: Boolean;             { возвращаемое значение RunStep }
  StepStatus: TPlanStepStatus; { фактический статус шага после попыток }
  InPlan: Boolean;             { шаг остался в плане после попыток }
  Where: string;               { состояние шага для записи журнала }
  FixHint: string;             { причина неудачи предыдущей попытки шага }
  TryNum: Integer;             { номер выполняемой попытки шага (с 1) }
  MaxTries: Integer;           { предел попыток: 1 + Cfg.PlanStepFixAttempts }
  Res: TLLMResponse;           { запись журнала о повторе/исчерпании попыток }
  LastFailId: string;          { шаг последней неудачи — попадает в Err хода }
  LastFailReason: string;      { причина последней неудачи шага }
  Halted: Boolean;             { ход остановлен: исправить шаг не удалось и
                                 модель решила прекратить работу }
  StopReason: string;          { причина остановки для aeError }
  PlanBuilt: Boolean;
  WorkTask: string;
  Analysis: string;
  AnaErr: string;
begin
  FinalText := '';
  Err := '';
  Result := False;
  PlanBuilt := False;
  Halted := False;
  StopReason := '';
  LastFailId := '';
  LastFailReason := '';
  { Фаза 1: план. Новый план строится, если плана нет или все шаги
    предыдущего плана достигли терминального состояния (новый ход —
    новая задача). Неполный план (pending/in_progress) — возобновление:
    сразу переходим к шагам. }
  if (FPlan = nil) or
     ((FPlan.CountByStatus(psPending) = 0) and
      (FPlan.CountByStatus(psInProgress) = 0))
  then
  begin
    { Фаза 0: предварительный анализ задачи. Его неудача не блокирует
      планирование: план строится без анализа. }
    if not AnalysisPhase(History, Analysis, AnaErr) then
    begin
      Fire(aeError, 'предварительный анализ не удался: ' + AnaErr);
      Analysis := '';
    end;
    if not PlanPhase(Task, History, Analysis, Err) then
      Exit(False);
    PlanBuilt := True;
    FPlanTask := Task;
  end;
  { При возобновлении (в т.ч. по указанию пользователя в интерактивном
    режиме) шаги и отчёт ориентируются на исходную задачу плана, а не на
    текст-указание. }
  if FPlanTask <> '' then
    WorkTask := FPlanTask
  else
    WorkTask := Task;
  { Интерактивный режим: после планирования работа завершается. Шаги
    выполняются при следующем указании пользователя — тогда план уже есть
    и неполный план возобновляется с текущего pending-шага. }
  if PlanBuilt and FInteractive then
  begin
    FinalText := FPlan.Render;
    Exit(True);
  end;
  { Фаза 2: шаги, пока есть pending. Предел попыток шага — 1 +
    Cfg.PlanStepFixAttempts (первая попытка + повторы; отрицательное значение
    вырождается в одну попытку). Неудачный шаг повторяется: причина неудачи
    уходит в промпт следующей попытки (RunStep.FixHint), чтобы модель
    исправила ситуацию, а не повторяла то же действие. Если исправить не
    удалось — модель решает (ReviseAfterStepFailure): пересмотреть план через
    HandleRevisePlan или прекратить работу (остановка хода через aeError).
    Каждая попытка попадает в журнал процесса модели
    (phase=step sN try K/M ...). }
  MaxTries := StepMaxTries(FCfg);
  while FPlan.NextPending >= 0 do
  begin
    I := FPlan.NextPending;
    Step := FPlan.Steps[I];
    FPlan.SetStatus(Step.Id, psInProgress, '');
    Fire(aeStepStart, Step.Id + ': ' + Step.Description);
    if Assigned(FOnPlanChanged) then
      FOnPlanChanged;
    StepErr := '';
    FixHint := '';
    TryNum := 0;
    repeat
      if TryNum > 0 then
      begin
        { Повтор: шаг снова в работе, причина прошлой неудачи — в FixHint.
          Шага могло не стать в плане (revise_plan в подцикле) — повторять
          нечего, Break до вызова модели. }
        if not FPlan.SetStatus(Step.Id, psInProgress, '') then
          Break;
        if Assigned(FOnPlanChanged) then
          FOnPlanChanged;
      end;
      StepOk := RunStep(Step, WorkTask, FixHint, TryNum + 1, MaxTries, StepErr);
      Inc(TryNum);
      { Учитываем и возвращаемое значение, и Err шага: при неудаче Err —
        причина, она уходит в промпт следующей попытки и запоминается для
        ошибки хода; при успехе подсказка сбрасывается, чтобы причина прошлой
        попытки не влияла на следующие шаги. }
      if StepOk then
      begin
        FixHint := '';
        LastFailId := '';
        LastFailReason := '';
      end
      else
      begin
        FixHint := StepErr;
        LastFailId := Step.Id;
        LastFailReason := StepErr;
      end;
    until StepOk or (FPlan.FindStep(Step.Id) < 0) or (TryNum >= MaxTries);
    { Что стало с шагом после попыток: RunStep вернул False, но шаг мог быть
      пересмотрен изнутри подцикла (revise_plan удалил его или сменил статус).
      Возвращаемое значение проверяем вместе с фактическим статусом шага:
      пересматривать план нужно только у шага, который остался failed. }
    I := FPlan.FindStep(Step.Id);
    InPlan := I >= 0;
    if InPlan then
      StepStatus := FPlan.Steps[I].Status
    else
      StepStatus := psSkipped;
    if not StepOk then
    begin
      if InPlan and (StepStatus = psFailed) then
      begin
        { Попытки исчерпаны — отдельной записью в журнале: шаг остаётся
          failed, повторов больше не будет (причина — response записи). }
        Res := Default(TLLMResponse);
        Res.Content := StepErr;
        LogModelCall(Format('step %s try %d/%d: попытки исчерпаны',
          [Step.Id, TryNum, MaxTries]), nil, Res, -1, '');
        { Исправить шаг не удалось — принимаем решение: изменить план
          (revise_plan, операции применяет HandleRevisePlan) или прекратить
          работу. Решение принимает модель; при отказе от плана или при
          невозможности его пересмотреть ход останавливается через aeError
          (ниже, после события конца шага). }
        if not ReviseAfterStepFailure(Step, WorkTask, StepErr, StopReason) then
          Halted := True;
      end
      else
      begin
        { Неудача без статуса failed: шаг уже пересмотрен внутри подцикла —
          пересматривать план нечего, но причина неудачи не теряется, она
          остаётся в журнале процесса модели. }
        if InPlan then
          Where := 'шаг в статусе ' + PlanStatusName(StepStatus)
        else
          Where := 'шаг удалён из плана';
        Res := Default(TLLMResponse);
        Res.Content := StepErr;
        LogModelCall(Format('step %s try %d/%d: %s — пересмотр плана не нужен',
          [Step.Id, TryNum, Where]), nil, Res, -1, '');
      end;
    end;
    { Шаг мог быть удалён из плана revise_plan в подцикле — тогда событие
      шлём с пометкой. }
    I := FPlan.FindStep(Step.Id);
    if I >= 0 then
      Fire(aeStepEnd, StepEndText(FPlan.Steps[I]))
    else
      Fire(aeStepEnd, Step.Id + ': удалён из плана');
    if Assigned(FOnPlanChanged) then
      FOnPlanChanged;
    { Ход остановлен: шаги больше не выполняются, отчёт не строится. }
    if Halted then
      Break;
  end;
  { Остановка хода — ошибкой (aeError + Err) и без отчёта: работа по задаче
    прекращена, итог подводить не по чему. }
  if Halted then
  begin
    Fire(aeError, StopReason);
    Err := StopReason;
    Exit(False);
  end;
  { Фаза 3: отчёт. Неудачный запрос отчёта не делает ход неудачным:
    FinalText — детерминированная сводка. }
  if not ReportPhase(WorkTask, FinalText, Err) then
    Err := '';
  { Успех хода: план построен и все шаги достигли терминального состояния
    (done/failed/skipped). }
  Result := (FPlan.CountByStatus(psPending) = 0) and
            (FPlan.CountByStatus(psInProgress) = 0);
  if not Result then
  begin
    { Err шага не теряется: причина последней неудачи дописывается к ошибке
      хода, иначе CLI покажет только констатацию остатка шагов. }
    Err := 'в плане остались шаги, не достигшие терминального состояния';
    if LastFailReason <> '' then
      Err := Err + '; последняя неудача шага ' + LastFailId + ': ' +
        LastFailReason;
  end;
end;

{ Инструмент revise_plan: применяет список операций к текущему плану.
  Операции применяются по порядку; при невалидной операции выполнившиеся
  до неё сохраняются, в результате — текст ошибки. }
function TPlanner.HandleRevisePlan(const Args: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Ops: TJSONArray;
  Op, Item: TJSONData;
  OpName, Desc, AfterId, Id: string;
  Order: array of string;
  Parts: array of string;
  I, J, Idx: Integer;
  Changes: string;
  Err: string;
  Changed: Boolean;
begin
  Result := ErrResult('');
  if FAnalyzing then
    Exit(ErrResult('revise_plan недоступен во время предварительного анализа'));
  if FPlan = nil then
    Exit(ErrResult('нет плана: revise_plan доступен только в режиме планирования'));
  Item := nil;
  try
    Item := Args.FindPath('ops');
  except
    Item := nil;
  end;
  if (Item = nil) or not (Item is TJSONArray) then
    Exit(ErrResult('нужен аргумент "ops": массив операций'));
  Ops := TJSONArray(Item);
  if Ops.Count = 0 then
    Exit(ErrResult('пустой "ops": нужна хотя бы одна операция'));
  SetLength(Parts, 0);
  Changed := False;
  for I := 0 to Ops.Count - 1 do
  begin
    Op := Ops.Items[I];
    if not (Op is TJSONObject) then
      Exit(ErrResult('операция ' + IntToStr(I + 1) + ': должна быть JSON-объектом'));
    OpName := LowerCase(Trim(JStr(TJSONObject(Op), 'op', '')));
    case OpName of
      'add':
        begin
          Desc := Trim(JStr(TJSONObject(Op), 'description', ''));
          if Desc = '' then
            Exit(ErrResult('операция ' + IntToStr(I + 1) +
              ': add требует непустое "description"'));
          if (FCfg.PlanMaxStep > 0) and (Length(FPlan.Steps) >= FCfg.PlanMaxStep) then
            Exit(ErrResult('операция ' + IntToStr(I + 1) +
              ': add: превышен лимит шагов в плане (' +
              IntToStr(FCfg.PlanMaxStep) + ')'));
          AfterId := JStr(TJSONObject(Op), 'after', '');
          if not AddStepAfter(FPlan, Desc, AfterId, Id, Err) then
            Exit(ErrResult('операция ' + IntToStr(I + 1) + ': ' + Err));
          SetLength(Parts, Length(Parts) + 1);
          Parts[Length(Parts) - 1] := 'add ' + Id + ' (' + Desc + ')';
        end;
      'remove':
        begin
          Id := JStr(TJSONObject(Op), 'id', '');
          if not FPlan.RemoveStep(Id) then
            Exit(ErrResult('операция ' + IntToStr(I + 1) +
              ': неизвестный шаг "' + Id + '" для remove'));
          SetLength(Parts, Length(Parts) + 1);
          Parts[Length(Parts) - 1] := 'remove ' + Id;
        end;
      'reorder':
        begin
          Item := nil;
          try
            Item := TJSONObject(Op).FindPath('order');
          except
            Item := nil;
          end;
          if (Item = nil) or not (Item is TJSONArray) then
            Exit(ErrResult('операция ' + IntToStr(I + 1) +
              ': reorder требует массив "order" из id шагов'));
          SetLength(Order, TJSONArray(Item).Count);
          for J := 0 to TJSONArray(Item).Count - 1 do
          begin
            if not (TJSONArray(Item).Items[J] is TJSONString) then
              Exit(ErrResult('операция ' + IntToStr(I + 1) +
                ': "order" должен содержать id шагов (строки)'));
            Order[J] := TJSONArray(Item).Items[J].AsString;
          end;
          if not FPlan.Reorder(Order) then
            Exit(ErrResult('операция ' + IntToStr(I + 1) +
              ': reorder: множество id не совпадает с шагами плана'));
          Changes := 'reorder [';
          for J := 0 to High(Order) do
          begin
            if J > 0 then
              Changes := Changes + ', ';
            Changes := Changes + Order[J];
          end;
          Changes := Changes + ']';
          SetLength(Parts, Length(Parts) + 1);
          Parts[Length(Parts) - 1] := Changes;
        end;
      'skip':
        begin
          Id := JStr(TJSONObject(Op), 'id', '');
          Idx := FPlan.FindStep(Id);
          if Idx < 0 then
            Exit(ErrResult('операция ' + IntToStr(I + 1) +
              ': неизвестный шаг "' + Id + '" для skip'));
          if FPlan.Steps[Idx].Status <> psPending then
            Exit(ErrResult('операция ' + IntToStr(I + 1) +
              ': skip доступен только для pending-шагов (шаг "' + Id +
              '" имеет статус ' + PlanStatusName(FPlan.Steps[Idx].Status) + ')'));
          FPlan.SetStatus(Id, psSkipped, '');
          SetLength(Parts, Length(Parts) + 1);
          Parts[Length(Parts) - 1] := 'skip ' + Id;
        end;
    else
      Exit(ErrResult('операция ' + IntToStr(I + 1) +
        ': неизвестный op "' + OpName + '"'));
    end;
    Changed := True;
  end;
  { План изменился (хотя бы частично): событие + сохранение сессии. }
  if Changed then
  begin
    Fire(aePlan, FPlan.Render);
    if Assigned(FOnPlanChanged) then
      FOnPlanChanged;
  end;
  Changes := '';
  for I := 0 to High(Parts) do
  begin
    if Changes <> '' then
      Changes := Changes + '; ';
    Changes := Changes + Parts[I];
  end;
  Result := OkResult('план обновлён: ' + Changes);
end;

procedure RegisterRevisePlanTool(R: TToolRegistry; P: TPlanner);
var
  Props: TJSONObject;
begin
  Props := TJSONObject.Create;
  Props.Add('ops', TJSONObject.Create([
    'type', 'array',
    'description',
      'Список операций над планом (применяются по порядку): ' +
      '{"op":"add","description":"...","after":"s2"} — добавить шаг после ' +
      '"after" (в конец, если after пуст); ' +
      '{"op":"remove","id":"s3"} — удалить шаг; ' +
      '{"op":"reorder","order":["s1","s4","s2"]} — новый порядок шагов; ' +
      '{"op":"skip","id":"s4"} — пропустить pending-шаг.',
    'items', TJSONObject.Create(['type', 'object'])
  ]));
  R.AddMethod(REVISE_PLAN_TOOL_NAME,
    'Пересматривает текущий план: добавляет, удаляет, переставляет или ' +
    'пропускает шаги. Операции применяются по порядку; при невалидной ' +
    'операции выполнившиеся до неё сохраняются.',
    SchemaObject(Props, ['ops']),
    @P.HandleRevisePlan);
end;

end.
