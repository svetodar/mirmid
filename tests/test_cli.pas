unit test_cli;
{ Регрессия форматирования событий CLI: FormatStepEnd (aeStepEnd) не должен
  оставлять «битый» байт от UTF-8-разделителя « — » и укорачивает только
  результат. Без сети. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TCliFormatTests = class(TTestCase)
  published
    { Разделитель « — » — 5 байт; раньше результат начинался с P + 3 и в
      вывод попадал хвостовой байт тире. }
    procedure TestStepEndKeepsUtf8Separator;
    { Нет разделителя — текст возвращается без изменений. }
    procedure TestStepEndNoSeparator;
    { Длинный результат укорачивается, заголовок «s1: done» сохраняется. }
    procedure TestStepEndShortensResult;
  end;

  TCliSubAgentOutputTests = class(TTestCase)
  published
    { DepthPrefix(0) — пустая строка (корневая сессия). }
    procedure TestDepthPrefixZero;
    { DepthPrefix(1) — один серый символ │. }
    procedure TestDepthPrefixOne;
    { DepthPrefix(2) — два символа │. }
    procedure TestDepthPrefixTwo;
    { FormatContextStatus: формат [время|текущий/общий|процент%]. }
    procedure TestFormatContextStatus;
    { FormatContextStatus: Total=0 — неизвестный общий размер. }
    procedure TestFormatContextStatusUnknownTotal;
    { FormatContextStatus с WithTime = False — без времени (часть субагента). }
    procedure TestFormatContextStatusNoTime;
    { Процент в строке статуса: округление до 0.1 без локали, '?' при
      неизвестном общем размере окна модели. }
    procedure TestFormatContextStatusPercent;
    { FormatSubAgentStatus: время печатает только часть основной сессии. }
    procedure TestSubAgentStatusTimeOnlyInMainPart;
    { FormatSubAgentStatus с меткой: «subagent» заменяется меткой под-сессии. }
    procedure TestSubAgentStatusCustomLabel;
    { FormatAnalysisStatus: «[ЧЧ:ММ:СС|main/sub/total|процент-main%/
      процент-sub%] анализ» — статус анализа первым, метка вторым; тега
      [анализ] нет, проценты считаются от общего окна модели. }
    procedure TestFormatAnalysisStatus;
    { FormatAnalysisStatus с контекстом основной сессии (MainCur > 0): в
      строке три счётчика и два процента, как у строки шага. }
    procedure TestFormatAnalysisStatusWithMain;
  end;

  { Строка шага плана: «[ЧЧ:ММ:СС|main/sub/total|процент-main%/
    процент-sub%] имя». Статус идёт первым, затем имя; часы в строке одни,
    префикса │ у шага нет, тега [шаг] тоже нет. }
  TCliStepOutputTests = class(TTestCase)
  published
    { Формат: статус контекста шага, затем имя шага (без тега). }
    procedure TestFormatStepStatus;
    { main/sub/total: оба счётчика в строке, два процента от общего окна. }
    procedure TestFormatStepStatusMainCounters;
    { MainCur не передан (контекст родителя не измерен) — main = 0. }
    procedure TestFormatStepStatusWithoutMain;
    { Пустое имя шага — остаётся один статус без хвостового пробела. }
    procedure TestFormatStepStatusEmptyName;
    { Под-сессия шага печатается с нулевой глубиной: префикса │ нет. }
    procedure TestFormatStepStatusNoDepthPrefix;
    { StepShortName: «s1: описание» → «s1» для закреплённой строки done. }
    procedure TestStepShortName;
  end;

  { Гейтинг текста шага плана: текст под-сессии шага и его результат
    печатаются только по --show-step-result или --show-reasoning.
    Проверяются все четыре комбинации флагов. }
  TCliStepGatingTests = class(TTestCase)
  published
    { Ни одного флага — текст шага скрыт (видны только строки статуса). }
    procedure TestStepTextHiddenByDefault;
    { Только --show-step-result — текст шага виден. }
    procedure TestStepTextShownByStepResult;
    { Только --show-reasoning — текст шага тоже виден. }
    procedure TestStepTextShownByReasoning;
    { Оба флага — видимость та же (дизъюнкция, не XOR). }
    procedure TestStepTextShownByBoth;
  end;

  { Гейтинг задания шага плана — строки «[шаг] имя» (aeStepStart): она
    печатается только по --show-step-task или --show-reasoning, при обоих
    off — не печатается (имя остаётся в строке статуса). --show-step-result
    к заданию не применяется: он про текст ответа и результат шага.
    Перебираются все восемь комбинаций трёх флагов. }
  TCliStepTaskGatingTests = class(TTestCase)
  published
    { Все восемь комбинаций: видимость = ShowStepTask or ShowReasoning. }
    procedure TestAllFlagCombinations;
    { Ни одного флага — задание не печатается (значение по умолчанию off). }
    procedure TestTaskHiddenByDefault;
    { Только --show-reasoning — задание печатается (независимо от
      --show-step-task). }
    procedure TestTaskShownByReasoningOnly;
    { Только --show-step-task — задание печатается. }
    procedure TestTaskShownByStepTaskOnly;
    { Один --show-step-result — задание всё равно скрыто: флаг относится к
      тексту/результату шага (StepTextVisible), а не к заданию. }
    procedure TestStepResultDoesNotShowTask;
    { --show-step-result не мешает показу, если задание включено другим
      флагом. }
    procedure TestStepResultIgnoredWhenTaskShown;
  end;

  { Гейтинг вывода инструментов (строка «[имя] аргументы», «$ команда» и
    результаты aeToolResult): task2.md — вывод печатается только вместе с
    размышлениями (--show-reasoning), независимо от того, основная это сессия,
    под-сессия субагента или под-сессия планировщика («анализ», «шаг sN»). }
  TCliToolOutputGatingTests = class(TTestCase)
  published
    { Без --show-reasoning вывод инструментов скрыт в любой сессии. }
    procedure TestHiddenByDefault;
    { Один --show-reasoning включает вывод инструментов. }
    procedure TestShownByReasoning;
  end;

  { Разбор --tool-output-lines (лимит строк вывода инструментов: по умолчанию
    9, 0 — без ограничения). Проверяется только ParseCli — без сети, INI и
    окружения; перенос значения в настройки (ResolveConfig) зависит от файла
    конфигурации и переменных хоста, поэтому здесь не трогается. }
  TCliParseToolOutputLinesTests = class(TTestCase)
  published
    { Без флага: HasToolOutputLines = False, значение 0 (лимит берётся из
      настроек; FillChar обнуляет запись TCli). }
    procedure TestDefaultOff;
    { Форма с отдельным аргументом: --tool-output-lines 15. }
    procedure TestSpaceForm;
    { Форма --tool-output-lines=12 (значение через «=»). }
    procedure TestInlineForm;
    { Ноль — явное «без ограничения», ключ считается заданным. }
    procedure TestZeroMeansUnlimited;
    { Нет значения — ошибка разбора, Err непустой, ключ не выставлен. }
    procedure TestMissingValue;
    { Флаг не мешает разбору соседних опций и запроса: остальные поля
      (ShowReasoning, Prompt) сохраняются. }
    procedure TestAlongsideOtherOptions;
  end;


  { Размер контекста для строки статуса: EffectiveContextWindow берёт минимум
    из значения настроек и значения, сообщённого хостом (LLM-сервером),
    чтобы проценты не считались от завышенного размера. }
  TEffectiveContextWindowTests = class(TTestCase)
  published
    { Хост не сообщил размер (0) — используется ContextWindow из настроек. }
    procedure TestHostUnsetUsesConfig;
    { Хост сообщил меньший размер — берётся он. }
    procedure TestHostSmallerWins;
    { Хост сообщил больший размер — остаётся значение настроек. }
    procedure TestHostLargerIgnored;
    { Равенство и отрицательное значение хоста — значение из настроек. }
    procedure TestEqualAndNegativeHost;
  end;
  { Учёт токенов строки статуса (регрессия дефекта: размер контекста
    субагента был неверным — базой считался 0). }
  TContextTokensTests = class(TTestCase)
  published
    { База субагента берётся из aeContext, а не 0. }
    procedure TestSubAgentBaseFromContext;
    { Токены ответа основной сессии и субагента не смешиваются. }
    procedure TestMainAndSubAccumSeparate;
    { Регрессия: токены размышлений при Depth > 0 считаются всегда —
      порциями, до первого aeContext и в строке под-сессии (шаг плана). }
    procedure TestReasoningTokensDepthGreaterZero;
    { Вход в субагента сбрасывает счётчики предыдущего субагента. }
    procedure TestEnterSubAgentResets;
    { Основная сессия показывает только одну часть статуса (без «subagent»). }
    procedure TestMainStatusHasNoSubPart;
    { MainTokens: контекст основной сессии (база + токены ответа) — нужен
      строке шага/анализа в формате main/sub/total. }
    procedure TestMainTokensAccessor;
    { Метка под-сессии в Text: «subagent» заменяется переданной меткой. }
    procedure TestTextCustomLabel;
    { Строка анализа собирается из счётчиков под-сессии (SubTokens) и
      контекста основной сессии (MainTokens), как строка шага; тега [анализ]
      нет, проценты считаются от общего окна модели. }
    procedure TestAnalysisLineMainAndSubCounters;
    { Выход из вложенной под-сессии возвращает счётчики родительской. }
    procedure TestExitSubSessionRestoresParent;
    { Стек счётчиков: SavedCount растёт на входе и падает на выходе. }
    procedure TestSavedCountTracksDepth;
    { UnwindTo снимает незакрытые вложенные под-сессии, сохраняя родителя. }
    procedure TestUnwindToRestoresParent;
    { ResetSubSession очищает счётчики и стек (падение шага, revise_plan). }
    procedure TestResetSubSessionClears;
    { Выход без входа — простое обнуление. }
    procedure TestExitWithoutEnterZeroes;
  end;
  { Контракт командной строки после перехода на секцию [tools]: справка
    описывает модель ключей и не содержит убранных флагов, а сами убранные
    флаги отвергаются разбором как неизвестные. }
  TCliToolsModelTests = class(TTestCase)
  published
    { В справке есть секция [tools] и нет --allow-write/--no-write,
      --allow-shell/--no-shell, --allow-http/--no-http. }
    procedure TestHelpMentionsToolsSection;
    { В справке нет упоминаний удалённых настроек доверия. }
    procedure TestHelpHasNoCaFile;
    { Убранные флаги — ошибка разбора («неизвестная опция»). }
    procedure TestRemovedFlagsRejected;
  end;

  { Сохранение основной сессии после неудачного хода (task2.md).
    Интеграционный тест на собранный bin/mirmid: ход с недоступным
    провайдером завершается ошибкой, но сессия обязана быть записана
    вместе с сообщением пользователя. Бинарник не собран — тест
    пропускается (make test сам bin/mirmid не собирает). }
  TCliSessionTurnTests = class(TTestCase)
  published
    procedure TestSessionSavedAfterFailedTurn;
  end;
  { Фатальная ошибка на неизвестный ключ в секции [tools] (собранный
    bin/mirmid): опечатка не должна молча оставить инструмент со значением по
    умолчанию, поэтому запуск завершается кодом 1 и сообщением с именем ключа
    и списком известных инструментов. Бинарник не собран — тест пропускается. }
  TCliUnknownToolKeyTests = class(TTestCase)
  published
    procedure TestUnknownToolKeyExitsWithCodeOne;
    procedure TestInitRepairsBrokenToolsSection;
  end;

implementation

uses
  Classes, SysUtils, process, mirmid.cli, mirmid.session, mirmid.types, mirmid.util;

procedure TCliFormatTests.TestStepEndKeepsUtf8Separator;
var
  InText, OutText: string;
begin
  InText := 's1: done — ' + 'Каталог успешно создан';
  OutText := FormatStepEnd(InText);
  AssertEquals('разделитель и UTF-8 результат не повреждены', InText, OutText);
end;

procedure TCliFormatTests.TestStepEndNoSeparator;
var
  InText: string;
begin
  InText := 's1: удалён из плана';
  AssertEquals('без разделителя текст не меняется', InText, FormatStepEnd(InText));
end;

procedure TCliFormatTests.TestStepEndShortensResult;
var
  Head, Tail, OutText: string;
begin
  Head := 's2: failed — ';
  Tail := StringOfChar('x', 500);
  OutText := FormatStepEnd(Head + Tail);
  AssertTrue('заголовок сохранён', Pos('s2: failed — ', OutText) = 1);
  { Shorten: 400 байт результата + '…' (3 байта UTF-8). }
  AssertEquals('результат укорочен до предела', 400 + 3, Length(OutText) - Length(Head));
  AssertEquals('в конце многоточие', '…', Copy(OutText, Length(OutText) - 2, MaxInt));
end;

{ ------------------------------------------------------- subagent output }

procedure TCliSubAgentOutputTests.TestDepthPrefixZero;
begin
  AssertEquals('глубина 0 — пустой префикс', '', DepthPrefix(0));
end;

procedure TCliSubAgentOutputTests.TestDepthPrefixOne;
var
  Pfx: string;
begin
  Pfx := DepthPrefix(1);
  AssertTrue('есть символ │', Pos('│', Pfx) > 0);
end;

procedure TCliSubAgentOutputTests.TestDepthPrefixTwo;
var
  Pfx1, Pfx2: string;
begin
  Pfx1 := DepthPrefix(1);
  Pfx2 := DepthPrefix(2);
  AssertTrue('есть символ │', Pos('│', Pfx2) > 0);
  AssertTrue('глубина 2 длиннее глубины 1', Length(Pfx2) > Length(Pfx1));
end;

procedure TCliSubAgentOutputTests.TestFormatContextStatus;
var
  S: string;
begin
  S := FormatContextStatus(1000, 128000);
  AssertTrue('начинается с [', S[1] = '[');
  AssertTrue('заканчивается ]', S[Length(S)] = ']');
  AssertTrue('есть разделитель |', Pos('|', S) > 0);
  AssertTrue('есть процент %', Pos('%', S) > 0);
  AssertTrue('есть текущий размер', Pos('1k', S) > 0);
  AssertTrue('есть общий размер', Pos('128k', S) > 0);
  { Процент с десятыми: 1000 из 128000 — «0.8%» (точка, не запятая). }
  AssertTrue('процент 0.8%', Pos('|0.8%]', S) > 0);
  { WithTime по умолчанию True: время (hh:nn:ss) в строке есть. }
  AssertTrue('есть время ЧЧ:ММ:СС', Pos(':', S) > 0);
end;

{ Процент в строке статуса считается от общего окна модели в десятых
  долях без участия локали (точка), граничные значения — 0.0%, 50.0% и
  100.0%; неизвестное окно (Total <= 0) даёт '?'. }
procedure TCliSubAgentOutputTests.TestFormatContextStatusPercent;
var
  S: string;
begin
  S := FormatContextStatus(0, 128000, False);
  AssertTrue('нет контекста — 0.0%: ' + S, Pos('|0.0%]', S) > 0);

  S := FormatContextStatus(1000, 128000, False);
  AssertTrue('0.8% (округление до 0.1): ' + S, Pos('|0.8%]', S) > 0);

  S := FormatContextStatus(64000, 128000, False);
  AssertTrue('половина окна — 50.0%: ' + S, Pos('|50.0%]', S) > 0);

  S := FormatContextStatus(128000, 128000, False);
  AssertTrue('окно заполнено — 100.0%: ' + S, Pos('|100.0%]', S) > 0);

  S := FormatContextStatus(500, 0, False);
  AssertTrue('неизвестное окно — ?: ' + S, Pos('|?]', S) > 0);
  AssertEquals('запятой в проценте нет: ' + S, 0, Pos(',', S));
end;

procedure TCliSubAgentOutputTests.TestFormatContextStatusUnknownTotal;
var
  S: string;
begin
  S := FormatContextStatus(500, 0);
  AssertTrue('начинается с [', S[1] = '[');
  AssertTrue('неизвестный общий размер', Pos('/?', S) > 0);
  AssertTrue('неизвестный процент', Pos('|?]', S) > 0);
end;

{ Часть строки статуса, отведённая субагенту, печатается без даты и времени:
  часы (hh:nn:ss) на строку одни. }
procedure TCliSubAgentOutputTests.TestFormatContextStatusNoTime;
var
  S: string;
begin
  S := FormatContextStatus(1000, 128000, False);
  AssertTrue('начинается с [', S[1] = '[');
  AssertEquals('времени нет', 0, Pos(':', S));
  AssertTrue('текущий размер на месте', Pos('1k', S) > 0);
  AssertTrue('общий размер на месте', Pos('128k', S) > 0);
  AssertTrue('процент на месте', Pos('%', S) > 0);

  { Неизвестный общий размер — тоже без времени. }
  S := FormatContextStatus(500, 0, False);
  AssertEquals('времени нет и при неизвестном общем размере', 0, Pos(':', S));
  AssertTrue('неизвестный общий размер', Pos('/?', S) > 0);
end;

{ Строка статуса субагента: слово «subagent», размеры обеих сессий, время —
  только в части основной сессии (два двоеточия из hh:nn:ss). }
procedure TCliSubAgentOutputTests.TestSubAgentStatusTimeOnlyInMainPart;
var
  S: string;
  I, Colons: Integer;
begin
  S := FormatSubAgentStatus(1000, 2000, 128000);
  AssertTrue('есть слово subagent', Pos('subagent', S) > 0);
  AssertTrue('контекст основной сессии', Pos('1k', S) > 0);
  AssertTrue('контекст субагента', Pos('2k', S) > 0);
  Colons := 0;
  for I := 1 to Length(S) do
    if S[I] = ':' then
      Inc(Colons);
  AssertEquals('время только в части основной сессии', 2, Colons);
end;

{ Метка под-сессии параметризована: планировщик передаёт «шаг s1»/«анализ»,
  субагент — значение по умолчанию «subagent». }
procedure TCliSubAgentOutputTests.TestSubAgentStatusCustomLabel;
var
  S: string;
begin
  S := FormatSubAgentStatus(1000, 2000, 128000, 'анализ');
  AssertTrue('метка анализа: ' + S, Pos('анализ', S) > 0);
  AssertEquals('слова subagent нет', 0, Pos('subagent', S));
  AssertTrue('часть основной сессии на месте', Pos('1k', S) > 0);
  AssertTrue('часть под-сессии на месте', Pos('2k', S) > 0);

  S := FormatSubAgentStatus(1000, 2000, 128000);
  AssertTrue('по умолчанию метка subagent', Pos('subagent', S) > 0);
end;

{ Убирает ANSI-последовательности цветов: проверяем текст строки, а не
  зависит ли вывод от включённых в окружении теста цветов. }
function StripAnsi(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
    if (S[I] = #27) and (I < Length(S)) and (S[I + 1] = '[') then
    begin
      Inc(I, 2);
      while (I <= Length(S)) and (S[I] <> 'm') do
        Inc(I);
      Inc(I);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
end;

{ -------------------------------------------- строка анализа плана }

{ Строка под-сессии анализа: «[ЧЧ:ММ:СС|main/sub/total|процент-main%/
  процент-sub%] анализ» — тот же порядок, что у строки шага
  (FormatStepStatus): сначала статус с контекстом основной сессии и
  под-сессии анализа, затем через один пробел серая метка «анализ». Тега
  [анализ] нет; часы одни; проценты считаются от общего окна модели, поэтому
  их два. Без переданного MainCur контекст родителя равен нулю (headless). }
procedure TCliSubAgentOutputTests.TestFormatAnalysisStatus;
const
  LabelText = 'анализ';
var
  S, StatusPart: string;
  I, Colons, StatusEnd, Brackets: Integer;
begin
  S := StripAnsi(FormatAnalysisStatus(1500, 128000));
  AssertEquals('строка начинается со статуса: ' + S, '[', Copy(S, 1, 1));
  AssertTrue('статус и метка через один пробел: ' + S,
    Pos('] ' + LabelText, S) > 0);
  AssertEquals('метка анализа закрывает строку: ' + S, LabelText,
    Copy(S, Length(S) - Length(LabelText) + 1, MaxInt));
  AssertEquals('тега [анализ] нет: ' + S, 0, Pos('[' + LabelText + ']', S));
  AssertEquals('слова subagent нет: ' + S, 0, Pos('subagent', S));
  { main/sub/total: без контекста родителя main = 0. }
  AssertTrue('счётчики main/sub/total (0/1.5k/128k): ' + S,
    Pos('0/1.5k/128k', S) > 0);
  AssertTrue('общий размер (128k): ' + S, Pos('128k', S) > 0);
  { Два процента от одного окна: main 0 → 0.0%, под-сессия → 1.2%. }
  AssertTrue('два процента от общего окна: ' + S, Pos('|0.0%/1.2%', S) > 0);
  { Один статус — значит, второй скобки [ нет (части под-сессий не
    печатаются раздельно, как в FormatSubAgentStatus). }
  Brackets := 0;
  for I := 1 to Length(S) do
    if S[I] = '[' then
      Inc(Brackets);
  AssertEquals('статус в строке один: ' + S, 1, Brackets);
  { Часы (два двоеточия) — в части статуса до закрывающей скобки, а не в
    метке или счётчиках. }
  StatusEnd := Pos(']', S);
  AssertTrue('статус закрыт квадратной скобкой: ' + S, StatusEnd > 0);
  StatusPart := Copy(S, 1, StatusEnd);
  Colons := 0;
  for I := 1 to Length(StatusPart) do
    if StatusPart[I] = ':' then
      Inc(Colons);
  AssertEquals('часы в строке одни (ЧЧ:ММ:СС)', 2, Colons);
  { Неизвестный общий размер — тот же порядок, без тега [анализ]. }
  S := StripAnsi(FormatAnalysisStatus(500, 0));
  AssertTrue('неизвестный общий размер: ' + S, Pos('0/500/?|?/?]', S) > 0);
  AssertEquals('метка анализа и при неизвестном размере: ' + S, LabelText,
    Copy(S, Length(S) - Length(LabelText) + 1, MaxInt));
  AssertEquals('тега [анализ] нет: ' + S, 0, Pos('[' + LabelText + ']', S));
end;

{ Контекст основной сессии передан (режим планирования: основной ход уже
  измерен кэшем CLI) — строка анализа содержит все три счётчика и два
  процента, как строка шага. }
procedure TCliSubAgentOutputTests.TestFormatAnalysisStatusWithMain;
var
  S: string;
begin
  S := StripAnsi(FormatAnalysisStatus(1500, 128000, 7000));
  AssertTrue('контекст основной сессии в строке (7k/1.5k/128k): ' + S,
    Pos('7k/1.5k/128k', S) > 0);
  AssertTrue('проценты обоих счётчиков (5.5%/1.2%): ' + S,
    Pos('|5.5%/1.2%', S) > 0);
  AssertEquals('метка анализа закрывает строку: ' + S, 'анализ',
    Copy(S, Length(S) - Length('анализ') + 1, MaxInt));
end;

{ ------------------------------------------------ строка шага плана }

{ Строка шага: «[ЧЧ:ММ:СС|main/sub/total|процент-main%/процент-sub%]
  имя». Статус идёт первым, затем через один пробел — имя шага; тега [шаг]
  нет, часы в строке одни, отступа │ нет — под-сессия шага печатается
  с нулевой глубиной. Счётчики: контекст основной сессии (MainCur), шага
  (Cur) и общее окно модели (Total); процент считается от Total для каждого
  счётчика отдельно. }
procedure TCliStepOutputTests.TestFormatStepStatus;
const
  StepName = 's1: обновить README';
var
  S, StatusPart: string;
  I, Colons, StatusEnd: Integer;
begin
  S := StripAnsi(FormatStepStatus(StepName, 1200, 128000, 8000));
  AssertEquals('строка начинается со статуса: ' + S, '[', Copy(S, 1, 1));
  AssertEquals('тега [шаг] больше нет: ' + S, 0, Pos('[шаг]', S));
  AssertEquals('имя шага закрывает строку: ' + S, StepName,
    Copy(S, Length(S) - Length(StepName) + 1, MaxInt));
  AssertTrue('статус и имя через один пробел: ' + S,
    Pos('] ' + StepName, S) > 0);
  AssertTrue('есть разделитель |: ' + S, Pos('|', S) > 0);
  AssertTrue('есть процент %: ' + S, Pos('%', S) > 0);
  { main/sub/total: контекст основной сессии, шага и окно модели. }
  AssertTrue('счётчики main/sub/total (8k/1.2k/128k): ' + S,
    Pos('8k/1.2k/128k', S) > 0);
  AssertTrue('общий размер (128k): ' + S, Pos('128k', S) > 0);
  { Два процента от одного окна: main 8k → 6.3%, шаг 1.2k → 0.9%. }
  AssertTrue('два процента от общего окна (6.3%/0.9%): ' + S,
    Pos('|6.3%/0.9%', S) > 0);
  AssertEquals('префикса │ у шага нет: ' + S, 0, Pos('│', S));
  { Часы (два двоеточия) — только в части статуса до первого ']', а не в
    имени шага («s1: …» тоже содержит двоеточие). }
  StatusEnd := Pos(']', S);
  AssertTrue('статус закрыт квадратной скобкой: ' + S, StatusEnd > 0);
  StatusPart := Copy(S, 1, StatusEnd);
  Colons := 0;
  for I := 1 to Length(StatusPart) do
    if StatusPart[I] = ':' then
      Inc(Colons);
  AssertEquals('часы в строке одни (ЧЧ:ММ:СС)', 2, Colons);
end;

{ Проценты считаются от одного окна модели: при полном контексте основной
  сессии первый процент — 100.0%, процент шага — от того же Total. Значение
  main идёт первым счётчиком, шаг — вторым. }
procedure TCliStepOutputTests.TestFormatStepStatusMainCounters;
var
  S: string;
begin
  S := StripAnsi(FormatStepStatus('s3: тесты', 1000, 128000, 128000));
  AssertTrue('main/sub/total (128k/1k/128k): ' + S,
    Pos('128k/1k/128k', S) > 0);
  AssertTrue('проценты от одного окна (100.0%/0.8%): ' + S,
    Pos('|100.0%/0.8%', S) > 0);
  AssertTrue('имя шага на месте: ' + S, Pos('] s3: тесты', S) > 0);
end;

{ Контекст родителя ещё не измерен (MainCur не передан): строка остаётся
  формата main/sub/total, но main равен нулю — шаг не подставляет чужие
  счётчики вместо контекста основной сессии. }
procedure TCliStepOutputTests.TestFormatStepStatusWithoutMain;
var
  S: string;
begin
  S := StripAnsi(FormatStepStatus('s1: обновить README', 1200, 128000));
  AssertTrue('main по умолчанию 0 (0/1.2k/128k): ' + S,
    Pos('0/1.2k/128k', S) > 0);
  AssertTrue('проценты (0.0%/0.9%): ' + S, Pos('|0.0%/0.9%', S) > 0);
end;

{ Пустое имя (шаг без описания) — остаётся только строка статуса: без тега
  [шаг] и без хвостового пробела. }
procedure TCliStepOutputTests.TestFormatStepStatusEmptyName;
var
  S: string;
  I, Colons: Integer;
begin
  S := StripAnsi(FormatStepStatus('', 500, 0));
  AssertEquals('строка начинается со статуса: ' + S, '[', Copy(S, 1, 1));
  { main/sub/total при неизвестном окне: «0/500/?|?/?». }
  AssertTrue('неизвестный общий размер: ' + S, Pos('0/500/?|?/?]', S) > 0);
  AssertEquals('строка закрывается статусом, без хвостового пробела: ' + S,
    ']', Copy(S, Length(S), 1));
  AssertEquals('тега [шаг] нет: ' + S, 0, Pos('[шаг]', S));
  AssertEquals('префикса │ нет: ' + S, 0, Pos('│', S));
  Colons := 0;
  for I := 1 to Length(S) do
    if S[I] = ':' then
      Inc(Colons);
  AssertEquals('часы в строке одни и без имени', 2, Colons);
end;
{ У шага плана нет префикса │: его под-сессия печатается с нулевой
  глубиной, поэтому строка начинается со статуса, а отступа-«ёлочки» из
  DepthPrefix нет ни перед ним, ни внутри строки; тега [шаг] тоже нет. }
procedure TCliStepOutputTests.TestFormatStepStatusNoDepthPrefix;
const
  Names: array[0..2] of string = ('s1: обновить README', 's2: тесты', '');
  Curs: array[0..2] of Integer = (1200, 0, 99999);
  Totals: array[0..2] of Integer = (128000, 0, 1000000);
var
  I: Integer;
  S: string;
begin
  for I := Low(Names) to High(Names) do
  begin
    S := StripAnsi(FormatStepStatus(Names[I], Curs[I], Totals[I]));
    AssertEquals('строка шага начинается со статуса, без отступа │: ' + S,
      '[', Copy(S, 1, 1));
    AssertEquals('префикса │ в строке шага нет: ' + S, 0, Pos('│', S));
    { DepthPrefix(1) — серый │, которым помечаются вложенные субагенты. }
    AssertEquals('глубина печати шага нулевая: ' + S, 0, Pos(DepthPrefix(1), S));
    { Метка «subagent» — признак второй части статуса под-сессии. }
    AssertEquals('метки под-сессии subagent у шага нет: ' + S,
      0, Pos('subagent', S));
    AssertEquals('тега [шаг] нет: ' + S, 0, Pos('[шаг]', S));
    if Names[I] = '' then
      AssertEquals('пустое имя — строка закрывается статусом: ' + S,
        ']', Copy(S, Length(S), 1))
    else
      AssertEquals('имя шага закрывает строку: ' + S, Names[I],
        Copy(S, Length(S) - Length(Names[I]) + 1, MaxInt));
  end;
end;
{ StepShortName — короткое имя для закреплённой done-строки: из
  «s1: описание» остаётся только идентификатор; без двоеточия имя не
  меняется, пустое остаётся пустым (вне шага). }
procedure TCliStepOutputTests.TestStepShortName;
begin
  AssertEquals('описание отброшено', 's1',
    StepShortName('s1: обновить README'));
  AssertEquals('пробелы вокруг идентификатора срезаны', 's2',
    StepShortName('  s2 : тесты  '));
  AssertEquals('без двоеточия — как есть', 's3', StepShortName('s3'));
  AssertEquals('пустое имя остаётся пустым', '', StepShortName(''));
  { Двоеточие внутри описания: берётся только часть до первого. }
  AssertEquals('первое двоеточие — граница', 's4',
    StepShortName('s4: правка: context.md'));
end;


{ ------------------------------------ гейтинг текста шага плана }

{ Ни --show-step-result, ни --show-reasoning: текст под-сессии шага и его
  результат скрыты, от шага остаются только строки статуса. }
procedure TCliStepGatingTests.TestStepTextHiddenByDefault;
begin
  AssertFalse('без флагов текст шага скрыт', StepTextVisible(False, False));
end;

{ Один --show-step-result включает текст шага (и результат в aeStepEnd). }
procedure TCliStepGatingTests.TestStepTextShownByStepResult;
begin
  AssertTrue('--show-step-result показывает текст шага',
    StepTextVisible(True, False));
end;

{ Один --show-reasoning включает текст шага тем же условием: в aeStreamText
  и aeStepEnd проверяется дизъюнкция флагов. }
procedure TCliStepGatingTests.TestStepTextShownByReasoning;
begin
  AssertTrue('--show-reasoning показывает текст шага',
    StepTextVisible(False, True));
end;

{ Оба флага: результат тот же — видимость не зависит от второго флага
  (условие «or», а не XOR). }
procedure TCliStepGatingTests.TestStepTextShownByBoth;
begin
  AssertTrue('оба флага показывают текст шага',
    StepTextVisible(True, True));
end;

{ ---------------------------------- гейтинг задания шага плана }

{ Все восемь комбинаций трёх флагов: строка «[шаг] имя» видна ровно тогда,
  когда включён --show-step-task или --show-reasoning; --show-step-result
  на задание шага не влияет. }
procedure TCliStepTaskGatingTests.TestAllFlagCombinations;
var
  Task, Reason, Res, Shown: Boolean;
  I, J, K: Integer;
  S: string;
begin
  for I := 0 to 1 do
    for J := 0 to 1 do
      for K := 0 to 1 do
      begin
        Task := I = 1;
        Reason := J = 1;
        Res := K = 1;
        Shown := StepTaskVisible(Task, Reason, Res);
        S := Format('task=%d reasoning=%d step-result=%d',
          [Ord(Task), Ord(Reason), Ord(Res)]);
        AssertTrue('ожидалось ShowStepTask or ShowReasoning: ' + S,
          Shown = (Task or Reason));
      end;
end;

{ Значения по умолчанию (все флаги off): задание шага не печатается —
  видна только строка статуса с именем шага. }
procedure TCliStepTaskGatingTests.TestTaskHiddenByDefault;
begin
  AssertFalse('без флагов задание шага скрыто',
    StepTaskVisible(False, False, False));
end;

{ Один --show-reasoning включает задание шага независимо от
  --show-step-task. }
procedure TCliStepTaskGatingTests.TestTaskShownByReasoningOnly;
begin
  AssertTrue('--show-reasoning показывает задание шага',
    StepTaskVisible(False, True, False));
end;

{ Один --show-step-task включает задание шага. }
procedure TCliStepTaskGatingTests.TestTaskShownByStepTaskOnly;
begin
  AssertTrue('--show-step-task показывает задание шага',
    StepTaskVisible(True, False, False));
end;

{ Один --show-step-result задание шага не показывает: этот флаг про текст
  ответа и результат шага (StepTextVisible), а не про само задание. }
procedure TCliStepTaskGatingTests.TestStepResultDoesNotShowTask;
begin
  AssertFalse('--show-step-result не показывает задание шага',
    StepTaskVisible(False, False, True));
end;

{ --show-step-result не отменяет показ задания, включённого другим флагом. }
procedure TCliStepTaskGatingTests.TestStepResultIgnoredWhenTaskShown;
begin
  AssertTrue('--show-step-task + --show-step-result',
    StepTaskVisible(True, False, True));
  AssertTrue('--show-reasoning + --show-step-result',
    StepTaskVisible(False, True, True));
end;

{ ------------------------------ гейтинг вывода инструментов }

{ По умолчанию (--show-reasoning off) вывод инструментов скрыт везде: в
  основной сессии, у субагента и в под-сессиях планировщика — как в шагах
  плана. Печатаются только строки статуса и финальный текст. }
procedure TCliToolOutputGatingTests.TestHiddenByDefault;
begin
  AssertFalse('без --show-reasoning вывод инструментов скрыт',
    ToolOutputVisible(False));
end;

{ Один --show-reasoning включает вывод инструментов во всех сессиях: гейтинг
  больше не зависит от метки под-сессии (task2.md). }
procedure TCliToolOutputGatingTests.TestShownByReasoning;
begin
  AssertTrue('--show-reasoning показывает вывод инструментов',
    ToolOutputVisible(True));
end;

{ ----------------------------------- эффективный размер контекста }

{ Хост не сообщил размер (0) — EffectiveContextWindow возвращает значение из
  настроек; значение по умолчанию тоже осмысленно (> 0). }
procedure TEffectiveContextWindowTests.TestHostUnsetUsesConfig;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  AssertEquals('по умолчанию ContextWindow — 128k', 128000, Cfg.ContextWindow);
  AssertEquals('хост не сообщил размер', 0, Cfg.HostContextWindow);
  AssertEquals('берётся значение настроек', Cfg.ContextWindow,
    EffectiveContextWindow(Cfg));

  Cfg.ContextWindow := 32000;
  AssertEquals('значение настроек, а не DEFAULT', 32000,
    EffectiveContextWindow(Cfg));
end;

{ Хост сообщил меньший размер — строке статуса нужен именно он, иначе
  проценты считаются от завышенного контекста. }
procedure TEffectiveContextWindowTests.TestHostSmallerWins;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  Cfg.ContextWindow := 128000;
  Cfg.HostContextWindow := 32000;
  AssertEquals('минимум из настроек и хоста', 32000, EffectiveContextWindow(Cfg));

  Cfg.ContextWindow := 16000;
  Cfg.HostContextWindow := 9000;
  AssertEquals('минимум не зависит от порядка значений', 9000,
    EffectiveContextWindow(Cfg));
end;

{ Хост сообщил размер больше настроечного (или равный) — остаётся значение
  из настроек: EffectiveContextWindow никогда не увеличивает контекст. }
procedure TEffectiveContextWindowTests.TestHostLargerIgnored;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  Cfg.ContextWindow := 128000;
  Cfg.HostContextWindow := 200000;
  AssertEquals('больший размер хоста игнорируется', 128000,
    EffectiveContextWindow(Cfg));

  Cfg.ContextWindow := 8000;
  Cfg.HostContextWindow := 8001;
  AssertEquals('на единицу больше — тоже значение настроек', 8000,
    EffectiveContextWindow(Cfg));
end;

{ Равные значения дают то же число, а отрицательное значение хоста
  трактуется как «не сообщено». }
procedure TEffectiveContextWindowTests.TestEqualAndNegativeHost;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  Cfg.ContextWindow := 64000;
  Cfg.HostContextWindow := 64000;
  AssertEquals('равные значения — без изменений', 64000,
    EffectiveContextWindow(Cfg));

  Cfg.HostContextWindow := -1;
  AssertEquals('отрицательное значение хоста — значение настроек', 64000,
    EffectiveContextWindow(Cfg));
end;

{ ------------------------------------------------- учёт токенов статуса }

{ База субагента — размер его собственного контекста из aeContext. Раньше
  в CLI она принудительно обнулялась, и статус показывал только токены
  текущего ответа. }
procedure TContextTokensTests.TestSubAgentBaseFromContext;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 5000);            { основная сессия: 5k }
    T.SetBase(1, 1200);            { субагент: 1.2k }
    T.AddResponseTokens(1, 300);   { + токены ответа }
    S := T.Text(128000, 1);
    AssertTrue('размер субагента из aeContext (1.5k): ' + S, Pos('1.5k', S) > 0);
    AssertTrue('основная сессия на месте (5k): ' + S, Pos('5k', S) > 0);
  finally
    T.Free;
  end;
end;

{ Токены ответа разных сессий не смешиваются. }
procedure TContextTokensTests.TestMainAndSubAccumSeparate;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 1000);
    T.AddResponseTokens(0, 100);
    T.SetBase(1, 2000);
    T.AddResponseTokens(1, 200);
    S := T.Text(128000, 1);
    AssertTrue('основная сессия 1.1k: ' + S, Pos('1.1k', S) > 0);
    AssertTrue('субагент 2.2k: ' + S, Pos('2.2k', S) > 0);
  finally
    T.Free;
  end;
end;

{ Регрессия учёта токенов размышлений при Depth > 0: размышления приходят
  отдельными порциями (иногда до первого aeContext под-сессии) и должны
  прибавляться к счётчикам под-сессии, не затрагивая основную сессию.
  Раньше при скрытом тексте порции могли теряться, и строка шага плана
  показывала заниженный размер контекста. }
procedure TContextTokensTests.TestReasoningTokensDepthGreaterZero;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 5000);            { основная сессия: 5k }
    T.SetBase(1, 1200);            { под-сессия шага: 1.2k }
    T.AddResponseTokens(1, 90);    { размышления тремя порциями }
    T.AddResponseTokens(1, 150);
    T.AddResponseTokens(1, 400);
    AssertEquals('токены размышлений учтены в под-сессии',
      1840, T.SubTokens);
    S := T.Text(128000, 1, 'шаг s1');
    AssertTrue('статус под-сессии содержит 1.8k: ' + S, Pos('1.8k', S) > 0);
    AssertTrue('основная сессия на месте (5k): ' + S, Pos('5k', S) > 0);
    AssertEquals('размышления не попали в основную сессию',
      0, Pos('5.6k', S));
    { Вход в новую под-сессию: размышления до её первого aeContext
      тоже учитываются (база 0 + накопленное). }
    T.EnterSubAgent;
    T.AddResponseTokens(1, 250);
    AssertEquals('размышления до aeContext учтены', 250, T.SubTokens);
    S := T.Text(128000, 1, 'шаг s2');
    AssertTrue('статус под-сессии содержит 250: ' + S, Pos('250', S) > 0);
  finally
    T.Free;
  end;
end;

{ Вход в субагента — счётчики предыдущего субагента не должны «протекать». }
procedure TContextTokensTests.TestEnterSubAgentResets;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 2000);
    T.AddResponseTokens(1, 400);
    T.EnterSubAgent;
    S := T.Text(128000, 1);
    AssertEquals('контекст субагента сброшен', 0, Pos('2.4k', S));
    AssertTrue('статус субагента показывает ноль: ' + S, Pos('0/128k', S) > 0);
  finally
    T.Free;
  end;
