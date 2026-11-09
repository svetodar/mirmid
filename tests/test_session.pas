unit test_session;
{ Session tests (mirmid.session): schema 2 with the plan field, round trip,
  backward compatibility with schema 1, invalid plan. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TSessionTests = class(TTestCase)
  private
    FDir: string;
    { Full path to the session file inside the test directory. }
    function SessionFile(const Id: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRoundTripWithPlan;
    procedure TestNilPlanSavedAsNull;
    procedure TestSchema1FileLoads;
    procedure TestInvalidPlanIsError;
    procedure TestNextSubagentNum;
    procedure TestSubagentSessionId;
    procedure TestStepSessionId;
    { Step attempt sessions: the first one keeps the old name, retries are _try<N>. }
    procedure TestStepSessionIdTry;
    { Analysis phase session: <base>_analysis and its exclusion from ListSessions. }
    procedure TestAnalysisSessionId;
    procedure TestIsAuxSessionFile;
    procedure TestListSessionsSkipsAux;
    procedure TestJournalEntryWritesFile;
    procedure TestJournalEntryFields;
    procedure TestJournalEntryAppends;
    { Journal paths: <WorkDir>/.mirmid/journal/<Id>.jsonl — outside sessions. }
    procedure TestJournalPaths;
    { A journal write failure returns False and the reason in Err. }
    procedure TestJournalEntryErrorReported;
    { With --no-session neither the journal file (nor the session file) is created. }
    procedure TestNoJournalWhenNoSession;
  end;

implementation

uses
  Classes, SysUtils, fpjson, mirmid.types, mirmid.util, mirmid.json,
  mirmid.session, mirmid.plan;

procedure TSessionTests.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(TempDir) +
    'mirmid-session-test-' + IntToStr(Random(1000000));
  ForceDirectories(FDir);
end;

procedure TSessionTests.TearDown;
begin
  DeleteFile(SessionFile('s1'));
  DeleteFile(SessionFile('s2'));
  DeleteFile(SessionFile('s3'));
  DeleteFile(SessionFile('s4'));
  DeleteFile(SessionFile('base_sub_1'));
  DeleteFile(SessionFile('base_sub_3'));
  DeleteFile(SessionFile('other'));
  DeleteFile(SessionFile('base_step_s1'));
  DeleteFile(SessionFile('base2_sub_1'));
  DeleteFile(SessionFile('auxmain'));
  DeleteFile(SessionFile('auxmain_sub_1'));
  DeleteFile(SessionFile('auxmain_step_s1'));
  DeleteFile(JournalFile(FDir, 'j1'));
  { A stub file in place of the directory the journal failure test cannot create. }
  DeleteFile(IncludeTrailingPathDelimiter(FDir) + 'blocked');
  { Files created by SaveSessionWithJournal in <FDir>/.mirmid. }
  DeleteFile(IncludeTrailingPathDelimiter(SessionDir(FDir)) + 'j2.json');
  DeleteFile(JournalFile(JournalDir(FDir), 'j2'));
  RemoveDir(SessionDir(FDir));
  RemoveDir(JournalDir(FDir));
  RemoveDir(ExtractFileDir(JournalDir(FDir)));
  RemoveDir(FDir);
end;

function TSessionTests.SessionFile(const Id: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + Id + '.json';
end;

{ Round trip: save with a plan -> load — messages and plan match
  (steps, ids, statuses, results); the file carries schema 2. }
procedure TSessionTests.TestRoundTripWithPlan;
var
  Msgs, Msgs2: TMessages;
  Plan, Plan2: TPlan;
  Err: string;
  Text: string;
  D: TJSONData;
begin
  Err := '';
  SetLength(Msgs, 2);
  Msgs[0].Role := mrUser;
  Msgs[0].Content := 'make a report';
  Msgs[1].Role := mrAssistant;
  Msgs[1].Content := 'grüße';

  Plan := TPlan.Create;
  try
    Plan.AddStep('collect data');
    Plan.AddStep('write report');
    Plan.SetStatus('s1', psDone, 'data collected');
    Plan.SetStatus('s2', psInProgress, '');

    AssertTrue('save: ' + Err,
      SaveSession(FDir, 's1', 'test-model', Msgs, Plan, Err));
    AssertEquals('error is empty', '', Err);

    { The file carries schema 2 and the plan field. }
    AssertTrue('read file: ', ReadTextFile(SessionFile('s1'), Text, Err));
    D := nil;
    AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
    try
      AssertEquals('schema 2', 2, TJSONObject(D).Find('schema').AsInteger);
      AssertTrue('plan field present', TJSONObject(D).FindPath('plan') <> nil);
    finally
      D.Free;
    end;

    Msgs2 := nil;
    Plan2 := nil;
    AssertTrue('load: ' + Err, LoadSession(FDir, 's1', Msgs2, Plan2, Err));
    try
      AssertEquals('message count', 2, Length(Msgs2));
      AssertEquals('role 1', Ord(mrUser), Ord(Msgs2[0].Role));
      AssertEquals('text 1', 'make a report', Msgs2[0].Content);
      AssertEquals('role 2', Ord(mrAssistant), Ord(Msgs2[1].Role));
      AssertEquals('text 2', 'grüße', Msgs2[1].Content);
      AssertTrue('plan loaded', Plan2 <> nil);
      AssertEquals('step count', 2, Length(Plan2.Steps));
      AssertEquals('id 1', 's1', Plan2.Steps[0].Id);
      AssertEquals('description 1', 'collect data', Plan2.Steps[0].Description);
      AssertEquals('status 1', Ord(psDone), Ord(Plan2.Steps[0].Status));
      AssertEquals('result 1', 'data collected', Plan2.Steps[0].Result);
      AssertEquals('id 2', 's2', Plan2.Steps[1].Id);
      AssertEquals('description 2', 'write report', Plan2.Steps[1].Description);
      AssertEquals('status 2', Ord(psInProgress), Ord(Plan2.Steps[1].Status));
      AssertEquals('result 2 is empty', '', Plan2.Steps[1].Result);
    finally
      Plan2.Free;
    end;
  finally
    Plan.Free;
  end;
end;

{ Saving with Plan = nil -> plan: null in the file -> loading gives Plan = nil. }
procedure TSessionTests.TestNilPlanSavedAsNull;
var
  Msgs, Msgs2: TMessages;
  Plan2: TPlan;
  Err: string;
  Text: string;
  D: TJSONData;
  PlanD: TJSONData;
begin
  Err := '';
  SetLength(Msgs, 1);
  Msgs[0].Role := mrUser;
  Msgs[0].Content := 'hello';

  AssertTrue('save: ' + Err,
    SaveSession(FDir, 's2', 'test-model', Msgs, nil, Err));

  AssertTrue('read file: ', ReadTextFile(SessionFile('s2'), Text, Err));
  D := nil;
  AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
  try
    PlanD := TJSONObject(D).FindPath('plan');
    AssertTrue('plan field present', PlanD <> nil);
    AssertTrue('plan = null', PlanD is TJSONNull);
  finally
    D.Free;
  end;

  Msgs2 := nil;
  Plan2 := nil;
  AssertTrue('load: ' + Err, LoadSession(FDir, 's2', Msgs2, Plan2, Err));
  AssertNull('plan is nil', Plan2);
  AssertEquals('message count', 1, Length(Msgs2));
  AssertEquals('text', 'hello', Msgs2[0].Content);
end;

{ A schema 1 file (JSON without the plan field, assembled by hand) loads,
  Plan = nil. }
procedure TSessionTests.TestSchema1FileLoads;
var
  Msgs: TMessages;
  Plan: TPlan;
  Err: string;
  O, M: TJSONObject;
  A: TJSONArray;
  S: string;
begin
  O := TJSONObject.Create;
  try
    O.Add('schema', 1);
    O.Add('id', 's3');
    O.Add('model', 'old-model');
    O.Add('updated', '2025-01-01T00:00:00');
    A := TJSONArray.Create;
    M := TJSONObject.Create;
    M.Add('role', 'user');
    { Literal through a variable: a direct literal in TJSONObject.Add is
      re-encoded twice (UTF-8 -> Latin-1 -> UTF-8). }
    S := 'grüße';
    M.Add('content', S);
    A.Add(M);
    O.Add('messages', A);
    AssertTrue('write file: ',
      WriteTextFile(SessionFile('s3'), O.FormatJSON([foUseTabChar]), Err));
  finally
    O.Free;
  end;
  Msgs := nil;
  Plan := nil;
  AssertTrue('load schema 1: ' + Err, LoadSession(FDir, 's3', Msgs, Plan, Err));
  AssertEquals('message count', 1, Length(Msgs));
  AssertEquals('role', Ord(mrUser), Ord(Msgs[0].Role));
  AssertEquals('text', 'grüße', Msgs[0].Content);
end;

{ An invalid plan ("steps": the string "x") — a load error, Plan = nil. }
procedure TSessionTests.TestInvalidPlanIsError;
var
  Msgs: TMessages;
  Plan: TPlan;
  Err: string;
  O, M, P: TJSONObject;
  A: TJSONArray;
  S: string;
begin
  O := TJSONObject.Create;
  try
    O.Add('schema', 2);
    O.Add('id', 's4');
    O.Add('model', 'test-model');
    O.Add('updated', '2025-01-01T00:00:00');
    A := TJSONArray.Create;
    M := TJSONObject.Create;
    M.Add('role', 'user');
    S := 'hello';
    M.Add('content', S);
    A.Add(M);
    O.Add('messages', A);
    P := TJSONObject.Create;
    P.Add('steps', 'x');
    O.Add('plan', P);
    AssertTrue('write file: ',
      WriteTextFile(SessionFile('s4'), O.FormatJSON([foUseTabChar]), Err));
  finally
    O.Free;
  end;

  Msgs := nil;
  Plan := nil;
  AssertFalse('invalid plan is an error',
    LoadSession(FDir, 's4', Msgs, Plan, Err));
  AssertTrue('error text is set', Err <> '');
  AssertNull('plan is nil', Plan);
end;

{ The next subagent number: an empty directory -> 1; after the files
  base_sub_1.json and base_sub_3.json -> 4; foreign files do not matter. }
procedure TSessionTests.TestNextSubagentNum;
var
  Err: string;
begin
  AssertEquals('empty directory', 1, NextSubagentNum(FDir, 'base'));
  AssertTrue('write 1: ', WriteTextFile(SessionFile('base_sub_1'), '{}', Err));
  AssertTrue('write 3: ', WriteTextFile(SessionFile('base_sub_3'), '{}', Err));
  AssertTrue('foreign file: ', WriteTextFile(SessionFile('other'), '{}', Err));
  AssertTrue('step file: ', WriteTextFile(SessionFile('base_step_s1'), '{}', Err));
  AssertEquals('after the files', 4, NextSubagentNum(FDir, 'base'));
end;

{ The subagent session file name: an empty directory -> <base>_sub_1;
  after the file base2_sub_1.json -> base2_sub_2. }
procedure TSessionTests.TestSubagentSessionId;
var
  Err: string;
begin
  AssertEquals('empty directory', 'base2_sub_1', SubagentSessionId(FDir, 'base2'));
  AssertTrue('write: ', WriteTextFile(SessionFile('base2_sub_1'), '{}', Err));
  AssertEquals('after the file', 'base2_sub_2', SubagentSessionId(FDir, 'base2'));
end;

{ Plan step session file name: <base>_step_<id>. }
procedure TSessionTests.TestStepSessionId;
begin
  AssertEquals('name', 'sess_step_s2', StepSessionId('sess', 's2'));
end;

{ A step attempt session: the first attempt is saved under the old name
  <base>_step_<id> (compatibility with PlanStepFixAttempts = 0), retries get
  the _try<N> suffix, so attempts do not overwrite each other. }
procedure TSessionTests.TestStepSessionIdTry;
begin
  AssertEquals('first attempt', 'sess_step_s2',
    StepSessionIdTry('sess', 's2', 1));
  AssertEquals('the same as StepSessionId', StepSessionId('sess', 's2'),
    StepSessionIdTry('sess', 's2', 1));
  AssertEquals('second attempt', 'sess_step_s2_try2',
    StepSessionIdTry('sess', 's2', 2));
  AssertEquals('third attempt', 'sess_step_s2_try3',
    StepSessionIdTry('sess', 's2', 3));
  AssertEquals('number 0 -> the first one', 'sess_step_s2',
    StepSessionIdTry('sess', 's2', 0));
  AssertTrue('the attempt file is auxiliary',
    IsAuxSessionFile(StepSessionIdTry('sess', 's2', 2) + '.json'));
end;

{ Analysis phase session: <base>_analysis; such files do not show up in
  ListSessions (the name contains '_analysis'), i.e. they do not look like
  ordinary dialogue sessions. }
procedure TSessionTests.TestAnalysisSessionId;
begin
  AssertEquals('name', 'base_analysis', AnalysisSessionId('base'));
  AssertTrue('the analysis file is auxiliary',
    IsAuxSessionFile(AnalysisSessionId('base') + '.json'));
  AssertFalse('the main session is not auxiliary',
    IsAuxSessionFile('20250101-120000-ab12cd.json'));
end;

{ An auxiliary session file: the name contains '_sub_' or '_step_'. }
procedure TSessionTests.TestIsAuxSessionFile;
begin
  AssertTrue('subagent', IsAuxSessionFile('x_sub_1.json'));
  AssertTrue('step', IsAuxSessionFile('x_step_s1.json'));
  AssertFalse('main session', IsAuxSessionFile('20250101-120000-ab12cd.json'));
end;

{ ListSessions does not include auxiliary files (subagents, steps). }
procedure TSessionTests.TestListSessionsSkipsAux;
var
  Msgs: TMessages;
  Err: string;
  Text: string;
begin
  Err := '';
  SetLength(Msgs, 1);
  Msgs[0].Role := mrUser;
  Msgs[0].Content := 'hello';
  AssertTrue('main: ' + Err,
    SaveSession(FDir, 'auxmain', 'test-model', Msgs, nil, Err));
  AssertTrue('subagent: ' + Err,
    SaveSession(FDir, 'auxmain_sub_1', 'test-model', Msgs, nil, Err));
  AssertTrue('step: ' + Err,
    SaveSession(FDir, 'auxmain_step_s1', 'test-model', Msgs, nil, Err));
  AssertTrue('list: ', ListSessions(FDir, Text));
  AssertEquals('the main session only', 'auxmain' + sLineBreak, Text);
end;

{ Context journal: AppendJournalEntry creates the file <Dir>/<Id>.jsonl,
  the entry is one valid JSON line terminated by a newline. }
procedure TSessionTests.TestJournalEntryWritesFile;
var
  Err, Path, Text: string;
  D: TJSONData;
begin
  Err := '';
  Path := JournalFile(FDir, 'j1');
  AssertFalse('the file does not exist yet', FileExists(Path));
  AssertTrue('journal write: ' + Err,
    AppendJournalEntry(FDir, 'j1', 100, 20, Err));
  AssertEquals('error is empty', '', Err);
  AssertTrue('file created', FileExists(Path));
  AssertTrue('read file: ' + Err, ReadTextFile(Path, Text, Err));
  AssertTrue('newline at the end',
    (Length(Text) > Length(sLineBreak)) and
    (Copy(Text, Length(Text) - Length(sLineBreak) + 1, Length(sLineBreak)) =
      sLineBreak));
  D := nil;
  AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
  try
    AssertTrue('object', D is TJSONObject);
  finally
    D.Free;
  end;
end;

{ Journal entry fields: operation = Flash, a non-empty time in the
  yyyy-mm-dd hh:nn:ss format, the context and part sizes are numbers. }
procedure TSessionTests.TestJournalEntryFields;
var
  Err, Text: string;
  D: TJSONData;
begin
  Err := '';
  AssertTrue('journal write: ' + Err,
    AppendJournalEntry(FDir, 'j1', 120, 30, Err));
  AssertTrue('read file: ' + Err,
    ReadTextFile(JournalFile(FDir, 'j1'), Text, Err));
  D := nil;
  AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
  try
    AssertEquals('operation', 'Flash', JStr(D, 'operation', ''));
    AssertEquals('time is not empty', 19, Length(JStr(D, 'time', '')));
    AssertEquals('context', 120, JInt(D, 'context', -1));
    AssertEquals('part', 30, JInt(D, 'part', -1));
  finally
    D.Free;
  end;
end;

{ A repeated call appends an entry as a new line instead of overwriting the file. }
procedure TSessionTests.TestJournalEntryAppends;
var
  Err, Text: string;
  L: TStringList;
  D: TJSONData;
begin
  Err := '';
  AssertTrue('entry 1: ' + Err, AppendJournalEntry(FDir, 'j1', 100, 20, Err));
  AssertTrue('entry 2: ' + Err, AppendJournalEntry(FDir, 'j1', 180, 80, Err));
  AssertTrue('read file: ' + Err,
    ReadTextFile(JournalFile(FDir, 'j1'), Text, Err));
  L := TStringList.Create;
  try
    L.Text := Text;
    AssertEquals('two lines', 2, L.Count);
    D := nil;
    AssertTrue('JSON 1: ' + Err, ParseJSON(L[0], D, Err));
    try
      AssertEquals('context 1', 100, JInt(D, 'context', -1));
      AssertEquals('part 1', 20, JInt(D, 'part', -1));
    finally
      D.Free;
    end;
    D := nil;
    AssertTrue('JSON 2: ' + Err, ParseJSON(L[1], D, Err));
    try
      AssertEquals('context 2', 180, JInt(D, 'context', -1));
      AssertEquals('part 2', 80, JInt(D, 'part', -1));
    finally
      D.Free;
    end;
  finally
    L.Free;
  end;
end;

{ Context journal paths: the directory <WorkDir>/.mirmid/journal (separate
  from sessions, so that ListSessions and the session *.json files are not
  affected) and the entry file <Dir>/<Id>.jsonl. }
procedure TSessionTests.TestJournalPaths;
begin
  AssertEquals('journal directory',
    IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'journal',
    JournalDir(FDir));
  AssertEquals('entry file',
    IncludeTrailingPathDelimiter(JournalDir(FDir)) + 'j9.jsonl',
    JournalFile(JournalDir(FDir), 'j9'));
  AssertTrue('the journal is outside the sessions directory',
    JournalDir(FDir) <> SessionDir(FDir));
end;

{ A journal write failure is not swallowed: AppendJournalEntry returns False
  and fills Err, so that SaveSessionWithJournal can report prJournalFailed.
  Here the journal directory cannot be created — a file sits in its place. }
procedure TSessionTests.TestJournalEntryErrorReported;
var
  Err, Blocked: string;
begin
  Err := '';
  Blocked := IncludeTrailingPathDelimiter(FDir) + 'blocked';
  AssertTrue('stub file: ' + Err, WriteTextFile(Blocked, 'x', Err));
  Err := '';
  AssertFalse('the journal write is impossible',
    AppendJournalEntry(IncludeTrailingPathDelimiter(Blocked) + 'journal',
      'j1', 10, 5, Err));
  AssertTrue('the reason is reported', Err <> '');
  AssertFalse('the journal file is not created',
    FileExists(JournalFile(IncludeTrailingPathDelimiter(Blocked) + 'journal',
      'j1')));
end;

{ --no-session: there is nothing to save — neither the session file nor the
  journal file is created (not even the journal directory). Control: the
  enabled mode writes both. }
procedure TSessionTests.TestNoJournalWhenNoSession;
var
  Msgs: TMessages;
  Err, SessPath: string;
begin
  Err := '';
  SetLength(Msgs, 1);
  Msgs[0].Role := mrUser;
  Msgs[0].Content := 'hello';
  SessPath := IncludeTrailingPathDelimiter(SessionDir(FDir)) + 'j2.json';
  AssertTrue('--no-session mode: skipped',
    SaveSessionWithJournal(FDir, 'j2', 'test-model', Msgs, nil, True,
      40, 10, Err) = prSkipped);
  AssertEquals('error is empty', '', Err);
  AssertFalse('no session file', FileExists(SessPath));
  AssertFalse('no journal file',
    FileExists(JournalFile(JournalDir(FDir), 'j2')));
  AssertFalse('no journal directory', DirectoryExists(JournalDir(FDir)));
  { Control: without --no-session both the session and the journal entry are saved. }
  AssertTrue('normal mode: written',
    SaveSessionWithJournal(FDir, 'j2', 'test-model', Msgs, nil, False,
      40, 10, Err) = prOk);
  AssertEquals('error is empty (2)', '', Err);
  AssertTrue('session file created', FileExists(SessPath));
  AssertTrue('journal file created',
    FileExists(JournalFile(JournalDir(FDir), 'j2')));
end;

initialization
  RegisterTest(TSessionTests);

end.
