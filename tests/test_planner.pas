unit test_planner;
{ Тесты планировщика (mirmid.planner): инструмент revise_plan (add/remove/
  reorder/skip, невалидные операции, частичное применение, события) и
  чистые части (подсказка шага, отчёт, разбор плана из текста). Без сети. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.types, mirmid.tools, mirmid.agent, mirmid.planner,
  mirmid.cli;

type
  { Тестовый обработчик событий планировщика: считает события и
    запоминает последний текст. Отдельно считаются события под-сессий
    планировщика (aeSubSessionStart/aeSubSessionEnd): вход/выход в анализ и
    шаг плана с меткой «анализ»/«шаг sN». }
  TPlannerEventLog = class
  public
    PlanEvents: Integer;
    StepStartEvents: Integer;
    StepEndEvents: Integer;
    ReportEvents: Integer;
    SubSessionStartEvents: Integer;
    SubSessionEndEvents: Integer;
    PlanChanged: Integer;
    LastPlanText: string;
    LastStepStartText: string;
    LastStepEndText: string;
    LastReportText: string;
    LastSubSessionStartText: string;
    LastSubSessionEndText: string;
    constructor Create;
    procedure OnEvent(Kind: TAgentEventKind; const Text: string);
    procedure OnPlanChanged;
  end;

  TPlannerTests = class(TTestCase)
  private
    FPlanner: TPlanner;
    FReg: TToolRegistry;
    FCtx: TToolContext;
    FLog: TPlannerEventLog;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
    function InvokeRevise(const ArgsJson: string): TToolOutcome;
  published
    procedure TestToolRegistered;
    procedure TestReviseAddToEnd;
    procedure TestReviseAddAfter;
    procedure TestReviseAddAfterRemove;
    procedure TestReviseRemove;
    procedure TestReviseReorder;
    procedure TestReviseSkip;
    procedure TestReviseSkipNonPending;
    procedure TestReviseUnknownId;
    procedure TestReviseUnknownOp;
    procedure TestReviseEmptyOps;
    procedure TestReviseMissingOps;
    procedure TestRevisePartialApply;
    procedure TestReviseEvents;
    procedure TestReviseNoEventsOnUnchangedError;
    procedure TestSubSessionEvents;
    procedure TestStepPrompt;
    procedure TestPlanReport;
    procedure TestParsePlanFromText;
    procedure TestAnalysisConfigInheritsPolicies;
    procedure TestStepSessionSaved;
    procedure TestStepEndResultGating;
    procedure TestClassifyStepResult;
    procedure TestStepPromptWithFixHint;
    procedure TestStepRetryHintChain;
    procedure TestStepMaxTries;
    procedure TestStepRetrySessionIds;
    procedure TestFailedStepHandling;
  end;

implementation

uses
  SysUtils, mirmid.plan, mirmid.session, mirmid.util;

constructor TPlannerEventLog.Create;
begin
  inherited Create;
  PlanEvents := 0;
  StepStartEvents := 0;
  StepEndEvents := 0;
  ReportEvents := 0;
  SubSessionStartEvents := 0;
  SubSessionEndEvents := 0;
  PlanChanged := 0;
  LastPlanText := '';
  LastStepStartText := '';
  LastStepEndText := '';
  LastReportText := '';
  LastSubSessionStartText := '';
  LastSubSessionEndText := '';
end;

procedure TPlannerEventLog.OnEvent(Kind: TAgentEventKind; const Text: string);
begin
  case Kind of
    aePlan:
      begin
        Inc(PlanEvents);
        LastPlanText := Text;
      end;
    aeStepStart:
      begin
        Inc(StepStartEvents);
        LastStepStartText := Text;
      end;
    aeStepEnd:
      begin
        Inc(StepEndEvents);
        LastStepEndText := Text;
      end;
    aeReport:
      begin
        Inc(ReportEvents);
        LastReportText := Text;
      end;
    aeSubSessionStart:
      begin
        Inc(SubSessionStartEvents);
        LastSubSessionStartText := Text;
      end;
    aeSubSessionEnd:
      begin
        Inc(SubSessionEndEvents);
        LastSubSessionEndText := Text;
      end;
  end;
end;

procedure TPlannerEventLog.OnPlanChanged;
begin
  Inc(PlanChanged);
end;

procedure TPlannerTests.SetUp;
var
  P: TPlan;
begin
  FPlanner := TPlanner.Create(DefaultConfig, nil);
  { План из четырёх pending-шагов; владение передаётся планировщику. }
  P := TPlan.Create;
  P.AddStep('первый');
  P.AddStep('второй');
  P.AddStep('третий');
  P.AddStep('четвёртый');
  FPlanner.Plan := P;
  FReg := TToolRegistry.Create;
  RegisterRevisePlanTool(FReg, FPlanner);
  FCtx := MakeToolContext(DefaultConfig);
  FLog := TPlannerEventLog.Create;
  FPlanner.OnEvent := @FLog.OnEvent;
  FPlanner.OnPlanChanged := @FLog.OnPlanChanged;
end;

procedure TPlannerTests.TearDown;
begin
  FPlanner.Free;
  FReg.Free;
  FLog.Free;
end;

function TPlannerTests.InvokeRevise(const ArgsJson: string): TToolOutcome;
begin
  Result := FReg.Invoke(REVISE_PLAN_TOOL_NAME, ArgsJson, FCtx);
end;

{ Инструмент зарегистрирован в реестре. }
procedure TPlannerTests.TestToolRegistered;
begin
  AssertTrue('revise_plan зарегистрирован', FReg.Has(REVISE_PLAN_TOOL_NAME));
end;

{ add в конец: новый шаг с авто-id добавляется в конец плана. }
procedure TPlannerTests.TestReviseAddToEnd;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"новый шаг"}]}');
  AssertFalse('без ошибки: ' + O.Text, O.IsError);
  AssertEquals('пять шагов', 5, Length(FPlanner.Plan.Steps));
  AssertEquals('id', 's5', FPlanner.Plan.Steps[4].Id);
  AssertEquals('описание', 'новый шаг', FPlanner.Plan.Steps[4].Description);
  AssertEquals('статус', Ord(psPending), Ord(FPlanner.Plan.Steps[4].Status));
