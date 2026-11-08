unit test_stream;
{ Регрессия TStreamPrinter (потоковый вывод): без лишних пустых строк,
  ведущие пробелы (отступ) строк сохраняются. Сценарии прогоняются в
  отдельном процессе bin/streamprobe (stdout — конвейер, ANSI-режим
  форсирован), сырой вывод проверяется через простую модель терминала. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry;

type
  TStreamPrinterTests = class(TTestCase)
  private
    { Прогоняет сценарий пробы и возвращает сырой вывод ('' — проба не
      собрана, тест пропускается). Cols > 0 — задать ширину терминала
      (переменная COLUMNS) для процесса пробы. }
    function RunProbe(const Scenario: string; Cols: Integer = 0): string;
    { Простая модель терминала: строки, курсор (строка/колонка). Поддерживает
      CR, LF, ESC[K (очистка до конца строки), ESC[A (вверх) и обычный текст.
      AWidth > 0 — жёсткий перенос строки по этой ширине (как в терминале):
      так проверяется, что частичная строка с префиксом не переполняет
      терминал. Возвращает итоговое состояние экрана. }
    function SimulateTerminal(const S: string; AWidth: Integer = 0): TStringList;
    { Убирает все пробельные символы (для сравнения текста после переноса
      по словам, где пробел на разрыве отбрасывается). }
    function NoSpace(const S: string): string;
  published
    procedure TestNoBlankLineForSpacesPartial;
    procedure TestIndentPreservedReasoning;
    procedure TestIndentPreservedContent;
    procedure TestPrefixWrapNotCorrupted;
    procedure TestDoneStatusKeptAfterSubSession;
    procedure TestPrepareStaticErasesStatus;
    procedure TestStepStatusWithoutPrefix;
    procedure TestStatusRedrawnOnToolCallAndResult;
    procedure TestToolOutputGating;
    procedure TestBlankLineAfterToolOutput;
    procedure TestEndStreamNoGlueBeforePrompt;
    procedure TestStatusStaysAfterTurn;
  end;

implementation

uses
  process, mirmid.util;

function TStreamPrinterTests.RunProbe(const Scenario: string;
  Cols: Integer): string;
var
  Exe: string;
  Proc: TProcess;
  Args, Env: TStringList;
  MS: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  { Расширение исполняемого файла берём у самого тестраннера: на Windows это
    «.exe», без него FileExists пробу не находит и тест молча пропускается. }
  Exe := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'streamprobe' + ExtractFileExt(ParamStr(0));
  if not FileExists(Exe) then
    Exit('');   { проба не собрана — тест пропускается }
  Args := TStringList.Create;
  Env := TStringList.Create;
  Proc := TProcess.Create(nil);
  try
    Args.Add(Scenario);
    Proc.Executable := Exe;
    Proc.Parameters := Args;
    Proc.Options := [poUsePipes];
    if Cols > 0 then
    begin
      { TProcess.Environment заменяет окружение целиком, поэтому
        заполняем его текущим и добавляем COLUMNS для TermWidth. }
      EnvironmentToList(Env);
      Env.Values['COLUMNS'] := IntToStr(Cols);
      Proc.Environment := Env;
    end;
    Proc.Execute;
    MS := TMemoryStream.Create;
    try
      while True do
      begin
        N := Proc.Output.Read(Buf, Length(Buf));
        if N <= 0 then
          Break;
        MS.WriteBuffer(Buf, N);
      end;
      Proc.WaitOnExit(10000);
      MS.Position := 0;
      SetLength(Result, MS.Size);
      if MS.Size > 0 then
        MS.ReadBuffer(Result[1], MS.Size);
    finally
      MS.Free;
    end;
  finally
    Args.Free;
    Env.Free;
    Proc.Free;
  end;
end;

function TStreamPrinterTests.SimulateTerminal(const S: string;
  AWidth: Integer): TStringList;
var
  Row, Col, I, N: Integer;
  C: Char;
  Line: string;
begin
  Result := TStringList.Create;
  Result.Add('');
  Row := 0;
  Col := 0;
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    C := S[I];
    if C = #27 then
    begin
      if (I + 2 <= N) and (S[I + 1] = '[') then
      begin
        if S[I + 2] = 'K' then
        begin
          { Очистка от курсора до конца строки. }
          if Col < Length(Result[Row]) then
            Result[Row] := Copy(Result[Row], 1, Col)
          else
            Result[Row] := '';
          Inc(I, 3);
          Continue;
        end
        else if S[I + 2] = 'A' then
        begin
          if Row > 0 then
            Dec(Row);
          Inc(I, 3);
          Continue;
        end;
      end;
      Inc(I);   { неизвестная ESC-последовательность — пропускаем }
    end
    else if C = #13 then
    begin
      Col := 0;
      Inc(I);
    end
    else if C = #10 then
    begin
      Inc(Row);
      Col := 0;
      while Row >= Result.Count do
        Result.Add('');
      Inc(I);
    end
    else
    begin
      if (AWidth > 0) and (Col >= AWidth) then
      begin
        Inc(Row);
        Col := 0;
      end;
      while Row >= Result.Count do
        Result.Add('');
      if Col < Length(Result[Row]) then
        begin
          Line := Result[Row];
          Line[Col + 1] := C;
          Result[Row] := Line;
        end
      else
        Result[Row] := Result[Row] + C;
      Inc(Col);
      Inc(I);
    end;
  end;
end;

function TStreamPrinterTests.NoSpace(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] > ' ' then
      Result := Result + S[I];
end;

procedure TStreamPrinterTests.TestNoBlankLineForSpacesPartial;
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { Строка «  word» приходит чанками: сначала ведущие пробелы, затем текст.
    Частичная строка из одних пробелов не должна оставлять лишнюю пустую
    строку: на экране ровно строка с отступом, а строка статуса под ней
    временная — EndStream её стирает, в лог она не попадает. }
  Out := RunProbe('spaces-partial');
  if Out = '' then
    Exit;
  { Статус действительно рисовался — иначе проверка экрана была бы
    тривиальной. }
  AssertTrue('статус нарисован в сыром выводе', Pos('[st]', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 2, Screen.Count);
    AssertEquals('строка с отступом', '  word', Screen[0]);
    AssertEquals('под текстом только хвост стёртого статуса', '', Screen[1]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('остатка строки статуса на экране нет', 0, Pos('[st]', All));
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestIndentPreservedReasoning;
var
  Out: string;
  Screen: TStringList;
begin
  { Размышления: ведущие пробелы строки (отступ) сохраняются. }
  Out := RunProbe('indent-reasoning');
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 2, Screen.Count);
    AssertEquals('отступ сохранён', '  indented', Screen[0]);
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestIndentPreservedContent;
var
  Out: string;
  Screen: TStringList;
begin
  { Контент: ведущие пробелы строки (отступ) сохраняются. }
  Out := RunProbe('indent-content');
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 2, Screen.Count);
    AssertEquals('отступ сохранён', '  indented', Screen[0]);
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestPrefixWrapNotCorrupted;
const
  { Должна совпадать с WRAP_TEXT в tests/fixtures/streamprobe.pas. }
  WRAP_TEXT = 'alpha beta gamma delta epsilon zeta eta theta iota kappa ' +
              'lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega';
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { Длинная строка приходит мелкими порциями при префиксе субагента из двух
    колонок. Раньше частичная строка не влезала в терминал (префикс не
    вычитался из ширины), переносилась на вторую строку, и перерисовка
    теряла/дублировала куски слов. Сценарий прогоняется в терминале шириной
    30 колонок (COLUMNS), чтобы частичная строка с префиксом переполняла
    строку. Регрессия: TStreamPrinter.ContentWidth. }
  Out := RunProbe('prefix-wrap', 30);
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out, 30);
  try
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
  finally
    Screen.Free;
  end;
  All := StringReplace(All, '||', '', [rfReplaceAll]);
  All := StringReplace(All, '[st]', '', [rfReplaceAll]);
  AssertEquals('текст не потерян при переносе с префиксом',
    NoSpace(WRAP_TEXT), NoSpace(All));
end;

procedure TStreamPrinterTests.TestDoneStatusKeptAfterSubSession;
const
  { Счётчики done-строки: main-контекст шага, итог шага и окно модели. }
  DONE_COUNTERS = '|6k/2.2k/128k|';
var
  Out, All: string;
  Screen: TStringList;
  I, Dones: Integer;
begin
  { Конец под-сессии шага (task1.md п.4): временная строка статуса стирается
    (EndStream), а PersistDoneStatus закрепляет на её месте done-строку с
    итоговыми счётчиками и коротким именем шага («…] s1 done»). Прежние
    варианты статуса в лог не попадают, а статичный вывод и следующий стрим
    идут с чистой строки под done-строкой.
    Регрессия: TMirmidApp.PersistDoneStatus/DoneStatusText, StepShortName. }
  Out := RunProbe('done-status');
  if Out = '' then
    Exit;
  { Временный статус действительно рисовался, а done-строка закреплена —
    иначе проверка экрана была бы тривиальной. }
  AssertTrue('статус шага нарисован в сыром выводе', Pos('[s1 2]', Out) > 0);
  AssertTrue('done-строка с коротким именем шага в сыром выводе',
    Pos('] s1 done', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 6, Screen.Count);
    AssertEquals('первая строка шага', '||first', Screen[0]);
    AssertEquals('вторая строка шага', '||second', Screen[1]);
    AssertEquals('done-строка под текстом шага', True,
      Pos('] s1 done', Screen[2]) > 0);
    AssertEquals('в done-строке итоговые счётчики', True,
      Pos(DONE_COUNTERS, Screen[2]) > 0);
    AssertEquals('статичный вывод под done-строкой', '||after done', Screen[3]);
    AssertEquals('строка следующего стрима', '||third', Screen[4]);
    AssertEquals('под последним стримом только хвост перевода строки', '',
      Screen[5]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('временного статуса шага на экране нет', 0, Pos('[s1 2]', All));
    AssertEquals('строки статуса второго стрима на экране нет', 0,
      Pos('[s2', All));
    Dones := 0;
    for I := 0 to Screen.Count - 1 do
      if Pos('] s1 done', Screen[I]) > 0 then
        Inc(Dones);
    AssertEquals('done-строка на экране ровно одна', 1, Dones);
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestPrepareStaticErasesStatus;
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { PrepareStatic при нарисованной строке статуса (FStatusShown=True) стирает
    её, а не печатает в scrollback. Сценарий рисует статус (BeginStream,
    FeedContent), зовёт PrepareStatic — статичная строка встаёт с начала
    чистой строки; затем рисует статус заново (DrawStatus, как после
    aeToolCall) и снова готовит статичный вывод. В итоговом экране нет ни
    строки статуса, ни её хвоста, а повторный PrepareStatic без статуса не
    оставляет пустой строки. Регрессия: TStreamPrinter.PrepareStatic. }
  Out := RunProbe('prepare-static-status');
  if Out = '' then
    Exit;
  { В сыром выводе статус действительно рисовался — иначе проверка экрана
    ниже была бы тривиальной. }
  AssertTrue('статус нарисован в сыром выводе',
    Pos('long status tail', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 5, Screen.Count);
    AssertEquals('текст под стёртым статусом', '||line one', Screen[0]);
    AssertEquals('статичный вывод на месте статуса', '||static after status',
      Screen[1]);
    AssertEquals('статичный вывод на месте нарисованного статуса',
      '||static after draw', Screen[2]);
    AssertEquals('повторный PrepareStatic не оставил пустой строки',
      '||third static', Screen[3]);
    AssertEquals('под последним выводом только хвост перевода строки', '',
      Screen[4]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('остатка строки статуса на экране нет', 0,
      Pos('long status tail', All));
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestStepStatusWithoutPrefix;
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { Под-сессия шага плана печатается без префикса «│» (глубина печати 0), а
    строка статуса шага («[ЧЧ:ММ:СС|main/sub/total|%/%] имя») временная: её
    стирает EndStream, а на aeSubSessionEnd вместо неё закрепляется done-строка
    с коротким именем «s1» и итоговыми счётчиками. Отступ даёт только вложенный
    инструмент subagent — ровно один «│» на строку; его результат печатается
    статично (PrepareStatic) с начала чистой строки, а после выхода префикс
    снова пустой. Регрессия FPrintDepth/FPrinter.Prefix, формата
    FormatStepStatus и закрепления done-строки. }
  Out := RunProbe('step-status');
  if Out = '' then
    Exit;
  { Временный статус действительно рисовался — иначе проверка экрана была бы
    тривиальной; счётчики в нём — main/шаг/окно. }
  AssertTrue('статус шага нарисован в сыром выводе',
    Pos('|6k/1.3k/128k|', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 6, Screen.Count);
    AssertEquals('текст шага без отступа', 'step line', Screen[0]);
    AssertEquals('текст вложенного субагента с одним │', '│sub line', Screen[1]);
    AssertEquals('результат вложенного субагента с одним │', '│sub result',
      Screen[2]);
    AssertEquals('продолжение шага без отступа', 'step tail', Screen[3]);
    AssertEquals('done-строка шага под текстом', True,
      Pos('] s1 done', Screen[4]) > 0);
    AssertEquals('в done-строке итоговые счётчики шага', True,
      Pos('|6k/1.7k/128k|', Screen[4]) > 0);
    AssertEquals('под done-строкой только хвост перевода строки', '',
      Screen[5]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('временного статуса (1.6k) на экране нет', 0,
      Pos('|6k/1.6k/128k|', All));
    AssertEquals('имени шага на экране нет (в done-строке только «s1»)', 0,
      Pos('s1: шаг', All));
    AssertEquals('тега [шаг] нет нигде в выводе', 0, Pos('[шаг]', Out));
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestStatusRedrawnOnToolCallAndResult;
const
  { Тексты задания шагов из сценария step-task-gating. }
  TASK1 = 's1: скрытое задание';
  TASK2 = 's2: задание по флагу';
  TASK3 = 's3: задание по размышлениям';
var
  Out, Tail, All: string;
  Screen: TStringList;
  I: Integer;
  CallPos, ResultPos: Integer;
  S1Task, S2Task, S3Task: Boolean;
  Statuses, Dones: Integer;
begin
  { Строка статуса временная, но на время работы инструмента она не теряется:
    строка вызова и его результата печатаются на месте нарисованного статуса
    (aeToolCall делает ClearLine, aeToolResult — PrepareStaticOverStatus), а
    статус затем рисуется заново под ними (DrawStatus). Сценарий повторяет эти
    ветки: под «[read] task1.md» нарисован статус с 3.2k, под «result text» — с
    3.3k. К концу под-сессии (EndStream) временный статус стирается, а на его
    месте PersistDoneStatus закрепляет done-строку с коротким именем «sN» и
    итоговыми счётчиками — поэтому временных статусов на экране нет, а
    done-строк ровно по числу завершённых шагов. Формат статуса —
    «[ЧЧ:ММ:СС|main/sub/total|%/%] имя» (статус первым, тега [шаг] нет). }
  Out := RunProbe('step-task-gating');
  if Out = '' then
    Exit;

  { Сырой вывод: статус с новыми счётчиками напечатан после строки вызова и
    после строки результата — это и есть DrawStatus. }
  CallPos := Pos('[read] task1.md', Out);
  AssertTrue('строка вызова инструмента напечатана', CallPos > 0);
  ResultPos := Pos('result text', Out);
  AssertTrue('строка результата инструмента напечатана', ResultPos > 0);
  Tail := Copy(Out, CallPos, ResultPos - CallPos);
  AssertTrue('статус 3.2k нарисован заново под вызовом инструмента',
    Pos('3.2k', Tail) > 0);
  Tail := Copy(Out, ResultPos, Length(Out));
  AssertTrue('статус 3.3k нарисован заново под результатом инструмента',
    Pos('3.3k', Tail) > 0);

  Screen := SimulateTerminal(Out);
  try
    { Итоговый экран: временных статусов шагов нет (EndStream их стёр), вместо
      них под текстом каждого шага стоят done-строки; остались ещё задания
      (гейтинг task1) и строки вызова/результата инструмента. За последним
      выводом — только хвост перевода строки. }
    AssertEquals('строк на экране', 12, Screen.Count);
    AssertEquals('текст первого шага', 'step one', Screen[0]);
    AssertEquals('done-строка первого шага', True,
      Pos('] s1 done', Screen[1]) > 0);
    AssertEquals('счётчики первого шага в done-строке', True,
      Pos('|5k/1.2k/128k|', Screen[1]) > 0);
    AssertEquals('задание второго шага по --show-step-task', TASK2, Screen[2]);
    AssertEquals('текст второго шага', 'step two', Screen[3]);
    AssertEquals('done-строка второго шага', True,
      Pos('] s2 done', Screen[4]) > 0);
    AssertEquals('счётчики второго шага в done-строке', True,
      Pos('|5k/2.2k/128k|', Screen[4]) > 0);
    AssertEquals('задание третьего шага по --show-reasoning', TASK3, Screen[5]);
    AssertEquals('текст третьего шага', 'step three', Screen[6]);
    AssertEquals('вызов инструмента', '[read] task1.md', Screen[7]);
    AssertEquals('результат инструмента', 'result text', Screen[8]);
    AssertEquals('пустая строка-разделитель под результатом (task1.md)', '',
      Screen[9]);
    AssertEquals('done-строка третьего шага под результатом', True,
      Pos('] s3 done', Screen[10]) > 0);
    AssertEquals('счётчики третьего шага в done-строке', True,
      Pos('|5k/3.3k/128k|', Screen[10]) > 0);
    AssertEquals('под последним выводом только хвост перевода строки', '',
      Screen[11]);

    { Все строки со счётчиками на экране — done-строки: временные варианты
      статусов (1.0k…3.1k) стёрты, остались только итоговые. }
    All := '';
    Statuses := 0;
    Dones := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Pos('128k', Screen[I]) > 0 then
      begin
        Inc(Statuses);
        if Pos(' done', Screen[I]) > 0 then
          Inc(Dones);
      end;
    end;
    AssertEquals('строк со счётчиками на экране ровно три', 3, Statuses);
    AssertEquals('все они — done-строки', 3, Dones);
    AssertEquals('временного статуса 3.1k на экране нет', 0,
      Pos('|5k/3.1k/128k|', All));

    { Гейтинг задания шага (task1): при обоих выключенных флагах строки
      с заданием нет (имя шага было только в стёртой строке статуса); с
      --show-step-task (s2) и с --show-reasoning (s3) задание печатается
      отдельной строкой без тега [шаг]. }
    S1Task := False;
    S2Task := False;
    S3Task := False;
    for I := 0 to Screen.Count - 1 do
    begin
      if Screen[I] = TASK1 then
        S1Task := True;
      if Screen[I] = TASK2 then
        S2Task := True;
      if Screen[I] = TASK3 then
        S3Task := True;
    end;
    AssertFalse('оба флага off: задания первого шага нет', S1Task);
    AssertTrue('задание второго шага по --show-step-task', S2Task);
    AssertTrue('задание третьего шага по --show-reasoning', S3Task);
    AssertEquals('тега [шаг] нет нигде в выводе', 0, Pos('[шаг]', Out));
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestToolOutputGating;
var
  Out, All: string;
  Screen: TStringList;
  I, Statuses, Dones, Analyzes: Integer;
begin
  { Гейтинг вывода инструментов (ToolOutputVisible): вывод печатается только
    вместе с размышлениями (--show-reasoning), в любой сессии — task2.md.
    Сценарий пробы: s1 — шаг без --show-reasoning (вызов и результат скрыты),
    s2 — анализ с ним (печатаются shell-команда «$ …» и результат), затем
    основная сессия без флага (скрыто) и с флагом (видно). Строка статуса при
    этом перерисовывается (DrawStatus) даже когда сам вывод скрыт, но к концу
    под-сессии временная строка стирается (EndStream), а на её месте
    закрепляется done-строка «s1 done» / «анализ done» с итоговыми счётчиками.
    У основной сессии закрепления нет — её статус просто стирается. }
  Out := RunProbe('tool-gating');
  if Out = '' then
    Exit;

  { Скрытый вывод не попадает в поток ни строкой вызова, ни результатом. }
  AssertEquals('вызов инструмента шага скрыт', 0, Pos('[read] hidden.md', Out));
  AssertEquals('результат инструмента шага скрыт', 0, Pos('hidden result', Out));
  { Основная сессия без --show-reasoning тоже молчит. }
  AssertEquals('вызов инструмента основной сессии без флага скрыт', 0,
    Pos('[write] main.txt', Out));
  AssertEquals('результат инструмента основной сессии без флага скрыт', 0,
    Pos('main result', Out));
  { DrawStatus выполняется безусловно — счётчики статусов видны
    (main/sub/total: 4.0k/1.3k/128k и 4.0k/1.4k/128k). }
  AssertTrue('статус 1.3k нарисован после скрытого вызова',
    Pos('|4k/1.3k/128k|', Out) > 0);
  AssertTrue('статус 1.4k нарисован после скрытого результата',
    Pos('|4k/1.4k/128k|', Out) > 0);

  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 12, Screen.Count);
    AssertEquals('текст первого шага', 'step one', Screen[0]);
    AssertEquals('done-строка шага под текстом', True,
      Pos('] s1 done', Screen[1]) > 0);
    AssertEquals('счётчики шага в done-строке', True,
      Pos('|4k/1.4k/128k|', Screen[1]) > 0);
    AssertEquals('строка под-сессии анализа', 'analysis line', Screen[2]);
    AssertEquals('shell-команда анализа видна', '$ echo shown', Screen[3]);
    AssertEquals('результат инструмента анализа виден', 'shown result',
      Screen[4]);
    AssertEquals('пустая строка-разделитель под результатом (task1.md)', '',
      Screen[5]);
    AssertEquals('done-строка анализа под разделителем', True,
      Pos('] анализ done', Screen[6]) > 0);
    AssertEquals('счётчики анализа в done-строке', True,
      Pos('|4.5k/500/128k|', Screen[6]) > 0);
    AssertEquals('строка основной сессии без флагов', 'main line', Screen[7]);
    AssertEquals('строка основной сессии с --show-reasoning',
      'main line two', Screen[8]);
    AssertEquals('вызов инструмента основной сессии с флагом виден',
      '[write] main2.txt', Screen[9]);
    AssertEquals('результат инструмента основной сессии с флагом виден',
      'main2 result', Screen[10]);
    AssertEquals('под последним выводом только хвост перевода строки', '',
      Screen[11]);
    All := '';
    Statuses := 0;
    Dones := 0;
    Analyzes := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Pos('128k', Screen[I]) > 0 then
      begin
        Inc(Statuses);
        if Pos(' done', Screen[I]) > 0 then
          Inc(Dones);
      end;
      if Pos('анализ', Screen[I]) > 0 then
        Inc(Analyzes);
    end;
    { На экране только две done-строки (шаг и анализ): временные варианты
      статусов стёрты, а у основной сессии строки статуса нет вовсе. }
    AssertEquals('строк со счётчиками на экране ровно две', 2, Statuses);
    AssertEquals('обе они — done-строки', 2, Dones);
    AssertEquals('имени шага на экране нет (в done-строке только «s1»)', 0,
      Pos('s1: скрытый вывод', All));
    AssertEquals('метка анализа только в done-строке', 1, Analyzes);
    AssertEquals('статусов основной сессии на экране нет', 0, Pos('[main', All));
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestBlankLineAfterToolOutput;
const
  { Done-строка завершённой под-сессии из сценария tool-blank. }
  DONE_LINE = '[st 9 done]';
var
  Out: string;
  Screen: TStringList;
  I, Blanks, Doubles, Statuses: Integer;
begin
  { Пустая строка после вывода инструмента (task1.md): результат отделяется от
    следующего блока информации — ровно одной пустой строкой. Сценарий пробы
    повторяет ветки aeToolResult/aeAssistant/aeSubSessionEnd: результат →
    статичный блок ответа (своя пустая строка ответа подавлена по
    BlankSeparated), два результата инструментов подряд, результат →
    done-строка, а также скрытый вывод, который пустых строк не добавляет.
    Регрессия: TStreamPrinter.RequestBlankLine/PrepareStatic/PersistStatus и
    ветка aeToolResult в TMirmidApp.OnAgentEvent. }
  Out := RunProbe('tool-blank');
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 13, Screen.Count);
    AssertEquals('строка перед первым инструментом', 'answer zero', Screen[0]);
    AssertEquals('вызов первого инструмента', '[read] a.txt', Screen[1]);
    AssertEquals('результат первого инструмента', 'result a', Screen[2]);
    AssertEquals('разделитель под результатом (task1.md)', '', Screen[3]);
    AssertEquals('ответ модели под разделителем', 'answer one', Screen[4]);
    AssertEquals('вызов второго инструмента', '[read] b.txt', Screen[5]);
    AssertEquals('результат второго инструмента', 'result b', Screen[6]);
    AssertEquals('разделитель между результатами инструментов', '', Screen[7]);
    AssertEquals('вызов третьего инструмента', '[read] c.txt', Screen[8]);
    AssertEquals('результат третьего инструмента', 'result c', Screen[9]);
    AssertEquals('разделитель перед done-строкой', '', Screen[10]);
    AssertEquals('done-строка под разделителем', DONE_LINE, Screen[11]);
    AssertEquals('под последним выводом только хвост перевода строки', '',
      Screen[12]);

    { Скрытый вывод пустых строк не добавил: пустых строк ровно три (по одной
      на видимый результат инструмента) плюс хвост перевода строки под
      последним выводом; двух пустых подряд (двойного разделителя) нет. }
    Blanks := 0;
    Doubles := 0;
    Statuses := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      if Screen[I] = '' then
      begin
        Inc(Blanks);
        if (I > 0) and (Screen[I - 1] = '') then
          Inc(Doubles);
      end;
      { Строки временного статуса на экране не остаются: единственная строка,
        начинающаяся с «[st », — закреплённая done-строка. }
      if (Copy(Screen[I], 1, 4) = '[st ') and (Pos(' done', Screen[I]) = 0) then
        Inc(Statuses);
    end;
    AssertEquals('пустых строк на экране ровно четыре', 4, Blanks);
    AssertEquals('пустых строк подряд (двойного разделителя) нет', 0, Doubles);
    AssertEquals('временных строк статуса на экране нет', 0, Statuses);
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestEndStreamNoGlueBeforePrompt;
const
  { Маркеры статусов s1/s2 из сценария endstream-prompt. }
  TAIL_A = 'tail-a';
  TAIL_B = 'tail-b';
  PROMPT = '|> ';
var
  Out, All: string;
  Screen: TStringList;
  I, Prompts: Integer;
begin
  { Конец стрима не оставляет строки статуса в логе: следующий вывод
    (приглашение REPL после PrepareStatic) начинается с начала чистой строки.
    Раньше EndStream печатал статус отдельной строкой (WriteLn), поэтому
    приглашение оказывалось под остатком статуса, а незавершённая последняя
    строка могла склеиться с ним. Сценарий повторяет обе ветки: s1 —
    незавершённая последняя строка и нарисованный статус, s2 — завершённая
    строка и статус под ней. Регрессия: TStreamPrinter.EndStream. }
  Out := RunProbe('endstream-prompt');
  if Out = '' then
    Exit;
  { Статусы действительно рисовались — иначе проверка экрана ниже была бы
    тривиальной. }
  AssertTrue('статус s1 нарисован в сыром выводе', Pos(TAIL_A, Out) > 0);
  AssertTrue('статус s2 нарисован в сыром выводе', Pos(TAIL_B, Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 6, Screen.Count);
    AssertEquals('строка до незавершённой', '||first', Screen[0]);
    AssertEquals('незавершённая строка осталась целой', '||pending tail',
      Screen[1]);
    AssertEquals('приглашение после стрима с незавершённой строкой', PROMPT,
      Screen[2]);
    AssertEquals('завершённая строка второго стрима', '||second', Screen[3]);
    AssertEquals('приглашение после завершённого стрима', PROMPT, Screen[4]);
    AssertEquals('под последним приглашением только перевод строки', '',
      Screen[5]);

    { Ни остатка статуса, ни пустой строки от WriteLn статуса на экране нет;
      приглашений ровно два, и оба стоят с начала строки. }
    All := '';
    Prompts := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Copy(Screen[I], 1, Length(PROMPT)) = PROMPT then
        Inc(Prompts);
    end;
    AssertEquals('приглашений ровно два', 2, Prompts);
    AssertEquals('остатка статуса s1 на экране нет', 0, Pos(TAIL_A, All));
    AssertEquals('остатка статуса s2 на экране нет', 0, Pos(TAIL_B, All));
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestStatusStaysAfterTurn;
const
  { Итоговые строки статуса из сценария persist-status. }
  FINAL1 = '||[turn 1 final 2.1k/128k]';
  FINAL2 = '||[turn 2 final 2.2k/128k]';
  PROMPT = '|> ';
var
  Out, All: string;
  Screen: TStringList;
  I, Finals: Integer;
begin
  { После хода итоговая строка статуса остаётся на экране (task2.md): временный
    статус стирает EndStream, а PersistStatus (ветка KeepContextStatus в
    потоковом режиме) фиксирует строку в логе — под ответом, с итоговыми
    счётчиками. Следующее приглашение REPL идёт с чистой строки под ней, и на
    каждый ход приходится ровно одна строка статуса (прежние варианты с
    меньшими счётчиками стёрты). Регрессия: TStreamPrinter.PersistStatus. }
  Out := RunProbe('persist-status');
  if Out = '' then
    Exit;
  { Временные статусы действительно рисовались — иначе проверка экрана была бы
    тривиальной. }
  AssertTrue('статус первого хода нарисован в сыром выводе',
    Pos('[turn 1 1.0k]', Out) > 0);
  AssertTrue('итоговый статус второго хода нарисован',
    Pos('2.2k/128k', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('строк на экране', 7, Screen.Count);
    AssertEquals('первая строка ответа', '||answer one', Screen[0]);
    AssertEquals('незавершённая строка ответа осталась целой', '||answer tail',
      Screen[1]);
    AssertEquals('итоговый статус первого хода под ответом', FINAL1, Screen[2]);
    AssertEquals('приглашение под строкой статуса', PROMPT, Screen[3]);
    AssertEquals('ответ второго хода', '||answer two', Screen[4]);
    AssertEquals('итоговый статус второго хода под ответом', FINAL2, Screen[5]);
    AssertEquals('под последним статусом только перевод строки', '', Screen[6]);

    { Временных статусов на экране нет: строка статуса на экране только одна
      на ход — итоговая (все строки вида «||[» сверх двух точных сравнений
      выше — уже лишние). }
    All := '';
    Finals := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Copy(Screen[I], 1, 3) = '||[' then
        Inc(Finals);
    end;
    AssertEquals('строк статуса на экране ровно две', 2, Finals);
    AssertEquals('временного статуса первого хода на экране нет', 0,
      Pos('[turn 1 1.0k]', All));
    AssertEquals('временного статуса первого хода (позднего) на экране нет', 0,
      Pos('[turn 1 3.0k]', All));
    AssertEquals('статуса второго хода без итога на экране нет', 0,
      Pos('[turn 2 start]', All));
  finally
    Screen.Free;
  end;
end;


initialization
  RegisterTest(TStreamPrinterTests);
end.