end;

{ В основной сессии части «subagent» нет. }
procedure TContextTokensTests.TestMainStatusHasNoSubPart;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 3000);
    S := T.Text(128000, 0);
    AssertEquals('нет слова subagent', 0, Pos('subagent', S));
    AssertTrue('размер основной сессии (3k): ' + S, Pos('3k', S) > 0);
  finally
    T.Free;
  end;
end;

{ MainTokens — контекст основной сессии (база из её aeContext плюс
  накопленные токены текущего ответа). Нужен строке шага/анализа в формате
  main/sub/total: SubTokens отдаёт только под-сессию, поэтому без отдельного
  аксессора контекст родителя было бы не взять. }
procedure TContextTokensTests.TestMainTokensAccessor;
var
  T: TContextTokens;
begin
  T := TContextTokens.Create;
  try
    AssertEquals('до событий контекст 0', 0, T.MainTokens);
    T.SetBase(0, 5000);            { aeContext основной сессии }
    AssertEquals('база основной сессии', 5000, T.MainTokens);
    T.AddResponseTokens(0, 300);   { токены текущего ответа }
    AssertEquals('база + токены ответа', 5300, T.MainTokens);
    { Токены под-сессии в основную не попадают. }
    T.SetBase(1, 1200);
    T.AddResponseTokens(1, 200);
    AssertEquals('основная сессия не изменилась', 5300, T.MainTokens);
    AssertEquals('счётчики под-сессии отдельно', 1400, T.SubTokens);
    { Выход из под-сессии основную сессию не трогает. }
    T.ExitSubSession;
    AssertEquals('после выхода — те же 5300', 5300, T.MainTokens);
  finally
    T.Free;
  end;
