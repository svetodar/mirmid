unit mirmid.cli;
{ Командная строка, разрешение настроек и интерактивный REPL. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.types;

{ Точка входа. Возвращает код выхода (0 — успех, 1 — ошибка, 2 — usage). }
function Main: Integer;

type
  { Разобранная командная строка. }
  TCli = record
    ConfigFile, WorkDir, Prompt, PromptFile: string;
    Model, BaseUrl, ApiKey, SystemPrompt, SessionId: string;
    Reasoning: string;
    Temperature: Double;
    HasTemperature: Boolean;
    MaxSteps, MaxTokens, Timeout, ConnectTimeout, ShellTimeout, ShellOutputLimit: Integer;
    HasMaxSteps, HasMaxTokens, HasTimeout, HasConnectTimeout, HasShellTimeout, HasShellOutputLimit: Boolean;
    LoopWarn, LoopStop: Integer;
    HasLoopWarn, HasLoopStop: Boolean;
    HasReasoning: Boolean;
    McpConfig: string;
    HasMcpConfig, NoMcp, ListMcp: Boolean;
    McpTimeout: Integer;
    HasMcpTimeout: Boolean;
    { Лимит строк вывода инструментов (0 — без лимита). }
    ToolOutputLines: Integer;
    HasToolOutputLines: Boolean;
    Verbose, ShowReasoning, ShowStepResult, ShowStepTask, NoSession: Boolean;
    Stream, HasStream: Boolean;
    PlanMode, HasPlanMode: Boolean;
    Interactive, DoInit, ListModels, ListSessions: Boolean;
    ShowHelp, ShowVersion: Boolean;
    BaseUrlSet, ApiKeySet: Boolean;
  end;

{ Разбирает командную строку. Args — аргументы (без имени программы). }
function ParseCli(const Args: array of string; out Cli: TCli; out Err: string): Boolean;
{ Разрешает итоговую конфигурацию из командной строки, INI и окружения.
  Возвращает False и текст причины в Err, если конфигурация непригодна
  (например, неизвестный ключ в секции [tools]): сессия тогда не начинается. }
function ResolveConfig(const Cli: TCli; var Cfg: TMirmidConfig;
  var WorkDir: string; out Err: string): Boolean;
{ Текст справки (--help): тот же, что печатает Main. Экспортируется для
  тестов контракта командной строки. }
function UsageText: string;
{ Форматирует текст события aeStepEnd «s1: done — результат» для показа:
  укорачивает только результат (до TOOL_RESULT_MAX), заголовок сохраняет.
  При отсутствии разделителя « — » возвращает текст как есть. }
function FormatStepEnd(const Text: string): string;
{ Статус шага без результата: часть текста события aeStepEnd до разделителя
  « — » (например «s1: done»). Результат шага печатается отдельно и только по
  --show-step-result / --show-reasoning. }
function FormatStepEndStatus(const Text: string): string;
{ Префикс глубины: серый символ │, повторённый Depth раз (0 — пусто). }
function DepthPrefix(Depth: Integer): string;
{ Строка статуса контекста: «[ЧЧ:ММ:СС|текущий/общий|процент%]».
  WithTime = False — без времени (вторая часть строки статуса субагента). }
function FormatContextStatus(const Cur, Total: Integer;
  WithTime: Boolean = True): string;
{ Строка статуса в режиме под-сессии: статус основной сессии + метка
  (по умолчанию «subagent») + статус под-сессии. Время печатается только
  в первой части (часы на строку одни), часть под-сессии — без времени. }
function FormatSubAgentStatus(const MainCur, SubCur, Total: Integer;
  const LabelText: string = 'subagent'): string;
{ Строка шага плана: «[ЧЧ:ММ:СС|main/sub/total|процент-main%/процент-sub%]
  имя». Счётчики идут от основной сессии (MainCur) к под-сессии шага (Cur) и
  общему окну модели (Total), проценты считаются от Total для каждого
  счётчика отдельно. MainCur по умолчанию 0 — контекст родителя ещё не
  измерен (вызывающий передаёт его, когда есть). Статус стоит первым, имя
  шага — после него; тега [шаг] в строке нет.
  Префикс │ для под-сессии шага не нужен (глубина печати у шага нулевая). }
function FormatStepStatus(const Name: string; Cur, Total: Integer;
  MainCur: Integer = 0): string;
{ Строка предварительного анализа плана: «[ЧЧ:ММ:СС|main/sub/total|
  процент-main%/процент-sub%] анализ» — тот же порядок, что у строки шага
  (FormatStepStatus): сначала статус с контекстом основной сессии и
  под-сессии анализа, затем метка «анализ». }
function FormatAnalysisStatus(const Cur, Total: Integer;
  MainCur: Integer = 0): string;
{ Короткое имя шага для итоговой строки статуса: из «s1: описание» берётся
  только идентификатор «s1». После завершения шага описание больше не нужно,
  строка выглядит «[…] s1 done» (task1.md). Без двоеточия имя возвращается
  как есть. }
function StepShortName(const Name: string): string;
{ Печатать ли текст под-сессии шага плана (и результат шага в aeStepEnd):
  по умолчанию шаг даёт только строку статуса, текст виден при
  --show-step-result или --show-reasoning. }
{ Печатать ли задание шага плана (имя шага в aeStepStart, без тега):
  по умолчанию задание не видно, включается --show-step-task или
  --show-reasoning (при обоих off — не печатается). --show-step-result
  (ShowStepResult) к заданию не применяется: он про текст ответа и
  результат шага (StepTextVisible); параметр оставлен для единообразия
  вызова и перебора всех комбинаций флагов в тестах. }
function StepTaskVisible(ShowStepTask, ShowReasoning,
  ShowStepResult: Boolean): Boolean;
{ Решение по выводу инструментов (task2.md): вызовы инструментов
  (aeToolCall), команды shell (aeShellCommand) и их результаты (aeToolResult)
  печатаются в любой сессии — основной, субагента и под-сессиях планировщика
  («анализ», «шаг sN») — только вместе с размышлениями (--show-reasoning),
  то есть как прочий промежуточный текст. Гейтится только печать:
  FToolStack.Add/pop, FSubAgentDepth/FPrintDepth, учёт токенов и перерисовка
  строки статуса (ClearLine/DrawStatus, PrepareStaticOverStatus) выполняются
  всегда, иначе разъедется учёт контекста и перестанет распознаваться результат
  subagent. }
function StepTextVisible(ShowStepResult, ShowReasoning: Boolean): Boolean;
{ Печатать ли вывод инструментов (вызов aeToolCall, shell-команду
  aeShellCommand и результат aeToolResult) — только вместе с размышлениями:
  результат равен ShowReasoning (--show-reasoning). Сессия (основная,
  субагента, шага или анализа) роли не играет: без флага промежуточный вывод
  инструментов скрыт везде, остаются строки статуса и финальный текст. }
function ToolOutputVisible(ShowReasoning: Boolean): Boolean;

type
{ Учёт токенов для строки статуса. База — оценка размера контекста, которую
  агент присылает событием `aeContext`: перед первым запросом хода, сразу
  после добавления ответа в историю и после добавления результатов
  инструментов (у субагента — по его собственной истории и системной
  подсказке), поэтому база не отстаёт от фактического контекста. Между
  событиями к базе прибавляются токены текущего ответа, посчитанные по
  дельтам стрима. Основная сессия и субагент ведутся раздельно: события
  субагента приходят в тот же обработчик, что и события родителя. }
TContextTokens = class
private
  FMainBase: Integer;    { контекст основной сессии на момент запроса }
  FMainAccum: Integer;   { токены текущего ответа основной сессии }
  FSubBase: Integer;     { контекст под-сессии на момент её запроса }
  FSubAccum: Integer;    { токены текущего ответа под-сессии }
  { Сохранённые счётчики родительских под-сессий: «шаг плана → субагент»
    вкладываются друг в друга, и выход из внутренней не должен терять
    размер контекста внешней (иначе после субагента шаг показывал бы 0). }
  FSavedBase: array of Integer;
  FSavedAccum: array of Integer;
public
  constructor Create;
  { Новая база (событие aeContext): размер текущего контекста — перед первым
    запросом хода, после добавления ответа и результатов инструментов.
    Depth > 0 — событие под-сессии. Накопленное за ответ обнуляется: база уже
    включает только что добавленные в историю сообщения. }
  procedure SetBase(Depth, Tokens: Integer);
  { Токены пришедшей порции ответа (или размышлений). }
  procedure AddResponseTokens(Depth, Tokens: Integer);
  { Вход в под-сессию (субагент или шаг плана): текущие счётчики
    сохраняются в стеке, новые начинаются с нуля, чтобы статус не показывал
    значения предыдущей под-сессии. }
  procedure EnterSubAgent;
  { Выход из под-сессии: восстанавливает счётчики родительской под-сессии
    (например, шага, внутри которого работал субагент); при пустом стеке —
    просто обнуляет. Стек не даёт значениям внутренней сессии «протечь»
    наружу или потерять данные внешней. }
  procedure ExitSubSession;
  { Число сохранённых пар счётчиков (глубина стека): по нему OnAgentEvent
    запоминает состояние на входе в под-сессию планировщика. }
  function SavedCount: Integer;
  { Откат стека к состоянию на входе в под-сессию (Level = SavedCount,
    снятый до EnterSubAgent): снимает собственную пару сессии и лишние пары
    незакрытых вложенных под-сессий (например, субагента, чей aeToolResult
    не пришёл из-за исключения). Level вне стека — полный сброс. }
  procedure UnwindTo(Level: Integer);
  { Полный сброс счётчиков под-сессии и стека: выход из внешней под-сессии
    (шаг/анализ), в том числе после падения шага или revise_plan, не должен
    оставлять значения следующему шагу или основной сессии. }
  procedure ResetSubSession;
  { Строка статуса: Depth > 0 — основная сессия + метка (по умолчанию
    «subagent»; планировщик передаёт «шаг s1», «анализ») + под-сессия. }
  function Text(Total, Depth: Integer;
    const LabelText: string = 'subagent'): string;
  { Токены текущей под-сессии (база + накопленное за ответ) — для строки
    шага плана, которая печатает только счётчики шага, без основной сессии. }
  function SubTokens: Integer;
  { Токены основной сессии (база из её aeContext плюс накопленное за текущий
    ответ). Нужны строке шага/анализа: она печатает и контекст родителя, и
    счётчики под-сессии одновременно (формат main/sub/total). Если основной
    сессии в этом проходе не было (headless-планировщик без истории), значение
    остаётся тем, что успело прийти из aeContext, — 0 без события. }
  function MainTokens: Integer;
end;

{ Потоковый вывод текста модели в терминал: построчно (блоки кода —
  группой, таблицы — с выравниванием колонок по мере заполнения).
  Статус контекста печатается в отдельной строке под текущим текстом и
  перерисовывается при каждой порции. Частичная строка перерисовывается на
  месте, пока её рендер не шире терминала; не влезает — фиксируется как
  полная строка (перенесённую строку перерисовать на месте нельзя).
  Вне терминала статус не выводится, очистка/перерисовка отключаются: текст
  пишется приростом. }
TStreamPrinter = class
private
  FActive: Boolean;
  FLive: Boolean;          { ANSI-терминал: можно очищать/перерисовывать строку }
  FStatusShown: Boolean;   { статус сейчас напечатан в своей строке под текстом }
  FPending: string;        { текст текущей строки без перевода строки }
  FReasoningMode: Boolean; { режим рендера текущей строки: размышления/контент }
  FInCodeBlock: Boolean;   { внутри ограждённого блока кода ``` / ~~~ }
  FGroupBuf: string;       { буфер группы строк блока кода }
  FInTable: Boolean;       { внутри markdown-таблицы }
  FTableBuf: string;       { буфер строк таблицы }
  FTableOnScreen: Integer; { отрисованных строк таблицы сейчас на экране }
  FTableWide: Boolean;     { таблица шире терминала: выравнивание брошено }
  FTableRawPrinted: Integer; { строк буфера, напечатанных в «сыром» режиме }
  FPendingOnScreen: Boolean; { частичный текст виден в строке над статусом }
  FPrefix: string;           { префикс для каждой печатаемой строки (отступ по глубине) }
  { Разделитель между блоками вывода (task1.md): запрошенная пустая строка
    печатается лениво — в начале следующего блока (PrepareStatic/PersistStatus),
    после стирания строки статуса. Иначе строка статуса заняла бы её место, и
    после стирания статуса разделителя на экране не осталось бы. }
  FBlankPending: Boolean;    { запрошена пустая строка перед следующим блоком }
  FBlankSeparated: Boolean;  { последний PrepareStatic/PersistStatus её напечатал }
  procedure EmitPendingBlank;
  procedure ClearLine;
  procedure ClearAbove;
  procedure PrintStatus(const Status: string);
  function RenderLine(const L: string): string;
  { Видимая ширина отрендеренной строки (для переноса по словам). }
  function MeasureRendered(const S: string): Integer;
  { Ширина, доступная тексту в строке: ширина терминала минус видимая
    ширина префикса глубины. Перенос и очистка строки рассчитаны на то,
    что напечатанная строка (префикс + текст) занимает ровно одну строку
    терминала; без вычета префикса частичная строка субагента переполняла
    строку, переносилась на вторую и перерисовка теряла/дублировала слова. }
  function ContentWidth: Integer;
  { Разрешение разрыва: не внутри инлайн-разметки. }
  function BreakSafe(const Pfx: string): Boolean;
  function PendingText: string;
  procedure EmitCompleteLine(const L: string);
  procedure ShowPartial;
  procedure EmitGroup(const G: string);
  procedure FlushCodeBlock;
  procedure ShowTable;
  procedure FlushTable;
  procedure ProcessContentLine(const L: string; var Emitted: Boolean);
  procedure FeedRaw(const Delta: string);
  { Добавляет FPrefix к началу каждой строки (в т.ч. многострочной). }
  function ApplyPrefix(const S: string): string;
public
  constructor Create;
  destructor Destroy; override;
  property Active: Boolean read FActive;
  property Live: Boolean read FLive write FLive;
  { Префикс, добавляемый к началу каждой печатаемой строки. }
  property Prefix: string read FPrefix write FPrefix;
  { Начало стрима: новая строка и статус. }
  procedure BeginStream(const Status: string);
  { Порция текста размышлений / ответа модели. }
  procedure FeedReasoning(const Delta, Status: string);
  procedure FeedContent(const Delta, Status: string);
  { Конец стрима: допечатать незавершённую строку/блок кода, затем стереть
    временную строку статуса, чтобы следующий вывод (приглашение REPL,
    статичный текст) начался с начала строки, а не приклеился к ней. }
  procedure EndStream(const Status: string);
  { Подготовка к статичной печати (инструменты, ошибки, приглашение):
    при необходимости переводит курсор на новую строку под статусом. }
  procedure PrepareStatic;
  { То же, но нарисованная строка статуса не фиксируется в scrollback:
    остатки стрима дописываются, статус стирается, и статичная строка
    (результат инструмента) печатается на его месте. Вызывающий затем рисует
    статус заново под ней (DrawStatus) — старый вариант с меньшими счётчиками
    не остаётся строкой выше. Вне ANSI-терминала статуса нет, поведение как
    у PrepareStatic. }
  procedure PrepareStaticOverStatus;
  { Запросить пустую строку-разделитель перед следующим блоком вывода
    (task1.md): результат инструмента отделяется от следующего блока
    информации. Печатается лениво и один раз — в начале следующего блока
    (PrepareStatic/PersistStatus), уже после стирания строки статуса: иначе
    статус занял бы её место, а после стирания статуса пустой строки на экране
    не осталось бы. }
  procedure RequestBlankLine;
  { Напечатал ли последний PrepareStatic/PersistStatus пустую строку по
    RequestBlankLine. Нужно вызывающим, которые сами печатают пустую строку
    перед своим блоком (aeAssistant, aeReport): вторая была бы лишней. }
  property BlankSeparated: Boolean read FBlankSeparated;
  { Завершение строки статуса (завершённая под-сессия планировщика): строка
    статуса полностью временная и в лог не попадает — она стирается, а не
    печатается в scrollback. Вне терминала молчит (статус там не печатается
    вовсе). }
  procedure FreezeStatus(const Status: string);
  { Перерисовать строку статуса без вывода текста: порция ответа (например,
    размышлений) учтена в счётчиках, но её текст скрыт настройкой. Вне
    терминала (статус там не печатается) молчит. }
  procedure RefreshStatus(const Status: string);
  { Нарисовать строку статуса заново без вывода текста: очищает текущую строку
    и печатает статус. В отличие от RefreshStatus не требует активного стрима
    (FActive) — вызывается и после статичной печати (строка вызова инструмента,
    shell-команда), чтобы строка статуса не пропадала из-под вывода. Вне
    ANSI-терминала молчит: ClearLine/PrintStatus не работают. }
  procedure DrawStatus(const Status: string);
  { Зафиксировать строку статуса в логе (конец хода): нарисованная временная
    строка заменяется итоговым текстом и завершается переводом строки, поэтому
    статус остаётся на экране, а следующий вывод (приглашение REPL, статичные
    строки) идёт под ней с чистой строки. Вне ANSI-терминала молчит: строки
    статуса там нет вовсе (в нестриминговом режиме main-статус печатает
    TMirmidApp.PrintContextStatus, done-строку под-сессии —
    TMirmidApp.PersistDoneStatus). }
  procedure PersistStatus(const Status: string);
end;

implementation

uses
  SysUtils, Classes,
  mirmid.util, mirmid.config, mirmid.tools, mirmid.subagent,
  mirmid.llm, mirmid.agent, mirmid.session, mirmid.plan, mirmid.planner, mirmid.version,
  mirmid.markdown, mirmid.mcp, mirmid.summarize, mirmid.http,
  mirmid.tlsclient;

type
  { Отметка входа в под-сессию планировщика (анализ, шаг плана). При выходе
    по ней восстанавливаются глубина, метка и стек счётчиков, а всё, что
    накопилось внутри (включая незакрытого субагента), отбрасывается. }
  TSubSessionMark = record
    Depth: Integer;       { FSubAgentDepth до входа }
    PrintDepth: Integer;  { FPrintDepth до входа }
    LabelText: string;    { метка родительской под-сессии }
    Saved: Integer;       { FTokens.SavedCount до входа }
  end;

  TMirmidApp = class
  private
    FCfg: TMirmidConfig;
    FReg: TToolRegistry;
    FAgent: TAgent;
    FSessionId: string;
    FNoSession: Boolean;
    FShowReasoning: Boolean;
    FShowStepTask: Boolean;       { печатать задание шага плана перед его
                                    работой (--show-step-task) }
    FShowStepResult: Boolean;     { печатать текст/результат шага плана
                                    (--show-step-result) }
    FPrinter: TStreamPrinter;
    FToolStack: TStringList;      { стек имён инструментов: push при
                                    aeToolCall/aeShellCommand, pop при
                                    aeToolResult. Позволяет распознать
                                    результат subagent, даже если сам
                                    субагент вызывал инструменты — его
                                    события идут через тот же обработчик. }
    FMcp: TMCPManager;            { подключённые MCP-серверы (может быть nil) }
    FPlanner: TPlanner;           { планировщик (режим планирования, может быть nil) }
    FSubAgentDepth: Integer;      { глубина учёта токенов: растёт и на
                                    инструменте subagent, и на под-сессии
                                    планировщика (анализ, шаг плана) }
    FPrintDepth: Integer;         { глубина префикса печати «│»: растёт только
                                    на инструменте subagent, поэтому под-сессии
                                    планировщика идут без отступа, а субагент
                                    внутри шага — с одним «│» }
    FSubAgentLabel: string;       { метка текущей под-сессии планировщика
                                    («анализ», «шаг s1»); пусто — «subagent» }
    FCurrentStepName: string;     { имя текущего шага плана — текст aeStepStart
                                    («s1: обновить README»); пусто — вне шага.
                                    Нужно строке статуса шага (FormatStepStatus):
                                    в aeSubSessionStart приходит только «шаг s1». }
    { Отметки входа в под-сессии планировщика: при выходе, в том числе по
      исключению (падение шага) или revise_plan, глубина, метка и счётчики
      возвращаются к состоянию на входе. }
    FSubSessionMarks: array of TSubSessionMark;
    FTokens: TContextTokens;      { учёт токенов для строки статуса }
    { Кэш оценки контекста основной сессии (FAgent.ContextTokens) на момент
      последнего обновления. В режиме планирования основной ход ведёт
      планировщик, и его под-сессии (анализ, шаг) обращаются к модели сами:
      aeContext с глубиной 0 в это время не приходит, а строке шага/анализа
      нужно значение main для формата main/sub/total. Обновляется перед
      запросом (в т.ч. из aeContext основной сессии), после хода и при сбросе
      истории — на каждой порции стрима пересчитывать историю было бы слишком
      дорого. }
    FMainContext: Integer;
    FLastSummarizeEffective: Boolean; { была ли последняя суммаризация эффективной }
    { Число сообщений, уже отражённых в журнале контекста: по нему считается
      «part» очередной записи журнала (токены добавленной части контекста). }
    FJournalMsgs: Integer;
    FLastSummarizeSaving: Integer;    { уменьшение токенов при последней суммаризации }
    { Пересчитывает FMainContext оценкой агента по его истории и схемам
      инструментов (TAgent.ContextTokens). }
    procedure UpdateMainContext;
    { Контекст основной сессии для строки статуса: свежий кэш, а если оценка
      ещё не снималась — база из aeContext (MainTokens). }
    function MainContextTokens: Integer;
    function StatusText: string;
    { Строка статуса под-сессии шага плана: «[ЧЧ:ММ:СС|main/sub/total|
      процент-main%/процент-sub%] имя» (см. FormatStepStatus). Счётчики —
      контекст основной сессии (MainContextTokens), шага (SubTokens) и общее
      окно модели. }
    function StepStatusText: string;
    { Строка статуса, закрепляемая в логе после выхода из под-сессии
      (task1.md: «…] анализ done», «…] s1 done»). Счётчики снимаются до
      отката глубины, поэтому числа — итог завершившейся под-сессии; метка
      шага берётся короткой (StepShortName), без описания задания. Вне
      под-сессии шага/анализа возвращает обычный StatusText. }
    function DoneStatusText: string;
    { Закрепить done-строку завершённой под-сессии одинаково во всех режимах:
      в ANSI-терминале её фиксирует принтер потока (PersistStatus), в консоли
      без VT-режима и в нестриминговом режиме (строки статуса на экране не
      было) она печатается статично, как main-статус после хода
      (PrintContextStatus). Headless/перенаправленный вывод молчит: статуса
      там нет вовсе. }
    procedure PersistDoneStatus;
    { Идёт ли под-сессия шага плана (метка «шаг sN» и имя шага из
      aeStepStart). Текст такой сессии — ответ шага: по умолчанию он
      скрыт, печатается только по --show-step-result/--show-reasoning.
      Вложенный субагент внутри шага тоже попадает под условие. }
    function InStepSubSession: Boolean;
    { Строка статуса контекста после хода — для нестримингового режима
      (в стриме её рисует принтер потока). }
    procedure PrintContextStatus;
    procedure OnAgentEvent(Kind: TAgentEventKind; const Text: string);
    { План изменился — сохранить сессию. }
    procedure OnPlanChanged;
    procedure LoadMcp;
    procedure Repl;
    procedure LoadOrNewSession(out Plan: TPlan);
    procedure SaveCurrentSession;
    function RunOne(const Prompt: string): Integer;
    procedure KeepContextStatus;
    { Суммаризация текущей сессии: создаёт новую сессию с резюме. }
    procedure DoSummarize;
    { Авто-суммаризация: проверяет порог заполнения контекста. }
    procedure CheckAutoSummarize;
    { Запрашивает у хоста (LLM-сервера) контекст модели. }
    procedure FetchHostContext;
  public
    constructor Create(const ACfg: TMirmidConfig);
    destructor Destroy; override;
    property SessionId: string read FSessionId;
    property NoSession: Boolean read FNoSession write FNoSession;
    property ShowReasoning: Boolean read FShowReasoning write FShowReasoning;
    property ShowStepTask: Boolean read FShowStepTask write FShowStepTask;
    property ShowStepResult: Boolean read FShowStepResult write FShowStepResult;
    function Execute(const Cli: TCli): Integer;
  end;

const
  USAGE =
    'mirmid ' + MIRMID_VERSION + ' — харнесс ИИ-агента на Free Pascal' + sLineBreak +
    '' + sLineBreak +
    'Использование:' + sLineBreak +
    '  mirmid [опции] ["запрос"]' + sLineBreak +
    '  mirmid -i ["запрос"]    интерактивный режим (запрос — первый ход, затем цикл)' + sLineBreak +
    '' + sLineBreak +
    'Модель и подключение:' + sLineBreak +
    '  -m, --model NAME        имя модели' + sLineBreak +
    '      --base-url URL      базовый URL OpenAI-совместимого API' + sLineBreak +
    '      --api-key KEY       ключ API (или &ИМЯ переменной окружения с ним)' + sLineBreak +
    '      --list-models       запросить список моделей у API (с деталями, если провайдер их сообщает)' + sLineBreak +
    '' + sLineBreak +
    'Агент:' + sLineBreak +
    '      --system TEXT       системная подсказка' + sLineBreak +
    '      --loop-warn N       предупреждение при N подряд одинаковых вызовах инструмента (0 — выкл., по умолчанию 3)' + sLineBreak +
    '      --loop-stop N       остановка при N подряд одинаковых вызовах инструмента (0 — выкл., по умолчанию 5)' + sLineBreak +
    '      --max-steps N       предел шагов модель→инструменты (0 — без ограничений, по умолчанию 0)' + sLineBreak +
    '      --plan              режим планирования: план → шаги → отчёт (по умолчанию выкл.)' + sLineBreak +
    '      --no-plan           выключить режим планирования' + sLineBreak +
    '      --max-tokens N      максимум токенов ответа (по умолчанию 32768)' + sLineBreak +
    '      --temperature T     температура (по умолчанию 0.1)' + sLineBreak +
    '      --reasoning [MODE]  reasoning_effort: none|minimal|low|medium|high' + sLineBreak +
    '                          (без MODE и без значения — medium)' + sLineBreak +
    '      --no-reasoning      синоним --reasoning none' + sLineBreak +
    '      --timeout SEC       таймаут HTTP-запроса (по умолчанию 1800)' + sLineBreak +
    '      --show-reasoning    печатать reasoning_content модели и вывод инструментов' + sLineBreak +
    '      --show-step-task    печатать задание шага плана перед его работой (по умолчанию нет)' + sLineBreak +
    '      --show-step-result  печатать результат каждого шага плана (по умолчанию нет)' + sLineBreak +
    '      --stream            потоковый вывод ответа модели (по умолчанию вкл.)' + sLineBreak +
    '      --no-stream         печатать весь ответ после завершения запроса' + sLineBreak +
    '' + sLineBreak +
    'Инструменты:' + sLineBreak +
    '      набор инструментов задаётся секцией [tools] файла mirmid.ini:' + sLineBreak +
    '      по одному ключу 1/0 на инструмент (см. mirmid --init)' + sLineBreak +
     '      --shell-timeout S   таймаут команды в секундах (по умолчанию 60)' + sLineBreak +
     '      --tool-output-lines N  максимум строк вывода инструмента (по умолчанию 9, середина сокращается, 0 — без ограничения)' + sLineBreak +
     '      --shell-output-limit N  максимум вывода shell в байтах (по умолчанию 65536, 0 — без ограничения)' + sLineBreak +
    '' + sLineBreak +
    'MCP (Model Context Protocol):' + sLineBreak +
    '      --mcp-config FILE   файл mcp.json с описанием серверов' + sLineBreak +
    '      --no-mcp            не подключать MCP-серверы' + sLineBreak +
    '      --mcp-timeout SEC   таймаут ответа MCP-сервера (по умолчанию 60)' + sLineBreak +
    '      --list-mcp          показать MCP-серверы и их инструменты' + sLineBreak +
    '' + sLineBreak +
    'Сессии и прочее:' + sLineBreak +
    '  -s, --session ID        продолжить/создать сессию с указанным ID' + sLineBreak +
    '      --list-sessions     показать сохранённые сессии' + sLineBreak +
    '      --no-session        не сохранять диалог' + sLineBreak +
    '  -c, --config FILE       файл конфигурации' + sLineBreak +
    '      --workdir DIR       рабочая папка инструментов' + sLineBreak +
    '      --prompt-file FILE  прочитать запрос из файла' + sLineBreak +
    '      --init              создать ./.mirmid/mirmid.ini с настройками' + sLineBreak +
    '  -v, --verbose           подробный вывод' + sLineBreak +
    '  -V, --version           версия' + sLineBreak +
    '  -h, --help              эта справка';

function UsageText: string;
begin
  Result := USAGE;
end;

function Shorten(const S: string; MaxLen: Integer): string;
begin
  if (MaxLen <= 0) or (Length(S) <= MaxLen) then
    Exit(S);
  { TruncateUTF8 не разрешает резать многобайтовый символ: иначе в вывод
    и в тело запроса к API попадают «битые» UTF-8 байты. }
  Result := TruncateUTF8(S, MaxLen) + '…';
end;

{ --------------------------------------------------------------- colors }

const
  { ANSI-коды цветов (SGR) для тегов на экране. }
  C_STEP       = '36';        { голубой — шаг плана }
  C_REASONING  = '38;5;101';  { зеленосерый — текст размышлений модели }
  C_TOOLCALL   = '33';        { жёлтый — тег с именем инструмента }
  C_TOOLTEXT   = '38;5;250';  { светлосерый — параметры инструментов (json) }
  C_SHELLCMD   = '94';        { ярко-синий — команда shell-инструмента }
  C_STATUS     = '31';        { красный — строка статуса контекста }
  C_RESULT     = '32';        { зелёный — тег [результат] }
  C_USAGE      = '90';        { серый — статистика токенов }
  C_ERROR      = '31';        { красный — Ошибка: }
  C_WARN       = '33';        { жёлтый — Предупреждение: }
  C_PROMPT     = '36';        { голубой — приглашение REPL }

  ESC = #27;                  { ESC-символ для ANSI-последовательностей }

  { Максимальная длина текста результата инструмента на экране; результат
    subagent печатается полностью (это финальный ответ отдельной сессии). }
  TOOL_RESULT_MAX = 400;

{ Разделитель « — » (пробел + тире + пробел) в UTF-8 занимает 5 байт.
  Позиция результата после Pos — P + Length(' — '), а не P + 3: иначе
  копирование начинается внутри многобайтового тире и в вывод попадает
  «битый» байт. }
function FormatStepEnd(const Text: string): string;
var
  P: Integer;
  Sep: string;
begin
  Sep := ' — ';
  P := Pos(Sep, Text);
  if P > 0 then
    Result := Copy(Text, 1, P - 1) + Sep +
      Shorten(Copy(Text, P + Length(Sep), MaxInt), TOOL_RESULT_MAX)
  else
    Result := Text;
end;

{ Статус шага без результата: текст события aeStepEnd до разделителя « — ».
  Сам результат печатает aeStepEnd, только если включён --show-step-result
  или --show-reasoning: иначе от шага остаётся лишь строка «s1: done». }
function FormatStepEndStatus(const Text: string): string;
var
  P: Integer;
  Sep: string;
begin
  Sep := ' — ';
  P := Pos(Sep, Text);
  if P > 0 then
    Result := Copy(Text, 1, P - 1)
  else
    Result := Text;
end;

{ Префикс глубины: серый символ │, повторённый Depth раз (0 — пусто). }
function DepthPrefix(Depth: Integer): string;
var
  I: Integer;
  S: string;
begin
  if Depth <= 0 then
    Exit('');
  S := '';
  for I := 1 to Depth do
    S := S + '│';
  Result := Colored(C_USAGE, S);
end;

{ Печатает сообщение об ошибке в StdErr с красным префиксом. }
procedure WriteError(const Text: string);
begin
  WriteLn(StdErr, Colored(C_ERROR, 'Ошибка:', 2), ' ', Text);
end;

{ Печатает предупреждение в StdErr с жёлтым префиксом. }
procedure WriteWarning(const Text: string);
begin
  WriteLn(StdErr, Colored(C_WARN, 'Предупреждение:', 2), ' ', Text);
end;

{ --------------------------------------------------------------- parsing }

function SplitOpt(const Arg: string; out Name, Inline: string): Boolean;
var
  P: Integer;
begin
  Result := (Length(Arg) > 1) and (Arg[1] = '-');
  Name := Arg;
  Inline := '';
  if not Result then
    Exit;
  P := Pos('=', Arg);
  if P > 0 then
  begin
    Name := Copy(Arg, 1, P - 1);
    Inline := Copy(Arg, P + 1, MaxInt);
  end;
end;

{ Похож ли аргумент на режим рассуждений: --reasoning без значения не должен
  съедать следующий за ним запрос. }
function IsReasoningToken(const S: string): Boolean;
begin
  Result := NormalizeReasoning(S) <> '';
end;

{ Достаёт значение опции: либо inline (--opt=value), либо следующий аргумент.
  Меняет I, если взял следующий аргумент. }
function TakeValue(const Args: array of string; var I: Integer; const Opt, Inline: string;
  out Value: string; out Err: string): Boolean;
begin
  Err := '';
  if Inline <> '' then
  begin
    Value := Inline;
    Exit(True);
  end;
  if I >= Length(Args) then
  begin
    Err := 'опция ' + Opt + ' требует значения';
    Exit(False);
  end;
  Inc(I);
  Value := Args[I - 1];
  Result := True;
end;

function ParseCli(const Args: array of string; out Cli: TCli; out Err: string): Boolean;
var
  I: Integer;
  A, Name, Inline, V: string;
  EndOpts: Boolean;
begin
  FillChar(Cli, SizeOf(Cli), 0);
  Cli.Temperature := 0;
  Err := '';
  EndOpts := False;
  I := 1;
  while I <= Length(Args) do
  begin
    A := Args[I - 1];
    if (not EndOpts) and (A = '--') then
    begin
      EndOpts := True;
      Inc(I);
      Continue;
    end;
    if (not EndOpts) and SplitOpt(A, Name, Inline) then
    begin
      if (Name = '-h') or (Name = '--help') then
        Cli.ShowHelp := True
      else if (Name = '-V') or (Name = '--version') then
        Cli.ShowVersion := True
      else if (Name = '-i') or (Name = '--interactive') then
        Cli.Interactive := True
      else if Name = '--no-mcp' then
        Cli.NoMcp := True
      else if Name = '--list-mcp' then
        Cli.ListMcp := True
      else if Name = '--mcp-config' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.McpConfig := V;
        Cli.HasMcpConfig := True;
      end
      else if Name = '--mcp-timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.McpTimeout := StrToIntDef(V, DEFAULT_MCP_TIMEOUT);
        Cli.HasMcpTimeout := True;
      end
      else if (Name = '-v') or (Name = '--verbose') then
        Cli.Verbose := True
      else if Name = '--show-reasoning' then
        Cli.ShowReasoning := True
      else if Name = '--show-step-result' then
        Cli.ShowStepResult := True
      else if Name = '--show-step-task' then
        Cli.ShowStepTask := True
      else if Name = '--stream' then
      begin
        Cli.Stream := True;
        Cli.HasStream := True;
      end
      else if Name = '--no-stream' then
      begin
        Cli.Stream := False;
        Cli.HasStream := True;
      end
      else if Name = '--plan' then
      begin
        Cli.PlanMode := True;
        Cli.HasPlanMode := True;
      end
      else if Name = '--no-plan' then
      begin
        Cli.PlanMode := False;
        Cli.HasPlanMode := True;
      end
      else if Name = '--reasoning' then
      begin
        V := Inline;
        if (V = '') and (I < Length(Args)) and IsReasoningToken(Args[I]) then
        begin
          Inc(I);
          V := Args[I - 1];
        end;
        if V = '' then
          Cli.Reasoning := 'medium'
        else
          Cli.Reasoning := NormalizeReasoning(V);
        if (V <> '') and (Cli.Reasoning = '') then
        begin
          Err := 'неизвестный режим рассуждений: ' + V +
            ' (none, minimal, low, medium, high)';
          Exit(False);
        end;
        Cli.HasReasoning := True;
      end
      else if Name = '--no-reasoning' then
      begin
        Cli.Reasoning := 'none';
        Cli.HasReasoning := True;
      end
      else if Name = '--no-session' then
        Cli.NoSession := True
      else if Name = '--init' then
        Cli.DoInit := True
      else if Name = '--list-models' then
        Cli.ListModels := True
      else if Name = '--list-sessions' then
        Cli.ListSessions := True
      else if (Name = '-m') or (Name = '--model') then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.Model := V;
      end
      else if Name = '--base-url' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.BaseUrl := V;
        Cli.BaseUrlSet := True;
      end
      else if Name = '--api-key' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ApiKey := V;
        Cli.ApiKeySet := True;
      end
      else if (Name = '-c') or (Name = '--config') then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ConfigFile := V;
      end
      else if (Name = '-s') or (Name = '--session') then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.SessionId := V;
      end
      else if Name = '--system' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.SystemPrompt := V;
      end
      else if Name = '--prompt-file' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.PromptFile := V;
      end
      else if Name = '--workdir' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.WorkDir := V;
      end
      else if Name = '--max-steps' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.MaxSteps := StrToIntDef(V, 0);
        Cli.HasMaxSteps := True;
      end
      else if Name = '--loop-warn' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.LoopWarn := StrToIntDef(V, 0);
        Cli.HasLoopWarn := True;
      end
      else if Name = '--loop-stop' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.LoopStop := StrToIntDef(V, 0);
        Cli.HasLoopStop := True;
      end
      else if Name = '--max-tokens' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.MaxTokens := StrToIntDef(V, 0);
        Cli.HasMaxTokens := True;
      end
      else if Name = '--temperature' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.Temperature := DotToFloat(V, 0);
        Cli.HasTemperature := True;
      end
      else if Name = '--timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.Timeout := StrToIntDef(V, 0);
        Cli.HasTimeout := True;
      end
      else if Name = '--connect-timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ConnectTimeout := StrToIntDef(V, 0);
        Cli.HasConnectTimeout := True;
      end
      else if Name = '--shell-timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ShellTimeout := StrToIntDef(V, 0);
        Cli.HasShellTimeout := True;
      end
      else if Name = '--shell-output-limit' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ShellOutputLimit := StrToIntDef(V, 0);
        Cli.HasShellOutputLimit := True;
      end
      else if Name = '--tool-output-lines' then
      begin
        // максимальное число строк вывода инструментов (0 — без лимита)
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ToolOutputLines := StrToIntDef(V, 0);
        Cli.HasToolOutputLines := True;
      end
      else
      begin
        Err := 'неизвестная опция: ' + A;
        Exit(False);
      end;
    end
    else
    begin
      if Cli.Prompt = '' then
        Cli.Prompt := A
      else
        Cli.Prompt := Cli.Prompt + ' ' + A;
    end;
    Inc(I);
  end;
  Result := True;
end;

function FindConfigFile(const Explicit, WorkDir: string): string;
begin
  if Explicit <> '' then
    Exit(Explicit);
  Result := ProjectConfigPath(WorkDir);
  if FileExists(Result) then
    Exit;
  Result := '';
end;

function ResolveConfig(const Cli: TCli; var Cfg: TMirmidConfig;
  var WorkDir: string; out Err: string): Boolean;
var
  ErrText: string;
begin
  Err := '';
  Result := True;
  if WorkDir = '' then
    WorkDir := GetCurrentDir;
  WorkDir := ExpPath(WorkDir, GetCurrentDir);
  Cfg := DefaultConfig;
  Cfg.WorkDir := WorkDir;

  { Неизвестный ключ в [tools] — фатальная ошибка: опечатка не должна молча
    оставить инструмент со значением по умолчанию. Исключение — `--init`: он
    как раз и нужен, чтобы починить сломанный файл, поэтому образец строится из
    умолчаний и переопределений командной строки, а причина разбора не выводится. }
  ErrText := '';
  if not LoadIni(FindConfigFile(Cli.ConfigFile, WorkDir), Cfg, ErrText) then
  begin
    if not Cli.DoInit then
    begin
      Err := ErrText;
      Exit(False);
    end;
  end;

  ApplyEnv(Cfg);

  if Cli.HasTemperature then Cfg.Temperature := Cli.Temperature;
  if Cli.HasReasoning then Cfg.Reasoning := Cli.Reasoning;
  if Cli.Model <> '' then Cfg.Model := Cli.Model;
  if Cli.SystemPrompt <> '' then Cfg.SystemPrompt := Cli.SystemPrompt;
  if Cli.HasMaxSteps then Cfg.MaxSteps := Cli.MaxSteps;
  if Cli.HasMaxTokens then Cfg.MaxTokens := Cli.MaxTokens;
  if Cli.HasTimeout then Cfg.RequestTimeout := Cli.Timeout * 1000;
  if Cli.HasConnectTimeout then Cfg.ConnectTimeout := Cli.ConnectTimeout * 1000;
  if Cli.HasShellTimeout then Cfg.ShellTimeout := Cli.ShellTimeout;
  if Cli.HasShellOutputLimit then Cfg.ShellOutputLimit := Cli.ShellOutputLimit;
  { Лимит строк вывода инструментов: 0 — без лимита (значение из CLI важнее INI/окружения). }
  if Cli.HasToolOutputLines then Cfg.ToolOutputLines := Cli.ToolOutputLines;
  if Cli.HasLoopWarn then Cfg.LoopWarn := Cli.LoopWarn;
  if Cli.HasLoopStop then Cfg.LoopStop := Cli.LoopStop;
  if Cli.NoMcp then Cfg.McpEnabled := False;
  if Cli.HasMcpConfig then Cfg.McpConfig := ExpPath(Cli.McpConfig, WorkDir);
  if Cli.HasMcpTimeout then Cfg.McpTimeout := Cli.McpTimeout;
  if Cli.HasStream then Cfg.Stream := Cli.Stream;
  if Cli.HasPlanMode then Cfg.PlanMode := Cli.PlanMode;
  if Cli.Verbose then Cfg.Verbose := True;
  if Cli.BaseUrlSet then Cfg.BaseUrl := Cli.BaseUrl;
  if Cli.ApiKeySet then Cfg.ApiKey := Cli.ApiKey;
  { api_key может быть ссылкой на переменную окружения — только с префиксом
    «&» (&MY_API_KEY). Исходное значение сохраняем в ApiKeyRaw: --init пишет
    его в новый INI, чтобы развёрнутый ключ не попадал в файл. }
  Cfg.ApiKeyRaw := Cfg.ApiKey;
  Cfg.ApiKey := ResolveApiKey(Cfg.ApiKey);
  { HTTPS-доверие: встроенный в exe снимок корней (tls.roots), а при его
    отсутствии — системное хранилище ОС. Настраивать здесь нечего, поэтому в
    INI нет ключа с путём к PEM-бандлу, а в окружении — переменной с ним. }
end;

{ Состояние встроенного снимка корней TLS (tls.roots) для пользователя: дата
  снимка и признак устаревания. Вызывается один раз при старте — до первого
  HTTPS-запроса (провайдер LLM, инструмент http_request), поэтому в лог не
  попадает повторно на каждое соединение. }
procedure WarnEmbeddedRoots(const Cfg: TMirmidConfig);
var
  Info: TEmbeddedRootsInfo;
begin
  Info := GetEmbeddedRootsInfo;
  if not Info.Available then
  begin
    { Запасное системное хранилище есть только на Windows (CryptoAPI), поэтому
      там молчим (если не -v): иначе каждая сборка без tlsroots.res пугала бы
      пользователя без причины. На прочих платформах без снимка проверять
      цепочку нечем — предупреждаем сразу, а не при первом запросе. }
    {$ifdef windows}
    if Cfg.Verbose then
      WriteWarning(EmbeddedRootsInfoText(Info) +
        '; используется системное хранилище Windows');
    {$else}
    WriteWarning(EmbeddedRootsInfoText(Info) +
      '; HTTPS-запросы завершатся ошибкой хранилища доверия');
    {$endif}
    Exit;
  end;
  if Info.Stale then
    WriteWarning(EmbeddedRootsInfoText(Info) +
      ' — обновите библиотеку tls (make roots)')
  else if Cfg.Verbose then
    { Снимок свежий: дата интересна только в подробном режиме. }
    WriteLn(StdErr, 'TLS: ', EmbeddedRootsInfoText(Info));
end;

{ --------------------------------------------------------------- streaming UI }

{ Короткая запись числа: 12345 → «12.3k», 128000 → «128k».
  Целочисленная арифметика — десятичная точка не зависит от локали. }
function CompactNumber(V: Integer): string;
var
  Tenth: Int64;   { значение в десятых долях: 12345 → 123 (≈12.3) }
begin
  if V >= 1000 then
  begin
    Tenth := (Int64(V) * 10 + 500) div 1000;   { округление до 0.1 }
    if Tenth mod 10 = 0 then
      Result := IntToStr(Tenth div 10) + 'k'
    else
      Result := IntToStr(Tenth div 10) + '.' + IntToStr(Tenth mod 10) + 'k';
  end
  else
    Result := IntToStr(V);
end;

{ Процент от общего окна в десятых: 123 из 128000 → «0.1%». По одному
  проценту на счётчик: строка шага печатает два — для основной сессии и для
  под-сессии. Целочисленная арифметика — точка не зависит от локали. }
function PercentText(Cur, Total: Integer): string;
var
  Tenth: Int64;   { процент в десятых долях }
begin
  if Total <= 0 then
    Exit('?');
  Tenth := (Int64(Cur) * 1000 + Int64(Total) div 2) div Int64(Total);
  Result := IntToStr(Tenth div 10) + '.' + IntToStr(Tenth mod 10) + '%';
end;

{ Строка статуса контекста: «[ЧЧ:ММ:СС|текущий/общий|процент%]». Время —
  локальное (hh:mm:ss, не зависит от локали); процент — целочисленное округление
  до 0.1 (PercentText), точка не зависит от локали. WithTime = False — без
  времени. }
function FormatContextStatus(const Cur, Total: Integer;
  WithTime: Boolean): string;
var
  TimePart: string;
begin
  if WithTime then
    TimePart := FormatDateTime('hh:nn:ss', Now) + '|'
  else
    TimePart := '';
  if Total <= 0 then
    Exit('[' + TimePart + CompactNumber(Cur) + '/?|?]');
  Result := '[' + TimePart + CompactNumber(Cur) + '/' +
            CompactNumber(Total) + '|' + PercentText(Cur, Total) + ']';
end;

{ Строка статуса под-сессии: статус основной сессии, метка (по умолчанию
  «subagent», для шагов плана — «шаг s1», «анализ») и статус самой
  под-сессии. Время печатает только первая часть: часов на строку
  достаточно одних, вторая часть — без даты и времени. }
function FormatSubAgentStatus(const MainCur, SubCur, Total: Integer;
  const LabelText: string): string;
begin
  Result := Colored(C_STATUS, FormatContextStatus(MainCur, Total)) + ' ' +
    Colored(C_USAGE, LabelText) + ' ' +
    Colored(C_STATUS, FormatContextStatus(SubCur, Total, False));
end;

{ Строка контекста под-сессии планировщика: «[ЧЧ:ММ:СС|main/sub/total|
  процент-main%/процент-sub%]». Первым идёт контекст основной сессии, затем
  под-сессии (шага или анализа), затем общее окно модели; проценты считаются
  от одного и того же окна, поэтому их два. Часы на строку одни. }
function FormatStepContextStatus(const MainCur, SubCur, Total: Integer): string;
begin
  if Total <= 0 then
    Exit('[' + FormatDateTime('hh:nn:ss', Now) + '|' +
      CompactNumber(MainCur) + '/' + CompactNumber(SubCur) + '/?|?/?]');
  Result := '[' + FormatDateTime('hh:nn:ss', Now) + '|' +
    CompactNumber(MainCur) + '/' + CompactNumber(SubCur) + '/' +
    CompactNumber(Total) + '|' + PercentText(MainCur, Total) + '/' +
    PercentText(SubCur, Total) + ']';
end;

{ Строка шага плана: «[ЧЧ:ММ:СС|main/sub/total|процент-main%/процент-sub%]
  имя». Статус красный (C_STATUS), имя — серое (C_USAGE); тега [шаг] нет,
  статус идёт первым. Контекст основной сессии (MainCur) идёт сразу перед
  контекстом шага (Cur) — см. FormatStepContextStatus. }
function FormatStepStatus(const Name: string; Cur, Total: Integer;
  MainCur: Integer): string;
begin
  Result := Colored(C_STATUS, FormatStepContextStatus(MainCur, Cur, Total));
  if Name <> '' then
    Result := Result + ' ' + Colored(C_USAGE, Name);
end;

{ Строка предварительного анализа плана: «[ЧЧ:ММ:СС|main/sub/total|
  процент-main%/процент-sub%] анализ». Порядок как у строки шага
  (FormatStepStatus): статус красный (C_STATUS) первым, затем серая
  (C_USAGE) метка «анализ»; тега [анализ] в строке статуса нет. }
function FormatAnalysisStatus(const Cur, Total: Integer;
  MainCur: Integer): string;
begin
  Result := Colored(C_STATUS, FormatStepContextStatus(MainCur, Cur, Total)) +
    ' ' + Colored(C_USAGE, 'анализ');
end;

{ Короткое имя шага для итоговой строки статуса: из «s1: описание» берётся
  только идентификатор «s1» (обрезка и пробелы по краям). В строке шага
  описание нужно, в закреплённой строке «s1 done» — нет (task1.md).
  Без двоеточия имя возвращается как есть, пустое — пустым. }
function StepShortName(const Name: string): string;
var
  P: Integer;
begin
  P := Pos(':', Name);
  if P > 0 then
    Result := Trim(Copy(Name, 1, P - 1))
  else
    Result := Trim(Name);
end;

{ Текст под-сессии шага плана (и результат шага в aeStepEnd) печатается
  только по одному из флагов: по умолчанию от шага остаются строки статуса. }
function StepTextVisible(ShowStepResult, ShowReasoning: Boolean): Boolean;
begin
  Result := ShowStepResult or ShowReasoning;
end;

{ Задание шага плана печатается при --show-step-task или --show-reasoning
  (при обоих off — имя шага в aeStepStart не выводится, имя остаётся только в
  строке статуса). --show-step-result (ShowStepResult) к заданию не
  применяется: он про текст ответа и результат шага (StepTextVisible),
  поэтому параметр намеренно не участвует в результате. }
{$PUSH}{$WARN 5024 OFF}  { ShowStepResult не используется — см. комментарий выше }
function StepTaskVisible(ShowStepTask, ShowReasoning,
  ShowStepResult: Boolean): Boolean;
begin
  Result := ShowStepTask or ShowReasoning;
end;
{$POP}

{ Вывод инструментов — только вместе с размышлениями (--show-reasoning):
  промежуточный вывод скрыт во всех сессиях, основная и субагентская не
  исключение (как в шагах плана). }
function ToolOutputVisible(ShowReasoning: Boolean): Boolean;
begin
  Result := ShowReasoning;
end;

constructor TContextTokens.Create;
begin
  inherited Create;
  FMainBase := 0;
  FMainAccum := 0;
  FSubBase := 0;
  FSubAccum := 0;
end;

{ Новая база (aeContext). Учитывается раздельно для основной сессии и
  субагента: события субагента приходят в тот же обработчик. }
procedure TContextTokens.SetBase(Depth, Tokens: Integer);
begin
  if Depth > 0 then
  begin
    FSubBase := Tokens;
    FSubAccum := 0;
  end
  else
  begin
    FMainBase := Tokens;
    FMainAccum := 0;
  end;
end;

procedure TContextTokens.AddResponseTokens(Depth, Tokens: Integer);
begin
  if Depth > 0 then
    Inc(FSubAccum, Tokens)
  else
    Inc(FMainAccum, Tokens);
end;

{ Вход в под-сессию: счётчики родительской под-сессии уходят в стек, а
  новые начинаются с нуля — иначе до первого aeContext (и в случае события
  без пары) статус показывал бы значения предыдущей под-сессии. }
procedure TContextTokens.EnterSubAgent;
var
  N: Integer;
begin
  N := Length(FSavedBase);
  SetLength(FSavedBase, N + 1);
  SetLength(FSavedAccum, N + 1);
  FSavedBase[N] := FSubBase;
  FSavedAccum[N] := FSubAccum;
  FSubBase := 0;
  FSubAccum := 0;
end;

{ Выход из под-сессии: восстановление счётчиков родительской (шаг плана,
  внутри которого работал субагент), чтобы её размер контекста не потерялся.
  Пустой стек (выход без входа) — просто обнуление. }
procedure TContextTokens.ExitSubSession;
var
  N: Integer;
begin
  N := Length(FSavedBase);
  if N = 0 then
  begin
    FSubBase := 0;
    FSubAccum := 0;
    Exit;
  end;
  FSubBase := FSavedBase[N - 1];
  FSubAccum := FSavedAccum[N - 1];
  SetLength(FSavedBase, N - 1);
  SetLength(FSavedAccum, N - 1);
end;

function TContextTokens.SavedCount: Integer;
begin
  Result := Length(FSavedBase);
end;

{ Откат к состоянию на входе в под-сессию: снимаются её собственная пара и
  пары незакрытых вложенных под-сессий (например, субагента внутри шага,
  чей aeToolResult не пришёл из-за исключения); при этом восстанавливаются
  счётчики родителя, сохранённые до входа. }
procedure TContextTokens.UnwindTo(Level: Integer);
begin
  if Level < 0 then
    Level := 0;
  if Level > Length(FSavedBase) then
  begin
    { Стек короче отметки — состояние недостоверно: безопаснее сбросить. }
    ResetSubSession;
    Exit;
  end;
  while Length(FSavedBase) > Level do
    ExitSubSession;
end;

{ Полный сброс: после выхода из внешней под-сессии (шаг/анализ) не должно
  остаться ни счётчиков, ни пар в стеке — иначе падение шага или
  revise_plan оставили бы значения следующему шагу или основной сессии. }
procedure TContextTokens.ResetSubSession;
begin
  FSubBase := 0;
  FSubAccum := 0;
  SetLength(FSavedBase, 0);
  SetLength(FSavedAccum, 0);
end;

{ Строка статуса: в режиме под-сессии — обе сессии (размер под-сессии без
  времени), иначе — только основная. Метка под-сессии — «subagent» по
  умолчанию, планировщик передаёт «шаг s1» и «анализ». }
function TContextTokens.Text(Total, Depth: Integer;
  const LabelText: string): string;
begin
  if Depth > 0 then
    Result := FormatSubAgentStatus(FMainBase + FMainAccum, FSubBase + FSubAccum,
      Total, LabelText)
  else
    Result := Colored(C_STATUS, FormatContextStatus(FMainBase + FMainAccum,
      Total));
end;

{ Токены текущей под-сессии: база из её aeContext плюс накопленное за
  текущий ответ. Строка шага плана печатает только эти счётчики — основная
  сессия в ней не участвует (время в строке одно, шага). }
function TContextTokens.SubTokens: Integer;
begin
  Result := FSubBase + FSubAccum;
end;

{ Токены основной сессии: база из её aeContext плюс накопленное за текущий
  ответ. Строка шага плана и анализа печатает их рядом со счётчиками
  под-сессии (формат main/sub/total), поэтому значение нужно отдельным
  аксессором — SubTokens возвращает только под-сессию. }
function TContextTokens.MainTokens: Integer;
begin
  Result := FMainBase + FMainAccum;
end;

constructor TStreamPrinter.Create;
begin
  inherited Create;
  FActive := False;
  FLive := AnsiEnabled(1);   { в консоли без VT-режима ESC-коды недопустимы }
  FStatusShown := False;
  FPending := '';
  FReasoningMode := False;
  FInCodeBlock := False;
  FGroupBuf := '';
  FInTable := False;
  FTableBuf := '';
  FTableOnScreen := 0;
  FTableWide := False;
  FTableRawPrinted := 0;
  FPendingOnScreen := False;
  FPrefix := '';
  FBlankPending := False;
  FBlankSeparated := False;
end;

{ Запрошенная пустая строка-разделитель (RequestBlankLine): печатается один
  раз — тем блоком вывода, который начнётся следующим. }
procedure TStreamPrinter.RequestBlankLine;
begin
  FBlankPending := True;
end;

procedure TStreamPrinter.EmitPendingBlank;
begin
  if not FBlankPending then
    Exit;
  FBlankPending := False;
  FBlankSeparated := True;
  WriteLn;
end;

destructor TStreamPrinter.Destroy;
begin
  inherited Destroy;
end;

{ Курсор в начало текущей строки и очистка до её конца. }
procedure TStreamPrinter.ClearLine;
begin
  if not FLive then
    Exit;
  Write(#13);
  Write(ESC + '[K');
end;

{ Очистить зону стрима: текущую строку (статус/пустую, курсор в её конце) и,
  если над ней лежит частичный текст (гарантированно не шире терминала), его
  строку. Курсор остаётся в начале верхней очищенной строки — там печатается
  новый контент; старый статус уже стёрт, поэтому перенос нового контента не
  оставит от него хвоста. }
procedure TStreamPrinter.ClearAbove;
begin
  if not FLive then
    Exit;
  ClearLine;             { CR + ESC[K на строке статуса/пустой }
  if FPendingOnScreen then
  begin
    Write(ESC + '[A');   { курсор на строку с частичным текстом }
    ClearLine;           { очистить её }
  end;
end;

{ Статус печатается в своей строке под текстом; вызывающий обеспечивает, что
  курсор в начале чистой строки. }
procedure TStreamPrinter.PrintStatus(const Status: string);
begin
  if not FLive then
    Exit;
  Write(FPrefix + Status);
  FStatusShown := True;
end;

{ Завершение строки статуса: строка статуса полностью временная и живёт только
  в ANSI-терминале — в scrollback она не печатается. Метод стирает текущую
  строку статуса (после EndStream там может остаться вариант с меньшими
  счётчиками) и сбрасывает признак нарисованного статуса, чтобы следующая
  перерисовка началась с чистой строки. Параметр Status оставлен ради
  вызывающих: завершившаяся под-сессия больше не оставляет своей строки.
  Вне ANSI-терминала метод молчит. }
procedure TStreamPrinter.FreezeStatus(const Status: string);
begin
  if not FLive then
    Exit;
  ClearLine;
  FStatusShown := False;
end;

{ Перерисовать строку статуса без вывода текста: порция ответа (размышления)
  учтена в счётчиках, но её текст скрыт настройкой — счётчики в статусе всё
  равно должны расти. Курсор между порциями стоит на строке статуса, поэтому
  достаточно очистить её и напечатать заново; вне ANSI-терминала статуса нет и
  метод молчит. }
procedure TStreamPrinter.RefreshStatus(const Status: string);
begin
  if not FActive then
    Exit;
  if not FLive then
    Exit;
  ClearLine;
  PrintStatus(Status);
end;

{ Нарисовать строку статуса заново без вывода текста: курсор между порциями
  вывода и после статичных строк стоит на строке статуса (или на пустой
  строке под ней), поэтому достаточно очистить её и напечатать статус. В
  отличие от RefreshStatus не требует активного стрима (FActive): метод
  вызывается и после статичной печати (строка вызова инструмента, shell-
  команда), чтобы строка статуса осталась под ней. ClearLine и PrintStatus
  вне ANSI-терминала молчат — там статуса нет. }
procedure TStreamPrinter.DrawStatus(const Status: string);
begin
  ClearLine;
  PrintStatus(Status);
end;

{ Зафиксировать строку статуса в логе (конец хода): нарисованная временная
  строка стирается и печатается заново с итоговым текстом, а перевод строки
  делает её постоянной — статус остаётся на экране, курсор уходит на чистую
  строку под ним (следующий вывод не приклеивается к статусу). Вне
  ANSI-терминала статуса нет — метод молчит. }
procedure TStreamPrinter.PersistStatus(const Status: string);
begin
  if not FLive then
    Exit;
  FBlankSeparated := False;
  ClearLine;
  { Запрошенный разделитель (RequestBlankLine) — перед закрепляемой строкой:
    результат инструмента отделяется пустой строкой и от done-строки. }
  EmitPendingBlank;
  PrintStatus(Status);
  WriteLn;
  FStatusShown := False;
end;

function TStreamPrinter.RenderLine(const L: string): string;
begin
  if FReasoningMode then
    Result := Colored(C_REASONING, StripMarkdown(L))
  else
    Result := RenderMarkdown(L);
end;

function TStreamPrinter.MeasureRendered(const S: string): Integer;
begin
  Result := VisibleLen(RenderLine(S));
end;

function TStreamPrinter.ContentWidth: Integer;
begin
  Result := TermWidth() - VisibleLen(FPrefix);
  if Result < 1 then
    Result := 1;
end;

function TStreamPrinter.BreakSafe(const Pfx: string): Boolean;
begin
  Result := MarkdownBreakSafe(Pfx);
end;

{ Текст текущей строки без хвостовых CR (CRLF, разорванный чанком). }
function TStreamPrinter.PendingText: string;
var
  S: string;
begin
  S := FPending;
  while (Length(S) > 0) and (S[Length(S)] = #13) do
    Delete(S, Length(S), 1);
  Result := S;
end;

function TStreamPrinter.ApplyPrefix(const S: string): string;
var
  Lines: TStringList;
  I: Integer;
begin
  if FPrefix = '' then
    Exit(S);
  Lines := TStringList.Create;
  try
    Lines.Text := S;
    for I := 0 to Lines.Count - 1 do
      Lines[I] := FPrefix + Lines[I];
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;
{ Полная строка: очистить зону стрима выше курсора, напечатать строку с
  переводом. Длинную строку предварительно переносим по словам — иначе
  терминал оборвёт её жёстко (знаки препинания уезжают в начало строки).
  Курсор остаётся в начале чистой строки под ней (там затем печатается
  статус). }
procedure TStreamPrinter.EmitCompleteLine(const L: string);
var
  Segs: TStringList;
  I: Integer;
begin
  ClearAbove;
  Segs := WrapText(L, ContentWidth, @MeasureRendered, @BreakSafe);
  try
    for I := 0 to Segs.Count - 1 do
      WriteLn(FPrefix + RenderLine(Segs[I]));
  finally
    Segs.Free;
  end;
  ClearLine;   { очистить строку, оказавшуюся под текстом (старый статус) }
  FStatusShown := False;
  FPendingOnScreen := False;
end;

{ Частичная (незавершённая) текущая строка: перерисовать её в своей строке и
  подготовить чистую строку под ней для статуса (статус печатает вызывающий).
  Строку переносим по словам: всё, что уже не влезает, печатаем полными
  строками (разрыв по пробелу, пробел отбрасывается), а последний фрагмент
  остаётся текущей строкой и перерисовывается. Частичная строка таблицы не
  печатается отдельно — она выйдет вместе с таблицей (иначе заголовок
  дублировался бы). }
procedure TStreamPrinter.ShowPartial;
var
  S, Trail, DrawS: string;
  Segs: TStringList;
  I: Integer;
begin
  DrawS := '';
  if FPending <> '' then
  begin
    S := PendingText;
    if (S <> '') and IsTableLine(S) then
    begin
      { Частичная строка таблицы не показывается отдельно: убираем её
        (если была показана) и оставляем курсор в начале строки, куда
        вызывающий напечатает статус. Новых строк не добавляем. }
      ClearAbove;
      FPendingOnScreen := False;
      Exit;
    end;
    if S <> '' then
    begin
      { Хвостовые пробелы сохраняем в буфере: строка ещё не завершена, а
        пробел — разделитель со следующим словом (перенос его отбросил бы).
        Рисуем без хвостовых пробелов, чтобы частичная строка гарантированно
        была уже терминала. }
      Trail := '';
      while (S <> '') and (S[Length(S)] = ' ') do
      begin
        Trail := ' ' + Trail;
        Delete(S, Length(S), 1);
      end;
      if S <> '' then
      begin
        { Переносим накопленную строку: фрагменты, которые уже не влезают,
          становятся полными строками; последний остаётся текущим. }
        Segs := WrapText(S, ContentWidth, @MeasureRendered, @BreakSafe);
        try
          for I := 0 to Segs.Count - 2 do
            EmitCompleteLine(Segs[I]);
          if Segs.Count > 0 then
            DrawS := Segs[Segs.Count - 1];
        finally
          Segs.Free;
        end;
      end;
      FPending := DrawS + Trail;
    end;
  ClearAbove;
  if DrawS <> '' then
  begin
    Write(FPrefix + RenderLine(DrawS));
    WriteLn;                     { вниз: строка статуса под текстом }
    ClearLine;                   { очистить старый статус (курсор в её начале) }
    FPendingOnScreen := True;
  end
  else
    { Рисовать нечего (частичная строка из одних пробелов): строку не
      добавляем — курсор остаётся в начале чистой строки, там вызывающий
      напечатает статус. }
    FPendingOnScreen := False;
end;
end;

{ Группа строк (ограждённый блок кода): печатается одним куском, чтобы
  разметка отрисовалась корректно. Курсор остаётся на новой строке — там
  затем печатается статус. }
procedure TStreamPrinter.EmitGroup(const G: string);
begin
  ClearAbove;
  WriteLn(ApplyPrefix(RenderMarkdown(G)));
  ClearLine;   { очистить строку, оказавшуюся под группой (старый статус) }
  FStatusShown := False;
  FPendingOnScreen := False;
end;

{ Закрывает открытый блок кода: незавершённая строка дописывается в буфер,
  весь блок печатается группой. }
procedure TStreamPrinter.FlushCodeBlock;
begin
  if not FInCodeBlock then
    Exit;
  if FPending <> '' then
  begin
    FGroupBuf := FGroupBuf + sLineBreak + FPending;
    FPending := '';
  end;
  if FGroupBuf <> '' then
    EmitGroup(FGroupBuf);
  FInCodeBlock := False;
  FGroupBuf := '';
end;

{ Печатает текущий буфер таблицы с выравниванием колонок. Если строки
  таблицы уже на экране — курсор поднимается на них, они очищаются, и
  вся таблица перерисовывается заново (выравнивание по мере заполнения).
  Если таблица перестаёт влезать в ширину терминала — уже нарисованная
  выровненная таблица стирается, а все строки буфера печатаются как есть,
  без псевдографики (выровнять и перерисовать таблицу шире терминала
  нельзя: перенесённые строки не поднять построчно). Курсор остаётся на
  чистой строке под таблицей (там затем печатается статус). }
procedure TStreamPrinter.ShowTable;
var
  Lines, RL: TStringList;
  R: string;
  I, MaxW, K: Integer;
begin
  if FTableBuf = '' then
    Exit;
  Lines := SplitLines(FTableBuf);
  RL := nil;
  try
    R := RenderTable(Lines, True);
    MaxW := 0;
    RL := SplitLines(R);
    for I := 0 to RL.Count - 1 do
      if VisibleLen(RL[I]) > MaxW then
        MaxW := VisibleLen(RL[I]);
    if MaxW > ContentWidth then
    begin
      { Шире терминала: убрать уже нарисованную выровненную таблицу (она
        была не шире терминала, значит без переносов) и печатать все
        строки буфера как есть. Каждую новую строку дописываем так же —
        без повторного разбора как таблицы. }
      if not FTableWide then
      begin
        FTableWide := True;
        { Вернуться на верхнюю границу выровненной таблицы, стереть её
          вместе со строкой статуса и оставить курсор на месте верхней
          границы — «сырые» строки печатаются там же, без пустого
          промежутка. }
        if FTableOnScreen > 0 then
        begin
          Write(ESC + '[' + IntToStr(FTableOnScreen) + 'A');
          ClearLine;
          for K := 2 to FTableOnScreen + 1 do
          begin
            Write(ESC + '[B');
            ClearLine;
          end;
          Write(ESC + '[' + IntToStr(FTableOnScreen + 1) + 'A');
        end;
        FTableRawPrinted := 0;
      end;
      for I := FTableRawPrinted to Lines.Count - 1 do
      begin
        ClearLine;            { стереть строку статуса под таблицей }
        WriteLn(FPrefix + Lines[I]);    { строка как есть, без границ }
      end;
      ClearLine;              { строка под таблицей (старый статус) }
      FTableRawPrinted := Lines.Count;
      FStatusShown := False;
    end
    else
    begin
      { Весь экран таблицы перерисовывается заново. Курсор поднимается
        ровно на число ОТРИСОВАННЫХ строк (не строк буфера): у каждой
        строки данных есть ещё верхняя/нижняя границы. Каждую строку
        очищаем перед выводом — иначе справа от короткой границы остаётся
        хвост старого статуса. }
      if FTableOnScreen > 0 then
        Write(ESC + '[' + IntToStr(FTableOnScreen) + 'A');
      for I := 0 to RL.Count - 1 do
      begin
        ClearLine;
        Write(FPrefix + RL[I]);
        WriteLn;
      end;
      ClearLine;   { строка под таблицей (старый статус) }
      FTableOnScreen := RL.Count;
    end;
    FPendingOnScreen := False;   { частичная строка не на экране }
  finally
    if RL <> nil then
      RL.Free;
    Lines.Free;
  end;
end;

{ Закрывает открытую таблицу: печатает буфер (выровненный) и сбрасывает
  состояние. }
procedure TStreamPrinter.FlushTable;
begin
  if not FInTable then
    Exit;
  if FTableBuf <> '' then
    ShowTable;
  FInTable := False;
  FTableBuf := '';
  FTableOnScreen := 0;
  FTableWide := False;
  FTableRawPrinted := 0;
end;

{ Одна завершённая строка контента: блоки кода буферизуются до закрывающего
  маркера, строки таблицы — до первой нетабличной строки, остальные
  печатаются сразу. }
procedure TStreamPrinter.ProcessContentLine(const L: string; var Emitted: Boolean);
var
  T: string;
begin
  T := Trim(L);
  if (Pos('```', T) = 1) or (Pos('~~~', T) = 1) then
  begin
    FlushTable;
    if FInCodeBlock then
    begin
      { Закрывающий маркер: блок кода печатается группой. }
      FInCodeBlock := False;
      EmitGroup(FGroupBuf + sLineBreak + L);
      FGroupBuf := '';
      Emitted := True;
    end
    else
    begin
      FInCodeBlock := True;
      FGroupBuf := L;
    end;
  end
  else if FInCodeBlock then
    FGroupBuf := FGroupBuf + sLineBreak + L
  else if IsTableLine(L) then
  begin
    { Строка таблицы: буферизуем и перерисовываем всю таблицу
      с выравниванием колонок. }
    if FInTable then
      FTableBuf := FTableBuf + sLineBreak + L
    else
    begin
      FInTable := True;
      FTableBuf := L;
    end;
    ShowTable;
    Emitted := True;
  end
  else
  begin
    FlushTable;
    EmitCompleteLine(L);
    Emitted := True;
  end;
end;

{ Вне терминала: без статуса и перерисовки — текст пишется как есть
  (включая переводы строк). FPending хранит хвост текущей незавершённой
  строки — для финального перевода в EndStream/PrepareStatic. }
procedure TStreamPrinter.FeedRaw(const Delta: string);
var
  P, I: Integer;
  S: string;
begin
  S := Delta;
  if FPrefix <> '' then
  begin
    S := '';
    if FPending = '' then
      S := FPrefix;
    for I := 1 to Length(Delta) do
    begin
      if Delta[I] = #10 then
        S := S + #10 + FPrefix
      else
        S := S + Delta[I];
    end;
  end;
  Write(S);
  P := Length(Delta);
  while (P > 0) and (Delta[P] <> #10) do
    Dec(P);
  if P = 0 then
    FPending := FPending + Delta
  else
    FPending := Copy(Delta, P + 1, MaxInt);
end;

procedure TStreamPrinter.BeginStream(const Status: string);
begin
  PrepareStatic;   { новая строка под предыдущим статусом/контентом }
  FActive := True;
  FInCodeBlock := False;
  FGroupBuf := '';
  FInTable := False;
  FTableBuf := '';
  FTableOnScreen := 0;
  FTableWide := False;
  FTableRawPrinted := 0;
  FPending := '';
  FReasoningMode := False;
  FPendingOnScreen := False;
  PrintStatus(Status);
end;

procedure TStreamPrinter.FeedReasoning(const Delta, Status: string);
var
  P: Integer;
  L: string;
  Emitted: Boolean;
begin
  if not FActive then
    Exit;
  if not FLive then
  begin
    FeedRaw(Delta);
    Exit;
  end;
  { Если текущая строка была контентом — завершить её до размышлений.
    Внутри блока кода частичная строка уходит в буфер группы, а не на экран. }
  if (FPending <> '') and (not FReasoningMode) then
  begin
    if FInCodeBlock then
      FGroupBuf := FGroupBuf + sLineBreak + FPending
    else
    begin
      FlushTable;
      EmitCompleteLine(FPending);
    end;
    FPending := '';
  end;
  FlushTable;
  FReasoningMode := True;
  FPending := FPending + Delta;
  Emitted := False;
  while Pos(#10, FPending) > 0 do
  begin
    P := Pos(#10, FPending);
    L := Copy(FPending, 1, P - 1);
    Delete(FPending, 1, P);
    if (Length(L) > 0) and (L[Length(L)] = #13) then
      Delete(L, Length(L), 1);
    EmitCompleteLine(L);
    Emitted := True;
  end;
  { Частичная строка — перерисовать (статус окажется в строке под ней). }
  if (FPending <> '') and (PendingText <> '') then
  begin
    ShowPartial;
    Emitted := True;
  end;
  if Emitted then
    PrintStatus(Status);
end;

procedure TStreamPrinter.FeedContent(const Delta, Status: string);
var
  P: Integer;
  L: string;
  Emitted: Boolean;
begin
  if not FActive then
    Exit;
  if not FLive then
  begin
    FeedRaw(Delta);
    Exit;
  end;
  { Если текущая строка была размышлениями — завершить её до контента. }
  if (FPending <> '') and FReasoningMode then
  begin
    EmitCompleteLine(FPending);
    FPending := '';
  end;
  FReasoningMode := False;
  FPending := FPending + Delta;
  Emitted := False;
  while Pos(#10, FPending) > 0 do
  begin
    P := Pos(#10, FPending);
    L := Copy(FPending, 1, P - 1);
    Delete(FPending, 1, P);
    if (Length(L) > 0) and (L[Length(L)] = #13) then
      Delete(L, Length(L), 1);
    ProcessContentLine(L, Emitted);
  end;
  { Частичная строка вне блока кода и таблицы — перерисовать (статус
    окажется в строке под ней). Внутри блока кода или таблицы не печатаем:
    строка выйдет вместе с группой при закрытии блока. Потенциальную
    строку таблицы (начинается с «|») тоже не показываем: она будет
    отрисована целиком, когда придёт перевод строки. }
  if (FPending <> '') and (not FInCodeBlock) and (not FInTable) and
     (PendingText <> '') and (not IsTableStart(PendingText)) then
  begin
    ShowPartial;
    Emitted := True;
  end;
  if Emitted then
    PrintStatus(Status);
end;

procedure TStreamPrinter.EndStream(const Status: string);
begin
  if not FActive then
    Exit;
  if FLive then
  begin
    { Незавершённая строка таблицы на момент конца стрима — дописать в
      буфер, чтобы она вышла вместе с таблицей. }
    if FInTable and (FPending <> '') and IsTableLine(PendingText) then
    begin
      FTableBuf := FTableBuf + sLineBreak + PendingText;
      FPending := '';
    end;
    { Незакрытые таблица/блок кода на момент конца стрима — допечатать. }
    FlushTable;
    FlushCodeBlock;
    if FPending <> '' then
    begin
      { Последняя незавершённая строка остаётся на экране, курсор — на чистой
        строке под ней; статус не рисуем: он временный и сразу стирается. }
      if PendingText <> '' then
        ShowPartial;
      FPending := '';
    end;
    { Строка статуса полностью временная: стираем её, чтобы следующий вывод
      (приглашение REPL, статичный текст) начался с начала строки, а не
      приклеился к остаткам статуса. Параметр Status оставлен ради
      вызывающих — завершившийся стрим больше не оставляет своей строки. }
    if FStatusShown then
    begin
      ClearLine;
      FStatusShown := False;
    end;
  end
  else
  begin
    if FPending <> '' then
    begin
      WriteLn;   { завершаем последнюю строку }
      FPending := '';
    end;
  end;
  FActive := False;
end;

procedure TStreamPrinter.PrepareStatic;
begin
  FBlankSeparated := False;
  if FLive then
  begin
    FlushTable;
    if FInCodeBlock and (FGroupBuf <> '') then
      EmitGroup(FGroupBuf);
    FInCodeBlock := False;
    FGroupBuf := '';
    if FPending <> '' then
    begin
      EmitCompleteLine(PendingText);   { допечатать как полную строку }
      FPending := '';
    end;
    if FStatusShown then
    begin
      { Строка статуса временная: стираем её, а не оставляем в scrollback. }
      ClearLine;
      FStatusShown := False;
    end;
  end
  else
  begin
    { Вне терминала текст пишется приростом: достаточно завершить
      незавершённую строку переводом. }
    if FPending <> '' then
    begin
      WriteLn;
      FPending := '';
    end;
  end;
  { Пустая строка-разделитель (RequestBlankLine) печатается последней: строка
    статуса к этому моменту уже стёрта (ClearLine выше), поэтому разделитель
    занимает её место и остаётся на экране, а блок вывода начинается под ним. }
  EmitPendingBlank;
end;

{ Обёртка над PrepareStatic для случаев, когда вызывающему важно не потерять
  статус: нарисованная строка статуса стирается до подготовки статичного вывода,
  а вызывающий после печати текста рисует статус заново (DrawStatus). Теперь и
  сам PrepareStatic стирает статус (ClearLine), так что обёртка остаётся для
  явного контракта: «стереть до вывода, статус нарисуем сами». }
procedure TStreamPrinter.PrepareStaticOverStatus;
begin
  if FLive and FStatusShown then
  begin
    ClearLine;         { стереть нарисованный статус — на его месте будет строка }
    FStatusShown := False;
  end;
  PrepareStatic;
end;

{ --------------------------------------------------------------- application }

constructor TMirmidApp.Create(const ACfg: TMirmidConfig);
begin
  inherited Create;
  FCfg := ACfg;
  FReg := TToolRegistry.Create;
  { Состав инструментов сессии: встроенные, subagent, http_request и
    revise_plan; какие из них попадут в запрос, решает секция [tools]. }
  RegisterSessionTools(FReg, FCfg);
  FAgent := TAgent.Create(FCfg, FReg);
  FAgent.OnEvent := @OnAgentEvent;
  FAgent.OnSubAgentEvent := @OnAgentEvent;
  FPrinter := TStreamPrinter.Create;
  FNoSession := False;
  FShowReasoning := False;
  FShowStepTask := False;
  FShowStepResult := False;
  FToolStack := TStringList.Create;
  FSubAgentDepth := 0;
  FPrintDepth := 0;
  FSubAgentLabel := '';
  FCurrentStepName := '';
  SetLength(FSubSessionMarks, 0);
  FTokens := TContextTokens.Create;
  FMainContext := 0;
  FLastSummarizeEffective := False;
  FLastSummarizeSaving := 0;
  FJournalMsgs := 0;
  FMcp := nil;
  FPlanner := nil;
  { Режим планирования: планировщик и инструмент revise_plan в реестре. }
  if FCfg.PlanMode then
  begin
    FPlanner := TPlanner.Create(FCfg, FReg);
    FPlanner.OnEvent := @OnAgentEvent;
    FPlanner.OnPlanChanged := @OnPlanChanged;
    RegisterRevisePlanTool(FReg, FPlanner);
  end;
  LoadMcp;
end;

{ Подключает MCP-серверы из mcp.json (если включено и файл найден). Ошибки
  отдельных серверов не прерывают запуск — выводятся предупреждениями. }
procedure TMirmidApp.LoadMcp;
var
  Path: string;
  W: TStringList;
  I: Integer;
begin
  if not FCfg.McpEnabled then
    Exit;
  Path := FCfg.McpConfig;
  if Path <> '' then
    Path := ExpPath(Path, FCfg.WorkDir)
  else
    Path := DefaultMcpConfigPath(FCfg.WorkDir);
  if not FileExists(Path) then
    Exit;
  FMcp := TMCPManager.Create(FReg, FCfg.McpTimeout);
  W := TStringList.Create;
  try
    FMcp.LoadFromFile(Path, W);
    for I := 0 to W.Count - 1 do
      WriteWarning(W[I]);
  finally
    W.Free;
  end;
end;

destructor TMirmidApp.Destroy;
begin
  FAgent.Free;
  FPlanner.Free;
  FMcp.Free;
  FReg.Free;
  FPrinter.Free;
  FToolStack.Free;
  FTokens.Free;
  inherited Destroy;
end;

{ Кэш контекста основной сессии: пересчитывается по истории агента и схемам
  инструментов только в точках «перед запросом» и «после хода», а не на
  каждой порции стрима (оценка проходит по всем сообщениям). В режиме
  планирования это единственный источник main-значения: сама основная сессия
  к модели не обращается, и aeContext с глубиной 0 не приходит. }
procedure TMirmidApp.UpdateMainContext;
begin
  if FAgent = nil then
    Exit;
  FMainContext := FAgent.ContextTokens;
end;

{ Контекст основной сессии для строки статуса. Пока кэш не снимался (0),
  отдаём базу из aeContext — это те же токены, что пришли от агента, поэтому
  переход к кэшу не меняет показания. }
function TMirmidApp.MainContextTokens: Integer;
begin
  if FMainContext > 0 then
    Result := FMainContext
  else
    Result := FTokens.MainTokens;
end;

{ Строка статуса контекста после хода в нестриминговом режиме: в стриме её
  рисует и фиксирует принтер потока (PersistStatus), поэтому вызывается только
  без стрима. Вне терминала молчим (как и в стриме). }
procedure TMirmidApp.PrintContextStatus;
begin
  if not IsTerminal(1) then
    Exit;
  WriteLn(Colored(C_STATUS,
    FormatContextStatus(FAgent.ContextTokens, EffectiveContextWindow(FCfg))));
end;

{ Итоговая строка статуса остаётся на экране после хода (task2.md): в
  потоковом режиме в лог фиксируется та же строка, которую принтер рисовал под
  ответом (счётчики на конец хода, тот же цвет), в нестриминговом её не
  рисовали — печатаем сами. Вне терминала оба пути молчат. }
procedure TMirmidApp.KeepContextStatus;
begin
  if FCfg.Stream then
    FPrinter.PersistStatus(StatusText)
  else
    PrintContextStatus;
end;

{ Статус контекста для текущей строки: размер запрашиваемого контекста (его
  присылает агент событием aeContext) плюс токены, пришедшие в этом стриме.
  Под-сессия шага плана печатается своей строкой —
  «[ЧЧ:ММ:СС|main/sub/total|процент-main%/процент-sub%] имя»
  (FormatStepStatus): статус и имя шага заменяют «основная сессия + метка»,
  счётчики строки — контекст основной сессии, шага и общее окно модели.
  Main-значение берётся из MainContextTokens: в режиме планирования сама
  основная сессия к модели не обращается, и aeContext с глубиной 0 не приходит,
  поэтому нужен кэш оценки агента. Под-сессия предварительного анализа — тем же
  порядком: «[ЧЧ:ММ:СС|main/sub/total|процент-main%/процент-sub%] анализ»
  (FormatAnalysisStatus). Вложенный в шаг или в анализ субагент (глубина > 1)
  сохраняет прежний вид: видно и основную сессию, и метку, и счётчики
  субагента. Инструмент subagent вне планировщика — статус основной сессии +
  метка («subagent» по умолчанию) + статус под-сессии (у её части времени нет,
  см. FormatSubAgentStatus). }
function TMirmidApp.StepStatusText: string;
begin
  Result := FormatStepStatus(FCurrentStepName, FTokens.SubTokens,
    EffectiveContextWindow(FCfg), MainContextTokens);
end;

function TMirmidApp.StatusText: string;
begin
  if InStepSubSession and (FSubAgentDepth = 1) then
    Exit(StepStatusText);
  { Под-сессия анализа — своя строка, как у шага: сначала статус анализа,
    затем метка «анализ» (FormatAnalysisStatus); main-счётчик — из того же
    источника, что и у строки шага (MainContextTokens). Вложенный субагент
    (глубина > 1) условием не перехватывается и печатается прежним видом,
    как и внутри шага. }
  if (FSubAgentLabel = 'анализ') and (FSubAgentDepth = 1) then
    Exit(FormatAnalysisStatus(FTokens.SubTokens,
      EffectiveContextWindow(FCfg), MainContextTokens));
  { Метка под-сессии («шаг s1») приходит событием; без метки — обычное
    поведение субагента-инструмента («subagent»). }
  if FSubAgentLabel <> '' then
    Result := FTokens.Text(EffectiveContextWindow(FCfg), FSubAgentDepth,
      FSubAgentLabel)
  else
    Result := FTokens.Text(EffectiveContextWindow(FCfg), FSubAgentDepth);
end;

{ Строка статуса, закрепляемая после выхода из под-сессии (task1.md):
  у шага метка короткая — «s1», без описания задания, которое нужно только
  в текущей строке шага; у анализа метка уже «анализ» (FormatAnalysisStatus).
  Счётчики те же, что в StatusText на момент вызова: до отката глубины и стека
  они соответствуют завершившейся под-сессии. }
function TMirmidApp.DoneStatusText: string;
begin
  if InStepSubSession and (FSubAgentDepth = 1) then
    Result := FormatStepStatus(StepShortName(FCurrentStepName),
      FTokens.SubTokens, EffectiveContextWindow(FCfg), MainContextTokens)
  else
    Result := StatusText;
end;

{ Закрепление done-строки завершённой под-сессии (task1.md, п.4):
  «…] анализ done», «…] s1 done». В ANSI-терминале строку фиксирует принтер
  потока: PersistStatus стирает нарисованную временную строку и печатает итог.
  В консоли без VT-режима нарисованной строки нет, а в нестриминговом режиме
  её не было вовсе — печатаем строку статично тем же WriteLn, что и main-статус
  после хода (PrintContextStatus). Headless/перенаправленный вывод молчит:
  строки статуса там нет, и main-статус после хода тоже не печатается. Так
  done-строка ведёт себя одинаково при --no-stream и в потоковом режиме.
  Цвета гасит Colored: в консоли без ANSI строка выходит простым текстом. }
procedure TMirmidApp.PersistDoneStatus;
var
  Line: string;
begin
  Line := DoneStatusText + Colored(C_USAGE, ' done');
  if FPrinter.Live then
    FPrinter.PersistStatus(Line)
  else if IsTerminal(1) then
    WriteLn(Line);
end;
{ Идёт ли под-сессия шага плана: имя шага выставлено в aeStepStart и
  снимается в aeStepEnd, глубина при этом больше нуля (вход в под-сессию
  шлёт aeSubSessionStart с меткой «шаг sN»). Текст такой сессии — ответ
  шага; по умолчанию он не печатается. }
function TMirmidApp.InStepSubSession: Boolean;
begin
  Result := (FSubAgentDepth > 0) and (FCurrentStepName <> '');
end;


procedure TMirmidApp.OnAgentEvent(Kind: TAgentEventKind; const Text: string);
var
  P, N: Integer;
  Name, Args, S, St: string;
  Pfx, Body: string;
begin
  Pfx := FPrinter.Prefix;
  case Kind of
    aeStep:
      { Текст шага плана: без тега, цветом шага (C_STEP). }
      if FCfg.Verbose then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_STEP, Text));
      end;
    aePlan:
      { План со статусами: тег [план] и по строке на шаг. }
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_STEP, '[план]'));
        WriteLn(FPrinter.ApplyPrefix(Text));
      end;
    aeStepStart:
      { Начало шага: «s1: описание» — без тега [шаг]. Имя шага запоминаем —
        по нему строка статуса под-сессии шага печатает «[время|…] имя»
        (в aeSubSessionStart приходит только короткая метка «шаг s1»).
        Решение по неоднозначности task1: гейтится ТОЛЬКО строка с именем
        шага ниже; условие показа задания —
        ShowStepTask or ShowReasoning (при обоих off задания не видно; с
        --show-reasoning задание печатается независимо от --show-step-task).
        Имя в строке статуса шага остаётся всегда — поэтому FCurrentStepName
        присваивается безусловно, вне условия показа. --show-step-result к
        заданию шага не применяется: он про текст ответа/результата шага
        (aeStepEnd, текст под-сессии — StepTextVisible, другое условие), а не
        про само задание. }
      begin
        { Имя шага нужно строке статуса всегда — присваиваем до проверки
          флагов, вне условия печати задания. }
        FCurrentStepName := Text;
        if StepTaskVisible(FShowStepTask, FShowReasoning, FShowStepResult) then
        begin
          FPrinter.PrepareStatic;
          WriteLn(Pfx + Colored(C_STEP, Text));
        end;
      end;
    aeStepEnd:
      { Конец шага: «s1: done» и результат — но только по
        --show-step-result или --show-reasoning (task1: с выключенными
        флагами от шага остаются лишь строки статуса, а результат не
        дублирует текст, который уже пришёл в aeAssistant/aeStreamText).
        Результат укорочен до TOOL_RESULT_MAX (см. FormatStepEnd). Имя шага
        после него не нужно: в статусе новая строка начнётся с основной
        сессии. }
      begin
        FCurrentStepName := '';
        FPrinter.PrepareStatic;
        if StepTextVisible(FShowStepResult, FShowReasoning) then
          WriteLn(Pfx + Colored(C_STEP, FormatStepEnd(Text)))
        else
          WriteLn(Pfx + Colored(C_STEP, FormatStepEndStatus(Text)));
      end;
    aeReport:
      { Отчёт: markdown-рендер, как для aeAssistant. }
      if Trim(Text) <> '' then
      begin
        FPrinter.PrepareStatic;
        { Пустая строка перед отчётом — только если её не оставил предыдущий блок
          (результат инструмента, task1.md). }
        if not FPrinter.BlankSeparated then
          WriteLn(Pfx);
        WriteLn(FPrinter.ApplyPrefix(RenderMarkdown(Text)));
      end;
    aeAnalysis:
      { Предварительный анализ: тег [анализ] и markdown-рендер. }
      if Trim(Text) <> '' then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_STEP, '[анализ]'));
        WriteLn(FPrinter.ApplyPrefix(RenderMarkdown(Text)));
      end;
    aeLoopWarning:
      { Loop-guard: жёлтая строка о повторяющихся вызовах инструментов
        (текст — тот же, что в синтетическом user-сообщении). }
      if Trim(Text) <> '' then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_WARN, '[цикл]'), ' ', Text);
      end;
    aeReasoning:
      { Нестриминговый режим: размышления без тега, зеленосерые, разметка
        markdown снимается. Условие печати то же, что у aeStreamReasoning:
        текст виден только с --show-reasoning (в под-сессии шага — в том
        числе, т.к. шаг по умолчанию отдаёт лишь строку статуса). }
      if FShowReasoning and (Trim(Text) <> '') then
      begin
        FPrinter.PrepareStatic;
        S := StripMarkdown(Trim(Text));
        WriteLn(FPrinter.ApplyPrefix(Colored(C_REASONING, S)));
      end;
    aeToolCall:
      { Имя инструмента — в теге вместо слова «инструмент», параметры (json) —
        светлосерые. При вызове subagent увеличиваем глубину и выставляем
        префикс принтера. }
      begin
        FPrinter.PrepareStatic;
        FPrinter.ClearLine;
        { Текст статуса снимаем здесь, до изменения глубины и счётчиков:
          StatusText после EnterSubAgent и роста FSubAgentDepth отдал бы
          пустой статус субагента (его контекст ещё не пришёл событием
          aeContext), и строка под вызовом подменила бы статус родителя
          нулями. }
        St := StatusText;
        Name := Text;
        Args := '';
        P := Pos(' ', Text);
        if P > 0 then
        begin
          Name := Copy(Text, 1, P - 1);
          Args := TrimRight(Copy(Text, P + 1, MaxInt));
        end;
        FToolStack.Add(Name);
        if Name = SUBAGENT_TOOL_NAME then
        begin
          { Глубина учёта токенов и глубина префикса печати растут вместе:
            инструмент subagent — единственный источник «│». }
          Inc(FSubAgentDepth);
          Inc(FPrintDepth);
          FPrinter.Prefix := DepthPrefix(FPrintDepth);
          Pfx := FPrinter.Prefix;
          { Счётчики субагента — с чистого листа: размер его контекста придёт
            событием aeContext перед первым запросом к модели. }
          FTokens.EnterSubAgent;
        end;
        { Печать гейтится: без --show-reasoning строка вызова инструмента
          скрыта в любой сессии (task2.md). Служебная часть (FToolStack.Add,
          глубины, ClearLine/DrawStatus) выполнена выше и ниже всегда — иначе
          разъедется учёт и распознавание результата subagent. }
        if ToolOutputVisible(FShowReasoning) then
        begin
          if Args <> '' then
            WriteLn(Pfx + Colored(C_TOOLCALL, '[' + Name + ']'), ' ',
              Colored(C_TOOLTEXT, Shorten(Args, 400)))
          else
            WriteLn(Pfx + Colored(C_TOOLCALL, '[' + Name + ']'));
        end;
        { Строка вызова печатается статично (если печать не скрыта), а
          ClearLine выше стёрла строку статуса: без перерисовки статус исчезает
          до следующей порции стрима (а у инструмента без текстового ответа — до
          конца хода). Рисуем его заново снятым до вызова текстом St; вне
          ANSI-терминала метод молчит. }
        FPrinter.DrawStatus(St);
      end;
    aeShellCommand:
      { Команда shell-инструмента — только текст команды с префиксом "$ ". }
      begin
        FPrinter.PrepareStatic;
        FPrinter.ClearLine;
        FToolStack.Add('shell');
        { Печать гейтится так же, как в aeToolCall (ToolOutputVisible): без
          --show-reasoning строка команды скрыта в любой сессии.
          FToolStack.Add('shell') выполнен выше безусловно —
          по нему aeToolResult находит пару и не путает результат с subagent. }
        if ToolOutputVisible(FShowReasoning) then
          WriteLn(Pfx + Colored(C_SHELLCMD, '$ ' + Text));
        { Как и в aeToolCall: строка команды печатается статично, а ClearLine
          выше стёрла строку статуса — рисуем её заново под строкой команды,
          иначе статус пропадает до следующего события. Вне ANSI — молчит. }
        FPrinter.DrawStatus(StatusText);
      end;
    aeToolResult:
      { Результат инструмента: текст зелёный и усечённый по числу строк;
        результат subagent лимитируется так же (это тоже результат
        инструмента; полный ответ остаётся в файле сессии), с префиксом
        глубины. Имя инструмента берём
        из стека (pop): одно общее «последнее имя» перезаписывалось
        инструментами самого субагента, и результат subagent не
        распознавался — глубина не уменьшалась, и вывод основной
        сессии продолжался с префиксом и статусом субагента.
        Многострочный текст печатается с префиксом на каждой строке. }
      begin
        { Пустые строки в начале и конце вывода инструмента убираем до обрезки
          по лимиту строк (task1.md): иначе лимит тратится на пустые строки, а
          на экране остаются лишние пустые строки. Текст — только для печати;
          в истории и файле сессии вывод остаётся как есть. }
        Body := TrimBlankLines(Text);
        Name := '';
        if FToolStack.Count > 0 then
        begin
          Name := FToolStack[FToolStack.Count - 1];
          FToolStack.Delete(FToolStack.Count - 1);
        end;
        if Name = SUBAGENT_TOOL_NAME then
        begin
          { Видимость результата гейтится так же, как вызов инструмента
            (ToolOutputVisible): без --show-reasoning ответ субагента скрыт в
            любой сессии. Снятие имени со стека, возврат глубины/счётчиков и
            перерисовка статуса ниже выполняются безусловно — гейтинг не
            влияет на учёт и распознавание результата subagent. }
          if ToolOutputVisible(FShowReasoning) and (Body <> '') then
          begin
            { Результат печатается на месте нарисованной строки статуса:
              PrepareStaticOverStatus её стирает, а не фиксирует строкой выше
              (иначе старый статус субагента оставался бы между вызовом
              инструмента и его результатом). Обрезка — та же, что у прочих
              инструментов (FCfg.ToolOutputLines, по умолчанию 9, 0 — без
              лимита): ответ субагента тоже результат инструмента, иначе он
              заливал бы экран целиком. Полный текст при этом не теряется —
              он остаётся в файле сессии субагента и в истории. }
            FPrinter.PrepareStaticOverStatus;
            WriteLn(FPrinter.ApplyPrefix(Colored(C_RESULT,
              ShortenLinesMiddle(Body, FCfg.ToolOutputLines))));
            { Пустая строка после вывода инструмента (task1.md): следующий блок
              информации (вызов следующего инструмента, ответ модели, done-строка)
              начинается под разделителем, а не вплотную к результату. Строка
              запрашивается лениво — её напечатает начало следующего блока. }
            FPrinter.RequestBlankLine;
          end;
          { Глубина и счётчики субагента возвращаются только если он был
            открыт: одиночный aeToolResult не должен уводить глубину в минус
            (после падения шага его незакрытая пара уже снята откатом). }
          if FSubAgentDepth > 0 then
          begin
            Dec(FSubAgentDepth);
            { Счётчики субагента не должны затирать размер контекста шага,
              внутри которого он работал («шаг → субагент»): восстанавливаем
              сохранённую пару родительской под-сессии. }
            FTokens.ExitSubSession;
          end;
          { Префикс печати живёт отдельно от глубины учёта токенов и не
            должен стать отрицательным, если парного aeToolCall не было. }
          if FPrintDepth > 0 then
            Dec(FPrintDepth);
          FPrinter.Prefix := DepthPrefix(FPrintDepth);
          { Статус рисуется заново уже с глубиной родительской сессии (вызов
            субагента выглядит как одна строка вызова + результат); вне
            ANSI-терминала метод молчит. }
          FPrinter.DrawStatus(StatusText);
        end
        else
        begin
          { Обычный результат: печать под тем же гейтингом, что у вызова
            (ToolOutputVisible); статус перерисовывается безусловно — строка
            статуса могла быть стёрта вызовом инструмента, а вне ANSI-терминала
            метод молчит. }
          if ToolOutputVisible(FShowReasoning) and (Body <> '') then
          begin
            { Как и для субагента: строка статуса стирается, результат встаёт
              на её место, статус рисуется заново под результатом.
              Обрезка — по числу строк (FCfg.ToolOutputLines, по умолчанию 9):
              при превышении сокращается середина с маркером «…», начало и
              конец вывода остаются видны. 0 — без лимита. Пустые строки сверху
              и снизу сняты до обрезки (Body, см. начало ветки aeToolResult). }
            FPrinter.PrepareStaticOverStatus;
            WriteLn(FPrinter.ApplyPrefix(Colored(C_RESULT,
              ShortenLinesMiddle(Body, FCfg.ToolOutputLines))));
            { Разделитель после вывода инструмента — так же, как в ветке
              subagent выше (task1.md). }
            FPrinter.RequestBlankLine;
          end;
          FPrinter.DrawStatus(StatusText);
        end;
      end;
    aeAssistant:
      { Нестриминговый режим: весь ответ целиком с markdown-разметкой. В
        стриминговом режиме текст уже напечатан построчно — не дублируем.
        Ответ под-сессии шага плана не печатаем вовсе: его результат уже
        приходит строкой «sN: статус — результат» в aeStepEnd, и текст
        шага выводился бы дважды (task1: результат шага включают флаги
        --show-step-result/--show-reasoning, и печатает его aeStepEnd).
        Вложенный в шаг субагент тоже скрыт: его ответ приходит полностью
        результатом инструмента (aeToolResult), а не как ответ шага. }
      if not FCfg.Stream and not InStepSubSession and (Trim(Text) <> '') then
      begin
        FPrinter.PrepareStatic;
        { Пустую строку перед ответом печатаем только если предыдущий блок сам
          её не оставил (результат инструмента — task1.md): иначе под выводом
          инструмента оказались бы две пустые строки подряд. }
        if not FPrinter.BlankSeparated then
          WriteLn(Pfx);
        WriteLn(FPrinter.ApplyPrefix(RenderMarkdown(Text)));
      end;
    aeUsage:
      if FCfg.Verbose then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_USAGE, '[' + Text + ']'));
      end;
    aeError:
      WriteError(Text);
    aeContext:
      { Размер контекста (оценка агента): база строки статуса. Приходит перед
        первым запросом хода, после добавления ответа в историю и после
        результатов инструментов, поэтому база соответствует фактическому
        контексту и в конце хода. У субагента — его собственная история и
        подсказка: раньше базой субагента считался 0, и статус показывал только
        токены текущего ответа. Для основной сессии (глубина 0) заодно
        обновляется кэш её контекста: значение main в строке шага/анализа
        остаётся свежим и после под-сессии, ход которой вёл планировщик. }
      begin
        FTokens.SetBase(FSubAgentDepth, StrToIntDef(Text, 0));
        if FSubAgentDepth = 0 then
          UpdateMainContext;
      end;
    aeSubSessionStart:
      { Вход в под-сессию планировщика (предварительный анализ, шаг плана):
        метка события («анализ», «шаг s1») уходит в строку статуса вместо
        «subagent», глубина учёта токенов растёт (свои счётчики под-сессии);
        префикс печати при этом не меняется — отступ «│» даёт только
        инструмент subagent. Отметка запоминает состояние до входа — по ней
        выход восстановит его даже после исключения внутри шага. }
      begin
        N := Length(FSubSessionMarks);
        SetLength(FSubSessionMarks, N + 1);
        FSubSessionMarks[N].Depth := FSubAgentDepth;
        FSubSessionMarks[N].PrintDepth := FPrintDepth;
        FSubSessionMarks[N].LabelText := FSubAgentLabel;
        FSubSessionMarks[N].Saved := FTokens.SavedCount;
        { Фазы планировщика запускает только корневая сессия, поэтому печать
          начинается на верхнем уровне: счётчик префикса обнуляется. Тогда
          строка шага идёт без отступа, а вложенный в шаг инструмент subagent
          получает ровно один «│» — даже если предыдущий субагент остался
          незакрытым (потерянный aeToolResult) и счётчик «протёк» сюда.
          Базовый уровень сохранён в отметке и вернётся на aeSubSessionEnd. }
        FPrintDepth := 0;
        FPrinter.Prefix := '';
        Inc(FSubAgentDepth);
        FSubAgentLabel := Text;
        FTokens.EnterSubAgent;
      end;
    aeSubSessionEnd:
      { Выход из под-сессии планировщика: строка статуса (в том числе метка
        шага) фиксируется в логе с меткой «done» — по ней видно, сколько
        контекста заняла завершённая под-сессия (task1.md). Затем глубина,
        метка и стек счётчиков возвращаются к отметке входа:
        всё, что осталось от незакрытого субагента или revise_plan,
        отбрасывается, и значения шага не «протекают» в следующий шаг или
        основную сессию. Вложенный субагент внутри шага метку не меняет: его
        события приходят как aeToolCall/aeToolResult, а не aeSubSession*; его
        счётчики снимаются со стека при aeToolResult. }
      begin
        { Строка статуса не стирается, а закрепляется: DoneStatusText
          снимается здесь, пока счётчики под-сессии и её метка ещё целы,
          поэтому в scrollback уходит строка с итоговыми числами
          завершившегося шага («…] s1 done») или анализа («…] анализ done»).
          Метка «done» серая, как и имя шага/«анализ». Выбор способа печати —
          в PersistDoneStatus: ANSI-терминал закрепляет нарисованную строку,
          нестриминговый режим и консоль без VT-режима печатают её статично
          (иначе в --no-stream done-строка терялась бы), headless молчит. }
        PersistDoneStatus;
        N := Length(FSubSessionMarks);
        if N > 0 then
        begin
          Dec(N);
          if FSubSessionMarks[N].Depth = 0 then
            { Внешний выход: пара и всё, что накопилось, — мусор. }
            FTokens.ResetSubSession
          else
            FTokens.UnwindTo(FSubSessionMarks[N].Saved);
          FSubAgentDepth := FSubSessionMarks[N].Depth;
          { Префикс печати возвращается к отметке входа: незакрытый субагент
            внутри шага не оставляет лишних «│» следующей строке. }
          FPrintDepth := FSubSessionMarks[N].PrintDepth;
          FSubAgentLabel := FSubSessionMarks[N].LabelText;
          { Вне шага имя шага в строке статуса не нужно: иначе падение хода
            до aeStepEnd оставило бы его следующей строке. }
          if FSubAgentDepth = 0 then
            FCurrentStepName := '';
          SetLength(FSubSessionMarks, N);
        end
        else
        begin
          { Событие без парного старта: прежнее поведение — снять одну
            под-сессию, метку убрать при возврате на верхний уровень. }
          if FSubAgentDepth > 0 then
            Dec(FSubAgentDepth);
          FTokens.ExitSubSession;
          if FSubAgentDepth = 0 then
          begin
            FSubAgentLabel := '';
            FCurrentStepName := '';
          end;
        end;
        { Выход из под-сессии планировщика не меняет префикс печати: «│»
          принадлежит только инструменту subagent. }
        FPrinter.Prefix := DepthPrefix(FPrintDepth);
      end;
    aeStreamStart:
      FPrinter.BeginStream(StatusText);
    aeStreamText:
      begin
        { Токены ответа учитываем всегда — статус отражает весь контекст.
          Текст ответа под-сессии шага плана печатается только по
          --show-step-result или --show-reasoning: по умолчанию шаг даёт
          лишь строку статуса, а его результат (тоже по флагам) — строка
          «sN: done — результат» в aeStepEnd. Скрытый текст не должен
          застревать в буфере принтера: вместо FeedContent перерисовываем
          статус. }
        FTokens.AddResponseTokens(FSubAgentDepth, (CountUTF8Chars(Text) + 3) div 4);
        if InStepSubSession and not StepTextVisible(FShowStepResult, FShowReasoning) then
        begin
          if Text <> '' then
            FPrinter.RefreshStatus(StatusText);
        end
        else
          FPrinter.FeedContent(Text, StatusText);
      end;
    aeStreamReasoning:
      begin
        { Токены размышлений учитываем всегда — статус отражает весь контекст
          (в том числе контекст шага плана: счётчики под-сессии ведутся
          раздельно по FSubAgentDepth). Печать текста — только с
          --show-reasoning. }
        FTokens.AddResponseTokens(FSubAgentDepth, (CountUTF8Chars(Text) + 3) div 4);
        if FShowReasoning then
          FPrinter.FeedReasoning(Text, StatusText)
        else if Text <> '' then
          { Текст размышлений скрыт настройкой, но токены уже учтены: без
            перерисовки строки статуса они не появятся на экране до первого
            куска ответа (а у ответа без текста — вообще не появятся).
            Пустая порция счётчики не меняет — перерисовывать нечего. }
          FPrinter.RefreshStatus(StatusText);
      end;
    aeStreamEnd:
      FPrinter.EndStream(StatusText);
  end;
