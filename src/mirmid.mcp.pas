unit mirmid.mcp;
{ MCP (Model Context Protocol) support: connecting external tool servers.
  The stdio transport is implemented -- JSON-RPC 2.0, one object per line,
  through the stdin/stdout of the child process.

  Servers are described in the mcp.json file (a format compatible with Claude
  Desktop): an object mcpServers where the key is the server name and the value
  is an object with the fields command, args, env, cwd, enabled, timeout.

  The tools of a server are registered in the registry under the name
  mcp__<server>__<tool> (characters that are invalid in a function name are
  replaced with an underscore, the length is limited to 64 characters). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, process, fpjson, mirmid.tools, mirmid.types;

const
  { Prefix of the MCP tool names in the registry. }
  MCP_PREFIX = 'mcp__';
  { MCP protocol version the client offers. }
  MCP_PROTOCOL_VERSION = '2024-11-05';
  { Length limit of one protocol line (protection against garbage in the stream). }
  MAX_MCP_LINE = 16 * 1024 * 1024;

{ Full tool name in the registry: mcp__<server>__<tool>. }
function MCPFullToolName(const Server, Tool: string): string;
{ Canonicalises a name component (A-Za-z0-9_-), replacing the rest with "_". }
function MCPSanitizeName(const S: string): string;
{ Default path to mcp.json: $MIRMID_MCP_CONFIG, then <WorkDir>/.mirmid/mcp.json.
  If the file is missing, <WorkDir>/.mirmid/mcp.json is returned. }
function DefaultMcpConfigPath(const WorkDir: string): string;

type
  { Abstract MCP transport: exchange of JSON-RPC lines. }
  TMCPTransport = class
  public
    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    function Running: Boolean; virtual; abstract;
    { Sends one JSON object (without the trailing newline). }
    procedure Send(const Line: string); virtual; abstract;
    { Reads one message (a JSON line) with the TimeoutMs timeout.
      False -- timeout/EOF/error (Err is filled). }
    function Receive(TimeoutMs: Integer; out Line: string; out Err: string): Boolean; virtual; abstract;
  end;

  { stdio transport: starts the server process and talks through its
    stdin/stdout. The stderr of the child process is drained so the server does
    not block. }
  TStdioTransport = class(TMCPTransport)
  private
    FCommand: string;
    FArgs: TStringList;
    FEnv: TStringList;
    FWorkDir: string;
    FProcess: TProcess;
    FBuf: RawByteString;
    FStderrLog: string;
    procedure DrainStderr;
  public
    constructor Create(const ACommand: string; AArgs, AEnv: TStrings;
      const AWorkDir: string);
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    function Running: Boolean; override;
    procedure Send(const Line: string); override;
    function Receive(TimeoutMs: Integer; out Line: string; out Err: string): Boolean; override;
    { The last lines of the server stderr (for diagnosing errors). }
    property StderrLog: string read FStderrLog;
  end;

  { Client of a single MCP server. Owns the transport. }
  TMCPClient = class
  private
    FName: string;
    FTransport: TMCPTransport;
    FTimeout: Integer;
    FNextId: Integer;
    FServerInfo: string;
    FProtocolVersion: string;
    { JSON-RPC request. Takes Params over (frees it together with the request
      object). Res is a copy of the response, freed by the caller. }
    function Request(const Method: string; Params: TJSONObject;
      out Res: TJSONData; out Err: string): Boolean;
    { JSON-RPC notification (no id). Takes Params over. }
    function Notify(const Method: string; Params: TJSONObject; out Err: string): Boolean;
  public
    constructor Create(const AName: string; ATransport: TMCPTransport;
      TimeoutSec: Integer);
    destructor Destroy; override;
    { Handshake: initialize + notifications/initialized. }
    function Initialize(out Err: string): Boolean;
    { tools/list; Tools is a new copy of the description array (freed by the
      caller). }
    function ListTools(out Tools: TJSONArray; out Err: string): Boolean;
    { tools/call. IsError means a tool error (isError=true) rather than a
      protocol failure: Err stays empty in that case. }
    function CallTool(const ToolName, ArgsJson: string;
      out Text: string; out IsError: Boolean; out Err: string): Boolean;
    property Name: string read FName;
    property ServerInfo: string read FServerInfo;
    property ProtocolVersion: string read FProtocolVersion;
  end;

  TMCPManager = class;

  { Handler of a single MCP tool: keeps a reference to the manager and the index. }
  TMCPHandler = class
  private
    FManager: TMCPManager;
    FIndex: Integer;
  public
    constructor Create(AManager: TMCPManager; AIndex: Integer);
    function Call(const Args: TJSONObject; const Ctx: TToolContext): TToolOutcome;
  end;

  { MCP server manager: starts the servers, registers their tools in the
    registry and proxies the calls. Owns the clients and the handlers; the tool
    schemas are freed by the registry. }
  TMCPManager = class
  private
    FRegistry: TToolRegistry;
    FTimeout: Integer;
    FClients: array of TMCPClient;
    FClientNames: array of string;
    FHandlers: array of TMCPHandler;
    FFullNames: array of string;
    FServerOfTool: array of string;
    FOrigNameOfTool: array of string;
    function UniqueFullName(const Base: string): string;
    function FindTool(const FullName: string): Integer;
    function ClientByName(const Server: string): TMCPClient;
  public
    constructor Create(ARegistry: TToolRegistry; TimeoutSec: Integer);
    destructor Destroy; override;
    { Starts the server, performs the handshake, fetches the tool list and
      registers the tools. The transport is taken over by the manager in any
      case (it is freed on error). }
    function AddServer(const Name: string; Transport: TMCPTransport;
      out Err: string): Boolean;
    { Reads mcp.json and connects all enabled servers. Errors of individual
      servers go to Warnings and do not interrupt loading the others. }
    procedure LoadFromFile(const FileName: string; var Warnings: TStringList);
    function CallTool(const FullName, ArgsJson: string;
      out Text: string; out IsError: Boolean; out Err: string): Boolean;
    function EntryFullName(Index: Integer): string;
    function ToolCount: Integer;
    { List of tools, one per line: "name [server: original]". }
    function ToolList: string;
    function ServerCount: Integer;
    function ServerList: string;
  end;

implementation

uses
  mirmid.util, mirmid.json, mirmid.version;

{ ------------------------------------------------------------------ helpers }

function MCPSanitizeName(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-'] then
      Result := Result + C
    else
      Result := Result + '_';
  end;
  if Result = '' then
    Result := 'x';
end;

function MCPFullToolName(const Server, Tool: string): string;
begin
  Result := MCP_PREFIX + MCPSanitizeName(Server) + '__' + MCPSanitizeName(Tool);
end;

function DefaultMcpConfigPath(const WorkDir: string): string;
var
  P: string;
begin
  P := GetEnvironmentVariable('MIRMID_MCP_CONFIG');
  if P <> '' then
    Exit(P);

  Result := IncludeTrailingPathDelimiter(WorkDir) + '.mirmid' + PathDelim + 'mcp.json';
end;

{ Adds the environment lines of the current process, replacing values from Extra. }
procedure FillEnvironment(Env: TProcessStrings; Extra: TStrings);
var
  I, J: Integer;
  Item, Key: string;
begin
  Env.Clear;
  EnvironmentToList(Env);
  for I := 0 to Extra.Count - 1 do
  begin
    Item := Extra[I];
    Key := Copy(Item, 1, Pos('=', Item));   { together with the '=' sign }
    if Key = '' then
      Continue;
    for J := Env.Count - 1 downto 0 do
      if Copy(Env[J], 1, Length(Key)) = Key then
        Env.Delete(J);
    Env.Add(Item);
  end;
end;

{ ------------------------------------------------------------ stdio transport }

constructor TStdioTransport.Create(const ACommand: string; AArgs, AEnv: TStrings;
  const AWorkDir: string);
begin
  inherited Create;
  FCommand := ACommand;
  FWorkDir := AWorkDir;
  FArgs := TStringList.Create;
  FEnv := TStringList.Create;
  if AArgs <> nil then
    FArgs.Assign(AArgs);
  if AEnv <> nil then
    FEnv.Assign(AEnv);
  FProcess := nil;
  FBuf := '';
  FStderrLog := '';
end;

destructor TStdioTransport.Destroy;
begin
  Stop;
  FArgs.Free;
  FEnv.Free;
  inherited Destroy;
end;

procedure TStdioTransport.Start;
var
  I: Integer;
begin
  if FProcess <> nil then
    Exit;
  FProcess := TProcess.Create(nil);
  FProcess.Executable := FCommand;
  for I := 0 to FArgs.Count - 1 do
    FProcess.Parameters.Add(FArgs[I]);
  if FWorkDir <> '' then
    FProcess.CurrentDirectory := FWorkDir;
  FProcess.Options := [poUsePipes];
  if FEnv.Count > 0 then
    FillEnvironment(FProcess.Environment, FEnv);
  FProcess.Execute;
end;

procedure TStdioTransport.Stop;
begin
  if FProcess = nil then
    Exit;
  try
    FProcess.CloseInput;
  except
    { the process may have exited already }
  end;
  try
    if FProcess.Running then
      FProcess.Terminate(0);
  except
    { ignore termination errors }
  end;
  try
    FProcess.WaitOnExit(1000);
  except
    { ignore }
  end;
  FreeAndNil(FProcess);
  FBuf := '';
end;

function TStdioTransport.Running: Boolean;
begin
  Result := (FProcess <> nil) and FProcess.Running;
end;

procedure TStdioTransport.DrainStderr;
var
  Buf: array[0..4095] of Byte;
  N: LongInt;
  Chunk: RawByteString;
begin
  if FProcess = nil then
    Exit;
  while FProcess.Stderr.NumBytesAvailable > 0 do
  begin
    N := FProcess.Stderr.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    SetLength(Chunk, N);
    Move(Buf[0], Chunk[1], N);
    FStderrLog := FStderrLog + Chunk;
    if Length(FStderrLog) > 16384 then
      FStderrLog := Copy(FStderrLog, Length(FStderrLog) - 16384, 16384);
  end;
end;

procedure TStdioTransport.Send(const Line: string);
var
  S: RawByteString;
begin
  if FProcess = nil then
    raise Exception.Create('MCP process is not running');
  S := Line + #10;
  FProcess.Input.WriteBuffer(S[1], Length(S));
end;

function TStdioTransport.Receive(TimeoutMs: Integer; out Line: string;
  out Err: string): Boolean;
var
  Deadline: QWord;
  P, N: Integer;
  Buf: array[0..65535] of Byte;
  Chunk: RawByteString;
begin
  Line := '';
  Err := '';
  if TimeoutMs < 1 then
    TimeoutMs := 1;
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  repeat
    P := Pos(#10, FBuf);
    if P > 0 then
    begin
      Line := Copy(FBuf, 1, P - 1);
      Delete(FBuf, 1, P);
      if (Line <> '') and (Line[Length(Line)] = #13) then
        Delete(Line, Length(Line), 1);
      Exit(True);
    end;

    if FProcess = nil then
    begin
      Err := 'MCP process is not running';
      Exit(False);
    end;

    DrainStderr;

    if FProcess.Output.NumBytesAvailable > 0 then
    begin
      N := FProcess.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetLength(Chunk, N);
        Move(Buf[0], Chunk[1], N);
        FBuf := FBuf + Chunk;
        if Length(FBuf) > MAX_MCP_LINE then
        begin
          Err := 'MCP message exceeds the size limit';
          Exit(False);
        end;
        Continue;   { check again for a complete line right away }
      end;
    end;

    if (not FProcess.Running) and (FProcess.Output.NumBytesAvailable = 0) then
    begin
      if FBuf <> '' then
      begin
        Line := FBuf;
        FBuf := '';
        Exit(True);
      end;
      DrainStderr;
      Err := 'MCP server exited';
      if Trim(FStderrLog) <> '' then
        Err := Err + ': ' + Trim(FStderrLog);
      Exit(False);
    end;

    Sleep(10);
  until GetTickCount64 >= Deadline;

  Err := Format('MCP response timeout (%d ms)', [TimeoutMs]);
  Result := False;
end;

{ ------------------------------------------------------------------- client }

constructor TMCPClient.Create(const AName: string; ATransport: TMCPTransport;
  TimeoutSec: Integer);
begin
  inherited Create;
  FName := AName;
  FTransport := ATransport;
  if TimeoutSec < 1 then
    TimeoutSec := DEFAULT_MCP_TIMEOUT;
  FTimeout := TimeoutSec;
  FNextId := 0;
  FServerInfo := '';
  FProtocolVersion := '';
end;

destructor TMCPClient.Destroy;
begin
  if FTransport <> nil then
  begin
    FTransport.Stop;
    FTransport.Free;
  end;
  inherited Destroy;
end;

function TMCPClient.Notify(const Method: string; Params: TJSONObject;
  out Err: string): Boolean;
var
  O: TJSONObject;
begin
  Result := False;
  Err := '';
  O := TJSONObject.Create;
  try
    O.Add('jsonrpc', '2.0');
    O.Add('method', Method);
    if Params <> nil then
      O.Add('params', Params)
    else
      O.Add('params', TJSONObject.Create);
    try
      FTransport.Send(O.AsJSON);
      Result := True;
    except
      on E: Exception do
        Err := 'failed to send the MCP message: ' + E.Message;
    end;
  finally
    O.Free;
  end;
end;

function TMCPClient.Request(const Method: string; Params: TJSONObject;
  out Res: TJSONData; out Err: string): Boolean;
var
  Id: Integer;
  O: TJSONObject;
  Line, RErr, EMsg: string;
  D, X: TJSONData;
  Deadline: QWord;
  Remaining: Integer;
  BadLine: string;
begin
  Result := False;
  Res := nil;
  Err := '';
  BadLine := '';
  Inc(FNextId);
  Id := FNextId;

  O := TJSONObject.Create;
  try
    O.Add('jsonrpc', '2.0');
    O.Add('id', Id);
    O.Add('method', Method);
    if Params <> nil then
      O.Add('params', Params)
    else
      O.Add('params', TJSONObject.Create);
    try
      FTransport.Send(O.AsJSON);
    except
      on E: Exception do
      begin
        Err := 'failed to send the MCP request: ' + E.Message;
        Exit;
      end;
    end;
  finally
    O.Free;
  end;

  Deadline := GetTickCount64 + QWord(FTimeout) * 1000;
  repeat
    Remaining := Integer(Deadline - GetTickCount64);
    if not FTransport.Receive(Remaining, Line, RErr) then
    begin
      Err := RErr;
      if Trim(BadLine) <> '' then
        Err := Err + sLineBreak + 'invalid line from the server: ' +
          Copy(BadLine, 1, 200);
      Exit(False);
    end;

    if Trim(Line) = '' then
      Continue;

    D := nil;
    if not ParseJSON(Line, D, RErr) then
    begin
      BadLine := Line;
      Continue;
    end;
    try
      { Skip notifications (no id) and responses to other requests. }
      X := D.FindPath('id');
      if (X = nil) or not (X is TJSONNumber) then
        Continue;
      if X.AsInteger <> Id then
        Continue;

      X := D.FindPath('error');
      if X <> nil then
      begin
        EMsg := JStr(X, 'message', '');
        if EMsg = '' then
          EMsg := X.AsJSON;
        Err := 'MCP error ' + JStr(X, 'code', '') + ': ' + EMsg;
        Exit(False);
      end;

      X := D.FindPath('result');
      if X <> nil then
        Res := X.Clone
      else
        Res := TJSONObject.Create;
      Result := True;
      Exit;
    finally
      D.Free;
    end;
  until GetTickCount64 >= Deadline;

  Err := Format('MCP server response timeout (%.1f s)', [FTimeout]);
  Result := False;
end;

function TMCPClient.Initialize(out Err: string): Boolean;
var
  Params, Info: TJSONObject;
  Res: TJSONData;
begin
  Result := False;
  Err := '';
  { Request takes Params over (frees it together with the request). }
  Params := TJSONObject.Create;
  Params.Add('protocolVersion', MCP_PROTOCOL_VERSION);
  Params.Add('capabilities', TJSONObject.Create);
  Info := TJSONObject.Create;
  Info.Add('name', MIRMID_NAME);
  Info.Add('version', MIRMID_VERSION);
  Params.Add('clientInfo', Info);

  if not Request('initialize', Params, Res, Err) then
    Exit;
  try
    FServerInfo := JStr(Res, 'serverInfo.name', '');
    FProtocolVersion := JStr(Res, 'protocolVersion', '');
  finally
    Res.Free;
  end;

  { Notification about the successful initialisation. }
  if not Notify('notifications/initialized', nil, Err) then
    Exit;
  Result := True;
end;

function TMCPClient.ListTools(out Tools: TJSONArray; out Err: string): Boolean;
var
  Res, X: TJSONData;
begin
  Result := False;
  Tools := nil;
  Err := '';
  if not Request('tools/list', TJSONObject.Create, Res, Err) then
    Exit;
  try
    X := Res.FindPath('tools');
    if X is TJSONArray then
      Tools := TJSONArray(X.Clone)
    else
      Tools := TJSONArray.Create;
    Result := True;
  finally
    Res.Free;
  end;
end;

{ Collects the text of a tools/call result from the content array. }
function ExtractToolText(Res: TJSONData; out Text: string): Boolean;
var
  Arr, Item, SC: TJSONData;
  I: Integer;
  T, S: string;
begin
  Text := '';
  Result := True;
  Arr := nil;
  if Res is TJSONObject then
    Arr := TJSONObject(Res).FindPath('content');

  if Arr is TJSONArray then
    for I := 0 to TJSONArray(Arr).Count - 1 do
    begin
      Item := TJSONArray(Arr).Items[I];
      T := JStr(Item, 'type', '');
      if T = 'text' then
        S := JStr(Item, 'text', '')
      else if T = 'resource' then
        S := JStr(Item, 'resource.text', '')
      else if T <> '' then
        S := '[' + T + ']'
      else
        S := Item.AsJSON;
      if S <> '' then
      begin
        if Text <> '' then
          Text := Text + sLineBreak;
        Text := Text + S;
      end;
    end;

  if (Text = '') and (Res is TJSONObject) then
  begin
    SC := TJSONObject(Res).FindPath('structuredContent');
    if SC <> nil then
      Text := SC.AsJSON
    else if Res <> nil then
      Text := Res.AsJSON;
  end;
end;

function TMCPClient.CallTool(const ToolName, ArgsJson: string;
  out Text: string; out IsError: Boolean; out Err: string): Boolean;
var
  Params: TJSONObject;
  ArgsD: TJSONData;
  Res: TJSONData;
begin
  Result := False;
  Text := '';
  IsError := False;
  Err := '';

  { Request takes Params (and the nested ArgsD) over. }
  Params := TJSONObject.Create;
  Params.Add('name', ToolName);
  ArgsD := nil;
  if Trim(ArgsJson) <> '' then
    ParseJSONRepair(ArgsJson, ArgsD, Err);
  if (ArgsD = nil) or not (ArgsD is TJSONObject) then
  begin
    if ArgsD <> nil then
      ArgsD.Free;
    ArgsD := TJSONObject.Create;
  end;
  Err := '';
  Params.Add('arguments', ArgsD);

  if not Request('tools/call', Params, Res, Err) then
    Exit;

  try
    IsError := JBool(Res, 'isError', False);
    ExtractToolText(Res, Text);
    Result := True;
  finally
    Res.Free;
  end;
end;

{ ------------------------------------------------------------------ manager }

constructor TMCPHandler.Create(AManager: TMCPManager; AIndex: Integer);
begin
  inherited Create;
  FManager := AManager;
  FIndex := AIndex;
end;

function TMCPHandler.Call(const Args: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Text, Err: string;
  IsErr: Boolean;
begin
  if not FManager.CallTool(FManager.EntryFullName(FIndex), Args.AsJSON,
    Text, IsErr, Err) then
    Exit(ErrResult(Err));
  if IsErr then
    Exit(ErrResult(Text));
  Result := OkResult(Text);
end;

constructor TMCPManager.Create(ARegistry: TToolRegistry; TimeoutSec: Integer);
begin
  inherited Create;
  FRegistry := ARegistry;
  if TimeoutSec < 1 then
    TimeoutSec := DEFAULT_MCP_TIMEOUT;
  FTimeout := TimeoutSec;
end;

destructor TMCPManager.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FHandlers) do
    FHandlers[I].Free;
  for I := 0 to High(FClients) do
    FClients[I].Free;
  inherited Destroy;
end;

function TMCPManager.EntryFullName(Index: Integer): string;
begin
  if (Index >= 0) and (Index <= High(FFullNames)) then
    Result := FFullNames[Index]
  else
    Result := '';
end;

function TMCPManager.FindTool(const FullName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FFullNames) do
    if FFullNames[I] = FullName then
      Exit(I);
  Result := -1;
end;

function TMCPManager.ClientByName(const Server: string): TMCPClient;
var
  I: Integer;
begin
  for I := 0 to High(FClients) do
    if FClientNames[I] = Server then
      Exit(FClients[I]);
  Result := nil;
end;

function TMCPManager.UniqueFullName(const Base: string): string;
var
  Root, Cand: string;
  N: Integer;
begin
  Root := Base;
  if Length(Root) > 64 then
    Root := Copy(Root, 1, 64);
  Cand := Root;
  N := 1;
  while FRegistry.Has(Cand) do
  begin
    Inc(N);
    Cand := Root + '_' + IntToStr(N);
    if Length(Cand) > 64 then
      Cand := Copy(Root, 1, 64 - Length(IntToStr(N)) - 1) + '_' + IntToStr(N);
  end;
  Result := Cand;
end;

function TMCPManager.AddServer(const Name: string; Transport: TMCPTransport;
  out Err: string): Boolean;
var
  Client: TMCPClient;
  Tools: TJSONArray;
  I, Idx: Integer;
  ToolObj: TJSONObject;
  TName, TDesc, Full: string;
  SchemaD: TJSONData;
  Schema: TJSONObject;
  H: TMCPHandler;
begin
  Result := False;
  Err := '';
  { The client takes the transport over -- even on error. }
  Client := TMCPClient.Create(Name, Transport, FTimeout);
  try
    try
      Transport.Start;
    except
      on E: Exception do
      begin
        Err := 'failed to start the server: ' + E.Message;
        Client.Free;
        Exit;
      end;
    end;

    if not Client.Initialize(Err) then
    begin
      if (Transport is TStdioTransport) and
         (Trim(TStdioTransport(Transport).StderrLog) <> '') then
        Err := Err + sLineBreak + 'stderr: ' +
          Trim(TStdioTransport(Transport).StderrLog);
      Client.Free;
      Exit;
    end;

    if not Client.ListTools(Tools, Err) then
    begin
      Client.Free;
      Exit;
    end;

    try
      for I := 0 to Tools.Count - 1 do
      begin
        if not (Tools.Items[I] is TJSONObject) then
          Continue;
        ToolObj := TJSONObject(Tools.Items[I]);
        TName := JStr(ToolObj, 'name', '');
        if TName = '' then
          Continue;
        TDesc := JStr(ToolObj, 'description', '');
        SchemaD := ToolObj.FindPath('inputSchema');
        if SchemaD is TJSONObject then
          Schema := TJSONObject(SchemaD.Clone)
        else
          Schema := SchemaObject(TJSONObject.Create, []);

        Full := UniqueFullName(MCPFullToolName(Name, TName));
        Idx := Length(FHandlers);
        SetLength(FHandlers, Idx + 1);
        SetLength(FFullNames, Idx + 1);
        SetLength(FServerOfTool, Idx + 1);
        SetLength(FOrigNameOfTool, Idx + 1);
        H := TMCPHandler.Create(Self, Idx);
        FHandlers[Idx] := H;
        FFullNames[Idx] := Full;
        FServerOfTool[Idx] := Name;
        FOrigNameOfTool[Idx] := TName;
        FRegistry.AddMethod(Full, TDesc, Schema, @H.Call);
      end;
    finally
      Tools.Free;
    end;

    Idx := Length(FClients);
    SetLength(FClients, Idx + 1);
    SetLength(FClientNames, Idx + 1);
    FClients[Idx] := Client;
    FClientNames[Idx] := Name;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Client.Free;
    end;
  end;
end;

procedure TMCPManager.LoadFromFile(const FileName: string; var Warnings: TStringList);
var
  Text, Err, Name, Cmd, Cwd: string;
  D, ServersD, Item, X: TJSONData;
  O: TJSONObject;
  Args, Env: TStringList;
  I, J: Integer;
  Transport: TStdioTransport;
  OneTimeout, OldTimeout: Integer;
begin
  if not FileExists(FileName) then
  begin
    Warnings.Add('MCP configuration file not found: ' + FileName);
    Exit;
  end;
  if not ReadTextFile(FileName, Text, Err) then
  begin
    Warnings.Add('failed to read ' + FileName + ': ' + Err);
    Exit;
  end;
  if not ParseJSON(Text, D, Err) then
  begin
    Warnings.Add('invalid JSON in ' + FileName + ': ' + Err);
    Exit;
  end;
  try
    ServersD := nil;
    if D is TJSONObject then
      ServersD := D.FindPath('mcpServers');
    if not (ServersD is TJSONObject) then
    begin
      Warnings.Add('no mcpServers object in ' + FileName);
      Exit;
    end;
    O := TJSONObject(ServersD);

    for I := 0 to O.Count - 1 do
    begin
      Name := O.Names[I];
      Item := O.Items[I];
      if not (Item is TJSONObject) then
      begin
        Warnings.Add('MCP server ' + Name + ': the description is not an object');
        Continue;
      end;
      if not JBool(Item, 'enabled', True) then
        Continue;

      Cmd := JStr(Item, 'command', '');
      if Cmd = '' then
      begin
        if JStr(Item, 'url', '') <> '' then
          Warnings.Add('MCP server ' + Name +
            ': the HTTP transport is not supported yet, command is required')
        else
          Warnings.Add('MCP server ' + Name + ': command is not set');
        Continue;
      end;

      Cwd := JStr(Item, 'cwd', '');
      Args := TStringList.Create;
      Env := TStringList.Create;
      try
        X := Item.FindPath('args');
        if X is TJSONArray then
          for J := 0 to TJSONArray(X).Count - 1 do
            Args.Add(TJSONArray(X).Items[J].AsString);
        X := Item.FindPath('env');
        if X is TJSONObject then
          for J := 0 to TJSONObject(X).Count - 1 do
            Env.Add(TJSONObject(X).Names[J] + '=' +
              TJSONObject(X).Items[J].AsString);

        Transport := TStdioTransport.Create(Cmd, Args, Env, Cwd);
      finally
        Args.Free;
        Env.Free;
      end;

      { Server timeout: its own or the common one. }
      OneTimeout := FTimeout;
      X := Item.FindPath('timeout');
      if (X is TJSONNumber) and (X.AsInteger > 0) then
        OneTimeout := X.AsInteger;

      { The server's own timeout applies both to the handshake and to the
        following tool calls. }
      OldTimeout := FTimeout;
      if OneTimeout > 0 then
        FTimeout := OneTimeout;
      try
        if not AddServer(Name, Transport, Err) then
          Warnings.Add('MCP server ' + Name + ': ' + Err);
      finally
        FTimeout := OldTimeout;
      end;
    end;
  finally
    D.Free;
  end;
end;

function TMCPManager.CallTool(const FullName, ArgsJson: string;
  out Text: string; out IsError: Boolean; out Err: string): Boolean;
var
  Idx: Integer;
  Client: TMCPClient;
begin
  Text := '';
  IsError := False;
  Err := '';
  Idx := FindTool(FullName);
  if Idx < 0 then
  begin
    Err := 'unknown MCP tool: ' + FullName;
    Exit(False);
  end;
  Client := ClientByName(FServerOfTool[Idx]);
  if Client = nil then
  begin
    Err := 'MCP server is unavailable: ' + FServerOfTool[Idx];
    Exit(False);
  end;
  Result := Client.CallTool(FOrigNameOfTool[Idx], ArgsJson, Text, IsError, Err);
end;

function TMCPManager.ToolCount: Integer;
begin
  Result := Length(FFullNames);
end;

function TMCPManager.ToolList: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FFullNames) do
  begin
    if I > 0 then
      Result := Result + sLineBreak;
    Result := Result + FFullNames[I] + '  [' + FServerOfTool[I] + ': ' +
      FOrigNameOfTool[I] + ']';
  end;
end;

function TMCPManager.ServerCount: Integer;
begin
  Result := Length(FClients);
end;

function TMCPManager.ServerList: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FClientNames) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + FClientNames[I];
  end;
end;

end.
