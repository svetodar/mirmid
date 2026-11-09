unit mirmid.planner;
{ Planning mode driver: four phases (analysis -> plan -> steps -> report),
  step sub-cycles and the revise_plan plan revision tool.
  The plan lives in the parent session; step sessions are saved to
  <base>_step_<id>.json files, the preliminary analysis session - to
  <base>_analysis.json (by analogy with the main session). }

{$mode objfpc}{$H+}

interface

uses
  fpjson, mirmid.types, mirmid.plan, mirmid.tools, mirmid.agent, mirmid.llm;

const
  REVISE_PLAN_TOOL_NAME = 'revise_plan';
  { Length of a step result in the plan (characters). }
  PLAN_STEP_RESULT_MAX = 500;

type
  { The plan changed - save the session. }
  TPlanChangedEvent = procedure of object;

  TPlanner = class
  private
    FCfg: TMirmidConfig;
    FRegistry: TToolRegistry;   { registry of the parent session, not owned }
    FPlan: TPlan;
    FOnEvent: TAgentEvent;
    FOnPlanChanged: TPlanChangedEvent;
    FSubAgentDepth: Integer;
    FSessionBase: string;
    FLogDir: string;             { model call log directory:
                                    <WorkDir>/.mirmid/logs }
    FLogPhase: string;           { label of the current phase for the log:
                                    analysis, plan, report, step sN }
    FInteractive: Boolean;       { interactive mode: the turn ends after the
                                    plan phase, the steps follow on user
                                    request }
    FPlanTask: string;           { task the current plan was built for
                                    (for step resumption and the report) }
    FAnalyzing: Boolean;         { the preliminary analysis is running:
                                    revise_plan is unavailable so the plan
                                    cannot change }
    procedure Fire(Kind: TAgentEventKind; const Text: string);
    { Appends a "request -> response" pair of the current phase to the model
      call log (time, phase, request, response, usage; on a call error - its
      text). A write failure does not abort the phase: the log is an auxiliary
      artefact, the error goes out as an aeError event. An empty FLogDir
      disables the log. }
    procedure LogModelCall(const Phase: string; const Msgs: TMessages;
      const Resp: TLLMResponse; ElapsedMs: Int64; const ErrText: string);
    { OnModelCall handler of a phase agent: writes the model call to the log
      with the current phase label (FLogPhase). It is attached to the analysis
      agent and to the plan step agents. }
    procedure AgentModelCall(const Msgs: TMessages; const Resp: TLLMResponse;
      ElapsedMs: Int64; const ErrText: string);
    { Direct model call of a phase (plan, report) through TLLMClient.Chat with
      the "request -> response" pair written to the model call log. The phase
      label is Phase (plan, report); a failed call also lands in the log (the
      error field). Result and Err - as with Chat. }
    function ChatLogged(LLM: TLLMClient; const Phase: string;
      const Msgs: TMessages; out Resp: TLLMResponse; out Err: string): Boolean;
    { Saves the analysis phase session to <SessionBase>_analysis.json (by
      analogy with the step session); does not save when SessionBase is
      empty. }
    procedure SaveAnalysisSession(const Msgs: TMessages);
    { Phase 0 - preliminary analysis: a separate read-only agent studies the
      task and returns a structured analysis. }
    function AnalysisPhase(const History: TMessages; out Analysis: string;
      out Err: string): Boolean;
    function PlanPhase(const Task: string; const History: TMessages;
      const Analysis: string; out Err: string): Boolean;
    { One plan step. FixHint - the reason of the previous attempt failure
      (empty - the first attempt): it goes into the step prompt (StepPrompt)
      so the model fixes the situation. TryNum/MaxTries - the attempt number
      (from 1) and the attempt limit (1 + Cfg.PlanStepFixAttempts): they go
      into the model log record label so step attempts differ by number. The
      repeat decision is made by RunPlannedTurn. }
    function RunStep(const Step: TPlanStep; const Task, FixHint: string;
      TryNum, MaxTries: Integer; out Err: string): Boolean;
    { Decision on a step that was not fixed within all attempts: ask the model
      whether to change the plan or to stop the work. The model answer is a
      JSON object with decision/ops/reason fields: decision = revise - plan
      revision (the operations are applied by the same handler as the
      revise_plan tool - HandleRevisePlan: validation, the aePlan event and
      session saving happen there), decision = stop or an unclear answer mean
      the turn stops. Returns True if the plan changed and the work can go on;
      False - the turn must stop, StopReason - the reason for aeError. }
    function ReviseAfterStepFailure(const Step: TPlanStep;
      const Task, Reason: string; out StopReason: string): Boolean;
    function ReportPhase(const Task: string; out Report: string; out Err: string): Boolean;
  public
    constructor Create(const ACfg: TMirmidConfig; ARegistry: TToolRegistry);
    destructor Destroy; override;
    { Current plan (nil until the plan phase is finished). Assigning the plan
      transfers ownership to the planner (session load, tests). }
    property Plan: TPlan read FPlan write FPlan;
    property OnEvent: TAgentEvent read FOnEvent write FOnEvent;
    property OnPlanChanged: TPlanChangedEvent read FOnPlanChanged write FOnPlanChanged;
    property SubAgentDepth: Integer read FSubAgentDepth write FSubAgentDepth;
    { Base of the plan step session file names (the main session id);
      empty - step sessions are not saved. }
    property SessionBase: string read FSessionBase write FSessionBase;
    { Model call log directory (<WorkDir>/.mirmid/logs): the planner phases
      write the request/response log there. Filled in the constructor from the
      WorkDir of the config; empty - nothing is logged. }
    property LogDir: string read FLogDir write FLogDir;
    { Interactive mode: after the plan is built RunPlannedTurn does not go on
      to the steps and the report but ends the turn - the user continues with
      the next instruction (an incomplete plan is resumed from the current
      pending step). }
    property Interactive: Boolean read FInteractive write FInteractive;
    { One turn in planning mode: plan -> steps -> report.
      History - the main session history including the current task as the
      last user message. }
    function RunPlannedTurn(const Task: string; const History: TMessages;
      out FinalText: string; out Err: string): Boolean;
    { revise_plan tool handler. Public so it can be bound to the registry as
      a method (RegisterRevisePlanTool). }
    function HandleRevisePlan(const Args: TJSONObject; const Ctx: TToolContext): TToolOutcome;
    { Saves the session of a step attempt (by analogy with the main session)
      to <SessionBase>_step_<Step.Id>.json, and for repeated attempts to
      <SessionBase>_step_<Step.Id>_try<N>.json (N - the attempt number from
      1), so attempts do not overwrite each other; does not save when
      SessionBase is empty. }
    procedure SaveStepSession(const Step: TPlanStep; const Msgs: TMessages;
      TryNum: Integer);
  end;