end;

procedure TMirmidApp.LoadOrNewSession(out Plan: TPlan);
var
  Err: string;
  Msgs: TMessages;
begin
  Plan := nil;
  if FSessionId = '' then
    FSessionId := NewSessionId
  else if LoadSession(SessionDir(FCfg.WorkDir), FSessionId, Msgs, Plan, Err) and
          (Length(Msgs) > 0)
  then
  begin
    FAgent.Messages := Msgs;
    { Загруженная история уже была в контексте раньше — в «part» первой
      записи журнала её не включаем. }
    FJournalMsgs := Length(Msgs);
    { Загруженный план передаём планировщику (если он создан). }
    if (FPlanner <> nil) and (Plan <> nil) then
    begin
      FPlanner.Plan := Plan;
      Plan := nil;
    end;
  end;
end;

{ План изменился (новый план, статус шага, revise_plan) — сохранить сессию. }
procedure TMirmidApp.OnPlanChanged;
begin
  SaveCurrentSession;
end;

procedure TMirmidApp.SaveCurrentSession;
var
  Err: string;
  P: TPlan;
  I, Ctx, Part: Integer;
  R: TPersistResult;
begin
  try
    { План (если планировщик создан) сохраняется вместе с сессией. }
    P := nil;
    if FPlanner <> nil then
      P := FPlanner.Plan;
    { Ctx — полный размер контекста, Part — токены сообщений, добавленных
      с прошлой записи журнала. При --no-session сохранять нечего: helper
      вернёт prSkipped и не создаст ни файла сессии, ни файла журнала. }
    Ctx := FAgent.ContextTokens;
    Part := 0;
    for I := FJournalMsgs to High(FAgent.Messages) do
      Inc(Part, MessageTokens(FAgent.Messages[I]));
    R := SaveSessionWithJournal(FCfg.WorkDir, FSessionId, FCfg.Model,
      FAgent.Messages, P, FNoSession, Ctx, Part, Err);
    case R of
      prSkipped:
        ; { --no-session: FJournalMsgs не двигаем — записи не было. }
      prSessionFailed:
        WriteWarning('не удалось сохранить сессию: ' + Err);
      prJournalFailed:
        begin
          { Сессия сохранена, поэтому часть контекста уже отражена в файле
            сессии — следующая запись журнала начнётся после неё. }
          FJournalMsgs := Length(FAgent.Messages);
          WriteWarning('не удалось записать журнал контекста: ' + Err);
        end;
      prOk:
        FJournalMsgs := Length(FAgent.Messages);
    end;
  except
    { Сбой записи не должен подменять исходную ошибку хода (task2.md:
      сессия сохраняется и после ошибки/исключения). }
    on E: Exception do
      WriteWarning('не удалось сохранить сессию: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ Запрашивает у хоста (LLM-сервера) контекст модели. Если хост сообщает
  значение — оно сохраняется в FCfg.HostContextWindow. Ошибки не фатальны. }
