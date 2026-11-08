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

{ Читает INI поверх переданных значений (отсутствующие ключи не трогает). }
procedure LoadIni(const FileName: string; var C: TMirmidConfig);
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
  SysUtils, Classes, IniFiles, mirmid.util;

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

procedure LoadIni(const FileName: string; var C: TMirmidConfig);
var
  F: TIniFile;
begin
  if not FileExists(FileName) then
    Exit;
  F := TIniFile.Create(FileName);
  try
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
    C.CaFile := Trim(F.ReadString('llm', 'ca_file', C.CaFile));
    C.SystemPrompt := F.ReadString('agent', 'system_prompt', C.SystemPrompt);
    C.MaxSteps := F.ReadInteger('agent', 'max_steps', C.MaxSteps);
    C.PlanMode := F.ReadBool('agent', 'plan', C.PlanMode);
    C.PlanStepMaxSteps := F.ReadInteger('agent', 'plan_step_max_steps', C.PlanStepMaxSteps);
    C.PlanStepFixAttempts := F.ReadInteger('agent', 'plan_step_fix_attempts', C.PlanStepFixAttempts);
    C.PlanMaxStep := F.ReadInteger('agent', 'plan_max_step', C.PlanMaxStep);
    C.Verbose := F.ReadBool('agent', 'verbose', C.Verbose);
    { Максимум строк вывода инструментов (0 — без ограничения). }
    C.ToolOutputLines := F.ReadInteger('agent', 'tool_output_lines', C.ToolOutputLines);

    C.AllowWrite := F.ReadBool('workspace', 'allow_write', C.AllowWrite);
    C.AllowShell := F.ReadBool('workspace', 'allow_shell', C.AllowShell);
    C.AllowHttp := F.ReadBool('workspace', 'allow_http', C.AllowHttp);
    C.ShellTimeout := F.ReadInteger('workspace', 'shell_timeout', C.ShellTimeout);
    C.ShellOutputLimit := F.ReadInteger('workspace', 'shell_output_limit', C.ShellOutputLimit);

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
  S := GetEnvironmentVariable('MIRMID_CA_FILE');
  if S <> '' then
    C.CaFile := Trim(S);
  S := LowerCase(Trim(GetEnvironmentVariable('MIRMID_ALLOW_HTTP')));
  if (S = '1') or (S = 'true') or (S = 'yes') or (S = 'on') then
    C.AllowHttp := True;

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
begin
  Err := '';
  Result := False;
  L := TStringList.Create;
  try
    L.Add('# Конфигурация mirmid. Создано командой `mirmid --init`.');
    L.Add('# Файл лежит в каталоге .mirmid рабочей папки.');
    L.Add('# Значения можно переопределять переменными MIRMID_BASE_URL, MIRMID_API_KEY,');
    L.Add('# MIRMID_MODEL, MIRMID_TEMPERATURE, MIRMID_REASONING, MIRMID_CA_FILE.');
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
    L.Add('# Путь к PEM-бандлу корневых сертификатов для HTTPS (необязательно).');
    L.Add('# Пусто — встроенный в программу снимок корней (tls.roots), а если его');
    L.Add('# нет — системное хранилище ОС (Windows). Автопоиска ca-bundle.pem нет.');
    L.Add('# Заданный путь должен существовать: битый или отсутствующий бандл — ошибка.');
    L.Add('ca_file=' + C.CaFile);
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
    L.Add('[workspace]');
    L.Add('allow_write=' + BoolToStr(C.AllowWrite, '1', '0'));
    L.Add('allow_shell=' + BoolToStr(C.AllowShell, '1', '0'));
    L.Add('allow_http=' + BoolToStr(C.AllowHttp, '1', '0'));
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