{ Registers the plan revision tool in the registry (bound to the current plan
  of the planner). }
procedure RegisterRevisePlanTool(R: TToolRegistry; P: TPlanner);

{ Config of the analysis phase agent: a copy of the parent session config with
  the analyst system prompt (PLANNER_ANALYSIS_PROMPT). Tool switches ([tools])
  and other settings are inherited as is: the analysis works with the same tool
  set as the other phases - otherwise tools explicitly enabled by the user
  would be silently disabled and answer "tool ... is disabled". The read-only
  requirement comes from the analyst prompt itself. }
function AnalysisConfig(const Parent: TMirmidConfig): TMirmidConfig;
{ aeStepEnd event text: "s1: done — result" (the result only when non-empty).
  The result itself is printed by the CLI and only with --show-step-result /
  --show-reasoning; by default a step leaves a status without a result.
  Exported for the event contract tests. }
function StepEndText(const Step: TPlanStep): string;
{ Step prompt with the failure reason of the previous attempt: when FixHint is
  non-empty, the (truncated) reason and the requirement to fix the situation
  instead of repeating the failed action are appended to BuildStepPrompt. When
  FixHint is empty the result equals BuildStepPrompt. Exported for the step
  retry tests. }
function StepPrompt(const Task, PlanRender, StepDesc, FixHint: string): string;
{ Limit of plan step attempts: 1 + Cfg.PlanStepFixAttempts (the first attempt
  plus fix retries); no retries (0) - a single attempt, a negative value
  degenerates into it as well. Exported for the step retry policy tests. }
function StepMaxTries(const Cfg: TMirmidConfig): Integer;

{ --- Classification of an abnormal step result --- }
{ Prefix of a tool error text (project convention): a step result starting
  with it counts as a failure, not as a result. }
const
  STEP_ERROR_PREFIX = 'ERROR:';

type
  { Class of a plan step result: sfNone - a regular result, the rest - a reason
    for a retry (Cfg.PlanStepFixAttempts):
    sfTurn - RunTurn returned False (Err - the failure reason),
    sfEmpty - the turn finished but the answer is empty,
    sfError - the step answer starts with "ERROR:" (a tool error became the
      final text of the step). }
  TStepFailure = (sfNone, sfTurn, sfEmpty, sfError);

{ Classification of a step result by three signs: turn success, answer text
  and Err. An empty (or blank) answer and a text with the ERROR: prefix are an
  abnormal result even with RunTurn=True: the step produced no result. }
function ClassifyStepResult(TurnOk: Boolean; const FinalText,
  Err: string): TStepFailure;
{ Name of the abnormal situation class for the log and the status line:
  ok / turn / empty / error. }
function StepFailureName(Kind: TStepFailure): string;
{ Reason of the abnormal result - the text for the retry prompt and for the
  step result in the plan. For sfNone - an empty string. }
function StepFailureReason(Kind: TStepFailure; const FinalText,
  Err: string): string;

{ --- Model call log (jsonl) ---
  Log directory: <WorkDir>/.mirmid/logs - next to the sessions but separate
  from them (ListSessions and the session *.json files are not affected). }
