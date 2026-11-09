unit mirmid.session;
{ Saving and loading of dialog sessions in <WorkDir>/.mirmid/sessions.
  Schema 2: the plan field (plan JSON or null); backward compatible
  with schema 1 (no plan field). Auxiliary session files of subagents
  (<base>_sub_<n>.json), plan steps (<base>_step_<id>.json) and the
  analysis phase (<base>_analysis.json) live there as well. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mirmid.types, mirmid.plan;

function SessionDir(const WorkDir: string): string;
{ Context journal directory: <WorkDir>/.mirmid/journal (outside sessions,
  so that *.json session files and ListSessions are not affected). }
function JournalDir(const WorkDir: string): string;
{ Journal file of session <Id>: <Dir>/<Id>.jsonl (one JSON record per line). }
function JournalFile(const Dir, Id: string): string;
{ Appends a save record to the session journal: time, operation=Flash,
  context size (ContextTokens) and the size of the context part of this
  record (PartTokens), in tokens. }
function AppendJournalEntry(const Dir, Id: string;
  ContextTokens, PartTokens: Integer; out Err: string): Boolean;

type
  { Outcome of saving a session together with the context journal. }
  TPersistResult = (
    prSkipped,        { sessions disabled (--no-session): nothing written }
    prSessionFailed,  { session file not saved (journal untouched) }
    prJournalFailed,  { session saved, journal entry failed }
    prOk);            { session saved, journal appended }

{ Saves the session and immediately appends a context journal record. In
  --no-session mode (NoSession=True) it creates neither the session file nor
  the journal file. Err — the failure reason for prSessionFailed /
  prJournalFailed. An exception while writing the journal is caught here so
  that the CLI does not report it as a session save failure. }
function SaveSessionWithJournal(const WorkDir, Id, Model: string;
  const Msgs: TMessages; const Plan: TPlan; NoSession: Boolean;
  ContextTokens, PartTokens: Integer; out Err: string): TPersistResult;
{ Identifier of the form 20250101-120000-ab12cd. }
function NewSessionId: string;
{ Next number of the subagent session file with base <Base>: the highest
  existing number among the <Base>_sub_<n>.json files + 1. }
function NextSubagentNum(const Dir, Base: string): Integer;
{ Name (without extension) of the subagent session file: <Base>_sub_<n>. }
function SubagentSessionId(const Dir, Base: string): string;
{ Name (without extension) of the plan step session file: <Base>_step_<StepId>
  (this is the name of the session of the first step attempt). }
function StepSessionId(const Base, StepId: string): string;
{ Name (without extension) of the file of a step attempt session: the first
  attempt is like StepSessionId (<Base>_step_<StepId>), retries carry the
  attempt number <Base>_step_<StepId>_try<N> (N — attempt number starting
  from 2), so that attempt sessions do not overwrite each other.
  TryNum <= 1 — the first attempt. }
function StepSessionIdTry(const Base, StepId: string; TryNum: Integer): string;
{ Name (without extension) of the analysis phase session file: <Base>_analysis. }
function AnalysisSessionId(const Base: string): string;
{ Auxiliary session file (subagent, plan step or analysis): the name contains
  '_sub_', '_step_' or '_analysis'. }
function IsAuxSessionFile(const Name: string): Boolean;

function SaveSession(const Dir, Id, Model: string; const Msgs: TMessages;
  const Plan: TPlan; out Err: string): Boolean;
function LoadSession(const Dir, Id: string; out Msgs: TMessages;
  out Plan: TPlan; out Err: string): Boolean;
function ListSessions(const Dir: string; out Text: string): Boolean;

implementation

uses
  Classes, fpjson, mirmid.util, mirmid.json;

function SessionDir(const WorkDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(WorkDir) + '.mirmid' + PathDelim + 'sessions';
end;

function JournalDir(const WorkDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(WorkDir) + '.mirmid' + PathDelim + 'journal';
end;

function JournalFile(const Dir, Id: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + Id + '.jsonl';
end;
{ String values go through variables: fpjson escapes and encodes strings
  itself, while a literal passed to Add risks double re-encoding. }
function AppendJournalEntry(const Dir, Id: string;
  ContextTokens, PartTokens: Integer; out Err: string): Boolean;
var
  O: TJSONObject;
  S, Op: string;
begin
  Err := '';
  O := TJSONObject.Create;
  try
    S := NowStamp;
    Op := 'Flash';
    O.Add('time', S);
    O.Add('operation', Op);
    O.Add('context', ContextTokens);
    O.Add('part', PartTokens);
    S := O.AsJSON + sLineBreak;
    Result := AppendTextFile(JournalFile(Dir, Id), S, Err);
  finally
    O.Free;
  end;
end;

function NewSessionId: string;
begin
  Result := FormatDateTime('yyyymmdd-hhnnss', Now) + '-' +
    IntToHex(Random(65536), 4);
end;

function NextSubagentNum(const Dir, Base: string): Integer;
var
  SR: TSearchRec;
  N, Max: Integer;
  S: string;
begin
  Max := 0;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + Base + '_sub_*.json',
    faAnyFile, SR) = 0 then
  try
    repeat
      S := ChangeFileExt(SR.Name, '');
      N := StrToIntDef(Copy(S, Length(Base) + Length('_sub_') + 1, MaxInt), 0);
      if N > Max then
        Max := N;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := Max + 1;
end;

function SubagentSessionId(const Dir, Base: string): string;
begin
  Result := Base + '_sub_' + IntToStr(NextSubagentNum(Dir, Base));
end;

function StepSessionId(const Base, StepId: string): string;
begin
  Result := Base + '_step_' + StepId;
end;

{ Step attempt session: the attempt number is part of the file name. The first
  attempt keeps the former name (<Base>_step_<StepId>), so that single-attempt
  steps (PlanStepFixAttempts = 0) are saved as before; retries get the
  _try<N> suffix (2, 3, ...). The suffix comes after '_step_', so
  IsAuxSessionFile counts such files as auxiliary too. }
function StepSessionIdTry(const Base, StepId: string; TryNum: Integer): string;
begin
  Result := StepSessionId(Base, StepId);
  if TryNum > 1 then
    Result := Result + '_try' + IntToStr(TryNum);
end;

function AnalysisSessionId(const Base: string): string;
begin
  Result := Base + '_analysis';
end;

function IsAuxSessionFile(const Name: string): Boolean;
begin
  Result := (Pos('_sub_', Name) > 0) or (Pos('_step_', Name) > 0) or
    (Pos('_analysis', Name) > 0);
end;

function SessionFile(const Dir, Id: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + Id + '.json';
end;

function SaveSession(const Dir, Id, Model: string; const Msgs: TMessages;
  const Plan: TPlan; out Err: string): Boolean;
var
  O, PlanO: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('schema', 2);
    O.Add('id', Id);
    O.Add('model', Model);
    O.Add('updated', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
    O.Add('messages', MessagesToJSONArray(Msgs));
    { Plan (schema 2): an object when present, otherwise null. }
    if Plan <> nil then
    begin
      PlanO := Plan.ToJSON;
      try
        O.Add('plan', PlanO);
      except
        PlanO.Free;
        raise;
      end;
    end
    else
      O.Add('plan', TJSONNull.Create);
    Result := WriteTextFile(SessionFile(Dir, Id), O.FormatJSON([foUseTabChar]), Err);
  finally
    O.Free;
  end;
end;

function SaveSessionWithJournal(const WorkDir, Id, Model: string;
  const Msgs: TMessages; const Plan: TPlan; NoSession: Boolean;
  ContextTokens, PartTokens: Integer; out Err: string): TPersistResult;
begin
  Err := '';
  { --no-session: the session is not saved and needs no journal. }
  if NoSession then
    Exit(prSkipped);
  if not SaveSession(SessionDir(WorkDir), Id, Model, Msgs, Plan, Err) then
    Exit(prSessionFailed);
  try
    if AppendJournalEntry(JournalDir(WorkDir), Id, ContextTokens, PartTokens,
      Err)
    then
      Result := prOk
    else
      Result := prJournalFailed;
  except
    on E: Exception do
    begin
      Err := E.ClassName + ': ' + E.Message;
      Result := prJournalFailed;
    end;
  end;
end;

function LoadSession(const Dir, Id: string; out Msgs: TMessages;
  out Plan: TPlan; out Err: string): Boolean;
var
  Text: string;
  D, ArrD, PlanD: TJSONData;
begin
  SetLength(Msgs, 0);
  Plan := nil;
  Err := '';
  Result := False;
  if not ReadTextFile(SessionFile(Dir, Id), Text, Err) then
  begin
    Err := 'failed to read session: ' + Err;
    Exit;
  end;
  if not ParseJSON(Text, D, Err) then
  begin
    Err := 'invalid session JSON: ' + Err;
    Exit;
  end;
  try
    ArrD := nil;
    PlanD := nil;
    if D is TJSONObject then
    begin
      ArrD := D.FindPath('messages');
      PlanD := D.FindPath('plan');
    end;
    if not (ArrD is TJSONArray) then
    begin
      Err := 'session has no messages';
      Exit;
    end;
    JSONArrayToMessages(TJSONArray(ArrD), Msgs);
    { Plan (schema 2): no field (schema 1) or null — no plan;
      the plan is present but invalid — a load error. }
    if (PlanD <> nil) and not (PlanD is TJSONNull) then
    begin
      Plan := TPlan.FromJSON(PlanD, Err);
      if Plan = nil then
      begin
        Err := 'invalid plan in session: ' + Err;
        Exit;
      end;
    end;
    Result := True;
  finally
    D.Free;
  end;
end;

function ListSessions(const Dir: string; out Text: string): Boolean;
var
  SR: TSearchRec;
  L: TStringList;
begin
  Text := '';
  Result := False;
  L := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.json', faAnyFile, SR) = 0 then
    try
      repeat
        if not IsAuxSessionFile(SR.Name) then
          L.Add(ChangeFileExt(SR.Name, ''));
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    L.Sorted := True;
    Text := L.Text;
    Result := True;
  finally
    L.Free;
  end;
end;

initialization
  Randomize;

end.
