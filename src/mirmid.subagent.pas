unit mirmid.subagent;
{ The subagent tool: runs a separate agent session of the model with its own
  context (its own system prompt and a clean message history) and the same tool
  set as the parent session. The final answer of the subagent is returned as
  the tool result. The subagent session is stored in the file
  <base>_sub_<n>.json (following the pattern of the main session). }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools, mirmid.types;

const
  SUBAGENT_TOOL_NAME = 'subagent';
  { Maximum subagent nesting depth (the root session is level 0). }
  MAX_SUBAGENT_DEPTH = 3;

  { The final answer of the subagent is empty: the model finished the turn
    without text. A frequent cause is an exhausted max_tokens with reasoning
    enabled, when the whole budget goes to reasoning. }
  SUBAGENT_EMPTY_ANSWER_MSG =
    'subagent finished without a final text: the model answer is empty ' +
    '(a frequent cause is an exhausted max_tokens limit with reasoning ' +
    'enabled; increase max_tokens or simplify the task)';

{ The subagent tool result derived from the final text of the session. An empty
  model answer is an error: the CLI does not print empty tool results, so
  without this the subagent result line would silently vanish from the screen. }
function SubagentOutcome(const FinalText: string): TToolOutcome;

{ Registers the subagent tool in the registry. }
procedure RegisterSubagentTool(R: TToolRegistry);

{ Full session tool set: the built-in tools, subagent and http_request.
  The set is filtered by the [tools] section: a disabled tool does not get
  into the registry. It is used both by the parent session and by subagents —
  the tools are equally available everywhere. }
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
  { Handler gate: the subagent key in the [tools] section. }
  if not ToolEnabled(Ctx.Cfg, SUBAGENT_TOOL_NAME) then
    Exit(ToolDisabled(SUBAGENT_TOOL_NAME));
  if Ctx.SubAgentDepth >= MAX_SUBAGENT_DEPTH then
    Exit(ErrResult(Format('subagent nesting depth exceeded (maximum %d)',
      [MAX_SUBAGENT_DEPTH])));

  Prompt := JStr(A, 'prompt', '');
  if Trim(Prompt) = '' then
    Exit(ErrResult('prompt is not set'));

  { Own context: its own system prompt and a clean message history. The model,
    keys, policies and limits are inherited from the parent session. }
  SubCfg := Ctx.Cfg;
  SubCfg.SystemPrompt := SUBAGENT_SYSTEM_PROMPT;
  SubBase := Ctx.SessionBase;

  { Tool set as in the parent session. If the context already has a ready
    registry (the usual case), reuse it: the MCP servers are already running
    and need not be started again. }
  SubReg := Ctx.Registry;
  OwnReg := SubReg = nil;
  if OwnReg then
  begin
    SubReg := TToolRegistry.Create;
    RegisterSessionTools(SubReg, SubCfg);
  end;

  SubAgent := TAgent.Create(SubCfg, SubReg);
  { Routing the subagent events into the parent handler: OnEvent — for the
    subagent's own events, OnSubAgentEvent — for its nested subagents
    (recursively). Without this the events were simply dropped. }
  if Assigned(Ctx.OnSubAgentEvent) then
  begin
    SubAgent.OnEvent := Ctx.OnSubAgentEvent;
    SubAgent.OnSubAgentEvent := Ctx.OnSubAgentEvent;
  end;
  try
    SubAgent.SubAgentDepth := Ctx.SubAgentDepth + 1;
    { Session file base of the subagent: <parent base>_sub_<n>. }
    if SubBase <> '' then
      SubAgent.SessionBase := SubagentSessionId(SessionDir(Ctx.Cfg.WorkDir), SubBase);
    { Rebuild the system message without AGENTS.md: the constructor ran Reset
      at depth 0. }
    SubAgent.Reset;
    SubAgent.AddUser(Prompt);
    if SubAgent.RunTurn(FinalText, Err) then
      Result := SubagentOutcome(FinalText)
    else
      Result := ErrResult(Err);
    { Session log of the subagent (same pattern as the main session). }
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
    'Runs a separate agent session with its own context and the same tool set. Returns the final answer of the subagent.',
    SchemaObject(
      TJSONObject.Create(['prompt', PropStr('Task for the subagent')]),
      ['prompt']),
    @ToolSubagent);
end;

procedure RegisterSessionTools(R: TToolRegistry; const Cfg: TMirmidConfig);
begin
  { The set is filtered by the [tools] section: a disabled tool is not
    registered and therefore never reaches the model in the tools array. The
    handlers additionally check their own key (ToolDisabled) — subagents, plan
    steps and MCP build their own views of the registry. }
  R.ApplyToolSwitches(Cfg);
  RegisterBuiltinTools(R);
  RegisterMediaTool(R);
  RegisterScreenTools(R);
  RegisterGuiTools(R);
  RegisterSubagentTool(R);
  RegisterHttpTool(R);
end;

end.