function ModelLogDir(const WorkDir: string): string;
{ Log file <Dir>/<Id>.jsonl; an empty Id - <Dir>/plan.jsonl. }
function ModelLogFile(const Dir, Id: string): string;
{ Appends one model call record to <Dir>/<Id>.jsonl: time, phase, request
  (messages), response, reasoning, tool_calls, finish_reason and usage.
  CallErr <> '' - the model call failed, its text goes into the error field
  (the response may be partial then).
  ElapsedMs < 0 - the duration is not written; an empty Dir - the log is
  disabled (Result=True, no file is created). Returns False and Err on a write
  failure: the caller decides how to react (a turn never fails because of the
  log). Exported for tests. }
function AppendModelLog(const Dir, Id, Phase: string; const Msgs: TMessages;
  const Resp: TLLMResponse; ElapsedMs: Int64; const CallErr: string;
  out Err: string): Boolean;

implementation

uses
  SysUtils, mirmid.json, mirmid.session, mirmid.util;

{ Truncation of a step result to PLAN_STEP_RESULT_MAX characters (an analogue
  of Shorten from mirmid.cli.pas; the CLI unit is not imported by the
  planner). }
function ShortenStepResult(const S: string): string;
begin
  if Length(S) <= PLAN_STEP_RESULT_MAX then
    Exit(S);
  { TruncateUTF8 does not cut a multi-byte character: "broken" bytes would then
    go into the API request and the server would answer HTTP 400. }
  Result := TruncateUTF8(S, PLAN_STEP_RESULT_MAX) + '…';
end;
{ Appends a message to the history (the [..] array constructor for TMessage is
  not available: the record has a dynamic ToolCalls field). }
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

{ String values go through variables: fpjson escapes strings itself, while a
  direct literal in the Add argument risks double re-encoding. The response and
  request content passes through SanitizeUTF8 (MessageToJSON does it itself):
  "broken" bytes from the model answer would otherwise make the log line
  unreadable. }
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
  { Empty directory - the log is disabled: no file is created. }
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
    { Failed model call: the failure reason next to the (possibly partial)
      response. }
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

{ Config of the analysis phase agent: a copy of the parent session config with
  the analyst system prompt. Tool switches ([tools]) and other settings are
  inherited as is - the analysis works with the same tool set as the other
  phases: otherwise tools explicitly enabled by the user would be silently
  disabled and answer "tool ... is disabled". The read-only requirement comes
  from the PLANNER_ANALYSIS_PROMPT prompt. }
function AnalysisConfig(const Parent: TMirmidConfig): TMirmidConfig;
begin
  Result := Parent;
  Result.SystemPrompt := PLANNER_ANALYSIS_PROMPT;
end;

{ aeStepEnd event text: "s1: done — result" (the result only when non-empty). }
function StepEndText(const Step: TPlanStep): string;
begin
  Result := Step.Id + ': ' + PlanStatusName(Step.Status);
  if Step.Result <> '' then
    Result := Result + ' — ' + Step.Result;
end;

{ Step prompt with the failure reason of the previous attempt. The reason is
  truncated: a whole "sheet" of an answer or of a tool error would otherwise
  bloat the system prompt of every next attempt. The model must eliminate the
  cause instead of repeating the failed action; if the step is already done -
  confirm the result. }
function StepPrompt(const Task, PlanRender, StepDesc, FixHint: string): string;
begin
  Result := BuildStepPrompt(Task, PlanRender, StepDesc);
  if Trim(FixHint) = '' then
    Exit;
  Result := Result + LineEnding + LineEnding +
    'The previous attempt of this step failed: ' +
    ShortenStepResult(Trim(FixHint)) + LineEnding +
    'Eliminate the cause of the failure and perform the step again. Do not ' +
    'repeat the same action that led to the failure; if the step is already ' +
    'done, briefly confirm the result.';
end;

{ Step attempt limit: the first attempt plus fix retries. A negative setting
  value (for example from the INI file) must not cancel the first attempt. }
function StepMaxTries(const Cfg: TMirmidConfig): Integer;
begin
  Result := 1 + Cfg.PlanStepFixAttempts;
  if Result < 1 then
    Result := 1;
end;

{ Step result classification. The order of the checks matters: a failed turn
  overrides the other signs (with RunTurn=False the answer text may be
  anything), then an empty/blank answer, then a text with the tool error
  prefix. The prefix is compared on the already trimmed string: models
  sometimes prepend a newline to the answer. }
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

{ Name of the abnormal situation class (for the model call log and debugging). }
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

{ Reason of the abnormal result - the text the model gets in the retry prompt
  and that lands in the plan step result. The turn Err may be empty (a rare
  case) - then the reason is formulated by class. }
function StepFailureReason(Kind: TStepFailure; const FinalText,
  Err: string): string;
begin
  case Kind of
    sfTurn:
      if Trim(Err) <> '' then
        Result := 'the turn failed: ' + Trim(Err)
      else
        Result := 'the turn failed without a stated reason';
    sfEmpty:
      Result := 'the model answer is empty: the step returned no result';
    sfError:
      Result := 'the step failed with a tool error: ' +
        ShortenStepResult(Trim(FinalText));
  else
    Result := '';
  end;
end;

{ The maximum numeric suffix among step ids (sN); 0 when there are none. }
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

