unit test_loopguard;
{ Loop-guard tests: the detector of repeated tool calls
  (src/mirmid.loopguard.pas). Pure unit tests, no network and no LLM. }

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

{ Strong signal: the same call with the same result,
  default thresholds warn=3, stop=5. }
procedure TLoopGuardTests.TestStrongRepeatWarnStop;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    AssertEquals('1st call — silence', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('2nd call — silence', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('3rd call — warn', Ord(laWarn), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('4th call — warn', Ord(laWarn), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('5th call — stop', Ord(laStop), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('6th call — stop', Ord(laStop), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
  finally
    G.Free;
  end;
end;

{ A different call (name or arguments) resets the repeat counters. }
procedure TLoopGuardTests.TestResetOnDifferentCall;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    AssertEquals('repeats before the reset', 2, G.RepeatCount);
    { A different call resets the counters. }
    AssertEquals('different call — silence', Ord(laNone), Ord(G.Feed('read_file', '{"path":"a"}', 'ok', T)));
    AssertEquals('repeat counter reset', 1, G.RepeatCount);
    { A repeat of the first call is counted from scratch (the counter does not
      remember the old repeats). }
    AssertEquals('back to the first one — silence', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    AssertEquals('repeat after the reset counted anew', 1, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Polling: the same call, but the result changes every time —
  weak signal with the LOOP_WEAK_WARN/LOOP_WEAK_STOP = 5/8 thresholds. }
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
      A := G.Feed('shell', '{"command":"ps"}', 'process ' + IntToStr(I), T);
      if I < 5 then
        AssertEquals('polling ' + IntToStr(I) + ' — silence', Ord(laNone), Ord(A))
      else if I < 8 then
        AssertEquals('polling ' + IntToStr(I) + ' — warn', Ord(laWarn), Ord(A))
      else
        AssertEquals('polling ' + IntToStr(I) + ' — stop', Ord(laStop), Ord(A));
    end;
  finally
    G.Free;
  end;
end;

{ A result change resets the strong counter (same results),
  but the repeat counter keeps growing. }
procedure TLoopGuardTests.TestResultChangeResetsStrongCounter;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    G.Feed('shell', '{"command":"ls"}', 'ok', T);
    AssertEquals('3rd with the same result — warn', Ord(laWarn), Ord(G.Feed('shell', '{"command":"ls"}', 'ok', T)));
    { A result change resets the strong counter. }
    AssertEquals('result change — silence', Ord(laNone), Ord(G.Feed('shell', '{"command":"ls"}', 'other', T)));
    AssertEquals('strong counter reset', 1, G.SameResultCount);
    AssertEquals('repeats keep counting', 4, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ The thresholds come from the constructor (from the config loop_warn/loop_stop). }
procedure TLoopGuardTests.TestCustomThresholds;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(2, 4);
  try
    AssertEquals('1st call — silence', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('2nd call — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('3rd call — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('4th call — stop', Ord(laStop), Ord(G.Feed('x', '', 'r', T)));
  finally
    G.Free;
  end;
end;

{ Stop is off (0) — warnings happen, no stop. }
procedure TLoopGuardTests.TestWarnOnly;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 0);
  try
    G.Feed('x', '', 'r', T);
    G.Feed('x', '', 'r', T);
    AssertEquals('3rd call — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('4th call — warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('5th call — still warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('6th call — still warn', Ord(laWarn), Ord(G.Feed('x', '', 'r', T)));
  finally
    G.Free;
  end;
end;

{ Warn is off (0) — stop only. }
procedure TLoopGuardTests.TestStopOnly;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(0, 5);
  try
    G.Feed('x', '', 'r', T);
    G.Feed('x', '', 'r', T);
    AssertEquals('3rd call — silence', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('4th call — silence', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('5th call — stop', Ord(laStop), Ord(G.Feed('x', '', 'r', T)));
  finally
    G.Free;
  end;
end;

{ Both thresholds 0 — the detector is off, repeats are not counted. }
procedure TLoopGuardTests.TestDisabled;
var
  G: TLoopGuard;
  T: string;
  I: Integer;
begin
  G := TLoopGuard.Create(0, 0);
  try
    for I := 1 to 10 do
      AssertEquals('repeat ' + IntToStr(I) + ' — silence', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('repeat counter does not grow', 0, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Reset clears the state (start of a new turn). }
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
    AssertEquals('repeats after Reset', 0, G.RepeatCount);
    AssertEquals('same results after Reset', 0, G.SameResultCount);
    AssertEquals('after Reset — counted anew', Ord(laNone), Ord(G.Feed('x', '', 'r', T)));
    AssertEquals('counter after Reset', 1, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Key order and whitespace in the JSON arguments do not change the signature;
  other arguments are a different call. }
procedure TLoopGuardTests.TestSignatureNormalization;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '{"a":1,"b":2}', 'r1', T);
    AssertEquals('other key order — same call', Ord(laNone), Ord(G.Feed('shell', '{"b":2,"a":1}', 'r2', T)));
    AssertEquals('whitespace — same call', Ord(laNone), Ord(G.Feed('shell', '{"a": 1, "b": 2}', 'r3', T)));
    AssertEquals('repeats are counted', 3, G.RepeatCount);
    { Other arguments are a different call, the counter is reset. }
    AssertEquals('other arguments — silence', Ord(laNone), Ord(G.Feed('shell', '{"a":1,"b":3}', 'r4', T)));
    AssertEquals('counter after other arguments', 1, G.RepeatCount);
  finally
    G.Free;
  end;
end;

{ Call signature: empty/unrecognised arguments are taken as is. }
procedure TLoopGuardTests.TestCallSignature;
begin
  AssertEquals('empty arguments', 'shell'#0, CallSignature('shell', ''));
  AssertEquals('whitespace — empty arguments', 'shell'#0, CallSignature('shell', '   '));
  AssertEquals('unrecognised JSON — as is', 'shell'#0 + 'not json', CallSignature('shell', 'not json'));
  AssertEquals('key order does not matter',
    CallSignature('shell', '{"a":1,"b":2}'), CallSignature('shell', '{"b":2,"a":1}'));
  AssertFalse('different names — different signatures',
    CallSignature('shell', '{}') = CallSignature('read', '{}'));
end;

{ Canonical JSON: object keys are sorted, no extra whitespace. }
procedure TLoopGuardTests.TestCanonicalJSON;
var
  D: TJSONData;
  Err: string;
begin
  AssertTrue('JSON parse', ParseJSON('{"b":2,"a":{"y":true,"x":[1,2]}}', D, Err));
  try
    AssertEquals('canonical JSON', '{"a":{"x":[1,2],"y":true},"b":2}', CanonicalJSON(D));
  finally
    D.Free;
  end;
end;

{ Message texts: the warning carries the name and the count, the stop text
  says that a loop was detected. }
procedure TLoopGuardTests.TestMessages;
var
  G: TLoopGuard;
  T: string;
begin
  G := TLoopGuard.Create(3, 5);
  try
    G.Feed('shell', '', 'r', T);
    G.Feed('shell', '', 'r', T);
    AssertEquals('3rd call — warn', Ord(laWarn), Ord(G.Feed('shell', '', 'r', T)));
    AssertTrue('warning text carries the name', Pos('shell', T) > 0);
    AssertTrue('warning text carries the count', Pos('3', T) > 0);
    G.Feed('shell', '', 'r', T);
    AssertEquals('5th call — stop', Ord(laStop), Ord(G.Feed('shell', '', 'r', T)));
    AssertTrue('stop text says "loop detected"', Pos('loop detected', T) > 0);
    AssertTrue('stop text carries the name', Pos('shell', T) > 0);
  finally
    G.Free;
  end;
end;

initialization
  RegisterTest(TLoopGuardTests);

end.
