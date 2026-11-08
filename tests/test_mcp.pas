unit test_mcp;
{ Тесты поддержки MCP: имена инструментов, JSON-RPC клиент (на подставном
  транспорте), менеджер серверов, разбор mcp.json и интеграция с реальным
  процессом-сервером bin/fakemcp. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpcunit, testregistry, mirmid.tools, mirmid.mcp;

type
  { Подставной транспорт: отвечает на запросы без процесса. }
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
  O.Add('description', 'Повторяет текст');
  O.Add('inputSchema', FakeSchema('text'));
  Result.Add(O);

  O := TJSONObject.Create;
  O.Add('name', 'boom');
  O.Add('description', 'Ошибка инструмента');
  O.Add('inputSchema', FakeSchema(''));
  Result.Add(O);

  O := TJSONObject.Create;
  O.Add('name', 'fail');
  O.Add('description', 'Ошибка JSON-RPC');
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
      Exit;   { уведомление — ответа нет }
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
        { Через переменную: прямой литерал в Add с UTF8String-параметром
          теряет кодировку при компиляции. }
        EMsg := 'внутренняя ошибка';
        ErrO := TJSONObject.Create;
        ErrO.Add('code', -32603);
        ErrO.Add('message', EMsg);
        O.Add('error', ErrO);
      end
      else if TName = 'echo' then
        O.Add('result', FakeTextContent(JStr(D, 'params.arguments.text', ''), False))
      else if TName = 'boom' then
        O.Add('result', FakeTextContent('что-то пошло не так', True))
      else
        O.Add('result', FakeTextContent('неизвестный инструмент', True));
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
    Err := 'нет ответа (подставной транспорт)';
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
  AssertEquals('пробелы и знаки', 'my_server_a-b', MCPSanitizeName('my server/a-b'));
  AssertEquals('пустое имя', 'x', MCPSanitizeName(''));
  { Замена идёт по байтам UTF-8: «тест» — 8 байт, все внедопустимы. }
  AssertEquals('кириллица', '________', MCPSanitizeName('тест'));
end;

procedure TMcpTests.TestFullToolName;
begin
  AssertEquals('полное имя', 'mcp__demo__echo',
    MCPFullToolName('demo', 'echo'));
  AssertEquals('недопустимые символы заменены', 'mcp__my_srv__a_b',
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
    AssertEquals('имя сервера', 'fake', C.ServerInfo);
    AssertTrue('tools/list', C.ListTools(Tools, Err));
    try
      AssertEquals('число инструментов', 3, Tools.Count);
      AssertEquals('первый инструмент', 'echo', JStr(Tools.Items[0], 'name', ''));
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
    AssertTrue('tools/call', C.CallTool('echo', '{"text":"привет"}', Text, IsErr, Err));
    AssertFalse('не ошибка', IsErr);
    AssertEquals('текст ответа', 'привет', Text);
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
    AssertEquals('текст ошибки', 'что-то пошло не так', Text);
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
    AssertFalse('ответ не получен', C.CallTool('fail', '{}', Text, IsErr, Err));
    AssertTrue('есть сообщение об ошибке: ' + Err,
      Pos('внутренняя ошибка', Err) > 0);
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
    AssertTrue('сервер добавлен', Mcp.AddServer('fake', TFakeTransport.Create, Err));
    AssertEquals('число инструментов', 3, Mcp.ToolCount);
    AssertTrue('инструмент в реестре', Reg.Has('mcp__fake__echo'));
    O := Reg.Invoke('mcp__fake__echo', '{"text":"ok"}', MakeToolContext(DefaultConfig));
    AssertFalse('без ошибки', O.IsError);
    AssertEquals('результат', 'ok', O.Text);
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
    AssertTrue('сервер добавлен', Mcp.AddServer('fake', TFakeTransport.Create, Err));
    O := Reg.Invoke('mcp__fake__boom', '{}', MakeToolContext(DefaultConfig));
    AssertTrue('ошибка инструмента', O.IsError);
    AssertTrue('текст ошибки', Pos('пошло не так', O.Text) > 0);
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
    AssertTrue('сервер добавлен', Mcp.AddServer('fake', TFakeTransport.Create, Err));
    O := Reg.Invoke('mcp__fake__fail', '{}', MakeToolContext(DefaultConfig));
    AssertTrue('ошибка протокола', O.IsError);
    AssertTrue('сообщение об ошибке', Pos('ошибка MCP', O.Text) > 0);
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
    AssertEquals('инструментов нет', 0, Mcp.ToolCount);
    AssertTrue('есть предупреждение', W.Count > 0);
    AssertTrue('про файл', Pos('не найден', W.Text) > 0);
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
  F := TempFile('{ это не json');
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 5);
  W := TStringList.Create;
  try
    Mcp.LoadFromFile(F, W);
    AssertEquals('инструментов нет', 0, Mcp.ToolCount);
    AssertTrue('есть предупреждение', W.Count > 0);
    AssertTrue('про JSON', Pos('JSON', W.Text) > 0);
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
    AssertEquals('инструментов нет', 0, Mcp.ToolCount);
    AssertTrue('есть предупреждение', W.Count > 0);
    AssertTrue('про mcpServers', Pos('mcpServers', W.Text) > 0);
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
    Exit;   { интеграционный сервер не собран — тест пропускается }

  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, 10);
  Args := TStringList.Create;
  Env := TStringList.Create;
  try
    Started := Mcp.AddServer('fake', TStdioTransport.Create(Exe, Args, Env, ''), Err);
    AssertTrue('сервер запущен: ' + Err, Started);
    AssertTrue('инструмент зарегистрирован', Reg.Has('mcp__fake__echo'));
    O := Reg.Invoke('mcp__fake__echo', '{"text":"через процесс"}',
      MakeToolContext(DefaultConfig));
    AssertFalse('без ошибки', O.IsError);
    AssertEquals('результат', 'через процесс', O.Text);
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