end;

{ Метка под-сессии в строке статуса: планировщик передаёт «шаг s2»/«анализ».
  Text остаётся форматом вложенной сессии (глубина > 1): основная сессия +
  метка + под-сессия; строка анализа на глубине 1 собирается отдельно —
  FormatAnalysisStatus (см. TestAnalysisLineMainAndSubCounters). }
procedure TContextTokensTests.TestTextCustomLabel;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 1200);
    S := T.Text(128000, 1, 'шаг s2');
    AssertTrue('метка шага: ' + S, Pos('шаг s2', S) > 0);
    AssertEquals('слова subagent нет', 0, Pos('subagent', S));
    AssertTrue('размер под-сессии (1.2k): ' + S, Pos('1.2k', S) > 0);

    S := T.Text(128000, 1, 'анализ');
    AssertTrue('метка анализа: ' + S, Pos('анализ', S) > 0);
    AssertTrue('размер под-сессии (1.2k): ' + S, Pos('1.2k', S) > 0);

    S := T.Text(128000, 1);
    AssertTrue('по умолчанию метка subagent', Pos('subagent', S) > 0);
  finally
    T.Free;
  end;
end;

{ Строка анализа (глубина 1) строится FormatAnalysisStatus из счётчиков
  под-сессии (SubTokens) и контекста основной сессии (MainTokens), как строка
  шага: main/sub/total и два процента от общего окна. Тега [анализ] нет,
  порядок — сначала статус, затем метка. Прежний вид (основная сессия +
  метка + под-сессия) остался в Text для вложенных сессий (глубина > 1),
  поэтому проверяются оба пути. }
