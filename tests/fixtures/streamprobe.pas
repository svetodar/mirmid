program streamprobe;
{ Проба TStreamPrinter (потоковый вывод): прогоняет сценарий и пишет сырой
  вывод (с ANSI-кодами) в stdout. Используется tests/test_stream.pas.
  Аргумент: имя сценария. }

{$mode objfpc}{$H+}

uses
  SysUtils, mirmid.cli;

procedure RunScenario(const Name: string);
const
  { Длинная строка для сценария prefix-wrap (длиннее 80 колонок). }
  WRAP_TEXT = 'alpha beta gamma delta epsilon zeta eta theta iota kappa ' +
              'lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega';
  { Контекст основной сессии (main-счётчик) для сценариев планировщика: в
    режиме плана основная сессия к модели не обращается, и значение берётся из
    кэша оценки агента. Числа у сценариев разные, чтобы в сыром выводе было
    видно подстановку main-счётчика; формат строки статуса —
    «[ЧЧ:ММ:СС|main/sub/total|процент-main%/процент-sub%]». }
  MAIN_CTX_STEP = 6000;
  MAIN_CTX_TASK = 5000;
  MAIN_CTX_TOOL = 4000;
  MAIN_CTX_ANALYSIS = 4500;
var
  P: TStreamPrinter;
  I, N: Integer;
