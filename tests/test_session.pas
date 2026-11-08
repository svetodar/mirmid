unit test_session;
{ Тесты сессий (mirmid.session): схема 2 с полем плана, round-trip,
  обратная совместимость со схемой 1, невалидный план. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TSessionTests = class(TTestCase)
  private
    FDir: string;
    { Полный путь к файлу сессии в каталоге теста. }
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
    { Сессии попыток шага: первая — прежнее имя, повторные — _try<N>. }
    procedure TestStepSessionIdTry;
    { Сессия фазы анализа: <база>_analysis и её исключение из ListSessions. }
    procedure TestAnalysisSessionId;
    procedure TestIsAuxSessionFile;
    procedure TestListSessionsSkipsAux;
    procedure TestJournalEntryWritesFile;
    procedure TestJournalEntryFields;
    procedure TestJournalEntryAppends;
    { Пути журнала: <WorkDir>/.mirmid/journal/<Id>.jsonl — вне sessions. }
    procedure TestJournalPaths;
    { Сбой записи журнала возвращает False и причину в Err. }
    procedure TestJournalEntryErrorReported;
    { При --no-session файл журнала (как и файл сессии) не создаётся. }
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
  { Файл-заглушка, на месте которого тест сбоя журнала не даёт создать каталог. }
  DeleteFile(IncludeTrailingPathDelimiter(FDir) + 'blocked');
  { Файлы, созданные SaveSessionWithJournal в <FDir>/.mirmid. }
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

{ Round-trip: сохранить с планом → загрузить — сообщения и план
  совпадают (шаги, id, статусы, результаты); в файле схема 2. }
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
  Msgs[0].Content := 'сделай отчёт';
  Msgs[1].Role := mrAssistant;
  Msgs[1].Content := 'готово';

  Plan := TPlan.Create;
  try
    Plan.AddStep('собрать данные');
    Plan.AddStep('написать отчёт');
    Plan.SetStatus('s1', psDone, 'данные собраны');
    Plan.SetStatus('s2', psInProgress, '');

    AssertTrue('сохранение: ' + Err,
      SaveSession(FDir, 's1', 'test-model', Msgs, Plan, Err));
    AssertEquals('ошибка пуста', '', Err);

    { В файле схема 2 и поле plan. }
    AssertTrue('чтение файла: ', ReadTextFile(SessionFile('s1'), Text, Err));
    D := nil;
    AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
    try
      AssertEquals('схема 2', 2, TJSONObject(D).Find('schema').AsInteger);
      AssertTrue('есть поле plan', TJSONObject(D).FindPath('plan') <> nil);
    finally
      D.Free;
    end;

    Msgs2 := nil;
    Plan2 := nil;
    AssertTrue('загрузка: ' + Err, LoadSession(FDir, 's1', Msgs2, Plan2, Err));
    try
      AssertEquals('число сообщений', 2, Length(Msgs2));
      AssertEquals('роль 1', Ord(mrUser), Ord(Msgs2[0].Role));
      AssertEquals('текст 1', 'сделай отчёт', Msgs2[0].Content);
      AssertEquals('роль 2', Ord(mrAssistant), Ord(Msgs2[1].Role));
      AssertEquals('текст 2', 'готово', Msgs2[1].Content);
      AssertTrue('план загружен', Plan2 <> nil);
      AssertEquals('число шагов', 2, Length(Plan2.Steps));
      AssertEquals('id 1', 's1', Plan2.Steps[0].Id);
      AssertEquals('описание 1', 'собрать данные', Plan2.Steps[0].Description);
      AssertEquals('статус 1', Ord(psDone), Ord(Plan2.Steps[0].Status));
      AssertEquals('результат 1', 'данные собраны', Plan2.Steps[0].Result);
      AssertEquals('id 2', 's2', Plan2.Steps[1].Id);
      AssertEquals('описание 2', 'написать отчёт', Plan2.Steps[1].Description);
      AssertEquals('статус 2', Ord(psInProgress), Ord(Plan2.Steps[1].Status));
      AssertEquals('результат 2 пуст', '', Plan2.Steps[1].Result);
    finally
      Plan2.Free;
    end;
  finally
    Plan.Free;
  end;
end;

{ Сохранение с Plan = nil → в файле plan: null → загрузка с Plan = nil. }
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
  Msgs[0].Content := 'привет';

  AssertTrue('сохранение: ' + Err,
    SaveSession(FDir, 's2', 'test-model', Msgs, nil, Err));

  AssertTrue('чтение файла: ', ReadTextFile(SessionFile('s2'), Text, Err));
  D := nil;
  AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
  try
    PlanD := TJSONObject(D).FindPath('plan');
    AssertTrue('поле plan есть', PlanD <> nil);
    AssertTrue('plan = null', PlanD is TJSONNull);
  finally
    D.Free;
  end;

  Msgs2 := nil;
  Plan2 := nil;
  AssertTrue('загрузка: ' + Err, LoadSession(FDir, 's2', Msgs2, Plan2, Err));
  AssertNull('план nil', Plan2);
  AssertEquals('число сообщений', 1, Length(Msgs2));
  AssertEquals('текст', 'привет', Msgs2[0].Content);
end;

{ Файл схемы 1 (JSON без поля plan, собран вручную) загружается,
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
    { Литерал через переменную: прямой литерал в TJSONObject.Add
      перекодируется дважды (UTF-8 → Latin-1 → UTF-8). }
    S := 'старое сообщение';
    M.Add('content', S);
    A.Add(M);
    O.Add('messages', A);
    AssertTrue('запись файла: ',
      WriteTextFile(SessionFile('s3'), O.FormatJSON([foUseTabChar]), Err));
  finally
    O.Free;
  end;
  Msgs := nil;
  Plan := nil;
  AssertTrue('загрузка схемы 1: ' + Err, LoadSession(FDir, 's3', Msgs, Plan, Err));
  AssertEquals('число сообщений', 1, Length(Msgs));
  AssertEquals('роль', Ord(mrUser), Ord(Msgs[0].Role));
  AssertEquals('текст', 'старое сообщение', Msgs[0].Content);
end;

{ Невалидный план («steps»: строка «x») — ошибка загрузки, Plan = nil. }
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
    S := 'привет';
    M.Add('content', S);
    A.Add(M);
    O.Add('messages', A);
    P := TJSONObject.Create;
    P.Add('steps', 'x');
    O.Add('plan', P);
    AssertTrue('запись файла: ',
      WriteTextFile(SessionFile('s4'), O.FormatJSON([foUseTabChar]), Err));
  finally
    O.Free;
  end;

  Msgs := nil;
  Plan := nil;
  AssertFalse('невалидный план — ошибка',
    LoadSession(FDir, 's4', Msgs, Plan, Err));
  AssertTrue('текст ошибки', Err <> '');
  AssertNull('план nil', Plan);
end;

{ Следующий номер субагента: пустой каталог → 1; после файлов
  base_sub_1.json и base_sub_3.json → 4; посторонние файлы не влияют. }
procedure TSessionTests.TestNextSubagentNum;
var
  Err: string;
begin
  AssertEquals('пустой каталог', 1, NextSubagentNum(FDir, 'base'));
  AssertTrue('запись 1: ', WriteTextFile(SessionFile('base_sub_1'), '{}', Err));
  AssertTrue('запись 3: ', WriteTextFile(SessionFile('base_sub_3'), '{}', Err));
  AssertTrue('посторонний файл: ', WriteTextFile(SessionFile('other'), '{}', Err));
  AssertTrue('файл шага: ', WriteTextFile(SessionFile('base_step_s1'), '{}', Err));
  AssertEquals('после файлов', 4, NextSubagentNum(FDir, 'base'));
end;

{ Имя файла сессии субагента: пустой каталог → <база>_sub_1;
  после файла base2_sub_1.json → base2_sub_2. }
procedure TSessionTests.TestSubagentSessionId;
var
  Err: string;
begin
  AssertEquals('пустой каталог', 'base2_sub_1', SubagentSessionId(FDir, 'base2'));
  AssertTrue('запись: ', WriteTextFile(SessionFile('base2_sub_1'), '{}', Err));
  AssertEquals('после файла', 'base2_sub_2', SubagentSessionId(FDir, 'base2'));
end;

{ Имя файла сессии шага плана: <база>_step_<id>. }
procedure TSessionTests.TestStepSessionId;
begin
  AssertEquals('имя', 'sess_step_s2', StepSessionId('sess', 's2'));
end;

{ Сессия попытки шага: первая попытка сохраняется под прежним именем
  <база>_step_<id> (совместимость с PlanStepFixAttempts = 0), повторные —
  с суффиксом _try<N>, поэтому попытки не затирают друг друга. }
procedure TSessionTests.TestStepSessionIdTry;
begin
  AssertEquals('первая попытка', 'sess_step_s2',
    StepSessionIdTry('sess', 's2', 1));
  AssertEquals('та же, что StepSessionId', StepSessionId('sess', 's2'),
    StepSessionIdTry('sess', 's2', 1));
  AssertEquals('вторая попытка', 'sess_step_s2_try2',
    StepSessionIdTry('sess', 's2', 2));
  AssertEquals('третья попытка', 'sess_step_s2_try3',
    StepSessionIdTry('sess', 's2', 3));
  AssertEquals('номер 0 — первая', 'sess_step_s2',
    StepSessionIdTry('sess', 's2', 0));
  AssertTrue('файл попытки вспомогательный',
    IsAuxSessionFile(StepSessionIdTry('sess', 's2', 2) + '.json'));
end;

{ Сессия фазы анализа: <база>_analysis; такие файлы не попадают в ListSessions
  (в имени есть '_analysis'), т.е. не выглядят как обычные сессии диалога. }
procedure TSessionTests.TestAnalysisSessionId;
begin
  AssertEquals('имя', 'base_analysis', AnalysisSessionId('base'));
  AssertTrue('файл анализа вспомогательный',
    IsAuxSessionFile(AnalysisSessionId('base') + '.json'));
  AssertFalse('основная сессия не вспомогательная',
    IsAuxSessionFile('20250101-120000-ab12cd.json'));
end;

{ Файл вспомогательной сессии: имя содержит '_sub_' или '_step_'. }
procedure TSessionTests.TestIsAuxSessionFile;
begin
  AssertTrue('субагент', IsAuxSessionFile('x_sub_1.json'));
  AssertTrue('шаг', IsAuxSessionFile('x_step_s1.json'));
  AssertFalse('основная сессия', IsAuxSessionFile('20250101-120000-ab12cd.json'));
end;

{ ListSessions не включает вспомогательные файлы (субагенты, шаги). }
procedure TSessionTests.TestListSessionsSkipsAux;
var
  Msgs: TMessages;
  Err: string;
  Text: string;
begin
  Err := '';
  SetLength(Msgs, 1);
  Msgs[0].Role := mrUser;
  Msgs[0].Content := 'привет';
  AssertTrue('основная: ' + Err,
    SaveSession(FDir, 'auxmain', 'test-model', Msgs, nil, Err));
  AssertTrue('субагент: ' + Err,
    SaveSession(FDir, 'auxmain_sub_1', 'test-model', Msgs, nil, Err));
  AssertTrue('шаг: ' + Err,
    SaveSession(FDir, 'auxmain_step_s1', 'test-model', Msgs, nil, Err));
  AssertTrue('список: ', ListSessions(FDir, Text));
  AssertEquals('только основная сессия', 'auxmain' + sLineBreak, Text);
end;

{ Журнал контекста: AppendJournalEntry создаёт файл <Dir>/<Id>.jsonl,
  запись — одна валидная JSON-строка с переводом строки в конце. }
procedure TSessionTests.TestJournalEntryWritesFile;
var
  Err, Path, Text: string;
  D: TJSONData;
begin
  Err := '';
  Path := JournalFile(FDir, 'j1');
  AssertFalse('файла ещё нет', FileExists(Path));
  AssertTrue('запись журнала: ' + Err,
    AppendJournalEntry(FDir, 'j1', 100, 20, Err));
  AssertEquals('ошибка пуста', '', Err);
  AssertTrue('файл создан', FileExists(Path));
  AssertTrue('чтение файла: ' + Err, ReadTextFile(Path, Text, Err));
  AssertTrue('перевод строки в конце',
    (Length(Text) > Length(sLineBreak)) and
    (Copy(Text, Length(Text) - Length(sLineBreak) + 1, Length(sLineBreak)) =
      sLineBreak));
  D := nil;
  AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
  try
    AssertTrue('объект', D is TJSONObject);
  finally
    D.Free;
  end;
end;

{ Поля записи журнала: operation = Flash, непустое время в формате
  yyyy-mm-dd hh:nn:ss, размеры контекста и части — числа. }
procedure TSessionTests.TestJournalEntryFields;
var
  Err, Text: string;
  D: TJSONData;
begin
  Err := '';
  AssertTrue('запись журнала: ' + Err,
    AppendJournalEntry(FDir, 'j1', 120, 30, Err));
  AssertTrue('чтение файла: ' + Err,
    ReadTextFile(JournalFile(FDir, 'j1'), Text, Err));
  D := nil;
  AssertTrue('JSON: ' + Err, ParseJSON(Text, D, Err));
  try
    AssertEquals('operation', 'Flash', JStr(D, 'operation', ''));
    AssertEquals('time не пусто', 19, Length(JStr(D, 'time', '')));
    AssertEquals('context', 120, JInt(D, 'context', -1));
    AssertEquals('part', 30, JInt(D, 'part', -1));
  finally
    D.Free;
  end;
end;

{ Повторный вызов дописывает запись новой строкой, а не перезаписывает файл. }
procedure TSessionTests.TestJournalEntryAppends;
var
  Err, Text: string;
  L: TStringList;
  D: TJSONData;
begin
  Err := '';
  AssertTrue('запись 1: ' + Err, AppendJournalEntry(FDir, 'j1', 100, 20, Err));
  AssertTrue('запись 2: ' + Err, AppendJournalEntry(FDir, 'j1', 180, 80, Err));
  AssertTrue('чтение файла: ' + Err,
    ReadTextFile(JournalFile(FDir, 'j1'), Text, Err));
  L := TStringList.Create;
  try
    L.Text := Text;
    AssertEquals('две строки', 2, L.Count);
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

{ Пути журнала контекста: каталог <WorkDir>/.mirmid/journal (отдельно от
  sessions, чтобы ListSessions и *.json сессий не затрагивались) и файл
  записи <Dir>/<Id>.jsonl. }
procedure TSessionTests.TestJournalPaths;
begin
  AssertEquals('каталог журнала',
    IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'journal',
    JournalDir(FDir));
  AssertEquals('файл записи',
    IncludeTrailingPathDelimiter(JournalDir(FDir)) + 'j9.jsonl',
    JournalFile(JournalDir(FDir), 'j9'));
  AssertTrue('журнал вне каталога сессий',
    JournalDir(FDir) <> SessionDir(FDir));
end;

{ Сбой записи журнала не глотается: AppendJournalEntry возвращает False и
  заполняет Err, чтобы SaveSessionWithJournal мог отдать prJournalFailed.
  Здесь каталог журнала создать нельзя — на его месте лежит файл. }
procedure TSessionTests.TestJournalEntryErrorReported;
var
  Err, Blocked: string;
begin
  Err := '';
  Blocked := IncludeTrailingPathDelimiter(FDir) + 'blocked';
  AssertTrue('файл-заглушка: ' + Err, WriteTextFile(Blocked, 'x', Err));
  Err := '';
  AssertFalse('запись в журнал невозможна',
    AppendJournalEntry(IncludeTrailingPathDelimiter(Blocked) + 'journal',
      'j1', 10, 5, Err));
  AssertTrue('причина сообщена', Err <> '');
  AssertFalse('файл журнала не создан',
    FileExists(JournalFile(IncludeTrailingPathDelimiter(Blocked) + 'journal',
      'j1')));
end;

{ --no-session: сохранять нечего — не создаётся ни файл сессии, ни файл
  журнала (и даже каталог журнала). Контроль: включённый режим пишет оба. }
procedure TSessionTests.TestNoJournalWhenNoSession;
var
  Msgs: TMessages;
  Err, SessPath: string;
begin
  Err := '';
  SetLength(Msgs, 1);
  Msgs[0].Role := mrUser;
  Msgs[0].Content := 'привет';
  SessPath := IncludeTrailingPathDelimiter(SessionDir(FDir)) + 'j2.json';
  AssertTrue('режим --no-session: пропуск',
    SaveSessionWithJournal(FDir, 'j2', 'test-model', Msgs, nil, True,
      40, 10, Err) = prSkipped);
  AssertEquals('ошибка пуста', '', Err);
  AssertFalse('файла сессии нет', FileExists(SessPath));
  AssertFalse('файла журнала нет',
    FileExists(JournalFile(JournalDir(FDir), 'j2')));
  AssertFalse('каталога журнала нет', DirectoryExists(JournalDir(FDir)));
  { Контроль: без --no-session сохраняются и сессия, и запись журнала. }
  AssertTrue('обычный режим: запись',
    SaveSessionWithJournal(FDir, 'j2', 'test-model', Msgs, nil, False,
      40, 10, Err) = prOk);
  AssertEquals('ошибка пуста (2)', '', Err);
  AssertTrue('файл сессии создан', FileExists(SessPath));
  AssertTrue('файл журнала создан',
    FileExists(JournalFile(JournalDir(FDir), 'j2')));
end;

initialization
  RegisterTest(TSessionTests);

end.
