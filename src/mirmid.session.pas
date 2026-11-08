unit mirmid.session;
{ Сохранение и загрузка сессий диалога в <WorkDir>/.mirmid/sessions.
  Схема 2: поле plan (JSON плана или null); обратная совместимость
  со схемой 1 (без поля plan). Там же лежат вспомогательные файлы
  сессий субагентов (<база>_sub_<n>.json), шагов плана
  (<база>_step_<id>.json) и фазы анализа (<база>_analysis.json). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mirmid.types, mirmid.plan;

function SessionDir(const WorkDir: string): string;
{ Каталог журнала контекста: <WorkDir>/.mirmid/journal (вне sessions,
  чтобы *.json сессий и ListSessions не затрагивались). }
function JournalDir(const WorkDir: string): string;
{ Файл журнала сессии <Id>: <Dir>/<Id>.jsonl (по одной JSON-записи в строке). }
function JournalFile(const Dir, Id: string): string;
{ Дописывает в журнал сессии запись о сохранении: время, operation=Flash,
  размер контекста (ContextTokens) и размер части контекста этой записи
  (PartTokens), в токенах. }
function AppendJournalEntry(const Dir, Id: string;
  ContextTokens, PartTokens: Integer; out Err: string): Boolean;

type
  { Итог сохранения сессии вместе с журналом контекста. }
  TPersistResult = (
    prSkipped,        { сессии отключены (--no-session): ничего не записано }
    prSessionFailed,  { файл сессии не сохранён (журнал не тронут) }
    prJournalFailed,  { сессия сохранена, запись в журнал не удалась }
    prOk);            { сессия сохранена, журнал дописан }

{ Сохраняет сессию и сразу дописывает запись журнала контекста. В режиме
  --no-session (NoSession=True) не создаёт ни файла сессии, ни файла журнала.
  Err — причина сбоя для prSessionFailed/prJournalFailed. Исключение при
  записи журнала перехватывается здесь, чтобы CLI не выдал его за сбой
  сохранения сессии. }
function SaveSessionWithJournal(const WorkDir, Id, Model: string;
  const Msgs: TMessages; const Plan: TPlan; NoSession: Boolean;
  ContextTokens, PartTokens: Integer; out Err: string): TPersistResult;
{ Идентификатор вида 20250101-120000-ab12cd. }
function NewSessionId: string;
{ Следующий номер файла сессии субагента с базой <Base>:
  максимальный существующий номер среди файлов <Base>_sub_<n>.json + 1. }
function NextSubagentNum(const Dir, Base: string): Integer;
{ Имя (без расширения) файла сессии субагента: <Base>_sub_<n>. }
function SubagentSessionId(const Dir, Base: string): string;
{ Имя (без расширения) файла сессии шага плана: <Base>_step_<StepId>
  (так называется сессия первой попытки шага). }
function StepSessionId(const Base, StepId: string): string;
{ Имя (без расширения) файла сессии попытки шага: первая попытка — как
  StepSessionId (<Base>_step_<StepId>), повторные — с номером попытки
  <Base>_step_<StepId>_try<N> (N — номер попытки, начиная с 2), чтобы сессии
  попыток не затирали друг друга. TryNum <= 1 — первая попытка. }
function StepSessionIdTry(const Base, StepId: string; TryNum: Integer): string;
{ Имя (без расширения) файла сессии фазы анализа: <Base>_analysis. }
function AnalysisSessionId(const Base: string): string;
{ Файл вспомогательной сессии (субагента, шага плана или анализа):
  имя содержит '_sub_', '_step_' или '_analysis'. }
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
{ Значения строк — через переменные: fpjson сам экранирует и кодирует
  строки, а прямой литерал в аргументе Add рискует двойным перекодированием. }
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

{ Сессия попытки шага: номер попытки в имени файла. Первая попытка — прежнее
  имя (<Base>_step_<StepId>), чтобы одиночные шаги (PlanStepFixAttempts = 0)
  сохранялись как раньше; повторные — с суффиксом _try<N> (2, 3, ...).
  Суффикс идёт после '_step_', поэтому IsAuxSessionFile такие файлы тоже
  считает вспомогательными. }
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
    { План (схема 2): объект, если есть, иначе null. }
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
  { --no-session: сессия не сохраняется, журнал ей не нужен. }
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
    Err := 'не удалось прочитать сессию: ' + Err;
    Exit;
  end;
  if not ParseJSON(Text, D, Err) then
  begin
    Err := 'некорректный JSON сессии: ' + Err;
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
      Err := 'в сессии нет messages';
      Exit;
    end;
    JSONArrayToMessages(TJSONArray(ArrD), Msgs);
    { План (схема 2): нет поля (схема 1) или null — плана нет;
      план присутствует, но невалиден — ошибка загрузки. }
    if (PlanD <> nil) and not (PlanD is TJSONNull) then
    begin
      Plan := TPlan.FromJSON(PlanD, Err);
      if Plan = nil then
      begin
        Err := 'некорректный план в сессии: ' + Err;
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
