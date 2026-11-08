unit mirmid.config;
{ Загрузка и сохранение настроек: INI-файлы и переменные окружения.
  Все конфигурационные файлы проекта хранятся в каталоге ./.mirmid. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.types;

{ Каталог конфигурации проекта: <Dir>/.mirmid (без концевого слэша). }
function ConfigDir(const Dir: string): string;
{ Проектный конфиг: <Dir>/.mirmid/mirmid.ini. }
function ProjectConfigPath(const Dir: string): string;

{ Читает INI поверх переданных значений (отсутствующие ключи не трогает).
  Возвращает False и текст причины в Err, если файл непригоден: неизвестный
  ключ в секции [tools], опечатка в имени самой секции ([tool]) или дубликат
  ключа — опечатка не должна молча включать или выключать инструмент. }
function LoadIni(const FileName: string; var C: TMirmidConfig;
  out Err: string): Boolean;
{ Применяет переменные окружения MIRMID_*. }
procedure ApplyEnv(var C: TMirmidConfig);
{ Пишет пример конфигурации. }
function SaveSampleIni(const FileName: string; const C: TMirmidConfig;
  out Err: string): Boolean;
{ Разбирает булеву строку (регистр не важен, пробелы по краям игнорируются):
  1/true/yes/on → True, 0/false/no/off → False.
  Пустая или нераспознанная строка — возвращается Def (значение не меняется). }
function ParseBoolStr(const S: string; Def: Boolean): Boolean;
{ Разрешает значение api_key. Имя переменной окружения задаётся только с
  префиксом «&»: «api_key=&MY_API_KEY» → значение переменной (на Windows —
  без учёта регистра имени). Любая другая строка, даже совпадающая с именем
  существующей переменной, считается литеральным ключом и возвращается как
  есть. Если переменная не задана или имя некорректно — строка остаётся как
  есть (литеральный ключ вместе с «&»). }
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
{ Разрешает значение api_key. Имя переменной окружения задаётся только с
  префиксом «&»: «api_key=&MY_API_KEY» → значение переменной (на Windows —
  без учёта регистра имени). Любая другая строка, даже совпадающая с именем
  существующей переменной, считается литеральным ключом и возвращается как
  есть. Если переменная не задана или имя некорректно — строка остаётся как
  есть (литеральный ключ вместе с «&»). }
function ResolveApiKey(const S: string): string;
var
  V, Name, Val: string;
  I: Integer;
begin
  V := Trim(S);
  if V = '' then
    Exit('');
  { Без префикса «&» строка — литеральный ключ, даже если совпадает с
    именем переменной окружения. }
  if V[1] <> '&' then
    Exit(V);
  Name := Trim(Copy(V, 2, MaxInt));
  if Name = '' then
    Exit(V);
  { Допустимое имя переменной окружения: начинается с буквы или
    подчёркивания, дальше — буквы, цифры, подчёркивания. }
  if not (Name[1] in ['A'..'Z', 'a'..'z', '_']) then
    Exit(V);
  for I := 2 to Length(Name) do
    if not (Name[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit(V);
  { Ищем переменную с таким именем. GetEnvironmentVariable отдаёт '' и для
    несуществующей, и для пустой переменной — в обоих случаях строка
    остаётся литеральным ключом. }
  Val := GetEnvironmentVariable(Name);
  if Val <> '' then
    Exit(Val);
  Result := V;
end;

{ Имя секции с ключами инструментов. Опечатка в самом имени секции («[tool]»
  или «[tools ]» с пробелом) раньше молча возвращала все инструменты к
  умолчаниям: пользователь писал grep=0, а grep оставался включённым. Это тот же
  класс тихой опечатки, что и неизвестный ключ, поэтому имя секции проверяется
  так же строго. Регистр не важен: TIniFile читает секции без учёта регистра,
  поэтому «[Tools]» — не ошибка. }
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
      { «[tools ]»: ключи этой секции TIniFile уже не читает, инструменты молча
        остаются с умолчаниями. }
      if (Norm = TOOLS_SECTION) and (Trim(Raw) <> Raw) then
      begin
        Err := Format('section name "[%s]" has stray spaces; write it as [%s]',
          [Raw, TOOLS_SECTION]);
        Exit(False);
      end;
      { «[tool]» — самая вероятная опечатка; любая другая секция тоже игнорируется,
        но полный запрет незнакомых секций сломал бы совместимость вперёд. }
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
    { Максимум строк вывода инструментов (0 — без ограничения). }
    C.ToolOutputLines := F.ReadInteger('agent', 'tool_output_lines', C.ToolOutputLines);

    C.ShellTimeout := F.ReadInteger('workspace', 'shell_timeout', C.ShellTimeout);
    C.ShellOutputLimit := F.ReadInteger('workspace', 'shell_output_limit', C.ShellOutputLimit);

    { Секция [tools]: один ключ на встроенный инструмент. Набор ключей задаёт
      таблица mirmid.tools; неизвестный ключ — фатальная ошибка, иначе
      опечатка молча оставила бы инструмент со значением по умолчанию. }
    Keys := TStringList.Create;
    try
      F.ReadSection(TOOLS_SECTION, Keys);
      for I := 0 to Keys.Count - 1 do
      begin
        { Имя ключа как в файле; пустые записи (ReadSection отдаёт их на
          пустых строках секции) пропускаем. }
        ToolName := Trim(Keys[I]);
        if ToolName = '' then
          Continue;
        { Дубликат ключа: TIniFile читает первое значение, а читатель файла ждёт
          последнее — расхождение могло включить инструмент вопреки явному «=0»
          ниже. Ошибка та же, что на неизвестный ключ. }
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
    { Защита от зацикливания (Loop-guard). }
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
    L.Add('# Конфигурация mirmid. Создано командой `mirmid --init`.');
    L.Add('# Файл лежит в каталоге .mirmid рабочей папки.');
    L.Add('# Значения можно переопределять переменными MIRMID_BASE_URL, MIRMID_API_KEY,');
    L.Add('# MIRMID_MODEL, MIRMID_TEMPERATURE, MIRMID_REASONING.');
    L.Add('');
    L.Add('[llm]');
    L.Add('base_url=' + C.BaseUrl);
    L.Add('# Ключ API буквально или «&ИМЯ» переменной окружения с ключом');
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
    L.Add('# Режим планирования: план → шаги → отчёт (0 — выкл, 1 — вкл).');
    L.Add('plan=' + BoolToStr(C.PlanMode, '1', '0'));
    L.Add('# Бюджет шага: предел итераций «модель→инструменты» на один шаг (0 — без ограничений).');
    L.Add('plan_step_max_steps=' + IntToStr(C.PlanStepMaxSteps));
    L.Add('# Повторы шага плана при нештатном результате с передачей причины сбоя (0 — не повторять).');
    L.Add('plan_step_fix_attempts=' + IntToStr(C.PlanStepFixAttempts));
    L.Add('# Максимум шагов в самом плане (0 — без ограничений).');
    L.Add('plan_max_step=' + IntToStr(C.PlanMaxStep));
    L.Add('system_prompt=' + C.SystemPrompt);
    L.Add('verbose=' + BoolToStr(C.Verbose, '1', '0'));
    L.Add('# Максимум строк вывода инструмента: середина сокращается строкой «…»');
    L.Add('# с отступом от начала строки (0 — без лимита).');
    L.Add('tool_output_lines=' + IntToStr(C.ToolOutputLines));
    L.Add('# Порог авто-суммаризации: % заполнения контекста (0 — выкл).');
    L.Add('summarize_threshold_percent=' + IntToStr(C.SummarizeThresholdPercent));
    L.Add('# Порог авто-суммаризации: абсолютное значение в токенах (0 — использовать процент).');
    L.Add('summarize_threshold_tokens=' + IntToStr(C.SummarizeThresholdTokens));
    L.Add('# Мин. % уменьшения контекста для эффективной суммаризации.');
    L.Add('summarize_min_saving_percent=' + IntToStr(C.SummarizeMinSavingPercent));
    L.Add('# Мин. абсолютное уменьшение в токенах (0 — использовать процент).');
    L.Add('summarize_min_saving_tokens=' + IntToStr(C.SummarizeMinSavingTokens));
    L.Add('# Loop-guard: повторы одного вызова инструмента подряд для предупреждения (0 — выкл).');
    L.Add('loop_warn=' + IntToStr(C.LoopWarn));
    L.Add('# Loop-guard: повторы одного вызова инструмента подряд для остановки хода (0 — выкл).');
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
    L.Add('# Максимум вывода shell-инструмента в байтах (0 — без ограничения).');
    L.Add('shell_output_limit=' + IntToStr(C.ShellOutputLimit));
    L.Add('');
    L.Add('[mcp]');
    L.Add('# Подключать MCP-серверы из .mirmid/mcp.json (см. config/mcp.json.example).');
    L.Add('enabled=' + BoolToStr(C.McpEnabled, '1', '0'));
    L.Add('# Путь к mcp.json; пусто — искать ./.mirmid/mcp.json.');
    L.Add('config=' + C.McpConfig);
    L.Add('# Таймаут ответа MCP-сервера, секунды.');
    L.Add('timeout=' + IntToStr(C.McpTimeout));
    if not EnsureParentDir(FileName) then
    begin
      Err := 'не удалось создать каталог для ' + FileName;
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
