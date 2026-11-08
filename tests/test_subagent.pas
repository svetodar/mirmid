unit test_subagent;
{ Тесты инструментов subagent и http_request (без сети: проверяются
  регистрация, политики и ранние проверки аргументов). }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.tools;

type
  TSubAgentToolTests = class(TTestCase)
  private
    FReg: TToolRegistry;
    FCtx: TToolContext;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSessionToolsDefault;
    procedure TestSessionToolsHttpEnabled;
    procedure TestDisabledToolRefusesInHandler;
    procedure TestSubagentEmptyPrompt;
    procedure TestSubagentDepthLimit;
    procedure TestSubagentEmptyAnswer;
    procedure TestHttpPolicyDenied;
    procedure TestContextOnSubAgentEventDefault;
    procedure TestSubagentOutcomeNonEmpty;
    procedure TestRequestToolsMatchTable;
    procedure TestDisabledToolAbsentFromRequest;
  end;

implementation

uses
  SysUtils, Classes, fpjson, mirmid.types, mirmid.subagent, mirmid.httprequest;

{ Имена инструментов из массива tools запроса — по одной строке, через
  перевод строки. }
function RequestToolNames(const R: TToolRegistry): string;
var
  A: TJSONArray;
  I: Integer;
  N: TJSONData;
begin
  Result := '';
  A := TJSONArray.Create;
  try
    R.BuildRequestTools(A);
    for I := 0 to A.Count - 1 do
    begin
      N := A.Objects[I].FindPath('function.name');
      if (N <> nil) and (Result <> '') then
        Result := Result + sLineBreak;
      if N <> nil then
        Result := Result + N.AsString;
    end;
  finally
    A.Free;
  end;
end;

procedure TSubAgentToolTests.SetUp;
var
  Cfg: TMirmidConfig;
begin
  { subagent по умолчанию выключен ([tools]), а тесты ниже проверяют его
    обработку — включаем ключ и собираем набор с ним. }
  Cfg := DefaultConfig;
  SetToolEnabled(Cfg, SUBAGENT_TOOL_NAME, True);
  FReg := TToolRegistry.Create;
  RegisterSessionTools(FReg, Cfg);
  FCtx := MakeToolContext(Cfg);
end;

procedure TSubAgentToolTests.TearDown;
begin
  FReg.Free;
end;

{ Набор по умолчанию: читающие инструменты и revise_plan есть, пишущие,
  сетевые и вложенные — нет (значения из таблицы mirmid.tools). }
procedure TSubAgentToolTests.TestSessionToolsDefault;
var
  R: TToolRegistry;
begin
  R := TToolRegistry.Create;
  try
    RegisterSessionTools(R, DefaultConfig);
    AssertFalse('subagent выключен по умолчанию', R.Has(SUBAGENT_TOOL_NAME));
    AssertFalse('http_request выключен по умолчанию', R.Has(HTTP_TOOL_NAME));
    AssertFalse('shell выключен по умолчанию', R.Has('shell'));
    AssertTrue('grep включён по умолчанию', R.Has('grep'));
  finally
    R.Free;
  end;
end;

{ Ключи [tools] включают инструменты в наборе сессии. }
procedure TSubAgentToolTests.TestSessionToolsHttpEnabled;
var
  Cfg: TMirmidConfig;
  R2: TToolRegistry;
begin
  Cfg := DefaultConfig;
  SetToolEnabled(Cfg, 'http_request', True);
  SetToolEnabled(Cfg, SUBAGENT_TOOL_NAME, True);
  R2 := TToolRegistry.Create;
  try
    RegisterSessionTools(R2, Cfg);
    AssertTrue('http_request доступен с ключом http_request=1',
      R2.Has(HTTP_TOOL_NAME));
    AssertTrue('subagent тоже на месте', R2.Has(SUBAGENT_TOOL_NAME));
  finally
    R2.Free;
  end;
end;

{ Защита в глубину: инструмент зарегистрирован (набор собран при включённом
  ключе), но контекст с выключенным ключом получает отказ обработчика. }
procedure TSubAgentToolTests.TestDisabledToolRefusesInHandler;
var
  O: TToolOutcome;
  CtxOff: TToolContext;
begin
  CtxOff := FCtx;
  SetToolEnabled(CtxOff.Cfg, SUBAGENT_TOOL_NAME, False);
  O := FReg.Invoke(SUBAGENT_TOOL_NAME, '{"prompt":"тест"}', CtxOff);
  AssertTrue('выключенный инструмент отказывает', O.IsError);
  AssertTrue('сообщение называет инструмент: ' + O.Text,
    Pos('tool "subagent" is disabled', O.Text) > 0);
end;

{ Пустой prompt отклоняется до обращения к модели. }
procedure TSubAgentToolTests.TestSubagentEmptyPrompt;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(SUBAGENT_TOOL_NAME, '{}', FCtx);
  AssertTrue('пустой prompt отклонён', O.IsError);
  AssertTrue('сообщение о prompt', Pos('prompt', O.Text) > 0);
end;

{ Глубина вложенности субагентов ограничена. }
procedure TSubAgentToolTests.TestSubagentDepthLimit;
var
  O: TToolOutcome;
