unit test_subagent;
{ Tests for the subagent and http_request tools (no network: registration,
  policies and early argument checks are verified). }

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

{ Tool names from the tools array of the request -- one per line, separated by
  line breaks. }
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
  { subagent is disabled by default ([tools]), and the tests below exercise its
    handler -- switch the key on and build a set that includes it. }
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

{ Default set: the read-only tools and revise_plan are there, the writing,
  network and nested ones are not (values from the mirmid.tools table). }
procedure TSubAgentToolTests.TestSessionToolsDefault;
var
  R: TToolRegistry;
begin
  R := TToolRegistry.Create;
  try
    RegisterSessionTools(R, DefaultConfig);
    AssertFalse('subagent is disabled by default', R.Has(SUBAGENT_TOOL_NAME));
    AssertFalse('http_request is disabled by default', R.Has(HTTP_TOOL_NAME));
    AssertFalse('shell is disabled by default', R.Has('shell'));
    AssertTrue('grep is enabled by default', R.Has('grep'));
  finally
    R.Free;
  end;
end;

{ The [tools] keys enable tools in the session set. }
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
    AssertTrue('http_request is available with the key http_request=1',
      R2.Has(HTTP_TOOL_NAME));
    AssertTrue('subagent is in place too', R2.Has(SUBAGENT_TOOL_NAME));
  finally
    R2.Free;
  end;
end;

{ Defence in depth: the tool is registered (the set was built with the key
  switched on), but a context with the key switched off gets a refusal from the
  handler. }
procedure TSubAgentToolTests.TestDisabledToolRefusesInHandler;
var
  O: TToolOutcome;
  CtxOff: TToolContext;
begin
  CtxOff := FCtx;
  SetToolEnabled(CtxOff.Cfg, SUBAGENT_TOOL_NAME, False);
  O := FReg.Invoke(SUBAGENT_TOOL_NAME, '{"prompt":"test"}', CtxOff);
  AssertTrue('a disabled tool refuses', O.IsError);
  AssertTrue('the message names the tool: ' + O.Text,
    Pos('tool "subagent" is disabled', O.Text) > 0);
end;

{ An empty prompt is rejected before the model is called. }
procedure TSubAgentToolTests.TestSubagentEmptyPrompt;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(SUBAGENT_TOOL_NAME, '{}', FCtx);
  AssertTrue('an empty prompt is rejected', O.IsError);
  AssertTrue('message about prompt', Pos('prompt', O.Text) > 0);
end;

{ The subagent nesting depth is limited. }
procedure TSubAgentToolTests.TestSubagentDepthLimit;
var
  O: TToolOutcome;
begin
  FCtx.SubAgentDepth := MAX_SUBAGENT_DEPTH;
  O := FReg.Invoke(SUBAGENT_TOOL_NAME, '{"prompt":"test"}', FCtx);
  AssertTrue('the depth is limited', O.IsError);
  AssertTrue('message about the depth', Pos('nesting depth', O.Text) > 0);
end;

{ An empty final answer of the subagent is an error, not silence: otherwise no
  result line would appear in the UI at all. }
procedure TSubAgentToolTests.TestSubagentEmptyAnswer;
var
  O: TToolOutcome;
begin
  O := SubagentOutcome('');
  AssertTrue('an empty answer is an error', O.IsError);
  AssertTrue('the message mentions the text', Pos('final text', O.Text) > 0);

  O := SubagentOutcome('   ');
  AssertTrue('spaces are an empty answer too', O.IsError);

  O := SubagentOutcome('  answer  ');
  AssertFalse('a non-empty answer is not an error: ' + O.Text, O.IsError);
  AssertEquals('the answer is trimmed', 'answer', O.Text);
end;

{ The tool is registered, but the key http_request=0 in [tools] forbids the
  request. }
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
    AssertTrue('http is disabled by the key', O.IsError);
    AssertTrue('the message names the tool: ' + O.Text,
      Pos('tool "http_request" is disabled', O.Text) > 0);
  finally
    R2.Free;
  end;
end;

{ By default OnSubAgentEvent is not assigned in the context (nil). }
procedure TSubAgentToolTests.TestContextOnSubAgentEventDefault;
begin
  AssertFalse('OnSubAgentEvent is nil by default',
    Assigned(FCtx.OnSubAgentEvent));
end;

{ A non-empty final answer of the subagent is not an error, the text is
  trimmed. }
procedure TSubAgentToolTests.TestSubagentOutcomeNonEmpty;
var
  O: TToolOutcome;
begin
  O := SubagentOutcome('  work result  ');
  AssertFalse('a non-empty answer is not an error', O.IsError);
  AssertEquals('the text is trimmed', 'work result', O.Text);
end;

{ The tools array of the request matches the [tools] table: every name is known
  to the table, and every key of it reaches the request -- except revise_plan,
  which is registered by the planner rather than by the session set. This way
  the test catches a mismatch between the table and the registry. }
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
    AssertTrue('the request is not empty', Names.Count > 0);
    { Upwards: no name outside the table. }
    for I := 0 to Names.Count - 1 do
      AssertTrue('a name from the table: ' + Names[I],
        IsKnownToolName(Names[I]));
    { Downwards: every key of the table, except revise_plan, is in the request. }
    for I := 0 to ToolSwitchCount - 1 do
    begin
      Name := ToolSwitchAt(I).Name;
      if Name = 'revise_plan' then
        Continue;
      AssertTrue('the request contains ' + Name, Names.IndexOf(Name) >= 0);
    end;
  finally
    Names.Free;
    R.Free;
  end;
end;

{ A tool disabled by its key does not get into the tools array of the request,
  while an enabled one does. }
procedure TSubAgentToolTests.TestDisabledToolAbsentFromRequest;
var
  Cfg: TMirmidConfig;
  R: TToolRegistry;
  S: string;
begin
  { By default shell is disabled: it is not in the tools array of the request. }
  Cfg := DefaultConfig;
  R := TToolRegistry.Create;
  try
    RegisterSessionTools(R, Cfg);
    S := RequestToolNames(R);
    AssertEquals('shell is disabled -- absent from the request', -1,
      S.IndexOf('shell'));
    AssertTrue('file_list is enabled -- present in the request',
      S.IndexOf('file_list') >= 0);
  finally
    R.Free;
  end;

  { The key shell=1 -- the tool is back in the request. }
  Cfg := DefaultConfig;
  SetToolEnabled(Cfg, 'shell', True);
  R := TToolRegistry.Create;
  try
    RegisterSessionTools(R, Cfg);
    S := RequestToolNames(R);
    AssertTrue('shell is enabled -- present in the request',
      S.IndexOf('shell') >= 0);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TSubAgentToolTests);

end.
