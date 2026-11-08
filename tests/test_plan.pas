unit test_plan;
{ Тесты модели плана (mirmid.plan): JSON-(де)сериализация, валидация,
  операции со шагами, разбор ответа модели, рендер, отчёт, подсказки. }

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
  AssertTrue('done по имени', PlanStatusFromName('done', St));
  AssertEquals('done', Ord(psDone), Ord(St));
  AssertTrue('регистр не важен', PlanStatusFromName('IN_PROGRESS', St));
  AssertEquals('in_progress', Ord(psInProgress), Ord(St));
  AssertFalse('неизвестное имя', PlanStatusFromName('weird', St));
end;

procedure TPlanTests.TestJsonRoundTrip;
var
  P, P2: TPlan;
  O: TJSONObject;
  Err: string;
begin
  P := TPlan.Create;
  try
    P.AddStep('прочитать файл');
    P.AddStep('выполнить команду');
    P.AddStep('написать отчёт');
    P.SetStatus('s1', psDone, 'файл прочитан');
    P.SetStatus('s2', psFailed, 'ошибка 127');
    P.SetStatus('s3', psSkipped, '');
    O := P.ToJSON;
    try
      P2 := TPlan.FromJSON(O, Err);
      AssertTrue('план разобран', P2 <> nil);
      AssertEquals('ошибка пуста', '', Err);
      AssertEquals('число шагов', 3, Length(P2.Steps));
      AssertEquals('id 1', 's1', P2.Steps[0].Id);
      AssertEquals('описание 1', 'прочитать файл', P2.Steps[0].Description);
      AssertEquals('статус 1', Ord(psDone), Ord(P2.Steps[0].Status));
      AssertEquals('результат 1', 'файл прочитан', P2.Steps[0].Result);
      AssertEquals('статус 2', Ord(psFailed), Ord(P2.Steps[1].Status));
      AssertEquals('результат 2', 'ошибка 127', P2.Steps[1].Result);
      AssertEquals('статус 3', Ord(psSkipped), Ord(P2.Steps[2].Status));
      AssertEquals('результат 3 пуст', '', P2.Steps[2].Result);
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
    AssertNull('нет steps — nil', P);
    AssertTrue('текст ошибки', Err <> '');
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
    AssertNull('пустой steps — nil', P);
    AssertTrue('текст ошибки', Err <> '');
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
    AssertNull('пустое description — nil', P);
    AssertTrue('текст ошибки', Err <> '');
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
    S1.Add('description', 'один');
    S2 := TJSONObject.Create;
    S2.Add('id', 'x');
    S2.Add('description', 'два');
    A.Add(S1);
    A.Add(S2);
    O.Add('steps', A);
    P := TPlan.FromJSON(O, Err);
    AssertNull('дубли id — nil', P);
    AssertTrue('текст ошибки', Err <> '');
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
    S.Add('description', 'шаг');
    S.Add('status', 'weird');
    A.Add(S);
    O.Add('steps', A);
    P := TPlan.FromJSON(O, Err);
    AssertNull('неизвестный статус — nil', P);
    AssertTrue('текст ошибки', Err <> '');
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
    S1.Add('description', 'первый');
    S2 := TJSONObject.Create;
    S2.Add('description', 'второй');
    S3 := TJSONObject.Create;
    S3.Add('id', 'custom');
    S3.Add('description', 'третий');
    A.Add(S1);
    A.Add(S2);
    A.Add(S3);
    O.Add('steps', A);
    P := TPlan.FromJSON(O, Err);
    AssertTrue('план разобран', P <> nil);
    try
      AssertEquals('ошибка пуста', '', Err);
      AssertEquals('число шагов', 3, Length(P.Steps));
      AssertEquals('авто-id 1', 's1', P.Steps[0].Id);
      AssertEquals('авто-id 2', 's2', P.Steps[1].Id);
      AssertEquals('явный id', 'custom', P.Steps[2].Id);
      AssertEquals('статус по умолчанию', Ord(psPending), Ord(P.Steps[0].Status));
      AssertEquals('результат по умолчанию', '', P.Steps[0].Result);
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
    AssertEquals('первый индекс', 0, P.AddStep('первый'));
    AssertEquals('второй индекс', 1, P.AddStep('второй'));
    AssertEquals('число шагов', 2, Length(P.Steps));
    AssertEquals('авто-id 1', 's1', P.Steps[0].Id);
    AssertEquals('авто-id 2', 's2', P.Steps[1].Id);
    AssertEquals('статус', Ord(psPending), Ord(P.Steps[0].Status));
    AssertEquals('описание', 'первый', P.Steps[0].Description);
    AssertEquals('результат пуст', '', P.Steps[0].Result);
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
    AssertEquals('находит s1', 0, P.FindStep('s1'));
    AssertEquals('находит s2', 1, P.FindStep('s2'));
    AssertEquals('нет s3', -1, P.FindStep('s3'));
    AssertEquals('пустой id', -1, P.FindStep(''));
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
    AssertTrue('удаляет s2', P.RemoveStep('s2'));
    AssertEquals('осталось два', 2, Length(P.Steps));
    AssertEquals('порядок 1', 's1', P.Steps[0].Id);
    AssertEquals('порядок 2', 's3', P.Steps[1].Id);
    AssertFalse('повторное удаление', P.RemoveStep('s2'));
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
    AssertTrue('перестановка', P.Reorder(['s3', 's1', 's2']));
    AssertEquals('новый порядок 1', 's3', P.Steps[0].Id);
    AssertEquals('новый порядок 2', 's1', P.Steps[1].Id);
    AssertEquals('новый порядок 3', 's2', P.Steps[2].Id);
    AssertFalse('меньше id', P.Reorder(['s1', 's2']));
    AssertFalse('дубли id', P.Reorder(['s1', 's1', 's2']));
    AssertFalse('чужой id', P.Reorder(['s1', 's2', 's9']));
    AssertEquals('план не изменился', 's3', P.Steps[0].Id);
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
    AssertTrue('в progress', P.SetStatus('s1', psInProgress, ''));
    AssertEquals('статус progress', Ord(psInProgress), Ord(P.Steps[0].Status));
    AssertTrue('в done с результатом', P.SetStatus('s1', psDone, 'готово'));
    AssertEquals('статус done', Ord(psDone), Ord(P.Steps[0].Status));
    AssertEquals('результат', 'готово', P.Steps[0].Result);
    AssertFalse('нет шага', P.SetStatus('s9', psDone, ''));
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
    AssertEquals('первый pending', 0, P.NextPending);
    P.SetStatus('s1', psDone, '');
    AssertEquals('второй pending', 1, P.NextPending);
    P.SetStatus('s2', psFailed, '');
    P.SetStatus('s3', psSkipped, '');
    AssertEquals('pending нет', -1, P.NextPending);
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
  S := 'Вот план:' + LineEnding +
       '```json' + LineEnding +
       '{"steps":[{"description":"a"},{"description":"b"}]}' + LineEnding +
       '```' + LineEnding +
       'Готово.';
  AssertEquals('блок из ограждения',
    '{"steps":[{"description":"a"},{"description":"b"}]}',
    ExtractJSONBlock(S));
