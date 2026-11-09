unit mirmid.loopguard;
{ Loop guard: detector of repeated tool calls (the main anti-loop mechanism).
  Pure unit, no network/LLM — easy to test.

  TLoopGuard stores the signature of the last call (name + normalised JSON
  arguments) and the counters of consecutive repeats. Feed(name, args, result)
  returns an action (laNone/laWarn/laStop) and a message text.

  Two kinds of signal:
  - strong: the same call with the same result — an obvious loop
    (thresholds from the config loop_warn/loop_stop, 3/5 by default; 0 — off);
  - weak: the same call with a different result — process polling
    (fixed thresholds LOOP_WEAK_WARN/LOOP_WEAK_STOP = 5/8, higher so that
    legitimate polling is not caught). The weak signal is active only when
    the corresponding action (warn/stop) is enabled. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, mirmid.json, mirmid.util;

type
  { Result of checking a single tool call. }
  TLoopAction = (laNone, laWarn, laStop);

  { Detector of repeated tool calls.
    AStrongWarn/AStrongStop — thresholds of the strong signal (from the config
    loop_warn/loop_stop; 0 — the corresponding action is off). The weak signal
    (polling) uses fixed thresholds LOOP_WEAK_WARN/LOOP_WEAK_STOP and is
    active only when the corresponding action is enabled. }
  TLoopGuard = class
  private
    FLastSig: string;
    FLastResult: string;
    FRepeat: Integer;      { consecutive calls with the same signature }
    FSameResult: Integer;  { consecutive calls with the same signature and result }
    FStrongWarn: Integer;
    FStrongStop: Integer;
    function Enabled: Boolean;
  public
    constructor Create(AStrongWarn, AStrongStop: Integer);
    { Reset the state (start of a new turn/session). }
    procedure Reset;
    { Check a tool call: name, JSON arguments, result.
      Returns the action; AText — message text (empty for laNone). }
    function Feed(const AName, AArgs, AResult: string; out AText: string): TLoopAction;
    { Current counters (for tests and debugging). }
    property RepeatCount: Integer read FRepeat;
    property SameResultCount: Integer read FSameResult;
  end;

{ Weak-signal thresholds (same call with a different result, polling). }
const
  LOOP_WEAK_WARN = 5;
  LOOP_WEAK_STOP = 8;

{ Call signature: name + '#0' + normalised JSON arguments
  (object keys sorted, no extra whitespace). Empty or unrecognised
  arguments — as is (after Trim). }
function CallSignature(const AName, AArgs: string): string;
{ Canonical JSON: object keys sorted, no extra whitespace. }
function CanonicalJSON(D: TJSONData): string;

implementation

{ String escaping for embedding into JSON. }
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

{ Canonical JSON: object keys sorted, no extra whitespace. }
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
  { Unknown type — as is. }
  Result := D.AsJSON;
end;

{ Call signature: name + '#0' + normalised JSON arguments. }
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

{ Warning text (synthetic user message). }
function WarnText(const AName: string; N: Integer): string;
begin
  Result := Format('You called %s %d times in a row with the same arguments. ' +
    'Stop repeating yourself: change your approach or finish', [AName, N]);
end;

{ Stop text (aeError). }
function StopText(const AName: string; N: Integer): string;
begin
  Result := Format('loop detected: %d identical calls of %s', [N, AName]);
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

  { Strong signal: the same call with the same result. }
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
  { Weak signal: the same call with a different result (polling).
    It fires only when the result has changed — with an identical
    result this is a strong loop, caught by the strong signal. }
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
