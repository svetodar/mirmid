unit test_planner;
{ Tests of the planner (mirmid.planner): the revise_plan tool (add/remove/
  reorder/skip, invalid operations, partial application, events) and the pure
  parts (step prompt, report, plan parsing from text). No network. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.types, mirmid.tools, mirmid.agent, mirmid.planner,
  mirmid.cli;

type
  { Test event handler of the planner: counts the events and remembers the
    last text. The planner sub-session events (aeSubSessionStart/aeSubSessionEnd)
    are counted separately: entering/leaving the analysis and a plan step with
    the label "analysis"/"step sN". }
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
  { A plan of four pending steps; ownership goes to the planner. }
  P := TPlan.Create;
  P.AddStep('first');
  P.AddStep('second');
  P.AddStep('third');
  P.AddStep('fourth');
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

{ The tool is registered in the registry. }
procedure TPlannerTests.TestToolRegistered;
begin
  AssertTrue('revise_plan is registered', FReg.Has(REVISE_PLAN_TOOL_NAME));
end;

{ add to the end: a new step with an auto id is appended to the plan. }
procedure TPlannerTests.TestReviseAddToEnd;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"new step"}]}');
  AssertFalse('no error: ' + O.Text, O.IsError);
  AssertEquals('five steps', 5, Length(FPlanner.Plan.Steps));
  AssertEquals('id', 's5', FPlanner.Plan.Steps[4].Id);
  AssertEquals('description', 'new step', FPlanner.Plan.Steps[4].Description);
  AssertEquals('status', Ord(psPending), Ord(FPlanner.Plan.Steps[4].Status));
end;

{ add after a step: the new step lands after the given one. }
procedure TPlannerTests.TestReviseAddAfter;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"new","after":"s2"}]}');
  AssertFalse('no error: ' + O.Text, O.IsError);
  AssertEquals('five steps', 5, Length(FPlanner.Plan.Steps));
  AssertEquals('s1 in place', 'first', FPlanner.Plan.Steps[0].Description);
  AssertEquals('s2 in place', 'second', FPlanner.Plan.Steps[1].Description);
  AssertEquals('new one after s2', 'new', FPlanner.Plan.Steps[2].Description);
  AssertEquals('s3 shifted', 'third', FPlanner.Plan.Steps[3].Description);
  AssertEquals('s4 shifted', 'fourth', FPlanner.Plan.Steps[4].Description);
end;

{ add after remove: the auto id sN may collide - the planner assigns a free id. }
procedure TPlannerTests.TestReviseAddAfterRemove;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s2"},{"op":"add","description":"new"}]}');
  AssertFalse('no error: ' + O.Text, O.IsError);
  AssertEquals('four steps', 4, Length(FPlanner.Plan.Steps));
  AssertEquals('the new id is free', 's5', FPlanner.Plan.Steps[3].Id);
  AssertEquals('description', 'new', FPlanner.Plan.Steps[3].Description);
end;

{ remove: the step is deleted, the order of the rest is kept. }
procedure TPlannerTests.TestReviseRemove;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s2"}]}');
  AssertFalse('no error: ' + O.Text, O.IsError);
  AssertEquals('three steps', 3, Length(FPlanner.Plan.Steps));
  AssertEquals('s1', 'first', FPlanner.Plan.Steps[0].Description);
  AssertEquals('s3', 'third', FPlanner.Plan.Steps[1].Description);
  AssertEquals('s4', 'fourth', FPlanner.Plan.Steps[2].Description);
end;

{ reorder: a new order of the steps. }
procedure TPlannerTests.TestReviseReorder;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"reorder","order":["s4","s1","s2","s3"]}]}');
  AssertFalse('no error: ' + O.Text, O.IsError);
  AssertEquals('order 1', 'fourth', FPlanner.Plan.Steps[0].Description);
  AssertEquals('order 2', 'first', FPlanner.Plan.Steps[1].Description);
  AssertEquals('order 3', 'second', FPlanner.Plan.Steps[2].Description);
  AssertEquals('order 4', 'third', FPlanner.Plan.Steps[3].Description);