end;

procedure TPlanTests.TestExtractJSONBlockSurrounding;
var
  S: string;
begin
  S := 'Разберём задачу. План: {"steps": [{"description": "x"}]} — дальше текст.';
  AssertEquals('блок среди текста',
    '{"steps": [{"description": "x"}]}',
    ExtractJSONBlock(S));
end;

procedure TPlanTests.TestExtractJSONBlockMissing;
begin
  AssertEquals('нет json', '', ExtractJSONBlock('просто текст без json'));
  AssertEquals('пустая строка', '', ExtractJSONBlock(''));
  AssertEquals('незакрытый блок', '', ExtractJSONBlock('текст {незакрытый'));
end;

procedure TPlanTests.TestParsePlanFromTextValid;
var
  S: string;
  Err: string;
  P: TPlan;
begin
  S := '```json' + LineEnding +
       '{"steps":[{"description":"сделать"},{"description":"проверить"}]}' + LineEnding +
       '```';
  P := ParsePlanFromText(S, Err);
  AssertTrue('план разобран', P <> nil);
  try
    AssertEquals('ошибка пуста', '', Err);
    AssertEquals('число шагов', 2, Length(P.Steps));
    AssertEquals('авто-id', 's1', P.Steps[0].Id);
    AssertEquals('описание', 'сделать', P.Steps[0].Description);
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestParsePlanFromTextInvalid;
var
  Err: string;
  P: TPlan;
begin
  P := ParsePlanFromText('без json', Err);
  AssertNull('нет json — nil', P);
  AssertTrue('ошибка 1', Err <> '');
  P := ParsePlanFromText('{"steps": []}', Err);
  AssertNull('пустой план — nil', P);
  AssertTrue('ошибка 2', Err <> '');
  P := ParsePlanFromText('{"steps": "не массив"}', Err);
  AssertNull('steps не массив — nil', P);
  AssertTrue('ошибка 3', Err <> '');
end;

procedure TPlanTests.TestRender;
var
  P: TPlan;
