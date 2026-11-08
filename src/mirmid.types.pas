unit mirmid.types;
{ Общие типы харнесса: сообщения диалога и настройки запуска.
  Юнит намеренно не зависит от fpjson/сети, чтобы его могли использовать все. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { Роль сообщения в диалоге. }
  TMessageRole = (mrSystem, mrUser, mrAssistant, mrTool);

  { Один вызов инструмента, запрошенный моделью. Arguments — сырая JSON-строка. }
  TToolCall = record
    Id: string;
    Name: string;
    Arguments: string;
  end;

  { Сообщение в формате OpenAI Chat Completions. }
  TMessage = record
    Role: TMessageRole;
    Content: string;
    Reasoning: string;          { reasoning_content у reasoning-моделей }
    ToolCalls: array of TToolCall;
    ToolCallId: string;         { только для mrTool }
    Name: string;               { имя инструмента для mrTool }
  end;

  TMessages = array of TMessage;

  { Вид события агента (для обработчиков UI).
    aeContext — перед каждым запросом к модели: Text — оценка размера
    контекста запроса в токенах (у субагента — по его собственной истории
    и системной подсказке).
    aeSubSessionStart/aeSubSessionEnd — вход/выход под-сессии планировщика
    (предварительный анализ, шаг плана): Text — метка под-сессии
    («анализ», «шаг s1»). В отличие от пары aeToolCall/aeToolResult с
    инструментом subagent, вложенность и счётчики статуса определяются
    этой меткой, а не именем инструмента. }
  TAgentEventKind = (aeStep, aeAssistant, aeReasoning, aeToolCall, aeShellCommand,
    aeToolResult, aeError, aeUsage, aeStreamStart, aeStreamText,
    aeStreamReasoning, aeStreamEnd, aePlan, aeStepStart, aeStepEnd, aeReport,
    aeAnalysis, aeLoopWarning, aeContext, aeSubSessionStart, aeSubSessionEnd);
  { Обработчик событий агента. }
  TAgentEvent = procedure(Kind: TAgentEventKind; const Text: string) of object;

  { Переключатель одного встроенного инструмента из секции [tools] INI:
    имя ключа и его значение. Набор инструментов и значения по умолчанию
    задаёт таблица в mirmid.tools; здесь хранится только то, что прочитано
    из конфигурации. Пустой массив — ни один ключ не задан, все инструменты
    работают со значениями по умолчанию. }
  TToolSwitch = record
    Name: string;
    Enabled: Boolean;
  end;

  TToolSwitches = array of TToolSwitch;

  { Настройки одного запуска харнесса. }
  TMirmidConfig = record
    BaseUrl: string;            { базовый URL OpenAI-совместимого API, без слэша }
    ApiKey: string;             { эффективный ключ (ссылки «&ИМЯ» уже развёрнуты) }
    ApiKeyRaw: string;          { исходное значение api_key до разрешения («&ИМЯ» остаётся);
                                  пусто — не задано }
    Model: string;
    SystemPrompt: string;
    Temperature: Double;
    MaxTokens: Integer;
    MaxSteps: Integer;          { предел итераций «модель→инструменты» за один ход; 0 — без ограничений }
    PlanMode: Boolean;          { режим планирования: план → шаги → отчёт }
    PlanStepMaxSteps: Integer;  { бюджет шага: предел итераций «модель→инструменты» на один шаг; 0 — без ограничений }
    PlanStepFixAttempts: Integer; { сколько раз повторять шаг плана при нештатном
                                    результате (ошибка/пустой ответ) с передачей
                                    причины сбоя в промпт; 0 — не повторять }
    PlanMaxStep: Integer;       { максимум шагов в самом плане; 0 — без ограничений }
    RequestTimeout: Integer;    { мс; общий таймаут HTTP-запроса }
    ConnectTimeout: Integer;    { мс }
    Tools: TToolSwitches;       { переключатели встроенных инструментов из
                                  секции [tools]; пусто — значения по умолчанию
                                  (таблица в mirmid.tools) }
    ShellTimeout: Integer;      { сек; 0 — без ограничения }
    ShellOutputLimit: Integer;  { байт; максимум вывода shell-инструмента; 0 — без ограничения }
    WorkDir: string;            { рабочая папка инструментов }
    Verbose: Boolean;
    Stream: Boolean;            { потоковый вывод (SSE) ответа модели }
    ContextWindow: Integer;     { максимальный размер контекста модели в токенах (из настроек) }
    HostContextWindow: Integer; { контекст, сообщённый хостом (LLM-сервером); 0 — не задан }
    Reasoning: string;          { reasoning_effort: none|minimal|low|medium|high;
                                  пустая строка — параметр не отправляется }
    McpEnabled: Boolean;        { подключать ли MCP-серверы из mcp.json }
    McpConfig: string;          { путь к mcp.json; пусто — искать по умолчанию }
    McpTimeout: Integer;        { сек; таймаут ответа MCP-сервера }
    ToolOutputLines: Integer;   { строк; максимум строк вывода инструмента на экране;
                                  при превышении середина сокращается строкой «…»
                                  с отступом от начала строки; 0 — без ограничения }
    { Суммаризация сессии. }
    SummarizeThresholdPercent: Integer;  { % заполнения контекста для авто-суммаризации (0 — выкл) }
    SummarizeThresholdTokens: Integer;   { абсолютный порог в токенах (0 — использовать процент) }
    SummarizeMinSavingPercent: Integer;  { мин. % уменьшения контекста для эффективной суммаризации }
    SummarizeMinSavingTokens: Integer;   { мин. абсолютное уменьшение в токенах (0 — использовать процент) }
    { Защита от зацикливания (Loop-guard). }
    LoopWarn: Integer;                  { порог повторений одного вызова инструмента для предупреждения; 0 — выкл }
    LoopStop: Integer;                  { порог повторений одного вызова инструмента для остановки; 0 — выкл }
  end;

const
  { Максимальный размер контекста модели в токенах, если не задан явно. }
  DEFAULT_CONTEXT_WINDOW = 128000;

  { Таймаут ответа MCP-сервера по умолчанию, секунды. }
  DEFAULT_MCP_TIMEOUT = 60;

  { Сколько строк вывода инструмента показывать, если не задано явно.
    При превышении середина вывода сокращается строкой с троеточием. }
  DEFAULT_TOOL_OUTPUT_LINES = 9;

  DEFAULT_SYSTEM_PROMPT =
    'Ты — mirmid, аккуратный ИИ-агент на локальной машине пользователя. ' +
    'Отвечай по-русски, кратко и по делу. ' +
    'Для работы с файлами и командами используй предоставленные инструменты. ' +
    'Сначала читай, потом меняй. Не выдумывай содержимое файлов.';

  { Системная подсказка субагента: отдельная сессия выполняет задание родителя
    и возвращает только результат работы. }
  SUBAGENT_SYSTEM_PROMPT =
    'Ты — субагент: отдельная агентская сессия, запущенная родительским ' +
    'агентом для выполнения конкретного задания. Выполняй задание с помощью ' +
    'доступных инструментов и в финальном ответе верни только результат работы: ' +
    'кратко, по делу, без описания процесса. Отвечай по-русски.';

{ Значения по умолчанию. }
function DefaultConfig: TMirmidConfig;
{ Канонизирует режим рассуждений: none|minimal|low|medium|high.
  Синонимы: on/true/yes → medium, off/false/no → none. Пустая строка и
  нераспознанные значения дают '' (режим не задан). }
function NormalizeReasoning(const S: string): string;
{ Имя роли в нотации OpenAI. }
function RoleName(R: TMessageRole): string;
{ Конструктор сообщения с ролью и содержимым. }
function MakeMessage(R: TMessageRole; const AContent: string): TMessage;
{ Эффективный размер контекста: минимум из значения в настройках и значения,
  переданного хостом (LLM-сервером). Если хост не сообщил значение (0) —
  используется только значение из настроек. }
function EffectiveContextWindow(const Cfg: TMirmidConfig): Integer;
{ Порог авто-суммаризации в токенах: если задано абсолютное значение
  (SummarizeThresholdTokens > 0) — оно, иначе процент от эффективного
  контекста. 0 — авто-суммаризация выключена. }
function SummarizeThreshold(const Cfg: TMirmidConfig): Integer;
{ Минимальное уменьшение контекста (в токенах) для эффективной суммаризации:
  если задано абсолютное значение (SummarizeMinSavingTokens > 0) — оно,
  иначе процент от эффективного контекста. }
function SummarizeMinSaving(const Cfg: TMirmidConfig): Integer;

implementation

function DefaultConfig: TMirmidConfig;
begin
  Result.BaseUrl        := 'http://127.0.0.1:1234/v1';
  Result.ApiKey         := '';
  Result.ApiKeyRaw      := '';
  Result.Model          := '';
  Result.SystemPrompt   := DEFAULT_SYSTEM_PROMPT;
  Result.Temperature    := 0.1;
  Result.MaxTokens      := 32768;
  Result.MaxSteps        := 0;
  Result.PlanMode        := False;
  Result.PlanStepMaxSteps := 0;
  Result.PlanMaxStep := 0;
  Result.PlanStepFixAttempts := 1;  { один повтор шага при сбое }
  Result.RequestTimeout := 1800000;
  Result.ConnectTimeout := 10000;
  { Переключателей [tools] по умолчанию нет: значения берутся из таблицы
    mirmid.tools (ToolEnabledByDefault), так что DefaultConfig не зависит от
    юнита реестра инструментов. }
  SetLength(Result.Tools, 0);
  Result.ShellTimeout   := 60;
  Result.ShellOutputLimit := 65536;
  Result.ToolOutputLines := DEFAULT_TOOL_OUTPUT_LINES;
  Result.WorkDir        := '';
  Result.Verbose        := False;
  Result.Stream         := True;
  Result.ContextWindow  := DEFAULT_CONTEXT_WINDOW;
  Result.HostContextWindow := 0;
  Result.Reasoning      := '';
  Result.McpEnabled     := True;
  Result.McpConfig      := '';
  Result.McpTimeout     := DEFAULT_MCP_TIMEOUT;
  Result.SummarizeThresholdPercent := 90;
  Result.SummarizeThresholdTokens  := 0;
  Result.SummarizeMinSavingPercent := 50;
  Result.SummarizeMinSavingTokens  := 0;
  Result.LoopWarn        := 3;
  Result.LoopStop        := 5;
end;

function NormalizeReasoning(const S: string): string;
var
  V: string;
begin
  V := LowerCase(Trim(S));
  case V of
    'none', 'off', 'false', 'no', '0':           Result := 'none';
    'minimal', 'min':                            Result := 'minimal';
    'low':                                       Result := 'low';
    'medium', 'med', 'on', 'true', 'yes', '1':  Result := 'medium';
    'high':                                      Result := 'high';
  else
    Result := '';
  end;
end;

function RoleName(R: TMessageRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  else
    Result := 'user';
  end;
end;

function MakeMessage(R: TMessageRole; const AContent: string): TMessage;
begin
  Result.Role       := R;
  Result.Content    := AContent;
  Result.Reasoning  := '';
  Result.ToolCallId := '';
  Result.Name       := '';
  SetLength(Result.ToolCalls, 0);
end;

function EffectiveContextWindow(const Cfg: TMirmidConfig): Integer;
begin
  if (Cfg.HostContextWindow > 0) and (Cfg.HostContextWindow < Cfg.ContextWindow) then
    Result := Cfg.HostContextWindow
  else
    Result := Cfg.ContextWindow;
end;

function SummarizeThreshold(const Cfg: TMirmidConfig): Integer;
begin
  if Cfg.SummarizeThresholdTokens > 0 then
    Result := Cfg.SummarizeThresholdTokens
  else if Cfg.SummarizeThresholdPercent > 0 then
    Result := (EffectiveContextWindow(Cfg) * Cfg.SummarizeThresholdPercent + 99) div 100
  else
    Result := 0;
end;

function SummarizeMinSaving(const Cfg: TMirmidConfig): Integer;
begin
  if Cfg.SummarizeMinSavingTokens > 0 then
    Result := Cfg.SummarizeMinSavingTokens
  else if Cfg.SummarizeMinSavingPercent > 0 then
    Result := (EffectiveContextWindow(Cfg) * Cfg.SummarizeMinSavingPercent + 99) div 100
  else
    Result := 0;
end;

initialization
  { Гарантируем UTF-8 как системную кодовую страницу: иначе кириллица теряется
    при конверсиях из UTF8String/TJSONStringType. }
  DefaultSystemCodePage := CP_UTF8;

end.