end;

{ add после шага: новый шаг встаёт после указанного. }
procedure TPlannerTests.TestReviseAddAfter;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"новый","after":"s2"}]}');
  AssertFalse('без ошибки: ' + O.Text, O.IsError);
  AssertEquals('пять шагов', 5, Length(FPlanner.Plan.Steps));
  AssertEquals('s1 на месте', 'первый', FPlanner.Plan.Steps[0].Description);
  AssertEquals('s2 на месте', 'второй', FPlanner.Plan.Steps[1].Description);
  AssertEquals('новый после s2', 'новый', FPlanner.Plan.Steps[2].Description);
  AssertEquals('s3 сдвинут', 'третий', FPlanner.Plan.Steps[3].Description);
  AssertEquals('s4 сдвинут', 'четвёртый', FPlanner.Plan.Steps[4].Description);
end;

{ add после удаления: авто-id sN может столкнуться — планировщик
  присваивает свободный id. }
procedure TPlannerTests.TestReviseAddAfterRemove;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s2"},{"op":"add","description":"новый"}]}');
  AssertFalse('без ошибки: ' + O.Text, O.IsError);
  AssertEquals('четыре шага', 4, Length(FPlanner.Plan.Steps));
  AssertEquals('новый id свободен', 's5', FPlanner.Plan.Steps[3].Id);
  AssertEquals('описание', 'новый', FPlanner.Plan.Steps[3].Description);
end;

{ remove: шаг удаляется, порядок остальных сохраняется. }
procedure TPlannerTests.TestReviseRemove;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s2"}]}');
  AssertFalse('без ошибки: ' + O.Text, O.IsError);
  AssertEquals('три шага', 3, Length(FPlanner.Plan.Steps));
  AssertEquals('s1', 'первый', FPlanner.Plan.Steps[0].Description);
  AssertEquals('s3', 'третий', FPlanner.Plan.Steps[1].Description);
  AssertEquals('s4', 'четвёртый', FPlanner.Plan.Steps[2].Description);
end;

{ reorder: новый порядок шагов. }
procedure TPlannerTests.TestReviseReorder;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"reorder","order":["s4","s1","s2","s3"]}]}');
  AssertFalse('без ошибки: ' + O.Text, O.IsError);
  AssertEquals('порядок 1', 'четвёртый', FPlanner.Plan.Steps[0].Description);
  AssertEquals('порядок 2', 'первый', FPlanner.Plan.Steps[1].Description);
  AssertEquals('порядок 3', 'второй', FPlanner.Plan.Steps[2].Description);
  AssertEquals('порядок 4', 'третий', FPlanner.Plan.Steps[3].Description);
end;

