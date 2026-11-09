unit test_mcp;
{ Tests of MCP support: tool names, the JSON-RPC client (over a fake
  transport), the server manager, mcp.json parsing and integration with a
  real server process, bin/fakemcp. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpcunit, testregistry, mirmid.tools, mirmid.mcp;

type
  { Fake transport: answers requests without a process. }
  TFakeTransport = class(TMCPTransport)
  private
    FQueue: TStringList;
    FStarted: Boolean;
    FSent: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    function Running: Boolean; override;
    procedure Send(const Line: string); override;
    function Receive(TimeoutMs: Integer; out Line: string; out Err: string): Boolean; override;
    property Sent: Integer read FSent;
  end;

  TMcpTests = class(TTestCase)
  private
    function TempFile(const Content: string): string;
  published
    procedure TestSanitizeName;
    procedure TestFullToolName;
    procedure TestClientHandshakeAndList;
    procedure TestClientCallTool;
    procedure TestClientToolIsError;
    procedure TestClientJsonRpcError;
    procedure TestManagerRegistersAndInvokes;
    procedure TestManagerToolError;
    procedure TestManagerJsonRpcError;
    procedure TestLoadFromFileMissing;
    procedure TestLoadFromFileBadJson;
    procedure TestLoadFromFileNoServers;
    procedure TestStdioTransportIntegration;
  end;

implementation

uses
  SysUtils, fpjson, mirmid.types, mirmid.json;

{ ------------------------------------------------------------ fake transport }

constructor TFakeTransport.Create;
begin
  inherited Create;
  FQueue := TStringList.Create;
  FStarted := False;
  FSent := 0;
end;

destructor TFakeTransport.Destroy;
begin
  FQueue.Free;
  inherited Destroy;
end;

procedure TFakeTransport.Start;
begin
  FStarted := True;
end;

procedure TFakeTransport.Stop;
begin
  FStarted := False;
end;

function TFakeTransport.Running: Boolean;
begin
  Result := FStarted;
end;

function FakeSchema(const Prop: string): TJSONObject;
var
  Props: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'object');
  Props := TJSONObject.Create;
  if Prop <> '' then
    Props.Add(Prop, TJSONObject.Create(['type', 'string']));
  Result.Add('properties', Props);
end;

function FakeTools: TJSONArray;
var
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  O := TJSONObject.Create;
  O.Add('name', 'echo');
  O.Add('description', 'Echoes the text');
  O.Add('inputSchema', FakeSchema('text'));
  Result.Add(O);

  O := TJSONObject.Create;
  O.Add('name', 'boom');
  O.Add('description', 'Tool error');
  O.Add('inputSchema', FakeSchema(''));
  Result.Add(O);

  O := TJSONObject.Create;
  O.Add('name', 'fail');
  O.Add('description', 'JSON-RPC error');
  O.Add('inputSchema', FakeSchema(''));
  Result.Add(O);
end;

function FakeTextContent(const S: string; IsErr: Boolean): TJSONObject;
var
  Arr: TJSONArray;
  Item: TJSONObject;
begin
  Arr := TJSONArray.Create;
  Item := TJSONObject.Create;
  Item.Add('type', 'text');
  Item.Add('text', S);
  Arr.Add(Item);
  Result := TJSONObject.Create;
  Result.Add('content', Arr);
  if IsErr then
    Result.Add('isError', True);
end;

procedure TFakeTransport.Send(const Line: string);
var
  D: TJSONData;
  Err, Method, TName, EMsg: string;
  Id: Integer;
  O, Res, ErrO: TJSONObject;
begin
  Inc(FSent);
  if not ParseJSON(Line, D, Err) then
    Exit;
  try
    Method := JStr(D, 'method', '');
    if Method = 'notifications/initialized' then
      Exit;   { notification - no response }
    Id := JInt(D, 'id', 0);

    O := TJSONObject.Create;
    O.Add('jsonrpc', '2.0');
    O.Add('id', Id);

    if Method = 'initialize' then
    begin
      Res := TJSONObject.Create;
      Res.Add('protocolVersion', '2024-11-05');
      Res.Add('capabilities', TJSONObject.Create);
      Res.Add('serverInfo', TJSONObject.Create(['name', 'fake', 'version', '1.0']));
      O.Add('result', Res);
    end
    else if Method = 'tools/list' then
    begin
      Res := TJSONObject.Create;
      Res.Add('tools', FakeTools);
      O.Add('result', Res);
    end
    else if Method = 'tools/call' then
    begin
      TName := JStr(D, 'params.name', '');
      if TName = 'fail' then
      begin
        { Through a variable: a direct literal in Add with a UTF8String
          parameter loses its encoding at compile time. }
        EMsg := 'internal error';
        ErrO := TJSONObject.Create;
        ErrO.Add('code', -32603);
        ErrO.Add('message', EMsg);
        O.Add('error', ErrO);
      end
      else if TName = 'echo' then
        O.Add('result', FakeTextContent(JStr(D, 'params.arguments.text', ''), False))
      else if TName = 'boom' then
        O.Add('result', FakeTextContent('something went wrong', True))
      else
        O.Add('result', FakeTextContent('unknown tool', True));
    end
    else
    begin
      ErrO := TJSONObject.Create;
      ErrO.Add('code', -32601);
      ErrO.Add('message', 'method not found');
      O.Add('error', ErrO);
    end;

    FQueue.Add(O.AsJSON);
    O.Free;
  finally
    D.Free;
  end;
