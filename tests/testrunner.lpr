program testrunner;
{ Unit tests for mirmid (fpcunit). Run: make test. }

{$mode objfpc}{$H+}

uses
  consoletestrunner,
  test_json,
  test_tools,
  test_config,
  test_cli,
  test_plan,
  test_planner,
  test_session,
  test_subagent,
  test_markdown,
  test_util,
  test_stream,
  test_llm,
  test_mcp, test_media, test_anthropic, test_gui, test_http,
  test_loopguard, test_tlsclient;
var
  App: TTestRunner;

begin
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'mirmid tests';
    App.Run;
  finally
    App.Free;
  end;
end.