begin
  P := TPlan.Create;
  try
    P.AddStep('первый');
    P.AddStep('второй');
    P.SetStatus('s1', psDone, 'готово');
    P.SetStatus('s2', psInProgress, '');
    AssertEquals('рендер',
      '1. [done] первый — готово' + LineEnding + '2. [in_progress] второй',
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
    AssertEquals('смешанная сводка', '3/5 выполнено, 1 ошибка, 1 пропущено', P.Summary);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.SetStatus('s1', psDone, '');
    P.SetStatus('s2', psDone, '');
    AssertEquals('только выполнено', '2/2 выполнено', P.Summary);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    AssertEquals('пустой план', '0/0 выполнено', P.Summary);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.SetStatus('s1', psFailed, '');
    P.SetStatus('s2', psFailed, '');
    AssertEquals('плюрализация', '0/2 выполнено, 2 ошибки', P.Summary);
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
    P.AddStep('сделать');
    P.SetStatus('s1', psDone, 'готово');
    Expected := 'Задача: задача' + LineEnding + LineEnding +
                'План:' + LineEnding +
                P.Render + LineEnding + LineEnding +
                'Сводка: ' + P.Summary;
    AssertEquals('отчёт', Expected, BuildPlanReport(P, 'задача'));
  finally
    P.Free;
  end;
end;

procedure TPlanTests.TestPrompts;
var
  SP: string;
begin
  AssertTrue('есть подсказка планировщика', Length(PLANNER_SYSTEM_PROMPT) > 0);
  AssertTrue('JSON в подсказке планировщика', Pos('{"steps"', PLANNER_SYSTEM_PROMPT) > 0);
  SP := BuildStepPrompt('задача', '1. [pending] шаг', 'шаг');
  AssertTrue('задача в подсказке шага', Pos('задача', SP) > 0);
  AssertTrue('план в подсказке шага', Pos('1. [pending] шаг', SP) > 0);
  AssertTrue('цель в подсказке шага', Pos('Цель текущего шага: шаг', SP) > 0);
  AssertTrue('есть подсказка отчётчика', Length(REPORT_SYSTEM_PROMPT) > 0);
  AssertTrue('есть подсказка аналитика', Length(PLANNER_ANALYSIS_PROMPT) > 0);
  AssertTrue('аналитик читает файлы', Pos('файл', PLANNER_ANALYSIS_PROMPT) > 0);
  SP := BuildPlanPrompt('моя задача', 'анализ: всё готово');
  AssertTrue('задача в запросе плана', Pos('моя задача', SP) > 0);
  AssertTrue('анализ в запросе плана', Pos('анализ: всё готово', SP) > 0);
  AssertTrue('JSON в запросе плана', Pos('{"steps"', SP) > 0);
  SP := BuildPlanPrompt('моя задача', '');
  AssertTrue('пустой анализ не ломает запрос', Pos('моя задача', SP) > 0);
end;
{ Truncate(0) не ограничивает план: все шаги сохраняются. }
procedure TPlanTests.TestTruncateZero;
var
  P: TPlan;
  Removed: Integer;
begin
  P := TPlan.Create;
  try
    P.AddStep('шаг 1');
    P.AddStep('шаг 2');
    P.AddStep('шаг 3');
    P.AddStep('шаг 4');
    P.AddStep('шаг 5');
    Removed := P.Truncate(0);
    AssertEquals('ничего не удалено', 0, Removed);
    AssertEquals('пять шагов', 5, Length(P.Steps));
    AssertEquals('первый шаг', 'шаг 1', P.Steps[0].Description);
    AssertEquals('последний шаг', 'шаг 5', P.Steps[4].Description);
  finally
    P.Free;
  end;
end;
{ Truncate(N) обрезает план до N шагов, удаляя лишние. }
procedure TPlanTests.TestTruncateN;
var
  P: TPlan;
  Removed: Integer;
begin
  P := TPlan.Create;
  try
    P.AddStep('шаг 1');
    P.AddStep('шаг 2');
    P.AddStep('шаг 3');
    P.AddStep('шаг 4');
    P.AddStep('шаг 5');
    Removed := P.Truncate(3);
    AssertEquals('удалено два', 2, Removed);
    AssertEquals('осталось три', 3, Length(P.Steps));
    AssertEquals('первый шаг', 'шаг 1', P.Steps[0].Description);
    AssertEquals('второй шаг', 'шаг 2', P.Steps[1].Description);
    AssertEquals('третий шаг', 'шаг 3', P.Steps[2].Description);
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    Removed := P.Truncate(5);
    AssertEquals('больше N — ничего не удалено', 0, Removed);
    AssertEquals('оба шага на месте', 2, Length(P.Steps));
  finally
    P.Free;
  end;
  P := TPlan.Create;
  try
    P.AddStep('a');
    P.AddStep('b');
    P.AddStep('c');
    Removed := P.Truncate(1);
    AssertEquals('удалено два', 2, Removed);
    AssertEquals('остался один', 1, Length(P.Steps));
    AssertEquals('первый шаг', 'a', P.Steps[0].Description);
  finally
    P.Free;
  end;
end;

initialization
  RegisterTest(TPlanTests);

end.