begin
  P := TStreamPrinter.Create;
  try
    P.Live := True;   { форсируем ANSI-режим: stdout может быть конвейером }
    P.BeginStream('[st]');
    if Name = 'spaces-partial' then
    begin
      { Строка приходит тремя чанками: сначала ведущие пробелы, затем
        текст, затем перевод строки. }
      P.FeedReasoning('  ', '[st]');
      P.FeedReasoning('word', '[st]');
      P.FeedReasoning(#10, '[st]');
    end
    else if Name = 'indent-reasoning' then
      P.FeedReasoning('  indented' + #10, '[st]')
    else if Name = 'indent-content' then
      P.FeedContent('  indented' + #10, '[st]')
    else if Name = 'prefix-wrap' then
    begin
      { Префикс субагента из двух колонок: частичная строка должна
        переноситься с учётом префикса и не занимать две строки терминала
        (иначе перерисовка теряла и дублировала куски слов). }
      P.Prefix := '||';
      N := Length(WRAP_TEXT);
      I := 1;
      while I <= N do
      begin
        P.FeedContent(Copy(WRAP_TEXT, I, 5), '[st]');
        Inc(I, 5);
      end;
      P.FeedContent(#10, '[st]');
    end
    else if Name = 'done-status' then
    begin
      { Конец под-сессии шага (task1.md п.4): временная строка статуса
        стирается (EndStream), а PersistStatus закрепляет на её месте
        done-строку с итоговыми счётчиками и коротким именем шага
        («[ЧЧ:ММ:СС|main/sub/total|%/%] s1 done»). Прежний вариант статуса
        «[s1 2]» в лог не попадает, а статичный вывод и следующий стрим идут с
        чистой строки под done-строкой. Регрессия:
        TMirmidApp.PersistDoneStatus/DoneStatusText, StepShortName,
        TStreamPrinter.PersistStatus/EndStream/PrepareStatic. }
      P.Prefix := '||';
      P.BeginStream('[s1 start]');
      P.FeedContent('first' + #10, '[s1 1]');
      P.FeedContent('second' + #10, '[s1 2]');
      P.EndStream('[s1 end]');
      { aeSubSessionEnd: DoneStatusText + ' done' через PersistStatus. }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: шаг'), 2200, 128000,
        MAIN_CTX_STEP) + ' done');
      { Статичный вывод (как aeToolResult) начинается с чистой строки под
        закреплённой done-строкой. }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'after done');
      P.BeginStream('[s2]');
      P.FeedContent('third' + #10, '[s2 1]');
      P.EndStream('[s2 end]');
    end
    else if Name = 'prepare-static-status' then
    begin
      { PrepareStatic при нарисованной строке статуса (FStatusShown=True)
        стирает её, а не печатает в scrollback. Сценарий повторяет ветку
        aeToolResult/статичного вывода: статус нарисован (BeginStream,
        FeedContent) — статичная строка встаёт на его месте с начала чистой
        строки; статус нарисован заново (DrawStatus, как после aeToolCall) —
        PrepareStatic снова его стирает. Повторный PrepareStatic без статуса
        не оставляет пустой строки. Регрессия: TStreamPrinter.PrepareStatic. }
      P.Prefix := '||';
      P.BeginStream('[s1 start long status tail]');
      P.FeedContent('line one' + #10, '[s1 1 long status tail]');
      { Статичный вывод при нарисованном статусе (ветка aeToolResult). }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'static after status');
      { Статус нарисован заново (DrawStatus после строки вызова) — стираем. }
      P.DrawStatus('[s1 2 long status tail]');
      P.PrepareStatic;
      WriteLn(P.Prefix + 'static after draw');
      { Статуса нет: PrepareStatic ничего не печатает и не добавляет строку. }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'third static');
    end
    else if Name = 'endstream-prompt' then
    begin
      { Конец стрима не оставляет строки статуса, поэтому следующий вывод
        (приглашение REPL после PrepareStatic) начинается с начала чистой
        строки. Сценарий повторяет ветки Repl: s1 — стрим с незавершённой
        последней строкой и нарисованным под ней статусом (EndStream печатает
        её как полную строку и стирает статус); s2 — стрим с завершённой
        последней строкой (стирается только статус). Приглашение «|> »
        печатается без хвоста статуса и не склеивается с текстом стрима.
        Регрессия: TStreamPrinter.EndStream. }
      P.Prefix := '||';
      P.BeginStream('[s1 1 tail-a]');
      P.FeedContent('first' + #10, '[s1 2 tail-a]');
      { Незавершённая последняя строка: нарисована, статус под ней. }
      P.FeedContent('pending tail', '[s1 3 tail-a]');
      P.EndStream('[s1 4 tail-a]');
      { Repl: погасить статус, затем приглашение. }
      P.PrepareStatic;
      Write('|> ');
      WriteLn;   { пользователь нажал Enter }

      { s2: последняя строка завершена переводом строки — на экране только
        текст и нарисованный под ним статус. }
      P.BeginStream('[s2 1 tail-b]');
      P.FeedContent('second' + #10, '[s2 2 tail-b]');
      P.EndStream('[s2 3 tail-b]');
      P.PrepareStatic;
      Write('|> ');
      WriteLn;
    end
    else if Name = 'step-status' then
    begin
      { Под-сессия шага плана печатается без префикса «│» (глубина печати 0):
        строка статуса шага — «[ЧЧ:ММ:СС|main/sub/total|процент-main%/
        процент-sub%] имя» (статус первым, тега [шаг] нет) — и текст шага идут
        от начала строки. Первый счётчик — контекст основной сессии из кэша
        оценки (MAIN_CTX_STEP), второй и третий — шаг и общее окно модели.
        Строка статуса временная: её стирает EndStream, а на aeSubSessionEnd
        PersistDoneStatus закрепляет вместо неё done-строку с коротким именем
        шага («…] s1 done») и итоговыми счётчиками — прежние варианты статуса
        в лог не попадают. Отступ даёт только инструмент subagent — вложенный в
        шаг субагент получает ровно один «│», а его результат печатается
        статичной строкой на месте стёртого статуса; после выхода префикс
        возвращается к пустому. Регрессия FPrintDepth/FPrinter.Prefix,
        формата FormatStepStatus и PersistStatus. }
      P.Prefix := '';
      P.BeginStream(FormatStepStatus('s1: шаг', 1200, 128000, MAIN_CTX_STEP));
      P.FeedContent('step line' + #10,
        FormatStepStatus('s1: шаг', 1300, 128000, MAIN_CTX_STEP));
      { Вложенный инструмент subagent: единственное место с префиксом. }
      P.Prefix := DepthPrefix(1);
      P.BeginStream('sub status');
      P.FeedContent('sub line' + #10, 'sub status');
      P.EndStream('sub status');   { нарисованный статус субагента стёрт }
      { aeToolResult субагента: готовый ответ (с префиксом) встаёт на место
        стёртого статуса — строка начинается с «│», хвоста статуса нет. }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'sub result');
      { Возврат на уровень шага: префикс печати снова пустой. }
      P.Prefix := '';
      P.BeginStream(FormatStepStatus('s1: шаг', 1500, 128000, MAIN_CTX_STEP));
      P.FeedContent('step tail' + #10,
        FormatStepStatus('s1: шаг', 1600, 128000, MAIN_CTX_STEP));
      P.EndStream(FormatStepStatus('s1: шаг', 1700, 128000, MAIN_CTX_STEP));
      { aeSubSessionEnd: строка шага стирается, а на её месте закрепляется
        done-строка с коротким именем «s1» и итоговыми счётчиками. }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: шаг'), 1700, 128000,
        MAIN_CTX_STEP) + ' done');
    end
    else if Name = 'step-task-gating' then
    begin
      { Гейтинг задания шага плана (task1) и закрепление done-строки.
        Сценарий повторяет ветки aeStepStart/aeToolCall/aeToolResult: имя
        шага (задание) печатается без тега [шаг] только при StepTaskVisible
        (то есть по --show-step-task или по --show-reasoning, при обоих off —
        не печатается), причём статично, на месте стёртого статуса. Имя шага
        в строке статуса (FormatStepStatus: сначала статус
        «[ЧЧ:ММ:СС|main/sub/total|процент-main%/процент-sub%]», затем имя)
        живёт только в терминале: EndStream её стирает, а на aeSubSessionEnd
        PersistDoneStatus закрепляет done-строку с коротким именем «sN» и
        итоговыми счётчиками — временных строк статуса в логе нет, остаются
        только done-строки завершённых шагов. Первый счётчик строки — контекст
        основной сессии (MAIN_CTX_TASK), второй — шага, третий — общее окно
        модели. Вызов инструмента и результат печатаются на месте нарисованного
        статуса (PrepareStatic/PrepareStaticOverStatus), а статус затем
        рисуется заново (DrawStatus) — счётчики растут под ними. }
      P.Prefix := '';

      { s1: оба флага выключены — задания нет, работа шага начинается сразу
        со строки статуса (имя шага в ней всё равно есть, но она временная и
        заменяется done-строкой при завершении шага). }
      if StepTaskVisible(False, False, False) then
      begin
        P.PrepareStatic;
        WriteLn('s1: скрытое задание');
      end;
      P.BeginStream(FormatStepStatus('s1: скрытое задание', 1000, 128000,
        MAIN_CTX_TASK));
      P.FeedContent('step one' + #10,
        FormatStepStatus('s1: скрытое задание', 1100, 128000, MAIN_CTX_TASK));
      P.EndStream(FormatStepStatus('s1: скрытое задание', 1200, 128000,
        MAIN_CTX_TASK));
      { aeSubSessionEnd: временная строка шага стирается, а PersistStatus
        закрепляет done-строку «s1 done» с итоговыми счётчиками. }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: скрытое задание'), 1200,
        128000, MAIN_CTX_TASK) + ' done');

      { s2: включён только --show-step-task — задание печатается до работы
        шага, с начала чистой строки (статус шага уже стёрт). }
      if StepTaskVisible(True, False, False) then
      begin
        P.PrepareStatic;
        WriteLn('s2: задание по флагу');
      end;
      P.BeginStream(FormatStepStatus('s2: задание по флагу', 2000, 128000,
        MAIN_CTX_TASK));
      P.FeedContent('step two' + #10,
        FormatStepStatus('s2: задание по флагу', 2100, 128000, MAIN_CTX_TASK));
      P.EndStream(FormatStepStatus('s2: задание по флагу', 2200, 128000,
        MAIN_CTX_TASK));
      P.PersistStatus(FormatStepStatus(StepShortName('s2: задание по флагу'), 2200,
        128000, MAIN_CTX_TASK) + ' done');

      { s3: включён только --show-reasoning (--show-step-result тоже задан, но
        на задание он не влияет) — задание печатается. }
      if StepTaskVisible(False, True, True) then
      begin
        P.PrepareStatic;
        WriteLn('s3: задание по размышлениям');
      end;
      P.BeginStream(FormatStepStatus('s3: задание по размышлениям', 3000, 128000,
        MAIN_CTX_TASK));
      P.FeedContent('step three' + #10,
        FormatStepStatus('s3: задание по размышлениям', 3100, 128000,
          MAIN_CTX_TASK));
      P.EndStream(FormatStepStatus('s3: задание по размышлениям', 3100, 128000,
        MAIN_CTX_TASK));

      { aeToolCall: после конца стрима статуса на экране уже нет (EndStream
        его стёр), поэтому строка вызова печатается с начала чистой строки —
        без склейки с хвостом статуса. ClearLine приложения приватный, здесь
        эмулируем его через CR + ESC[K. Затем DrawStatus рисует статус с
        новыми счётчиками (3.1k → 3.2k), чтобы он не исчезал на время работы
        инструмента. }
      P.PrepareStatic;
      Write(#13, #27, '[K');
      WriteLn('[read] task1.md');
      P.DrawStatus(FormatStepStatus('s3: задание по размышлениям', 3200, 128000,
        MAIN_CTX_TASK));

      { aeToolResult: нарисованный статус стирается, результат встаёт на его
        место, статус рисуется заново под результатом. }
      P.PrepareStaticOverStatus;
      WriteLn('result text');
      { Разделитель после вывода инструмента (task1.md). }
      P.RequestBlankLine;
      P.DrawStatus(FormatStepStatus('s3: задание по размышлениям', 3300, 128000,
        MAIN_CTX_TASK));
      { aeSubSessionEnd: последний вариант временного статуса (3.3k) стирается и
        заменяется done-строкой «s3 done» — счётчики 3.2k/3.3k остаются только в
        сыром выводе. }
      P.PersistStatus(FormatStepStatus(StepShortName('s3: задание по размышлениям'),
        3300, 128000, MAIN_CTX_TASK) + ' done');
    end
    else if Name = 'tool-gating' then
    begin
      { Гейтинг вывода инструментов (ToolOutputVisible): строки вызова и
        результата инструмента печатаются только вместе с размышлениями —
        --show-reasoning. Сессия роли не играет: в шаге и в основной сессии
        без флага вывод скрыт, в анализе и в основной сессии с флагом виден
        (task2.md). Сценарий повторяет ветки aeToolCall/aeShellCommand/
        aeToolResult: строка статуса временная, её стирает EndStream, а на
        aeSubSessionEnd PersistDoneStatus закрепляет done-строку с итоговыми
        счётчиками (у основной сессии из этого сценария закрепления нет —
        там статус просто стирается). ClearLine/DrawStatus (приватный ClearLine
        эмулируем через CR + ESC[K) выполняются безусловно — поэтому скрытый
        вывод не оставляет пустых строк, а видимый встаёт на место стёртого
        статуса. }
      P.Prefix := '';

      { s1: под-сессия шага без --show-reasoning — вызов и результат скрыты,
        на экране остаётся текст шага и done-строка; счётчики статуса
        (main/sub/total: 4.0k/1.0k → 1.4k/128k) видны в сыром выводе, а в лог
        попадают только итоговые — из done-строки. }
      P.BeginStream(FormatStepStatus('s1: скрытый вывод', 1000, 128000,
        MAIN_CTX_TOOL));
      P.FeedContent('step one' + #10,
        FormatStepStatus('s1: скрытый вывод', 1100, 128000, MAIN_CTX_TOOL));
      P.EndStream(FormatStepStatus('s1: скрытый вывод', 1200, 128000,
        MAIN_CTX_TOOL));
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(False) then
        WriteLn('[read] hidden.md');
      P.DrawStatus(FormatStepStatus('s1: скрытый вывод', 1300, 128000,
        MAIN_CTX_TOOL));
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(False) then
        WriteLn('hidden result');
      P.DrawStatus(FormatStepStatus('s1: скрытый вывод', 1400, 128000,
        MAIN_CTX_TOOL));
      { aeSubSessionEnd: временная строка шага заменяется done-строкой «s1». }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: скрытый вывод'), 1400,
        128000, MAIN_CTX_TOOL) + ' done');

      { s2: под-сессия анализа с --show-reasoning — вывод инструментов
        виден: печатаются строка shell-команды («$ …», ветка
        aeShellCommand) и результат, каждый на месте стёртого статуса.
        Строка анализа того же формата, что у шага: main (MAIN_CTX_ANALYSIS),
        под-сессия анализа, общее окно и два процента. }
      P.BeginStream(FormatAnalysisStatus(0, 128000, MAIN_CTX_ANALYSIS));
      P.FeedContent('analysis line' + #10,
        FormatAnalysisStatus(200, 128000, MAIN_CTX_ANALYSIS));
      P.EndStream(FormatAnalysisStatus(300, 128000, MAIN_CTX_ANALYSIS));
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(True) then
        WriteLn('$ echo shown');
      P.DrawStatus(FormatAnalysisStatus(400, 128000, MAIN_CTX_ANALYSIS));
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(True) then
      begin
        WriteLn('shown result');
        { Разделитель после вывода инструмента (task1.md). }
        P.RequestBlankLine;
      end;
      P.DrawStatus(FormatAnalysisStatus(500, 128000, MAIN_CTX_ANALYSIS));
      { aeSubSessionEnd анализа: временный статус заменяется done-строкой
        «анализ done» с итоговыми счётчиками (main/sub/total из
        MAIN_CTX_ANALYSIS и 500). }
      P.PersistStatus(FormatAnalysisStatus(500, 128000, MAIN_CTX_ANALYSIS) +
        ' done');

      { Основная сессия без флагов — вызов и результат тоже скрыты (task2.md:
        гейтинг одинаков для всех сессий); статус стирается, а не остаётся
        строкой в логе: закрепление done-строки есть только у под-сессий. }
      P.BeginStream('[main]');
      P.FeedContent('main line' + #10, '[main 1]');
      P.EndStream('[main 2]');
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(False) then
        WriteLn('[write] main.txt');
      P.DrawStatus('[main 3]');
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(False) then
        WriteLn('main result');
      P.DrawStatus('[main 4]');
      P.FreezeStatus('');

      { Основная сессия с --show-reasoning — вывод виден, как в анализе. }
      P.BeginStream('[main2]');
      P.FeedContent('main line two' + #10, '[main2 1]');
      P.EndStream('[main2 2]');
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(True) then
        WriteLn('[write] main2.txt');
      P.DrawStatus('[main2 3]');
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(True) then
      begin
        WriteLn('main2 result');
        { Разделитель после вывода инструмента (task1.md). }
        P.RequestBlankLine;
      end;
      P.DrawStatus('[main2 4]');
      P.FreezeStatus('');
    end
    else if Name = 'tool-blank' then
    begin
      { Пустая строка после вывода инструмента (task1.md): результат
        отделяется от следующего блока информации. Сценарий повторяет ветки
        aeToolCall/aeToolResult/aeAssistant/aeSubSessionEnd:
        1) результат инструмента, затем статичный блок (ответ модели) — между
           ними ровно одна пустая строка (свою пустую строку ответ подавляет
           по BlankSeparated, второй не появляется);
        2) два результата инструментов подряд — тоже одна пустая строка;
        3) результат, затем done-строка (PersistStatus) — пустая строка и перед
           ней;
        4) скрытый вывод (ToolOutputVisible = False) пустых строк не
           добавляет: заказывать разделитель нечему.
        Регрессия: TStreamPrinter.RequestBlankLine/PrepareStatic/PersistStatus и
        ветка aeToolResult в TMirmidApp.OnAgentEvent. }
      P.Prefix := '';
      P.BeginStream('[st start]');
      P.FeedContent('answer zero' + #10, '[st 1]');
      P.EndStream('[st 2]');

      { aeToolCall + aeToolResult первого инструмента (вывод виден). }
      P.PrepareStatic;
      Write(#13, #27, '[K');
      WriteLn('[read] a.txt');
      P.DrawStatus('[st 3]');
      P.PrepareStaticOverStatus;
      WriteLn('result a');
      P.RequestBlankLine;
      P.DrawStatus('[st 4]');

      { aeAssistant: PrepareStatic уже напечатал разделитель, вторая пустая
        строка не нужна (проверка BlankSeparated). }
      P.PrepareStatic;
      if not P.BlankSeparated then
        WriteLn;
      WriteLn('answer one');

      { Второй инструмент: перед строкой вызова разделителя нет — его никто не
        заказывал. }
      P.PrepareStatic;
      WriteLn('[read] b.txt');
      P.DrawStatus('[st 5]');
      P.PrepareStaticOverStatus;
      WriteLn('result b');
      P.RequestBlankLine;
      P.DrawStatus('[st 6]');

      { Третий инструмент подряд: между результатами ровно одна пустая строка. }
      P.PrepareStatic;
      WriteLn('[read] c.txt');
      P.DrawStatus('[st 7]');
      P.PrepareStaticOverStatus;
      WriteLn('result c');
      P.RequestBlankLine;
      P.DrawStatus('[st 8]');

      { aeSubSessionEnd: done-строка встаёт под разделителем. }
      P.PersistStatus('[st 9 done]');

      { Скрытый вывод: ни строк вызова/результата, ни пустых строк. }
      P.PrepareStatic;
      Write(#13, #27, '[K');
      P.DrawStatus('[st 10]');
      P.PrepareStaticOverStatus;
      P.DrawStatus('[st 11]');
      P.PrepareStatic;
      Write(#13, #27, '[K');
      P.DrawStatus('[st 12]');
      P.FreezeStatus('');
    end
    else if Name = 'persist-status' then
    begin
      { Конец хода (task2.md): итоговая строка статуса остаётся на экране.
        Сценарий повторяет ветку TMirmidApp.KeepContextStatus в потоковом
        режиме: после EndStream (он стёр временный статус) принтер фиксирует
        строку с итоговыми счётчиками (PersistStatus), а следующий вывод —
        приглашение REPL после PrepareStatic — идёт с чистой строки под ней.
        Два хода подряд: у каждого в логе ровно одна строка статуса, и она
        стоит под ответом, а не вместо него. Регрессия:
        TStreamPrinter.PersistStatus. }
      P.Prefix := '||';
      P.BeginStream('[turn 1 start]');
      P.FeedContent('answer one' + #10, '[turn 1 1.0k]');
      { Незавершённая последняя строка: она станет полной строкой в EndStream,
        статус под ней — временным. }
      P.FeedContent('answer tail', '[turn 1 2.0k]');
      P.EndStream('[turn 1 3.0k]');
      { KeepContextStatus (стрим): фиксируем итоговую строку в логе. }
      P.PersistStatus('[turn 1 final 2.1k/128k]');
      { Repl: приглашение под зафиксированной строкой. }
      P.PrepareStatic;
      Write('|> ');
      WriteLn;

      P.BeginStream('[turn 2 start]');
      P.FeedContent('answer two' + #10, '[turn 2 1.0k]');
      P.EndStream('[turn 2 2.0k]');
      P.PersistStatus('[turn 2 final 2.2k/128k]');
      P.PrepareStatic;
    end
    else
      Halt(2);
    P.EndStream('[st]');
  finally
    P.Free;
  end;
end;

begin
  if ParamCount < 1 then
    Halt(2);
  RunScenario(ParamStr(1));
end.