procedure TContextTokensTests.TestAnalysisLineMainAndSubCounters;
var
  T: TContextTokens;
  S, Legacy: string;
  I, Colons: Integer;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 7000);            { основная сессия: 7k }
    T.SetBase(1, 1200);
    T.AddResponseTokens(1, 300);   { токены ответа анализа: 1.5k }
    S := StripAnsi(FormatAnalysisStatus(T.SubTokens, 128000, T.MainTokens));
    AssertEquals('статус идёт первым: ' + S, '[', Copy(S, 1, 1));
    { Оба счётчика в строке: контекст родителя и под-сессии анализа. }
    AssertTrue('счётчики main/sub/total (7k/1.5k/128k): ' + S,
      Pos('7k/1.5k/128k', S) > 0);
    { Проценты обоих счётчиков — от одного окна модели. }
    AssertTrue('два процента (5.5%/1.2%): ' + S, Pos('|5.5%/1.2%', S) > 0);
    AssertTrue('метка анализа на месте: ' + S, Pos('анализ', S) > 0);
    AssertEquals('тега [анализ] нет: ' + S, 0, Pos('[анализ]', S));
    AssertEquals('слова subagent нет: ' + S, 0, Pos('subagent', S));
    Colons := 0;
    for I := 1 to Length(S) do
      if S[I] = ':' then
        Inc(Colons);
    AssertEquals('часы в строке одни (ЧЧ:ММ:СС)', 2, Colons);

    { Прежний вид (основная сессия + метка + под-сессия) остаётся в Text:
      им печатается вложенная сессия (глубина > 1). }
    Legacy := StripAnsi(T.Text(128000, 1, 'анализ'));
    AssertTrue('Text сохраняет часть основной сессии (7k): ' + Legacy,
      Pos('7k', Legacy) > 0);
    AssertTrue('Text сохраняет счётчики анализа (1.5k): ' + Legacy,
      Pos('1.5k', Legacy) > 0);
  finally
    T.Free;
  end;