procedure TMirmidApp.FetchHostContext;
var
  Client: TLLMClient;
  Models: TModelList;
  Err: string;
  I: Integer;
begin
  if FCfg.Model = '' then
    Exit;
  Client := TLLMClient.Create(FCfg);
  try
    if not Client.FetchModelList(Models, Err) then
      Exit;
    for I := Low(Models) to High(Models) do
    begin
      if LowerCase(Models[I].Id) = LowerCase(FCfg.Model) then
      begin
        FCfg.HostContextWindow := EffectiveContext(Models[I]);
        Break;
      end;
    end;
  finally
    Client.Free;
  end;
end;

{ Суммаризация текущей сессии: создаёт новую сессию с резюме.
  Вызывается по команде пользователя или автоматически. }
procedure TMirmidApp.DoSummarize;
var
  Res: TSummarizeResult;
  Err: string;
  NewMsgs: TMessages;
  P: TPlan;
  NewId: string;
  Saving: Integer;
begin
  if FNoSession then
  begin
    WriteWarning('суммаризация недоступна: режим --no-session');
    Exit;
  end;
  if Length(FAgent.Messages) <= 1 then
  begin
    WriteWarning('суммаризация: нечего суммаризировать (диалог пуст)');
    Exit;
  end;

  FPrinter.PrepareStatic;
  WriteLn(Colored(C_USAGE, 'Суммаризация сессии...'));

  if not SummarizeSession(FCfg, FAgent.Messages, Res, Err) then
  begin
    WriteError('суммаризация не удалась: ' + Err);
    Exit;
  end;

  Saving := Res.TokensBefore - Res.TokensAfter;
  FLastSummarizeEffective := Res.Effective;
  FLastSummarizeSaving := Saving;

  { Создаём новую сессию с резюме. }
  NewId := NewSessionId;
  NewMsgs := BuildSummarizedMessages(FCfg, Res.Summary);
  FAgent.Messages := NewMsgs;
  FSessionId := NewId;
  { База файлов вспомогательных сессий следует за новым id сессии. }
  FAgent.SessionBase := NewId;
  if FPlanner <> nil then
    FPlanner.SessionBase := NewId;

  { Сохраняем новую сессию. }
  P := nil;
  if FPlanner <> nil then
    P := FPlanner.Plan;
  if not SaveSession(SessionDir(FCfg.WorkDir), FSessionId, FCfg.Model,
    FAgent.Messages, P, Err)
  then
    WriteWarning('не удалось сохранить новую сессию: ' + Err);

  if Res.Effective then
    WriteLn(Colored(C_RESULT,
      Format('Сессия суммаризирована: %s → %s (экономия %d токенов, новая сессия %s)',
        [CompactNumber(Res.TokensBefore), CompactNumber(Res.TokensAfter),
         Saving, FSessionId])))
  else
  begin
    { Яркое красное предупреждение: суммаризация не дала достаточного
      уменьшения контекста. }
    WriteLn(StdErr, Colored('91',
      Format('Предупреждение: суммаризация дала уменьшение контекста менее %d%% ' +
        '(экономия %d токенов). Текущая сессия не может быть более сокращена.',
        [FCfg.SummarizeMinSavingPercent, Saving])));
  end;
