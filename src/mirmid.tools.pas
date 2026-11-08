unit mirmid.tools;
{ Реестр инструментов агента и вспомогательные конструкторы JSON-схем.
  Сами инструменты регистрируются в mirmid.toolbuiltin. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, mirmid.types;

type
  TToolRegistry = class;

  { Контекст выполнения: рабочая папка и политики безопасности. }
  TToolContext = record
    WorkDir: string;
    AllowWrite: Boolean;
    AllowShell: Boolean;
    AllowHttp: Boolean;         { разрешён ли инструмент http_request }
    ShellTimeout: Integer;
    ShellOutputLimit: Integer;  { байт; максимум вывода shell; 0 — без ограничения }
    Cfg: TMirmidConfig;          { конфигурация родительской сессии }
    SubAgentDepth: Integer;     { глубина вложенности субагентов, 0 — корневая сессия }
    Registry: TToolRegistry;    { реестр текущей сессии (может быть nil) }
    SessionBase: string;        { база имён файлов вспомогательных сессий
                                  (субагенты, шаги плана); пусто — не сохраняются }
    OnSubAgentEvent: TAgentEvent; { обработчик событий субагентов (может быть nil) }
  end;

  TToolOutcome = record
    Text: string;
    IsError: Boolean;
  end;

  TToolHandler = function(const Args: TJSONObject;
    const Ctx: TToolContext): TToolOutcome;

  { Обработчик-метод: позволяет держать состояние (например, MCP-клиент). }
  TToolMethod = function(const Args: TJSONObject;
    const Ctx: TToolContext): TToolOutcome of object;

  { Реестр инструментов. Владеет переданными схемами. }
  TToolRegistry = class
  private
    FNames: array of string;
    FDescs: array of string;
    FSchemas: array of TJSONObject;
    FHandlers: array of TToolHandler;
    FMethods: array of TToolMethod;
    FIsMethod: array of Boolean;
    function IndexOf(const Name: string): Integer;
  public
    procedure Add(const Name, Desc: string; Schema: TJSONObject; Handler: TToolHandler);
    { Регистрирует обработчик-метод (с состоянием). }
    procedure AddMethod(const Name, Desc: string; Schema: TJSONObject;
      const Handler: TToolMethod);
    function Has(const Name: string): Boolean;
    function Count: Integer;
    function Names: string;
    { Добавляет схемы в массив tools запроса (копии). }
    procedure BuildRequestTools(const Arr: TJSONArray);
    { Разбирает аргументы и вызывает обработчик. Исключения ловятся. }
    function Invoke(const Name, ArgsJson: string; const Ctx: TToolContext): TToolOutcome;
    destructor Destroy; override;
  end;

function OkResult(const Text: string): TToolOutcome;
function ErrResult(const Text: string): TToolOutcome;
{ Контекст выполнения по конфигурации сессии (глубина субагентов — 0). }
function MakeToolContext(const Cfg: TMirmidConfig): TToolContext;

{ Конструкторы фрагментов JSON-схемы. }
function PropStr(const Desc: string): TJSONObject;
function PropInt(const Desc: string): TJSONObject;
function PropBool(const Desc: string): TJSONObject;
function SchemaObject(const Props: TJSONObject; const Required: array of string): TJSONObject;

implementation

uses
  mirmid.json;

function OkResult(const Text: string): TToolOutcome;
begin
  Result.Text := Text;
  Result.IsError := False;
end;

function ErrResult(const Text: string): TToolOutcome;
begin
  Result.Text := Text;
  Result.IsError := True;
end;

function MakeToolContext(const Cfg: TMirmidConfig): TToolContext;
begin
  Result.WorkDir      := Cfg.WorkDir;
  Result.AllowWrite   := Cfg.AllowWrite;
  Result.AllowShell   := Cfg.AllowShell;
  Result.AllowHttp    := Cfg.AllowHttp;
  Result.ShellTimeout := Cfg.ShellTimeout;
  Result.ShellOutputLimit := Cfg.ShellOutputLimit;
  Result.Cfg          := Cfg;
  Result.SubAgentDepth := 0;
  Result.SessionBase   := '';
  Result.Registry     := nil;
  Result.OnSubAgentEvent := nil;
end;

function PropStr(const Desc: string): TJSONObject;
begin
  Result := TJSONObject.Create(['type', 'string', 'description', Desc]);
end;

function PropInt(const Desc: string): TJSONObject;
begin
  Result := TJSONObject.Create(['type', 'integer', 'description', Desc]);
end;

function PropBool(const Desc: string): TJSONObject;
begin
  Result := TJSONObject.Create(['type', 'boolean', 'description', Desc]);
end;

function SchemaObject(const Props: TJSONObject; const Required: array of string): TJSONObject;
var
  A: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'object');
  Result.Add('properties', Props);
  if Length(Required) > 0 then
  begin
    A := TJSONArray.Create;
    for I := Low(Required) to High(Required) do
      A.Add(Required[I]);
    Result.Add('required', A);
  end;
