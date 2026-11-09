unit mirmid.plan;
{ Plan data model for the planning mode: steps with statuses, JSON
  (de)serialisation, parsing of the model answer, human-readable rendering,
  deterministic report and planner prompts.
  Dependencies: SysUtils, fpjson, mirmid.types (no network layer). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, mirmid.types;

type
  { Status of a plan step. }
  TPlanStepStatus = (psPending, psInProgress, psDone, psFailed, psSkipped);

  { One plan step. }
  TPlanStep = record
    Id: string;
    Description: string;
    Status: TPlanStepStatus;
    Result: string;
  end;

  { List of plan steps (FPC does not allow declaring a class field/property as
    an open array directly - a named type is needed). }
  TPlanSteps = array of TPlanStep;

  { Plan: an ordered list of steps. }
  TPlan = class
  private
    FSteps: TPlanSteps;
  public
    constructor Create;
    property Steps: TPlanSteps read FSteps;
    { Adds a step with the auto id sN (N = number of steps + 1) and the status
      psPending; returns the index of the new step. }
    function AddStep(const ADesc: string): Integer;
    { Index of the step by id, or -1. }
    function FindStep(const AId: string): Integer;
    { Removes the step by id; False if there is no such step. }
    function RemoveStep(const AId: string): Boolean;
    { New order of the steps by id; False if the set of ids does not match the
      plan steps (the plan is left unchanged). }
    function Reorder(const AOrder: array of string): Boolean;
    { Sets the status and the result of a step; False if there is no such step. }
    function SetStatus(const AId: string; AStatus: TPlanStepStatus; const AResult: string): Boolean;
    { Index of the first step with the status psPending, or -1. }
    function NextPending: Integer;
    { Number of steps with the given status. }
    function CountByStatus(AStatus: TPlanStepStatus): Integer;
    { Truncates the plan to AMax steps (drops the tail); returns the number of
      removed steps (0 if AMax <= 0 or the plan is already shorter than AMax). }
    function Truncate(AMax: Integer): Integer;
    { JSON: an object with the steps array; every step has id, description,
      status, result. }
    function ToJSON: TJSONObject;
    { Parses back; nil if invalid (Err holds the error text). }
    class function FromJSON(D: TJSONData; out Err: string): TPlan;
    { Human-readable plan: one line per step
      "N. [status] description - result" (the result only if not empty). }
    function Render: string;
    { Summary: "3/5 done, 1 failed, 1 skipped" (only non-zero categories,
      order: done / failed / skipped). }
    function Summary: string;
  end;

{ Status name in JSON notation: pending, in_progress, done, failed, skipped. }
function PlanStatusName(S: TPlanStepStatus): string;
{ Status by name (case-insensitive); False if the name is unknown. }
function PlanStatusFromName(const S: string; out St: TPlanStepStatus): Boolean;

{ The first JSON object in the text (also inside a ```json fence and with
  surrounding text); an empty string if none is found. }
function ExtractJSONBlock(const S: string): string;
{ Plan from the model answer: ExtractJSONBlock + JSON parsing + FromJSON;
  nil on error (Err holds the error text). }
function ParsePlanFromText(const S: string; out Err: string): TPlan;

{ Deterministic report: task, rendered plan, summary. }
function BuildPlanReport(const Plan: TPlan; const Task: string): string;

{ Analyst prompt: study the task and its environment before building a plan
  (read-only) and return a structured analysis; do not build the plan itself.
  The tools stay available according to the session permissions - the no-change
  rule comes from the prompt, not from disabling tools. }
const
  PLANNER_ANALYSIS_PROMPT =
    'You are the planner analyst. Before building a plan, study the task and ' +
    'its environment and return a preliminary analysis. Work read-only: list ' +
    'directories, read files, search contents and, if allowed, run commands ' +
    'for inspection only (for example git status, git log, git diff); do not ' +
    'change anything. If the task refers to a file (for example a plan), ' +
    'be sure to read it. Determine: 1) what the task is about and what is ' +
    'actually required; 2) what has already been done and which files, ' +
    'entities and constraints are relevant to the task; 3) which facts the ' +
    'plan needs and what the risks are; 4) what exactly has to be done. Rely ' +
    'only on facts from the tools and do not invent anything. Do not produce ' +
    'a numbered plan of steps - the planner does that. Reply in the same ' +
    'language the user writes in, structured and to the point.';

{ Planner prompt: break the task into atomic steps and return only the JSON
  array steps (the description of each step) without extra text. }
const
  PLANNER_SYSTEM_PROMPT =
    'You are the planner. Break the task into atomic steps: every step is one ' +
    'concrete action (one tool call or one short command) that can be done ' +
    'without further deliberation. List the steps in execution order. Rely on ' +
    'the provided preliminary task analysis and do not contradict its facts. ' +
    'Return ONLY JSON without explanations, without markdown fences and ' +
    'without extra text: {"steps": [{"description": "..."}]}. ' +
    'The description is a short description of the step (up to 100 ' +
    'characters); do not add other fields.';

{ Plan phase request: the task and the results of the preliminary analysis
  (may be empty). The model must return only the JSON plan. }
function BuildPlanPrompt(const Task, Analysis: string): string;

{ Step prompt: the overall task, the current plan (rendered), the goal of the
  current step, and the instruction to perform the step and return a short
  result. }
function BuildStepPrompt(const Task, PlanRender, StepDesc: string): string;

{ Reporter prompt: the final answer based on the state of the plan (what is
  done, what is skipped, what failed). }
const
  REPORT_SYSTEM_PROMPT =
    'You are the reporter. Based on the state of the plan, give the final ' +
    'answer on the task: what is done, what is skipped, what failed and what ' +
    'the outcome is. Reply briefly and to the point, in the same language the ' +
    'user writes in, without describing the process.';

implementation

uses
  jsonparser;

function PlanStatusName(S: TPlanStepStatus): string;
begin
  case S of
    psPending:    Result := 'pending';
    psInProgress: Result := 'in_progress';
    psDone:       Result := 'done';
    psFailed:     Result := 'failed';
    psSkipped:    Result := 'skipped';
  else
    Result := 'pending';
  end;
end;

function PlanStatusFromName(const S: string; out St: TPlanStepStatus): Boolean;
var
  V: string;
begin
  Result := False;
  V := LowerCase(Trim(S));
  case V of
    'pending':     St := psPending;
    'in_progress': St := psInProgress;
    'done':        St := psDone;
    'failed':      St := psFailed;
    'skipped':     St := psSkipped;
  else
    Exit;
  end;
  Result := True;
end;

constructor TPlan.Create;
begin
  inherited Create;
  SetLength(FSteps, 0);
end;

function TPlan.AddStep(const ADesc: string): Integer;
begin
  SetLength(FSteps, Length(FSteps) + 1);
  FSteps[Length(FSteps) - 1].Id := 's' + IntToStr(Length(FSteps));
  FSteps[Length(FSteps) - 1].Description := ADesc;
  FSteps[Length(FSteps) - 1].Status := psPending;
  FSteps[Length(FSteps) - 1].Result := '';
  Result := Length(FSteps) - 1;
end;

function TPlan.FindStep(const AId: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FSteps) do
    if FSteps[I].Id = AId then
    begin
      Result := I;
      Exit;
    end;
end;

function TPlan.RemoveStep(const AId: string): Boolean;
var
  I, K, Idx: Integer;
  Tmp: TPlanSteps;
begin
  Idx := FindStep(AId);
  if Idx < 0 then
  begin
    Result := False;
    Exit;
  end;
  SetLength(Tmp, Length(FSteps) - 1);
  K := 0;
  for I := 0 to High(FSteps) do
    if I <> Idx then
    begin
      Tmp[K] := FSteps[I];
      Inc(K);
    end;
  FSteps := Tmp;
  Result := True;
end;

function TPlan.Reorder(const AOrder: array of string): Boolean;
var
  I, J, K: Integer;
  Tmp: TPlanSteps;
  Found: array of Boolean;
begin
  Result := False;
  if Length(AOrder) <> Length(FSteps) then
    Exit;
  SetLength(Found, Length(FSteps));
  for I := 0 to High(Found) do
    Found[I] := False;
  { The set of ids must match the plan steps: no duplicates and no foreign ids. }
  for I := 0 to High(AOrder) do
  begin
    J := FindStep(AOrder[I]);
    if (J < 0) or Found[J] then
      Exit;
    Found[J] := True;
  end;
  SetLength(Tmp, Length(FSteps));
  K := 0;
  for I := 0 to High(AOrder) do
  begin
    Tmp[K] := FSteps[FindStep(AOrder[I])];
    Inc(K);
  end;
  FSteps := Tmp;
  Result := True;
end;

function TPlan.SetStatus(const AId: string; AStatus: TPlanStepStatus; const AResult: string): Boolean;
var
  I: Integer;
begin
  I := FindStep(AId);
  if I < 0 then
  begin
    Result := False;
    Exit;
  end;
  FSteps[I].Status := AStatus;
  FSteps[I].Result := AResult;
  Result := True;
end;

function TPlan.NextPending: Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FSteps) do
    if FSteps[I].Status = psPending then
    begin
      Result := I;
      Exit;
    end;
end;

function TPlan.CountByStatus(AStatus: TPlanStepStatus): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FSteps) do
    if FSteps[I].Status = AStatus then
      Inc(Result);
end;

function TPlan.Truncate(AMax: Integer): Integer;
begin
  Result := 0;
  if (AMax > 0) and (Length(FSteps) > AMax) then
  begin
    Result := Length(FSteps) - AMax;
    SetLength(FSteps, AMax);
  end;
end;

function TPlan.ToJSON: TJSONObject;
var
  A: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  Result := TJSONObject.Create;
  A := TJSONArray.Create;
  for I := 0 to High(FSteps) do
  begin
    O := TJSONObject.Create;
    O.Add('id', FSteps[I].Id);
    O.Add('description', FSteps[I].Description);
    O.Add('status', PlanStatusName(FSteps[I].Status));
    O.Add('result', FSteps[I].Result);
    A.Add(O);
  end;
  Result.Add('steps', A);
end;

{ String by the key of a JSON object; '' - the key is missing or the value is null. }
function JStrLocal(O: TJSONObject; const Key: string): string;
var
  X: TJSONData;
begin
  Result := '';
  X := nil;
  try
    X := O.FindPath(Key);
  except
    X := nil;
  end;
  if (X = nil) or (X is TJSONNull) then
    Exit;
  Result := X.AsString;
end;

class function TPlan.FromJSON(D: TJSONData; out Err: string): TPlan;
var
  O, StepO: TJSONObject;
  A: TJSONArray;
  Item: TJSONData;
  Step: TPlanStep;
  Id, Desc, StName, Res: string;
  St: TPlanStepStatus;
  I: Integer;
  P: TPlan;
begin
  Result := nil;
  Err := '';
  if (D = nil) or not (D is TJSONObject) then
  begin
    Err := 'the plan must be a JSON object';
    Exit;
  end;
  O := TJSONObject(D);
  Item := nil;
  try
    Item := O.FindPath('steps');
  except
    Item := nil;
  end;
  if (Item = nil) or not (Item is TJSONArray) then
  begin
    Err := 'no "steps" array';
    Exit;
  end;
  A := TJSONArray(Item);
  if A.Count = 0 then
  begin
    Err := 'empty plan: at least one step is required';
    Exit;
  end;
  P := TPlan.Create;
  try
    for I := 0 to A.Count - 1 do
    begin
      Item := A.Items[I];
      if not (Item is TJSONObject) then
      begin
        Err := 'step ' + IntToStr(I + 1) + ' must be a JSON object';
        P.Free;
        Exit;
      end;
      StepO := TJSONObject(Item);
      Desc := JStrLocal(StepO, 'description');
      if Trim(Desc) = '' then
      begin
        Err := 'step ' + IntToStr(I + 1) + ': empty "description"';
        P.Free;
        Exit;
      end;
      { id is optional: assigned automatically as sN in the order of the steps. }
      Id := JStrLocal(StepO, 'id');
      if Id = '' then
        Id := 's' + IntToStr(I + 1);
      if P.FindStep(Id) >= 0 then
      begin
        Err := 'duplicate step id: ' + Id;
        P.Free;
        Exit;
      end;
      { status is optional: pending by default, an unknown name is an error. }
      StName := JStrLocal(StepO, 'status');
      if StName = '' then
        St := psPending
      else
      begin
        if not PlanStatusFromName(StName, St) then
        begin
          Err := 'step ' + IntToStr(I + 1) + ': unknown status "' + StName + '"';
          P.Free;
          Exit;
        end;
      end;
      { result is optional: an empty string by default. }
      Res := JStrLocal(StepO, 'result');
      Step.Id := Id;
      Step.Description := Desc;
      Step.Status := St;
      Step.Result := Res;
      SetLength(P.FSteps, Length(P.FSteps) + 1);
      P.FSteps[Length(P.FSteps) - 1] := Step;
    end;
    Result := P;
  except
    P.Free;
    raise;
  end;
end;

function ExtractJSONBlock(const S: string): string;
var
  I, Start, Depth: Integer;
  InStr, Esc, Found: Boolean;
  Ch: Char;
  Block: string;
  D: TJSONData;
begin
  Result := '';
  I := 1;
  while (I <= Length(S)) and (Result = '') do
  begin
    if S[I] <> '{' then
    begin
      Inc(I);
      Continue;
    end;
    { Candidate: a brace-balanced block that starts with an opening brace. }
    Start := I;
    Depth := 1;
    InStr := False;
    Esc := False;
    Found := False;
    Inc(I);
    while (I <= Length(S)) and (Depth > 0) do
    begin
      Ch := S[I];
      if InStr then
      begin
        if Esc then
          Esc := False
        else if Ch = '\' then
          Esc := True
        else if Ch = '"' then
          InStr := False;
      end
      else
      begin
        if Ch = '"' then
          InStr := True
        else if Ch = '{' then
          Inc(Depth)
        else if Ch = '}' then
        begin
          Dec(Depth);
          if Depth = 0 then
          begin
            Block := Copy(S, Start, I - Start + 1);
            try
              D := GetJSON(Block);
              D.Free;
              Result := Block;
              Found := True;
            except
              { not JSON - try the next candidate }
            end;
          end;
        end;
      end;
      Inc(I);
    end;
    if not Found then
      I := Start + 1; { the next candidate starts after this opening brace }
  end;
end;

function ParsePlanFromText(const S: string; out Err: string): TPlan;
var
  Block: string;
  D: TJSONData;
begin
  Result := nil;
  Err := '';
  Block := ExtractJSONBlock(S);
  if Block = '' then
  begin
    Err := 'no JSON object found in the text';
    Exit;
  end;
  D := nil;
  try
    D := GetJSON(Block);
  except
    on E: Exception do
    begin
      Err := 'JSON parse error: ' + E.Message;
      Exit;
    end;
  end;
  try
    Result := TPlan.FromJSON(D, Err);
  finally
    D.Free;
  end;
end;

function TPlan.Render: string;
var
  I: Integer;
  L: string;
begin
  Result := '';
  for I := 0 to High(FSteps) do
  begin
    L := IntToStr(I + 1) + '. [' + PlanStatusName(FSteps[I].Status) + '] ' +
         FSteps[I].Description;
    if FSteps[I].Result <> '' then
      L := L + ' — ' + FSteps[I].Result;
    if Result <> '' then
      Result := Result + LineEnding;
    Result := Result + L;
  end;
end;

function TPlan.Summary: string;
var
  Done, Failed, Skipped, Total: Integer;
begin
  Total := Length(FSteps);
  Done := CountByStatus(psDone);
  Failed := CountByStatus(psFailed);
  Skipped := CountByStatus(psSkipped);
  Result := IntToStr(Done) + '/' + IntToStr(Total) + ' done';
  if Failed > 0 then
    Result := Result + ', ' + IntToStr(Failed) + ' failed';
  if Skipped > 0 then
    Result := Result + ', ' + IntToStr(Skipped) + ' skipped';
end;

function BuildPlanReport(const Plan: TPlan; const Task: string): string;
var
  P: TPlan;
begin
  if Plan = nil then
    P := TPlan.Create
  else
    P := Plan;
  try
    Result := 'Task: ' + Task + LineEnding + LineEnding +
              'Plan:' + LineEnding +
              P.Render + LineEnding + LineEnding +
              'Summary: ' + P.Summary;
  finally
    if (P <> nil) and (P <> Plan) then
      P.Free;
  end;
end;

function BuildPlanPrompt(const Task, Analysis: string): string;
begin
  Result := 'Task: ' + Task + LineEnding + LineEnding;
  if Trim(Analysis) <> '' then
    Result := Result + 'Preliminary task analysis:' + LineEnding +
              Analysis + LineEnding + LineEnding +
              'Build a plan for the task based on this analysis.'
  else
    Result := Result + 'Build a plan for the task.';
  Result := Result + ' Return only JSON in the format ' +
            '{"steps":[{"description":"..."}]}.';
end;

function BuildStepPrompt(const Task, PlanRender, StepDesc: string): string;
begin
  Result := 'Overall task: ' + Task + LineEnding + LineEnding +
            'Current plan:' + LineEnding + PlanRender + LineEnding + LineEnding +
            'Goal of the current step: ' + StepDesc + LineEnding + LineEnding +
            'Perform only this step using the tools and return a short ' +
            'result (1-3 sentences). Do not perform other plan steps.';
end;

end.