end;

{ Авто-суммаризация: проверяет порог заполнения контекста.
  Срабатывает, если контекст >= порога И предыдущая суммаризация была
  менее 50% (или не было суммаризации вовсе). }
procedure TMirmidApp.CheckAutoSummarize;
var
  Threshold: Integer;
  Cur: Integer;
begin
  Threshold := SummarizeThreshold(FCfg);
  if Threshold <= 0 then
    Exit;
  Cur := FAgent.ContextTokens;
  if Cur < Threshold then
    Exit;
  { Если предыдущая суммаризация была эффективной — не повторяем. }
  if FLastSummarizeEffective then
    Exit;
  DoSummarize;
end;

function TMirmidApp.RunOne(const Prompt: string): Integer;
var
  FinalText, Err: string;
  Msgs: TMessages;
  M: TMessage;
  N: Integer;
  Ok: Boolean;
begin
  { Ход один: промпт сразу попадает в историю. Сессия сохраняется в любом
    случае — и после ошибки модели (например «HTTP 400 Bad Request»), и
    после исключения внутри хода (task2.md): иначе история неудачного хода
    теряется и разобрать причину нечем. }
  Result := 1;
  Ok := False;
  FAgent.AddUser(Prompt);
  { Кэш контекста основной сессии — перед запросом: в режиме планирования ход
    ведёт планировщик, и aeContext с глубиной 0 в это время не приходит, а
    строке анализа и шага нужно значение main (формат main/sub/total). Сразу
    после хода кэш обновляется ещё раз — в историю добавились ответ и отчёт. }
  UpdateMainContext;
  try
    try
      if FCfg.PlanMode then
      begin
        { Режим планирования: план → шаги → отчёт. }
        if FPlanner.RunPlannedTurn(Prompt, FAgent.Messages, FinalText, Err) then
        begin
          { Отчёт — assistant-сообщение в истории сессии. }
          Msgs := FAgent.Messages;
          M := MakeMessage(mrAssistant, FinalText);
          N := Length(Msgs);
          SetLength(Msgs, N + 1);
          Msgs[N] := M;
          FAgent.Messages := Msgs;
          Ok := True;
        end
        else
          { Планировщик событие aeError не шлёт — ошибку печатаем сами. }
          WriteError(Err);
      end
      else if FAgent.RunTurn(FinalText, Err) then
        { Ошибку хода печатает событие aeError. }
        Ok := True;

      if Ok then
      begin
        { Кэш контекста основной сессии — после хода: в историю добавились
          ответ модели и (в режиме планирования) отчёт. }
        UpdateMainContext;
        { Итоговая строка статуса остаётся на экране после хода (task2.md). }
        KeepContextStatus;
        CheckAutoSummarize;
      end;
    except
      on E: Exception do
      begin
        { Исключение внутри хода не роняет сессию: печатаем причину и идём
          дальше — сохранение сессии ниже выполнится в любом случае. }
        FPrinter.PrepareStatic;
        WriteError('исключение при выполнении хода: ' + E.ClassName + ': ' +
          E.Message);
      end;
    end;
  finally
    SaveCurrentSession;
  end;
  if Ok then
    Result := 0;