end;

function TToolRegistry.IndexOf(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FNames) do
    if SameText(FNames[I], Name) then
      Exit(I);
  Result := -1;
end;

procedure TToolRegistry.Add(const Name, Desc: string; Schema: TJSONObject;
  Handler: TToolHandler);
var
  N: Integer;
begin
  N := Length(FNames);
  SetLength(FNames, N + 1);
  SetLength(FDescs, N + 1);
  SetLength(FSchemas, N + 1);
  SetLength(FHandlers, N + 1);
  SetLength(FMethods, N + 1);
  SetLength(FIsMethod, N + 1);
  FNames[N] := Name;
  FDescs[N] := Desc;
  FSchemas[N] := Schema;
  FHandlers[N] := Handler;
  FMethods[N] := nil;
  FIsMethod[N] := False;
end;

procedure TToolRegistry.AddMethod(const Name, Desc: string; Schema: TJSONObject;
  const Handler: TToolMethod);
var
  N: Integer;
begin
  N := Length(FNames);
  SetLength(FNames, N + 1);
  SetLength(FDescs, N + 1);
  SetLength(FSchemas, N + 1);
  SetLength(FHandlers, N + 1);
  SetLength(FMethods, N + 1);
  SetLength(FIsMethod, N + 1);
  FNames[N] := Name;
  FDescs[N] := Desc;
  FSchemas[N] := Schema;
  FHandlers[N] := nil;
  FMethods[N] := Handler;
  FIsMethod[N] := True;
end;

function TToolRegistry.Has(const Name: string): Boolean;
begin
  Result := IndexOf(Name) >= 0;
end;

function TToolRegistry.Count: Integer;
begin
  Result := Length(FNames);
end;

function TToolRegistry.Names: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FNames) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + FNames[I];
  end;
end;

procedure TToolRegistry.BuildRequestTools(const Arr: TJSONArray);
var
  I: Integer;
  TObj, Fn: TJSONObject;
begin
  for I := 0 to High(FNames) do
  begin
    TObj := TJSONObject.Create;
    TObj.Add('type', 'function');
    Fn := TJSONObject.Create;
    Fn.Add('name', FNames[I]);
    Fn.Add('description', FDescs[I]);
    Fn.Add('parameters', FSchemas[I].Clone);
    TObj.Add('function', Fn);
    Arr.Add(TObj);
  end;
end;

function TToolRegistry.Invoke(const Name, ArgsJson: string;
  const Ctx: TToolContext): TToolOutcome;
var
  Idx: Integer;
  D: TJSONData;
  O: TJSONObject;
  Err: string;
begin
  Idx := IndexOf(Name);
  if Idx < 0 then
    Exit(ErrResult('неизвестный инструмент: ' + Name));

  O := nil;
  if Trim(ArgsJson) <> '' then
  begin
    if not ParseJSONRepair(ArgsJson, D, Err) then
      Exit(ErrResult('некорректные аргументы JSON: ' + Err));
    if not (D is TJSONObject) then
    begin
      D.Free;
      Exit(ErrResult('аргументы инструмента должны быть JSON-объектом'));
    end;
    O := TJSONObject(D);
  end
  else
    O := TJSONObject.Create;

  try
    try
      if FIsMethod[Idx] then
        Result := FMethods[Idx](O, Ctx)
      else
        Result := FHandlers[Idx](O, Ctx);
    except
      on E: Exception do
        Result := ErrResult('ошибка инструмента ' + Name + ': ' + E.Message);
    end;
  finally
    O.Free;
  end;
end;

destructor TToolRegistry.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FSchemas) do
    FSchemas[I].Free;
  inherited Destroy;
end;

end.
