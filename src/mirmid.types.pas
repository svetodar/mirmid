unit mirmid.types;
{ Shared harness types: dialogue messages and run settings.
  The unit deliberately does not depend on fpjson or networking so that every
  other unit can use it. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { Message role in the dialogue. }
  TMessageRole = (mrSystem, mrUser, mrAssistant, mrTool);

  { One tool call requested by the model. Arguments is the raw JSON string. }
  TToolCall = record
    Id: string;
    Name: string;
    Arguments: string;
  end;

  { Message in the OpenAI Chat Completions format. }
  TMessage = record
    Role: TMessageRole;
    Content: string;
    Reasoning: string;          { reasoning_content of reasoning models }
    ToolCalls: array of TToolCall;
    ToolCallId: string;         { mrTool only }
    Name: string;               { tool name for mrTool }
  end;

  TMessages = array of TMessage;

  { Agent event kind (for UI handlers).
    aeContext - before every model request: Text is the estimated size of the
    request context in tokens (for a subagent - over its own history and
    system prompt).
    aeSubSessionStart/aeSubSessionEnd - entering/leaving a planner sub-session
    (preliminary analysis, plan step): Text is the sub-session label
    ("analysis", "step s1"). Unlike the aeToolCall/aeToolResult pair of the
    subagent tool, nesting and status counters are driven by this label, not
    by the tool name. }
  TAgentEventKind = (aeStep, aeAssistant, aeReasoning, aeToolCall, aeShellCommand,
    aeToolResult, aeError, aeUsage, aeStreamStart, aeStreamText,
    aeStreamReasoning, aeStreamEnd, aePlan, aeStepStart, aeStepEnd, aeReport,
    aeAnalysis, aeLoopWarning, aeContext, aeSubSessionStart, aeSubSessionEnd);
  { Agent event handler. }
  TAgentEvent = procedure(Kind: TAgentEventKind; const Text: string) of object;

  { Switch of one built-in tool from the [tools] INI section: the key name and
    its value. The tool set and the default values come from the table in
    mirmid.tools; only what was read from the configuration is stored here.
    An empty array means no key was set and every tool works with its default
    value. }
  TToolSwitch = record
    Name: string;
    Enabled: Boolean;
  end;

  TToolSwitches = array of TToolSwitch;

  { Settings of one harness run. }
  TMirmidConfig = record
    BaseUrl: string;            { base URL of the OpenAI-compatible API, no trailing slash }
    ApiKey: string;             { effective key ("&NAME" references already expanded) }
    ApiKeyRaw: string;          { raw api_key value before resolution ("&NAME" kept);
                                  empty - not set }
    Model: string;
    SystemPrompt: string;
    Temperature: Double;
    MaxTokens: Integer;
    MaxSteps: Integer;          { limit of "model->tools" iterations per turn; 0 - unlimited }
    PlanMode: Boolean;          { planning mode: plan -> steps -> report }
    PlanStepMaxSteps: Integer;  { step budget: limit of "model->tools" iterations per step; 0 - unlimited }
    PlanStepFixAttempts: Integer; { how many times to repeat a plan step after an
                                    abnormal result (error/empty answer) passing the
                                    failure cause into the prompt; 0 - do not repeat }
    PlanMaxStep: Integer;       { maximum number of steps in the plan itself; 0 - unlimited }
    RequestTimeout: Integer;    { ms; overall HTTP request timeout }
    ConnectTimeout: Integer;    { ms }
    Tools: TToolSwitches;       { built-in tool switches from the
                                  [tools] section; empty - default values
                                  (table in mirmid.tools) }
    ShellTimeout: Integer;      { sec; 0 - no limit }
    ShellOutputLimit: Integer;  { bytes; maximum output of the shell tool; 0 - no limit }
    WorkDir: string;            { working directory of the tools }
    Verbose: Boolean;
    Stream: Boolean;            { streamed (SSE) output of the model answer }
    ContextWindow: Integer;     { maximum model context size in tokens (from settings) }
    HostContextWindow: Integer; { context reported by the host (LLM server); 0 - not set }
    Reasoning: string;          { reasoning_effort: none|minimal|low|medium|high;
                                  empty string - the parameter is not sent }
    McpEnabled: Boolean;        { whether to connect MCP servers from mcp.json }
    McpConfig: string;          { path to mcp.json; empty - use the default lookup }
    McpTimeout: Integer;        { sec; MCP server answer timeout }
    ToolOutputLines: Integer;   { lines; maximum number of tool output lines on screen;
                                  above the limit the middle is cut with a "..." line
                                  indented from the start of the line; 0 - no limit }
    { Session summarisation. }
    SummarizeThresholdPercent: Integer;  { % of context fill for auto-summarisation (0 - off) }
    SummarizeThresholdTokens: Integer;   { absolute threshold in tokens (0 - use the percentage) }
    SummarizeMinSavingPercent: Integer;  { min. % of context reduction for effective summarisation }
    SummarizeMinSavingTokens: Integer;   { min. absolute reduction in tokens (0 - use the percentage) }
    { Loop-guard. }
    LoopWarn: Integer;                  { repetition threshold of one tool call for a warning; 0 - off }
    LoopStop: Integer;                  { repetition threshold of one tool call for a stop; 0 - off }
  end;

const
  { Maximum model context size in tokens when it is not set explicitly. }
  DEFAULT_CONTEXT_WINDOW = 128000;

  { Default MCP server answer timeout, seconds. }
  DEFAULT_MCP_TIMEOUT = 60;

  { How many tool output lines to show when it is not set explicitly.
    Above the limit the middle of the output is cut with an ellipsis line. }
  DEFAULT_TOOL_OUTPUT_LINES = 9;

  DEFAULT_SYSTEM_PROMPT =
    'You are mirmid, a careful AI agent on the user''s local machine. ' +
    'Reply in the same language the user writes in, briefly and to the point. ' +
    'Use the provided tools to work with files and commands. ' +
    'Read first, then change. Do not invent file contents.';

  { Subagent system prompt: a separate session performs the task of the parent
    and returns only the result of the work. }
  SUBAGENT_SYSTEM_PROMPT =
    'You are a subagent: a separate agent session started by the parent ' +
    'agent to perform one specific task. Perform the task with the ' +
    'available tools and return only the result of the work in the final answer: ' +
    'briefly, to the point, without describing the process. Reply in the ' +
    'same language as the task.';

{ Default values. }
function DefaultConfig: TMirmidConfig;
{ Canonicalises the reasoning mode: none|minimal|low|medium|high.
  Synonyms: on/true/yes -> medium, off/false/no -> none. An empty string and
  unrecognised values give '' (mode not set). }
function NormalizeReasoning(const S: string): string;
{ Role name in OpenAI notation. }
function RoleName(R: TMessageRole): string;
{ Message constructor with a role and content. }
function MakeMessage(R: TMessageRole; const AContent: string): TMessage;
{ Effective context size: the minimum of the value from the settings and the
  value reported by the host (LLM server). If the host reported nothing (0),
  only the value from the settings is used. }
function EffectiveContextWindow(const Cfg: TMirmidConfig): Integer;
{ Auto-summarisation threshold in tokens: if an absolute value is set
  (SummarizeThresholdTokens > 0) it is used, otherwise the percentage of the
  effective context. 0 - auto-summarisation is disabled. }
function SummarizeThreshold(const Cfg: TMirmidConfig): Integer;
{ Minimum context reduction (in tokens) for an effective summarisation:
  if an absolute value is set (SummarizeMinSavingTokens > 0) it is used,
  otherwise the percentage of the effective context. }
function SummarizeMinSaving(const Cfg: TMirmidConfig): Integer;

implementation

function DefaultConfig: TMirmidConfig;
begin
  Result.BaseUrl        := 'http://127.0.0.1:1234/v1';
  Result.ApiKey         := '';
  Result.ApiKeyRaw      := '';
  Result.Model          := '';
  Result.SystemPrompt   := DEFAULT_SYSTEM_PROMPT;
  Result.Temperature    := 0.1;
  Result.MaxTokens      := 32768;
  Result.MaxSteps        := 0;
  Result.PlanMode        := False;
  Result.PlanStepMaxSteps := 0;
  Result.PlanMaxStep := 0;
  Result.PlanStepFixAttempts := 1;  { repeat a step once after a failure }
  Result.RequestTimeout := 1800000;
  Result.ConnectTimeout := 10000;
  { No [tools] switches by default: the values come from the
    mirmid.tools table (ToolEnabledByDefault), so DefaultConfig does not depend
    on the tool registry unit. }
  SetLength(Result.Tools, 0);
  Result.ShellTimeout   := 60;
  Result.ShellOutputLimit := 65536;
  Result.ToolOutputLines := DEFAULT_TOOL_OUTPUT_LINES;
  Result.WorkDir        := '';
  Result.Verbose        := False;
  Result.Stream         := True;
  Result.ContextWindow  := DEFAULT_CONTEXT_WINDOW;
  Result.HostContextWindow := 0;
  Result.Reasoning      := '';
  Result.McpEnabled     := True;
  Result.McpConfig      := '';
  Result.McpTimeout     := DEFAULT_MCP_TIMEOUT;
  Result.SummarizeThresholdPercent := 90;
  Result.SummarizeThresholdTokens  := 0;
  Result.SummarizeMinSavingPercent := 50;
  Result.SummarizeMinSavingTokens  := 0;
  Result.LoopWarn        := 3;
  Result.LoopStop        := 5;
end;

function NormalizeReasoning(const S: string): string;
var
  V: string;
begin
  V := LowerCase(Trim(S));
  case V of
    'none', 'off', 'false', 'no', '0':           Result := 'none';
    'minimal', 'min':                            Result := 'minimal';
    'low':                                       Result := 'low';
    'medium', 'med', 'on', 'true', 'yes', '1':  Result := 'medium';
    'high':                                      Result := 'high';
  else
    Result := '';
  end;
end;

function RoleName(R: TMessageRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  else
    Result := 'user';
  end;
end;

function MakeMessage(R: TMessageRole; const AContent: string): TMessage;
begin
  Result.Role       := R;
  Result.Content    := AContent;
  Result.Reasoning  := '';
  Result.ToolCallId := '';
  Result.Name       := '';
  SetLength(Result.ToolCalls, 0);
end;

function EffectiveContextWindow(const Cfg: TMirmidConfig): Integer;
begin
  if (Cfg.HostContextWindow > 0) and (Cfg.HostContextWindow < Cfg.ContextWindow) then
    Result := Cfg.HostContextWindow
  else
    Result := Cfg.ContextWindow;
end;

function SummarizeThreshold(const Cfg: TMirmidConfig): Integer;
begin
  if Cfg.SummarizeThresholdTokens > 0 then
    Result := Cfg.SummarizeThresholdTokens
  else if Cfg.SummarizeThresholdPercent > 0 then
    Result := (EffectiveContextWindow(Cfg) * Cfg.SummarizeThresholdPercent + 99) div 100
  else
    Result := 0;
end;

function SummarizeMinSaving(const Cfg: TMirmidConfig): Integer;
begin
  if Cfg.SummarizeMinSavingTokens > 0 then
    Result := Cfg.SummarizeMinSavingTokens
  else if Cfg.SummarizeMinSavingPercent > 0 then
    Result := (EffectiveContextWindow(Cfg) * Cfg.SummarizeMinSavingPercent + 99) div 100
  else
    Result := 0;
end;

initialization
  { Force UTF-8 as the system code page: otherwise non-ASCII text is lost in
    conversions from UTF8String/TJSONStringType. }
  DefaultSystemCodePage := CP_UTF8;

end.