end;

function TFakeTransport.Receive(TimeoutMs: Integer; out Line: string;
  out Err: string): Boolean;
begin
  Line := '';
  Err := '';
  if FQueue.Count = 0 then
  begin
    Err := 'no response (fake transport)';
    Exit(False);
  end;
  Line := FQueue[0];
  FQueue.Delete(0);
  Result := True;
end;

{ ------------------------------------------------------------------- tests }

function TMcpTests.TempFile(const Content: string): string;
var
  SL: TStringList;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    'mirmid_mcp_test_' + IntToStr(Random(1000000)) + '.json';
  SL := TStringList.Create;
  try
    SL.Text := Content;
    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;

procedure TMcpTests.TestSanitizeName;
begin
  AssertEquals('spaces and punctuation', 'my_server_a-b', MCPSanitizeName('my server/a-b'));
  AssertEquals('empty name', 'x', MCPSanitizeName(''));
  { The replacement works byte-wise on UTF-8: "grüße" is 7 bytes, none allowed. }
  AssertEquals('multi-byte UTF-8', 'gr____e', MCPSanitizeName('grüße'));
end;

procedure TMcpTests.TestFullToolName;
begin
  AssertEquals('full name', 'mcp__demo__echo',
    MCPFullToolName('demo', 'echo'));
  AssertEquals('invalid characters replaced', 'mcp__my_srv__a_b',
    MCPFullToolName('my srv', 'a.b'));
end;

procedure TMcpTests.TestClientHandshakeAndList;
var
  C: TMCPClient;
  Tools: TJSONArray;
  Err: string;
begin
  C := TMCPClient.Create('fake', TFakeTransport.Create, 5);
  try
    AssertTrue('initialize', C.Initialize(Err));
    AssertEquals('server name', 'fake', C.ServerInfo);
    AssertTrue('tools/list', C.ListTools(Tools, Err));
    try
      AssertEquals('tool count', 3, Tools.Count);
      AssertEquals('first tool', 'echo', JStr(Tools.Items[0], 'name', ''));
    finally
      Tools.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TMcpTests.TestClientCallTool;
var
  C: TMCPClient;
  Text, Err: string;
  IsErr: Boolean;
begin
  C := TMCPClient.Create('fake', TFakeTransport.Create, 5);
  try
    AssertTrue('initialize', C.Initialize(Err));
    AssertTrue('tools/call', C.CallTool('echo', '{"text":"grüße"}', Text, IsErr, Err));
    AssertFalse('no error', IsErr);
    AssertEquals('answer text', 'grüße', Text);
  finally
    C.Free;
  end;
end;

procedure TMcpTests.TestClientToolIsError;
var
  C: TMCPClient;
  Text, Err: string;
  IsErr: Boolean;
begin
  C := TMCPClient.Create('fake', TFakeTransport.Create, 5);
  try
    AssertTrue('initialize', C.Initialize(Err));
    AssertTrue('tools/call', C.CallTool('boom', '{}', Text, IsErr, Err));
    AssertTrue('isError', IsErr);
    AssertEquals('error text', 'something went wrong', Text);
  finally
    C.Free;
  end;
end;

procedure TMcpTests.TestClientJsonRpcError;
var
  C: TMCPClient;
  Text, Err: string;
  IsErr: Boolean;
begin
  C := TMCPClient.Create('fake', TFakeTransport.Create, 5);
  try
    AssertTrue('initialize', C.Initialize(Err));
    AssertFalse('no response received', C.CallTool('fail', '{}', Text, IsErr, Err));
    AssertTrue('there is an error message: ' + Err,
      Pos('internal error', Err) > 0);
  finally
    C.Free;
  end;