{ skip: pending-шаг помечается пропущенным. }
procedure TPlannerTests.TestReviseSkip;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"skip","id":"s4"}]}');
  AssertFalse('без ошибки: ' + O.Text, O.IsError);
  AssertEquals('статус', Ord(psSkipped), Ord(FPlanner.Plan.Steps[3].Status));
end;

{ skip для непустого pending-шага — ошибка. }
procedure TPlannerTests.TestReviseSkipNonPending;
var
  O: TToolOutcome;
begin
  FPlanner.Plan.SetStatus('s1', psDone, 'готово');
  O := InvokeRevise('{"ops":[{"op":"skip","id":"s1"}]}');
  AssertTrue('ошибка', O.IsError);
  AssertTrue('сообщение о pending', Pos('pending', O.Text) > 0);
end;

{ Неизвестный id — ошибка, план не меняется. }
procedure TPlannerTests.TestReviseUnknownId;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s9"}]}');
  AssertTrue('ошибка', O.IsError);
  AssertTrue('сообщение о шаге', Pos('s9', O.Text) > 0);
  AssertEquals('план не изменился', 4, Length(FPlanner.Plan.Steps));
end;

{ Неизвестный op — ошибка. }
procedure TPlannerTests.TestReviseUnknownOp;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"teleport","id":"s1"}]}');
  AssertTrue('ошибка', O.IsError);
  AssertTrue('сообщение об op', Pos('teleport', O.Text) > 0);
end;

{ Пустой ops — ошибка. }
procedure TPlannerTests.TestReviseEmptyOps;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[]}');
  AssertTrue('ошибка', O.IsError);
  AssertTrue('сообщение об ops', Pos('ops', O.Text) > 0);
end;

{ Отсутствующий ops — ошибка. }
procedure TPlannerTests.TestReviseMissingOps;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{}');
  AssertTrue('ошибка', O.IsError);
  AssertTrue('сообщение об ops', Pos('ops', O.Text) > 0);
end;

{ Невалидная операция после валидной: валидная применяется,
  в результате — текст ошибки. }
procedure TPlannerTests.TestRevisePartialApply;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"новый"},{"op":"remove","id":"s9"}]}');
  AssertTrue('ошибка', O.IsError);
  AssertTrue('сообщение о s9', Pos('s9', O.Text) > 0);
  AssertEquals('add применён', 5, Length(FPlanner.Plan.Steps));
  AssertEquals('новый шаг в конце', 'новый', FPlanner.Plan.Steps[4].Description);
end;

{ Успех: события aePlan и OnPlanChanged срабатывают, текст события —
  отрендеренный план. }
procedure TPlannerTests.TestReviseEvents;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"новый шаг"}]}');
  AssertFalse('без ошибки: ' + O.Text, O.IsError);
  AssertEquals('aePlan сработал', 1, FLog.PlanEvents);
  AssertEquals('OnPlanChanged сработал', 1, FLog.PlanChanged);
  AssertTrue('текст плана в событии', Pos('новый шаг', FLog.LastPlanText) > 0);
  AssertTrue('результат упоминает изменение', Pos('add', O.Text) > 0);
  { revise_plan не открывает под-сессию планировщика. }
  AssertEquals('aeSubSessionStart не шлётся', 0, FLog.SubSessionStartEvents);
  AssertEquals('aeSubSessionEnd не шлётся', 0, FLog.SubSessionEndEvents);
end;

{ Ошибка без изменения плана: события не шлются. }
procedure TPlannerTests.TestReviseNoEventsOnUnchangedError;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s9"}]}');
  AssertTrue('ошибка', O.IsError);
  AssertEquals('aePlan не шлётся', 0, FLog.PlanEvents);
  AssertEquals('OnPlanChanged не шлётся', 0, FLog.PlanChanged);
end;

{ События под-сессий планировщика (анализ и шаг плана): тестовый обработчик
  считает aeSubSessionStart/aeSubSessionEnd и запоминает метки. Сами фазы без
  сети не запустить (нужен ответ модели), поэтому проверяется контракт меток,
  которые шлют AnalysisPhase/RunStep: «анализ» и «шаг sN». }
procedure TPlannerTests.TestSubSessionEvents;
begin
  FLog.OnEvent(aeSubSessionStart, 'анализ');
  FLog.OnEvent(aeSubSessionEnd, 'анализ');
  FLog.OnEvent(aeSubSessionStart, 'шаг s1');
  FLog.OnEvent(aeSubSessionEnd, 'шаг s1');
  AssertEquals('два старта под-сессий', 2, FLog.SubSessionStartEvents);
  AssertEquals('два конца под-сессий', 2, FLog.SubSessionEndEvents);
  AssertEquals('последняя метка старта', 'шаг s1', FLog.LastSubSessionStartText);
  AssertEquals('последняя метка конца', 'шаг s1', FLog.LastSubSessionEndText);
  { События под-сессий не подменяют события шагов и плана. }
  AssertEquals('aeStepStart не путается', 0, FLog.StepStartEvents);
  AssertEquals('aeStepEnd не путается', 0, FLog.StepEndEvents);
  AssertEquals('aePlan не путается', 0, FLog.PlanEvents);