{ Adds a step to the plan: at the end, then (if AfterId is non-empty) moves it
  after the step with that id. Returns the id of the new step.
  The auto id sN of AddStep may collide with an existing one after steps were
  removed - in that case a free id is assigned. }
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
    { Id collision: assign a free sN. }
    Plan.Steps[Idx].Id := 's' + IntToStr(MaxStepNum(Plan) + 1);
    NewId := Plan.Steps[Idx].Id;
  end;
  if AfterId <> '' then
  begin
    AIdx := Plan.FindStep(AfterId);
    if AIdx < 0 then
    begin
      Err := 'unknown step "' + AfterId + '" for add.after';
      Exit(False);
    end;
    { New order: all steps except the new one, the new one inserted after
      AfterId. The new step is at the end of the plan, so the position of
      AfterId in Order equals its position in the plan. }
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
      Err := 'internal error: failed to reorder the new step';
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
  { File name with the attempt number: otherwise a step retry would overwrite
    the session of the previous attempt and it would be unclear how it
    ended. }
  SaveSession(SessionDir(FCfg.WorkDir),
    StepSessionIdTry(FSessionBase, Step.Id, TryNum), FCfg.Model, Msgs, nil, Err);
end;
{ Analysis phase session: <session base>_analysis.json - next to the step
  sessions (<base>_step_<id>.json). Saved by analogy with the main session;
  an empty SessionBase - sessions are not saved. }
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

{ Writes a "request -> response" pair to the model call log. A write failure
  (no permissions, busy disk) does not interrupt the turn: the log is an
  auxiliary artefact, so the error goes out as an aeError event and the phase
  continues. Exceptions are swallowed too: AppendTextFile returns the error as
  a string, but O.AsJSON could raise on unexpected data. }
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
      Fire(aeError, 'model log: ' + Err);
  except
    on E: Exception do
      Fire(aeError, 'model log: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ OnModelCall handler of a phase agent (analysis, plan step): writes the call
  to the log with the current phase label FLogPhase. It has no logic of its
  own - all the work is in LogModelCall so every phase behaves the same. }
procedure TPlanner.AgentModelCall(const Msgs: TMessages;
  const Resp: TLLMResponse; ElapsedMs: Int64; const ErrText: string);
begin
  LogModelCall(FLogPhase, Msgs, Resp, ElapsedMs, ErrText);
end;

{ Direct Chat call of the plan/report phase with the model call log. The
  duration is measured by TicksMs around the call; the record is written in
  finally so a failed call also lands in the log (Err is non-empty then, Resp
  is partial). }
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

{ Phase 0 - preliminary analysis: a separate agent studies the task and its
  environment and returns the analysis text. Tool access is the parent
  session's: AnalysisConfig replaces only the system prompt, so the `[tools]`
  grants stay in force, while "read-only" is required by the analyst prompt. The
  plan is then built on top of the analysis. }
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
  { The analysis budget is the common agent one (FCfg.MaxSteps); the steps use
    a separate PlanStepMaxSteps budget. }
  Cfg := AnalysisConfig(FCfg);
  { Label of the analysis sub-session in the status line: "analysis". }
  LabelText := 'analysis';
  SubSession := False;
  A := TAgent.Create(Cfg, FRegistry);
  try
    A.SubAgentDepth := FSubAgentDepth + 1;
    { Model call log: every "request -> response" pair of this phase is written
      to <WorkDir>/.mirmid/logs/<base>.jsonl with phase=analysis. Always
      attached: an empty FLogDir disables the recording inside LogModelCall. }
    FLogPhase := 'analysis';
    A.OnModelCall := @AgentModelCall;
    { Analysis events go to the parent handler (status line as with a
      subagent); entry to and exit from the sub-session are marked by separate
      events with the "analysis" label so the UI does not guess the phase from
      the text. Without a handler the events are not needed: they are only for
      the UI. The analysis result still arrives as an aeAnalysis event. }
    if Assigned(FOnEvent) then
    begin
      A.OnEvent := @Fire;
      { The flag before Fire: if the event handler fails, finally still sends
        aeSubSessionEnd and clears the counters/analysis label. }
      SubSession := True;
      Fire(aeSubSessionStart, LabelText);
    end;
    { Dialog context: parent session history without the system message. }
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
    { Analysis session log (by analogy with the step session): saved even after
      a failed turn - the file shows where the agent stopped. }
    SaveAnalysisSession(A.Messages);
    if Result then
      Fire(aeAnalysis, Analysis);
  finally
    { Exit from the analysis sub-session - even on a crash: otherwise the
      analysis label and counters would remain in the status line of the next
      phase. }
    if SubSession then
      Fire(aeSubSessionEnd, LabelText);
    A.Free;
  end;
end;

