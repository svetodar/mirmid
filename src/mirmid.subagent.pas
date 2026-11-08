unit mirmid.subagent;
{ Инструмент subagent: запускает отдельную агентскую сессию модели со своим
  контекстом (своя системная подсказка и чистая история сообщений) и тем же
  набором инструментов, что у родительской сессии. Финальный ответ субагента
  возвращается как результат инструмента. Сессия субагента сохраняется в файл
  <база>_sub_<n>.json (по аналогии с основной сессией). }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools, mirmid.types;

const
  SUBAGENT_TOOL_NAME = 'subagent';
  { Максимальная глубина вложенности субагентов (корневая сессия — уровень 0). }
  MAX_SUBAGENT_DEPTH = 3;

  { Финальный ответ субагента пуст: модель завершила ход без текста. Частая
    причина — исчерпанный max_tokens при включённом режиме рассуждений, когда
    весь бюджет уходит на reasoning. }
  SUBAGENT_EMPTY_ANSWER_MSG =
    'субагент завершил работу без финального текста: ответ модели пуст ' +
    '(частая причина — исчерпан лимит max_tokens при включённом режиме ' +
    'рассуждений; увеличьте max_tokens или упростите задание)';

{ Результат инструмента subagent по финальному тексту сессии. Пустой ответ
  модели — ошибка: CLI не печатает пустые результаты инструментов, поэтому без
  этого строка результата субагента молча пропадала бы на экране. }
function SubagentOutcome(const FinalText: string): TToolOutcome;

{ Регистрирует инструмент subagent в реестре. }
procedure RegisterSubagentTool(R: TToolRegistry);

{ Полный набор инструментов сессии: встроенные инструменты, subagent и
  http_request. Набор фильтруется секцией [tools]: выключенный инструмент в
  реестр не попадает. Используется и родительской сессией, и субагентами —
  доступность инструментов одинаковая. }
procedure RegisterSessionTools(R: TToolRegistry; const Cfg: TMirmidConfig);

implementation

uses
  SysUtils, fpjson, mirmid.agent, mirmid.json, mirmid.session,
  mirmid.toolbuiltin, mirmid.httprequest, mirmid.media, mirmid.screen, mirmid.gui;

function SubagentOutcome(const FinalText: string): TToolOutcome;
begin
  if Trim(FinalText) = '' then
    Result := ErrResult(SUBAGENT_EMPTY_ANSWER_MSG)
  else
    Result := OkResult(Trim(FinalText));
end;
function ToolSubagent(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Prompt: string;
  SubCfg: TMirmidConfig;
  SubReg: TToolRegistry;
  OwnReg: Boolean;
  SubAgent: TAgent;
  FinalText, Err: string;
  SubBase, SaveErr: string;
begin
  { Гейт в обработчике: ключ subagent в секции [tools]. }
  if not ToolEnabled(Ctx.Cfg, SUBAGENT_TOOL_NAME) then
    Exit(ToolDisabled(SUBAGENT_TOOL_NAME));
  if Ctx.SubAgentDepth >= MAX_SUBAGENT_DEPTH then
    Exit(ErrResult(Format('превышена глубина вложенности субагентов (максимум %d)',
      [MAX_SUBAGENT_DEPTH])));

  Prompt := JStr(A, 'prompt', '');
  if Trim(Prompt) = '' then
    Exit(ErrResult('не задан prompt'));

  { Свой контекст: своя системная подсказка и чистая история сообщений.
    Модель, ключи, политики и лимиты наследуются от родительской сессии. }
  SubCfg := Ctx.Cfg;
  SubCfg.SystemPrompt := SUBAGENT_SYSTEM_PROMPT;
  SubBase := Ctx.SessionBase;

  { Набор инструментов — как у родительской сессии. Если у контекста есть
    готовый реестр (обычный случай), переиспользуем его: MCP-серверы уже
    запущены, повторно их поднимать не нужно. }
  SubReg := Ctx.Registry;
  OwnReg := SubReg = nil;
  if OwnReg then
  begin
    SubReg := TToolRegistry.Create;
    RegisterSessionTools(SubReg, SubCfg);
  end;

  SubAgent := TAgent.Create(SubCfg, SubReg);
  { Маршрутизация событий субагента в обработчик родителя: OnEvent — для
    собственных событий субагента, OnSubAgentEvent — для его вложенных
    субагентов (рекурсивно). Без этого события просто отбрасывались. }
  if Assigned(Ctx.OnSubAgentEvent) then
  begin
    SubAgent.OnEvent := Ctx.OnSubAgentEvent;
    SubAgent.OnSubAgentEvent := Ctx.OnSubAgentEvent;
  end;
  try
    SubAgent.SubAgentDepth := Ctx.SubAgentDepth + 1;
    { База имени файла сессии субагента: <база родителя>_sub_<n>. }
    if SubBase <> '' then
      SubAgent.SessionBase := SubagentSessionId(SessionDir(Ctx.Cfg.WorkDir), SubBase);
    { Пересобираем системное сообщение без AGENTS.md: в конструкторе Reset
      выполнялся при глубине 0. }
    SubAgent.Reset;
    SubAgent.AddUser(Prompt);
    if SubAgent.RunTurn(FinalText, Err) then
      Result := SubagentOutcome(FinalText)
    else
      Result := ErrResult(Err);
    { Лог сессии субагента (по аналогии с основной сессией). }
    if SubAgent.SessionBase <> '' then
      SaveSession(SessionDir(Ctx.Cfg.WorkDir), SubAgent.SessionBase,
        Ctx.Cfg.Model, SubAgent.Messages, nil, SaveErr);
  finally
    SubAgent.Free;
    if OwnReg then
      SubReg.Free;
  end;
end;

procedure RegisterSubagentTool(R: TToolRegistry);
begin
  R.Add(SUBAGENT_TOOL_NAME,
    'Запускает отдельную агентскую сессию со своим контекстом и тем же набором инструментов. Возвращает финальный ответ субагента.',
    SchemaObject(
      TJSONObject.Create(['prompt', PropStr('Задание для субагента')]),
      ['prompt']),
    @ToolSubagent);
end;

procedure RegisterSessionTools(R: TToolRegistry; const Cfg: TMirmidConfig);
begin
  { Набор фильтруется секцией [tools]: выключенный инструмент не регистрируется
    и потому не уходит модели в массиве tools. Обработчики дополнительно
    проверяют свой ключ (ToolDisabled) — субагенты, шаги плана и MCP собирают
    собственные представления реестра. }
  R.ApplyToolSwitches(Cfg);
  RegisterBuiltinTools(R);
  RegisterMediaTool(R);
  RegisterScreenTools(R);
  RegisterGuiTools(R);
  RegisterSubagentTool(R);
  RegisterHttpTool(R);
end;

end.