end;

{ Регрессия (task1.md): фаза анализа наследует набор инструментов
  родительской сессии. Раньше AnalysisPhase жёстко выключала пишущие и
  сетевые инструменты, поэтому при включённом ключе shell инструмент отвечал
  «выполнение команд запрещено». }
procedure TPlannerTests.TestAnalysisConfigInheritsPolicies;
var
  Cfg, AC: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  SetToolEnabled(Cfg, 'edit_text_file', True);
  SetToolEnabled(Cfg, 'shell', True);
  SetToolEnabled(Cfg, 'http_request', True);
  Cfg.Model := 'модель-анализа';
  Cfg.MaxSteps := 7;
  AC := AnalysisConfig(Cfg);
  AssertTrue('edit_text_file наследуется', ToolEnabled(AC, 'edit_text_file'));
  AssertTrue('shell наследуется', ToolEnabled(AC, 'shell'));
  AssertTrue('http_request наследуется', ToolEnabled(AC, 'http_request'));
  AssertEquals('модель наследуется', 'модель-анализа', AC.Model);
  AssertEquals('бюджет шагов наследуется', 7, AC.MaxSteps);
  AssertEquals('подсказка аналитика', PLANNER_ANALYSIS_PROMPT, AC.SystemPrompt);
  { Родительский конфиг — запись, поэтому копия не меняет его. }
  SetToolEnabled(AC, 'shell', False);
  AssertTrue('родитель не изменён', ToolEnabled(Cfg, 'shell'));
  { Выключенный в родителе инструмент остаётся выключенным и в анализе. }
  SetToolEnabled(Cfg, 'shell', False);
  AssertFalse('запрет наследуется',
    ToolEnabled(AnalysisConfig(Cfg), 'shell'));
end;

{ Подсказка шага: общая задача, текущий план, цель шага. }
procedure TPlannerTests.TestStepPrompt;
var
  SP: string;
begin
  SP := BuildStepPrompt('задача', '1. [pending] шаг', 'шаг');
  AssertTrue('задача в подсказке', Pos('задача', SP) > 0);
  AssertTrue('план в подсказке', Pos('1. [pending] шаг', SP) > 0);
  AssertTrue('цель в подсказке', Pos('Цель текущего шага: шаг', SP) > 0);
end;

{ Отчёт: задача, отрендеренный план, сводка. }
procedure TPlannerTests.TestPlanReport;
var
  P: TPlan;
  R: string;
begin
  P := TPlan.Create;
  try
    P.AddStep('сделать');
    P.SetStatus('s1', psDone, 'готово');
    R := BuildPlanReport(P, 'задача');
    AssertTrue('задача в отчёте', Pos('Задача: задача', R) > 0);
    AssertTrue('план в отчёте', Pos('1. [done] сделать — готово', R) > 0);
    AssertTrue('сводка в отчёте', Pos('Сводка: 1/1 выполнено', R) > 0);
  finally
    P.Free;
  end;
end;

{ Разбор плана из текста: валидный план и ошибка. }
procedure TPlannerTests.TestParsePlanFromText;
var
  P: TPlan;
  Err: string;
begin
  P := ParsePlanFromText('План: {"steps":[{"description":"a"},{"description":"b"}]}', Err);
  AssertTrue('план разобран', P <> nil);
  try
    AssertEquals('два шага', 2, Length(P.Steps));
    AssertEquals('id 1', 's1', P.Steps[0].Id);
    AssertEquals('id 2', 's2', P.Steps[1].Id);
  finally
    P.Free;
  end;
  P := ParsePlanFromText('JSON здесь нет', Err);
  AssertNull('нет JSON — nil', P);
  AssertTrue('ошибка', Err <> '');
end;

{ Сессия шага сохраняется в файл <база>_step_<id>.json (по аналогии с
  основной сессией); при пустом SessionBase файл не создаётся. }