end;

procedure TMirmidApp.Repl;
var
  Line, Cmd, Arg, V: string;
begin
  WriteLn(Output, MIRMID_NAME, ' ', MIRMID_VERSION, ' — модель: ', FCfg.Model,
    ' @ ', FCfg.BaseUrl);
  WriteLn(Output, 'Инструменты: ', FReg.Names);
  if (FMcp <> nil) and (FMcp.ToolCount > 0) then
    WriteLn(Output, 'MCP: ', FMcp.ServerList, ' — инструментов: ', FMcp.ToolCount);
  WriteLn(Output, 'Сессия: ', FSessionId, '   (/help — справка, /exit — выход)');
  while true do
  begin
    { Сначала гасим временную строку статуса (PrepareStatic стирает её
      через ClearLine и допечатывает хвост незавершённой строки), и только
      потом печатаем приглашение: оно начинается с чистой строки и не
      приклеивается к остатку статуса. }
    FPrinter.PrepareStatic;
    Write(Output, Colored(C_PROMPT, '|> '));
    Flush(Output);
    if EOF(Input) then
      break;
    ReadLn(Input, Line);
    Line := Trim(Line);
    if Line = '' then
      Continue;
    if Line[1] = '/' then
    begin
      Cmd := Line;
      Arg := '';
      if Pos(' ', Line) > 0 then
      begin
        Cmd := Copy(Line, 1, Pos(' ', Line) - 1);
        Arg := Trim(Copy(Line, Pos(' ', Line) + 1, MaxInt));
      end;
      if (Cmd = '/exit') or (Cmd = '/quit') or (Cmd = '/q') then
        Break
      else if Cmd = '/help' then
        WriteLn('Команды: /help, /exit, /reset, /tools, /mcp, /model NAME, ',
          '/system TEXT, /reasoning [MODE], /session, /plan, /history, ',
          '/summarize')
      else if Cmd = '/reset' then
      begin
        FAgent.Reset;
        { Кэш основной сессии: после очистки истории контекст — только
          системная подсказка и схемы инструментов. }
        UpdateMainContext;
        WriteLn('Диалог очищен.');
      end
      else if Cmd = '/tools' then
        WriteLn(FReg.Names)
      else if Cmd = '/mcp' then
      begin
        if FMcp = nil then
          WriteLn('MCP-серверы не подключены.')
        else if FMcp.ToolCount = 0 then
          WriteLn('MCP-серверы: ', FMcp.ServerList, ' (инструментов нет)')
        else
        begin
          WriteLn('MCP-серверы: ', FMcp.ServerList);
          WriteLn(FMcp.ToolList);
        end;
      end
      else if Cmd = '/model' then
      begin
        if Arg <> '' then
        begin
          FCfg.Model := Arg;
          FAgent.Config := FCfg;
          WriteLn('Модель: ', FCfg.Model);
        end
        else
          WriteLn('Текущая модель: ', FCfg.Model);
      end
      else if Cmd = '/system' then
      begin
        FCfg.SystemPrompt := Arg;
        FAgent.Config := FCfg;
        FAgent.Reset;
        WriteLn('Системная подсказка обновлена, диалог очищен.');
      end
      else if Cmd = '/reasoning' then
      begin
        if Arg = '' then
        begin
          if FCfg.Reasoning = '' then
            WriteLn('Режим рассуждений: не задан (по умолчанию провайдера)')
          else
            WriteLn('Режим рассуждений: ', FCfg.Reasoning);
        end
        else
        begin
          V := NormalizeReasoning(Arg);
          if V = '' then
            WriteLn('Неизвестный режим: ', Arg,
              ' (none, minimal, low, medium, high)')
          else
          begin
            FCfg.Reasoning := V;
            FAgent.Config := FCfg;
            WriteLn('Режим рассуждений: ', V);
          end;
        end;
      end
      else if Cmd = '/session' then
        WriteLn(FSessionId)
      else if Cmd = '/plan' then
      begin
        { Текущий план (режим планирования) или «плана нет». }
        if (FPlanner <> nil) and (FPlanner.Plan <> nil) then
          WriteLn(FPlanner.Plan.Render)
        else
          WriteLn('плана нет');
      end
      else if Cmd = '/history' then
        WriteLn('Сообщений: ', Length(FAgent.Messages))
      else if Cmd = '/summarize' then
        DoSummarize
      else
        WriteLn('Неизвестная команда: ', Cmd);
      Continue;
    end;
    RunOne(Line);
  end;
  SaveCurrentSession;
  WriteLn('До свидания.');