end;

{ skip: a pending step is marked as skipped. }
procedure TPlannerTests.TestReviseSkip;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"skip","id":"s4"}]}');
  AssertFalse('no error: ' + O.Text, O.IsError);
  AssertEquals('status', Ord(psSkipped), Ord(FPlanner.Plan.Steps[3].Status));
end;

{ skip on a non-pending step is an error. }
procedure TPlannerTests.TestReviseSkipNonPending;
var
  O: TToolOutcome;
begin
  FPlanner.Plan.SetStatus('s1', psDone, 'done');
  O := InvokeRevise('{"ops":[{"op":"skip","id":"s1"}]}');
  AssertTrue('error', O.IsError);
  AssertTrue('message about pending', Pos('pending', O.Text) > 0);
end;

{ Unknown id: an error, the plan stays unchanged. }
procedure TPlannerTests.TestReviseUnknownId;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s9"}]}');
  AssertTrue('error', O.IsError);
  AssertTrue('message about the step', Pos('s9', O.Text) > 0);
  AssertEquals('plan unchanged', 4, Length(FPlanner.Plan.Steps));
end;

{ Unknown op: an error. }
procedure TPlannerTests.TestReviseUnknownOp;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"teleport","id":"s1"}]}');
  AssertTrue('error', O.IsError);
  AssertTrue('message about the op', Pos('teleport', O.Text) > 0);
end;

{ Empty ops: an error. }
procedure TPlannerTests.TestReviseEmptyOps;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[]}');
  AssertTrue('error', O.IsError);
  AssertTrue('message about ops', Pos('ops', O.Text) > 0);
end;

{ Missing ops: an error. }
procedure TPlannerTests.TestReviseMissingOps;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{}');
  AssertTrue('error', O.IsError);
  AssertTrue('message about ops', Pos('ops', O.Text) > 0);
end;

{ An invalid operation after a valid one: the valid one is applied and the
  outcome is the error text. }
procedure TPlannerTests.TestRevisePartialApply;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"new"},{"op":"remove","id":"s9"}]}');
  AssertTrue('error', O.IsError);
  AssertTrue('message about s9', Pos('s9', O.Text) > 0);
  AssertEquals('add applied', 5, Length(FPlanner.Plan.Steps));
  AssertEquals('new step at the end', 'new', FPlanner.Plan.Steps[4].Description);
end;

{ Success: the aePlan and OnPlanChanged events fire, the event text is the
  rendered plan. }
procedure TPlannerTests.TestReviseEvents;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"add","description":"new step"}]}');
  AssertFalse('no error: ' + O.Text, O.IsError);
  AssertEquals('aePlan fired', 1, FLog.PlanEvents);
  AssertEquals('OnPlanChanged fired', 1, FLog.PlanChanged);
  AssertTrue('plan text in the event', Pos('new step', FLog.LastPlanText) > 0);
  AssertTrue('outcome mentions the change', Pos('add', O.Text) > 0);
  { revise_plan does not open a planner sub-session. }
  AssertEquals('aeSubSessionStart not sent', 0, FLog.SubSessionStartEvents);
  AssertEquals('aeSubSessionEnd not sent', 0, FLog.SubSessionEndEvents);
end;

{ Error without a plan change: no events are sent. }
procedure TPlannerTests.TestReviseNoEventsOnUnchangedError;
var
  O: TToolOutcome;
begin
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s9"}]}');
  AssertTrue('error', O.IsError);
  AssertEquals('aePlan not sent', 0, FLog.PlanEvents);
  AssertEquals('OnPlanChanged not sent', 0, FLog.PlanChanged);
end;

{ Planner sub-session events (analysis and a plan step): the test handler counts
  aeSubSessionStart/aeSubSessionEnd and remembers the labels. The phases
  themselves cannot run without network (a model answer is needed), so the
  contract of the labels sent by AnalysisPhase/RunStep is verified: "analysis"
  and "step sN". }
