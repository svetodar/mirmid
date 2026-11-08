unit mirmid.plan;
{ Модель данных плана для режима планирования: шаги со статусами,
  JSON-(де)сериализация, разбор ответа модели, человекочитаемый рендер,
  детерминированный отчёт и подсказки планировщика.
  Зависимости: SysUtils, fpjson, mirmid.types (без сетевого слоя). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, mirmid.types;

type
  { Статус шага плана. }
  TPlanStepStatus = (psPending, psInProgress, psDone, psFailed, psSkipped);

  { Один шаг плана. }
  TPlanStep = record
    Id: string;
    Description: string;
    Status: TPlanStepStatus;
    Result: string;
  end;

  { Список шагов плана (FPC не позволяет объявлять поле/свойство класса
    открытым массивом напрямую — нужен именованный тип). }
  TPlanSteps = array of TPlanStep;

  { План: упорядоченный список шагов. }
  TPlan = class
  private
    FSteps: TPlanSteps;
  public
    constructor Create;
    property Steps: TPlanSteps read FSteps;
    { Добавляет шаг с авто-id sN (N = количество шагов + 1) и статусом
      psPending; возвращает индекс нового шага. }
    function AddStep(const ADesc: string): Integer;
    { Индекс шага по id или -1. }
    function FindStep(const AId: string): Integer;
    { Удаляет шаг по id; False, если шага нет. }
    function RemoveStep(const AId: string): Boolean;
    { Новый порядок шагов по id; False, если множество id не совпадает
      с шагами плана (план не меняется). }
    function Reorder(const AOrder: array of string): Boolean;
    { Ставит статус и результат шага; False, если шага нет. }
    function SetStatus(const AId: string; AStatus: TPlanStepStatus; const AResult: string): Boolean;
    { Индекс первого шага со статусом psPending или -1. }
    function NextPending: Integer;
    { Количество шагов с заданным статусом. }
    function CountByStatus(AStatus: TPlanStepStatus): Integer;
    { Усекает план до AMax шагов (удаляет хвост); возвращает число
      удалённых шагов (0, если AMax <= 0 или план уже короче AMax). }
    function Truncate(AMax: Integer): Integer;
    { JSON: объект с массивом steps; у каждого шага id, description, status, result. }
    function ToJSON: TJSONObject;
    { Обратный разбор; nil, если невалидно (Err — текст ошибки). }
    class function FromJSON(D: TJSONData; out Err: string): TPlan;
    { Человекочитаемый план: по строке на шаг
      «N. [статус] описание — результат» (результат — только если непустой). }
    function Render: string;
    { Сводка: «3/5 выполнено, 1 ошибка, 1 пропущено» (только ненулевые
      категории, порядок: выполнено / ошибка / пропущено). }
    function Summary: string;
  end;

{ Имя статуса в нотации JSON: pending, in_progress, done, failed, skipped. }
function PlanStatusName(S: TPlanStepStatus): string;
{ Статус по имени (регистр не важен); False, если имя неизвестно. }
function PlanStatusFromName(const S: string; out St: TPlanStepStatus): Boolean;

{ Первый JSON-объект в тексте (в т.ч. внутри ```json-ограждения и с
  окружающим текстом); пустая строка, если не найден. }
function ExtractJSONBlock(const S: string): string;
{ План из ответа модели: ExtractJSONBlock + разбор JSON + FromJSON;
  nil при ошибке (Err — текст ошибки). }
function ParsePlanFromText(const S: string; out Err: string): TPlan;

{ Детерминированный отчёт: задача, рендер плана, сводка. }
function BuildPlanReport(const Plan: TPlan; const Task: string): string;

{ Подсказка аналитика: до составления плана изучить задачу и её окружение
  (только чтение) и вернуть структурированный анализ; сам план не строить.
  Инструменты при этом доступны по правам сессии — запрет на изменения задаёт
  подсказка, а не отключение инструментов. }
const
  PLANNER_ANALYSIS_PROMPT =
    'Ты — аналитик планировщика. До составления плана изучи задачу и её ' +
    'окружение и верни предварительный анализ. Работай только на чтение: ' +
    'просматривай каталоги, читай файлы, ищи по содержимому и, если это ' +
    'разрешено, выполняй команды только для просмотра (например git status, ' +
    'git log, git diff); ничего не изменяй. Если задача ссылается на файл ' +
    '(например, план), обязательно прочитай его. Выясни: 1) в чём суть ' +
    'задачи и что требуется на самом деле; 2) что уже сделано и какие ' +
    'файлы, сущности и ограничения относятся к задаче; 3) какие факты нужны ' +
    'для плана и есть риски; 4) что конкретно предстоит сделать. Опирайся ' +
    'только на факты из инструментов и не выдумывай. Не составляй ' +
    'нумерованный план шагов — это сделает планировщик. Отвечай по-русски, ' +
    'структурировано и по делу.';

{ Подсказка планировщика: разбить задачу на атомарные шаги и вернуть
  только JSON-массив steps (описание каждого шага) без лишнего текста. }
const
  PLANNER_SYSTEM_PROMPT =
    'Ты — планировщик. Разбей задачу на атомарные шаги: каждый шаг — одно ' +
    'конкретное действие (один вызов инструмента или одна короткая команда), ' +
    'выполнимое без дополнительных раздумий. Перечисли шаги в порядке ' +
    'выполнения. Опирайся на переданный предварительный анализ задачи и не ' +
    'противоречь фактам из него. Верни ТОЛЬКО JSON без пояснений, без ' +
    'markdown-ограждений и без лишнего текста: ' +
    '{"steps": [{"description": "..."}]}. ' +
    'В description — краткое описание шага (до 100 символов); других полей ' +
    'не добавляй.';

{ Запрос фазы плана: задача и результаты предварительного анализа (может
  быть пустым). Модель должна вернуть только JSON-план. }
function BuildPlanPrompt(const Task, Analysis: string): string;

{ Подсказка шага: общая задача, текущий план (отрендеренный), цель
  текущего шага, инструкция выполнить шаг и вернуть краткий результат. }
function BuildStepPrompt(const Task, PlanRender, StepDesc: string): string;

{ Подсказка отчётчика: итоговый ответ по состоянию плана (что сделано,
  что пропущено, что упало). }
const
  REPORT_SYSTEM_PROMPT =
    'Ты — отчётчик. По состоянию плана дай итоговый ответ по задаче: ' +
    'что сделано, что пропущено, что упало и каков итог. ' +
    'Отвечай по-русски, кратко и по делу, без описания процесса.';

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
  { Множество id должно совпадать с шагами плана: без дублей и чужих id. }
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

{ Строка по ключу JSON-объекта; '' — ключа нет или значение null. }
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
    Err := 'план должен быть JSON-объектом';
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
    Err := 'нет массива "steps"';
    Exit;
  end;
  A := TJSONArray(Item);
  if A.Count = 0 then
  begin
    Err := 'план пуст: нужен минимум один шаг';
    Exit;
  end;
  P := TPlan.Create;
  try
    for I := 0 to A.Count - 1 do
    begin
      Item := A.Items[I];
      if not (Item is TJSONObject) then
      begin
        Err := 'шаг ' + IntToStr(I + 1) + ' должен быть JSON-объектом';
        P.Free;
        Exit;
      end;
      StepO := TJSONObject(Item);
      Desc := JStrLocal(StepO, 'description');
      if Trim(Desc) = '' then
      begin
        Err := 'шаг ' + IntToStr(I + 1) + ': пустое "description"';
        P.Free;
        Exit;
      end;
      { id опционален: автоприсваивается sN по порядку шагов. }
      Id := JStrLocal(StepO, 'id');
      if Id = '' then
        Id := 's' + IntToStr(I + 1);
      if P.FindStep(Id) >= 0 then
      begin
        Err := 'дублирующийся id шага: ' + Id;
        P.Free;
        Exit;
      end;
      { status опционален: по умолчанию pending, неизвестный — ошибка. }
      StName := JStrLocal(StepO, 'status');
      if StName = '' then
        St := psPending
      else
      begin
        if not PlanStatusFromName(StName, St) then
        begin
          Err := 'шаг ' + IntToStr(I + 1) + ': неизвестный статус "' + StName + '"';
          P.Free;
          Exit;
        end;
      end;
      { result опционален: по умолчанию пустая строка. }
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
    { Кандидат: сбалансированный по скобкам блок, начинающийся с открывающей скобки. }
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
              { не JSON — ищем следующий кандидат }
            end;
          end;
        end;
      end;
      Inc(I);
    end;
    if not Found then
      I := Start + 1; { следующий кандидат — после этой открывающей скобки }
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
    Err := 'JSON-объект в тексте не найден';
    Exit;
  end;
  D := nil;
  try
    D := GetJSON(Block);
  except
    on E: Exception do
    begin
      Err := 'ошибка разбора JSON: ' + E.Message;
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

{ Русская плюрализация: 1 — One, 2–4 — Few, остальное — Many. }
function PluralNoun(N: Integer; const One, Few, Many: string): string;
var
  M100, M10: Integer;
begin
  M100 := N mod 100;
  M10 := N mod 10;
  if (M100 >= 11) and (M100 <= 14) then
    Result := Many
  else
    case M10 of
      1:    Result := One;
      2..4: Result := Few;
    else
      Result := Many;
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
  Result := IntToStr(Done) + '/' + IntToStr(Total) + ' выполнено';
  if Failed > 0 then
    Result := Result + ', ' + IntToStr(Failed) + ' ' +
              PluralNoun(Failed, 'ошибка', 'ошибки', 'ошибок');
  if Skipped > 0 then
    Result := Result + ', ' + IntToStr(Skipped) + ' пропущено';
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
    Result := 'Задача: ' + Task + LineEnding + LineEnding +
              'План:' + LineEnding +
              P.Render + LineEnding + LineEnding +
              'Сводка: ' + P.Summary;
  finally
    if (P <> nil) and (P <> Plan) then
      P.Free;
  end;
end;

function BuildPlanPrompt(const Task, Analysis: string): string;
begin
  Result := 'Задача: ' + Task + LineEnding + LineEnding;
  if Trim(Analysis) <> '' then
    Result := Result + 'Предварительный анализ задачи:' + LineEnding +
              Analysis + LineEnding + LineEnding +
              'Составь план выполнения задачи на основании этого анализа.'
  else
    Result := Result + 'Составь план выполнения задачи.';
  Result := Result + ' Верни только JSON в формате ' +
            '{"steps":[{"description":"..."}]}.';
end;

function BuildStepPrompt(const Task, PlanRender, StepDesc: string): string;
begin
  Result := 'Общая задача: ' + Task + LineEnding + LineEnding +
            'Текущий план:' + LineEnding + PlanRender + LineEnding + LineEnding +
            'Цель текущего шага: ' + StepDesc + LineEnding + LineEnding +
            'Выполни только этот шаг с помощью инструментов и верни краткий ' +
            'результат (1–3 предложения). Не выполняй другие шаги плана.';
end;

end.
