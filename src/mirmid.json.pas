unit mirmid.json;
{ Helpers for fpjson and for (de)serialising dialogue messages. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, mirmid.types;

{ Parse a JSON string. }
function ParseJSON(const S: string; out D: TJSONData; out Err: string): Boolean;

(* Lenient repair of the JSON mistakes models often make in tool arguments:
  cuts the useful object out of markdown fences and explanatory text,
  removes trailing commas, inserts a colon missing after a key
  (for example "path""docs/index.md"), quotes keys that have no quotes
  (path:"x"), turns single quotes into double quotes and appends the
  missing closing brackets. If the structure is unrecognisable (no object
  or array start), the string is returned unchanged. *)
function RepairJSON(const S: string): string;

{ Parse with lenient repair: strict first, then through RepairJSON.
  Returns True if at least the repaired string parsed. }
function ParseJSONRepair(const S: string; out D: TJSONData; out Err: string): Boolean;

{ Safe value lookup by a simple path (FindPath). }
function JStr(D: TJSONData; const Path, Def: string): string;
function JInt(D: TJSONData; const Path: string; Def: Integer): Integer;
function JFloat(D: TJSONData; const Path: string; Def: Double): Double;
function JBool(D: TJSONData; const Path: string; Def: Boolean): Boolean;

{ Message <-> JSON object. }
function MessageToJSON(const M: TMessage): TJSONObject;
function JSONToMessage(O: TJSONObject): TMessage;
function MessagesToJSONArray(const Msgs: TMessages): TJSONArray;
procedure JSONArrayToMessages(A: TJSONArray; out Msgs: TMessages);

implementation

uses
  jsonparser, mirmid.util;

function ParseJSON(const S: string; out D: TJSONData; out Err: string): Boolean;
begin
  D := nil;
  Err := '';
  try
    D := GetJSON(S);
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

(* Returns the substring from the first { or [ up to the matching closing
  bracket (taking strings and nesting into account). Empty if there is no
  structure start. *)
function ExtractJSONBlob(const S: string): string;
var
  Start, I, N, Depth: Integer;
  C: Char;
  InStr, Esc: Boolean;
  Quote: Char;
begin
  Start := 0;
  N := Length(S);
  for I := 1 to N do
    if (S[I] = '{') or (S[I] = '[') then
    begin
      Start := I;
      Break;
    end;
  if Start = 0 then
    Exit('');

  Depth := 0;
  InStr := False;
  Esc := False;
  Quote := #0;
  for I := Start to N do
  begin
    C := S[I];
    if InStr then
    begin
      if Esc then
        Esc := False
      else if C = '\' then
        Esc := True
      else if C = Quote then
        InStr := False;
      Continue;
    end;
    case C of
      '"', '''':
        begin
          InStr := True;
          Quote := C;
        end;
      '{', '[': Inc(Depth);
      '}', ']':
        begin
          Dec(Depth);
          if Depth <= 0 then
            Exit(Copy(S, Start, I - Start + 1));
        end;
    end;
  end;
  { The structure is not closed — return the rest; the missing brackets are
    appended afterwards. }
  Result := Copy(S, Start, N - Start + 1);
end;

function RepairJSON(const S: string): string;
var
  T: string;
  I, N: Integer;
  Stack: array of Char;
  InStr, Esc, KeyClosed, WasKey, AtKeyPos: Boolean;
  Quote, C, D: Char;
  Ident: string;

  procedure Emit(const Ch: Char);
  begin
    Result := Result + Ch;
  end;

  function TopIsObject: Boolean;
  begin
    Result := (Length(Stack) > 0) and (Stack[High(Stack)] = '{');
  end;

  function NextSignificant(FromPos: Integer): Char;
  var
    J: Integer;
  begin
    Result := #0;
    for J := FromPos to N do
      if not (T[J] in [' ', #9, #10, #13]) then
        Exit(T[J]);
  end;

  function IsIdentStart(const Ch: Char): Boolean;
  begin
    Result := Ch in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$'];
  end;

  function IsIdentChar(const Ch: Char): Boolean;
  begin
    Result := Ch in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$', '.', '-'];
  end;

begin
  T := ExtractJSONBlob(S);
  if T = '' then
    Exit(S);

  N := Length(T);
  Result := '';
  SetLength(Stack, 0);
  InStr := False;
  Esc := False;
  KeyClosed := False;
  WasKey := False;
  AtKeyPos := False;
  Quote := #0;
  I := 1;
  while I <= N do
  begin
    C := T[I];

    if InStr then
    begin
      if Esc then
      begin
        if (Quote = '''') and (C = '"') then
          Emit('\');
        Emit(C);
        Esc := False;
      end
      else if C = '\' then
      begin
        Emit('\');
        Esc := True;
      end
      else if C = Quote then
      begin
        Emit('"');
        InStr := False;
        if WasKey then
          KeyClosed := True;
      end
      else
      begin
        if (Quote = '''') and (C = '"') then
          Emit('\');
        Emit(C);
      end;
      Inc(I);
      Continue;
    end;

    { Whitespace outside strings is insignificant — drop it. }
    if C in [' ', #9, #10, #13] then
    begin
      Inc(I);
      Continue;
    end;

    { The key was a string and the colon is missing — insert it. }
    if KeyClosed and (C <> ':') then
    begin
      if not (C in ['}', ']']) then
        Emit(':');
      KeyClosed := False;
    end;

    case C of
      '{':
        begin
          Emit('{');
          SetLength(Stack, Length(Stack) + 1);
          Stack[High(Stack)] := '{';
          AtKeyPos := True;
        end;
      '[':
        begin
          Emit('[');
          SetLength(Stack, Length(Stack) + 1);
          Stack[High(Stack)] := '[';
          AtKeyPos := False;
        end;
      '}', ']':
        begin
          if Length(Stack) = 0 then
          begin
            Inc(I);
            Continue;
          end;
          Emit(C);
          SetLength(Stack, Length(Stack) - 1);
          AtKeyPos := False;
        end;
      ':':
        begin
          Emit(':');
          AtKeyPos := False;
          KeyClosed := False;
        end;
      ',':
        begin
          D := NextSignificant(I + 1);
          if (D = '}') or (D = ']') or (D = #0) then
          begin
            Inc(I);
            Continue;
          end;
          Emit(',');
          AtKeyPos := TopIsObject;
        end;
      '"', '''':
        begin
          WasKey := AtKeyPos;
          AtKeyPos := False;
          Quote := C;
          InStr := True;
          Esc := False;
          Emit('"');
        end;
      else
        begin
          { Unquoted key: path:"x" -> "path":"x". }
          if AtKeyPos and IsIdentStart(C) then
          begin
            Ident := '';
            while (I <= N) and IsIdentChar(T[I]) do
            begin
              Ident := Ident + T[I];
              Inc(I);
            end;
            Emit('"');
            Result := Result + Ident;
            Emit('"');
            AtKeyPos := False;
            KeyClosed := True;
            Continue;
          end;
          Emit(C);
          AtKeyPos := False;
        end;
    end;
    Inc(I);
  end;

  { Append the missing closing brackets. }
  while Length(Stack) > 0 do
  begin
    if Stack[High(Stack)] = '{' then
      Emit('}')
    else
      Emit(']');
    SetLength(Stack, Length(Stack) - 1);
  end;
end;

function ParseJSONRepair(const S: string; out D: TJSONData; out Err: string): Boolean;
var
  Fixed, FixedErr: string;
begin
  if ParseJSON(S, D, Err) then
    Exit(True);
  Fixed := RepairJSON(S);
  if Fixed = S then
    Exit(False);
  if ParseJSON(Fixed, D, FixedErr) then
    Exit(True);
  Result := False;
end;

function GetPathOrNil(D: TJSONData; const Path: string): TJSONData;
begin
  Result := nil;
  if D = nil then
    Exit;
  try
    Result := D.FindPath(Path);
  except
    Result := nil;
  end;
end;

function JStr(D: TJSONData; const Path, Def: string): string;
var
  X: TJSONData;
begin
  Result := Def;
  X := GetPathOrNil(D, Path);
  if (X = nil) or (X is TJSONNull) then
    Exit;
  Result := X.AsString;
end;

function JInt(D: TJSONData; const Path: string; Def: Integer): Integer;
var
  X: TJSONData;
begin
  Result := Def;
  X := GetPathOrNil(D, Path);
  if (X = nil) or (X is TJSONNull) then
    Exit;
  if X is TJSONNumber then
    Result := X.AsInteger
  else
    Result := StrToIntDef(X.AsString, Def);
end;

function JFloat(D: TJSONData; const Path: string; Def: Double): Double;
var
  X: TJSONData;
begin
  Result := Def;
  X := GetPathOrNil(D, Path);
  if (X = nil) or (X is TJSONNull) then
    Exit;
  if X is TJSONNumber then
    Result := X.AsFloat
  else
    Result := DotToFloat(X.AsString, Def);
end;

function JBool(D: TJSONData; const Path: string; Def: Boolean): Boolean;
var
  X: TJSONData;
begin
  Result := Def;
  X := GetPathOrNil(D, Path);
  if (X = nil) or (X is TJSONNull) then
    Exit;
  if X is TJSONBoolean then
    Result := X.AsBoolean
  else
  begin
    case LowerCase(X.AsString) of
      '1', 'true', 'yes', 'on': Result := True;
      '0', 'false', 'no', 'off': Result := False;
    end;
  end;
end;

function MessageToJSON(const M: TMessage): TJSONObject;
var
  A: TJSONArray;
  TC: TJSONObject;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('role', RoleName(M.Role));

  if (M.Content = '') and (Length(M.ToolCalls) > 0) and (M.Role = mrAssistant) then
    Result.Add('content', TJSONNull.Create)
  else
    Result.Add('content', SanitizeUTF8(M.Content));

  if M.Reasoning <> '' then
    Result.Add('reasoning_content', SanitizeUTF8(M.Reasoning));

  if M.Role = mrTool then
  begin
    Result.Add('tool_call_id', M.ToolCallId);
    if M.Name <> '' then
      Result.Add('name', M.Name);
  end;

  if Length(M.ToolCalls) > 0 then
  begin
    A := TJSONArray.Create;
    for I := 0 to High(M.ToolCalls) do
    begin
      TC := TJSONObject.Create;
      TC.Add('id', M.ToolCalls[I].Id);
      TC.Add('type', 'function');
      TC.Add('function', TJSONObject.Create([
        'name', M.ToolCalls[I].Name,
        'arguments', M.ToolCalls[I].Arguments]));
      A.Add(TC);
    end;
    Result.Add('tool_calls', A);
  end;
end;

function JSONToMessage(O: TJSONObject): TMessage;
var
  RT: string;
  A: TJSONArray;
  Item: TJSONData;
  TC: TToolCall;
  Arg: TJSONData;
  I: Integer;
begin
  RT := JStr(O, 'role', 'user');
  if RT = 'system' then
    Result.Role := mrSystem
  else if RT = 'assistant' then
    Result.Role := mrAssistant
  else if RT = 'tool' then
    Result.Role := mrTool
  else
    Result.Role := mrUser;

  Result.Content    := JStr(O, 'content', '');
  Result.Reasoning  := JStr(O, 'reasoning_content', '');
  Result.ToolCallId := JStr(O, 'tool_call_id', '');
  Result.Name       := JStr(O, 'name', '');
  SetLength(Result.ToolCalls, 0);

  A := nil;
  Item := GetPathOrNil(O, 'tool_calls');
  if Item is TJSONArray then
    A := TJSONArray(Item);
  if A = nil then
    Exit;

  SetLength(Result.ToolCalls, A.Count);
  for I := 0 to A.Count - 1 do
  begin
    if not (A.Items[I] is TJSONObject) then
      Continue;
    TC.Id := JStr(A.Items[I], 'id', '');
    TC.Name := JStr(A.Items[I], 'function.name', '');
    Arg := GetPathOrNil(A.Items[I], 'function.arguments');
    if Arg is TJSONObject then
      TC.Arguments := Arg.AsJSON
    else if (Arg = nil) or (Arg is TJSONNull) then
      TC.Arguments := '{}'
    else
      TC.Arguments := Arg.AsString;
    Result.ToolCalls[I] := TC;
  end;
end;

function MessagesToJSONArray(const Msgs: TMessages): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(Msgs) do
    Result.Add(MessageToJSON(Msgs[I]));
end;

procedure JSONArrayToMessages(A: TJSONArray; out Msgs: TMessages);
var
  I, N: Integer;
begin
  N := 0;
  SetLength(Msgs, A.Count);
  for I := 0 to A.Count - 1 do
    if A.Items[I] is TJSONObject then
    begin
      Msgs[N] := JSONToMessage(TJSONObject(A.Items[I]));
      Inc(N);
    end;
  SetLength(Msgs, N);
end;

end.