procedure TPlannerTests.TestStepSessionSaved;
var
  Cfg: TMirmidConfig;
  P: TPlanner;
  Plan: TPlan;
  Step: TPlanStep;
  Msgs, Msgs2: TMessages;
  Plan2: TPlan;
  Err: string;
  Dir, SessDir, FilePath: string;
begin
  Dir := IncludeTrailingPathDelimiter(TempDir) +
    'mirmid-planner-step-' + IntToStr(Random(1000000));
  SessDir := IncludeTrailingPathDelimiter(Dir) + '.mirmid' + PathDelim + 'sessions';
  FilePath := IncludeTrailingPathDelimiter(SessDir) + 'testsess_step_s1.json';
  try
    Cfg := DefaultConfig;
    Cfg.WorkDir := Dir;
    P := TPlanner.Create(Cfg, nil);
    try
      P.SessionBase := 'testsess';
      Plan := TPlan.Create;
      try
        Plan.AddStep('сделать');
        Step := Plan.Steps[0];
        SetLength(Msgs, 1);
        Msgs[0].Role := mrUser;
        Msgs[0].Content := 'сделать';

        { Первая попытка — прежнее имя <база>_step_<id>. }
        P.SaveStepSession(Step, Msgs, 1);
        AssertTrue('файл создан', FileExists(FilePath));
        Msgs2 := nil;
        Plan2 := nil;
        AssertTrue('загрузка: ' + Err,
          LoadSession(SessDir, 'testsess_step_s1', Msgs2, Plan2, Err));
        AssertEquals('число сообщений', 1, Length(Msgs2));
        AssertEquals('текст', 'сделать', Msgs2[0].Content);
        AssertNull('план nil', Plan2);

        { Повторная попытка — отдельный файл с номером попытки, сессия первой
          попытки не перезаписана. }
        Msgs[0].Content := 'сделать (повтор)';
        P.SaveStepSession(Step, Msgs, 2);
        AssertTrue('файл попытки 2 создан',
          FileExists(IncludeTrailingPathDelimiter(SessDir) +
            'testsess_step_s1_try2.json'));
        Msgs2 := nil;
        Plan2 := nil;
        AssertTrue('загрузка попытки 2: ' + Err,
          LoadSession(SessDir, 'testsess_step_s1_try2', Msgs2, Plan2, Err));
        AssertEquals('текст попытки 2', 'сделать (повтор)', Msgs2[0].Content);
        Msgs2 := nil;
        Plan2 := nil;
        AssertTrue('загрузка попытки 1: ' + Err,
          LoadSession(SessDir, 'testsess_step_s1', Msgs2, Plan2, Err));
        AssertEquals('попытка 1 не перезаписана', 'сделать', Msgs2[0].Content);
        DeleteFile(IncludeTrailingPathDelimiter(SessDir) +
          'testsess_step_s1_try2.json');

        { Пустой SessionBase — файл не создаётся. }
        DeleteFile(FilePath);
        P.SessionBase := '';
        P.SaveStepSession(Step, Msgs, 1);
        AssertFalse('без базы файл не создаётся', FileExists(FilePath));
      finally
        Plan.Free;
      end;
    finally
      P.Free;
    end;
  finally
    DeleteFile(FilePath);
    RemoveDir(SessDir);
    RemoveDir(IncludeTrailingPathDelimiter(Dir) + '.mirmid');
    RemoveDir(Dir);
  end;
end;

{ Гейтинг результата шага в aeStepEnd: планировщик кладёт в событие
  «s1: done — результат» (StepEndText), а CLI печатает результат только по
  --show-step-result / --show-reasoning. По умолчанию от шага остаётся строка
  статуса без результата: событие результат содержит, но он скрыт. }
procedure TPlannerTests.TestStepEndResultGating;
var
  P: TPlan;
  Txt: string;
begin
  P := TPlan.Create;
  try
    P.AddStep('сделать');
    P.SetStatus('s1', psDone, 'готово');
    Txt := StepEndText(P.Steps[0]);
    AssertEquals('событие aeStepEnd с результатом', 's1: done — готово', Txt);

    { Без флагов печатается только статус шага. }
    AssertFalse('по умолчанию текст шага скрыт', StepTextVisible(False, False));
    AssertEquals('статус без результата', 's1: done', FormatStepEndStatus(Txt));
    AssertEquals('результата в строке статуса нет', 0,
      Pos('готово', FormatStepEndStatus(Txt)));

    { Любой из флагов показывает полный текст события (результат не усечён). }
    AssertTrue('--show-step-result', StepTextVisible(True, False));
    AssertTrue('--show-reasoning', StepTextVisible(False, True));
    AssertTrue('оба флага', StepTextVisible(True, True));
    AssertEquals('полный текст события', Txt, FormatStepEnd(Txt));

    { Шаг без результата: разделителя нет, статус совпадает с событием. }
    P.SetStatus('s1', psFailed, '');
    Txt := StepEndText(P.Steps[0]);
    AssertEquals('событие без результата', 's1: failed', Txt);
    AssertEquals('статус = событие', Txt, FormatStepEndStatus(Txt));

    { Шаг, удалённый из плана в подцикле: тоже без результата, гейтинг
      оставляет текст как есть. }
    Txt := 's1: удалён из плана';
    AssertEquals('удалённый шаг без изменений', Txt, FormatStepEndStatus(Txt));
  finally
    P.Free;
  end;
