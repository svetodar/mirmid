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
    procedure TestSubagentEmptyPrompt;
    procedure TestSubagentDepthLimit;
    procedure TestSubagentEmptyAnswer;
    procedure TestHttpPolicyDenied;
    procedure TestContextOnSubAgentEventDefault;
    procedure TestSubagentOutcomeNonEmpty;
  end;

implementation

uses
  SysUtils, mirmid.types, mirmid.subagent, mirmid.httprequest;

procedure TSubAgentToolTests.SetUp;
begin
  FReg := TToolRegistry.Create;
  RegisterSessionTools(FReg, DefaultConfig);
  FCtx := MakeToolContext(DefaultConfig);
end;

procedure TSubAgentToolTests.TearDown;
begin
  FReg.Free;
end;

{ subagent доступен по умолчанию, http_request — нет. }
procedure TSubAgentToolTests.TestSessionToolsDefault;
begin
  AssertTrue('subagent доступен по умолчанию', FReg.Has(SUBAGENT_TOOL_NAME));
  AssertFalse('http_request недоступен по умолчанию', FReg.Has(HTTP_TOOL_NAME));
end;

{ С политикой AllowHttp http_request попадает в набор инструментов. }
procedure TSubAgentToolTests.TestSessionToolsHttpEnabled;
var
  Cfg: TMirmidConfig;
  R2: TToolRegistry;
begin
  Cfg := DefaultConfig;
  Cfg.AllowHttp := True;
  R2 := TToolRegistry.Create;
  try
    RegisterSessionTools(R2, Cfg);
    AssertTrue('http_request доступен с AllowHttp', R2.Has(HTTP_TOOL_NAME));
    AssertTrue('subagent тоже на месте', R2.Has(SUBAGENT_TOOL_NAME));
  finally
    R2.Free;
  end;
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

{ Инструмент зарегистрирован, но политика AllowHttp запрещает запрос. }
procedure TSubAgentToolTests.TestHttpPolicyDenied;
var
  O: TToolOutcome;
  R2: TToolRegistry;
begin
  R2 := TToolRegistry.Create;
  try
    RegisterHttpTool(R2);
    FCtx.AllowHttp := False;
    O := R2.Invoke(HTTP_TOOL_NAME, '{"url":"http://example.com"}', FCtx);
    AssertTrue('http запрещён политикой', O.IsError);
    AssertTrue('сообщение о запрете', Pos('запрещён', O.Text) > 0);
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

initialization
  RegisterTest(TSubAgentToolTests);

end.
