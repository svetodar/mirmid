unit test_config;
{ Тесты загрузки и сохранения конфигурации. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.types;

type
  TConfigTests = class(TTestCase)
  private
    { Читает INI и требует успешного разбора: тесты разбора значений не должны
      проходить на файле, который LoadIni отверг (например из-за опечатки в
      имени секции [tools]). }
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
  AssertTrue('INI не разобран: ' + Err, Ok);
end;

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
  SetToolEnabled(Base, 'shell', True);
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
  LoadIniOk(FileName, C2);
  AssertEquals('base_url', Base.BaseUrl, C2.BaseUrl);
  AssertEquals('model', Base.Model, C2.Model);
  AssertEquals('temperature', Base.Temperature, C2.Temperature, 0.0001);
  AssertEquals('max_steps', Base.MaxSteps, C2.MaxSteps);
  AssertTrue('shell из [tools]', ToolEnabled(C2, 'shell'));
  AssertFalse('edit_text_file по умолчанию выключен',
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
  LoadIniOk(FileName, C);
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
  LoadIniOk(FileName, C);
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
  LoadIniOk(FileName, C);
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
  LoadIniOk(FileName, C);
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
  LoadIniOk(FileName, C);
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
  LoadIniOk(FileName, C);
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

procedure TConfigTests.TestIniToolsSection;
var
  C: TMirmidConfig;
  FileName, Err: string;
  L: TStringList;
begin
  { Секция [tools]: значения 1/0/true/false читаются, нераспознанное и пустое
    значение оставляют значение по умолчанию (1/true/yes/on, 0/false/no/off). }
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
  AssertTrue('разбор [tools]', LoadIni(FileName, C, Err));
  AssertEquals('ошибки нет', '', Err);
  AssertTrue('shell=1', ToolEnabled(C, 'shell'));
  AssertTrue('http_request=true', ToolEnabled(C, 'http_request'));
  AssertFalse('edit_text_file=0', ToolEnabled(C, 'edit_text_file'));
  AssertFalse('copy_file=false', ToolEnabled(C, 'copy_file'));
  AssertTrue('пустое значение — умолчание (grep=1)', ToolEnabled(C, 'grep'));
  AssertFalse('нераспознанное — умолчание (subagent=0)',
    ToolEnabled(C, 'subagent'));
  AssertFalse('не упомянутый ключ — умолчание (screen_shoot=0)',
    ToolEnabled(C, 'screen_shoot'));

  { Значение ключа перекрывает умолчание в обе стороны. }
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
  AssertTrue('разбор [tools] (2)', LoadIni(FileName, C, Err));
  AssertFalse('grep=0 выключает инструмент', ToolEnabled(C, 'grep'));
  AssertTrue('screen_shoot=1 включает инструмент', ToolEnabled(C, 'screen_shoot'));

  DeleteFile(FileName);
end;

{ Неизвестный ключ в [tools] — ошибка чтения INI с перечислением известных
  имён: опечатка не должна молча оставить инструмент с умолчанием. }
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
  AssertFalse('неизвестный ключ — отказ', LoadIni(FileName, C, Err));
  AssertTrue('в сообщении имя ключа: ' + Err, Pos('"shel"', Err) > 0);
  AssertTrue('в сообщении есть перечень известных: ' + Err,
    Pos('known tools: ', Err) > 0);
  AssertTrue('перечень начинается с file_list: ' + Err,
    Pos(ToolNamesCsv, Err) > 0);

  DeleteFile(FileName);
end;

{ Секции [tools] нет: все инструменты работают со значениями по умолчанию из
  таблицы mirmid.tools. }
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
  AssertTrue('разбор INI без [tools]', LoadIni(FileName, C, Err));
  AssertEquals('переключателей нет', 0, Length(C.Tools));
  for I := 0 to ToolSwitchCount - 1 do
    AssertEquals('умолчание ' + ToolSwitchAt(I).Name,
      ToolSwitchAt(I).Default, ToolEnabled(C, ToolSwitchAt(I).Name));

  DeleteFile(FileName);
end;

{ Образец конфигурации (--init) содержит секцию [tools] со всеми ключами
  таблицы и не содержит убранных ключей; файл читается обратно и
  воспроизводит те же переключатели. }
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
  AssertTrue('сохранение примера', SaveSampleIni(FileName, C, Err));

  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    AssertTrue('есть секция [tools]', L.IndexOf('[tools]') >= 0);
    { Каждый ключ таблицы присутствует в образце (значение — из настроек). }
    for I := 0 to ToolSwitchCount - 1 do
    begin
      Found := False;
      for J := 0 to L.Count - 1 do
        if Pos(ToolSwitchAt(I).Name + '=', L[J]) = 1 then
          Found := True;
      AssertTrue('в образце есть ключ ' + ToolSwitchAt(I).Name, Found);
    end;
    AssertTrue('shell=1 из настроек',
      L.IndexOf('shell=1') >= 0);
    AssertTrue('grep=0 из настроек', L.IndexOf('grep=0') >= 0);
    AssertFalse('нет ключа записи', L.IndexOf('allow' + '_write=1') >= 0);
    AssertFalse('нет ключа команд', L.IndexOf('allow' + '_shell=1') >= 0);
    AssertFalse('нет ключа HTTP', L.IndexOf('allow' + '_http=1') >= 0);
    AssertFalse('нет ключа доверия', L.IndexOf('ca' + '_file=') >= 0);
  finally
    L.Free;
  end;

  C := DefaultConfig;
  AssertTrue('пример читается обратно', LoadIni(FileName, C, Err));
  AssertTrue('shell=1 из образца', ToolEnabled(C, 'shell'));
  AssertFalse('grep=0 из образца', ToolEnabled(C, 'grep'));
  AssertFalse('edit_text_file по умолчанию', ToolEnabled(C, 'edit_text_file'));

  DeleteFile(FileName);
end;

{ Опечатка в имени секции («[tool]», «[tools ]» с пробелом) — отказ чтения:
  раньше ключи такой секции молча игнорировались и инструменты оставались с
  умолчаниями (написанное «grep=0» ничего не выключало). Регистр при этом не
  важен: «[Tools]» TIniFile читает, поэтому это не ошибка. }
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
  AssertFalse('[tool] — отказ', LoadIni(FileName, C, Err));
  AssertTrue('в сообщении имя секции: ' + Err, Pos('"[tool]"', Err) > 0);
  AssertTrue('в сообщении подсказка [tools]: ' + Err, Pos('[tools]', Err) > 0);

  { Пробел в имени секции: TIniFile такую секцию с [tools] уже не сопоставит. }
  L := TStringList.Create;
  try
    L.Add('[tools ]');
    L.Add('grep=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
  C := DefaultConfig;
  AssertFalse('[tools ] — отказ', LoadIni(FileName, C, Err));
  AssertTrue('в сообщении про пробелы: ' + Err, Pos('stray spaces', Err) > 0);

  { Регистр имени секции не ошибка: ключи читаются. }
  L := TStringList.Create;
  try
    L.Add('[Tools]');
    L.Add('grep=0');
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
  C := DefaultConfig;
  AssertTrue('[Tools] читается', LoadIni(FileName, C, Err));
  AssertFalse('[Tools] grep=0 выключает инструмент', ToolEnabled(C, 'grep'));

  DeleteFile(FileName);
end;

{ Дубликат ключа в [tools] — отказ: TIniFile читает первое значение, а
  последнее («shell=0») пользователь написал ниже и ждёт именно его. }
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
  AssertFalse('дубликат ключа — отказ', LoadIni(FileName, C, Err));
  AssertTrue('в сообщении имя ключа: ' + Err,
    Pos('duplicate tool "shell"', Err) > 0);

  DeleteFile(FileName);
end;

{ Контракт ResolveConfig: корректный INI — True и пустая причина. }
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
  AssertTrue('командная строка разобрана', ParseCli(Args, Cli, Err));
  WorkDir := GetCurrentDir;
  AssertTrue('корректный INI принят', ResolveConfig(Cli, C, WorkDir, Err));
  AssertEquals('причины нет', '', Err);
  AssertTrue('shell=1 из INI', ToolEnabled(C, 'shell'));

  DeleteFile(FileName);
end;

{ Неизвестный ключ в [tools] возвращается из ResolveConfig как отказ с причиной:
  по этому контракту Main печатает ошибку и выходит с кодом 1 (E2E-тест в
  test_cli проверяет собранный бинарник, но пропускается, если его нет). }
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
  AssertTrue('командная строка разобрана', ParseCli(Args, Cli, Err));
  WorkDir := GetCurrentDir;
  AssertFalse('неизвестный ключ — отказ', ResolveConfig(Cli, C, WorkDir, Err));
  AssertTrue('в причине имя ключа: ' + Err, Pos('"shel"', Err) > 0);
  AssertTrue('в причине список известных: ' + Err, Pos('known tools: ', Err) > 0);

  DeleteFile(FileName);
end;

{ --init обязан работать и со сломанным INI: он и нужен, чтобы починить файл,
  поэтому отказ разбора не должен мешать генерации образца. }
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
  AssertTrue('командная строка разобрана', ParseCli(Args, Cli, Err));
  WorkDir := GetCurrentDir;
  AssertTrue('--init со сломанным INI', ResolveConfig(Cli, C, WorkDir, Err));
  AssertEquals('причины нет — образец пишется', '', Err);
  AssertTrue('инструменты — умолчания (grep=1)', ToolEnabled(C, 'grep'));

  DeleteFile(FileName);
end;

initialization
  RegisterTest(TConfigTests);

end.