{ Phase 1 - plan: a model request, parsing, one retry on a parse failure. The
  request includes the preliminary analysis results. }
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
  { Request: the system prompt + the history without the system message (the
    current task is already the last user message) + the plan request that
    includes the preliminary analysis. }
  FLogPhase := 'plan';
  Msgs := nil;
  AppendMsg(Msgs, MakeMessage(mrSystem, PLANNER_SYSTEM_PROMPT));
  for I := 0 to High(History) do
    if History[I].Role <> mrSystem then
      AppendMsg(Msgs, History[I]);
  AppendMsg(Msgs, MakeMessage(mrUser, BuildPlanPrompt(Task, Analysis)));
  LLM := TLLMClient.Create(FCfg);
  try
    { Model call log: the plan request (and the retry after a failed parse -
      a separate record with the same phase=plan). }
    if not ChatLogged(LLM, 'plan', Msgs, Resp, Err) then
      Exit(False);
    P := ParsePlanFromText(Resp.Content, Err);
    if P = nil then
    begin
      { One retry: the failed model answer and a user message about the
        error. }
      AppendMsg(Msgs, MakeMessage(mrAssistant, Resp.Content));
      AppendMsg(Msgs, MakeMessage(mrUser,
        'the previous answer was not valid JSON: ' + Err +
        '; return only JSON'));
      if not ChatLogged(LLM, 'plan', Msgs, Resp, Err) then
        Exit(False);
      P := ParsePlanFromText(Resp.Content, Err);
      if P = nil then
        Exit(False);
    end;
    if FPlan <> nil then
      FPlan.Free;
    FPlan := P;
    { Limit of the number of steps in the plan (plan_max_step > 0). }
    if FPlan.Truncate(FCfg.PlanMaxStep) > 0 then
      Fire(aeError, 'the plan is truncated: the step limit is exceeded (' +
        IntToStr(FCfg.PlanMaxStep) + ')');
    Fire(aePlan, FPlan.Render);
    if Assigned(FOnPlanChanged) then
      FOnPlanChanged;
    Result := True;
  finally
    LLM.Free;
  end;
end;

{ Phase 2 - one step: a sub-cycle in a new TAgent. The result is classified
  (ClassifyStepResult): a regular answer - done with the truncated result; a
  failed turn, an empty answer and a text with the "ERROR:" prefix - failed
  with the reason (StepFailureReason). FixHint - the failure reason of the
  previous attempt: it goes into the step prompt (StepPrompt) so the model
  fixes the situation instead of repeating the failed action. The repeat
  decision is made by RunPlannedTurn according to Cfg.PlanStepFixAttempts. }
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
  { Config - a copy of the parent one: the step prompt (with the failure reason
    of the previous attempt) and the step budget. }
  Cfg := FCfg;
  Cfg.SystemPrompt := StepPrompt(Task, FPlan.Render, Step.Description, FixHint);
  Cfg.MaxSteps := FCfg.PlanStepMaxSteps;
  { Base of the step attempt session file name: <session base>_step_<id>, for
    retries - with the attempt number (<base>_step_<id>_try<N>). Subagents
    inside the step inherit it, so their files differ by attempt as well. }
  StepBase := StepSessionIdTry(FSessionBase, Step.Id, TryNum);
  { Label of the step sub-session in the status line: "step sN". }
  LabelText := 'step ' + Step.Id;
  SubSession := False;
  A := TAgent.Create(Cfg, FRegistry);
  try
    A.SubAgentDepth := FSubAgentDepth + 1;
    { Step model call log: records of this phase get the label
      phase=step <id> in the same <base>.jsonl file as the other phases. }
    FLogPhase := 'step ' + Step.Id;
    A.OnModelCall := @AgentModelCall;
    { Step events go to the parent handler (status line as with a subagent);
      entry to and exit from the sub-session are marked by separate events
      with the label so the UI does not guess the phase from the text. Without
      a handler the events are not needed: they are only for the UI. }
    if Assigned(FOnEvent) then
    begin
      A.OnEvent := @Fire;
      { The flag before Fire: if the event handler fails, finally still sends
        aeSubSessionEnd and clears the counters/step label. }
      SubSession := True;
      Fire(aeSubSessionStart, LabelText);
    end;
    if FSessionBase <> '' then
      A.SessionBase := StepBase;
    A.AddUser(Step.Description);
    TurnOk := A.RunTurn(FinalText, Err);
    Fail := ClassifyStepResult(TurnOk, FinalText, Err);
    { The result class is visible in the model call log as a separate record
      (phase=step sN try K/M result: <class>, response - the reason): it shows
      how each step attempt ended and how many attempts are allowed
      (PlanStepFixAttempts). A write failure does not hinder the turn. }
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
      { The reason of the abnormal situation goes into the step result: it is
        visible in the plan and in the aeStepEnd events, and the retry
        (RunPlannedTurn) passes it to the model in the prompt. }
      Err := StepFailureReason(Fail, FinalText, Err);
      FPlan.SetStatus(Step.Id, psFailed, Err);
    end;
    { Session log of the step attempt (by analogy with the main session): for
      retries the file name contains the attempt number, so attempts do not
      overwrite each other. }
    SaveStepSession(Step, A.Messages, TryNum);
  finally
    { Exit from the sub-session - even when the step crashes: otherwise the
      step label and counters would remain in the status line of the next
      step. }
    if SubSession then
      Fire(aeSubSessionEnd, LabelText);
    A.Free;
  end;
end;

