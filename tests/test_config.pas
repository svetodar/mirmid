unit test_config;
{ Тесты загрузки и сохранения конфигурации. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TConfigTests = class(TTestCase)
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
    procedure TestIniCaFile;
    procedure TestResolveConfigCaFile;
  end;

implementation

uses
  SysUtils, Classes, mirmid.types, mirmid.config, mirmid.util, mirmid.cli,
  mirmid.http;

procedure TConfigTests.TestIniRoundTrip;
var
  C2, Base: TMirmidConfig;
  L: TStringList;
  FileName, Err: string;
  OldSep: Char;
begin
  { Локаль с запятой-разделителем не должна ломать формат INI. }
  OldSep := DefaultFormatSettings.DecimalSeparator;
  DefaultFormatSettings.DecimalSeparator := ',';
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test.ini';
  DeleteFile(FileName);

  Base := DefaultConfig;
  Base.BaseUrl := 'http://example.test/v1';
  Base.Model := 'test-model';
  Base.Temperature := 0.7;
  Base.MaxSteps := 5;
  Base.AllowShell := True;
  Base.Reasoning := 'high';
  AssertTrue('сохранение', SaveSampleIni(FileName, Base, Err));

  { В файле число записано с точкой — значение переносимо между локалями. }
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    AssertTrue('в файле температура записана с точкой',
      L.IndexOf('temperature=0.7') >= 0);
  finally
    L.Free;
  end;

  C2 := DefaultConfig;
  LoadIni(FileName, C2);
  AssertEquals('base_url', Base.BaseUrl, C2.BaseUrl);
  AssertEquals('model', Base.Model, C2.Model);
  AssertEquals('temperature', Base.Temperature, C2.Temperature, 0.0001);
  AssertEquals('max_steps', Base.MaxSteps, C2.MaxSteps);
  AssertEquals('allow_shell', True, C2.AllowShell);
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
  LoadIni('/nonexistent/mirmid.ini', C);
  AssertEquals('значение не изменилось', 'keep-me', C.Model);
end;

procedure TConfigTests.TestPathsInMirmidDir;
begin
  AssertEquals('каталог конфигурации',
    IncludeTrailingPathDelimiter(GetCurrentDir) + '.mirmid',
    ConfigDir(GetCurrentDir));
  AssertEquals('файл конфигурации',
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
  { Ключи plan/plan_step_max_steps в [agent] читаются. }
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
  LoadIni(FileName, C);
  AssertTrue('plan=1 читается', C.PlanMode);
  AssertEquals('plan_step_max_steps=5 читается', 5, C.PlanStepMaxSteps);
  DeleteFile(FileName);
end;

procedure TConfigTests.TestIniPlanKeysMissing;
var
  C: TMirmidConfig;
  FileName: string;
  L: TStringList;
begin
  { Отсутствующие ключи не меняют значения по умолчанию. }
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
  LoadIni(FileName, C);
  AssertFalse('plan по умолчанию выкл.', C.PlanMode);
  AssertEquals('plan_step_max_steps по умолчанию 0 (без ограничений)', 0, C.PlanStepMaxSteps);
  DeleteFile(FileName);
end;

procedure TConfigTests.TestIniToolOutputLines;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  { Лимит строк вывода инструмента: по умолчанию — DEFAULT_TOOL_OUTPUT_LINES
    (середина длинного вывода сокращается), 0 — без ограничения. }
  C := DefaultConfig;
  AssertEquals('по умолчанию — DEFAULT_TOOL_OUTPUT_LINES',
    DEFAULT_TOOL_OUTPUT_LINES, C.ToolOutputLines);

  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-tool-lines.ini';
  DeleteFile(FileName);

  { Ключа нет — значение по умолчанию сохраняется. }
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('verbose=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIni(FileName, C);
  AssertEquals('без ключа — значение по умолчанию',
    DEFAULT_TOOL_OUTPUT_LINES, C.ToolOutputLines);

  { Ключ читается из [agent]. }
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('tool_output_lines=15');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIni(FileName, C);
  AssertEquals('tool_output_lines=15 читается', 15, C.ToolOutputLines);

  { 0 — без ограничения (значение не подменяется дефолтом). }
  L := TStringList.Create;
  try
    L.Add('[agent]');
    L.Add('tool_output_lines=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  LoadIni(FileName, C);
  AssertEquals('tool_output_lines=0 — без ограничения', 0, C.ToolOutputLines);

  { Образец конфигурации (--init) содержит ключ и читается обратно. }
  C := DefaultConfig;
  C.ToolOutputLines := 12;
  AssertTrue('сохранение примера', SaveSampleIni(FileName, C, Err));
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    AssertTrue('в примере есть tool_output_lines=12',
      L.IndexOf('tool_output_lines=12') >= 0);
  finally
    L.Free;
  end;
  C := DefaultConfig;
  LoadIni(FileName, C);
  AssertEquals('tool_output_lines из примера', 12, C.ToolOutputLines);

  DeleteFile(FileName);
end;

procedure TConfigTests.TestEnvPlan;
begin
  { Логика разбора MIRMID_PLAN, используемая в ApplyEnv:
    1/true/yes/on → True, 0/false/no/off → False, иначе — без изменений. }
  AssertTrue('MIRMID_PLAN=1', ParseBoolStr('1', False));
  AssertFalse('MIRMID_PLAN=0', ParseBoolStr('0', True));
  AssertTrue('MIRMID_PLAN=true', ParseBoolStr('true', False));
  AssertFalse('MIRMID_PLAN=false', ParseBoolStr('false', True));
  AssertTrue('MIRMID_PLAN=yes', ParseBoolStr('yes', False));
  AssertFalse('MIRMID_PLAN=no', ParseBoolStr('no', True));
  AssertTrue('MIRMID_PLAN=on', ParseBoolStr('on', False));
  AssertFalse('MIRMID_PLAN=off', ParseBoolStr('off', True));
  AssertFalse('пустое значение не меняет (выкл.)', ParseBoolStr('', False));
  AssertTrue('пустое значение не меняет (вкл.)', ParseBoolStr('', True));
  AssertTrue('нераспознанное не меняет (вкл.)', ParseBoolStr('garbage', True));
  AssertFalse('нераспознанное не меняет (выкл.)', ParseBoolStr('garbage', False));
  AssertTrue('регистр и пробелы игнорируются', ParseBoolStr('  ON  ', False));
end;

procedure TConfigTests.TestResolveApiKey;
begin
  { Строка без префикса «&» — литеральный ключ, даже если совпадает с именем
    существующей переменной окружения (PATH в окружении всегда есть). }
  AssertEquals('literal key', 'sk-12345', ResolveApiKey('sk-12345'));
  AssertEquals('empty', '', ResolveApiKey(''));
  AssertEquals('spaces', '', ResolveApiKey('   '));
  AssertEquals('digit start', '123ABC', ResolveApiKey('123ABC'));
  AssertEquals('hyphen', 'MY-ENV', ResolveApiKey('MY-ENV'));
  AssertEquals('inner space', 'MY ENV', ResolveApiKey('MY ENV'));
  AssertEquals('trimmed literal', 'sk-12345', ResolveApiKey('  sk-12345  '));
  AssertEquals('name without ampersand is literal', 'PATH', ResolveApiKey('PATH'));

  { Ссылка на переменную — только с префиксом «&». }
  AssertEquals('env ref', GetEnvironmentVariable('PATH'),
    ResolveApiKey('&PATH'));
  AssertEquals('env ref with spaces', GetEnvironmentVariable('PATH'),
    ResolveApiKey('  &  PATH  '));
  {$IFDEF WINDOWS}
    { На Windows имена переменных окружения регистронезависимы. }
    AssertEquals('case-insensitive', GetEnvironmentVariable('PATH'),
      ResolveApiKey('&path'));
  {$ENDIF}

  { Переменной с таким именем нет — строка остаётся как есть (литеральный
    ключ вместе с «&»); «&» без имени тоже не разрешается. }
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
  { --plan включает режим планирования. }
  SetLength(Args, 2);
  Args[0] := '--plan';
  Args[1] := 'привет';
  AssertTrue('ParseCli --plan', ParseCli(Args, Cli, Err));
  AssertTrue('HasPlanMode (--plan)', Cli.HasPlanMode);
  AssertTrue('PlanMode (--plan)', Cli.PlanMode);

  { --no-plan выключает режим планирования. }
  SetLength(Args, 2);
  Args[0] := '--no-plan';
  Args[1] := 'привет';
  AssertTrue('ParseCli --no-plan', ParseCli(Args, Cli, Err));
  AssertTrue('HasPlanMode (--no-plan)', Cli.HasPlanMode);
  AssertFalse('PlanMode (--no-plan)', Cli.PlanMode);

  { Без флага HasPlanMode = False. }
  SetLength(Args, 1);
  Args[0] := 'привет';
  AssertTrue('ParseCli без флага', ParseCli(Args, Cli, Err));
  AssertFalse('HasPlanMode (без флага)', Cli.HasPlanMode);
end;

procedure TConfigTests.TestIniCaFile;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  { Ключ ca_file в секции [llm] читается; запись в примере конфигурации
    (--init) потом читается обратно. }
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-ca.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[llm]');
    L.Add('ca_file=certs/ca-bundle.pem');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  { По умолчанию ca_file пуст: доверие берётся из встроенного снимка корней
    (tls.roots), а при его отсутствии — из системного хранилища ОС. Явный
    путь из INI просто читается (существование файла проверяет TLS-слой). }
  C := DefaultConfig;
  AssertEquals('по умолчанию ca_file пуст', '', C.CaFile);

  LoadIni(FileName, C);
  AssertEquals('ca_file читается', 'certs/ca-bundle.pem', C.CaFile);
  DeleteFile(FileName);

  { Пример конфигурации содержит ключ ca_file. }
  C := DefaultConfig;
  C.CaFile := 'C:\certs\ca-bundle.pem';
  AssertTrue('сохранение примера', SaveSampleIni(FileName, C, Err));
  C := DefaultConfig;
  LoadIni(FileName, C);
  AssertEquals('ca_file из примера', 'C:\certs\ca-bundle.pem', C.CaFile);
  DeleteFile(FileName);
end;

procedure TConfigTests.TestResolveConfigCaFile;
var
  Cli: TCli;
  Cfg: TMirmidConfig;
  Err, WorkDir, FileName, EnvCa: string;
  Args: array of string;
  L: TStringList;
  SavedCaFile: string;
begin
  { ResolveConfig раскрывает относительный ca_file от рабочей папки и
    пробрасывает его в глобальную настройку HttpCaFile (mirmid.http).
    Приоритет выше INI имеет переменная окружения MIRMID_CA_FILE, поэтому
    при заданной переменной тест проверяет именно её (иначе тест зависел бы
    от окружения машины: ApplyEnv перекрывает значение из INI). }
  WorkDir := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-ca-work';
  FileName := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-ca-cli.ini';
  DeleteFile(FileName);
  L := TStringList.Create;
  try
    L.Add('[llm]');
    L.Add('ca_file=certs/ca-bundle.pem');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;

  SetLength(Args, 4);
  Args[0] := '--config';
  Args[1] := FileName;
  Args[2] := '--workdir';
  Args[3] := WorkDir;
  AssertTrue('ParseCli', ParseCli(Args, Cli, Err));

  EnvCa := Trim(GetEnvironmentVariable('MIRMID_CA_FILE'));
  SavedCaFile := HttpCaFile;
  try
    ResolveConfig(Cli, Cfg, WorkDir);
    if EnvCa <> '' then
      AssertEquals('MIRMID_CA_FILE приоритетнее INI',
        ExpPath(EnvCa, WorkDir), Cfg.CaFile)
    else
      AssertEquals('ca_file от рабочей папки',
        ExpPath('certs/ca-bundle.pem', WorkDir), Cfg.CaFile);
    AssertEquals('HttpCaFile проброшен', Cfg.CaFile, HttpCaFile);
  finally
    HttpCaFile := SavedCaFile;
    DeleteFile(FileName);
  end;
end;

initialization
  RegisterTest(TConfigTests);

end.