procedure TPlannerTests.TestSubSessionEvents;
begin
  FLog.OnEvent(aeSubSessionStart, 'analysis');
  FLog.OnEvent(aeSubSessionEnd, 'analysis');
  FLog.OnEvent(aeSubSessionStart, 'step s1');
  FLog.OnEvent(aeSubSessionEnd, 'step s1');
  AssertEquals('two sub-session starts', 2, FLog.SubSessionStartEvents);
  AssertEquals('two sub-session ends', 2, FLog.SubSessionEndEvents);
  AssertEquals('last start label', 'step s1', FLog.LastSubSessionStartText);
  AssertEquals('last end label', 'step s1', FLog.LastSubSessionEndText);
  { Sub-session events do not replace the step and plan events. }
  AssertEquals('aeStepStart not mixed up', 0, FLog.StepStartEvents);
  AssertEquals('aeStepEnd not mixed up', 0, FLog.StepEndEvents);
  AssertEquals('aePlan not mixed up', 0, FLog.PlanEvents);
end;

{ Regression (task1.md): the analysis phase inherits the tool set of the parent
  session. AnalysisPhase used to switch the writing and network tools off
  unconditionally, so with the shell key enabled the tool answered
  "running commands is not allowed". }
procedure TPlannerTests.TestAnalysisConfigInheritsPolicies;
var
  Cfg, AC: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  SetToolEnabled(Cfg, 'edit_text_file', True);
  SetToolEnabled(Cfg, 'shell', True);
  SetToolEnabled(Cfg, 'http_request', True);
  Cfg.Model := 'analysis-model';
  Cfg.MaxSteps := 7;
  AC := AnalysisConfig(Cfg);
  AssertTrue('edit_text_file is inherited', ToolEnabled(AC, 'edit_text_file'));
  AssertTrue('shell is inherited', ToolEnabled(AC, 'shell'));
  AssertTrue('http_request is inherited', ToolEnabled(AC, 'http_request'));
  AssertEquals('model is inherited', 'analysis-model', AC.Model);
  AssertEquals('step budget is inherited', 7, AC.MaxSteps);
  AssertEquals('analyst prompt', PLANNER_ANALYSIS_PROMPT, AC.SystemPrompt);
  { The parent config is a record, so the copy does not change it. }
  SetToolEnabled(AC, 'shell', False);
  AssertTrue('parent unchanged', ToolEnabled(Cfg, 'shell'));
  { A tool disabled in the parent stays disabled in the analysis. }
  SetToolEnabled(Cfg, 'shell', False);
  AssertFalse('the prohibition is inherited',
    ToolEnabled(AnalysisConfig(Cfg), 'shell'));
end;

{ Step prompt: the overall task, the current plan, the goal of the step. }
procedure TPlannerTests.TestStepPrompt;
var
  SP: string;
begin
  SP := BuildStepPrompt('task', '1. [pending] step', 'step');
  AssertTrue('task in the prompt', Pos('task', SP) > 0);
  AssertTrue('plan in the prompt', Pos('1. [pending] step', SP) > 0);
  AssertTrue('goal in the prompt', Pos('Goal of the current step: step', SP) > 0);
end;

{ Report: the task, the rendered plan, the summary. }
procedure TPlannerTests.TestPlanReport;
var
  P: TPlan;
  R: string;
begin
  P := TPlan.Create;
  try
    P.AddStep('do it');
    P.SetStatus('s1', psDone, 'done');
    R := BuildPlanReport(P, 'task');
    AssertTrue('task in the report', Pos('Task: task', R) > 0);
    AssertTrue('plan in the report', Pos('1. [done] do it — done', R) > 0);
    AssertTrue('summary in the report', Pos('Summary: 1/1 done', R) > 0);
  finally
    P.Free;
  end;
end;

{ Plan parsing from text: a valid plan and an error. }
procedure TPlannerTests.TestParsePlanFromText;
var
  P: TPlan;
  Err: string;
begin
  P := ParsePlanFromText('Plan: {"steps":[{"description":"a"},{"description":"b"}]}', Err);
  AssertTrue('plan parsed', P <> nil);
  try
    AssertEquals('two steps', 2, Length(P.Steps));
    AssertEquals('id 1', 's1', P.Steps[0].Id);
    AssertEquals('id 2', 's2', P.Steps[1].Id);
  finally
    P.Free;
  end;
  P := ParsePlanFromText('there is no JSON here', Err);
  AssertNull('no JSON - nil', P);
  AssertTrue('error', Err <> '');
