unit test_json;
{ Tests for the JSON helpers and message serialisation. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TJsonTests = class(TTestCase)
  published
    procedure TestParseAndGet;
    procedure TestMessageRoundTrip;
    procedure TestToolMessage;
    procedure TestJFloatStringValue;
    procedure TestMessageSanitizesInvalidUTF8;
    procedure TestRepairMissingColon;
    procedure TestRepairCommonMalformations;
    procedure TestRepairKeepsValidJSON;
    procedure TestRepairRejectsGarbage;
  end;

implementation

uses
  fpjson, SysUtils, mirmid.types, mirmid.json, mirmid.util;

procedure TJsonTests.TestParseAndGet;
var
  D: TJSONData;
  Err: string;
begin
  AssertTrue('JSON parse', ParseJSON('{"a":{"b":5},"s":"grüße","f":1.5}', D, Err));
  try
    AssertEquals('nested number', 5, JInt(D, 'a.b', 0));
    AssertEquals('string', 'grüße', JStr(D, 's', ''));
    AssertEquals('fractional', 1.5, JFloat(D, 'f', 0.0), 0.0001);
    AssertEquals('default value', 'none', JStr(D, 'missing', 'none'));
  finally
    D.Free;
  end;
end;

procedure TJsonTests.TestJFloatStringValue;
var
  D: TJSONData;
  Err: string;
  OldSep: Char;
begin
  { A number that arrives as a JSON string is read under any locale. }
  AssertTrue('JSON parse', ParseJSON('{"f":"0.5","bad":"abc"}', D, Err));
  try
    OldSep := DefaultFormatSettings.DecimalSeparator;
    DefaultFormatSettings.DecimalSeparator := ',';
    try
      AssertEquals('string "0.5"', 0.5, JFloat(D, 'f', -1.0), 0.0001);
      AssertEquals('garbage — default value', -1.0, JFloat(D, 'bad', -1.0), 0.0001);
    finally
      DefaultFormatSettings.DecimalSeparator := OldSep;
    end;
  finally
    D.Free;
  end;
end;

procedure TJsonTests.TestMessageRoundTrip;
var
  M, M2: TMessage;
  TC: TToolCall;
begin
  M := MakeMessage(mrAssistant, '');
  SetLength(M.ToolCalls, 1);
  TC.Id := 'call_1';
  TC.Name := 'shell';
  TC.Arguments := '{"command":"ls"}';
  M.ToolCalls[0] := TC;

  M2 := JSONToMessage(MessageToJSON(M));
  AssertEquals('role', Ord(mrAssistant), Ord(M2.Role));
  AssertEquals('tool call count', 1, Length(M2.ToolCalls));
  AssertEquals('tool name', 'shell', M2.ToolCalls[0].Name);
  AssertEquals('arguments', '{"command":"ls"}', M2.ToolCalls[0].Arguments);
  AssertEquals('call id', 'call_1', M2.ToolCalls[0].Id);
end;

procedure TJsonTests.TestToolMessage;
var
  M, M2: TMessage;
begin
  M := MakeMessage(mrTool, 'result');
  M.ToolCallId := 'call_9';
  M.Name := 'read_text_file';
  M2 := JSONToMessage(MessageToJSON(M));
  AssertEquals('role', Ord(mrTool), Ord(M2.Role));
  AssertEquals('content', 'result', M2.Content);
  AssertEquals('tool_call_id', 'call_9', M2.ToolCallId);
  AssertEquals('name', 'read_text_file', M2.Name);
end;

procedure TJsonTests.TestMessageSanitizesInvalidUTF8;
var
  M: TMessage;
  O: TJSONObject;
  Body: string;
begin
  { A tool result may have been cut in the middle of a character: an invalid
    UTF-8 byte must not reach the request body. }
  M := MakeMessage(mrTool, 'text' + #$D0);
  O := MessageToJSON(M);
  try
    Body := O.AsJSON;
  finally
    O.Free;
  end;
  AssertTrue('request body is valid UTF-8', IsValidUTF8(Body));
end;

{ Helper: parse through ParseJSONRepair and return the value of a key. }
function RepairedValue(const S, Path: string): string;
var
  D: TJSONData;
  Err: string;
begin
  Result := '<error: ' + S + '>';
  if not ParseJSONRepair(S, D, Err) then
    Exit;
  try
    Result := JStr(D, Path, '<missing>');
  finally
    D.Free;
  end;
end;

{ Bug seen in real use: "path""..." — the colon is missing. }
procedure TJsonTests.TestRepairMissingColon;
begin
  AssertEquals('missing colon', 'docs/index.md',
    RepairedValue('{"path""docs/index.md"}', 'path'));
  AssertEquals('colon before a number', '7',
    RepairedValue('{"n"7}', 'n'));
  AssertEquals('colon before an object', 'x',
    RepairedValue('{"a"{"b":"x"}}', 'a.b'));
  AssertEquals('whitespace around it', 'v',
    RepairedValue('{ "a"   "v" }', 'a'));
end;

procedure TJsonTests.TestRepairCommonMalformations;
begin
  AssertEquals('trailing comma', '1',
    RepairedValue('{"a":1,}', 'a'));
  AssertEquals('unquoted key', '2',
    RepairedValue('{a:2}', 'a'));
  AssertEquals('single quotes', 'v',
    RepairedValue('{''a'':''v''}', 'a'));
  AssertEquals('markdown fence and text', 'v',
    RepairedValue('Here are the arguments:' + sLineBreak + '```json' + sLineBreak +
      '{"a":"v"}' + sLineBreak + '```' + sLineBreak + 'done', 'a'));
  AssertEquals('unclosed structure', 'v',
    RepairedValue('{"a":"v"', 'a'));
end;

{ Valid JSON must not change. }
procedure TJsonTests.TestRepairKeepsValidJSON;
begin
  AssertEquals('valid JSON stays untouched',
    '{"a":{"b":5},"s":"grüße"}',
    RepairJSON('{"a":{"b":5},"s":"grüße"}'));
end;

{ Garbage without an opening object or array is still an error. }
procedure TJsonTests.TestRepairRejectsGarbage;
var
  D: TJSONData;
  Err: string;
begin
  AssertFalse('text without a structure', ParseJSONRepair('just text', D, Err));
  AssertFalse('closing brace only', ParseJSONRepair('}', D, Err));
end;

initialization
  RegisterTest(TJsonTests);

end.