end;

function TMirmidApp.Execute(const Cli: TCli): Integer;
var
  Prompt, Err: string;
  Plan: TPlan;
begin
  FNoSession := Cli.NoSession;
  FShowReasoning := Cli.ShowReasoning;
  FShowStepTask := Cli.ShowStepTask;
  FShowStepResult := Cli.ShowStepResult;
  FSessionId := Cli.SessionId;

  if Cli.ListSessions then
  begin
    if ListSessions(SessionDir(FCfg.WorkDir), Prompt) then
    begin
      if Prompt = '' then
        WriteLn('(сессий пока нет)')
      else
        Write(Prompt);
    end
    else
      WriteError('не удалось получить список сессий');
    Exit(0);
  end;

  if Cli.PromptFile <> '' then
  begin
    if not ReadTextFile(Cli.PromptFile, Prompt, Err) then
    begin
      WriteError('не удалось прочитать ' + Cli.PromptFile + ': ' + Err);
      Exit(2);
    end;
  end
  else
    Prompt := Cli.Prompt;

  LoadOrNewSession(Plan);
  { Если план не передан планировщику (нет режима планирования) — освободить. }
  Plan.Free;

  { База имён файлов вспомогательных сессий (субагенты, шаги плана):
    id основной сессии; в режиме --no-session пусто — они не сохраняются. }
  if not FNoSession then
  begin
    FAgent.SessionBase := FSessionId;
    if FPlanner <> nil then
      FPlanner.SessionBase := FSessionId;
  end;

  { Запрашиваем у хоста контекст модели (для эффективного контекста). }
  FetchHostContext;

  { Планировщик в интерактивном режиме (флаг -i или REPL без запроса)
    после планирования завершает ход: шаги выполняются по следующему
    указанию пользователя. }
  if FPlanner <> nil then
    FPlanner.Interactive := Cli.Interactive or (Prompt = '');

  if Cli.Interactive or ((Prompt = '') and (not Cli.ListModels)) then
  begin
    { Интерактивный режим цикличен: если запрос задан в командной строке,
      он выполняется первым ходом, затем REPL продолжает цикл. }
    if (Cli.Interactive) and (Prompt <> '') then
      RunOne(Prompt);
    Repl;
    Exit(0);
  end;

  if Prompt = '' then
  begin
    WriteLn(StdErr, 'Не задан запрос. См. mirmid --help');
    Exit(2);
  end;

  Result := RunOne(Prompt);