end;

{ The step session is saved to <base>_step_<id>.json (similar to the main
  session); with an empty SessionBase no file is created. }
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
        Plan.AddStep('do it');
        Step := Plan.Steps[0];
        SetLength(Msgs, 1);
        Msgs[0].Role := mrUser;
        Msgs[0].Content := 'do it';

        { First attempt: the former name <base>_step_<id>. }
        P.SaveStepSession(Step, Msgs, 1);
        AssertTrue('file created', FileExists(FilePath));
        Msgs2 := nil;
        Plan2 := nil;
        AssertTrue('load: ' + Err,
          LoadSession(SessDir, 'testsess_step_s1', Msgs2, Plan2, Err));
        AssertEquals('message count', 1, Length(Msgs2));
        AssertEquals('text', 'do it', Msgs2[0].Content);
        AssertNull('plan nil', Plan2);

        { Retry: a separate file with the attempt number, the session of the
          first attempt is not overwritten. }
        Msgs[0].Content := 'do it (retry)';
        P.SaveStepSession(Step, Msgs, 2);
        AssertTrue('attempt 2 file created',
          FileExists(IncludeTrailingPathDelimiter(SessDir) +
            'testsess_step_s1_try2.json'));
        Msgs2 := nil;
        Plan2 := nil;
        AssertTrue('load attempt 2: ' + Err,
          LoadSession(SessDir, 'testsess_step_s1_try2', Msgs2, Plan2, Err));
        AssertEquals('attempt 2 text', 'do it (retry)', Msgs2[0].Content);
        Msgs2 := nil;
        Plan2 := nil;
        AssertTrue('load attempt 1: ' + Err,
          LoadSession(SessDir, 'testsess_step_s1', Msgs2, Plan2, Err));
        AssertEquals('attempt 1 not overwritten', 'do it', Msgs2[0].Content);
        DeleteFile(IncludeTrailingPathDelimiter(SessDir) +
          'testsess_step_s1_try2.json');

        { Empty SessionBase: no file is created. }
        DeleteFile(FilePath);
        P.SessionBase := '';
        P.SaveStepSession(Step, Msgs, 1);
        AssertFalse('no base - no file', FileExists(FilePath));
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

{ Gating of the step result in aeStepEnd: the planner puts "s1: done - result"
  into the event (StepEndText), while the CLI prints the result only with
  --show-step-result / --show-reasoning. By default a step leaves just the
  status line without the result: the event contains the result, but it stays
  hidden. }
procedure TPlannerTests.TestStepEndResultGating;
var
  P: TPlan;
  Txt: string;
begin
  P := TPlan.Create;
  try
    P.AddStep('do it');
    P.SetStatus('s1', psDone, 'file read');
    Txt := StepEndText(P.Steps[0]);
    AssertEquals('aeStepEnd event with the result', 's1: done — file read', Txt);

    { Without the flags only the step status is printed. }
    AssertFalse('the step text is hidden by default', StepTextVisible(False, False));
    AssertEquals('status without the result', 's1: done', FormatStepEndStatus(Txt));
    AssertEquals('no result in the status line', 0,
      Pos('file read', FormatStepEndStatus(Txt)));

    { Any of the flags shows the whole event text (the result is not cut). }
    AssertTrue('--show-step-result', StepTextVisible(True, False));
    AssertTrue('--show-reasoning', StepTextVisible(False, True));
    AssertTrue('both flags', StepTextVisible(True, True));
    AssertEquals('full event text', Txt, FormatStepEnd(Txt));

    { A step without a result: no separator, the status matches the event. }
    P.SetStatus('s1', psFailed, '');
    Txt := StepEndText(P.Steps[0]);
    AssertEquals('event without a result', 's1: failed', Txt);
    AssertEquals('status = event', Txt, FormatStepEndStatus(Txt));

    { A step removed from the plan inside the sub-loop: also without a result,
      the gating leaves the text as is. }
    Txt := 's1: removed from the plan';
    AssertEquals('removed step unchanged', Txt, FormatStepEndStatus(Txt));
  finally
    P.Free;
  end;
