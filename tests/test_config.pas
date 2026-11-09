unit test_config;
{ Tests for loading and saving the configuration. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.types;

type
  TConfigTests = class(TTestCase)
  private
    { Reads the INI and requires successful parsing: value parsing tests must
      not pass on a file that LoadIni rejected (for example because of a typo in
      the [tools] section name). }
    procedure LoadIniOk(const FileName: string; var C: TMirmidConfig);
  published
    procedure TestIniRoundTrip;
    procedure TestMissingFileKeepsDefaults;
    procedure TestNormalizeReasoning;
    procedure TestPathsInMirmidDir;
    procedure TestIniPlanKeys;
    procedure TestIniPlanKeysMissing;
    procedure TestIniToolOutputLines;
    procedure TestEnvPlan;
    procedure TestResolveApiKey;
    procedure TestCliPlanFlags;
    procedure TestIniToolsSection;
    procedure TestIniToolsUnknownKey;
    procedure TestIniToolsDefaults;
    procedure TestSampleIniToolsBlock;
    procedure TestIniToolsSectionNameTypo;
    procedure TestIniToolsDuplicateKey;
    procedure TestResolveConfigValidIni;
    procedure TestResolveConfigUnknownToolKey;
    procedure TestResolveConfigInitToleratesBrokenIni;
  end;

implementation

uses
  SysUtils, Classes, mirmid.config, mirmid.util, mirmid.cli, mirmid.tools;

procedure TConfigTests.LoadIniOk(const FileName: string; var C: TMirmidConfig);
var
  Err: string;
  Ok: Boolean;
begin
  Ok := LoadIni(FileName, C, Err);
  AssertTrue('INI was not parsed: ' + Err, Ok);
end;

procedure TConfigTests.TestIniRoundTrip;
var
  C2, Base: TMirmidConfig;
  L: TStringList;
  FileName, Err: string;
  OldSep: Char;
begin
  { A comma-decimal locale must not break the INI format. }
  OldSep := DefaultFormatSettings.DecimalSeparator;
  DefaultFormatSettings.DecimalSeparator := ',';
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test.ini';
  DeleteFile(FileName);

  Base := DefaultConfig;
  Base.BaseUrl := 'http://example.test/v1';
  Base.Model := 'test-model';
  Base.Temperature := 0.7;
  Base.MaxSteps := 5;
  SetToolEnabled(Base, 'shell', True);
  Base.Reasoning := 'high';
  AssertTrue('save', SaveSampleIni(FileName, Base, Err));

  { The number is written with a dot — the value is portable across locales. }
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    AssertTrue('temperature is written with a dot',
      L.IndexOf('temperature=0.7') >= 0);
  finally
    L.Free;
  end;

  C2 := DefaultConfig;
  LoadIniOk(FileName, C2);
  AssertEquals('base_url', Base.BaseUrl, C2.BaseUrl);
  AssertEquals('model', Base.Model, C2.Model);
  AssertEquals('temperature', Base.Temperature, C2.Temperature, 0.0001);
  AssertEquals('max_steps', Base.MaxSteps, C2.MaxSteps);
  AssertTrue('shell from [tools]', ToolEnabled(C2, 'shell'));
  AssertFalse('edit_text_file is off by default',
    ToolEnabled(C2, 'edit_text_file'));
  AssertEquals('reasoning', 'high', C2.Reasoning);

  DeleteFile(FileName);
  DefaultFormatSettings.DecimalSeparator := OldSep;
end;

procedure TConfigTests.TestMissingFileKeepsDefaults;
var
  C: TMirmidConfig;
begin
  C := DefaultConfig;
  C.Model := 'keep-me';
  LoadIniOk('/nonexistent/mirmid.ini', C);
  AssertEquals('value is unchanged', 'keep-me', C.Model);
end;

procedure TConfigTests.TestPathsInMirmidDir;
begin
  AssertEquals('config directory',
    IncludeTrailingPathDelimiter(GetCurrentDir) + '.mirmid',
    ConfigDir(GetCurrentDir));
  AssertEquals('config file',
    IncludeTrailingPathDelimiter(GetCurrentDir) + '.mirmid' + PathDelim + 'mirmid.ini',
    ProjectConfigPath(GetCurrentDir));
end;

procedure TConfigTests.TestNormalizeReasoning;
begin
  AssertEquals('empty', '', NormalizeReasoning(''));
  AssertEquals('none', 'none', NormalizeReasoning('off'));
  AssertEquals('false', 'none', NormalizeReasoning('false'));
  AssertEquals('on', 'medium', NormalizeReasoning('on'));
  AssertEquals('true', 'medium', NormalizeReasoning('TRUE'));
  AssertEquals('minimal', 'minimal', NormalizeReasoning(' Minimal '));
  AssertEquals('high', 'high', NormalizeReasoning('high'));
  AssertEquals('unknown', '', NormalizeReasoning('turbo'));
end;

procedure TConfigTests.TestIniPlanKeys;
var
  C: TMirmidConfig;
  FileName: string;
  L: TStringList;
begin
  { The plan/plan_step_max_steps keys of [agent] are read. }
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-plan.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('plan=1');
    L.Add('plan_step_max_steps=5');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIniOk(FileName, C);
  AssertTrue('plan=1 is read', C.PlanMode);
  AssertEquals('plan_step_max_steps=5 is read', 5, C.PlanStepMaxSteps);
  DeleteFile(FileName);
end;

procedure TConfigTests.TestIniPlanKeysMissing;
var
  C: TMirmidConfig;
  FileName: string;
  L: TStringList;
begin
  { Missing keys do not change the default values. }
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-plan-missing.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('verbose=1');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIniOk(FileName, C);
  AssertFalse('plan is off by default', C.PlanMode);
  AssertEquals('plan_step_max_steps defaults to 0 (no limit)', 0, C.PlanStepMaxSteps);
  DeleteFile(FileName);
end;

procedure TConfigTests.TestIniToolOutputLines;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  { Tool output line limit: DEFAULT_TOOL_OUTPUT_LINES by default (the middle of
    a long output is cut out), 0 — no limit. }
  C := DefaultConfig;
  AssertEquals('DEFAULT_TOOL_OUTPUT_LINES by default',
    DEFAULT_TOOL_OUTPUT_LINES, C.ToolOutputLines);

  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tool-lines.ini';
  DeleteFile(FileName);

  { No key — the default value is kept. }
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('verbose=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIniOk(FileName, C);
  AssertEquals('without the key — the default value',
    DEFAULT_TOOL_OUTPUT_LINES, C.ToolOutputLines);

  { The key is read from [agent]. }
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('tool_output_lines=15');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIniOk(FileName, C);
  AssertEquals('tool_output_lines=15 is read', 15, C.ToolOutputLines);

  { 0 — no limit (the value is not replaced by the default). }
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('tool_output_lines=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIniOk(FileName, C);
  AssertEquals('tool_output_lines=0 — no limit', 0, C.ToolOutputLines);

  { The sample configuration (--init) contains the key and reads back. }
  C := DefaultConfig;
  C.ToolOutputLines := 12;
  AssertTrue('save the sample', SaveSampleIni(FileName, C, Err));
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    AssertTrue('the sample contains tool_output_lines=12',
      L.IndexOf('tool_output_lines=12') >= 0);
  finally
    L.Free;
  end;
  C := DefaultConfig;
  LoadIniOk(FileName, C);
  AssertEquals('tool_output_lines from the sample', 12, C.ToolOutputLines);

  DeleteFile(FileName);
end;

procedure TConfigTests.TestEnvPlan;
begin
  { The MIRMID_PLAN parsing logic used by ApplyEnv:
    1/true/yes/on -> True, 0/false/no/off -> False, anything else — unchanged. }
  AssertTrue('MIRMID_PLAN=1', ParseBoolStr('1', False));
  AssertFalse('MIRMID_PLAN=0', ParseBoolStr('0', True));
  AssertTrue('MIRMID_PLAN=true', ParseBoolStr('true', False));
  AssertFalse('MIRMID_PLAN=false', ParseBoolStr('false', True));
  AssertTrue('MIRMID_PLAN=yes', ParseBoolStr('yes', False));
  AssertFalse('MIRMID_PLAN=no', ParseBoolStr('no', True));
  AssertTrue('MIRMID_PLAN=on', ParseBoolStr('on', False));
  AssertFalse('MIRMID_PLAN=off', ParseBoolStr('off', True));
  AssertFalse('an empty value changes nothing (off)', ParseBoolStr('', False));
  AssertTrue('an empty value changes nothing (on)', ParseBoolStr('', True));
  AssertTrue('an unrecognised value changes nothing (on)', ParseBoolStr('garbage', True));
  AssertFalse('an unrecognised value changes nothing (off)', ParseBoolStr('garbage', False));
  AssertTrue('case and spaces are ignored', ParseBoolStr('  ON  ', False));
end;

procedure TConfigTests.TestResolveApiKey;
begin
  { A string without the "&" prefix is a literal key, even when it matches the
    name of an existing environment variable (PATH is always present). }
  AssertEquals('literal key', 'sk-12345', ResolveApiKey('sk-12345'));
  AssertEquals('empty', '', ResolveApiKey(''));
  AssertEquals('spaces', '', ResolveApiKey('   '));
  AssertEquals('digit start', '123ABC', ResolveApiKey('123ABC'));
  AssertEquals('hyphen', 'MY-ENV', ResolveApiKey('MY-ENV'));
  AssertEquals('inner space', 'MY ENV', ResolveApiKey('MY ENV'));
  AssertEquals('trimmed literal', 'sk-12345', ResolveApiKey('  sk-12345  '));
  AssertEquals('name without ampersand is literal', 'PATH', ResolveApiKey('PATH'));

  { A variable reference is recognised only with the "&" prefix. }
  AssertEquals('env ref', GetEnvironmentVariable('PATH'),
    ResolveApiKey('&PATH'));
  AssertEquals('env ref with spaces', GetEnvironmentVariable('PATH'),
    ResolveApiKey('  &  PATH  '));
  {$IFDEF WINDOWS}
    { On Windows environment variable names are case-insensitive. }
    AssertEquals('case-insensitive', GetEnvironmentVariable('PATH'),
      ResolveApiKey('&path'));
  {$ENDIF}

  { There is no variable with that name — the string stays as is (a literal
    key together with the "&"); a bare "&" is not resolved either. }
  AssertEquals('unset var', '&MIRMID_TEST_API_KEY_NOPE_9X7',
    ResolveApiKey('&MIRMID_TEST_API_KEY_NOPE_9X7'));
  AssertEquals('bare ampersand', '&', ResolveApiKey('&'));
  AssertEquals('bad name', '&MY-ENV', ResolveApiKey('&MY-ENV'));
end;

procedure TConfigTests.TestCliPlanFlags;
var
  Cli: TCli;
  Err: string;
  Args: array of string;
begin
  { --plan enables the plan mode. }
  SetLength(Args, 2);
  Args[0] := '--plan';
  Args[1] := 'hello';
  AssertTrue('ParseCli --plan', ParseCli(Args, Cli, Err));
  AssertTrue('HasPlanMode (--plan)', Cli.HasPlanMode);
  AssertTrue('PlanMode (--plan)', Cli.PlanMode);

  { --no-plan disables the plan mode. }
  SetLength(Args, 2);
  Args[0] := '--no-plan';
  Args[1] := 'hello';
  AssertTrue('ParseCli --no-plan', ParseCli(Args, Cli, Err));
  AssertTrue('HasPlanMode (--no-plan)', Cli.HasPlanMode);
  AssertFalse('PlanMode (--no-plan)', Cli.PlanMode);

  { Without the flag HasPlanMode = False. }
  SetLength(Args, 1);
  Args[0] := 'hello';
  AssertTrue('ParseCli without the flag', ParseCli(Args, Cli, Err));
  AssertFalse('HasPlanMode (no flag)', Cli.HasPlanMode);
end;

procedure TConfigTests.TestIniToolsSection;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  { [tools] section: the values 1/0/true/false are read, an unrecognised or
    empty value keeps the default (1/true/yes/on, 0/false/no/off). }
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tools.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tools]');
    L.Add('shell=1');
    L.Add('http_request=true');
    L.Add('edit_text_file=0');
    L.Add('copy_file=false');
    L.Add('grep=');
    L.Add('subagent=garbage');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  AssertTrue('parse [tools]', LoadIni(FileName, C, Err));
  AssertEquals('no error', '', Err);
  AssertTrue('shell=1', ToolEnabled(C, 'shell'));
  AssertTrue('http_request=true', ToolEnabled(C, 'http_request'));
  AssertFalse('edit_text_file=0', ToolEnabled(C, 'edit_text_file'));
  AssertFalse('copy_file=false', ToolEnabled(C, 'copy_file'));
  AssertTrue('an empty value — the default (grep=1)', ToolEnabled(C, 'grep'));
  AssertFalse('an unrecognised value — the default (subagent=0)',
    ToolEnabled(C, 'subagent'));
  AssertFalse('an unmentioned key — the default (screen_shoot=0)',
    ToolEnabled(C, 'screen_shoot'));

  { A key value overrides the default in both directions. }
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tools]');
    L.Add('grep=0');
    L.Add('screen_shoot=1');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
  C := DefaultConfig;
  AssertTrue('parse [tools] (2)', LoadIni(FileName, C, Err));
  AssertFalse('grep=0 disables the tool', ToolEnabled(C, 'grep'));
  AssertTrue('screen_shoot=1 enables the tool', ToolEnabled(C, 'screen_shoot'));

  DeleteFile(FileName);
end;

{ An unknown key in [tools] is an INI read error listing the known names: a
  typo must not silently leave a tool at its default. }
procedure TConfigTests.TestIniToolsUnknownKey;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tools-bad.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tools]');
    L.Add('shel=1');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  AssertFalse('unknown key — rejection', LoadIni(FileName, C, Err));
  AssertTrue('the message names the key: ' + Err, Pos('"shel"', Err) > 0);
  AssertTrue('the message lists the known ones: ' + Err,
    Pos('known tools: ', Err) > 0);
  AssertTrue('the list starts with file_list: ' + Err,
    Pos(ToolNamesCsv, Err) > 0);

  DeleteFile(FileName);