end;

{ Подключает MCP-серверы и печатает их инструменты (для --list-mcp). }
function ListMcpTools(const Cfg: TMirmidConfig): Integer;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  Path: string;
  W: TStringList;
  I: Integer;
begin
  Path := Cfg.McpConfig;
  if Path <> '' then
    Path := ExpPath(Path, Cfg.WorkDir)
  else
    Path := DefaultMcpConfigPath(Cfg.WorkDir);
  if not FileExists(Path) then
  begin
    WriteError('файл MCP-конфигурации не найден: ' + Path);
    Exit(1);
  end;
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, Cfg.McpTimeout);
  W := TStringList.Create;
  try
    Mcp.LoadFromFile(Path, W);
    for I := 0 to W.Count - 1 do
      WriteWarning(W[I]);
    if Mcp.ToolCount = 0 then
      WriteLn('MCP-инструментов не найдено.')
    else
    begin
      WriteLn('MCP-серверы: ', Mcp.ServerList);
      WriteLn(Mcp.ToolList);
    end;
    Result := 0;
  finally
    W.Free;
    Mcp.Free;
    Reg.Free;
  end;
end;

{ ------------------------------------------------------------------- main }

function Main: Integer;
var
  Cli: TCli;
  Cfg: TMirmidConfig;
  WorkDir, Err, Models: string;
  App: TMirmidApp;
  Client: TLLMClient;
  Args: array of string;
  I: Integer;
