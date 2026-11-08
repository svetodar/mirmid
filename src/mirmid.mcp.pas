unit mirmid.mcp;
{ Поддержка MCP (Model Context Protocol): подключение внешних серверов
  инструментов. Реализован транспорт stdio — JSON-RPC 2.0 по одному объекту
  в строке через stdin/stdout дочернего процесса.

  Серверы описываются в файле mcp.json (формат совместим с Claude Desktop):
  объект mcpServers, где ключ — имя сервера, а значение — объект с полями
  command, args, env, cwd, enabled, timeout.

  Инструменты сервера регистрируются в реестре под именем
  mcp__<server>__<tool> (недопустимые для имён функции символы заменяются
  подчёркиванием, длина ограничена 64 символами). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, process, fpjson, mirmid.tools, mirmid.types;

const
  { Префикс имён MCP-инструментов в реестре. }
  MCP_PREFIX = 'mcp__';
  { Версия протокола MCP, которую предлагает клиент. }
  MCP_PROTOCOL_VERSION = '2024-11-05';
  { Предел длины одной строки протокола (защита от мусора в потоке). }
  MAX_MCP_LINE = 16 * 1024 * 1024;

{ Полное имя инструмента в реестре: mcp__<server>__<tool>. }
function MCPFullToolName(const Server, Tool: string): string;
{ Канонизирует компоненту имени (A-Za-z0-9_-), заменяя прочее на «_». }
function MCPSanitizeName(const S: string): string;
{ Путь к mcp.json по умолчанию: $MIRMID_MCP_CONFIG, затем <WorkDir>/.mirmid/mcp.json.
  Если файла нет — возвращается <WorkDir>/.mirmid/mcp.json. }
function DefaultMcpConfigPath(const WorkDir: string): string;

type
  { Абстрактный транспорт MCP: обмен строками JSON-RPC. }
  TMCPTransport = class
  public
    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    function Running: Boolean; virtual; abstract;
    { Отправляет один объект JSON (без завершающего перевода строки). }
    procedure Send(const Line: string); virtual; abstract;
    { Читает одно сообщение (строку JSON) с таймаутом TimeoutMs.
      False — таймаут/EOF/ошибка (Err заполнен). }
    function Receive(TimeoutMs: Integer; out Line: string; out Err: string): Boolean; virtual; abstract;
  end;

  { Транспорт stdio: запускает процесс сервера и общается через его stdin/stdout.
    stderr дочернего процесса вычитывается, чтобы сервер не блокировался. }
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
    { Последние строки stderr сервера (для диагностики ошибок). }
    property StderrLog: string read FStderrLog;
  end;

  { Клиент одного MCP-сервера. Владеет транспортом. }
  TMCPClient = class
  private
    FName: string;
    FTransport: TMCPTransport;
    FTimeout: Integer;
    FNextId: Integer;
    FServerInfo: string;
    FProtocolVersion: string;
    { Запрос JSON-RPC. Забирает Params во владение (освобождает вместе с
      отправляемым объектом). Res — копия ответа, освобождает вызывающий. }
    function Request(const Method: string; Params: TJSONObject;
      out Res: TJSONData; out Err: string): Boolean;
    { Уведомление JSON-RPC (без id). Забирает Params во владение. }
    function Notify(const Method: string; Params: TJSONObject; out Err: string): Boolean;
  public
    constructor Create(const AName: string; ATransport: TMCPTransport;
      TimeoutSec: Integer);
    destructor Destroy; override;
    { Рукопожатие initialize + notifications/initialized. }
    function Initialize(out Err: string): Boolean;
    { tools/list; Tools — новая копия массива описаний (освобождает вызывающий). }
    function ListTools(out Tools: TJSONArray; out Err: string): Boolean;
    { tools/call. IsError — это ошибка инструмента (isError=true), а не сбой
      протокола: Err при этом пуст. }
    function CallTool(const ToolName, ArgsJson: string;
      out Text: string; out IsError: Boolean; out Err: string): Boolean;
    property Name: string read FName;
    property ServerInfo: string read FServerInfo;
    property ProtocolVersion: string read FProtocolVersion;
  end;

  TMCPManager = class;

  { Обработчик одного MCP-инструмента: держит ссылку на менеджер и индекс. }
  TMCPHandler = class
  private
    FManager: TMCPManager;
    FIndex: Integer;
  public
    constructor Create(AManager: TMCPManager; AIndex: Integer);
    function Call(const Args: TJSONObject; const Ctx: TToolContext): TToolOutcome;
  end;

  { Менеджер MCP-серверов: запускает их, регистрирует инструменты в реестре
    и проксирует вызовы. Владеет клиентами и обработчиками; схемы инструментов
    освобождает реестр. }
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
    { Запускает сервер, выполняет рукопожатие, получает список инструментов и
      регистрирует их. Транспорт переходит во владение менеджера в любом
      случае (при ошибке освобождается). }
    function AddServer(const Name: string; Transport: TMCPTransport;
      out Err: string): Boolean;
    { Читает mcp.json и подключает все включённые серверы. Ошибки отдельных
      серверов попадают в Warnings и не прерывают загрузку остальных. }
    procedure LoadFromFile(const FileName: string; var Warnings: TStringList);
    function CallTool(const FullName, ArgsJson: string;
      out Text: string; out IsError: Boolean; out Err: string): Boolean;
    function EntryFullName(Index: Integer): string;
    function ToolCount: Integer;
    { Список инструментов, по одному в строке: «имя [сервер: оригинал]». }
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

{ Добавляет строки окружения из текущего процесса с заменой значений из Extra. }
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
    Key := Copy(Item, 1, Pos('=', Item));   { вместе со знаком «=» }
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
    { процесс мог уже завершиться }
  end;
  try
    if FProcess.Running then
      FProcess.Terminate(0);
  except
    { игнорируем ошибки завершения }
  end;
  try
    FProcess.WaitOnExit(1000);
  except
    { игнорируем }
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
    raise Exception.Create('MCP-процесс не запущен');
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
      Err := 'MCP-процесс не запущен';
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
          Err := 'превышен предельный размер сообщения MCP';
          Exit(False);
        end;
        Continue;   { сразу проверяем наличие полной строки }
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
      Err := 'MCP-сервер завершился';
      if Trim(FStderrLog) <> '' then
        Err := Err + ': ' + Trim(FStderrLog);
      Exit(False);
    end;

    Sleep(10);
  until GetTickCount64 >= Deadline;

  Err := Format('таймаут ожидания ответа MCP (%d мс)', [TimeoutMs]);
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
        Err := 'не удалось отправить сообщение MCP: ' + E.Message;
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
        Err := 'не удалось отправить запрос MCP: ' + E.Message;
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
        Err := Err + sLineBreak + 'некорректная строка от сервера: ' +
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
      { Уведомления (без id) и чужие ответы пропускаем. }
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
        Err := 'ошибка MCP ' + JStr(X, 'code', '') + ': ' + EMsg;
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

  Err := Format('таймаут ответа MCP-сервера (%.1f с)', [FTimeout]);
  Result := False;
end;

function TMCPClient.Initialize(out Err: string): Boolean;
var
  Params, Info: TJSONObject;
  Res: TJSONData;
begin
  Result := False;
  Err := '';
  { Request забирает Params во владение (освобождает вместе с запросом). }
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

  { Уведомление об успешной инициализации. }
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

{ Собирает текст результата tools/call из массива content. }
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

  { Request забирает Params (и вложенный ArgsD) во владение. }
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
  { Клиент забирает транспорт во владение — даже при ошибке. }
  Client := TMCPClient.Create(Name, Transport, FTimeout);
  try
    try
      Transport.Start;
    except
      on E: Exception do
      begin
        Err := 'не удалось запустить сервер: ' + E.Message;
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
    Warnings.Add('файл MCP-конфигурации не найден: ' + FileName);
    Exit;
  end;
  if not ReadTextFile(FileName, Text, Err) then
  begin
    Warnings.Add('не удалось прочитать ' + FileName + ': ' + Err);
    Exit;
  end;
  if not ParseJSON(Text, D, Err) then
  begin
    Warnings.Add('некорректный JSON в ' + FileName + ': ' + Err);
    Exit;
  end;
  try
    ServersD := nil;
    if D is TJSONObject then
      ServersD := D.FindPath('mcpServers');
    if not (ServersD is TJSONObject) then
    begin
      Warnings.Add('в ' + FileName + ' нет объекта mcpServers');
      Exit;
    end;
    O := TJSONObject(ServersD);

    for I := 0 to O.Count - 1 do
    begin
      Name := O.Names[I];
      Item := O.Items[I];
      if not (Item is TJSONObject) then
      begin
        Warnings.Add('MCP-сервер ' + Name + ': описание не является объектом');
        Continue;
      end;
      if not JBool(Item, 'enabled', True) then
        Continue;

      Cmd := JStr(Item, 'command', '');
      if Cmd = '' then
      begin
        if JStr(Item, 'url', '') <> '' then
          Warnings.Add('MCP-сервер ' + Name +
            ': HTTP-транспорт пока не поддерживается, нужен command')
        else
          Warnings.Add('MCP-сервер ' + Name + ': не задан command');
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

      { Таймаут сервера: собственный или общий. }
      OneTimeout := FTimeout;
      X := Item.FindPath('timeout');
      if (X is TJSONNumber) and (X.AsInteger > 0) then
        OneTimeout := X.AsInteger;

      { Собственный таймаут сервера действует и на рукопожатие,
        и на последующие вызовы инструментов. }
      OldTimeout := FTimeout;
      if OneTimeout > 0 then
        FTimeout := OneTimeout;
      try
        if not AddServer(Name, Transport, Err) then
          Warnings.Add('MCP-сервер ' + Name + ': ' + Err);
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
    Err := 'неизвестный MCP-инструмент: ' + FullName;
    Exit(False);
  end;
  Client := ClientByName(FServerOfTool[Idx]);
  if Client = nil then
  begin
    Err := 'MCP-сервер недоступен: ' + FServerOfTool[Idx];
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