end;

{ Классификация нештатного результата шага: три класса (turn/empty/error) и
  штатный sfNone. Проверяются приоритеты: отказ хода перекрывает текст,
  пустой ответ отличается от текста ошибки инструмента. }
procedure TPlannerTests.TestClassifyStepResult;
var
  Reason: string;
begin
  { Штатный результат. }
  AssertTrue('успех — sfNone',
    ClassifyStepResult(True, 'готово', '') = sfNone);
  AssertEquals('имя класса успеха', 'ok', StepFailureName(sfNone));
  AssertEquals('причины у успеха нет', '', StepFailureReason(sfNone, 'готово', ''));

  { Отказ хода: Err — причина. }
  AssertTrue('отказ хода — sfTurn',
    ClassifyStepResult(False, '', 'нет сети') = sfTurn);
  AssertEquals('имя класса отказа', 'turn', StepFailureName(sfTurn));
  Reason := StepFailureReason(sfTurn, '', 'нет сети');
  AssertEquals('причина отказа с Err', 'ход завершился неудачей: нет сети', Reason);
  Reason := StepFailureReason(sfTurn, '', '  ');
  AssertEquals('причина отказа без Err',
    'ход завершился неудачей без указания причины', Reason);

  { Пустой и пробельный ответ при успешном ходе. }
  AssertTrue('пустой ответ — sfEmpty',
    ClassifyStepResult(True, '', '') = sfEmpty);
  AssertTrue('пробельный ответ — sfEmpty',
    ClassifyStepResult(True, '  ' + LineEnding, '') = sfEmpty);
  AssertEquals('имя класса пустого ответа', 'empty', StepFailureName(sfEmpty));
  Reason := StepFailureReason(sfEmpty, '', '');
  AssertEquals('причина пустого ответа',
    'ответ модели пуст: шаг не вернул результата', Reason);

  { Текст ошибки инструмента стал финальным ответом шага (в т.ч. с ведущим
    переводом строки/пробелами). }
  AssertTrue('ERROR: в ответе — sfError',
    ClassifyStepResult(True, 'ERROR: нет доступа', '') = sfError);
  AssertTrue('ERROR: после пробелов — sfError',
    ClassifyStepResult(True, ' ' + LineEnding + 'ERROR: нет доступа', '') = sfError);
  AssertTrue('ERROR: не в начале — штатный результат',
    ClassifyStepResult(True, 'инструмент вернул ERROR: но шаг продолжен', '') = sfNone);
  AssertEquals('имя класса ошибки', 'error', StepFailureName(sfError));
  Reason := StepFailureReason(sfError, 'ERROR: нет доступа', '');
  AssertEquals('причина ошибки инструмента',
    'шаг завершился ошибкой инструмента: ERROR: нет доступа', Reason);

  { Приоритет: при RunTurn=False текст ответа не важен. }
  AssertTrue('отказ хода важнее текста',
    ClassifyStepResult(False, 'ERROR: что-то', 'нет сети') = sfTurn);
end;

{ Повтор шага: подсказка второй попытки содержит причину неудачи и требование
  устранить её, а не повторять неудачное действие; пустая (пробельная) причина
  ничего не добавляет — первая попытка совпадает с BuildStepPrompt. Длинная
  причина усекается, чтобы «простыня» ответа не раздувала системную подсказку
  каждой следующей попытки. }
procedure TPlannerTests.TestStepPromptWithFixHint;
const
  TASK = 'задача';
  PLAN = '1. [in_progress] шаг';
  DESC = 'шаг';
var
  Base, SP, Hint: string;