end;

{ «шаг плана → субагент»: выход из субагента возвращает счётчики шага, иначе
  после вложенной сессии шаг показывал бы 0. }
procedure TContextTokensTests.TestExitSubSessionRestoresParent;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 1500);
    T.AddResponseTokens(1, 200);   { шаг: 1.7k }
    T.EnterSubAgent;               { внутри шага — субагент }
    T.SetBase(1, 400);
    S := T.Text(128000, 1, 'шаг s1');
    AssertTrue('субагент 400: ' + S, Pos('400', S) > 0);
    AssertEquals('счётчики шага не видны изнутри', 0, Pos('1.7k', S));

    T.ExitSubSession;
    S := T.Text(128000, 1, 'шаг s1');
    AssertTrue('счётчики шага восстановлены (1.7k): ' + S, Pos('1.7k', S) > 0);
  finally
    T.Free;
  end;
end;

{ Стек счётчиков: SavedCount растёт на входе и падает на выходе. }
procedure TContextTokensTests.TestSavedCountTracksDepth;
var
  T: TContextTokens;
begin
  T := TContextTokens.Create;
  try
    AssertEquals('стек пуст', 0, T.SavedCount);
    T.EnterSubAgent;
    AssertEquals('один уровень', 1, T.SavedCount);
    T.EnterSubAgent;
    AssertEquals('два уровня', 2, T.SavedCount);
    T.ExitSubSession;
    AssertEquals('вернулись на уровень шага', 1, T.SavedCount);
    T.ResetSubSession;
    AssertEquals('сброс очистил стек', 0, T.SavedCount);
  finally
    T.Free;
  end;