begin
  FCtx.SubAgentDepth := MAX_SUBAGENT_DEPTH;
  O := FReg.Invoke(SUBAGENT_TOOL_NAME, '{"prompt":"тест"}', FCtx);
  AssertTrue('глубина ограничена', O.IsError);
  AssertTrue('сообщение о глубине', Pos('глубин', O.Text) > 0);
end;

{ Пустой финальный ответ субагента — ошибка, а не молчание: иначе строка
  результата в UI не появлялась бы вовсе. }
procedure TSubAgentToolTests.TestSubagentEmptyAnswer;
var
  O: TToolOutcome;
begin
  O := SubagentOutcome('');
  AssertTrue('пустой ответ — ошибка', O.IsError);
  AssertTrue('в сообщении упомянут текст', Pos('текст', O.Text) > 0);

  O := SubagentOutcome('   ');
  AssertTrue('пробелы — тоже пустой ответ', O.IsError);

  O := SubagentOutcome('  ответ  ');
  AssertFalse('непустой ответ не ошибка: ' + O.Text, O.IsError);
  AssertEquals('ответ обрезан по краям', 'ответ', O.Text);
end;

{ Инструмент зарегистрирован, но ключ http_request=0 в [tools] запрещает
  запрос. }
procedure TSubAgentToolTests.TestHttpPolicyDenied;
var
  O: TToolOutcome;
  R2: TToolRegistry;
begin
  R2 := TToolRegistry.Create;
  try
    RegisterHttpTool(R2);
    SetToolEnabled(FCtx.Cfg, 'http_request', False);
    O := R2.Invoke(HTTP_TOOL_NAME, '{"url":"http://example.com"}', FCtx);
    AssertTrue('http выключен ключом', O.IsError);
    AssertTrue('сообщение называет инструмент: ' + O.Text,
      Pos('tool "http_request" is disabled', O.Text) > 0);
  finally
    R2.Free;
  end;
end;

{ По умолчанию OnSubAgentEvent в контексте не назначен (nil). }
procedure TSubAgentToolTests.TestContextOnSubAgentEventDefault;
begin
  AssertFalse('OnSubAgentEvent по умолчанию nil',
    Assigned(FCtx.OnSubAgentEvent));
end;

{ Непустой финальный ответ субагента — не ошибка, текст обрезан. }
procedure TSubAgentToolTests.TestSubagentOutcomeNonEmpty;
var
  O: TToolOutcome;
begin
  O := SubagentOutcome('  результат работы  ');
  AssertFalse('непустой ответ не ошибка', O.IsError);
  AssertEquals('текст обрезан по краям', 'результат работы', O.Text);
end;

{ Массив tools запроса совпадает с таблицей [tools]: все имена известны
  таблице, и каждый её ключ попадает в запрос — кроме revise_plan, который
  регистрирует планировщик, а не набор сессии. Так тест ловит расхождение
  таблицы и реестра. }
procedure TSubAgentToolTests.TestRequestToolsMatchTable;
var
  Cfg: TMirmidConfig;
  R: TToolRegistry;
  Names: TStringList;
  I: Integer;
  Name: string;
begin
  Cfg := DefaultConfig;
  for I := 0 to ToolSwitchCount - 1 do
    SetToolEnabled(Cfg, ToolSwitchAt(I).Name, True);
  R := TToolRegistry.Create;
  Names := TStringList.Create;
  try
    RegisterSessionTools(R, Cfg);
    Names.Text := RequestToolNames(R);
    AssertTrue('запрос не пуст', Names.Count > 0);
    { Вверх: ни одного имени вне таблицы. }
    for I := 0 to Names.Count - 1 do
      AssertTrue('имя из таблицы: ' + Names[I],
        IsKnownToolName(Names[I]));
    { Вниз: каждый ключ таблицы, кроме revise_plan, в запросе. }
    for I := 0 to ToolSwitchCount - 1 do
    begin
      Name := ToolSwitchAt(I).Name;
      if Name = 'revise_plan' then
        Continue;
      AssertTrue('в запросе есть ' + Name, Names.IndexOf(Name) >= 0);
    end;
  finally
    Names.Free;
    R.Free;
  end;
end;

{ Выключенный ключом инструмент не попадает в массив tools запроса, а
  включённый — попадает. }
procedure TSubAgentToolTests.TestDisabledToolAbsentFromRequest;
var
  Cfg: TMirmidConfig;
  R: TToolRegistry;
  S: string;
begin
  { По умолчанию shell выключен: его нет в массиве tools запроса. }
  Cfg := DefaultConfig;
  R := TToolRegistry.Create;
  try
    RegisterSessionTools(R, Cfg);
    S := RequestToolNames(R);
    AssertEquals('shell выключен — нет в запросе', -1,
      S.IndexOf('shell'));
    AssertTrue('file_list включён — есть в запросе',
      S.IndexOf('file_list') >= 0);
  finally
    R.Free;
  end;

  { Ключ shell=1 — инструмент снова в запросе. }
  Cfg := DefaultConfig;
  SetToolEnabled(Cfg, 'shell', True);
  R := TToolRegistry.Create;
  try
    RegisterSessionTools(R, Cfg);
    S := RequestToolNames(R);
    AssertTrue('shell включён — есть в запросе',
      S.IndexOf('shell') >= 0);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TSubAgentToolTests);

end.
