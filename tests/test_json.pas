unit test_json;
{ Тесты JSON-хелперов и сериализации сообщений. }

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
  AssertTrue('разбор JSON', ParseJSON('{"a":{"b":5},"s":"привет","f":1.5}', D, Err));
  try
    AssertEquals('вложенное число', 5, JInt(D, 'a.b', 0));
    AssertEquals('строка', 'привет', JStr(D, 's', ''));
    AssertEquals('дробное', 1.5, JFloat(D, 'f', 0.0), 0.0001);
    AssertEquals('значение по умолчанию', 'нет', JStr(D, 'missing', 'нет'));
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
  { Число, пришедшее в JSON строкой, читается при любой локали. }
  AssertTrue('разбор JSON', ParseJSON('{"f":"0.5","bad":"abc"}', D, Err));
  try
    OldSep := DefaultFormatSettings.DecimalSeparator;
    DefaultFormatSettings.DecimalSeparator := ',';
    try
      AssertEquals('строка "0.5"', 0.5, JFloat(D, 'f', -1.0), 0.0001);
      AssertEquals('мусор — значение по умолчанию', -1.0, JFloat(D, 'bad', -1.0), 0.0001);
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
  AssertEquals('роль', Ord(mrAssistant), Ord(M2.Role));
  AssertEquals('число вызовов', 1, Length(M2.ToolCalls));
  AssertEquals('имя инструмента', 'shell', M2.ToolCalls[0].Name);
  AssertEquals('аргументы', '{"command":"ls"}', M2.ToolCalls[0].Arguments);
  AssertEquals('id вызова', 'call_1', M2.ToolCalls[0].Id);
end;

procedure TJsonTests.TestToolMessage;
var
  M, M2: TMessage;
begin
  M := MakeMessage(mrTool, 'результат');
  M.ToolCallId := 'call_9';
  M.Name := 'read_text_file';
  M2 := JSONToMessage(MessageToJSON(M));
  AssertEquals('роль', Ord(mrTool), Ord(M2.Role));
  AssertEquals('содержимое', 'результат', M2.Content);
  AssertEquals('tool_call_id', 'call_9', M2.ToolCallId);
  AssertEquals('name', 'read_text_file', M2.Name);
end;

procedure TJsonTests.TestMessageSanitizesInvalidUTF8;
var
  M: TMessage;
  O: TJSONObject;
  Body: string;
begin
  { Результат инструмента мог быть обрезан на середине символа: в тело
    запроса не должен попасть некорректный UTF-8-байт. }
  M := MakeMessage(mrTool, 'текст' + #$D0);
  O := MessageToJSON(M);
  try
    Body := O.AsJSON;
  finally
    O.Free;
  end;
  AssertTrue('тело запроса — корректный UTF-8', IsValidUTF8(Body));
end;

{ Помощник: разобрать через ParseJSONRepair и вернуть значение ключа. }
function RepairedValue(const S, Path: string): string;
var
  D: TJSONData;
  Err: string;
begin
  Result := '<ошибка: ' + S + '>';
  if not ParseJSONRepair(S, D, Err) then
    Exit;
  try
    Result := JStr(D, Path, '<нет>');
  finally
    D.Free;
  end;
end;

{ Баг из реальной работы: "path""..." — пропущено двоеточие. }
procedure TJsonTests.TestRepairMissingColon;
begin
  AssertEquals('пропущенное двоеточие', 'docs/index.md',
    RepairedValue('{"path""docs/index.md"}', 'path'));
  AssertEquals('двоеточие перед числом', '7',
    RepairedValue('{"n"7}', 'n'));
  AssertEquals('двоеточие перед объектом', 'x',
    RepairedValue('{"a"{"b":"x"}}', 'a.b'));
  AssertEquals('пробелы вокруг', 'v',
    RepairedValue('{ "a"   "v" }', 'a'));
end;

procedure TJsonTests.TestRepairCommonMalformations;
begin
  AssertEquals('висячая запятая', '1',
    RepairedValue('{"a":1,}', 'a'));
  AssertEquals('ключ без кавычек', '2',
    RepairedValue('{a:2}', 'a'));
  AssertEquals('одинарные кавычки', 'v',
    RepairedValue('{''a'':''v''}', 'a'));
  AssertEquals('markdown-забор и текст', 'v',
    RepairedValue('Вот аргументы:' + sLineBreak + '```json' + sLineBreak +
      '{"a":"v"}' + sLineBreak + '```' + sLineBreak + 'готово', 'a'));
  AssertEquals('незакрытая структура', 'v',
    RepairedValue('{"a":"v"', 'a'));
end;

{ Корректный JSON не должен меняться. }
procedure TJsonTests.TestRepairKeepsValidJSON;
begin
  AssertEquals('корректный JSON не меняется',
    '{"a":{"b":5},"s":"привет"}',
    RepairJSON('{"a":{"b":5},"s":"привет"}'));
end;

{ Мусор без начала объекта или массива по-прежнему ошибка. }
procedure TJsonTests.TestRepairRejectsGarbage;
var
  D: TJSONData;
  Err: string;
begin
  AssertFalse('текст без структуры', ParseJSONRepair('просто текст', D, Err));
  AssertFalse('только закрывающая скобка', ParseJSONRepair('}', D, Err));
end;

initialization
  RegisterTest(TJsonTests);

end.