end;

{ Непарный вход вложенной под-сессии (субагент упал, aeToolResult не пришёл):
  UnwindTo по отметке входа снимает лишние пары, сохраняя счётчики шага. }
procedure TContextTokensTests.TestUnwindToRestoresParent;
var
  T: TContextTokens;
  S: string;
  Mark: Integer;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 1000);            { шаг }
    Mark := T.SavedCount;          { отметка входа в шаг: 0 }
    T.EnterSubAgent;
    T.SetBase(1, 300);
    T.EnterSubAgent;               { незакрытый вложенный субагент }
    T.SetBase(1, 50);
    AssertEquals('два уровня вложенности', 2, T.SavedCount);

    T.UnwindTo(Mark);              { откат к состоянию перед входом в шаг }
    AssertEquals('стек снят до отметки', 0, T.SavedCount);
    S := T.Text(128000, 1, 'шаг s1');
    AssertTrue('счётчики шага восстановлены (1k): ' + S, Pos('1k', S) > 0);
    AssertEquals('значения вложенной сессии не протекли', 0, Pos('300', S));
  finally
    T.Free;
  end;
end;

{ Выход из внешней под-сессии (шаг/анализ), в том числе после падения шага
  или revise_plan: счётчики и стек очищены, основная сессия на месте. }