end;

procedure TMcpTests.TestManagerRegistersAndInvokes;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  Err: string;
  O: TToolOutcome;
begin
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 5);
  try
    AssertTrue('server added', Mcp.AddServer('fake', TFakeTransport.Create, Err));
    AssertEquals('tool count', 3, Mcp.ToolCount);
    AssertTrue('tool in the registry', Reg.Has('mcp__fake__echo'));
    O := Reg.Invoke('mcp__fake__echo', '{"text":"ok"}', MakeToolContext(DefaultConfig));
    AssertFalse('no error', O.IsError);
    AssertEquals('result', 'ok', O.Text);
  finally
    Mcp.Free;
    Reg.Free;
  end;
end;

procedure TMcpTests.TestManagerToolError;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  Err: string;
  O: TToolOutcome;
begin
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 5);
  try
    AssertTrue('server added', Mcp.AddServer('fake', TFakeTransport.Create, Err));
    O := Reg.Invoke('mcp__fake__boom', '{}', MakeToolContext(DefaultConfig));
    AssertTrue('tool error', O.IsError);
    AssertTrue('error text', Pos('went wrong', O.Text) > 0);
  finally
    Mcp.Free;
    Reg.Free;
  end;
end;

procedure TMcpTests.TestManagerJsonRpcError;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  Err: string;
  O: TToolOutcome;
begin
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 5);
  try
    AssertTrue('server added', Mcp.AddServer('fake', TFakeTransport.Create, Err));
    O := Reg.Invoke('mcp__fake__fail', '{}', MakeToolContext(DefaultConfig));
    AssertTrue('protocol error', O.IsError);
    AssertTrue('error message', Pos('MCP error', O.Text) > 0);
  finally
    Mcp.Free;
    Reg.Free;
  end;
end;

procedure TMcpTests.TestLoadFromFileMissing;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  W: TStringList;
begin
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 5);
  W := TStringList.Create;
  try
    Mcp.LoadFromFile('/nonexistent/mirmid/mcp.json', W);
    AssertEquals('no tools', 0, Mcp.ToolCount);
    AssertTrue('there is a warning', W.Count > 0);
    AssertTrue('about the file', Pos('not found', W.Text) > 0);
  finally
    W.Free;
    Mcp.Free;
    Reg.Free;
  end;
end;

procedure TMcpTests.TestLoadFromFileBadJson;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  W: TStringList;
  F: string;
begin
  F := TempFile('{ not json');
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 5);
  W := TStringList.Create;
  try
    Mcp.LoadFromFile(F, W);
    AssertEquals('no tools', 0, Mcp.ToolCount);
    AssertTrue('there is a warning', W.Count > 0);
    AssertTrue('about JSON', Pos('JSON', W.Text) > 0);
  finally
    W.Free;
    Mcp.Free;
    Reg.Free;
    DeleteFile(F);
  end;
end;

procedure TMcpTests.TestLoadFromFileNoServers;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  W: TStringList;
  F: string;
begin
  F := TempFile('{"other":1}');
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 5);
  W := TStringList.Create;
  try
    Mcp.LoadFromFile(F, W);
    AssertEquals('no tools', 0, Mcp.ToolCount);
    AssertTrue('there is a warning', W.Count > 0);
    AssertTrue('about mcpServers', Pos('mcpServers', W.Text) > 0);
  finally
    W.Free;
    Mcp.Free;
    Reg.Free;
    DeleteFile(F);
  end;
end;

procedure TMcpTests.TestStdioTransportIntegration;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  Args, Env: TStringList;
  Err: string;
  O: TToolOutcome;
  Exe: string;
  Started: Boolean;
begin
  Exe := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'fakemcp';
  if not FileExists(Exe) then
    Exit;   { integration server not built - test skipped }

  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 10);
  Args := TStringList.Create;
  Env := TStringList.Create;
  try
    Started := Mcp.AddServer('fake', TStdioTransport.Create(Exe, Args, Env, ''), Err);
    AssertTrue('server started: ' + Err, Started);
    AssertTrue('tool registered', Reg.Has('mcp__fake__echo'));
    O := Reg.Invoke('mcp__fake__echo', '{"text":"via the process"}',
      MakeToolContext(DefaultConfig));
    AssertFalse('no error', O.IsError);
    AssertEquals('result', 'via the process', O.Text);
  finally
    Env.Free;
    Args.Free;
    Mcp.Free;
    Reg.Free;
  end;
end;

initialization
  Randomize;
  RegisterTest(TMcpTests);

end.
