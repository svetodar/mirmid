unit mirmid.loopguard;
{ Loop-guard: детектор повторяющихся вызовов инструментов (основной механизм
  защиты от зацикливания). Чистый юнит без сети/LLM — легко тестируется.

  TLoopGuard хранит сигнатуру последнего вызова (имя + нормализованные
  JSON-аргументы) и счётчики подряд идущих повторов. Feed(name, args, result)
  возвращает действие (laNone/laWarn/laStop) и текст сообщения.

  Два вида сигнала:
  - сильный: одинаковый вызов с одинаковым результатом — явный цикл
    (пороги из конфига loop_warn/loop_stop, по умолчанию 3/5; 0 — выкл);
  - слабый: одинаковый вызов с разным результатом — поллинг процесса
    (фиксированные пороги LOOP_WEAK_WARN/LOOP_WEAK_STOP = 5/8, выше, чтобы
    не ловить легитимный поллинг). Слабый сигнал активен только тогда, когда
    включено соответствующее действие (warn/stop). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, mirmid.json, mirmid.util;

type
  { Результат проверки одного вызова инструмента. }
  TLoopAction = (laNone, laWarn, laStop);

  { Детектор повторяющихся вызовов инструментов.
    AStrongWarn/AStrongStop — пороги сильного сигнала (из конфига
    loop_warn/loop_stop; 0 — выкл соответствующее действие). Слабый сигнал
    (поллинг) использует фиксированные пороги LOOP_WEAK_WARN/LOOP_WEAK_STOP
    и активен, только если включено соответствующее действие. }
  TLoopGuard = class
  private
    FLastSig: string;
    FLastResult: string;
    FRepeat: Integer;      { подряд вызовов с одинаковой сигнатурой }
    FSameResult: Integer;  { подряд вызовов с одинаковой сигнатурой и результатом }
    FStrongWarn: Integer;
    FStrongStop: Integer;
    function Enabled: Boolean;
  public
    constructor Create(AStrongWarn, AStrongStop: Integer);
    { Сброс состояния (начало нового хода/сессии). }
    procedure Reset;
    { Проверить вызов инструмента: имя, JSON-аргументы, результат.
      Возвращает действие; AText — текст сообщения (пусто при laNone). }
    function Feed(const AName, AArgs, AResult: string; out AText: string): TLoopAction;
    { Текущие счётчики (для тестов и отладки). }
    property RepeatCount: Integer read FRepeat;
    property SameResultCount: Integer read FSameResult;
  end;

{ Пороги слабого сигнала (одинаковый вызов с разным результатом, поллинг). }
const
  LOOP_WEAK_WARN = 5;
  LOOP_WEAK_STOP = 8;

{ Сигнатура вызова: имя + «#0» + нормализованные JSON-аргументы
  (ключи объектов отсортированы, без лишних пробелов). Пустые или
  нераспознаваемые аргументы — как есть (после Trim). }
function CallSignature(const AName, AArgs: string): string;
{ Канонический JSON: ключи объектов отсортированы, без лишних пробелов. }
function CanonicalJSON(D: TJSONData): string;

implementation

{ Экранирование строки для вставки в JSON. }
function JSONEscape(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #13:  Result := Result + '\r';
      #12:  Result := Result + '\f';
    else
      if Ord(C) < 32 then
        Result := Result + Format('\u%04x', [Ord(C)])
      else
        Result := Result + C;
    end;
  end;
end;

{ Канонический JSON: ключи объектов отсортированы, без лишних пробелов. }
function CanonicalJSON(D: TJSONData): string;
var
  O: TJSONObject;
  A: TJSONArray;
  I: Integer;
  Keys: TStringList;
  K: string;
begin
  if D = nil then
    Exit('null');
  if D is TJSONNull then
    Exit('null');
  if D is TJSONBoolean then
    if D.AsBoolean then
      Exit('true')
    else
      Exit('false');
  if D is TJSONNumber then
    Exit(FloatToDotStr(D.AsFloat));
  if D is TJSONString then
    Exit('"' + JSONEscape(D.AsString) + '"');
  if D is TJSONArray then
  begin
    A := TJSONArray(D);
    Result := '[';
    for I := 0 to A.Count - 1 do
    begin
      if I > 0 then
        Result := Result + ',';
      Result := Result + CanonicalJSON(A.Items[I]);
    end;
    Exit(Result + ']');
  end;
  if D is TJSONObject then
  begin
    O := TJSONObject(D);
    Keys := TStringList.Create;
    try
      for I := 0 to O.Count - 1 do
        Keys.Add(O.Names[I]);
      Keys.Sort;
      Result := '{';
      for I := 0 to Keys.Count - 1 do
      begin
        if I > 0 then
          Result := Result + ',';
        K := Keys[I];
        Result := Result + '"' + JSONEscape(K) + '":' + CanonicalJSON(O.Elements[K]);
      end;
      Exit(Result + '}');
    finally
      Keys.Free;
    end;
  end;
  { Неизвестный тип — как есть. }
  Result := D.AsJSON;
end;

{ Сигнатура вызова: имя + «#0» + нормализованные JSON-аргументы. }
function CallSignature(const AName, AArgs: string): string;
var
  D: TJSONData;
  Err: string;
  T: string;
begin
  T := Trim(AArgs);
  if T = '' then
    Exit(AName + #0);
  if ParseJSONRepair(T, D, Err) then
  begin
    try
      Result := AName + #0 + CanonicalJSON(D);
    finally
      D.Free;
    end;
  end
  else
    Result := AName + #0 + T;
end;

{ Текст предупреждения (синтетическое user-сообщение). }
function WarnText(const AName: string; N: Integer): string;
begin
  Result := Format('Ты %d раз подряд вызвал %s с одинаковыми аргументами. ' +
    'Перестань повторяться: смени подход или заверши', [N, AName]);
end;

{ Текст остановки (aeError). }
function StopText(const AName: string; N: Integer): string;
begin
  Result := Format('обнаружен цикл: %d одинаковых вызовов %s', [N, AName]);
end;

constructor TLoopGuard.Create(AStrongWarn, AStrongStop: Integer);
begin
  inherited Create;
  FStrongWarn := AStrongWarn;
  FStrongStop := AStrongStop;
  Reset;
end;

procedure TLoopGuard.Reset;
begin
  FLastSig := '';
  FLastResult := '';
  FRepeat := 0;
  FSameResult := 0;
end;

function TLoopGuard.Enabled: Boolean;
begin
  Result := (FStrongWarn > 0) or (FStrongStop > 0);
end;

function TLoopGuard.Feed(const AName, AArgs, AResult: string; out AText: string): TLoopAction;
var
  Sig: string;
  ResultChanged: Boolean;
begin
  AText := '';
  Result := laNone;
  if not Enabled then
    Exit;
  Sig := CallSignature(AName, AArgs);
  ResultChanged := False;
  if Sig = FLastSig then
  begin
    Inc(FRepeat);
    if AResult = FLastResult then
      Inc(FSameResult)
    else
    begin
      FSameResult := 1;
      ResultChanged := True;
    end;
  end
  else
  begin
    FRepeat := 1;
    FSameResult := 1;
  end;
  FLastSig := Sig;
  FLastResult := AResult;

  { Сильный сигнал: одинаковый вызов с одинаковым результатом. }
  if (FStrongStop > 0) and (FSameResult >= FStrongStop) then
  begin
    AText := StopText(AName, FSameResult);
    Exit(laStop);
  end;
  if (FStrongWarn > 0) and (FSameResult >= FStrongWarn) then
  begin
    AText := WarnText(AName, FSameResult);
    Exit(laWarn);
  end;
  { Слабый сигнал: одинаковый вызов с разным результатом (поллинг).
    Срабатывает только когда результат изменился — при одинаковом
    результате это сильный цикл, его ловит сильный сигнал. }
  if ResultChanged then
  begin
    if (FStrongStop > 0) and (FRepeat >= LOOP_WEAK_STOP) then
    begin
      AText := StopText(AName, FRepeat);
      Exit(laStop);
    end;
    if (FStrongWarn > 0) and (FRepeat >= LOOP_WEAK_WARN) then
    begin
      AText := WarnText(AName, FRepeat);
      Exit(laWarn);
    end;
  end;
end;

end.