{ Prompt for a decision on a step that exhausted its attempts: change the plan
  or stop the work. The answer is only a JSON object (decision/ops/reason
  fields) so the parsing does not depend on the model wording. }
const
  STEP_REVISE_PROMPT =
    'You are the planner. A plan step failed after all fix attempts. ' +
    'Decide what to do next and return only a JSON object: ' +
    '{"decision":"revise","ops":[<operations>],"reason":"why"} - change ' +
    'the plan (operations: {"op":"add","description":"...","after":"s2"}, ' +
    '{"op":"remove","id":"s3"}, {"op":"reorder","order":["s1","s2"]}, ' +
    '{"op":"skip","id":"s4"}), or ' +
    '{"decision":"stop","reason":"why"} - stop the work. ' +
    'Do not repeat the same step without changing the approach.';

{ Decision on an exhausted step. A failure of the decision itself (no model
  answer, unparsable JSON, rejected ops) is treated as stopping the turn: the
  work cannot continue without a clear plan. }
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
  StopReason := 'step ' + Step.Id + ' failed: ' + Reason;
  Phase := 'step ' + Step.Id + ' revise';
  FLogPhase := Phase;
  Msgs := nil;
  AppendMsg(Msgs, MakeMessage(mrSystem, STEP_REVISE_PROMPT));
  AppendMsg(Msgs, MakeMessage(mrUser,
    'Task:' + LineEnding + Task + LineEnding + LineEnding +
    'Current plan:' + LineEnding + FPlan.Render + LineEnding + LineEnding +
    'Failed step ' + Step.Id + ': ' + Step.Description + LineEnding +
    'Reason of the failure after all attempts: ' + Reason));
  LLM := TLLMClient.Create(FCfg);
  try
    if not ChatLogged(LLM, Phase, Msgs, Resp, Err) then
    begin
      StopReason := StopReason + '; the plan decision was not obtained: ' + Err;
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
    StopReason := StopReason + '; could not parse the model decision';
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
      StopReason := StopReason + '; the revise decision has no plan operations';
      Exit;
    end;
    { The operations are applied by the same handler as the revise_plan tool:
      validation, the aePlan event and session saving - in one place. The
      context is filled as for a step: the handler checks the revise_plan key
      in the [tools] section by it, so a disabled tool does not change the plan
      on this path either. }
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
      StopReason := StopReason + '; plan revision failed: ' + Outcome.Text;
      Exit;
    end;
    Result := True;
  finally
    D.Free;
  end;
end;

{ Phase 3 - report: a deterministic summary + one final model request. If the
  request fails, Report is left unchanged (the deterministic summary); the turn
  does not count as failed. }
function TPlanner.ReportPhase(const Task: string; out Report: string; out Err: string): Boolean;
var
  LLM: TLLMClient;
  Msgs: TMessages;
  Resp: TLLMResponse;
begin
  Result := False;
  Err := '';
  Report := BuildPlanReport(FPlan, Task);
  { The report phase does not go through an agent either: a direct Chat into
    the model call log with the label phase=report. }
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

{ One turn in planning mode: plan -> steps -> report. }
function TPlanner.RunPlannedTurn(const Task: string; const History: TMessages;
  out FinalText: string; out Err: string): Boolean;