end;

{ Classification of an abnormal step result: three classes (turn/empty/error)
  and the normal sfNone. The priorities are checked: a failed turn overrides the
  text, an empty answer differs from a tool error text. }
procedure TPlannerTests.TestClassifyStepResult;
var
  Reason: string;
begin
  { Normal result. }
  AssertTrue('success - sfNone',
    ClassifyStepResult(True, 'done', '') = sfNone);
  AssertEquals('success class name', 'ok', StepFailureName(sfNone));
  AssertEquals('success has no reason', '', StepFailureReason(sfNone, 'done', ''));

  { Failed turn: Err is the reason. }
  AssertTrue('failed turn - sfTurn',
    ClassifyStepResult(False, '', 'no network') = sfTurn);
  AssertEquals('failed turn class name', 'turn', StepFailureName(sfTurn));
  Reason := StepFailureReason(sfTurn, '', 'no network');
  AssertEquals('turn reason with Err', 'the turn failed: no network', Reason);
  Reason := StepFailureReason(sfTurn, '', '  ');
  AssertEquals('turn reason without Err',
    'the turn failed without a stated reason', Reason);

  { Empty and blank answer after a successful turn. }
  AssertTrue('empty answer - sfEmpty',
    ClassifyStepResult(True, '', '') = sfEmpty);
  AssertTrue('blank answer - sfEmpty',
    ClassifyStepResult(True, '  ' + LineEnding, '') = sfEmpty);
  AssertEquals('empty answer class name', 'empty', StepFailureName(sfEmpty));
  Reason := StepFailureReason(sfEmpty, '', '');
  AssertEquals('empty answer reason',
    'the model answer is empty: the step returned no result', Reason);

  { A tool error text became the final answer of the step (including a leading
    newline/spaces). }
  AssertTrue('ERROR: in the answer - sfError',
    ClassifyStepResult(True, 'ERROR: no access', '') = sfError);
  AssertTrue('ERROR: after spaces - sfError',
    ClassifyStepResult(True, ' ' + LineEnding + 'ERROR: no access', '') = sfError);
  AssertTrue('ERROR: not at the start - normal result',
    ClassifyStepResult(True, 'the tool returned ERROR: but the step went on', '') = sfNone);
  AssertEquals('error class name', 'error', StepFailureName(sfError));
  Reason := StepFailureReason(sfError, 'ERROR: no access', '');
  AssertEquals('tool error reason',
    'the step failed with a tool error: ERROR: no access', Reason);

  { Priority: with RunTurn=False the answer text does not matter. }
  AssertTrue('a failed turn outweighs the text',
    ClassifyStepResult(False, 'ERROR: something', 'no network') = sfTurn);
end;

{ Step retry: the prompt of the second attempt contains the failure reason and
  the requirement to eliminate it instead of repeating the failed action; an
  empty (blank) reason adds nothing - the first attempt equals BuildStepPrompt.
  A long reason is truncated so that a "sheet" of an answer does not bloat the
  system prompt of every next attempt. }
procedure TPlannerTests.TestStepPromptWithFixHint;
const
  TASK = 'task';
  PLAN = '1. [in_progress] step';
  DESC = 'step';
var
  Base, SP, Hint: string;
