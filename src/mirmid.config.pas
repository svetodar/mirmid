unit mirmid.config;
{ Loading and saving settings: INI files and environment variables.
  All configuration files of the project live in the ./.mirmid directory. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.types;

{ Project configuration directory: <Dir>/.mirmid (without a trailing slash). }
function ConfigDir(const Dir: string): string;
{ Project config file: <Dir>/.mirmid/mirmid.ini. }
function ProjectConfigPath(const Dir: string): string;

{ Reads the INI over the passed values (missing keys are left untouched).
  Returns False and the reason in Err when the file is unusable: an unknown
  key in the [tools] section, a typo in the section name itself ([tool]) or a
  duplicate key — a typo must never silently enable or disable a tool. }
function LoadIni(const FileName: string; var C: TMirmidConfig;
  out Err: string): Boolean;
{ Applies the MIRMID_* environment variables. }
procedure ApplyEnv(var C: TMirmidConfig);
{ Writes a sample configuration. }
function SaveSampleIni(const FileName: string; const C: TMirmidConfig;
  out Err: string): Boolean;
{ Parses a boolean string (case-insensitive, surrounding spaces ignored):
  1/true/yes/on -> True, 0/false/no/off -> False.
  An empty or unrecognised string returns Def (the value is not changed). }
function ParseBoolStr(const S: string; Def: Boolean): Boolean;
{ Resolves the api_key value. A variable name is recognised only with the "&"
  prefix: "api_key=&MY_API_KEY" -> the value of the variable (on Windows the
  name is case-insensitive). Any other string, even one matching the name of
  an existing environment variable, is treated as a literal key and returned
  as is. If the variable is unset or the name is invalid, the string stays as
  is (a literal key together with the "&"). }
function ResolveApiKey(const S: string): string;

implementation

uses
  SysUtils, Classes, IniFiles, mirmid.util, mirmid.tools;

function ConfigDir(const Dir: string): string;
begin
  Result := MirmidDir(Dir);
end;

function ProjectConfigPath(const Dir: string): string;
begin
  Result := ConfigDir(Dir) + PathDelim + 'mirmid.ini';
end;

function ReadFloatIni(F: TIniFile; const Section, Name: string; Def: Double): Double;
var
  S: string;
begin
  S := F.ReadString(Section, Name, '');
  if S = '' then
    Exit(Def);
  Result := DotToFloat(S, Def);
end;

function ParseBoolStr(const S: string; Def: Boolean): Boolean;
var
  V: string;
begin
  V := LowerCase(Trim(S));
  if (V = '1') or (V = 'true') or (V = 'yes') or (V = 'on') then
    Exit(True);
  if (V = '0') or (V = 'false') or (V = 'no') or (V = 'off') then
    Exit(False);
  Result := Def;
end;
{ Resolves the api_key value. A variable name is recognised only with the "&"
  prefix: "api_key=&MY_API_KEY" -> the value of the variable (on Windows the
  name is case-insensitive). Any other string, even one matching the name of
  an existing environment variable, is treated as a literal key and returned
  as is. If the variable is unset or the name is invalid, the string stays as
  is (a literal key together with the "&"). }
function ResolveApiKey(const S: string): string;
var
  V, Name, Val: string;
  I: Integer;
begin
  V := Trim(S);
  if V = '' then
    Exit('');
  { Without the "&" prefix the string is a literal key, even when it matches
    the name of an environment variable. }
  if V[1] <> '&' then
    Exit(V);
  Name := Trim(Copy(V, 2, MaxInt));
  if Name = '' then
    Exit(V);
  { A valid environment variable name: starts with a letter or an underscore,
    followed by letters, digits and underscores. }
  if not (Name[1] in ['A'..'Z', 'a'..'z', '_']) then
    Exit(V);
  for I := 2 to Length(Name) do
    if not (Name[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit(V);
  { Look up the variable with that name. GetEnvironmentVariable returns '' both
    for a missing and for an empty variable — in both cases the string stays a
    literal key. }
  Val := GetEnvironmentVariable(Name);
  if Val <> '' then
    Exit(Val);
  Result := V;
end;

{ Name of the section holding the tool keys. A typo in the section name itself
  ("[tool]" or "[tools ]" with a space) used to silently reset every tool to its
  defaults: the user wrote grep=0 and grep stayed enabled. This is the same
  class of silent typo as an unknown key, so the section name is validated just
  as strictly. Case does not matter: TIniFile reads sections case-insensitively,
  therefore "[Tools]" is not an error. }
const
  TOOLS_SECTION = 'tools';

function CheckToolsSectionName(F: TIniFile; out Err: string): Boolean;
var
  Sections: TStringList;
  I: Integer;
  Raw, Norm: string;
begin
  Err := '';
  Result := True;
  Sections := TStringList.Create;
  try
    F.ReadSections(Sections);
    for I := 0 to Sections.Count - 1 do
    begin
      Raw := Sections[I];
      Norm := LowerCase(Trim(Raw));
      { "[tools ]": TIniFile no longer reads the keys of this section, so the
        tools silently stay at their defaults. }
      if (Norm = TOOLS_SECTION) and (Trim(Raw) <> Raw) then
      begin
        Err := Format('section name "[%s]" has stray spaces; write it as [%s]',
          [Raw, TOOLS_SECTION]);
        Exit(False);
      end;
      { "[tool]" is the most likely typo; any other section is ignored as well,
        but banning every unfamiliar section would break forward compatibility. }
      if Norm = 'tool' then
      begin
        Err := Format('unknown section "[%s]"; did you mean [%s]?',
          [Raw, TOOLS_SECTION]);
        Exit(False);
      end;
    end;
  finally
    Sections.Free;
  end;
end;

function LoadIni(const FileName: string; var C: TMirmidConfig;
  out Err: string): Boolean;
var
  F: TIniFile;
  Keys: TStringList;
  I, J: Integer;
  ToolName: string;
begin
  Err := '';
  Result := True;
  if not FileExists(FileName) then
    Exit;
  F := TIniFile.Create(FileName);
  try
    if not CheckToolsSectionName(F, Err) then
      Exit(False);
    C.BaseUrl := F.ReadString('llm', 'base_url', C.BaseUrl);
    C.ApiKey := F.ReadString('llm', 'api_key', C.ApiKey);
    C.Model := F.ReadString('llm', 'model', C.Model);
    C.Temperature := ReadFloatIni(F, 'llm', 'temperature', C.Temperature);
    C.MaxTokens := F.ReadInteger('llm', 'max_tokens', C.MaxTokens);
    C.Reasoning := NormalizeReasoning(F.ReadString('llm', 'reasoning', C.Reasoning));
    C.Stream := F.ReadBool('llm', 'stream', C.Stream);
    C.ContextWindow := F.ReadInteger('llm', 'context_window', C.ContextWindow);
    C.RequestTimeout := F.ReadInteger('llm', 'timeout', C.RequestTimeout div 1000) * 1000;
    C.ConnectTimeout := F.ReadInteger('llm', 'connect_timeout', C.ConnectTimeout div 1000) * 1000;
    C.SystemPrompt := F.ReadString('agent', 'system_prompt', C.SystemPrompt);
    C.MaxSteps := F.ReadInteger('agent', 'max_steps', C.MaxSteps);
    C.PlanMode := F.ReadBool('agent', 'plan', C.PlanMode);
    C.PlanStepMaxSteps := F.ReadInteger('agent', 'plan_step_max_steps', C.PlanStepMaxSteps);
    C.PlanStepFixAttempts := F.ReadInteger('agent', 'plan_step_fix_attempts', C.PlanStepFixAttempts);
    C.PlanMaxStep := F.ReadInteger('agent', 'plan_max_step', C.PlanMaxStep);
    C.Verbose := F.ReadBool('agent', 'verbose', C.Verbose);
    { Maximum number of tool output lines (0 — no limit). }
    C.ToolOutputLines := F.ReadInteger('agent', 'tool_output_lines', C.ToolOutputLines);

    C.ShellTimeout := F.ReadInteger('workspace', 'shell_timeout', C.ShellTimeout);
    C.ShellOutputLimit := F.ReadInteger('workspace', 'shell_output_limit', C.ShellOutputLimit);

    { [tools] section: one key per built-in tool. The set of keys is defined by
      the mirmid.tools table; an unknown key is a fatal error, otherwise a typo
      would silently leave a tool at its default value. }
    Keys := TStringList.Create;
    try
      F.ReadSection(TOOLS_SECTION, Keys);
      for I := 0 to Keys.Count - 1 do
      begin
        { Key name as written in the file; empty entries (ReadSection returns
          them for blank lines of the section) are skipped. }
        ToolName := Trim(Keys[I]);
        if ToolName = '' then
          Continue;
        { Duplicate key: TIniFile reads the first value while the reader of the
          file expects the last one — the mismatch could enable a tool despite an
          explicit "=0" written below. The error is the same as for an unknown
          key. }
        for J := 0 to I - 1 do
          if SameText(Trim(Keys[J]), ToolName) then
          begin
            Err := Format('duplicate tool "%s" in [%s]', [ToolName, TOOLS_SECTION]);
            Exit(False);
          end;
        if not IsKnownToolName(ToolName) then
        begin
          Err := Format('unknown tool "%s"; known tools: %s',
            [ToolName, ToolNamesCsv]);
          Exit(False);
        end;
        SetToolEnabled(C, ToolName,
          ParseBoolStr(F.ReadString(TOOLS_SECTION, ToolName, ''),
            ToolEnabledByDefault(ToolName)));
      end;
    finally
      Keys.Free;
    end;

    C.McpEnabled := F.ReadBool('mcp', 'enabled', C.McpEnabled);
    C.McpConfig := F.ReadString('mcp', 'config', C.McpConfig);
    C.McpTimeout := F.ReadInteger('mcp', 'timeout', C.McpTimeout);

    C.SummarizeThresholdPercent := F.ReadInteger('agent', 'summarize_threshold_percent', C.SummarizeThresholdPercent);
    C.SummarizeThresholdTokens := F.ReadInteger('agent', 'summarize_threshold_tokens', C.SummarizeThresholdTokens);
    C.SummarizeMinSavingPercent := F.ReadInteger('agent', 'summarize_min_saving_percent', C.SummarizeMinSavingPercent);
    C.SummarizeMinSavingTokens := F.ReadInteger('agent', 'summarize_min_saving_tokens', C.SummarizeMinSavingTokens);
    { Loop protection (loop-guard). }
    C.LoopWarn := F.ReadInteger('agent', 'loop_warn', C.LoopWarn);
    C.LoopStop := F.ReadInteger('agent', 'loop_stop', C.LoopStop);

  finally
    F.Free;
  end;
end;

procedure ApplyEnv(var C: TMirmidConfig);
var
  S: string;
begin
  S := GetEnvironmentVariable('MIRMID_BASE_URL');
  if S <> '' then
    C.BaseUrl := S;
  S := GetEnvironmentVariable('MIRMID_API_KEY');
  if S <> '' then
    C.ApiKey := S;
  S := GetEnvironmentVariable('MIRMID_MODEL');
  if S <> '' then
    C.Model := S;
  S := GetEnvironmentVariable('MIRMID_TEMPERATURE');
  if S <> '' then
    C.Temperature := DotToFloat(S, C.Temperature);
  S := GetEnvironmentVariable('MIRMID_REASONING');
  if S <> '' then
    C.Reasoning := NormalizeReasoning(S);
  S := LowerCase(Trim(GetEnvironmentVariable('MIRMID_STREAM')));
  if (S = '1') or (S = 'true') or (S = 'yes') or (S = 'on') then
    C.Stream := True;
  if (S = '0') or (S = 'false') or (S = 'no') or (S = 'off') then
    C.Stream := False;
  C.PlanMode := ParseBoolStr(GetEnvironmentVariable('MIRMID_PLAN'), C.PlanMode);
  S := GetEnvironmentVariable('MIRMID_CONTEXT_WINDOW');
  if S <> '' then
    C.ContextWindow := StrToIntDef(S, C.ContextWindow);

  S := LowerCase(Trim(GetEnvironmentVariable('MIRMID_MCP')));
  if (S = '1') or (S = 'true') or (S = 'yes') or (S = 'on') then
    C.McpEnabled := True;
  if (S = '0') or (S = 'false') or (S = 'no') or (S = 'off') then
    C.McpEnabled := False;
  S := GetEnvironmentVariable('MIRMID_MCP_CONFIG');
  if S <> '' then
    C.McpConfig := S;
  S := GetEnvironmentVariable('MIRMID_MCP_TIMEOUT');
  if S <> '' then
    C.McpTimeout := StrToIntDef(S, C.McpTimeout);
end;

function SaveSampleIni(const FileName: string; const C: TMirmidConfig;
  out Err: string): Boolean;
var
  L: TStringList;
  I: Integer;
  Def: TToolSwitchDef;
begin
  Err := '';
  Result := False;
  L := TStringList.Create;
  try
    L.Add('# mirmid configuration. Created by `mirmid --init`.');
    L.Add('# The file lives in the .mirmid directory of the working folder.');
    L.Add('# Values can be overridden with the MIRMID_BASE_URL, MIRMID_API_KEY,');
    L.Add('# MIRMID_MODEL, MIRMID_TEMPERATURE, MIRMID_REASONING environment variables.');
    L.Add('');
    L.Add('[llm]');
    L.Add('base_url=' + C.BaseUrl);
    L.Add('# API key literally, or "&NAME" of an environment variable holding it');
    if C.ApiKeyRaw <> '' then
      L.Add('api_key=' + C.ApiKeyRaw)
    else
      L.Add('api_key=' + C.ApiKey);
    L.Add('model=' + C.Model);
    L.Add('temperature=' + FloatToDotStr(C.Temperature));
    L.Add('max_tokens=' + IntToStr(C.MaxTokens));
    L.Add('reasoning=' + C.Reasoning);
    L.Add('stream=' + BoolToStr(C.Stream, '1', '0'));
    L.Add('context_window=' + IntToStr(C.ContextWindow));
    L.Add('timeout=' + IntToStr(C.RequestTimeout div 1000));
    L.Add('connect_timeout=' + IntToStr(C.ConnectTimeout div 1000));
    L.Add('');
    L.Add('[agent]');
    L.Add('max_steps=' + IntToStr(C.MaxSteps));
    L.Add('# Plan mode: plan -> steps -> report (0 — off, 1 — on).');
    L.Add('plan=' + BoolToStr(C.PlanMode, '1', '0'));
    L.Add('# Step budget: limit of "model -> tools" iterations per step (0 — no limit).');
    L.Add('plan_step_max_steps=' + IntToStr(C.PlanStepMaxSteps));
    L.Add('# Retries of a plan step after an abnormal result, passing the failure cause (0 — do not retry).');
    L.Add('plan_step_fix_attempts=' + IntToStr(C.PlanStepFixAttempts));
    L.Add('# Maximum number of steps in the plan itself (0 — no limit).');
    L.Add('plan_max_step=' + IntToStr(C.PlanMaxStep));
    L.Add('system_prompt=' + C.SystemPrompt);
    L.Add('verbose=' + BoolToStr(C.Verbose, '1', '0'));
    L.Add('# Maximum number of tool output lines: the middle is cut out into an');
    L.Add('# indented "..." line (0 — no limit).');
    L.Add('tool_output_lines=' + IntToStr(C.ToolOutputLines));
    L.Add('# Auto-summarisation threshold: % of context fill (0 — off).');
    L.Add('summarize_threshold_percent=' + IntToStr(C.SummarizeThresholdPercent));
    L.Add('# Auto-summarisation threshold: absolute value in tokens (0 — use the percent).');
    L.Add('summarize_threshold_tokens=' + IntToStr(C.SummarizeThresholdTokens));
    L.Add('# Minimum % of context reduction for a summary to be effective.');
    L.Add('summarize_min_saving_percent=' + IntToStr(C.SummarizeMinSavingPercent));
    L.Add('# Minimum absolute reduction in tokens (0 — use the percent).');
    L.Add('summarize_min_saving_tokens=' + IntToStr(C.SummarizeMinSavingTokens));
    L.Add('# Loop-guard: repetitions of one tool call in a row that trigger a warning (0 — off).');
    L.Add('loop_warn=' + IntToStr(C.LoopWarn));
    L.Add('# Loop-guard: repetitions of one tool call in a row that stop the turn (0 — off).');
    L.Add('loop_stop=' + IntToStr(C.LoopStop));
    L.Add('');
    L.Add('[tools]');
    L.Add('# One key per built-in tool: 1 enables the tool, 0 keeps it away from');
    L.Add('# the model and makes its handler refuse to run.');
    for I := 0 to ToolSwitchCount - 1 do
    begin
      Def := ToolSwitchAt(I);
      L.Add('# ' + Def.Note);
      L.Add(Def.Name + '=' + BoolToStr(ToolEnabled(C, Def.Name), '1', '0'));
    end;
    L.Add('');
    L.Add('[workspace]');
    L.Add('shell_timeout=' + IntToStr(C.ShellTimeout));
    L.Add('# Maximum output of the shell tool in bytes (0 — no limit).');
    L.Add('shell_output_limit=' + IntToStr(C.ShellOutputLimit));
    L.Add('');
    L.Add('[mcp]');
    L.Add('# Connect MCP servers from .mirmid/mcp.json (see config/mcp.json.example).');
    L.Add('enabled=' + BoolToStr(C.McpEnabled, '1', '0'));
    L.Add('# Path to mcp.json; empty — look for ./.mirmid/mcp.json.');
    L.Add('config=' + C.McpConfig);
    L.Add('# MCP server response timeout, seconds.');
    L.Add('timeout=' + IntToStr(C.McpTimeout));
    if not EnsureParentDir(FileName) then
    begin
      Err := 'cannot create directory for ' + FileName;
      Exit;
    end;
    try
      L.SaveToFile(FileName);
      Result := True;
    except
      on E: Exception do
        Err := E.Message;
    end;
  finally
    L.Free;
  end;
end;

end.