begin
  Base := BuildStepPrompt(TASK, PLAN, DESC);
  AssertEquals('без причины — как BuildStepPrompt', Base,
    StepPrompt(TASK, PLAN, DESC, ''));
  AssertEquals('пробельная причина игнорируется', Base,
    StepPrompt(TASK, PLAN, DESC, '  ' + LineEnding));
  AssertEquals('табуляция вместо причины игнорируется', Base,
    StepPrompt(TASK, PLAN, DESC, #9));

  { Причина прошлой попытки — в подсказке повтора, вместе с требованием
    исправить ситуацию и прежним текстом шага. }
  Hint := 'ход завершился неудачей: нет сети';
  SP := StepPrompt(TASK, PLAN, DESC, Hint);
  AssertEquals('прежняя подсказка в начале', 1, Pos(Base, SP));
  AssertTrue('причина прошлой попытки', Pos(Hint, SP) > 0);
  AssertTrue('требование исправить', Pos('Устрани причину неудачи', SP) > 0);
  AssertTrue('запрет повторять действие', Pos('Не повторяй', SP) > 0);

  { Усечение: 900-байтовый ответ целиком в подсказку не попадает. }
  Hint := StringOfChar('x', 900);
  SP := StepPrompt(TASK, PLAN, DESC, Hint);
  AssertTrue('начало причины сохранено',
    Pos(StringOfChar('x', PLAN_STEP_RESULT_MAX), SP) > 0);
  AssertEquals('простыня не попала целиком', 0, Pos(Hint, SP));
  AssertTrue('признак усечения', Pos('…', SP) > 0);
end;

{ Цепочка повтора: класс нештатного результата → причина (StepFailureReason)
  → подсказка следующей попытки (StepPrompt). Проверяются все три нештатных
  класса: отказ хода, пустой ответ и текст ошибки инструмента. }
procedure TPlannerTests.TestStepRetryHintChain;
var
  Kind: TStepFailure;
  Reason, SP: string;
begin
  { Ход завершился неудачей: причина — Err провайдера. }
  Kind := ClassifyStepResult(False, '', 'HTTP 500');
  AssertTrue('отказ хода', Kind = sfTurn);
  Reason := StepFailureReason(Kind, '', 'HTTP 500');
  SP := StepPrompt('задача', '1. [failed] шаг', 'шаг', Reason);
  AssertTrue('причина отказа в подсказке повтора', Pos('HTTP 500', SP) > 0);

  { Пустой ответ при успешном ходе — тоже повод для повтора. }
  Kind := ClassifyStepResult(True, '  ' + LineEnding, '');
  AssertTrue('пустой ответ', Kind = sfEmpty);
  Reason := StepFailureReason(Kind, '  ' + LineEnding, '');
  SP := StepPrompt('задача', '1. [failed] шаг', 'шаг', Reason);
  AssertTrue('причина пустого ответа в подсказке', Pos('пуст', SP) > 0);

  { Ошибка инструмента стала финальным ответом шага. }
  Kind := ClassifyStepResult(True, 'ERROR: нет доступа', '');
  AssertTrue('ошибка инструмента', Kind = sfError);
  Reason := StepFailureReason(Kind, 'ERROR: нет доступа', '');
  SP := StepPrompt('задача', '1. [failed] шаг', 'шаг', Reason);
  AssertTrue('текст ошибки инструмента в подсказке',
    Pos('ERROR: нет доступа', SP) > 0);

  { Штатный результат повтора не требует: причины нет, подсказка — первая
    попытка, причину прошлой попытки RunPlannedTurn сбрасывает (FixHint=''). }
  Kind := ClassifyStepResult(True, 'готово', '');
  AssertEquals('успех — без причины', '', StepFailureReason(Kind, 'готово', ''));
  AssertEquals('после успеха подсказка обычная',
    BuildStepPrompt('задача', '1. [done] шаг', 'шаг'),
    StepPrompt('задача', '1. [done] шаг', 'шаг', ''));
end;

{ Политика повторов шага: предел попыток = 1 + PlanStepFixAttempts (первая
  попытка плюс повторы исправления); 0 — повторов нет, отрицательное значение
  из INI не отменяет первую попытку. По умолчанию — один повтор. }
procedure TPlannerTests.TestStepMaxTries;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  AssertEquals('по умолчанию один повтор', 1, Cfg.PlanStepFixAttempts);
  AssertEquals('две попытки по умолчанию', 2, StepMaxTries(Cfg));
  Cfg.PlanStepFixAttempts := 0;
  AssertEquals('без повторов одна попытка', 1, StepMaxTries(Cfg));
  Cfg.PlanStepFixAttempts := 3;
  AssertEquals('три повтора — четыре попытки', 4, StepMaxTries(Cfg));
  Cfg.PlanStepFixAttempts := -5;
  AssertEquals('отрицательное — всё равно одна попытка', 1,
    StepMaxTries(Cfg));
end;

{ Имена сессий попыток шага: первая попытка — прежнее имя <база>_step_<id>,
  повторы — с суффиксом _try<N>, поэтому попытки не затирают друг друга.
  Такие файлы остаются вспомогательными сессиями и в список основных не
  попадают. }
procedure TPlannerTests.TestStepRetrySessionIds;
begin
  AssertEquals('первая попытка — имя шага', StepSessionId('base', 's1'),
    StepSessionIdTry('base', 's1', 1));
  AssertEquals('нулевой номер — как первая', 'base_step_s1',
    StepSessionIdTry('base', 's1', 0));
  AssertEquals('вторая попытка', 'base_step_s1_try2',
    StepSessionIdTry('base', 's1', 2));
  AssertEquals('третья попытка', 'base_step_s1_try3',
    StepSessionIdTry('base', 's1', 3));
  AssertTrue('сессия повтора — вспомогательная',
    IsAuxSessionFile('base_step_s1_try2.json'));
  AssertTrue('сессия шага — вспомогательная',
    IsAuxSessionFile('base_step_s1.json'));
  AssertFalse('основная сессия — не вспомогательная',
    IsAuxSessionFile('base.json'));
end;

{ Обработка сбоя шага на уровне плана — на этом держится цикл повторов
  RunPlannedTurn:
  - проваленный шаг перестаёт быть pending (следующий шаг берётся из
    NextPending, а когда pending не осталось — цикл завершается);
  - повторный заход разрешён: failed → in_progress ставится перед каждой
    новой попыткой;
  - шаг, удалённый revise_plan внутри подцикла, повторять нечего: FindStep < 0,
    а SetStatus возвращает False (по этому признаку цикл делает Break);
  - пропустить проваленный шаг нельзя (правило pending), его удаляют или
    переставляют план. }
procedure TPlannerTests.TestFailedStepHandling;
var
  P: TPlan;
  O: TToolOutcome;
begin
  P := FPlanner.Plan;
  AssertTrue('s1 взят в работу', P.SetStatus('s1', psInProgress, ''));
  AssertTrue('s1 провален',
    P.SetStatus('s1', psFailed, 'ход завершился неудачей: нет сети'));
  AssertEquals('следующий pending — s2', 's2', P.Steps[P.NextPending].Id);
  AssertEquals('проваленный шаг не pending', 1, P.CountByStatus(psFailed));
  AssertEquals('pending остались s2..s4', 3, P.CountByStatus(psPending));

  { Повтор: цикл попыток ставит шаг снова в работу. }
  AssertTrue('повтор разрешён', P.SetStatus('s1', psInProgress, ''));
  AssertEquals('статус повтора', Ord(psInProgress), Ord(P.Steps[0].Status));

  { Проваленный шаг не пропускается — как и любой не-pending шаг. }
  AssertTrue('снова провален', P.SetStatus('s1', psFailed, 'причина'));
  O := InvokeRevise('{"ops":[{"op":"skip","id":"s1"}]}');
  AssertTrue('skip проваленного шага — ошибка', O.IsError);
  AssertTrue('сообщение о pending', Pos('pending', O.Text) > 0);
  AssertEquals('статус не изменился', Ord(psFailed), Ord(P.Steps[0].Status));

  { Шаг удалён из плана внутри подцикла (revise_plan): повторять нечего. }
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s1"}]}');
  AssertFalse('remove без ошибки: ' + O.Text, O.IsError);
  AssertTrue('шага нет в плане', P.FindStep('s1') < 0);
  AssertFalse('SetStatus удалённого шага — False (признак Break)',
    P.SetStatus('s1', psInProgress, ''));

  { План доведён до терминального состояния: ход считается успешным
    (pending/in_progress нет), новых шагов цикл не берёт. }
  AssertTrue('s2 выполнен', P.SetStatus('s2', psDone, 'готово'));
  AssertTrue('s3 пропущен', P.SetStatus('s3', psSkipped, 'не нужно'));
  AssertTrue('s4 провален', P.SetStatus('s4', psFailed, 'причина'));
  AssertEquals('pending нет', 0, P.CountByStatus(psPending));
  AssertEquals('in_progress нет', 0, P.CountByStatus(psInProgress));
  AssertTrue('следующего шага нет', P.NextPending < 0);
end;

initialization
  RegisterTest(TPlannerTests);

end.