end;

{ There is no [tools] section: every tool works with the defaults from the
  mirmid.tools table. }
procedure TConfigTests.TestIniToolsDefaults;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
  I: Integer;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tools-none.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('verbose=1');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  AssertTrue('parse an INI without [tools]', LoadIni(FileName, C, Err));
  AssertEquals('no switches', 0, Length(C.Tools));
  for I := 0 to ToolSwitchCount - 1 do
    AssertEquals('default for ' + ToolSwitchAt(I).Name,
      ToolSwitchAt(I).Default, ToolEnabled(C, ToolSwitchAt(I).Name));

  DeleteFile(FileName);
end;

{ The sample configuration (--init) contains the [tools] section with every key
  of the table and none of the removed keys; the file reads back and reproduces
  the same switches. }
procedure TConfigTests.TestSampleIniToolsBlock;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
  I, J: Integer;
  Found: Boolean;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tools-sample.ini';
  DeleteFile(FileName);
  C := DefaultConfig;
  SetToolEnabled(C, 'shell', True);
  SetToolEnabled(C, 'grep', False);
  AssertTrue('save the sample', SaveSampleIni(FileName, C, Err));

  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    AssertTrue('[tools] section present', L.IndexOf('[tools]') >= 0);
    { Every key of the table is present in the sample (the value comes from the
      settings). }
    for I := 0 to ToolSwitchCount - 1 do
    begin
      Found := False;
      for J := 0 to L.Count - 1 do
        if Pos(ToolSwitchAt(I).Name + '=', L[J]) = 1 then
          Found := True;
      AssertTrue('the sample contains the key ' + ToolSwitchAt(I).Name, Found);
    end;
    AssertTrue('shell=1 from the settings',
      L.IndexOf('shell=1') >= 0);
    AssertTrue('grep=0 from the settings', L.IndexOf('grep=0') >= 0);
    AssertFalse('no write key', L.IndexOf('allow' + '_write=1') >= 0);
    AssertFalse('no shell key', L.IndexOf('allow' + '_shell=1') >= 0);
    AssertFalse('no HTTP key', L.IndexOf('allow' + '_http=1') >= 0);
    AssertFalse('no trust key', L.IndexOf('ca' + '_file=') >= 0);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  AssertTrue('the sample reads back', LoadIni(FileName, C, Err));
  AssertTrue('shell=1 from the sample', ToolEnabled(C, 'shell'));
  AssertFalse('grep=0 from the sample', ToolEnabled(C, 'grep'));
  AssertFalse('edit_text_file by default', ToolEnabled(C, 'edit_text_file'));

  DeleteFile(FileName);