procedure TContextTokensTests.TestResetSubSessionClears;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 4000);
    T.SetBase(1, 2000);
    T.AddResponseTokens(1, 100);
    T.EnterSubAgent;
    T.SetBase(1, 700);

    T.ResetSubSession;
    AssertEquals('стек очищен', 0, T.SavedCount);
    S := T.Text(128000, 1, 'анализ');
    AssertTrue('под-сессия обнулена: ' + S, Pos('0/128k', S) > 0);
    AssertTrue('основная сессия сохранена (4k): ' + S, Pos('4k', S) > 0);
    AssertTrue('метка под-сессии сохранена: ' + S, Pos('анализ', S) > 0);
  finally
    T.Free;
  end;
end;

{ Выход без парного входа — простое обнуление, стек не портится. }
procedure TContextTokensTests.TestExitWithoutEnterZeroes;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 900);
    T.ExitSubSession;
    AssertEquals('стек пуст', 0, T.SavedCount);
    S := T.Text(128000, 1, 'анализ');
    AssertTrue('счётчики обнулены: ' + S, Pos('0/128k', S) > 0);
    AssertTrue('метка анализа: ' + S, Pos('анализ', S) > 0);
  finally
    T.Free;
  end;
end;

{ --- Сохранение сессии после неудачного хода (task2.md) -------------------

  Интеграционный тест на собранный бинарник bin/mirmid. Ход завершается
  ошибкой (провайдер недоступен: 127.0.0.1:1) — сессия всё равно должна
  лежать в <workdir>/.mirmid/sessions/<id>.json с сообщением пользователя.
  Внешняя сеть не нужна: соединение отклоняется локально. Бинарник не
  собран — тест пропускается (make test bin/mirmid не собирает). }

function AppExePath: string;
begin
  { Расширение берём у тестраннера: на Windows это «.exe». }
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'mirmid' + ExtractFileExt(ParamStr(0));
end;

{ Запускает mirmid с заданными аргументами и ждёт выхода. Окружение хоста
  очищается от MIRMID_*: тест не должен зависеть от настроек разработчика
  (например MIRMID_PLAN включил бы планировщик). stdout и stderr слиты в один
  поток (poStderrToOutPut): проверяются сообщения об ошибках. }
function RunAppArgs(const Exe: string; const Args: array of string;
  out OutText: string; out ExitCode: Integer): Boolean;
var
  Proc: TProcess;
  Params, Env: TStringList;
  MS: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N, I: Integer;