var
  I: Integer;
  Step: TPlanStep;
  StepErr: string;             { step failure reason (Err of the last attempt) }
  StepOk: Boolean;             { return value of RunStep }
  StepStatus: TPlanStepStatus; { actual step status after the attempts }
  InPlan: Boolean;             { the step stayed in the plan after attempts }
  Where: string;               { step state for the log record }
  FixHint: string;             { failure reason of the previous step attempt }
  TryNum: Integer;             { number of the running step attempt (from 1) }
  MaxTries: Integer;           { attempt limit: 1 + Cfg.PlanStepFixAttempts }
  Res: TLLMResponse;           { log record about a retry/exhausted attempts }
  LastFailId: string;          { step of the last failure - goes into turn Err }
  LastFailReason: string;      { reason of the last step failure }
  Halted: Boolean;             { the turn stopped: the step could not be fixed
                                 and the model decided to stop the work }
  StopReason: string;          { stop reason for aeError }
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
  { Phase 1: plan. A new plan is built when there is no plan or all steps of
    the previous plan reached a terminal state (a new turn is a new task). An
    incomplete plan (pending/in_progress) - resumption: go straight to the
    steps. }
  if (FPlan = nil) or
     ((FPlan.CountByStatus(psPending) = 0) and
      (FPlan.CountByStatus(psInProgress) = 0))
  then
  begin
    { Phase 0: preliminary analysis of the task. Its failure does not block the
      planning: the plan is built without the analysis. }
    if not AnalysisPhase(History, Analysis, AnaErr) then
    begin
      Fire(aeError, 'preliminary analysis failed: ' + AnaErr);
      Analysis := '';
    end;
    if not PlanPhase(Task, History, Analysis, Err) then
      Exit(False);
    PlanBuilt := True;
    FPlanTask := Task;
  end;
  { On resumption (including a user instruction in interactive mode) the steps
    and the report rely on the original plan task, not on the instruction
    text. }
  if FPlanTask <> '' then
    WorkTask := FPlanTask
  else
    WorkTask := Task;
  { Interactive mode: the work ends after the planning. The steps run on the
    next user instruction - then the plan exists and an incomplete plan is
    resumed from the current pending step. }
  if PlanBuilt and FInteractive then
  begin
    FinalText := FPlan.Render;
    Exit(True);
  end;
  { Phase 2: steps while there is a pending one. The step attempt limit is
    1 + Cfg.PlanStepFixAttempts (the first attempt plus retries; a negative
    value degenerates into a single attempt). A failed step is repeated: the
    failure reason goes into the prompt of the next attempt
    (RunStep.FixHint) so the model fixes the situation instead of repeating
    the same action. If it cannot be fixed, the model decides
    (ReviseAfterStepFailure): revise the plan through HandleRevisePlan or stop
    the work (the turn stops through aeError). Every attempt lands in the
    model call log (phase=step sN try K/M ...). }
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
        { Retry: the step is in progress again, the reason of the previous
          failure is in FixHint. The step might have left the plan (revise_plan
          in the sub-cycle) - there is nothing to repeat, Break before the
          model call. }
        if not FPlan.SetStatus(Step.Id, psInProgress, '') then
          Break;
        if Assigned(FOnPlanChanged) then
          FOnPlanChanged;
      end;
      StepOk := RunStep(Step, WorkTask, FixHint, TryNum + 1, MaxTries, StepErr);
      Inc(TryNum);
      { Both the return value and the step Err are taken into account: on a
        failure Err is the reason, it goes into the retry prompt and is
        remembered for the turn error; on success the hint is cleared so the
        previous failure does not affect the following steps. }
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
    { What happened to the step after the attempts: RunStep returned False but
      the step might have been revised inside the sub-cycle (revise_plan
      removed it or changed its status). The return value is checked together
      with the actual step status: the plan needs revision only for a step
      that stayed failed. }
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
        { Attempts exhausted - a separate log record: the step stays failed,
          there will be no more retries (the reason is the response of the
          record). }
        Res := Default(TLLMResponse);
        Res.Content := StepErr;
        LogModelCall(Format('step %s try %d/%d: attempts exhausted',
          [Step.Id, TryNum, MaxTries]), nil, Res, -1, '');
        { The step could not be fixed - make a decision: change the plan
          (revise_plan, the operations are applied by HandleRevisePlan) or stop
          the work. The model makes the decision; on a refusal of the plan or
          when it cannot be revised the turn stops through aeError (below,
          after the step end event). }
        if not ReviseAfterStepFailure(Step, WorkTask, StepErr, StopReason) then
          Halted := True;
      end
      else
      begin
        { Failure without the failed status: the step was already revised
          inside the sub-cycle - there is nothing to revise, but the failure
          reason is not lost, it stays in the model call log. }
        if InPlan then
          Where := 'step in status ' + PlanStatusName(StepStatus)
        else
          Where := 'step removed from the plan';
        Res := Default(TLLMResponse);
        Res.Content := StepErr;
        LogModelCall(Format('step %s try %d/%d: %s — plan revision is not needed',
          [Step.Id, TryNum, Where]), nil, Res, -1, '');
      end;
    end;
    { The step might have been removed from the plan by revise_plan in the
      sub-cycle - then the event carries a note. }
    I := FPlan.FindStep(Step.Id);
    if I >= 0 then
      Fire(aeStepEnd, StepEndText(FPlan.Steps[I]))
    else
      Fire(aeStepEnd, Step.Id + ': removed from the plan');
    if Assigned(FOnPlanChanged) then
      FOnPlanChanged;
    { The turn stopped: no more steps, no report. }
    if Halted then
      Break;
  end;
  { Stopping the turn - as an error (aeError + Err) and without a report: the
    work on the task is cancelled, there is nothing to summarise. }
  if Halted then
  begin
    Fire(aeError, StopReason);
    Err := StopReason;
    Exit(False);
  end;
  { Phase 3: report. A failed report request does not make the turn fail:
    FinalText is the deterministic summary. }
  if not ReportPhase(WorkTask, FinalText, Err) then
    Err := '';
  { Turn success: the plan is built and all steps reached a terminal state
    (done/failed/skipped). }
  Result := (FPlan.CountByStatus(psPending) = 0) and
            (FPlan.CountByStatus(psInProgress) = 0);
  if not Result then
  begin
    { The step Err is not lost: the reason of the last failure is appended to
      the turn error, otherwise the CLI would show only the statement about the
      remaining steps. }
    Err := 'the plan still has steps that did not reach a terminal state';
    if LastFailReason <> '' then
      Err := Err + '; last step failure ' + LastFailId + ': ' +
        LastFailReason;
  end;
end;