end;

{ A typo in the section name ("[tool]", "[tools ]" with a space) — read
  rejection: previously the keys of such a section were silently ignored and the
  tools kept their defaults (the written "grep=0" disabled nothing). Case does
  not matter here: TIniFile reads "[Tools]", so that is not an error. }
procedure TConfigTests.TestIniToolsSectionNameTypo;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tools-typo.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tool]');
    L.Add('grep=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  AssertFalse('[tool] — rejection', LoadIni(FileName, C, Err));
  AssertTrue('the message names the section: ' + Err, Pos('"[tool]"', Err) > 0);
  AssertTrue('the message hints at [tools]: ' + Err, Pos('[tools]', Err) > 0);

  { A space in the section name: TIniFile will no longer match such a section
    against [tools]. }
  L := TStringList.Create;
  try
    L.Add('[tools ]');
    L.Add('grep=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
  C := DefaultConfig;
  AssertFalse('[tools ] — rejection', LoadIni(FileName, C, Err));
  AssertTrue('the message mentions stray spaces: ' + Err, Pos('stray spaces', Err) > 0);

  { The section name case is not an error: the keys are read. }
  L := TStringList.Create;
  try
    L.Add('[Tools]');
    L.Add('grep=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
  C := DefaultConfig;
  AssertTrue('[Tools] is read', LoadIni(FileName, C, Err));
  AssertFalse('[Tools] grep=0 disables the tool', ToolEnabled(C, 'grep'));

  DeleteFile(FileName);
end;

{ A duplicate key in [tools] — rejection: TIniFile reads the first value while
  the user wrote the last one ("shell=0") below and expects exactly that. }
procedure TConfigTests.TestIniToolsDuplicateKey;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tools-dup.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tools]');
    L.Add('shell=1');
    L.Add('shell=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  AssertFalse('duplicate key — rejection', LoadIni(FileName, C, Err));
  AssertTrue('the message names the key: ' + Err,
    Pos('duplicate tool "shell"', Err) > 0);

  DeleteFile(FileName);
end;

{ ResolveConfig contract: a valid INI — True and an empty reason. }
procedure TConfigTests.TestResolveConfigValidIni;
var
  C: TMirmidConfig;
  Cli: TCli;
  Args: array of string;
  WorkDir, Err, FileName: string;
  L: TStringList;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-resolve-ok.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tools]');
    L.Add('shell=1');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  SetLength(Args, 2);
  Args[0] := '--config';
  Args[1] := FileName;
  AssertTrue('command line parsed', ParseCli(Args, Cli, Err));
  WorkDir := GetCurrentDir;
  AssertTrue('a valid INI is accepted', ResolveConfig(Cli, C, WorkDir, Err));
  AssertEquals('no reason', '', Err);
  AssertTrue('shell=1 from the INI', ToolEnabled(C, 'shell'));

  DeleteFile(FileName);
end;

{ An unknown key in [tools] comes back from ResolveConfig as a rejection with a
  reason: by that contract Main prints the error and exits with code 1 (the E2E
  test in test_cli checks the built binary, but is skipped when it is absent). }
procedure TConfigTests.TestResolveConfigUnknownToolKey;
var
  C: TMirmidConfig;
  Cli: TCli;
  Args: array of string;
  WorkDir, Err, FileName: string;
  L: TStringList;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-resolve-bad.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tools]');
    L.Add('shel=1');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  SetLength(Args, 2);
  Args[0] := '--config';
  Args[1] := FileName;
  AssertTrue('command line parsed', ParseCli(Args, Cli, Err));
  WorkDir := GetCurrentDir;
  AssertFalse('unknown key — rejection', ResolveConfig(Cli, C, WorkDir, Err));
  AssertTrue('the reason names the key: ' + Err, Pos('"shel"', Err) > 0);
  AssertTrue('the reason lists the known ones: ' + Err, Pos('known tools: ', Err) > 0);

  DeleteFile(FileName);
end;

{ --init must work even with a broken INI: it is exactly what is needed to fix
  the file, so a parse rejection must not prevent generating the sample. }
procedure TConfigTests.TestResolveConfigInitToleratesBrokenIni;
var
  C: TMirmidConfig;
  Cli: TCli;
  Args: array of string;
  WorkDir, Err, FileName: string;
  L: TStringList;
begin
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-init-broken.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[tools]');
    L.Add('shel=1');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  SetLength(Args, 3);
  Args[0] := '--init';
  Args[1] := '--config';
  Args[2] := FileName;
  AssertTrue('command line parsed', ParseCli(Args, Cli, Err));
  WorkDir := GetCurrentDir;
  AssertTrue('--init with a broken INI', ResolveConfig(Cli, C, WorkDir, Err));
  AssertEquals('no reason — the sample is written', '', Err);
  AssertTrue('tools keep their defaults (grep=1)', ToolEnabled(C, 'grep'));

  DeleteFile(FileName);
end;

initialization
  RegisterTest(TConfigTests);

end.