begin
  Result := False;
  OutText := '';
  ExitCode := -1;
  Params := TStringList.Create;
  Env := TStringList.Create;
  Proc := TProcess.Create(nil);
  MS := TMemoryStream.Create;
  try
    for I := 0 to High(Args) do
      Params.Add(Args[I]);

    EnvironmentToList(Env);
    for I := Env.Count - 1 downto 0 do
      if Pos('MIRMID_', UpperCase(Env.Names[I])) = 1 then
        Env.Delete(I);

    Proc.Executable := Exe;
    Proc.Parameters := Params;
    Proc.Environment := Env;
    Proc.Options := [poUsePipes, poStderrToOutPut];
    Proc.Execute;
    while True do
    begin
      N := Proc.Output.Read(Buf, Length(Buf));
      if N <= 0 then
        Break;
      MS.WriteBuffer(Buf, N);
    end;
    if not Proc.WaitOnExit(60000) then
    begin
      Proc.Terminate(0);
      Exit;
    end;
    ExitCode := Proc.ExitStatus;
    SetLength(OutText, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.ReadBuffer(OutText[1], MS.Size);
    end;
    Result := True;
  finally
    MS.Free;
    Proc.Free;
    Env.Free;
    Params.Free;
  end;
end;

{ Запускает mirmid с недоступным провайдером в отдельном рабочем каталоге. }
function RunAppWithBadProvider(const Exe, WorkDir: string;
  out OutText: string; out ExitCode: Integer): Boolean;
begin
  Result := RunAppArgs(Exe, ['--config',
    IncludeTrailingPathDelimiter(WorkDir) + 'none.ini',
    '--workdir', WorkDir,
    '--base-url', 'http://127.0.0.1:1/v1',
    '--api-key', 'test-key',
    '--model', 'test-model',
    '--no-stream', '--no-mcp',
    '--connect-timeout', '1',
    '--timeout', '5',
    'session-save-check'], OutText, ExitCode);
end;

{ Первый JSON-файл основной сессии (вспомогательные *_sub_/_step_ не в счёт). }
function FirstMainSessionFile(const WorkDir: string): string;
var
  SR: TSearchRec;
  Dir: string;
  More: Boolean;
begin
  Result := '';
  Dir := SessionDir(WorkDir);
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.json', faAnyFile, SR) <> 0 then
    Exit;
  try
    { Без Continue/Break: выход из try-finally внутри repeat закрыл бы поиск,
      и следующий FindNext работал бы с закрытым дескриптором. }
    More := True;
    while More do
    begin
      if ((SR.Attr and faDirectory) = 0) and not IsAuxSessionFile(SR.Name) then
      begin
        Result := IncludeTrailingPathDelimiter(Dir) + SR.Name;
        Break;
      end;
      More := FindNext(SR) = 0;
    end;
  finally
    FindClose(SR);
  end;
end;

{ Рекурсивное удаление временного каталога теста. }
procedure RemoveTree(const Dir: string);
var
  SR: TSearchRec;
  Path: string;
  More: Boolean;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    More := True;
    while More do
    begin
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        Path := IncludeTrailingPathDelimiter(Dir) + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          RemoveTree(Path)
        else
          DeleteFile(Path);
      end;
      More := FindNext(SR) = 0;
    end;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure TCliSessionTurnTests.TestSessionSavedAfterFailedTurn;
var
  Exe, WorkDir, OutText, FileName, SessionText, Err: string;
  ExitCode: Integer;
begin
  Exe := AppExePath;
  if not FileExists(Exe) then
    Exit;   { bin/mirmid не собран — тест пропускается }

  WorkDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'mirmid_session_turn_' + FormatDateTime('hhnnsszzz', Now);
  AssertTrue('временный каталог создан', ForceDirectories(WorkDir));
  try
    AssertTrue('приложение запущено', RunAppWithBadProvider(Exe, WorkDir,
      OutText, ExitCode));
    AssertTrue('ход завершился ошибкой (код ' + IntToStr(ExitCode) + ')',
      ExitCode <> 0);

    FileName := FirstMainSessionFile(WorkDir);
    AssertTrue('сессия сохранена после неудачного хода (нет ' +
      SessionDir(WorkDir) + '/*.json), вывод: ' + OutText, FileName <> '');
    if FileName = '' then
      Exit;

    AssertTrue('сессия читается', ReadTextFile(FileName, SessionText, Err));
    AssertTrue('в сессии сохранён запрос пользователя',
      Pos('session-save-check', SessionText) > 0);
  finally
    RemoveTree(WorkDir);
  end;
end;

{ --- Неизвестный ключ [tools] — фатальная ошибка (E2E) ---------------------

  Собранный bin/mirmid с INI, где в [tools] есть неизвестный ключ, обязан
  завершиться с кодом 1 и назвать ключ со списком известных инструментов:
  молчаливое включение/выключение инструмента из-за опечатки недопустимо.
  Сети тест не требует — сессия не начинается. }

procedure TCliUnknownToolKeyTests.TestUnknownToolKeyExitsWithCodeOne;
var
  Exe, WorkDir, IniFile, OutText, Err: string;
  ExitCode: Integer;
begin
  Exe := AppExePath;
  if not FileExists(Exe) then
    Exit;   { bin/mirmid не собран — тест пропускается }

  WorkDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'mirmid_unknown_tool_' + FormatDateTime('hhnnsszzz', Now);
  AssertTrue('временный каталог создан', ForceDirectories(WorkDir));
  try
    IniFile := IncludeTrailingPathDelimiter(WorkDir) + 'unknown.ini';
    AssertTrue('INI с неизвестным ключом записан',
      WriteTextFile(IniFile, '[tools]' + LineEnding +
        'read_text_file=1' + LineEnding + 'no_such_tool=1' + LineEnding, Err));

    AssertTrue('приложение запущено', RunAppArgs(Exe, ['--config', IniFile,
      '--workdir', WorkDir, '--no-mcp', '--no-stream', 'hello'],
      OutText, ExitCode));
    AssertEquals('неизвестный ключ [tools] — код возврата 1, вывод: ' + OutText,
      1, ExitCode);
    AssertTrue('сообщение называет неизвестный ключ: ' + OutText,
      Pos('unknown tool "no_such_tool"', OutText) > 0);
    AssertTrue('сообщение перечисляет известные инструменты: ' + OutText,
      Pos('known tools:', OutText) > 0);
    { Список известных инструментов непуст: в нём есть ключ из реестра. }
    AssertTrue('в списке есть read_text_file: ' + OutText,
      Pos('read_text_file', OutText) > 0);
  finally
    RemoveTree(WorkDir);
  end;
end;

{ `--init` обязан починить и сломанный INI: если файл содержит неизвестный ключ
  [tools], обычный старт завершается ошибкой, а пересоздать конфигурацию всё
  равно нужно. Проверяется на собранном бинарнике: код 0 и образец со всеми
  ключами [tools]. }
procedure TCliUnknownToolKeyTests.TestInitRepairsBrokenToolsSection;
var
  Exe, WorkDir, IniFile, ConfigFile, OutText, Text, Err: string;
  ExitCode: Integer;
begin
  Exe := AppExePath;
  if not FileExists(Exe) then
    Exit;   { bin/mirmid не собран — тест пропускается }

  WorkDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'mirmid_init_repair_' + FormatDateTime('hhnnsszzz', Now);
  AssertTrue('временный каталог создан', ForceDirectories(WorkDir));
  try
    IniFile := IncludeTrailingPathDelimiter(WorkDir) + 'broken.ini';
    AssertTrue('INI с неизвестным ключом записан',
      WriteTextFile(IniFile, '[tools]' + LineEnding + 'shel=1' + LineEnding, Err));

    AssertTrue('приложение запущено', RunAppArgs(Exe, ['--init', '--config',
      IniFile, '--workdir', WorkDir], OutText, ExitCode));
    AssertEquals('--init со сломанным INI — код 0, вывод: ' + OutText,
      0, ExitCode);

    ConfigFile := IncludeTrailingPathDelimiter(WorkDir) + '.mirmid' + PathDelim +
      'mirmid.ini';
    AssertTrue('образец создан: ' + ConfigFile, FileExists(ConfigFile));
    AssertTrue('образец читается', ReadTextFile(ConfigFile, Text, Err));
    AssertTrue('в образце есть секция [tools]', Pos('[tools]', Text) > 0);
    AssertTrue('в образце есть ключ shell', Pos('shell=', Text) > 0);
  finally
    RemoveTree(WorkDir);
  end;
end;

procedure TCliParseToolOutputLinesTests.TestDefaultOff;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('командная строка разобрана', ParseCli(['привет', 'мир'], Cli, Err));
  AssertEquals('ошибки нет', '', Err);
  AssertFalse('ключ не задан без флага', Cli.HasToolOutputLines);
  AssertEquals('значение по умолчанию — 0 (из настроек)', 0, Cli.ToolOutputLines);
  AssertEquals('запрос сохранён', 'привет мир', Cli.Prompt);
end;

procedure TCliParseToolOutputLinesTests.TestSpaceForm;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('командная строка разобрана',
    ParseCli(['--tool-output-lines', '15'], Cli, Err));
  AssertEquals('ошибки нет', '', Err);
  AssertTrue('ключ задан', Cli.HasToolOutputLines);
  AssertEquals('значение из следующего аргумента', 15, Cli.ToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestInlineForm;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('командная строка разобрана',
    ParseCli(['--tool-output-lines=12'], Cli, Err));
  AssertEquals('ошибки нет', '', Err);
  AssertTrue('ключ задан', Cli.HasToolOutputLines);
  AssertEquals('значение после «=»', 12, Cli.ToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestZeroMeansUnlimited;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('командная строка разобрана',
    ParseCli(['--tool-output-lines', '0'], Cli, Err));
  AssertEquals('ошибки нет', '', Err);
  AssertTrue('0 — тоже явно заданный ключ', Cli.HasToolOutputLines);
  AssertEquals('0 — без ограничения', 0, Cli.ToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestMissingValue;
var
  Cli: TCli;
  Err: string;
begin
  AssertFalse('опция без значения — ошибка разбора',
    ParseCli(['--tool-output-lines'], Cli, Err));
  AssertTrue('сообщение об ошибке непустое', Err <> '');
  AssertTrue('сообщение упоминает опцию', Pos('--tool-output-lines', Err) > 0);
  AssertFalse('ключ не выставлен', Cli.HasToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestAlongsideOtherOptions;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('командная строка разобрана',
    ParseCli(['--show-reasoning', '--tool-output-lines', '5', 'вопрос'], Cli, Err));
  AssertEquals('ошибки нет', '', Err);
  AssertTrue('--show-reasoning разобран', Cli.ShowReasoning);
  AssertTrue('--tool-output-lines разобран', Cli.HasToolOutputLines);
  AssertEquals('значение лимита', 5, Cli.ToolOutputLines);
  AssertEquals('запрос не съеден как значение', 'вопрос', Cli.Prompt);
end;

{ --- TCliToolsModelTests ------------------------------------------------ }

procedure TCliToolsModelTests.TestHelpMentionsToolsSection;
var
  H: string;
begin
  H := UsageText;
  AssertTrue('в справке есть секция [tools]', Pos('[tools]', H) > 0);
  AssertTrue('справка описывает ключи 1/0', Pos('1/0', H) > 0);
  AssertEquals('нет --allow-write', 0, Pos('--allow-write', H));
  AssertEquals('нет --no-write', 0, Pos('--no-write', H));
  AssertEquals('нет --allow-shell', 0, Pos('--allow-shell', H));
  AssertEquals('нет --no-shell', 0, Pos('--no-shell', H));
  AssertEquals('нет --allow-http', 0, Pos('--allow-http', H));
  AssertEquals('нет --no-http', 0, Pos('--no-http', H));
  { Настройки shell остаются флагами и не должны исчезнуть вместе с
    переключателями. }
  AssertTrue('--shell-timeout остался', Pos('--shell-timeout', H) > 0);
  AssertTrue('--tool-output-lines остался', Pos('--tool-output-lines', H) > 0);
end;

procedure TCliToolsModelTests.TestHelpHasNoCaFile;
var
  H: string;
begin
  H := UsageText;
  AssertEquals('нет ключа доверия', 0, Pos('ca' + '_file', H));
  { Имени переменной окружения с путём к бандлу в справке тоже нет: строка
    собирается по частям, чтобы сам тест не содержал искомого текста. }
  AssertEquals('нет переменной окружения с бандлом',
    0, Pos('CA' + '_FILE', H));
end;

procedure TCliToolsModelTests.TestRemovedFlagsRejected;
var
  Cli: TCli;
  Err: string;
begin
  AssertFalse('--allow-write отвергнут',
    ParseCli(['--allow-write'], Cli, Err));
  AssertTrue('сообщение об опции: ' + Err, Pos('--allow-write', Err) > 0);

  AssertFalse('--allow-shell отвергнут',
    ParseCli(['--allow-shell'], Cli, Err));
  AssertFalse('--no-shell отвергнут', ParseCli(['--no-shell'], Cli, Err));
  AssertFalse('--allow-http отвергнут',
    ParseCli(['--allow-http'], Cli, Err));
  AssertFalse('--no-http отвергнут', ParseCli(['--no-http'], Cli, Err));
  AssertFalse('-w отвергнут', ParseCli(['-w'], Cli, Err));
end;

initialization
  RegisterTest(TCliFormatTests);
  RegisterTest(TCliSubAgentOutputTests);
  RegisterTest(TCliStepOutputTests);
  RegisterTest(TCliStepGatingTests);
  RegisterTest(TCliStepTaskGatingTests);
  RegisterTest(TCliToolOutputGatingTests);
  RegisterTest(TCliParseToolOutputLinesTests);
  RegisterTest(TEffectiveContextWindowTests);
  RegisterTest(TContextTokensTests);
  RegisterTest(TCliToolsModelTests);
  RegisterTest(TCliSessionTurnTests);
  RegisterTest(TCliUnknownToolKeyTests);
end.
