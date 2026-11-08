unit mirmid.tools;
{ Реестр инструментов агента и вспомогательные конструкторы JSON-схем.
  Сами инструменты регистрируются в mirmid.toolbuiltin. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, mirmid.types;

type
  TToolRegistry = class;

  { Контекст выполнения: рабочая папка и настройки сессии. }
  TToolContext = record
    WorkDir: string;
    ShellTimeout: Integer;
    ShellOutputLimit: Integer;  { байт; максимум вывода shell; 0 — без ограничения }
    Cfg: TMirmidConfig;          { конфигурация родительской сессии;
                                   переключатели инструментов — в Cfg.Tools }
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

  { Описание встроенного инструмента для секции [tools] INI: имя ключа,
    значение по умолчанию и одна строка комментария для образца конфигурации
    (mirmid --init). }
  TToolSwitchDef = record
    Name: string;
    Default: Boolean;
    Note: string;
  end;

  { Реестр инструментов. Владеет переданными схемами. }
  TToolRegistry = class
  private
    FNames: array of string;
    FDescs: array of string;
    FSchemas: array of TJSONObject;
    FHandlers: array of TToolHandler;
    FMethods: array of TToolMethod;
    FIsMethod: array of Boolean;
    { Политика набора: после ApplyToolSwitches регистрируются только
      инструменты, включённые в секции [tools]. }
    FPolicyCfg: TMirmidConfig;
    FPolicySet: Boolean;
    function IndexOf(const Name: string): Integer;
    { Разрешён ли инструмент политикой набора ([tools]). }
    function Allowed(const Name: string): Boolean;
  public
    procedure Add(const Name, Desc: string; Schema: TJSONObject; Handler: TToolHandler);
    { Регистрирует обработчик-метод (с состоянием). }
    procedure AddMethod(const Name, Desc: string; Schema: TJSONObject;
      const Handler: TToolMethod);
    { Ограничивает набор инструментов секцией [tools]: инструмент с ключом 0
      в реестр не попадает, поэтому его нет и в массиве tools запроса.
      Внешние инструменты (mcp__*) политикой не управляются. Вызывается до
      регистрации — порядок задаёт RegisterSessionTools. }
    procedure ApplyToolSwitches(const Cfg: TMirmidConfig);
    function Has(const Name: string): Boolean;
    function Count: Integer;
    function Names: string;
    { Добавляет схемы в массив tools запроса (копии). }
    procedure BuildRequestTools(const Arr: TJSONArray);
    { Разбирает аргументы и вызывает обработчик. Исключения ловятся. }
    function Invoke(const Name, ArgsJson: string; const Ctx: TToolContext): TToolOutcome;
    destructor Destroy; override;
  end;

{ Таблица встроенных инструментов — единственный источник истины для секции
  [tools]: набор ключей, значения по умолчанию и порядок строк в образце
  конфигурации. Инструменты MCP (mcp__<server>__<tool>) сюда не входят: ими
  управляет секция [mcp]. }
const
  TOOL_SWITCHES: array[0..16] of TToolSwitchDef = (
    (Name: 'file_list'; Default: True;
     Note: 'read-only: list files and directories'),
    (Name: 'exist_file'; Default: True;
     Note: 'read-only: check whether a path exists'),
    (Name: 'read_text_file'; Default: True;
     Note: 'read-only: read a text file with its hash header'),
    (Name: 'read_pascal_interface'; Default: True;
     Note: 'read-only: read the interface section of a Pascal unit'),
    (Name: 'grep'; Default: True;
     Note: 'read-only: search a substring in text files'),
    (Name: 'list_windows'; Default: True;
     Note: 'read-only: list open windows'),
    (Name: 'find_window'; Default: True;
     Note: 'read-only: find a window by title or class'),
    (Name: 'window_info'; Default: True;
     Note: 'read-only: window details and child controls'),
    (Name: 'edit_text_file'; Default: False;
     Note: 'writes files: create a file or replace a line range'),
    (Name: 'copy_file'; Default: False;
     Note: 'writes files: copy a file'),
    (Name: 'shell'; Default: False;
     Note: 'runs commands: execute a shell command'),
    (Name: 'http_request'; Default: False;
     Note: 'network: perform an HTTP request'),
    (Name: 'subagent'; Default: False;
     Note: 'nested session: run a separate agent session'),
    (Name: 'read_media_file'; Default: False;
     Note: 'reads binary media: image, audio and video info'),
    (Name: 'screen_shoot'; Default: False;
     Note: 'writes an image: capture the whole screen'),
    (Name: 'window_shoot'; Default: False;
     Note: 'writes an image: capture the active window'),
    (Name: 'revise_plan'; Default: True;
     Note: 'plan revision while the plan mode is on'));

{ Есть ли инструмент с таким именем в таблице [tools]. }
function IsKnownToolName(const Name: string): Boolean;
{ Значение по умолчанию для ключа [tools]; неизвестное имя — False. }
function ToolEnabledByDefault(const Name: string): Boolean;
{ Имена всех встроенных инструментов через запятую — для сообщения о
  неизвестном ключе в [tools]. }
function ToolNamesCsv: string;
{ Число записей таблицы [tools]. }
function ToolSwitchCount: Integer;
{ Запись таблицы по индексу (0 .. ToolSwitchCount-1). }
function ToolSwitchAt(Index: Integer): TToolSwitchDef;
{ Включён ли инструмент: значение из [tools], если ключ задан, иначе значение
  по умолчанию из таблицы. Неизвестное имя — False. }
function ToolEnabled(const Cfg: TMirmidConfig; const Name: string): Boolean;
{ Записывает значение ключа [tools] (разбор INI и тесты). Неизвестное имя —
  EArgumentException: набор ключей задаёт таблица, и опечатка не должна молча
  ничего не менять. }
procedure SetToolEnabled(var Cfg: TMirmidConfig; const Name: string; Enabled: Boolean);
{ Отказ выключенного инструмента: именованный ERROR-результат — вызов
  обработчика в обход реестра тоже не должен сработать. }
function ToolDisabled(const Name: string): TToolOutcome;

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
  Result.ShellTimeout := Cfg.ShellTimeout;
  Result.ShellOutputLimit := Cfg.ShellOutputLimit;
  Result.Cfg          := Cfg;
  Result.SubAgentDepth := 0;
  Result.SessionBase   := '';
  Result.Registry     := nil;
  Result.OnSubAgentEvent := nil;
end;

{ --- Секция [tools]: таблица инструментов и их переключатели ------------- }

function IsKnownToolName(const Name: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(TOOL_SWITCHES) do
    if SameText(TOOL_SWITCHES[I].Name, Name) then
      Exit(True);
  Result := False;
end;

function ToolEnabledByDefault(const Name: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(TOOL_SWITCHES) do
    if SameText(TOOL_SWITCHES[I].Name, Name) then
      Exit(TOOL_SWITCHES[I].Default);
  Result := False;
end;

function ToolNamesCsv: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(TOOL_SWITCHES) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + TOOL_SWITCHES[I].Name;
  end;
end;

function ToolSwitchCount: Integer;
begin
  Result := Length(TOOL_SWITCHES);
end;

function ToolSwitchAt(Index: Integer): TToolSwitchDef;
begin
  if (Index < 0) or (Index > High(TOOL_SWITCHES)) then
    raise EArgumentOutOfRangeException.Create('Index');
  Result := TOOL_SWITCHES[Index];
end;

function ToolEnabled(const Cfg: TMirmidConfig; const Name: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Cfg.Tools) do
    if SameText(Cfg.Tools[I].Name, Name) then
      Exit(Cfg.Tools[I].Enabled);
  Result := ToolEnabledByDefault(Name);
end;

procedure SetToolEnabled(var Cfg: TMirmidConfig; const Name: string;
  Enabled: Boolean);
var
  I, N: Integer;
  Tmp: TToolSwitches;
begin
  if not IsKnownToolName(Name) then
    raise EArgumentException.CreateFmt('unknown tool "%s"', [Name]);
  { Копия массива: динамический массив в записи общий по ссылке, поэтому
    правка элемента на месте изменила бы и родительский конфиг (TMirmidConfig
    копируется по значению, например в AnalysisConfig). }
  Tmp := Copy(Cfg.Tools);
  for I := 0 to High(Tmp) do
    if SameText(Tmp[I].Name, Name) then
    begin
      Tmp[I].Enabled := Enabled;
      Cfg.Tools := Tmp;
      Exit;
    end;
  N := Length(Tmp);
  SetLength(Tmp, N + 1);
  Tmp[N].Name := Name;
  Tmp[N].Enabled := Enabled;
  Cfg.Tools := Tmp;
end;

function ToolDisabled(const Name: string): TToolOutcome;
begin
  Result := ErrResult('tool "' + Name + '" is disabled');
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

function TToolRegistry.Allowed(const Name: string): Boolean;
begin
  { Внешние инструменты (не из таблицы [tools], например mcp__*) политикой
    набора не управляются: ими ведает секция [mcp]. }
  Result := (not FPolicySet) or (not IsKnownToolName(Name)) or
    ToolEnabled(FPolicyCfg, Name);
end;

procedure TToolRegistry.ApplyToolSwitches(const Cfg: TMirmidConfig);
begin
  FPolicyCfg := Cfg;
  FPolicySet := True;
end;

procedure TToolRegistry.Add(const Name, Desc: string; Schema: TJSONObject;
  Handler: TToolHandler);
var
  N: Integer;
begin
  { Выключенный в [tools] инструмент в набор не попадает: схема уже наша,
    поэтому освобождаем её. Так он не уйдёт модели и в массиве tools. }
  if not Allowed(Name) then
  begin
    Schema.Free;
    Exit;
  end;
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
  { См. Add: политика [tools] действует и на обработчики-методы. }
  if not Allowed(Name) then
  begin
    Schema.Free;
    Exit;
  end;
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
  { Защита в глубину: реестр могли наполнить в обход политики (тесты,
    внешний код), поэтому выключенный в [tools] встроенный инструмент
    отказывает и при вызове. Инструменты MCP управляются секцией [mcp]. }
  if IsKnownToolName(Name) and not ToolEnabled(Ctx.Cfg, Name) then
    Exit(ToolDisabled(Name));

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