begin
  Base := BuildStepPrompt(TASK, PLAN, DESC);
  AssertEquals('no reason - same as BuildStepPrompt', Base,
    StepPrompt(TASK, PLAN, DESC, ''));
  AssertEquals('a blank reason is ignored', Base,
    StepPrompt(TASK, PLAN, DESC, '  ' + LineEnding));
  AssertEquals('a tab instead of a reason is ignored', Base,
    StepPrompt(TASK, PLAN, DESC, #9));

  { The reason of the previous attempt goes into the retry prompt together with
    the requirement to fix the situation and the former step text. }
  Hint := 'the turn failed: no network';
  SP := StepPrompt(TASK, PLAN, DESC, Hint);
  AssertEquals('the former prompt comes first', 1, Pos(Base, SP));
  AssertTrue('reason of the previous attempt', Pos(Hint, SP) > 0);
  AssertTrue('requirement to fix it',
    Pos('Eliminate the cause of the failure', SP) > 0);
  AssertTrue('no repeating the action', Pos('Do not repeat', SP) > 0);

  { Truncation: a 900-byte answer does not go into the prompt as a whole. }
  Hint := StringOfChar('x', 900);
  SP := StepPrompt(TASK, PLAN, DESC, Hint);
  AssertTrue('the beginning of the reason is kept',
    Pos(StringOfChar('x', PLAN_STEP_RESULT_MAX), SP) > 0);
  AssertEquals('the sheet did not get in whole', 0, Pos(Hint, SP));
  AssertTrue('truncation marker', Pos('…', SP) > 0);
end;

{ Retry chain: the class of the abnormal result -> the reason
  (StepFailureReason) -> the prompt of the next attempt (StepPrompt). All three
  abnormal classes are checked: a failed turn, an empty answer and a tool error
  text. }
procedure TPlannerTests.TestStepRetryHintChain;
var
  Kind: TStepFailure;
  Reason, SP: string;
begin
  { The turn failed: the reason is the provider Err. }
  Kind := ClassifyStepResult(False, '', 'HTTP 500');
  AssertTrue('failed turn', Kind = sfTurn);
  Reason := StepFailureReason(Kind, '', 'HTTP 500');
  SP := StepPrompt('task', '1. [failed] step', 'step', Reason);
  AssertTrue('turn reason in the retry prompt', Pos('HTTP 500', SP) > 0);

  { An empty answer after a successful turn is a reason to retry too. }
  Kind := ClassifyStepResult(True, '  ' + LineEnding, '');
  AssertTrue('empty answer', Kind = sfEmpty);
  Reason := StepFailureReason(Kind, '  ' + LineEnding, '');
  SP := StepPrompt('task', '1. [failed] step', 'step', Reason);
  AssertTrue('empty answer reason in the prompt', Pos('empty', SP) > 0);

  { A tool error became the final answer of the step. }
  Kind := ClassifyStepResult(True, 'ERROR: no access', '');
  AssertTrue('tool error', Kind = sfError);
  Reason := StepFailureReason(Kind, 'ERROR: no access', '');
  SP := StepPrompt('task', '1. [failed] step', 'step', Reason);
  AssertTrue('tool error text in the prompt',
    Pos('ERROR: no access', SP) > 0);

  { A normal result needs no retry: no reason, the prompt is the first attempt,
    the reason of the previous attempt is reset by RunPlannedTurn (FixHint). }
  Kind := ClassifyStepResult(True, 'done', '');
  AssertEquals('success - no reason', '', StepFailureReason(Kind, 'done', ''));
  AssertEquals('after success the prompt is the usual one',
    BuildStepPrompt('task', '1. [done] step', 'step'),
    StepPrompt('task', '1. [done] step', 'step', ''));
end;

{ Step retry policy: the attempt limit is 1 + PlanStepFixAttempts (the first
  attempt plus the fix retries); 0 means no retries, a negative value from the
  INI file does not cancel the first attempt. By default there is one retry. }
procedure TPlannerTests.TestStepMaxTries;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  AssertEquals('one retry by default', 1, Cfg.PlanStepFixAttempts);
  AssertEquals('two attempts by default', 2, StepMaxTries(Cfg));
  Cfg.PlanStepFixAttempts := 0;
  AssertEquals('no retries - one attempt', 1, StepMaxTries(Cfg));
  Cfg.PlanStepFixAttempts := 3;
  AssertEquals('three retries - four attempts', 4, StepMaxTries(Cfg));
  Cfg.PlanStepFixAttempts := -5;
  AssertEquals('negative - still one attempt', 1,
    StepMaxTries(Cfg));
end;

{ Session names of the step attempts: the first attempt keeps the former name
  <base>_step_<id>, the retries get the _try<N> suffix, so the attempts do not
  overwrite each other. Such files stay auxiliary sessions and are not listed
  among the main ones. }
procedure TPlannerTests.TestStepRetrySessionIds;
begin
  AssertEquals('first attempt - the step name', StepSessionId('base', 's1'),
    StepSessionIdTry('base', 's1', 1));
  AssertEquals('zero number - as the first one', 'base_step_s1',
    StepSessionIdTry('base', 's1', 0));
  AssertEquals('second attempt', 'base_step_s1_try2',
    StepSessionIdTry('base', 's1', 2));
  AssertEquals('third attempt', 'base_step_s1_try3',
    StepSessionIdTry('base', 's1', 3));
  AssertTrue('the retry session is auxiliary',
    IsAuxSessionFile('base_step_s1_try2.json'));
  AssertTrue('the step session is auxiliary',
    IsAuxSessionFile('base_step_s1.json'));
  AssertFalse('the main session is not auxiliary',
    IsAuxSessionFile('base.json'));
end;

{ Handling of a step failure at the plan level - this is what the retry loop of
  RunPlannedTurn rests on:
  - a failed step stops being pending (the next step comes from NextPending,
    and when no pending steps are left the loop ends);
  - a repeated entry is allowed: failed -> in_progress is set before every new
    attempt;
  - a step removed by revise_plan inside the sub-loop has nothing to retry:
    FindStep < 0 and SetStatus returns False (the loop breaks on that sign);
  - a failed step cannot be skipped (the pending rule), it is removed or the
    plan is reordered. }
procedure TPlannerTests.TestFailedStepHandling;
var
  P: TPlan;
  O: TToolOutcome;
begin
  P := FPlanner.Plan;
  AssertTrue('s1 taken into work', P.SetStatus('s1', psInProgress, ''));
  AssertTrue('s1 failed',
    P.SetStatus('s1', psFailed, 'the turn failed: no network'));
  AssertEquals('next pending is s2', 's2', P.Steps[P.NextPending].Id);
  AssertEquals('the failed step is not pending', 1, P.CountByStatus(psFailed));
  AssertEquals('pending left: s2..s4', 3, P.CountByStatus(psPending));

  { Retry: the attempt loop puts the step back into work. }
  AssertTrue('retry allowed', P.SetStatus('s1', psInProgress, ''));
  AssertEquals('retry status', Ord(psInProgress), Ord(P.Steps[0].Status));

  { A failed step is not skipped - like any non-pending step. }
  AssertTrue('failed again', P.SetStatus('s1', psFailed, 'reason'));
  O := InvokeRevise('{"ops":[{"op":"skip","id":"s1"}]}');
  AssertTrue('skip of a failed step is an error', O.IsError);
  AssertTrue('message about pending', Pos('pending', O.Text) > 0);
  AssertEquals('status unchanged', Ord(psFailed), Ord(P.Steps[0].Status));

  { The step was removed from the plan inside the sub-loop (revise_plan):
    there is nothing to retry. }
  O := InvokeRevise('{"ops":[{"op":"remove","id":"s1"}]}');
  AssertFalse('remove without an error: ' + O.Text, O.IsError);
  AssertTrue('the step is not in the plan', P.FindStep('s1') < 0);
  AssertFalse('SetStatus of a removed step - False (the break sign)',
    P.SetStatus('s1', psInProgress, ''));

  { The plan reached a terminal state: the turn counts as successful (no
    pending/in_progress), the loop takes no new steps. }
  AssertTrue('s2 done', P.SetStatus('s2', psDone, 'done'));
  AssertTrue('s3 skipped', P.SetStatus('s3', psSkipped, 'not needed'));
  AssertTrue('s4 failed', P.SetStatus('s4', psFailed, 'reason'));
  AssertEquals('no pending', 0, P.CountByStatus(psPending));
  AssertEquals('no in_progress', 0, P.CountByStatus(psInProgress));
  AssertTrue('no next step', P.NextPending < 0);
end;

initialization
  RegisterTest(TPlannerTests);

end.