begin
  Err := '';
  SetLength(Args, ParamCount);
  for I := 0 to ParamCount - 1 do
    Args[I] := ParamStr(I + 1);
  if not ParseCli(Args, Cli, Err) then
  begin
    WriteError(Err);
    WriteLn(StdErr, 'См. mirmid --help');
    Exit(2);
  end;

  if Cli.ShowHelp then
  begin
    WriteLn(USAGE);
    Exit(0);
  end;

  if Cli.ShowVersion then
  begin
    WriteLn(FullVersion);
    Exit(0);
  end;

  WorkDir := Cli.WorkDir;
  { Неизвестный ключ в [tools] (и прочие непригодные настройки) — фатальная
    ошибка до старта сессии: печатаем причину и выходим с кодом 1. }
  if not ResolveConfig(Cli, Cfg, WorkDir, Err) then
  begin
    WriteError(Err);
    Exit(1);
  end;

  if Cli.DoInit then
    begin
      if SaveSampleIni(ProjectConfigPath(WorkDir), Cfg, Err) then
        WriteLn('Создан файл: ', ProjectConfigPath(WorkDir))
      else
      begin
        WriteError(Err);
        Exit(1);
      end;
      Exit(0);
    end;

  { Диагностика снимка корней выводится один раз за процесс, до первого
    HTTPS-запроса (её печатает и -v при свежем снимке). Ветка --init выше уже
    вышла: при генерации INI сеть не используется. }
  WarnEmbeddedRoots(Cfg);

  if Cli.ListModels then
    begin
      Client := TLLMClient.Create(Cfg);
      try
        if Client.ListModels(Models, Err) then
          Write(Models)
        else
        begin
          WriteError(Err);
          Exit(1);
        end;
      finally
        Client.Free;
      end;
      Exit(0);
    end;

    if Cli.ListMcp then
    begin
      Result := ListMcpTools(Cfg);
      Exit;
    end;

  App := TMirmidApp.Create(Cfg);
  try
    try
      Result := App.Execute(Cli);
    except
      on E: Exception do
      begin
        { Исключение вне хода (REPL, команды, планировщик) не должно оставить
          сессию несохранённой: печатаем причину и сохраняем историю, уже
          накопленную в сессии (task2.md). }
        WriteError('исключение: ' + E.ClassName + ': ' + E.Message);
        App.SaveCurrentSession;
        Result := 1;
      end;
    end;
  finally
    App.Free;
  end;
end;

end.
