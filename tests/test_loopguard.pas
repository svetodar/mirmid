unit test_loopguard;
{ Тесты loop-guard: детектора повторяющихся вызовов инструментов
  (src/mirmid.loopguard.pas). Чистые юнит-тесты без сети и LLM. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TLoopGuardTests = class(TTestCase)
  published
    procedure TestStrongRepeatWarnStop;
    procedure TestResetOnDifferentCall;
    procedure TestDifferentResultsPolling;
    procedure TestResultChangeResetsStrongCounter;
    procedure TestCustomThresholds;
    procedure TestWarnOnly;
    procedure TestStopOnly;
    procedure TestDisabled;
    procedure TestResetProcedure;
    procedure TestSignatureNormalization;
    procedure TestCallSignature;
    procedure TestCanonicalJSON;
    procedure TestMessages;
  end;

implementation

uses
  SysUtils, fpjson, mirmid.json, mirmid.loopguard;

{ Сильный сигнал: одинаковый вызов с одинаковым результатом,
  пороги по умолчанию warn=3, stop=5. }
procedure TLoopGuardTests.TestStrongRepeatWarnStop;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    AssertEquals('1-й вызов — тишина', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('2-й вызов — тишина', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('3-й вызов — warn', Ord(laWarn), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('4-й вызов — warn', Ord(laWarn), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('5-й вызов — stop', Ord(laStop), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('6-й вызов — stop', Ord(laStop), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
  finally
    G.Free;
  end;
end;

{ Другой вызов (имя или аргументы) сбрасывает счётчики повторов. }
procedure TLoopGuardTests.TestResetOnDifferentCall;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    AssertEquals('повторы до сброса', 2, G.RepeatCount);
    { Другой вызов сбрасывает счётчики. }
    AssertEquals('другой вызов — тишина', Ord(laNone), Ord(G.Feed('read_file', '{"path":"a"}', 'ok', T)));
    AssertEquals('счётчик повторов сброшен', 1, G.RepeatCount);
    { Повтор первого вызова считается заново (счётчик не помнит старые повторы). }
    AssertEquals('возврат к первому — тишина', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('повтор после сброса считается заново', 1, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Поллинг: один и тот же вызов, но результат каждый раз меняется —
  слабый сигнал с порогами LOOP_WEAK_WARN/LOOP_WEAK_STOP = 5/8. }
procedure TLoopGuardTests.TestDifferentResultsPolling;
var
  G: TLoopGuard;
  T: string;
  I: Integer;
  A: TLoopAction;
begin
  G := TLoopGuard.Create(3, 5);
  try
    for I := 1 to 8 do
    begin
      A := G.Feed('shell', '{"command":"ps"}', 'процесс ' + IntToStr(I), T);
      if I < 5 then
        AssertEquals('поллинг ' + IntToStr(I) + ' — тишина', Ord(laNone), Ord(A))
      else if I < 8 then
        AssertEquals('поллинг ' + IntToStr(I) + ' — warn', Ord(laWarn), Ord(A))
      else
        AssertEquals('поллинг ' + IntToStr(I) + ' — stop', Ord(laStop), Ord(A));
    end;
  finally
    G.Free;
  end;
end;

{ Смена результата сбрасывает сильный счётчик (совпадений),
  но счётчик повторов продолжает расти. }
procedure TLoopGuardTests.TestResultChangeResetsStrongCounter;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    AssertEquals('3-й с тем же результатом — warn', Ord(laWarn), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    { Смена результата сбрасывает сильный счётчик. }
    AssertEquals('смена результата — тишина', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'другое', T)));
    AssertEquals('сильный счётчик сброшен', 1, G.SameResultCount);
    AssertEquals('повторы продолжают считаться', 4, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Пороги берутся из конструктора (из конфига loop_warn/loop_stop). }
procedure TLoopGuardTests.TestCustomThresholds;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(2, 4);
  try
    AssertEquals('1-й вызов — тишина', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('2-й вызов — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('3-й вызов — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('4-й вызов — stop', Ord(laStop), Ord(G.Feed('x', '', 'r', T)));
  finally
    G.Free;
  end;
end;

{ Stop выключен (0) — предупреждения есть, остановки нет. }
procedure TLoopGuardTests.TestWarnOnly;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 0);
  try
    G.Feed('x', '', 'r', T);
    G.Feed('x', '', 'r', T);
    AssertEquals('3-й вызов — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('4-й вызов — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('5-й вызов — всё ещё warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('6-й вызов — всё ещё warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
  finally
    G.Free;
  end;
end;

{ Warn выключен (0) — только остановка. }
procedure TLoopGuardTests.TestStopOnly;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(0, 5);
  try
    G.Feed('x', '', 'r', T);
    G.Feed('x', '', 'r', T);
    AssertEquals('3-й вызов — тишина', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('4-й вызов — тишина', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('5-й вызов — stop', Ord(laStop), Ord(G.Feed('x', '', 'r', T)));
  finally
    G.Free;
  end;
end;

{ Оба порога 0 — детектор выключен, повторы не считаются. }
procedure TLoopGuardTests.TestDisabled;
var
  G: TLoopGuard;
  T: string;
  I: Integer;
begin
  G := TLoopGuard.Create(0, 0);
  try
    for I := 1 to 10 do
      AssertEquals('повтор ' + IntToStr(I) + ' — тишина', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('счётчик повторов не растёт', 0, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Reset сбрасывает состояние (начало нового хода). }
procedure TLoopGuardTests.TestResetProcedure;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('x', '', 'r', T);
    G.Feed('x', '', 'r', T);
    G.Reset;
    AssertEquals('повторы после Reset', 0, G.RepeatCount);
    AssertEquals('совпадения после Reset', 0, G.SameResultCount);
    AssertEquals('после Reset — считаем заново', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('счётчик после Reset', 1, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Порядок ключей и пробелы в JSON-аргументах не меняют сигнатуру;
  другие аргументы — другой вызов. }
procedure TLoopGuardTests.TestSignatureNormalization;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '{"a":1,"b":2}', 'r1', T);
    AssertEquals('другой порядок ключей — тот же вызов', Ord(laNone), Ord(G.Feed('shell', '{"b":2,"a":1}', 'r2', T)));
    AssertEquals('пробелы — тот же вызов', Ord(laNone), Ord(G.Feed('shell', '{"a": 1, "b": 2}', 'r3', T)));
    AssertEquals('повторы считаются', 3, G.RepeatCount);
    { Другие аргументы — другой вызов, счётчик сбрасывается. }
    AssertEquals('другие аргументы — тишина', Ord(laNone), Ord(G.Feed('shell', '{"a":1,"b":3}', 'r4', T)));
    AssertEquals('счётчик после других аргументов', 1, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Сигнатура вызова: пустые/нераспознаваемые аргументы — как есть. }
procedure TLoopGuardTests.TestCallSignature;
begin
  AssertEquals('пустые аргументы', 'shell'#0, CallSignature('shell', ''));
  AssertEquals('пробелы — пустые аргументы', 'shell'#0, CallSignature('shell', '   '));
  AssertEquals('нераспознаваемый JSON — как есть', 'shell'#0 + 'not json', CallSignature('shell', 'not json'));
  AssertEquals('порядок ключей не важен',
    CallSignature('shell', '{"a":1,"b":2}'), CallSignature('shell', '{"b":2,"a":1}'));
  AssertFalse('разные имена — разные сигнатуры',
    CallSignature('shell', '{}') = CallSignature('read', '{}'));
end;

{ Канонический JSON: ключи объектов отсортированы, без лишних пробелов. }
procedure TLoopGuardTests.TestCanonicalJSON;
var
  D: TJSONData;
  Err: string;
begin
  AssertTrue('разбор JSON', ParseJSON('{"b":2,"a":{"y":true,"x":[1,2]}}', D, Err));
  try
    AssertEquals('канонический JSON', '{"a":{"x":[1,2],"y":true},"b":2}', CanonicalJSON(D));
  finally
    D.Free;
  end;
end;

{ Тексты сообщений: warn содержит имя и счёт, stop — «обнаружен цикл». }
procedure TLoopGuardTests.TestMessages;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '', 'r', T);
    G.Feed('shell', '', 'r', T);
    AssertEquals('3-й вызов — warn', Ord(laWarn), Ord(G.Feed('shell', '', 'r', T)));
    AssertTrue('текст warn содержит имя', Pos('shell', T) > 0);
    AssertTrue('текст warn содержит счёт', Pos('3', T) > 0);
    G.Feed('shell', '', 'r', T);
    AssertEquals('5-й вызов — stop', Ord(laStop), Ord(G.Feed('shell', '', 'r', T)));
    AssertTrue('текст stop — «обнаружен цикл»', Pos('обнаружен цикл', T) > 0);
    AssertTrue('текст stop содержит имя', Pos('shell', T) > 0);
  finally
    G.Free;
  end;
end;

initialization
  RegisterTest(TLoopGuardTests);

end.
