unit test_plan;
{ Tests of the plan model (mirmid.plan): JSON (de)serialisation, validation,
  step operations, parsing the model answer, rendering, report, prompts. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TPlanTests = class(TTestCase)
  published
    procedure TestStatusNames;
    procedure TestJsonRoundTrip;
    procedure TestFromJSONNoSteps;
    procedure TestFromJSONEmptySteps;
    procedure TestFromJSONEmptyDescription;
    procedure TestFromJSONDuplicateIds;
    procedure TestFromJSONUnknownStatus;
    procedure TestFromJSONAutoIds;
    procedure TestAddStep;
    procedure TestFindStep;
    procedure TestRemoveStep;
    procedure TestReorder;
    procedure TestSetStatus;
    procedure TestNextPending;
    procedure TestCountByStatus;
    procedure TestExtractJSONBlockFenced;
    procedure TestExtractJSONBlockSurrounding;
    procedure TestExtractJSONBlockMissing;
    procedure TestParsePlanFromTextValid;
    procedure TestParsePlanFromTextInvalid;
    procedure TestRender;
    procedure TestSummary;
    procedure TestBuildPlanReport;
    procedure TestPrompts;
    procedure TestTruncateZero;
    procedure TestTruncateN;
  end;

implementation

uses
  SysUtils, fpjson, mirmid.plan;

procedure TPlanTests.TestStatusNames;
var
  St: TPlanStepStatus;
begin
  AssertEquals('pending', 'pending', PlanStatusName(psPending));
  AssertEquals('in_progress', 'in_progress', PlanStatusName(psInProgress));
  AssertEquals('done', 'done', PlanStatusName(psDone));
  AssertEquals('failed', 'failed', PlanStatusName(psFailed));
  AssertEquals('skipped', 'skipped', PlanStatusName(psSkipped));
  AssertTrue('done by name', PlanStatusFromName('done', St));
  AssertEquals('done', Ord(psDone), Ord(St));
  AssertTrue('case does not matter', PlanStatusFromName('IN_PROGRESS', St));
  AssertEquals('in_progress', Ord(psInProgress), Ord(St));
  AssertFalse('unknown name', PlanStatusFromName('weird', St));
end;

procedure TPlanTests.TestJsonRoundTrip;
var
  P, P2: TPlan;
  O: TJSONObject;
  Err: string;
begin
  P := TPlan.Create;
  try
    P.AddStep('read the file');
    P.AddStep('run the command');
    P.AddStep('write the report');
    P.SetStatus('s1', psDone, 'file read');
    P.SetStatus('s2', psFailed, 'error 127');
    P.SetStatus('s3', psSkipped, '');
    O := P.ToJSON;
    try
      P2 := TPlan.FromJSON(O, Err);
      AssertTrue('plan parsed', P2 <> nil);
      AssertEquals('error is empty', '', Err);
      AssertEquals('step count', 3, Length(P2.Steps));
      AssertEquals('id 1', 's1', P2.Steps[0].Id);
      AssertEquals('description 1', 'read the file', P2.Steps[0].Description);
      AssertEquals('status 1', Ord(psDone), Ord(P2.Steps[0].Status));
      AssertEquals('result 1', 'file read', P2.Steps[0].Result);
      AssertEquals('status 2', Ord(psFailed), Ord(P2.Steps[1].Status));
      AssertEquals('result 2', 'error 127', P2.Steps[1].Result);
      AssertEquals('status 3', Ord(psSkipped), Ord(P2.Steps[2].Status));
      AssertEquals('result 3 is empty', '', P2.Steps[2].Result);
    finally
      P2.Free;
      O.Free;
    end;
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestFromJSONNoSteps;
var
  O: TJSONObject;
  Err: string;
  P: TPlan;
begin
  O := TJSONObject.Create;
  try
    O.Add('foo', 'bar');
    P := TPlan.FromJSON(O, Err);
    AssertNull('no steps - nil', P);
    AssertTrue('error text', Err <> '');
  finally
    O.Free;
  end;
end;

procedure TPlanTests.TestFromJSONEmptySteps;
var
  O: TJSONObject;
  Err: string;
  P: TPlan;
begin
  O := TJSONObject.Create;
  try
    O.Add('steps', TJSONArray.Create);
    P := TPlan.FromJSON(O, Err);
    AssertNull('empty steps - nil', P);
    AssertTrue('error text', Err <> '');
  finally
    O.Free;
  end;
end;

procedure TPlanTests.TestFromJSONEmptyDescription;
var
  O, S: TJSONObject;
  A: TJSONArray;
  Err: string;
  P: TPlan;
begin
  O := TJSONObject.Create;
  try
    A := TJSONArray.Create;
    S := TJSONObject.Create;
    S.Add('description', '');
    A.Add(S);
    O.Add('steps', A);
    P := TPlan.FromJSON(O, Err);
    AssertNull('empty description - nil', P);
    AssertTrue('error text', Err <> '');
  finally
    O.Free;
  end;
end;

procedure TPlanTests.TestFromJSONDuplicateIds;
var
  O, S1, S2: TJSONObject;
  A: TJSONArray;
  Err: string;
  P: TPlan;
begin
  O := TJSONObject.Create;
  try
    A := TJSONArray.Create;
    S1 := TJSONObject.Create;
    S1.Add('id', 'x');
    S1.Add('description', 'one');
    S2 := TJSONObject.Create;
    S2.Add('id', 'x');
    S2.Add('description', 'two');
    A.Add(S1);
    A.Add(S2);
    O.Add('steps', A);
    P := TPlan.FromJSON(O, Err);
    AssertNull('duplicate ids - nil', P);
    AssertTrue('error text', Err <> '');
  finally
    O.Free;
  end;
end;

procedure TPlanTests.TestFromJSONUnknownStatus;
var
  O, S: TJSONObject;
  A: TJSONArray;
  Err: string;
  P: TPlan;
begin
  O := TJSONObject.Create;
  try
    A := TJSONArray.Create;
    S := TJSONObject.Create;
    S.Add('description', 'step');
    S.Add('status', 'weird');
    A.Add(S);
    O.Add('steps', A);
    P := TPlan.FromJSON(O, Err);
    AssertNull('unknown status - nil', P);
    AssertTrue('error text', Err <> '');
  finally
    O.Free;
  end;
end;

procedure TPlanTests.TestFromJSONAutoIds;
var
  O, S1, S2, S3: TJSONObject;
  A: TJSONArray;
  Err: string;
  P: TPlan;
begin
  O := TJSONObject.Create;
  try
    A := TJSONArray.Create;
    S1 := TJSONObject.Create;
    S1.Add('description', 'first');
    S2 := TJSONObject.Create;
    S2.Add('description', 'second');
    S3 := TJSONObject.Create;
    S3.Add('id', 'custom');
    S3.Add('description', 'third');
    A.Add(S1);
    A.Add(S2);
    A.Add(S3);
    O.Add('steps', A);
    P := TPlan.FromJSON(O, Err);
    AssertTrue('plan parsed', P <> nil);
    try
      AssertEquals('error is empty', '', Err);
      AssertEquals('step count', 3, Length(P.Steps));
      AssertEquals('auto id 1', 's1', P.Steps[0].Id);
      AssertEquals('auto id 2', 's2', P.Steps[1].Id);
      AssertEquals('explicit id', 'custom', P.Steps[2].Id);
      AssertEquals('default status', Ord(psPending), Ord(P.Steps[0].Status));
      AssertEquals('default result', '', P.Steps[0].Result);
    finally
      P.Free;
    end;
  finally
    O.Free;
  end;
end;

procedure TPlanTests.TestAddStep;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    AssertEquals('first index', 0, P.AddStep('first'));
    AssertEquals('second index', 1, P.AddStep('second'));
    AssertEquals('step count', 2, Length(P.Steps));
    AssertEquals('auto id 1', 's1', P.Steps[0].Id);
    AssertEquals('auto id 2', 's2', P.Steps[1].Id);
    AssertEquals('status', Ord(psPending), Ord(P.Steps[0].Status));
    AssertEquals('description', 'first', P.Steps[0].Description);
    AssertEquals('result is empty', '', P.Steps[0].Result);
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestFindStep;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    AssertEquals('finds s1', 0, P.FindStep('s1'));
    AssertEquals('finds s2', 1, P.FindStep('s2'));
    AssertEquals('no s3', -1, P.FindStep('s3'));
    AssertEquals('empty id', -1, P.FindStep(''));
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestRemoveStep;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.AddStep('c');
    AssertTrue('removes s2', P.RemoveStep('s2'));
    AssertEquals('two left', 2, Length(P.Steps));
    AssertEquals('order 1', 's1', P.Steps[0].Id);
    AssertEquals('order 2', 's3', P.Steps[1].Id);
    AssertFalse('repeated removal', P.RemoveStep('s2'));
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestReorder;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.AddStep('c');
    AssertTrue('reorder', P.Reorder(['s3', 's1', 's2']));
    AssertEquals('new order 1', 's3', P.Steps[0].Id);
    AssertEquals('new order 2', 's1', P.Steps[1].Id);
    AssertEquals('new order 3', 's2', P.Steps[2].Id);
    AssertFalse('fewer ids', P.Reorder(['s1', 's2']));
    AssertFalse('duplicate ids', P.Reorder(['s1', 's1', 's2']));
    AssertFalse('foreign id', P.Reorder(['s1', 's2', 's9']));
    AssertEquals('plan unchanged', 's3', P.Steps[0].Id);
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestSetStatus;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('a');
    AssertTrue('to in progress', P.SetStatus('s1', psInProgress, ''));
    AssertEquals('in progress status', Ord(psInProgress), Ord(P.Steps[0].Status));
    AssertTrue('to done with a result', P.SetStatus('s1', psDone, 'done'));
    AssertEquals('done status', Ord(psDone), Ord(P.Steps[0].Status));
    AssertEquals('result', 'done', P.Steps[0].Result);
    AssertFalse('no such step', P.SetStatus('s9', psDone, ''));
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestNextPending;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.AddStep('c');
    AssertEquals('first pending', 0, P.NextPending);
    P.SetStatus('s1', psDone, '');
    AssertEquals('second pending', 1, P.NextPending);
    P.SetStatus('s2', psFailed, '');
    P.SetStatus('s3', psSkipped, '');
    AssertEquals('no pending', -1, P.NextPending);
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestCountByStatus;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.AddStep('c');
    P.AddStep('d');
    P.SetStatus('s1', psDone, '');
    P.SetStatus('s2', psFailed, '');
    P.SetStatus('s3', psSkipped, '');
    AssertEquals('done', 1, P.CountByStatus(psDone));
    AssertEquals('failed', 1, P.CountByStatus(psFailed));
    AssertEquals('skipped', 1, P.CountByStatus(psSkipped));
    AssertEquals('pending', 1, P.CountByStatus(psPending));
    AssertEquals('in_progress', 0, P.CountByStatus(psInProgress));
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestExtractJSONBlockFenced;
var
  S: string;
begin
  S := 'Here is the plan:' + LineEnding +
       '```json' + LineEnding +
       '{"steps":[{"description":"a"},{"description":"b"}]}' + LineEnding +
       '```' + LineEnding +
       'Done.';
  AssertEquals('block from the fence',
    '{"steps":[{"description":"a"},{"description":"b"}]}',
    ExtractJSONBlock(S));
end;

procedure TPlanTests.TestExtractJSONBlockSurrounding;
var
  S: string;
begin
  S := 'Let us look at the task. Plan: {"steps": [{"description": "x"}]} - more text follows.';
  AssertEquals('block inside the text',
    '{"steps": [{"description": "x"}]}',
    ExtractJSONBlock(S));
end;

procedure TPlanTests.TestExtractJSONBlockMissing;
begin
  AssertEquals('no json', '', ExtractJSONBlock('just plain text without json'));
  AssertEquals('empty string', '', ExtractJSONBlock(''));
  AssertEquals('unclosed block', '', ExtractJSONBlock('text {unclosed'));
end;

procedure TPlanTests.TestParsePlanFromTextValid;
var
  S: string;
  Err: string;
  P: TPlan;
begin
  S := '```json' + LineEnding +
       '{"steps":[{"description":"do it"},{"description":"check it"}]}' + LineEnding +
       '```';
  P := ParsePlanFromText(S, Err);
  AssertTrue('plan parsed', P <> nil);
  try
    AssertEquals('error is empty', '', Err);
    AssertEquals('step count', 2, Length(P.Steps));
    AssertEquals('auto id', 's1', P.Steps[0].Id);
    AssertEquals('description', 'do it', P.Steps[0].Description);
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestParsePlanFromTextInvalid;
var
  Err: string;
  P: TPlan;
begin
  P := ParsePlanFromText('no json', Err);
  AssertNull('no json - nil', P);
  AssertTrue('error 1', Err <> '');
  P := ParsePlanFromText('{"steps": []}', Err);
  AssertNull('empty plan - nil', P);
  AssertTrue('error 2', Err <> '');
  P := ParsePlanFromText('{"steps": "not an array"}', Err);
  AssertNull('steps is not an array - nil', P);
  AssertTrue('error 3', Err <> '');
end;

procedure TPlanTests.TestRender;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('first');
    P.AddStep('second');
    P.SetStatus('s1', psDone, 'done');
    P.SetStatus('s2', psInProgress, '');
    AssertEquals('render',
      '1. [done] first — done' + LineEnding + '2. [in_progress] second',
      P.Render);
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestSummary;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.AddStep('c');
    P.AddStep('d');
    P.AddStep('e');
    P.SetStatus('s1', psDone, '');
    P.SetStatus('s2', psDone, '');
    P.SetStatus('s3', psDone, '');
    P.SetStatus('s4', psFailed, '');
    P.SetStatus('s5', psSkipped, '');
    AssertEquals('mixed summary', '3/5 done, 1 failed, 1 skipped', P.Summary);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.SetStatus('s1', psDone, '');
    P.SetStatus('s2', psDone, '');
    AssertEquals('done only', '2/2 done', P.Summary);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    AssertEquals('empty plan', '0/0 done', P.Summary);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.SetStatus('s1', psFailed, '');
    P.SetStatus('s2', psFailed, '');
    AssertEquals('no pluralisation', '0/2 done, 2 failed', P.Summary);
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestBuildPlanReport;
var
  P: TPlan;
  Expected: string;
begin
  P := TPlan.Create;
  try
    P.AddStep('do it');
    P.SetStatus('s1', psDone, 'done');
    Expected := 'Task: task' + LineEnding + LineEnding +
                'Plan:' + LineEnding +
                P.Render + LineEnding + LineEnding +
                'Summary: ' + P.Summary;
    AssertEquals('report', Expected, BuildPlanReport(P, 'task'));
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestPrompts;
var
  SP: string;
begin
  AssertTrue('planner prompt exists', Length(PLANNER_SYSTEM_PROMPT) > 0);
  AssertTrue('JSON in the planner prompt', Pos('{"steps"', PLANNER_SYSTEM_PROMPT) > 0);
  SP := BuildStepPrompt('task', '1. [pending] step', 'step');
  AssertTrue('task in the step prompt', Pos('task', SP) > 0);
  AssertTrue('plan in the step prompt', Pos('1. [pending] step', SP) > 0);
  AssertTrue('goal in the step prompt', Pos('Goal of the current step: step', SP) > 0);
  AssertTrue('reporter prompt exists', Length(REPORT_SYSTEM_PROMPT) > 0);
  AssertTrue('analyst prompt exists', Length(PLANNER_ANALYSIS_PROMPT) > 0);
  AssertTrue('analyst reads files', Pos('file', PLANNER_ANALYSIS_PROMPT) > 0);
  SP := BuildPlanPrompt('my task', 'analysis: everything is ready');
  AssertTrue('task in the plan request', Pos('my task', SP) > 0);
  AssertTrue('analysis in the plan request', Pos('analysis: everything is ready', SP) > 0);
  AssertTrue('JSON in the plan request', Pos('{"steps"', SP) > 0);
  SP := BuildPlanPrompt('my task', '');
  AssertTrue('empty analysis does not break the request', Pos('my task', SP) > 0);
end;
{ Truncate(0) does not limit the plan: every step is kept. }
procedure TPlanTests.TestTruncateZero;
var
  P: TPlan;
  Removed: Integer;
begin
  P := TPlan.Create;
  try
    P.AddStep('step 1');
    P.AddStep('step 2');
    P.AddStep('step 3');
    P.AddStep('step 4');
    P.AddStep('step 5');
    Removed := P.Truncate(0);
    AssertEquals('nothing removed', 0, Removed);
    AssertEquals('five steps', 5, Length(P.Steps));
    AssertEquals('first step', 'step 1', P.Steps[0].Description);
    AssertEquals('last step', 'step 5', P.Steps[4].Description);
  finally
    P.Free;
  end;
end;
{ Truncate(N) cuts the plan down to N steps, dropping the extra ones. }
procedure TPlanTests.TestTruncateN;
var
  P: TPlan;
  Removed: Integer;
begin
  P := TPlan.Create;
  try
    P.AddStep('step 1');
    P.AddStep('step 2');
    P.AddStep('step 3');
    P.AddStep('step 4');
    P.AddStep('step 5');
    Removed := P.Truncate(3);
    AssertEquals('two removed', 2, Removed);
    AssertEquals('three left', 3, Length(P.Steps));
    AssertEquals('first step', 'step 1', P.Steps[0].Description);
    AssertEquals('second step', 'step 2', P.Steps[1].Description);
    AssertEquals('third step', 'step 3', P.Steps[2].Description);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    Removed := P.Truncate(5);
    AssertEquals('more than N - nothing removed', 0, Removed);
    AssertEquals('both steps still there', 2, Length(P.Steps));
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.AddStep('c');
    Removed := P.Truncate(1);
    AssertEquals('two removed', 2, Removed);
    AssertEquals('one left', 1, Length(P.Steps));
    AssertEquals('first step', 'a', P.Steps[0].Description);
  finally
    P.Free;
  end;
end;

initialization
  RegisterTest(TPlanTests);

end.