{ revise_plan tool: applies a list of operations to the current plan.
  The operations are applied in order; if an operation is invalid, the ones
  applied before it are kept and the result is the error text. }
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
  { Gate in the handler: the revise_plan key in the [tools] section. The
    planner calls this handler directly too (the structural "revise" decision
    when parsing the model answer), so the check here covers both paths: a
    disabled tool does not change the plan even when the call did not come
    through the registry. }
  if not ToolEnabled(Ctx.Cfg, REVISE_PLAN_TOOL_NAME) then
    Exit(ToolDisabled(REVISE_PLAN_TOOL_NAME));
  if FAnalyzing then
    Exit(ErrResult('revise_plan is not available during the preliminary analysis'));
  if FPlan = nil then
    Exit(ErrResult('no plan: revise_plan is available only in planning mode'));
  Item := nil;
  try
    Item := Args.FindPath('ops');
  except
    Item := nil;
  end;
  if (Item = nil) or not (Item is TJSONArray) then
    Exit(ErrResult('the "ops" argument is required: an array of operations'));
  Ops := TJSONArray(Item);
  if Ops.Count = 0 then
    Exit(ErrResult('empty "ops": at least one operation is required'));
  SetLength(Parts, 0);
  Changed := False;
  for I := 0 to Ops.Count - 1 do
  begin
    Op := Ops.Items[I];
    if not (Op is TJSONObject) then
      Exit(ErrResult('operation ' + IntToStr(I + 1) + ': must be a JSON object'));
    OpName := LowerCase(Trim(JStr(TJSONObject(Op), 'op', '')));
    case OpName of
      'add':
        begin
          Desc := Trim(JStr(TJSONObject(Op), 'description', ''));
          if Desc = '' then
            Exit(ErrResult('operation ' + IntToStr(I + 1) +
              ': add requires a non-empty "description"'));
          if (FCfg.PlanMaxStep > 0) and (Length(FPlan.Steps) >= FCfg.PlanMaxStep) then
            Exit(ErrResult('operation ' + IntToStr(I + 1) +
              ': add: the plan step limit is exceeded (' +
              IntToStr(FCfg.PlanMaxStep) + ')'));
          AfterId := JStr(TJSONObject(Op), 'after', '');
          if not AddStepAfter(FPlan, Desc, AfterId, Id, Err) then
            Exit(ErrResult('operation ' + IntToStr(I + 1) + ': ' + Err));
          SetLength(Parts, Length(Parts) + 1);
          Parts[Length(Parts) - 1] := 'add ' + Id + ' (' + Desc + ')';
        end;
      'remove':
        begin
          Id := JStr(TJSONObject(Op), 'id', '');
          if not FPlan.RemoveStep(Id) then
            Exit(ErrResult('operation ' + IntToStr(I + 1) +
              ': unknown step "' + Id + '" for remove'));
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
            Exit(ErrResult('operation ' + IntToStr(I + 1) +
              ': reorder requires an "order" array of step ids'));
          SetLength(Order, TJSONArray(Item).Count);
          for J := 0 to TJSONArray(Item).Count - 1 do
          begin
            if not (TJSONArray(Item).Items[J] is TJSONString) then
              Exit(ErrResult('operation ' + IntToStr(I + 1) +
                ': "order" must contain step ids (strings)'));
            Order[J] := TJSONArray(Item).Items[J].AsString;
          end;
          if not FPlan.Reorder(Order) then
            Exit(ErrResult('operation ' + IntToStr(I + 1) +
              ': reorder: the id set does not match the plan steps'));
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
            Exit(ErrResult('operation ' + IntToStr(I + 1) +
              ': unknown step "' + Id + '" for skip'));
          if FPlan.Steps[Idx].Status <> psPending then
            Exit(ErrResult('operation ' + IntToStr(I + 1) +
              ': skip is available only for pending steps (step "' + Id +
              '" has status ' + PlanStatusName(FPlan.Steps[Idx].Status) + ')'));
          FPlan.SetStatus(Id, psSkipped, '');
          SetLength(Parts, Length(Parts) + 1);
          Parts[Length(Parts) - 1] := 'skip ' + Id;
        end;
    else
      Exit(ErrResult('operation ' + IntToStr(I + 1) +
        ': unknown op "' + OpName + '"'));
    end;
    Changed := True;
  end;
  { The plan changed (at least partially): event + session saving. }
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
  Result := OkResult('plan updated: ' + Changes);
end;

procedure RegisterRevisePlanTool(R: TToolRegistry; P: TPlanner);
var
  Props: TJSONObject;
begin
  Props := TJSONObject.Create;
  Props.Add('ops', TJSONObject.Create([
    'type', 'array',
    'description',
      'List of plan operations (applied in order): ' +
      '{"op":"add","description":"...","after":"s2"} - add a step after ' +
      '"after" (at the end when after is empty); ' +
      '{"op":"remove","id":"s3"} - remove a step; ' +
      '{"op":"reorder","order":["s1","s4","s2"]} - new step order; ' +
      '{"op":"skip","id":"s4"} - skip a pending step.',
    'items', TJSONObject.Create(['type', 'object'])
  ]));
  R.AddMethod(REVISE_PLAN_TOOL_NAME,
    'Revises the current plan: adds, removes, reorders or skips steps. ' +
    'The operations are applied in order; if an operation is invalid, the ' +
    'ones applied before it are kept.',
    SchemaObject(Props, ['ops']),
    @P.HandleRevisePlan);
end;

end.
