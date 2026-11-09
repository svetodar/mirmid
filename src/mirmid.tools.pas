unit mirmid.tools;
{ Agent tool registry and helpers that build JSON schemas.
  The tools themselves are registered in mirmid.toolbuiltin. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, mirmid.types;

type
  TToolRegistry = class;

  { Execution context: the working folder and the session settings. }
  TToolContext = record
    WorkDir: string;
    ShellTimeout: Integer;
    ShellOutputLimit: Integer;  { bytes; maximum shell output; 0 — no limit }
    Cfg: TMirmidConfig;          { configuration of the parent session;
                                   the tool switches live in Cfg.Tools }
    SubAgentDepth: Integer;     { subagent nesting depth, 0 — root session }
    Registry: TToolRegistry;    { registry of the current session (may be nil) }
    SessionBase: string;        { base name of the auxiliary session files
                                  (subagents, plan steps); empty — not saved }
    OnSubAgentEvent: TAgentEvent; { subagent event handler (may be nil) }
  end;

  TToolOutcome = record
    Text: string;
    IsError: Boolean;
  end;

  TToolHandler = function(const Args: TJSONObject;
    const Ctx: TToolContext): TToolOutcome;

  { Method handler: keeps state (the MCP client, for example). }
  TToolMethod = function(const Args: TJSONObject;
    const Ctx: TToolContext): TToolOutcome of object;

  { Description of a built-in tool for the [tools] section of the INI file: the
    key name, the default value and one comment line for the sample
    configuration (mirmid --init). }
  TToolSwitchDef = record
    Name: string;
    Default: Boolean;
    Note: string;
  end;

  { Tool registry. Owns the schemas passed to it. }
  TToolRegistry = class
  private
    FNames: array of string;
    FDescs: array of string;
    FSchemas: array of TJSONObject;
    FHandlers: array of TToolHandler;
    FMethods: array of TToolMethod;
    FIsMethod: array of Boolean;
    { Set policy: after ApplyToolSwitches only the tools enabled in the [tools]
      section are registered. }
    FPolicyCfg: TMirmidConfig;
    FPolicySet: Boolean;
    function IndexOf(const Name: string): Integer;
    { Is the tool allowed by the set policy ([tools])? }
    function Allowed(const Name: string): Boolean;
  public
    procedure Add(const Name, Desc: string; Schema: TJSONObject; Handler: TToolHandler);
    { Registers a method handler (with state). }
    procedure AddMethod(const Name, Desc: string; Schema: TJSONObject;
      const Handler: TToolMethod);
    { Restricts the tool set by the [tools] section: a tool with the key set to
      0 never reaches the registry, so it is absent from the tools array of the
      request as well. External tools (mcp__*) are not governed by this policy.
      Called before registration — the order is set by RegisterSessionTools. }
    procedure ApplyToolSwitches(const Cfg: TMirmidConfig);
    function Has(const Name: string): Boolean;
    function Count: Integer;
    function Names: string;
    { Appends the schemas to the tools array of the request (copies). }
    procedure BuildRequestTools(const Arr: TJSONArray);
    { Parses the arguments and calls the handler. Exceptions are caught. }
    function Invoke(const Name, ArgsJson: string; const Ctx: TToolContext): TToolOutcome;
    destructor Destroy; override;
  end;

{ Table of the built-in tools — the single source of truth for the [tools]
  section: the key set, the default values and the order of the lines in the
  sample configuration. MCP tools (mcp__<server>__<tool>) are not listed here:
  they are governed by the [mcp] section. }
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

{ Is there a tool with this name in the [tools] table? }
function IsKnownToolName(const Name: string): Boolean;
{ Default value of a [tools] key; an unknown name gives False. }
function ToolEnabledByDefault(const Name: string): Boolean;
{ Names of all built-in tools separated by commas — for the message about an
  unknown key in [tools]. }
function ToolNamesCsv: string;
{ Number of entries in the [tools] table. }
function ToolSwitchCount: Integer;
{ Table entry by index (0 .. ToolSwitchCount-1). }
function ToolSwitchAt(Index: Integer): TToolSwitchDef;
{ Is the tool enabled: the value from [tools] when the key is set, otherwise the
  default from the table. An unknown name gives False. }
function ToolEnabled(const Cfg: TMirmidConfig; const Name: string): Boolean;
{ Writes the value of a [tools] key (INI parsing and tests). An unknown name
  raises EArgumentException: the key set is defined by the table, and a typo
  must not silently change nothing. }
procedure SetToolEnabled(var Cfg: TMirmidConfig; const Name: string; Enabled: Boolean);
{ Refusal of a disabled tool: a named ERROR result — a handler called around
  the registry must refuse as well. }
function ToolDisabled(const Name: string): TToolOutcome;

function OkResult(const Text: string): TToolOutcome;
function ErrResult(const Text: string): TToolOutcome;
{ Execution context built from the session configuration (subagent depth 0). }
function MakeToolContext(const Cfg: TMirmidConfig): TToolContext;

{ Constructors of JSON schema fragments. }
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

{ --- [tools] section: the tool table and its switches ---------------------- }

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
  { A copy of the array: a dynamic array inside a record is shared by reference,
    so changing an element in place would change the parent configuration too
    (TMirmidConfig is copied by value, into AnalysisConfig for instance). }
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
  { External tools (not from the [tools] table, mcp__* for instance) are not
    governed by the set policy: the [mcp] section rules them. }
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
  { A tool disabled in [tools] never reaches the set: the schema is already
    ours, so it is freed here. That way it does not reach the model in the tools
    array either. }
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
  { See Add: the [tools] policy applies to method handlers as well. }
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
    Exit(ErrResult('unknown tool: ' + Name));
  { Defence in depth: the registry could be filled around the policy (tests,
    external code), so a built-in tool disabled in [tools] refuses a call as
    well. MCP tools are governed by the [mcp] section. }
  if IsKnownToolName(Name) and not ToolEnabled(Ctx.Cfg, Name) then
    Exit(ToolDisabled(Name));

  O := nil;
  if Trim(ArgsJson) <> '' then
  begin
    if not ParseJSONRepair(ArgsJson, D, Err) then
      Exit(ErrResult('invalid JSON arguments: ' + Err));
    if not (D is TJSONObject) then
    begin
      D.Free;
      Exit(ErrResult('tool arguments must be a JSON object'));
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
        Result := ErrResult('tool error ' + Name + ': ' + E.Message);
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
