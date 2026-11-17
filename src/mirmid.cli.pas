unit mirmid.cli;
{ Command line, settings resolution and the interactive REPL. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.types;

{ Entry point. Returns the exit code (0 — success, 1 — error, 2 — usage). }
function Main: Integer;

type
  { The parsed command line. }
  TCli = record
    ConfigFile, WorkDir, Prompt, PromptFile: string;
    Model, BaseUrl, ApiKey, SystemPrompt, SessionId: string;
    Reasoning: string;
    Temperature: Double;
    HasTemperature: Boolean;
    MaxSteps, MaxTokens, Timeout, ConnectTimeout, ShellTimeout, ShellOutputLimit: Integer;
    HasMaxSteps, HasMaxTokens, HasTimeout, HasConnectTimeout, HasShellTimeout, HasShellOutputLimit: Boolean;
    LoopWarn, LoopStop: Integer;
    HasLoopWarn, HasLoopStop: Boolean;
    HasReasoning: Boolean;
    McpConfig: string;
    HasMcpConfig, NoMcp, ListMcp: Boolean;
    McpTimeout: Integer;
    HasMcpTimeout: Boolean;
    { Tool output line limit (0 — no limit). }
    ToolOutputLines: Integer;
    HasToolOutputLines: Boolean;
    Verbose, ShowReasoning, ShowStepResult, ShowStepTask, NoSession: Boolean;
    Stream, HasStream: Boolean;
    PlanMode, HasPlanMode: Boolean;
    Interactive, DoInit, ListModels, ListSessions: Boolean;
    ShowHelp, ShowVersion: Boolean;
    BaseUrlSet, ApiKeySet: Boolean;
  end;

{ Parses the command line. Args are the arguments (without the program name). }
function ParseCli(const Args: array of string; out Cli: TCli; out Err: string): Boolean;
{ Resolves the final configuration from the command line, the INI and the
  environment. Returns False and the reason text in Err when the configuration is
  unusable (for example an unknown key in the [tools] section): the session is
  not started then. }
function ResolveConfig(const Cli: TCli; var Cfg: TMirmidConfig;
  var WorkDir: string; out Err: string): Boolean;
{ The help text (--help): the same that Main prints. Exported for the command
  line contract tests. }
function UsageText: string;
{ Formats the text of the aeStepEnd event "s1: done — result" for display: only
  the result is shortened (to TOOL_RESULT_MAX), the header is kept. Without the
  " — " separator it returns the text as it is. }
function FormatStepEnd(const Text: string): string;
{ The step status without the result: the part of the aeStepEnd event text up to
  the " — " separator (for example "s1: done"). The step result is printed
  separately and only under --show-step-result / --show-reasoning. }
function FormatStepEndStatus(const Text: string): string;
{ The one-line step summary printed when the step result is hidden: the step
  status plus the first non-empty line of the result, shortened to
  STEP_BRIEF_MAX visible columns on a single line. }
function FormatStepEndBrief(const Text: string): string;
{ The depth prefix: the grey │ character repeated Depth times (0 — empty). }
function DepthPrefix(Depth: Integer): string;
{ The context status line: "[HH:MM:SS|current/total|percent%]".
  WithTime = False — no time (the second part of the subagent status line). }
function FormatContextStatus(const Cur, Total: Integer;
  WithTime: Boolean = True): string;
{ The status line in sub-session mode: the status of the main session + the label
  ("subagent" by default) + the status of the sub-session. The time is printed
  only in the first part (one clock per line), the sub-session part has no time. }
function FormatSubAgentStatus(const MainCur, SubCur, Total: Integer;
  const LabelText: string = 'subagent'): string;
{ The plan step line: "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%] name".
  The counters go from the main session (MainCur) to the step sub-session (Cur)
  and the common model window (Total), the percentages are counted from Total for
  every counter separately. MainCur is 0 by default — the parent context has not
  been measured yet (the caller passes it when it is there). The status comes
  first, the step name after it; there is no [step] tag on the line. The │ prefix
  is not needed for a step sub-session (the print depth of a step is zero). }
function FormatStepStatus(const Name: string; Cur, Total: Integer;
  MainCur: Integer = 0): string;
{ The line of the preliminary plan analysis: "[HH:MM:SS|main/sub/total|
  main-percent%/sub-percent%] analysis" — the same order as in the step line
  (FormatStepStatus): first the status with the context of the main session and
  of the analysis sub-session, then the "analysis" label. }
function FormatAnalysisStatus(const Cur, Total: Integer;
  MainCur: Integer = 0): string;
{ The short step name for the final status line: only the identifier "s1" is
  taken from "s1: description". After the step finishes the description is no
  longer needed, the line looks like "[…] s1 done". Without a colon the
  name is returned as it is. }
function StepShortName(const Name: string): string;
{ Whether to print the text of a plan step sub-session (and the step result in
  aeStepEnd): by default a step gives only the status line, the text is visible
  under --show-step-result or --show-reasoning. }
{ Whether to print the plan step task (the step name in aeStepStart, without a
  tag): by default the task is not visible, it is enabled by --show-step-task or
  --show-reasoning (with both off it is not printed). --show-step-result
  (ShowStepResult) does not apply to the task: it is about the answer text and
  the step result (StepTextVisible); the parameter is kept for a uniform call
  signature and for trying all flag combinations in the tests. }
function StepTaskVisible(ShowStepTask, ShowReasoning,
  ShowStepResult: Boolean): Boolean;
{ The decision on the tool output: tool calls (aeToolCall), shell
  commands (aeShellCommand) and their results (aeToolResult) are printed in any
  session — the main one, the subagent and the planner sub-sessions ("analysis",
  "step sN") — only together with the reasoning (--show-reasoning), that is as
  other intermediate text. Only printing is gated: FToolStack.Add/pop,
  FSubAgentDepth/FPrintDepth, the token accounting and the status line redraw
  (ClearLine/DrawStatus, PrepareStaticOverStatus) always run, otherwise the
  context accounting would drift apart and the subagent result would no longer be
  recognized. }
function StepTextVisible(ShowStepResult, ShowReasoning: Boolean): Boolean;
{ Whether to print the one-line step summary (FormatStepEndBrief) instead of the
  full step result in aeStepEnd: the summary replaces the bare status line when
  the step text is hidden, that is when StepTextVisible is False
  (--show-step-result and --show-reasoning are both off). With the text visible
  the full FormatStepEnd is printed instead. }
function StepBriefVisible(ShowStepResult, ShowReasoning: Boolean): Boolean;
{ Whether to print the tool output (the aeToolCall call, the aeShellCommand shell
  command and the aeToolResult result) — only together with the reasoning: the
  result equals ShowReasoning (--show-reasoning). The session (main, subagent,
  step or analysis) plays no role: without the flag the intermediate tool output
  is hidden everywhere, only the status lines and the final text remain. }
function ToolOutputVisible(ShowReasoning: Boolean): Boolean;

type
{ Token accounting for the status line. The base is the context size estimate the
  agent sends with the `aeContext` event: before the first request of the turn,
  right after the answer is added to the history and after the tool results are
  added (for a subagent — over its own history and system prompt), so the base
  does not lag behind the actual context. Between the events the tokens of the
  current answer, counted from the stream deltas, are added to the base. The main
  session and the subagent are tracked separately: the subagent events arrive in
  the same handler as the parent events. }
TContextTokens = class
private
  FMainBase: Integer;    { the main session context at the request time }
  FMainAccum: Integer;   { the tokens of the current main session answer }
  FSubBase: Integer;     { the sub-session context at its request time }
  FSubAccum: Integer;    { the tokens of the current sub-session answer }
  { Saved counters of the parent sub-sessions: "plan step → subagent" nest into
    each other, and leaving the inner one must not lose the context size of the
    outer one (otherwise the step would show 0 after the subagent). }
  FSavedBase: array of Integer;
  FSavedAccum: array of Integer;
public
  constructor Create;
  { A new base (the aeContext event): the size of the current context — before
    the first request of the turn, after the answer and the tool results are
    added. Depth > 0 — a sub-session event. What was accumulated for the answer
    is zeroed: the base already includes the messages just added to the
    history. }
  procedure SetBase(Depth, Tokens: Integer);
  { The tokens of the arrived answer (or reasoning) portion. }
  procedure AddResponseTokens(Depth, Tokens: Integer);
  { Entering a sub-session (a subagent or a plan step): the current counters are
    saved in the stack and the new ones start from zero so that the status does
    not show the values of the previous sub-session. }
  procedure EnterSubAgent;
  { Leaving a sub-session: restores the counters of the parent sub-session (for
    example a step the subagent worked inside); with an empty stack it just
    zeroes them. The stack keeps the values of the inner session from leaking out
    and the data of the outer one from being lost. }
  procedure ExitSubSession;
  { The number of saved counter pairs (the stack depth): OnAgentEvent remembers
    the state at the entry into a planner sub-session by it. }
  function SavedCount: Integer;
  { Unwinds the stack to the state at the entry into the sub-session
    (Level = SavedCount taken before EnterSubAgent): removes the session's own
    pair and the extra pairs of unclosed nested sub-sessions (for example a
    subagent whose aeToolResult never arrived because of an exception). A Level
    outside the stack — a full reset. }
  procedure UnwindTo(Level: Integer);
  { A full reset of the sub-session counters and the stack: leaving an outer
    sub-session (step/analysis), including after a failed step or revise_plan,
    must not leave values for the next step or the main session. }
  procedure ResetSubSession;
  { The status line: Depth > 0 — the main session + the label ("subagent" by
    default; the planner passes "step s1", "analysis") + the sub-session. }
  function Text(Total, Depth: Integer;
    const LabelText: string = 'subagent'): string;
  { The tokens of the current sub-session (base + what was accumulated for the
    answer) — for the plan step line, which prints only the step counters,
    without the main session. }
  function SubTokens: Integer;
  { The tokens of the main session (the base from its aeContext plus what was
    accumulated for the current answer). Needed by the step/analysis line: it
    prints the parent context and the sub-session counters at the same time
    (main/sub/total format). When there was no main session in this pass (a
    headless planner without history), the value stays what managed to arrive from
    aeContext — 0 without the event. }
  function MainTokens: Integer;
end;

{ Streaming output of the model text to the terminal: line by line (code blocks —
  as a group, tables — with column alignment as they fill up). The context status
  is printed on a separate line under the current text and is redrawn on every
  portion. A partial line is redrawn in place while its render is not wider than
  the terminal; when it does not fit, it is fixed as a complete line (a wrapped
  line cannot be redrawn in place). Outside a terminal the status is not printed,
  the clearing/redraw is disabled: the text is written incrementally. }
TStreamPrinter = class
private
  FActive: Boolean;
  FLive: Boolean;          { ANSI terminal: the line can be cleared/redrawn }
  FStatusShown: Boolean;   { the status is currently printed on its line under the text }
  FPending: string;        { the text of the current line without a line break }
  FReasoningMode: Boolean; { render mode of the current line: reasoning/content }
  FInCodeBlock: Boolean;   { inside a fenced code block ``` / ~~~ }
  FGroupBuf: string;       { buffer of the code block line group }
  FInTable: Boolean;       { inside a markdown table }
  FTableBuf: string;       { buffer of the table lines }
  FTableOnScreen: Integer; { table lines currently drawn on the screen }
  FTableWide: Boolean;     { the table is wider than the terminal: alignment dropped }
  FTableRawPrinted: Integer; { buffer lines printed in the "raw" mode }
  FPendingOnScreen: Boolean; { the partial text is visible on the line above the status }
  FPrefix: string;           { prefix for every printed line (depth indent) }
  { Separator between output blocks: the requested blank line is
    printed lazily — at the start of the next block (PrepareStatic/PersistStatus),
    after the status line is erased. Otherwise the status line would take its
    place, and after the status is erased no separator would remain on the
    screen. }
  FBlankPending: Boolean;    { a blank line before the next block was requested }
  FBlankSeparated: Boolean;  { the last PrepareStatic/PersistStatus printed it }
  procedure EmitPendingBlank;
  procedure ClearLine;
  procedure ClearAbove;
  procedure PrintStatus(const Status: string);
  function RenderLine(const L: string): string;
  { The visible width of the rendered line (for word wrapping). }
  function MeasureRendered(const S: string): Integer;
  { The width available to the text on a line: the terminal width minus the
    visible width of the depth prefix. Wrapping and clearing a line rely on the
    printed line (prefix + text) taking exactly one terminal line; without
    subtracting the prefix a partial subagent line overflowed the line, wrapped
    onto a second one, and the redraw lost or duplicated words. }
  function ContentWidth: Integer;
  { Break permission: not inside inline markup. }
  function BreakSafe(const Pfx: string): Boolean;
  function PendingText: string;
  procedure EmitCompleteLine(const L: string);
  procedure ShowPartial;
  procedure EmitGroup(const G: string);
  procedure FlushCodeBlock;
  procedure ShowTable;
  procedure FlushTable;
  procedure ProcessContentLine(const L: string; var Emitted: Boolean);
  procedure FeedRaw(const Delta: string);
  { Prepends FPrefix to every line (including a multi-line string). }
  function ApplyPrefix(const S: string): string;
public
  constructor Create;
  destructor Destroy; override;
  property Active: Boolean read FActive;
  property Live: Boolean read FLive write FLive;
  { The prefix added to the beginning of every printed line. }
  property Prefix: string read FPrefix write FPrefix;
  { Start of the stream: a new line and the status. }
  procedure BeginStream(const Status: string);
  { A portion of the reasoning / model answer text. }
  procedure FeedReasoning(const Delta, Status: string);
  procedure FeedContent(const Delta, Status: string);
  { End of the stream: print out the unfinished line/code block, then erase the
    temporary status line so that the next output (the REPL prompt, static text)
    starts at the beginning of a line instead of sticking to it. }
  procedure EndStream(const Status: string);
  { Preparation for static printing (tools, errors, the prompt): moves the
    cursor to a new line under the status when needed. }
  procedure PrepareStatic;
  { The same, but the drawn status line is not fixed in the scrollback: the
    remains of the stream are printed out, the status is erased, and the static
    line (a tool result) is printed in its place. The caller then draws the
    status again under it (DrawStatus) — the old variant with smaller counters
    does not stay a line above. Outside an ANSI terminal there is no status, the
    behaviour is the same as in PrepareStatic. }
  procedure PrepareStaticOverStatus;
  { Request a blank separator line before the next output block: a
    tool result is separated from the next block of information. It is printed
    lazily and once — at the start of the next block
    (PrepareStatic/PersistStatus), already after the status line is erased:
    otherwise the status would take its place, and after the status is erased no
    blank line would remain on the screen. }
  procedure RequestBlankLine;
  { Did the last PrepareStatic/PersistStatus print a blank line because of
    RequestBlankLine. Needed by the callers that print a blank line themselves
    before their block (aeAssistant, aeReport): the second one would be
    superfluous. }
  property BlankSeparated: Boolean read FBlankSeparated;
  { Finishing the status line (a finished planner sub-session): the status line
    is fully temporary and never reaches the log — it is erased instead of being
    printed into the scrollback. Silent outside a terminal (the status is not
    printed there at all). }
  procedure FreezeStatus(const Status: string);
  { Redraw the status line without printing any text: a portion of the answer
    (for example reasoning) is accounted in the counters, but its text is hidden
    by the setting. Silent outside a terminal (the status is not printed there). }
  procedure RefreshStatus(const Status: string);
  { Draw the status line again without printing any text: clears the current
    line and prints the status. Unlike RefreshStatus it does not require an
    active stream (FActive) — it is called after static printing too (a tool call
    line, a shell command) so that the status line does not disappear from under
    the output. Silent outside an ANSI terminal: ClearLine/PrintStatus do not
    work there. }
  procedure DrawStatus(const Status: string);
  { Fix the status line in the log (end of a turn): the drawn temporary line is
    replaced with the final text and terminated with a line break, so the status
    stays on the screen and the next output (the REPL prompt, static lines) goes
    under it from a clean line. Silent outside an ANSI terminal: there is no
    status line there at all (in non-streaming mode the main status is printed by
    TMirmidApp.PrintContextStatus, the done line of a sub-session — by
    TMirmidApp.PersistDoneStatus). }
  procedure PersistStatus(const Status: string);
end;

implementation

uses
  SysUtils, Classes,
  mirmid.util, mirmid.config, mirmid.tools, mirmid.subagent,
  mirmid.llm, mirmid.agent, mirmid.session, mirmid.plan, mirmid.planner, mirmid.version,
  mirmid.markdown, mirmid.mcp, mirmid.summarize, mirmid.http,
  mirmid.tlsclient;

type
  { The entry mark of a planner sub-session (analysis, plan step). On exit the
    depth, the label and the counter stack are restored from it, and everything
    accumulated inside (an unclosed subagent included) is dropped. }
  TSubSessionMark = record
    Depth: Integer;       { FSubAgentDepth before the entry }
    PrintDepth: Integer;  { FPrintDepth before the entry }
    LabelText: string;    { the label of the parent sub-session }
    Saved: Integer;       { FTokens.SavedCount before the entry }
  end;

  TMirmidApp = class
  private
    FCfg: TMirmidConfig;
    FReg: TToolRegistry;
    FAgent: TAgent;
    FSessionId: string;
    FNoSession: Boolean;
    FShowReasoning: Boolean;
    FShowStepTask: Boolean;       { print the plan step task before its work
                                    (--show-step-task) }
    FShowStepResult: Boolean;     { print the plan step text/result
                                    (--show-step-result) }
    FPrinter: TStreamPrinter;
    FToolStack: TStringList;      { stack of tool names: push on
                                    aeToolCall/aeShellCommand, pop on
                                    aeToolResult. It allows recognizing the
                                    subagent result even when the subagent itself
                                    called tools — its events go through the same
                                    handler. }
    FMcp: TMCPManager;            { connected MCP servers (may be nil) }
    FPlanner: TPlanner;           { the planner (planning mode, may be nil) }
    FSubAgentDepth: Integer;      { token accounting depth: it grows both on the
                                    subagent tool and on a planner sub-session
                                    (analysis, plan step) }
    FPrintDepth: Integer;         { the depth of the │ print prefix: it grows only
                                    on the subagent tool, so planner sub-sessions
                                    go without an indent, and a subagent inside a
                                    step — with one │ }
    FSubAgentLabel: string;       { the label of the current planner sub-session
                                    ("analysis", "step s1"); empty — "subagent" }
    FCurrentStepName: string;     { the name of the current plan step — the text
                                    of aeStepStart ("s1: update README"); empty —
                                    outside a step. Needed by the step status line
                                    (FormatStepStatus): aeSubSessionStart carries
                                    only "step s1". }
    { The entry marks of planner sub-sessions: on exit, including on an exception
      (a failed step) or revise_plan, the depth, the label and the counters return
      to the state at the entry. }
    FSubSessionMarks: array of TSubSessionMark;
    FTokens: TContextTokens;      { token accounting for the status line }
    { The cache of the main session context estimate (FAgent.ContextTokens) at the
      moment of the last refresh. In planning mode the main turn is driven by the
      planner, and its sub-sessions (analysis, step) talk to the model themselves:
      no aeContext with depth 0 arrives at that time, while the step/analysis line
      needs the main value for the main/sub/total format. It is refreshed before
      the request (including from the aeContext of the main session), after the
      turn and on a history reset — recomputing the history on every stream
      portion would be too expensive. }
    FMainContext: Integer;
    FLastSummarizeEffective: Boolean; { whether the last summarization was effective }
    { The number of messages already reflected in the context journal: it is used
      to compute the "part" of the next journal record (the tokens of the added
      part of the context). }
    FJournalMsgs: Integer;
    FLastSummarizeSaving: Integer;    { the token reduction of the last summarization }
    { Recomputes FMainContext with the agent estimate over its history and the
      tool schemas (TAgent.ContextTokens). }
    procedure UpdateMainContext;
    { The context of the main session for the status line: the fresh cache, or,
      when the estimate has never been taken, the base from aeContext
      (MainTokens). }
    function MainContextTokens: Integer;
    function StatusText: string;
    { The status line of a plan step sub-session:
      "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%] name" (see
      FormatStepStatus). The counters are the context of the main session
      (MainContextTokens), of the step (SubTokens) and the common model window. }
    function StepStatusText: string;
    { The status line fixed in the log after leaving a sub-session (for example
      "…] analysis done", "…] s1 done"). The counters are taken before the depth
      is unwound, so the numbers are the result of the finished sub-session; the
      step label is taken short (StepShortName), without the task description.
      Outside a step/analysis sub-session it returns the usual StatusText. }
    function DoneStatusText: string;
    { Fix the done line of a finished sub-session the same way in all modes: in an
      ANSI terminal it is fixed by the stream printer (PersistStatus), in a console
      without VT mode and in non-streaming mode (there was no status line on the
      screen) it is printed statically, like the main status after a turn
      (PrintContextStatus). Headless/redirected output stays silent: there is no
      status there at all. }
    procedure PersistDoneStatus;
    { Is a plan step sub-session running (the "step sN" label and the step name
      from aeStepStart). The text of such a session is the step answer: by default
      it is hidden and printed only under
      --show-step-result/--show-reasoning. A subagent nested in the step falls
      under the condition too. }
    { Is the analysis sub-session running: the session label is "analysis" (it
      arrives in aeSubSessionStart) and the depth is exactly one. The analysis
      answer is printed only once — by the final output of the planner — so the
      text of this session is suppressed in aeAssistant and aeStreamText. }
    function InAnalysisSubSession: Boolean;
    function InStepSubSession: Boolean;
    { The context status line after a turn — for non-streaming mode (in a stream
      it is drawn by the stream printer). }
    procedure PrintContextStatus;
    procedure OnAgentEvent(Kind: TAgentEventKind; const Text: string);
    { The plan changed — save the session. }
    procedure OnPlanChanged;
    procedure LoadMcp;
    procedure Repl;
    procedure LoadOrNewSession(out Plan: TPlan);
    procedure SaveCurrentSession;
    function RunOne(const Prompt: string): Integer;
    procedure KeepContextStatus;
    { Summarization of the current session: creates a new session with the
      summary. }
    procedure DoSummarize;
    { Auto-summarization: checks the context fill threshold. }
    procedure CheckAutoSummarize;
    { Asks the host (LLM server) for the model context. }
    procedure FetchHostContext;
  public
    constructor Create(const ACfg: TMirmidConfig);
    destructor Destroy; override;
    property SessionId: string read FSessionId;
    property NoSession: Boolean read FNoSession write FNoSession;
    property ShowReasoning: Boolean read FShowReasoning write FShowReasoning;
    property ShowStepTask: Boolean read FShowStepTask write FShowStepTask;
    property ShowStepResult: Boolean read FShowStepResult write FShowStepResult;
    function Execute(const Cli: TCli): Integer;
  end;

const
  USAGE =
    'mirmid ' + MIRMID_VERSION + ' — AI agent harness in Free Pascal' + sLineBreak +
    '' + sLineBreak +
    'Usage:' + sLineBreak +
    '  mirmid [options] ["prompt"]' + sLineBreak +
    '  mirmid -i ["prompt"]    interactive mode (--interactive is the same; the prompt is the first turn, then the loop)' + sLineBreak +
    '' + sLineBreak +
    'Model and connection:' + sLineBreak +
    '  -m, --model NAME        model name' + sLineBreak +
    '      --base-url URL      base URL of an OpenAI-compatible API' + sLineBreak +
    '      --api-key KEY       API key (or &NAME of the environment variable holding it)' + sLineBreak +
    '      --list-models       request the model list from the API (with details when the provider reports them)' + sLineBreak +
    '' + sLineBreak +
    'Agent:' + sLineBreak +
    '      --system TEXT       system prompt' + sLineBreak +
    '      --loop-warn N       warn on N identical tool calls in a row (0 — off, 3 by default)' + sLineBreak +
    '      --loop-stop N       stop on N identical tool calls in a row (0 — off, 5 by default)' + sLineBreak +
    '      --max-steps N       limit of model→tools steps (0 — unlimited, 0 by default)' + sLineBreak +
    '      --plan              planning mode: plan → steps → report (off by default)' + sLineBreak +
    '      --no-plan           disable the planning mode' + sLineBreak +
    '      --max-tokens N      maximum answer tokens (32768 by default)' + sLineBreak +
    '      --temperature T     temperature (0.1 by default)' + sLineBreak +
    '      --reasoning [MODE]  reasoning_effort: none|minimal|low|medium|high' + sLineBreak +
    '                          (without MODE and without a value — medium)' + sLineBreak +
    '      --no-reasoning      synonym of --reasoning none' + sLineBreak +
    '      --timeout SEC       HTTP request timeout (1800 by default)' + sLineBreak +
    '      --connect-timeout SEC  connection timeout in seconds (10 by default)' + sLineBreak +
    '      --show-reasoning    print the model reasoning_content and the tool output' + sLineBreak +
    '      --show-step-task    print the plan step task before its work (off by default)' + sLineBreak +
    '      --show-step-result  print the result of every plan step (off by default)' + sLineBreak +
    '      --stream            stream the model answer (on by default)' + sLineBreak +
    '      --no-stream         print the whole answer after the request completes' + sLineBreak +
    '' + sLineBreak +
    'Tools:' + sLineBreak +
    '      the tool set is defined by the [tools] section of mirmid.ini:' + sLineBreak +
    '      one 1/0 key per tool (see mirmid --init)' + sLineBreak +
    '      --shell-timeout S   command timeout in seconds (60 by default)' + sLineBreak +
    '      --tool-output-lines N  maximum tool output lines (9 by default, the middle is cut, 0 — no limit)' + sLineBreak +
    '      --shell-output-limit N  maximum shell output in bytes (65536 by default, 0 — no limit)' + sLineBreak +
    '' + sLineBreak +
    'MCP (Model Context Protocol):' + sLineBreak +
    '      --mcp-config FILE   mcp.json file describing the servers' + sLineBreak +
    '      --no-mcp            do not connect MCP servers' + sLineBreak +
    '      --mcp-timeout SEC   MCP server response timeout (60 by default)' + sLineBreak +
    '      --list-mcp          show the MCP servers and their tools' + sLineBreak +
    '' + sLineBreak +
    'Sessions and misc:' + sLineBreak +
    '  -s, --session ID        continue/create the session with the given ID' + sLineBreak +
    '      --list-sessions     show the saved sessions' + sLineBreak +
    '      --no-session        do not save the dialog' + sLineBreak +
    '  -c, --config FILE       configuration file' + sLineBreak +
    '      --workdir DIR       working directory of the tools' + sLineBreak +
    '      --prompt-file FILE  read the prompt from a file' + sLineBreak +
    '      --init              create ./.mirmid/mirmid.ini with the settings' + sLineBreak +
    '  -v, --verbose           verbose output' + sLineBreak +
    '  -V, --version           version' + sLineBreak +
    '  -h, --help              this help';

function UsageText: string;
begin
  Result := USAGE;
end;

function Shorten(const S: string; MaxLen: Integer): string;
begin
  if (MaxLen <= 0) or (Length(S) <= MaxLen) then
    Exit(S);
  { TruncateUTF8 does not allow cutting a multi-byte character: otherwise
    "broken" UTF-8 bytes get into the output and into the API request body. }
  Result := TruncateUTF8(S, MaxLen) + '…';
end;

{ --------------------------------------------------------------- colors }

const
  { ANSI colour codes (SGR) for the on-screen tags. }
  C_STEP       = '36';        { cyan — plan step }
  C_REASONING  = '38;5;101';  { green-grey — the model reasoning text }
  C_TOOLCALL   = '33';        { yellow — the tag with the tool name }
  C_TOOLTEXT   = '38;5;250';  { light grey — tool parameters (json) }
  C_SHELLCMD   = '94';        { bright blue — the shell tool command }
  C_STATUS     = '31';        { red — the context status line }
  C_RESULT     = '32';        { green — the tool result }
  C_USAGE      = '90';        { grey — token statistics }
  C_ERROR      = '31';        { red — Error: }
  C_WARN       = '33';        { yellow — Warning: }
  C_PROMPT     = '36';        { cyan — the REPL prompt }

  ESC = #27;                  { the ESC character for ANSI sequences }

  { The maximum length of the tool result text on the screen; the subagent result
    is printed in full (it is the final answer of a separate session). }
  TOOL_RESULT_MAX = 400;
  { Visible columns of the one-line step summary printed by FormatStepEndBrief
    when the step result is hidden: the header plus the first non-empty line of
    the step text, shortened to this width. }
  STEP_BRIEF_MAX = 120;

{ The separator " — " (space + dash + space) takes 5 bytes in UTF-8. The position
  of the result after Pos is P + Length(' — '), not P + 3: otherwise the copy
  starts inside the multi-byte dash and a "broken" byte gets into the output. }
function FormatStepEnd(const Text: string): string;
var
  P: Integer;
  Sep: string;
begin
  Sep := ' — ';
  P := Pos(Sep, Text);
  if P > 0 then
    Result := Copy(Text, 1, P - 1) + Sep +
      Shorten(Copy(Text, P + Length(Sep), MaxInt), TOOL_RESULT_MAX)
  else
    Result := Text;
end;

{ The step status without the result: the text of the aeStepEnd event up to the
  " — " separator. The result itself is printed by aeStepEnd only when
  --show-step-result or --show-reasoning is on: otherwise only the "s1: done"
  line remains of the step. }
function FormatStepEndStatus(const Text: string): string;
var
  P: Integer;
  Sep: string;
begin
  Sep := ' — ';
  P := Pos(Sep, Text);
  if P > 0 then
    Result := Copy(Text, 1, P - 1)
  else
    Result := Text;
end;
{ The one-line step summary printed when the step result is hidden: the step
  status plus the first non-empty line of the result. The result may be a
  multi-line tool output or model answer, so only its first non-empty line is
  taken (the step must stay one line), and the whole summary is cut by visible
  columns, not bytes: a wide character or an ANSI sequence must not be broken. }
function FormatStepEndBrief(const Text: string): string;
var
  P, I, Start: Integer;
  Sep, Header, Body, Line: string;
begin
  Sep := ' — ';
  P := Pos(Sep, Text);
  if P > 0 then
  begin
    Header := Copy(Text, 1, P - 1);
    Body := Copy(Text, P + Length(Sep), MaxInt);
  end
  else
  begin
    Header := Text;
    Body := '';
  end;
  { The first non-empty line of the result: a blank line before a tool output or
    a trailing newline must not turn the summary into an empty one. A CRLF and a
    lone LF are both treated as a line break. }
  Line := '';
  Start := 1;
  while (Line = '') and (Start <= Length(Body)) do
  begin
    I := Start;
    while (I <= Length(Body)) and (Body[I] <> #10) and (Body[I] <> #13) do
      Inc(I);
    Line := Trim(Copy(Body, Start, I - Start));
    if (I < Length(Body)) and (Body[I] = #13) and (Body[I + 1] = #10) then
      Inc(I);
    Start := I + 1;
  end;
  if Line <> '' then
    Result := Header + Sep + Line
  else
    Result := Header;
  if VisibleLen(Result) > STEP_BRIEF_MAX then
    { The ellipsis takes one column, so the prefix is cut to STEP_BRIEF_MAX - 1. }
    Result := TruncateVisible(Result, STEP_BRIEF_MAX - 1) + '…';
end;

{ The depth prefix: the grey │ character repeated Depth times (0 — empty). }
function DepthPrefix(Depth: Integer): string;
var
  I: Integer;
  S: string;
begin
  if Depth <= 0 then
    Exit('');
  S := '';
  for I := 1 to Depth do
    S := S + '│';
  Result := Colored(C_USAGE, S);
end;

{ Prints an error message to StdErr with a red prefix. }
procedure WriteError(const Text: string);
begin
  WriteLn(StdErr, Colored(C_ERROR, 'Error:', 2), ' ', Text);
end;

{ Prints a warning to StdErr with a yellow prefix. }
procedure WriteWarning(const Text: string);
begin
  WriteLn(StdErr, Colored(C_WARN, 'Warning:', 2), ' ', Text);
end;

{ --------------------------------------------------------------- parsing }

function SplitOpt(const Arg: string; out Name, Inline: string): Boolean;
var
  P: Integer;
begin
  Result := (Length(Arg) > 1) and (Arg[1] = '-');
  Name := Arg;
  Inline := '';
  if not Result then
    Exit;
  P := Pos('=', Arg);
  if P > 0 then
  begin
    Name := Copy(Arg, 1, P - 1);
    Inline := Copy(Arg, P + 1, MaxInt);
  end;
end;

{ Does the argument look like a reasoning mode: --reasoning without a value must
  not swallow the prompt that follows it. }
function IsReasoningToken(const S: string): Boolean;
begin
  Result := NormalizeReasoning(S) <> '';
end;

{ Takes the option value: either inline (--opt=value) or the next argument.
  Changes I when it takes the next argument. }
function TakeValue(const Args: array of string; var I: Integer; const Opt, Inline: string;
  out Value: string; out Err: string): Boolean;
begin
  Err := '';
  if Inline <> '' then
  begin
    Value := Inline;
    Exit(True);
  end;
  if I >= Length(Args) then
  begin
    Err := 'option ' + Opt + ' requires a value';
    Exit(False);
  end;
  Inc(I);
  Value := Args[I - 1];
  Result := True;
end;

function ParseCli(const Args: array of string; out Cli: TCli; out Err: string): Boolean;
var
  I: Integer;
  A, Name, Inline, V: string;
  EndOpts: Boolean;
begin
  FillChar(Cli, SizeOf(Cli), 0);
  Cli.Temperature := 0;
  Err := '';
  EndOpts := False;
  I := 1;
  while I <= Length(Args) do
  begin
    A := Args[I - 1];
    if (not EndOpts) and (A = '--') then
    begin
      EndOpts := True;
      Inc(I);
      Continue;
    end;
    if (not EndOpts) and SplitOpt(A, Name, Inline) then
    begin
      if (Name = '-h') or (Name = '--help') then
        Cli.ShowHelp := True
      else if (Name = '-V') or (Name = '--version') then
        Cli.ShowVersion := True
      else if (Name = '-i') or (Name = '--interactive') then
        Cli.Interactive := True
      else if Name = '--no-mcp' then
        Cli.NoMcp := True
      else if Name = '--list-mcp' then
        Cli.ListMcp := True
      else if Name = '--mcp-config' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.McpConfig := V;
        Cli.HasMcpConfig := True;
      end
      else if Name = '--mcp-timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.McpTimeout := StrToIntDef(V, DEFAULT_MCP_TIMEOUT);
        Cli.HasMcpTimeout := True;
      end
      else if (Name = '-v') or (Name = '--verbose') then
        Cli.Verbose := True
      else if Name = '--show-reasoning' then
        Cli.ShowReasoning := True
      else if Name = '--show-step-result' then
        Cli.ShowStepResult := True
      else if Name = '--show-step-task' then
        Cli.ShowStepTask := True
      else if Name = '--stream' then
      begin
        Cli.Stream := True;
        Cli.HasStream := True;
      end
      else if Name = '--no-stream' then
      begin
        Cli.Stream := False;
        Cli.HasStream := True;
      end
      else if Name = '--plan' then
      begin
        Cli.PlanMode := True;
        Cli.HasPlanMode := True;
      end
      else if Name = '--no-plan' then
      begin
        Cli.PlanMode := False;
        Cli.HasPlanMode := True;
      end
      else if Name = '--reasoning' then
      begin
        V := Inline;
        if (V = '') and (I < Length(Args)) and IsReasoningToken(Args[I]) then
        begin
          Inc(I);
          V := Args[I - 1];
        end;
        if V = '' then
          Cli.Reasoning := 'medium'
        else
          Cli.Reasoning := NormalizeReasoning(V);
        if (V <> '') and (Cli.Reasoning = '') then
        begin
          Err := 'unknown reasoning mode: ' + V +
            ' (none, minimal, low, medium, high)';
          Exit(False);
        end;
        Cli.HasReasoning := True;
      end
      else if Name = '--no-reasoning' then
      begin
        Cli.Reasoning := 'none';
        Cli.HasReasoning := True;
      end
      else if Name = '--no-session' then
        Cli.NoSession := True
      else if Name = '--init' then
        Cli.DoInit := True
      else if Name = '--list-models' then
        Cli.ListModels := True
      else if Name = '--list-sessions' then
        Cli.ListSessions := True
      else if (Name = '-m') or (Name = '--model') then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.Model := V;
      end
      else if Name = '--base-url' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.BaseUrl := V;
        Cli.BaseUrlSet := True;
      end
      else if Name = '--api-key' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ApiKey := V;
        Cli.ApiKeySet := True;
      end
      else if (Name = '-c') or (Name = '--config') then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ConfigFile := V;
      end
      else if (Name = '-s') or (Name = '--session') then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.SessionId := V;
      end
      else if Name = '--system' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.SystemPrompt := V;
      end
      else if Name = '--prompt-file' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.PromptFile := V;
      end
      else if Name = '--workdir' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.WorkDir := V;
      end
      else if Name = '--max-steps' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.MaxSteps := StrToIntDef(V, 0);
        Cli.HasMaxSteps := True;
      end
      else if Name = '--loop-warn' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.LoopWarn := StrToIntDef(V, 0);
        Cli.HasLoopWarn := True;
      end
      else if Name = '--loop-stop' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.LoopStop := StrToIntDef(V, 0);
        Cli.HasLoopStop := True;
      end
      else if Name = '--max-tokens' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.MaxTokens := StrToIntDef(V, 0);
        Cli.HasMaxTokens := True;
      end
      else if Name = '--temperature' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.Temperature := DotToFloat(V, 0);
        Cli.HasTemperature := True;
      end
      else if Name = '--timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.Timeout := StrToIntDef(V, 0);
        Cli.HasTimeout := True;
      end
      else if Name = '--connect-timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ConnectTimeout := StrToIntDef(V, 0);
        Cli.HasConnectTimeout := True;
      end
      else if Name = '--shell-timeout' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ShellTimeout := StrToIntDef(V, 0);
        Cli.HasShellTimeout := True;
      end
      else if Name = '--shell-output-limit' then
      begin
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ShellOutputLimit := StrToIntDef(V, 0);
        Cli.HasShellOutputLimit := True;
      end
      else if Name = '--tool-output-lines' then
      begin
        // maximum number of tool output lines (0 — no limit)
        if not TakeValue(Args, I, Name, Inline, V, Err) then Exit(False);
        Cli.ToolOutputLines := StrToIntDef(V, 0);
        Cli.HasToolOutputLines := True;
      end
      else
      begin
        Err := 'unknown option: ' + A;
        Exit(False);
      end;
    end
    else
    begin
      if Cli.Prompt = '' then
        Cli.Prompt := A
      else
        Cli.Prompt := Cli.Prompt + ' ' + A;
    end;
    Inc(I);
  end;
  Result := True;
end;

function FindConfigFile(const Explicit, WorkDir: string): string;
begin
  if Explicit <> '' then
    Exit(Explicit);
  Result := ProjectConfigPath(WorkDir);
  if FileExists(Result) then
    Exit;
  Result := '';
end;

function ResolveConfig(const Cli: TCli; var Cfg: TMirmidConfig;
  var WorkDir: string; out Err: string): Boolean;
var
  ErrText: string;
begin
  Err := '';
  Result := True;
  if WorkDir = '' then
    WorkDir := GetCurrentDir;
  WorkDir := ExpPath(WorkDir, GetCurrentDir);
  Cfg := DefaultConfig;
  Cfg.WorkDir := WorkDir;

  { An unknown key in [tools] is a fatal error: a typo must not silently leave a
    tool at its default value. The exception is `--init`: it exists precisely to
    repair a broken file, so the sample is built from the defaults and the
    command line overrides, and the parse reason is not printed. }
  ErrText := '';
  if not LoadIni(FindConfigFile(Cli.ConfigFile, WorkDir), Cfg, ErrText) then
  begin
    if not Cli.DoInit then
    begin
      Err := ErrText;
      Exit(False);
    end;
  end;

  ApplyEnv(Cfg);

  if Cli.HasTemperature then Cfg.Temperature := Cli.Temperature;
  if Cli.HasReasoning then Cfg.Reasoning := Cli.Reasoning;
  if Cli.Model <> '' then Cfg.Model := Cli.Model;
  if Cli.SystemPrompt <> '' then Cfg.SystemPrompt := Cli.SystemPrompt;
  if Cli.HasMaxSteps then Cfg.MaxSteps := Cli.MaxSteps;
  if Cli.HasMaxTokens then Cfg.MaxTokens := Cli.MaxTokens;
  if Cli.HasTimeout then Cfg.RequestTimeout := Cli.Timeout * 1000;
  if Cli.HasConnectTimeout then Cfg.ConnectTimeout := Cli.ConnectTimeout * 1000;
  if Cli.HasShellTimeout then Cfg.ShellTimeout := Cli.ShellTimeout;
  if Cli.HasShellOutputLimit then Cfg.ShellOutputLimit := Cli.ShellOutputLimit;
  { Tool output line limit: 0 — no limit (the CLI value wins over INI/env). }
  if Cli.HasToolOutputLines then Cfg.ToolOutputLines := Cli.ToolOutputLines;
  if Cli.HasLoopWarn then Cfg.LoopWarn := Cli.LoopWarn;
  if Cli.HasLoopStop then Cfg.LoopStop := Cli.LoopStop;
  if Cli.NoMcp then Cfg.McpEnabled := False;
  if Cli.HasMcpConfig then Cfg.McpConfig := ExpPath(Cli.McpConfig, WorkDir);
  if Cli.HasMcpTimeout then Cfg.McpTimeout := Cli.McpTimeout;
  if Cli.HasStream then Cfg.Stream := Cli.Stream;
  if Cli.HasPlanMode then Cfg.PlanMode := Cli.PlanMode;
  if Cli.Verbose then Cfg.Verbose := True;
  if Cli.BaseUrlSet then Cfg.BaseUrl := Cli.BaseUrl;
  if Cli.ApiKeySet then Cfg.ApiKey := Cli.ApiKey;
  { api_key may be a reference to an environment variable — only with the "&"
    prefix (&MY_API_KEY). The original value is kept in ApiKeyRaw: --init writes
    it into the new INI so that the expanded key never reaches the file. }
  Cfg.ApiKeyRaw := Cfg.ApiKey;
  Cfg.ApiKey := ResolveApiKey(Cfg.ApiKey);
  { HTTPS trust: the snapshot of the roots embedded in the exe (tls.roots), and
    when it is missing — the OS system store. There is nothing to configure here,
    so the INI has no key with a path to a PEM bundle and the environment has no
    variable with one. }
end;

{ The state of the embedded TLS root snapshot (tls.roots) for the user: the date
  of the snapshot and the staleness flag. It is called once at start — before the
  first HTTPS request (the LLM provider, the http_request tool), so it does not
  get into the log again for every connection. }
procedure WarnEmbeddedRoots(const Cfg: TMirmidConfig);
var
  Info: TEmbeddedRootsInfo;
begin
  Info := GetEmbeddedRootsInfo;
  if not Info.Available then
  begin
    { A fallback system store exists only on Windows (CryptoAPI), so there we stay
      silent (unless -v): otherwise every build without tlsroots.res would scare
      the user for no reason. On other platforms there is nothing to validate the
      chain with when the snapshot is missing — warn at once instead of at the
      first request. }
    {$ifdef windows}
    if Cfg.Verbose then
      WriteWarning(EmbeddedRootsInfoText(Info) +
        '; using the Windows system store');
    {$else}
    WriteWarning(EmbeddedRootsInfoText(Info) +
      '; HTTPS requests will fail with a trust store error');
    {$endif}
    Exit;
  end;
  if Info.Stale then
    WriteWarning(EmbeddedRootsInfoText(Info) +
      ' — update the tls library (make roots)')
  else if Cfg.Verbose then
    { The snapshot is fresh: the date matters only in verbose mode. }
    WriteLn(StdErr, 'TLS: ', EmbeddedRootsInfoText(Info));
end;

{ --------------------------------------------------------------- streaming UI }

{ A short number notation: 12345 → "12.3k", 128000 → "128k". Integer arithmetic —
  the decimal point does not depend on the locale. }
function CompactNumber(V: Integer): string;
var
  Tenth: Int64;   { the value in tenths: 12345 → 123 (≈12.3) }
begin
  if V >= 1000 then
  begin
    Tenth := (Int64(V) * 10 + 500) div 1000;   { rounding to 0.1 }
    if Tenth mod 10 = 0 then
      Result := IntToStr(Tenth div 10) + 'k'
    else
      Result := IntToStr(Tenth div 10) + '.' + IntToStr(Tenth mod 10) + 'k';
  end
  else
    Result := IntToStr(V);
end;

{ The percentage of the whole window in tenths: 123 out of 128000 → "0.1%". One
  percentage per counter: the step line prints two — for the main session and for
  the sub-session. Integer arithmetic — the point does not depend on the locale. }
function PercentText(Cur, Total: Integer): string;
var
  Tenth: Int64;   { the percentage in tenths }
begin
  if Total <= 0 then
    Exit('?');
  Tenth := (Int64(Cur) * 1000 + Int64(Total) div 2) div Int64(Total);
  Result := IntToStr(Tenth div 10) + '.' + IntToStr(Tenth mod 10) + '%';
end;

{ The context status line: "[HH:MM:SS|current/total|percent%]". The time is local
  (hh:mm:ss, locale independent); the percentage is rounded to 0.1 with integer
  arithmetic (PercentText), the point is locale independent. WithTime = False — no
  time. }
function FormatContextStatus(const Cur, Total: Integer;
  WithTime: Boolean): string;
var
  TimePart: string;
begin
  if WithTime then
    TimePart := FormatDateTime('hh:nn:ss', Now) + '|'
  else
    TimePart := '';
  if Total <= 0 then
    Exit('[' + TimePart + CompactNumber(Cur) + '/?|?]');
  Result := '[' + TimePart + CompactNumber(Cur) + '/' +
            CompactNumber(Total) + '|' + PercentText(Cur, Total) + ']';
end;

{ The sub-session status line: the status of the main session, the label
  ("subagent" by default, for plan steps "step s1", "analysis") and the status of
  the sub-session itself. Only the first part prints the time: one clock per line
  is enough, the second part has no date and time. }
function FormatSubAgentStatus(const MainCur, SubCur, Total: Integer;
  const LabelText: string): string;
begin
  Result := Colored(C_STATUS, FormatContextStatus(MainCur, Total)) + ' ' +
    Colored(C_USAGE, LabelText) + ' ' +
    Colored(C_STATUS, FormatContextStatus(SubCur, Total, False));
end;

{ The context line of a planner sub-session: "[HH:MM:SS|main/sub/total|
  main-percent%/sub-percent%]". First the context of the main session, then the
  sub-session (step or analysis), then the common model window; both percentages
  are counted from the same window, hence there are two. One clock per line. }
function FormatStepContextStatus(const MainCur, SubCur, Total: Integer): string;
begin
  if Total <= 0 then
    Exit('[' + FormatDateTime('hh:nn:ss', Now) + '|' +
      CompactNumber(MainCur) + '/' + CompactNumber(SubCur) + '/?|?/?]');
  Result := '[' + FormatDateTime('hh:nn:ss', Now) + '|' +
    CompactNumber(MainCur) + '/' + CompactNumber(SubCur) + '/' +
    CompactNumber(Total) + '|' + PercentText(MainCur, Total) + '/' +
    PercentText(SubCur, Total) + ']';
end;

{ The plan step line: "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%]
  name". The status is red (C_STATUS), the name is grey (C_USAGE); there is no
  [step] tag, the status comes first. The context of the main session (MainCur)
  goes right before the context of the step (Cur) — see FormatStepContextStatus. }
function FormatStepStatus(const Name: string; Cur, Total: Integer;
  MainCur: Integer): string;
begin
  Result := Colored(C_STATUS, FormatStepContextStatus(MainCur, Cur, Total));
  if Name <> '' then
    Result := Result + ' ' + Colored(C_USAGE, Name);
end;

{ The line of the preliminary plan analysis: "[HH:MM:SS|main/sub/total|
  main-percent%/sub-percent%] analysis". The order is the same as in the step
  line (FormatStepStatus): the red status (C_STATUS) first, then the grey
  (C_USAGE) "analysis" label; there is no [analysis] tag in the status line. }
function FormatAnalysisStatus(const Cur, Total: Integer;
  MainCur: Integer): string;
begin
  Result := Colored(C_STATUS, FormatStepContextStatus(MainCur, Cur, Total)) +
    ' ' + Colored(C_USAGE, 'analysis');
end;

{ The short step name for the final status line: only the identifier "s1" is
  taken from "s1: description" (trimmed and stripped of the surrounding spaces).
  In the step line the description is needed, in the fixed "s1 done" line it is
  not. Without a colon the name is returned as it is, an empty one
  stays empty. }
function StepShortName(const Name: string): string;
var
  P: Integer;
begin
  P := Pos(':', Name);
  if P > 0 then
    Result := Trim(Copy(Name, 1, P - 1))
  else
    Result := Trim(Name);
end;

{ The text of a plan step sub-session (and the step result in aeStepEnd) is
  printed only under one of the flags: by default only the status lines remain of
  a step. }
function StepTextVisible(ShowStepResult, ShowReasoning: Boolean): Boolean;
begin
  Result := ShowStepResult or ShowReasoning;
end;

{ The one-line summary (FormatStepEndBrief) is printed exactly when the step text
  is hidden: it replaces the bare "s1: done" status line and gives a hint of what
  the step produced without repeating the answer. With the text visible the full
  FormatStepEnd is printed instead, so the summary is not needed. }
function StepBriefVisible(ShowStepResult, ShowReasoning: Boolean): Boolean;
begin
  Result := not StepTextVisible(ShowStepResult, ShowReasoning);
end;

{ The plan step task is printed with --show-step-task or --show-reasoning (with
  both off the step name is not printed in aeStepStart, the name stays only in the
  status line). --show-step-result (ShowStepResult) does not apply to the task: it
  is about the answer text and the step result (StepTextVisible), so the
  parameter deliberately does not take part in the result. }
{$PUSH}{$WARN 5024 OFF}  { ShowStepResult is unused — see the comment above }
function StepTaskVisible(ShowStepTask, ShowReasoning,
  ShowStepResult: Boolean): Boolean;
begin
  Result := ShowStepTask or ShowReasoning;
end;
{$POP}

{ Tool output — only together with the reasoning (--show-reasoning): the
  intermediate output is hidden in all sessions, the main and the subagent one
  included (as in plan steps). }
function ToolOutputVisible(ShowReasoning: Boolean): Boolean;
begin
  Result := ShowReasoning;
end;

constructor TContextTokens.Create;
begin
  inherited Create;
  FMainBase := 0;
  FMainAccum := 0;
  FSubBase := 0;
  FSubAccum := 0;
end;

{ A new base (aeContext). It is accounted separately for the main session and the
  subagent: the subagent events arrive in the same handler. }
procedure TContextTokens.SetBase(Depth, Tokens: Integer);
begin
  if Depth > 0 then
  begin
    FSubBase := Tokens;
    FSubAccum := 0;
  end
  else
  begin
    FMainBase := Tokens;
    FMainAccum := 0;
  end;
end;

procedure TContextTokens.AddResponseTokens(Depth, Tokens: Integer);
begin
  if Depth > 0 then
    Inc(FSubAccum, Tokens)
  else
    Inc(FMainAccum, Tokens);
end;

{ Entering a sub-session: the counters of the parent sub-session go to the stack
  and the new ones start from zero — otherwise, until the first aeContext (and in
  the case of an unpaired event), the status would show the values of the
  previous sub-session. }
procedure TContextTokens.EnterSubAgent;
var
  N: Integer;
begin
  N := Length(FSavedBase);
  SetLength(FSavedBase, N + 1);
  SetLength(FSavedAccum, N + 1);
  FSavedBase[N] := FSubBase;
  FSavedAccum[N] := FSubAccum;
  FSubBase := 0;
  FSubAccum := 0;
end;

{ Leaving a sub-session: the counters of the parent (a plan step the subagent
  worked inside) are restored so that its context size is not lost. An empty
  stack (an exit without an entry) — just zeroing. }
procedure TContextTokens.ExitSubSession;
var
  N: Integer;
begin
  N := Length(FSavedBase);
  if N = 0 then
  begin
    FSubBase := 0;
    FSubAccum := 0;
    Exit;
  end;
  FSubBase := FSavedBase[N - 1];
  FSubAccum := FSavedAccum[N - 1];
  SetLength(FSavedBase, N - 1);
  SetLength(FSavedAccum, N - 1);
end;

function TContextTokens.SavedCount: Integer;
begin
  Result := Length(FSavedBase);
end;

{ Unwinding to the state at the entry into the sub-session: its own pair and the
  pairs of unclosed nested sub-sessions (for example a subagent inside a step
  whose aeToolResult never arrived because of an exception) are removed; the
  parent counters saved before the entry are restored. }
procedure TContextTokens.UnwindTo(Level: Integer);
begin
  if Level < 0 then
    Level := 0;
  if Level > Length(FSavedBase) then
  begin
    { The stack is shorter than the mark — the state is unreliable: resetting is
      safer. }
    ResetSubSession;
    Exit;
  end;
  while Length(FSavedBase) > Level do
    ExitSubSession;
end;

{ A full reset: after leaving an outer sub-session (step/analysis) neither
  counters nor pairs must remain in the stack — otherwise a failed step or
  revise_plan would leave values for the next step or the main session. }
procedure TContextTokens.ResetSubSession;
begin
  FSubBase := 0;
  FSubAccum := 0;
  SetLength(FSavedBase, 0);
  SetLength(FSavedAccum, 0);
end;

{ The status line: in a sub-session — both sessions (the sub-session size without
  time), otherwise only the main one. The sub-session label is "subagent" by
  default, the planner passes "step s1" and "analysis". }
function TContextTokens.Text(Total, Depth: Integer;
  const LabelText: string): string;
begin
  if Depth > 0 then
    Result := FormatSubAgentStatus(FMainBase + FMainAccum, FSubBase + FSubAccum,
      Total, LabelText)
  else
    Result := Colored(C_STATUS, FormatContextStatus(FMainBase + FMainAccum,
      Total));
end;

{ The tokens of the current sub-session: the base from its aeContext plus what
  was accumulated for the current answer. The plan step line prints only these
  counters — the main session does not take part in it (the line has one time,
  the step one). }
function TContextTokens.SubTokens: Integer;
begin
  Result := FSubBase + FSubAccum;
end;

{ The tokens of the main session: the base from its aeContext plus what was
  accumulated for the current answer. The plan step and analysis line prints them
  next to the sub-session counters (main/sub/total format), so the value is
  needed as a separate accessor — SubTokens returns the sub-session only. }
function TContextTokens.MainTokens: Integer;
begin
  Result := FMainBase + FMainAccum;
end;

constructor TStreamPrinter.Create;
begin
  inherited Create;
  FActive := False;
  FLive := AnsiEnabled(1);   { without VT mode in the console ESC codes are invalid }
  FStatusShown := False;
  FPending := '';
  FReasoningMode := False;
  FInCodeBlock := False;
  FGroupBuf := '';
  FInTable := False;
  FTableBuf := '';
  FTableOnScreen := 0;
  FTableWide := False;
  FTableRawPrinted := 0;
  FPendingOnScreen := False;
  FPrefix := '';
  FBlankPending := False;
  FBlankSeparated := False;
end;

{ The requested blank separator line (RequestBlankLine): it is printed once — by
  the output block that starts next. }
procedure TStreamPrinter.RequestBlankLine;
begin
  FBlankPending := True;
end;

procedure TStreamPrinter.EmitPendingBlank;
begin
  if not FBlankPending then
    Exit;
  FBlankPending := False;
  FBlankSeparated := True;
  WriteLn;
end;

destructor TStreamPrinter.Destroy;
begin
  inherited Destroy;
end;

{ The cursor to the beginning of the current line and a clear down to its end. }
procedure TStreamPrinter.ClearLine;
begin
  if not FLive then
    Exit;
  Write(#13);
  Write(ESC + '[K');
end;

{ Clear the stream area: the current line (status/empty, the cursor at its end)
  and, when a partial text lies above it (guaranteed not wider than the
  terminal), its line. The cursor stays at the beginning of the upper cleared
  line — the new content is printed there; the old status is already erased, so
  wrapping the new content leaves no tail of it. }
procedure TStreamPrinter.ClearAbove;
begin
  if not FLive then
    Exit;
  ClearLine;             { CR + ESC[K on the status/empty line }
  if FPendingOnScreen then
  begin
    Write(ESC + '[A');   { the cursor to the line with the partial text }
    ClearLine;           { clear it }
  end;
end;

{ The status is printed on its own line under the text; the caller ensures that
  the cursor is at the beginning of a clean line. A status wider than the
  terminal wraps onto a second line, while the next redraw clears only the last
  one, so the tail of the old status stays in the scrollback; therefore the text
  is cut to the content width minus one column (moving the cursor into the very
  last cell makes some terminals wrap). The prefix already accounts for the
  prefix width inside ContentWidth. }
procedure TStreamPrinter.PrintStatus(const Status: string);
begin
  if not FLive then
    Exit;
  Write(FPrefix + TruncateVisible(Status, ContentWidth - 1));
  FStatusShown := True;
end;

{ Finishing the status line: the status line is fully temporary and lives only in
  an ANSI terminal — it is never printed into the scrollback. The method erases
  the current status line (after EndStream a variant with smaller counters may
  remain there) and resets the drawn-status flag so that the next redraw starts
  from a clean line. The Status parameter is kept for the callers: a finished
  sub-session no longer leaves its line. Outside an ANSI terminal the method
  stays silent. }
procedure TStreamPrinter.FreezeStatus(const Status: string);
begin
  if not FLive then
    Exit;
  ClearLine;
  FStatusShown := False;
end;

{ Redraw the status line without printing any text: a portion of the answer
  (reasoning) is accounted in the counters, but its text is hidden by the
  setting — the counters in the status must grow anyway. Between portions the
  cursor stands on the status line, so clearing it and printing it again is
  enough; outside an ANSI terminal there is no status and the method stays
  silent. }
procedure TStreamPrinter.RefreshStatus(const Status: string);
begin
  if not FActive then
    Exit;
  if not FLive then
    Exit;
  ClearLine;
  PrintStatus(Status);
end;

{ Draw the status line again without printing any text: between output portions
  and after static lines the cursor stands on the status line (or on the empty
  line under it), so clearing it and printing the status is enough. Unlike
  RefreshStatus it does not require an active stream (FActive): the method is
  called after static printing too (the tool call line, a shell command), so that
  the status line stays under them. ClearLine and PrintStatus stay silent outside
  an ANSI terminal — there is no status there. }
procedure TStreamPrinter.DrawStatus(const Status: string);
begin
  ClearLine;
  PrintStatus(Status);
end;

{ Fix the status line in the log (end of a turn): the drawn temporary line is
  erased and printed again with the final text, and the line break makes it
  permanent — the status stays on the screen, the cursor moves to the clean line
  under it (the next output does not stick to the status). Outside an ANSI
  terminal there is no status — the method stays silent. }
procedure TStreamPrinter.PersistStatus(const Status: string);
begin
  if not FLive then
    Exit;
  FBlankSeparated := False;
  ClearLine;
  { The requested separator (RequestBlankLine) — before the line being fixed: a
    tool result is separated by a blank line from the done line too. }
  EmitPendingBlank;
  PrintStatus(Status);
  WriteLn;
  FStatusShown := False;
end;

function TStreamPrinter.RenderLine(const L: string): string;
begin
  if FReasoningMode then
    Result := Colored(C_REASONING, StripMarkdown(L))
  else
    Result := RenderMarkdown(L);
end;

function TStreamPrinter.MeasureRendered(const S: string): Integer;
begin
  Result := VisibleLen(RenderLine(S));
end;

function TStreamPrinter.ContentWidth: Integer;
begin
  Result := TermWidth() - VisibleLen(FPrefix);
  if Result < 1 then
    Result := 1;
end;

function TStreamPrinter.BreakSafe(const Pfx: string): Boolean;
begin
  Result := MarkdownBreakSafe(Pfx);
end;

{ The text of the current line without trailing CRs (CRLF split by a chunk). }
function TStreamPrinter.PendingText: string;
var
  S: string;
begin
  S := FPending;
  while (Length(S) > 0) and (S[Length(S)] = #13) do
    Delete(S, Length(S), 1);
  Result := S;
end;

function TStreamPrinter.ApplyPrefix(const S: string): string;
var
  Lines: TStringList;
  I: Integer;
begin
  if FPrefix = '' then
    Exit(S);
  Lines := TStringList.Create;
  try
    Lines.Text := S;
    for I := 0 to Lines.Count - 1 do
      Lines[I] := FPrefix + Lines[I];
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;
{ A complete line: clear the stream area above the cursor, print the line with a
  line break. A long line is first wrapped at word boundaries — otherwise the
  terminal would cut it hard (punctuation would move to the beginning of the
  line). The cursor stays at the beginning of the clean line below it (the status
  is printed there afterwards). }
procedure TStreamPrinter.EmitCompleteLine(const L: string);
var
  Segs: TStringList;
  I: Integer;
begin
  ClearAbove;
  Segs := WrapText(L, ContentWidth, @MeasureRendered, @BreakSafe);
  try
    for I := 0 to Segs.Count - 1 do
      WriteLn(FPrefix + RenderLine(Segs[I]));
  finally
    Segs.Free;
  end;
  ClearLine;   { clear the line under the text (the old status) }
  FStatusShown := False;
  FPendingOnScreen := False;
end;

{ The partial (unfinished) current line: redraw it on its line and prepare a
  clean line below it for the status (the caller prints the status). The line is
  wrapped at word boundaries: whatever no longer fits is printed as complete
  lines (broken at a space, the space is dropped), and the last fragment stays
  the current line and is redrawn. A partial table line is not printed
  separately — it comes out together with the table (otherwise the header would
  be duplicated). }
procedure TStreamPrinter.ShowPartial;
var
  S, Trail, DrawS: string;
  Segs: TStringList;
  I: Integer;
begin
  DrawS := '';
  if FPending <> '' then
  begin
    S := PendingText;
    if (S <> '') and IsTableLine(S) then
    begin
      { A partial table line is not shown separately: remove it (if it was
        shown) and leave the cursor at the beginning of the line where the
        caller prints the status. No new lines are added. }
      ClearAbove;
      FPendingOnScreen := False;
      Exit;
    end;
    if S <> '' then
    begin
      { Trailing spaces are kept in the buffer: the line is not finished yet,
        and a space is the separator from the next word (wrapping would drop
        it). Draw without the trailing spaces so that the partial line is
        guaranteed to be narrower than the terminal. }
      Trail := '';
      while (S <> '') and (S[Length(S)] = ' ') do
      begin
        Trail := ' ' + Trail;
        Delete(S, Length(S), 1);
      end;
      if S <> '' then
      begin
        { Wrap the accumulated line: the fragments that no longer fit become
          complete lines; the last one stays current. }
        Segs := WrapText(S, ContentWidth, @MeasureRendered, @BreakSafe);
        try
          for I := 0 to Segs.Count - 2 do
            EmitCompleteLine(Segs[I]);
          if Segs.Count > 0 then
            DrawS := Segs[Segs.Count - 1];
        finally
          Segs.Free;
        end;
      end;
      FPending := DrawS + Trail;
    end;
  ClearAbove;
  if DrawS <> '' then
  begin
    Write(FPrefix + RenderLine(DrawS));
    WriteLn;                     { down: the status line under the text }
    ClearLine;                   { clear the old status (the cursor is at its start) }
    FPendingOnScreen := True;
  end
  else
    { Nothing to draw (a partial line of spaces only): do not add a line — the
      cursor stays at the beginning of the clean line and the caller prints the
      status there. }
    FPendingOnScreen := False;
end;
end;

{ A group of lines (a fenced code block): printed in one piece so that the
  markup is rendered correctly. The cursor stays on a new line — the status is
  printed there afterwards. }
procedure TStreamPrinter.EmitGroup(const G: string);
begin
  ClearAbove;
  { The rendered group is wrapped to the visible content width, so long lines
    (tables, paragraphs) never run past the terminal edge. }
  WriteLn(ApplyPrefix(RenderMarkdown(G, 1, ContentWidth)));
  ClearLine;   { clear the line under the group (the old status) }
  FStatusShown := False;
  FPendingOnScreen := False;
end;

{ Closes an open code block: the unfinished line is appended to the buffer, the
  whole block is printed as a group. }
procedure TStreamPrinter.FlushCodeBlock;
begin
  if not FInCodeBlock then
    Exit;
  if FPending <> '' then
  begin
    FGroupBuf := FGroupBuf + sLineBreak + FPending;
    FPending := '';
  end;
  if FGroupBuf <> '' then
    EmitGroup(FGroupBuf);
  FInCodeBlock := False;
  FGroupBuf := '';
end;

{ Prints the current table buffer with aligned columns. If the table lines are
  already on the screen, the cursor goes up to them, they are cleared, and the
  whole table is redrawn (alignment as it fills up). If the table stops fitting
  into the terminal width, the already drawn aligned table is erased and all
  buffer lines are printed as they are, without box drawing (a table wider than
  the terminal cannot be aligned and redrawn: wrapped lines cannot be raised line
  by line). The cursor stays on a clean line under the table (the status is
  printed there afterwards). }
procedure TStreamPrinter.ShowTable;
var
  Lines, RL: TStringList;
  R: string;
  I, MaxW, K: Integer;
begin
  if FTableBuf = '' then
    Exit;
  Lines := SplitLines(FTableBuf);
  RL := nil;
  try
    { The table width is limited by the visible content width (the terminal
      minus the stream prefix): RenderTable wraps cells by words and distributes
      the column widths itself. A cell that cannot be broken (a long word or an
      inline span wider than its column) widens the column instead of losing
      text, so the table may still not fit — then the lines are printed as they
      are, without the box. }
    R := RenderTable(Lines, True, ContentWidth);
    MaxW := 0;
    RL := SplitLines(R);
    for I := 0 to RL.Count - 1 do
      if VisibleLen(RL[I]) > MaxW then
        MaxW := VisibleLen(RL[I]);
    if MaxW > ContentWidth then
    begin
      { Wider than the terminal: remove the already drawn aligned table (it was
        not wider than the terminal, hence without wrapping) and print all buffer
        lines as they are. Every new line is appended the same way — without
        parsing it again as a table. }
      if not FTableWide then
      begin
        FTableWide := True;
        { Go back to the top border of the aligned table, erase it together with
          the status line and leave the cursor at the top border — the "raw" lines
          are printed right there, without an empty gap. }
        if FTableOnScreen > 0 then
        begin
          Write(ESC + '[' + IntToStr(FTableOnScreen) + 'A');
          ClearLine;
          for K := 2 to FTableOnScreen + 1 do
          begin
            Write(ESC + '[B');
            ClearLine;
          end;
          Write(ESC + '[' + IntToStr(FTableOnScreen + 1) + 'A');
        end;
        FTableRawPrinted := 0;
      end;
      for I := FTableRawPrinted to Lines.Count - 1 do
      begin
        ClearLine;            { clear the status line under the table }
        WriteLn(FPrefix + Lines[I]);    { the line as it is, without borders }
      end;
      ClearLine;              { the line under the table (the old status) }
      FTableRawPrinted := Lines.Count;
      FStatusShown := False;
    end
    else
    begin
      { The whole table screen is redrawn. The cursor goes up exactly by the
        number of DRAWN lines (not buffer lines): every data line also has a top
        and a bottom border. Every line is cleared before printing — otherwise
        the tail of the old status remains to the right of a short border. }
      if FTableOnScreen > 0 then
        Write(ESC + '[' + IntToStr(FTableOnScreen) + 'A');
      for I := 0 to RL.Count - 1 do
      begin
        ClearLine;
        Write(FPrefix + RL[I]);
        WriteLn;
      end;
      ClearLine;   { the line under the table (the old status) }
      { The drawn height is not monotone: a new buffer line redistributes the
        column widths and can unwrap an older cell, so the new rendering may be
        shorter than the previous one. Erase the lines the old table left below
        and put the cursor back under the new bottom border. }
      if FTableOnScreen > RL.Count then
      begin
        for K := RL.Count to FTableOnScreen - 1 do
        begin
          Write(ESC + '[B');
          ClearLine;
        end;
        Write(ESC + '[' + IntToStr(FTableOnScreen - RL.Count) + 'A');
      end;
      FTableOnScreen := RL.Count;
    end;
    FPendingOnScreen := False;   { the partial line is not on the screen }
  finally
    if RL <> nil then
      RL.Free;
    Lines.Free;
  end;
end;

{ Closes an open table: prints the buffer (aligned) and resets the state. }
procedure TStreamPrinter.FlushTable;
begin
  if not FInTable then
    Exit;
  if FTableBuf <> '' then
    ShowTable;
  FInTable := False;
  FTableBuf := '';
  FTableOnScreen := 0;
  FTableWide := False;
  FTableRawPrinted := 0;
end;

{ One complete content line: code blocks are buffered until the closing marker,
  table lines — until the first non-table line, the rest is printed at once. }
procedure TStreamPrinter.ProcessContentLine(const L: string; var Emitted: Boolean);
var
  T: string;
begin
  T := Trim(L);
  if (Pos('```', T) = 1) or (Pos('~~~', T) = 1) then
  begin
    FlushTable;
    if FInCodeBlock then
    begin
      { The closing marker: the code block is printed as a group. }
      FInCodeBlock := False;
      EmitGroup(FGroupBuf + sLineBreak + L);
      FGroupBuf := '';
      Emitted := True;
    end
    else
    begin
      FInCodeBlock := True;
      FGroupBuf := L;
    end;
  end
  else if FInCodeBlock then
    FGroupBuf := FGroupBuf + sLineBreak + L
  else if IsTableLine(L) then
  begin
    { A table line: buffer it and redraw the whole table with aligned columns. }
    if FInTable then
      FTableBuf := FTableBuf + sLineBreak + L
    else
    begin
      FInTable := True;
      FTableBuf := L;
    end;
    ShowTable;
    Emitted := True;
  end
  else
  begin
    FlushTable;
    EmitCompleteLine(L);
    Emitted := True;
  end;
end;

{ Outside a terminal: no status and no redraw — the text is written as it is
  (including the line breaks). FPending keeps the tail of the current unfinished
  line — for the final newline in EndStream/PrepareStatic. }
procedure TStreamPrinter.FeedRaw(const Delta: string);
var
  P, I: Integer;
  S: string;
begin
  S := Delta;
  if FPrefix <> '' then
  begin
    S := '';
    if FPending = '' then
      S := FPrefix;
    for I := 1 to Length(Delta) do
    begin
      if Delta[I] = #10 then
        S := S + #10 + FPrefix
      else
        S := S + Delta[I];
    end;
  end;
  Write(S);
  P := Length(Delta);
  while (P > 0) and (Delta[P] <> #10) do
    Dec(P);
  if P = 0 then
    FPending := FPending + Delta
  else
    FPending := Copy(Delta, P + 1, MaxInt);
end;

procedure TStreamPrinter.BeginStream(const Status: string);
begin
  PrepareStatic;   { a new line under the previous status/content }
  FActive := True;
  FInCodeBlock := False;
  FGroupBuf := '';
  FInTable := False;
  FTableBuf := '';
  FTableOnScreen := 0;
  FTableWide := False;
  FTableRawPrinted := 0;
  FPending := '';
  FReasoningMode := False;
  FPendingOnScreen := False;
  PrintStatus(Status);
end;

procedure TStreamPrinter.FeedReasoning(const Delta, Status: string);
var
  P: Integer;
  L: string;
  Emitted: Boolean;
begin
  if not FActive then
    Exit;
  if not FLive then
  begin
    FeedRaw(Delta);
    Exit;
  end;
  { If the current line was content, finish it before the reasoning. Inside a
    code block a partial line goes into the group buffer, not to the screen. }
  if (FPending <> '') and (not FReasoningMode) then
  begin
    if FInCodeBlock then
      FGroupBuf := FGroupBuf + sLineBreak + FPending
    else
    begin
      FlushTable;
      EmitCompleteLine(FPending);
    end;
    FPending := '';
  end;
  FlushTable;
  FReasoningMode := True;
  FPending := FPending + Delta;
  Emitted := False;
  while Pos(#10, FPending) > 0 do
  begin
    P := Pos(#10, FPending);
    L := Copy(FPending, 1, P - 1);
    Delete(FPending, 1, P);
    if (Length(L) > 0) and (L[Length(L)] = #13) then
      Delete(L, Length(L), 1);
    EmitCompleteLine(L);
    Emitted := True;
  end;
  { A partial line — redraw it (the status ends up on the line below it). }
  if (FPending <> '') and (PendingText <> '') then
  begin
    ShowPartial;
    Emitted := True;
  end;
  if Emitted then
    PrintStatus(Status);
end;

procedure TStreamPrinter.FeedContent(const Delta, Status: string);
var
  P: Integer;
  L: string;
  Emitted: Boolean;
begin
  if not FActive then
    Exit;
  if not FLive then
  begin
    FeedRaw(Delta);
    Exit;
  end;
  { If the current line was reasoning, finish it before the content. }
  if (FPending <> '') and FReasoningMode then
  begin
    EmitCompleteLine(FPending);
    FPending := '';
  end;
  FReasoningMode := False;
  FPending := FPending + Delta;
  Emitted := False;
  while Pos(#10, FPending) > 0 do
  begin
    P := Pos(#10, FPending);
    L := Copy(FPending, 1, P - 1);
    Delete(FPending, 1, P);
    if (Length(L) > 0) and (L[Length(L)] = #13) then
      Delete(L, Length(L), 1);
    ProcessContentLine(L, Emitted);
  end;
  { A partial line outside a code block and a table — redraw it (the status ends
    up on the line below it). Inside a code block or a table we do not print it:
    the line comes out together with the group when the block is closed. A
    potential table line (starting with "|") is not shown either: it is drawn
    as a whole when the line break arrives. }
  if (FPending <> '') and (not FInCodeBlock) and (not FInTable) and
     (PendingText <> '') and (not IsTableStart(PendingText)) then
  begin
    ShowPartial;
    Emitted := True;
  end;
  if Emitted then
    PrintStatus(Status);
end;

procedure TStreamPrinter.EndStream(const Status: string);
begin
  if not FActive then
    Exit;
  if FLive then
  begin
    { An unfinished table line at the end of the stream — append it to the
      buffer so that it comes out together with the table. }
    if FInTable and (FPending <> '') and IsTableLine(PendingText) then
    begin
      FTableBuf := FTableBuf + sLineBreak + PendingText;
      FPending := '';
    end;
    { Unclosed table/code block at the end of the stream — print them out. }
    FlushTable;
    FlushCodeBlock;
    if FPending <> '' then
    begin
      { The last unfinished line stays on the screen, the cursor is on a clean
        line below it; the status is not drawn: it is temporary and is erased at
        once. }
      if PendingText <> '' then
        ShowPartial;
      FPending := '';
    end;
    { The status line is fully temporary: erase it so that the next output (the
      REPL prompt, static text) starts at the beginning of the line instead of
      sticking to the remains of the status. The Status parameter is kept for the
      callers — a finished stream no longer leaves its line. }
    if FStatusShown then
    begin
      ClearLine;
      FStatusShown := False;
    end;
  end
  else
  begin
    if FPending <> '' then
    begin
      WriteLn;   { finish the last line }
      FPending := '';
    end;
  end;
  FActive := False;
end;

procedure TStreamPrinter.PrepareStatic;
begin
  FBlankSeparated := False;
  if FLive then
  begin
    FlushTable;
    if FInCodeBlock and (FGroupBuf <> '') then
      EmitGroup(FGroupBuf);
    FInCodeBlock := False;
    FGroupBuf := '';
    if FPending <> '' then
    begin
      EmitCompleteLine(PendingText);   { print it out as a complete line }
      FPending := '';
    end;
    if FStatusShown then
    begin
      { The status line is temporary: erase it instead of leaving it in the
        scrollback. }
      ClearLine;
      FStatusShown := False;
    end;
  end
  else
  begin
    { Outside a terminal the text is written incrementally: finishing the
      unfinished line with a line break is enough. }
    if FPending <> '' then
    begin
      WriteLn;
      FPending := '';
    end;
  end;
  { The blank separator line (RequestBlankLine) is printed last: by now the
    status line is already erased (ClearLine above), so the separator takes its
    place and stays on the screen, and the output block starts under it. }
  EmitPendingBlank;
end;

{ A wrapper over PrepareStatic for the cases when the caller must not lose the
  status: the drawn status line is erased before preparing static output, and
  the caller redraws the status after printing the text (DrawStatus). By now
  PrepareStatic itself erases the status (ClearLine), so the wrapper remains for
  the explicit contract: "erase before the output, we draw the status
  ourselves". }
procedure TStreamPrinter.PrepareStaticOverStatus;
begin
  if FLive and FStatusShown then
  begin
    ClearLine;         { erase the drawn status — a line takes its place }
    FStatusShown := False;
  end;
  PrepareStatic;
end;

{ --------------------------------------------------------------- application }

constructor TMirmidApp.Create(const ACfg: TMirmidConfig);
begin
  inherited Create;
  FCfg := ACfg;
  FReg := TToolRegistry.Create;
  { The tool set of the session: the built-ins, subagent, http_request and
    revise_plan; which of them reach the request is decided by the [tools]
    section. }
  RegisterSessionTools(FReg, FCfg);
  FAgent := TAgent.Create(FCfg, FReg);
  FAgent.OnEvent := @OnAgentEvent;
  FAgent.OnSubAgentEvent := @OnAgentEvent;
  FPrinter := TStreamPrinter.Create;
  FNoSession := False;
  FShowReasoning := False;
  FShowStepTask := False;
  FShowStepResult := False;
  FToolStack := TStringList.Create;
  FSubAgentDepth := 0;
  FPrintDepth := 0;
  FSubAgentLabel := '';
  FCurrentStepName := '';
  SetLength(FSubSessionMarks, 0);
  FTokens := TContextTokens.Create;
  FMainContext := 0;
  FLastSummarizeEffective := False;
  FLastSummarizeSaving := 0;
  FJournalMsgs := 0;
  FMcp := nil;
  FPlanner := nil;
  { Planning mode: the planner and the revise_plan tool in the registry. }
  if FCfg.PlanMode then
  begin
    FPlanner := TPlanner.Create(FCfg, FReg);
    FPlanner.OnEvent := @OnAgentEvent;
    FPlanner.OnPlanChanged := @OnPlanChanged;
    RegisterRevisePlanTool(FReg, FPlanner);
  end;
  LoadMcp;
end;

{ Connects the MCP servers from mcp.json (when enabled and the file is found).
  Errors of individual servers do not abort the start — they are printed as
  warnings. }
procedure TMirmidApp.LoadMcp;
var
  Path: string;
  W: TStringList;
  I: Integer;
begin
  if not FCfg.McpEnabled then
    Exit;
  Path := FCfg.McpConfig;
  if Path <> '' then
    Path := ExpPath(Path, FCfg.WorkDir)
  else
    Path := DefaultMcpConfigPath(FCfg.WorkDir);
  if not FileExists(Path) then
    Exit;
  FMcp := TMCPManager.Create(FReg, FCfg.McpTimeout);
  W := TStringList.Create;
  try
    FMcp.LoadFromFile(Path, W);
    for I := 0 to W.Count - 1 do
      WriteWarning(W[I]);
  finally
    W.Free;
  end;
end;

destructor TMirmidApp.Destroy;
begin
  FAgent.Free;
  FPlanner.Free;
  FMcp.Free;
  FReg.Free;
  FPrinter.Free;
  FToolStack.Free;
  FTokens.Free;
  inherited Destroy;
end;

{ The context cache of the main session: it is recomputed from the agent history
  and the tool schemas only at the "before the request" and "after the turn"
  points, not on every stream portion (the estimate walks all messages). In
  planning mode this is the only source of the main value: the main session
  itself does not talk to the model and no aeContext with depth 0 arrives. }
procedure TMirmidApp.UpdateMainContext;
begin
  if FAgent = nil then
    Exit;
  FMainContext := FAgent.ContextTokens;
end;

{ The context of the main session for the status line. While the cache has never
  been taken (0) return the base from aeContext — these are the same tokens that
  came from the agent, so switching to the cache does not change the readings. }
function TMirmidApp.MainContextTokens: Integer;
begin
  if FMainContext > 0 then
    Result := FMainContext
  else
    Result := FTokens.MainTokens;
end;

{ The context status line after a turn in non-streaming mode: in a stream it is
  drawn and fixed by the stream printer (PersistStatus), so it is called only
  without streaming. Outside a terminal we stay silent (as in a stream). }
procedure TMirmidApp.PrintContextStatus;
begin
  if not IsTerminal(1) then
    Exit;
  WriteLn(Colored(C_STATUS,
    FormatContextStatus(FAgent.ContextTokens, EffectiveContextWindow(FCfg))));
end;

{ The final status line stays on the screen after a turn: in
  streaming mode the log gets the same line the printer drew under the answer
  (end-of-turn counters, the same colour), in non-streaming mode it was never
  drawn — print it ourselves. Outside a terminal both paths stay silent. }
procedure TMirmidApp.KeepContextStatus;
begin
  if FCfg.Stream then
    FPrinter.PersistStatus(StatusText)
  else
    PrintContextStatus;
end;

{ The context status for the current line: the size of the requested context (the
  agent sends it with the aeContext event) plus the tokens that arrived in this
  stream. A plan step sub-session is printed on its own line —
  "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%] name"
  (FormatStepStatus): the status and the step name replace "main session +
  label", the counters of the line are the context of the main session, of the
  step and the common model window. The main value comes from
  MainContextTokens: in planning mode the main session itself does not talk to
  the model and no aeContext with depth 0 arrives, so the agent estimate cache is
  needed. The preliminary analysis sub-session uses the same order:
  "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%] analysis"
  (FormatAnalysisStatus). A subagent nested in a step or in the analysis
  (depth > 1) keeps its former look: the main session, the label and the
  subagent counters are all visible. The subagent tool outside the planner — the
  status of the main session + the label ("subagent" by default) + the status of
  the sub-session (its part has no time, see FormatSubAgentStatus). }
function TMirmidApp.StepStatusText: string;
begin
  Result := FormatStepStatus(FCurrentStepName, FTokens.SubTokens,
    EffectiveContextWindow(FCfg), MainContextTokens);
end;

function TMirmidApp.StatusText: string;
begin
  if InStepSubSession and (FSubAgentDepth = 1) then
    Exit(StepStatusText);
  { The analysis sub-session has its own line, like a step: first the analysis
    status, then the "analysis" label (FormatAnalysisStatus); the main counter
    comes from the same source as the step line (MainContextTokens). A nested
    subagent (depth > 1) is not caught by the condition and is printed the
    former way, as inside a step. }
  if (FSubAgentLabel = 'analysis') and (FSubAgentDepth = 1) then
    Exit(FormatAnalysisStatus(FTokens.SubTokens,
      EffectiveContextWindow(FCfg), MainContextTokens));
  { The sub-session label ("step s1") arrives with the event; without a label the
    usual behaviour of the subagent tool ("subagent") applies. }
  if FSubAgentLabel <> '' then
    Result := FTokens.Text(EffectiveContextWindow(FCfg), FSubAgentDepth,
      FSubAgentLabel)
  else
    Result := FTokens.Text(EffectiveContextWindow(FCfg), FSubAgentDepth);
end;

{ The status line fixed after leaving a sub-session: for a step the
  label is short — "s1", without the task description that is needed only in the
  current step line; for the analysis the label is already "analysis"
  (FormatAnalysisStatus). The counters are the same as in StatusText at the
  moment of the call: before the depth and the stack are unwound they belong to
  the finished sub-session. }
function TMirmidApp.DoneStatusText: string;
begin
  if InStepSubSession and (FSubAgentDepth = 1) then
    Result := FormatStepStatus(StepShortName(FCurrentStepName),
      FTokens.SubTokens, EffectiveContextWindow(FCfg), MainContextTokens)
  else
    Result := StatusText;
end;

{ Fixing the done line of a finished sub-session:
  "…] analysis done", "…] s1 done". In an ANSI terminal the line is fixed by the
  stream printer: PersistStatus erases the drawn temporary line and prints the
  result. In a console without VT mode there is no drawn line, and in
  non-streaming mode there was none at all — print the line statically with the
  same WriteLn as the main status after a turn (PrintContextStatus).
  Headless/redirected output stays silent: there is no status line there, and
  the main status after a turn is not printed either. Thus the done line behaves
  the same with --no-stream and in streaming mode. Colored mutes the colours: in
  a console without ANSI the line comes out as plain text. }
procedure TMirmidApp.PersistDoneStatus;
var
  Line: string;
begin
  Line := DoneStatusText + Colored(C_USAGE, ' done');
  if FPrinter.Live then
    FPrinter.PersistStatus(Line)
  else if IsTerminal(1) then
    WriteLn(Line);
end;
{ Is a plan step sub-session running: the step name is set in aeStepStart and
  cleared in aeStepEnd, and the depth is greater than zero (entering the
  sub-session sends aeSubSessionStart with the "step sN" label). The text of such
  a session is the step answer; by default it is not printed. }
function TMirmidApp.InStepSubSession: Boolean;
begin
  Result := (FSubAgentDepth > 0) and (FCurrentStepName <> '');
end;

{ Is the analysis sub-session running: the label "analysis" arrives in
  aeSubSessionStart and the depth is exactly one (the planner drives the
  analysis from the top level). A deeper subagent keeps the usual printing, and
  the step sub-session ("step sN") is a different label. }
function TMirmidApp.InAnalysisSubSession: Boolean;
begin
  Result := (FSubAgentDepth = 1) and (FSubAgentLabel = 'analysis');
end;


procedure TMirmidApp.OnAgentEvent(Kind: TAgentEventKind; const Text: string);
var
  P, N: Integer;
  Name, Args, S, St: string;
  Pfx, Body: string;
  AvailWidth: Integer;
begin
  Pfx := FPrinter.Prefix;
  { Visible columns left for the text after the subagent prefix: a rendered
    markdown block must not overrun the terminal. At least one column, so the
    renderers never see a zero or negative width. }
  AvailWidth := TermWidth() - VisibleLen(Pfx);
  if AvailWidth < 1 then
    AvailWidth := 1;
  case Kind of
    aeStep:
      { Plan step text: no tag, in the step colour (C_STEP). }
      if FCfg.Verbose then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_STEP, Text));
      end;
    aePlan:
      { The plan with statuses: the [plan] tag and one line per step. }
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_STEP, '[plan]'));
        WriteLn(FPrinter.ApplyPrefix(Text));
      end;
    aeStepStart:
      { Start of a step: "s1: description" — without the [step] tag. The step
        name is remembered — the status line of the step sub-session prints
        "[time|…] name" by it (aeSubSessionStart carries only the short "step sN"
        label). Resolution of the task1 ambiguity: ONLY the line with the step
        name below is gated; the condition for showing the task is
        ShowStepTask or ShowReasoning (with both off the task is not visible;
        with --show-reasoning the task is printed regardless of
        --show-step-task). The name in the step status line stays always — that
        is why FCurrentStepName is assigned unconditionally, outside the display
        condition. --show-step-result does not apply to the step task: it is
        about the answer/result text of the step (aeStepEnd, the sub-session
        text — StepTextVisible, another condition), not about the task itself. }
      begin
        { The step name is needed by the status line always — assign it before
          the flag check, outside the task printing condition. }
        FCurrentStepName := Text;
        if StepTaskVisible(FShowStepTask, FShowReasoning, FShowStepResult) then
        begin
          FPrinter.PrepareStatic;
          WriteLn(Pfx + Colored(C_STEP, Text));
        end;
      end;
    aeStepEnd:
      { End of a step: the header plus the result. With --show-step-result or
        --show-reasoning the result is printed in full (shortened to
        TOOL_RESULT_MAX, see FormatStepEnd) — it is the step answer, and the step
        text itself is hidden at that moment only if the flags are off. With the
        flags off the answer is already hidden in aeAssistant/aeStreamText, so the
        step must still say what it produced: FormatStepEndBrief prints the header
        plus the first non-empty line of the result on one line (STEP_BRIEF_MAX
        columns). FormatStepEndStatus stays as the fallback of the bare header when
        the summary is not requested. The step name is not needed after it: the next
        status line starts with the main session. }
      begin
        FCurrentStepName := '';
        FPrinter.PrepareStatic;
        if StepTextVisible(FShowStepResult, FShowReasoning) then
          WriteLn(Pfx + Colored(C_STEP, FormatStepEnd(Text)))
        else if StepBriefVisible(FShowStepResult, FShowReasoning) then
          WriteLn(Pfx + Colored(C_STEP, FormatStepEndBrief(Text)))
        else
          WriteLn(Pfx + Colored(C_STEP, FormatStepEndStatus(Text)));
      end;
    aeReport:
      { The report: markdown rendering, as for aeAssistant. }
      if Trim(Text) <> '' then
      begin
        FPrinter.PrepareStatic;
        { The blank line before the report — only when the previous block did not
          leave it (a tool result). }
        if not FPrinter.BlankSeparated then
          WriteLn(Pfx);
        { The report is wrapped to the width left after the prefix. }
        WriteLn(FPrinter.ApplyPrefix(RenderMarkdown(Text, 1, AvailWidth)));
      end;
    aeAnalysis:
      { Preliminary analysis: the [analysis] tag and markdown rendering. }
      if Trim(Text) <> '' then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_STEP, '[analysis]'));
        { The analysis text is wrapped to the width left after the prefix. }
        WriteLn(FPrinter.ApplyPrefix(RenderMarkdown(Text, 1, AvailWidth)));
      end;
    aeLoopWarning:
      { Loop-guard: a yellow line about repeated tool calls (the text is the same
        as in the synthetic user message). }
      if Trim(Text) <> '' then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_WARN, '[loop]'), ' ', Text);
      end;
    aeReasoning:
      { Non-streaming mode: reasoning without a tag, green-grey, the markdown
        markup is stripped. The printing condition is the same as in
        aeStreamReasoning: the text is visible only with --show-reasoning
        (including in a step sub-session, since by default a step gives only the
        status line). }
      if FShowReasoning and (Trim(Text) <> '') then
      begin
        FPrinter.PrepareStatic;
        S := StripMarkdown(Trim(Text));
        WriteLn(FPrinter.ApplyPrefix(Colored(C_REASONING, S)));
      end;
    aeToolCall:
      { The tool name goes into the tag instead of the word "tool", the
        parameters (json) are light grey. On a subagent call the depth grows and
        the printer prefix is set. }
      begin
        FPrinter.PrepareStatic;
        FPrinter.ClearLine;
        { Take the status text here, before the depth and the counters change:
          StatusText after EnterSubAgent and the growth of FSubAgentDepth would
          return the empty subagent status (its context has not arrived with an
          aeContext event yet), and the line under the call would replace the
          parent status with zeros. }
        St := StatusText;
        Name := Text;
        Args := '';
        P := Pos(' ', Text);
        if P > 0 then
        begin
          Name := Copy(Text, 1, P - 1);
          Args := TrimRight(Copy(Text, P + 1, MaxInt));
        end;
        FToolStack.Add(Name);
        if Name = SUBAGENT_TOOL_NAME then
        begin
          { The token accounting depth and the print prefix depth grow together:
            the subagent tool is the only source of "│". }
          Inc(FSubAgentDepth);
          Inc(FPrintDepth);
          FPrinter.Prefix := DepthPrefix(FPrintDepth);
          Pfx := FPrinter.Prefix;
          { The subagent counters start from scratch: its context size arrives
            with the aeContext event before the first model request. }
          FTokens.EnterSubAgent;
        end;
        { Printing is gated: without --show-reasoning the tool call line is
          hidden in every session. The service part (FToolStack.Add,
          depth, ClearLine/DrawStatus) is done above and below in any case —
          otherwise the accounting and the detection of the subagent result
          would drift apart. }
        if ToolOutputVisible(FShowReasoning) then
        begin
          if Args <> '' then
            WriteLn(Pfx + Colored(C_TOOLCALL, '[' + Name + ']'), ' ',
              Colored(C_TOOLTEXT, Shorten(Args, 400)))
          else
            WriteLn(Pfx + Colored(C_TOOLCALL, '[' + Name + ']'));
        end;
        { The call line is printed statically (when printing is not hidden),
          and ClearLine above erased the status line: without a redraw the
          status disappears until the next stream portion (and for a tool
          without a text answer — until the end of the turn). Redraw it with the
          text St captured before the call; outside an ANSI terminal the method
          stays silent. }
        FPrinter.DrawStatus(St);
      end;
    aeShellCommand:
      { The command of the shell tool — only the command text with the "$ "
        prefix. }
      begin
        FPrinter.PrepareStatic;
        FPrinter.ClearLine;
        FToolStack.Add('shell');
        { Printing is gated exactly as in aeToolCall (ToolOutputVisible):
          without --show-reasoning the command line is hidden in every session.
          FToolStack.Add('shell') above runs unconditionally — by it aeToolResult
          finds the pair and does not confuse the result with a subagent. }
        if ToolOutputVisible(FShowReasoning) then
          WriteLn(Pfx + Colored(C_SHELLCMD, '$ ' + Text));
        { As in aeToolCall: the command line is printed statically, and ClearLine
          above erased the status line — redraw it under the command line,
          otherwise the status vanishes until the next event. Silent outside
          ANSI. }
        FPrinter.DrawStatus(StatusText);
      end;
    aeToolResult:
      { A tool result: the text is green and truncated by the number of lines;
        the subagent result is limited the same way (it is also a tool result;
        the full answer stays in the session file), with the depth prefix. The
        tool name comes from the stack (pop): a single shared "last name" was
        overwritten by the tools of the subagent itself, the subagent result was
        not recognized — the depth did not decrease, and the output of the main
        session continued with the prefix and the status of the subagent.
        Multi-line text is printed with the prefix on every line. }
      begin
        { Blank lines at the start and the end of the tool output are removed
          before truncation by the line limit: otherwise the limit is
          spent on blank lines and extra blank lines stay on the screen. The
          text is for printing only; in the history and in the session file the
          output stays as it is. }
        Body := TrimBlankLines(Text);
        Name := '';
        if FToolStack.Count > 0 then
        begin
          Name := FToolStack[FToolStack.Count - 1];
          FToolStack.Delete(FToolStack.Count - 1);
        end;
        if Name = SUBAGENT_TOOL_NAME then
        begin
          { The visibility of the result is gated exactly as the tool call
            (ToolOutputVisible): without --show-reasoning the subagent answer is
            hidden in every session. Removing the name from the stack, returning
            the depth/counters and redrawing the status below run
            unconditionally — gating does not affect the accounting and the
            detection of the subagent result. }
          if ToolOutputVisible(FShowReasoning) and (Body <> '') then
          begin
            { The result is printed in place of the drawn status line:
              PrepareStaticOverStatus erases it instead of freezing it as a line
              above (otherwise the old subagent status would remain between the
              tool call and its result). Truncation is the same as for the other
              tools (FCfg.ToolOutputLines, 9 by default, 0 — no limit): the
              subagent answer is also a tool result, otherwise it would flood
              the whole screen. The full text is not lost — it stays in the
              subagent session file and in the history. }
            FPrinter.PrepareStaticOverStatus;
            WriteLn(FPrinter.ApplyPrefix(Colored(C_RESULT,
              ShortenLinesMiddle(Body, FCfg.ToolOutputLines))));
            { A blank line after the tool output: the next block of
              information (the call of the next tool, the model answer, the done
              line) starts under a separator, not right against the result. The
              line is requested lazily — the start of the next block prints it. }
            FPrinter.RequestBlankLine;
          end;
          { The depth and the counters of the subagent are returned only if it
            was opened: a lone aeToolResult must not drive the depth below zero
            (after a failed step its unclosed pair is already removed by the
            unwinding). }
          if FSubAgentDepth > 0 then
          begin
            Dec(FSubAgentDepth);
            { The subagent counters must not overwrite the context size of the
              step it worked inside ("step → subagent"): restore the saved pair
              of the parent sub-session. }
            FTokens.ExitSubSession;
          end;
          { The print prefix lives separately from the token accounting depth and
            must not become negative when there was no matching aeToolCall. }
          if FPrintDepth > 0 then
            Dec(FPrintDepth);
          FPrinter.Prefix := DepthPrefix(FPrintDepth);
          { The status is redrawn already with the depth of the parent session
            (the subagent call looks like one call line plus the result); outside
            an ANSI terminal the method stays silent. }
          FPrinter.DrawStatus(StatusText);
        end
        else
        begin
          { A regular result: printing under the same gating as the call
            (ToolOutputVisible); the status is redrawn unconditionally — the
            status line could have been erased by the tool call, and outside an
            ANSI terminal the method stays silent. }
          if ToolOutputVisible(FShowReasoning) and (Body <> '') then
          begin
            { As for the subagent: the status line is erased, the result takes
              its place, the status is redrawn under the result. Truncation is by
              the number of lines (FCfg.ToolOutputLines, 9 by default): when it
              is exceeded the middle is cut with the "…" marker, the beginning
              and the end of the output stay visible. 0 — no limit. Blank lines
              at the top and the bottom are removed before truncation (Body, see
              the start of the aeToolResult branch). }
            FPrinter.PrepareStaticOverStatus;
            WriteLn(FPrinter.ApplyPrefix(Colored(C_RESULT,
              ShortenLinesMiddle(Body, FCfg.ToolOutputLines))));
            { A separator after the tool output, as in the subagent branch above. }
            FPrinter.RequestBlankLine;
          end;
          FPrinter.DrawStatus(StatusText);
        end;
      end;
    aeAssistant:
      { Non-streaming mode: the whole answer with markdown markup. In streaming
        mode the text is already printed line by line — do not duplicate it.
        The answer of a plan step sub-session is not printed at all: its result
        already arrives as the line "sN: status — result" in aeStepEnd, and the
        step text would be printed twice (task1: the step result is included by
        the --show-step-result/--show-reasoning flags and printed by aeStepEnd).
        A subagent nested in a step is hidden too: its answer arrives as the full
        tool result (aeToolResult), not as the step answer.
        The analysis sub-session is hidden for the same reason: its answer is
        printed exactly once, by the final output of the planner, so printing it
        here would duplicate it (InAnalysisSubSession, see also aeStreamText). }
      if not FCfg.Stream and not InStepSubSession and not InAnalysisSubSession
        and (Trim(Text) <> '') then
      begin
        FPrinter.PrepareStatic;
        { Print the blank line before the answer only when the previous block did
          not leave it itself (a tool result): otherwise two blank
          lines in a row would end up under the tool output. }
        if not FPrinter.BlankSeparated then
          WriteLn(Pfx);
        { The answer is wrapped to the width left after the prefix. }
        WriteLn(FPrinter.ApplyPrefix(RenderMarkdown(Text, 1, AvailWidth)));
      end;
    aeUsage:
      if FCfg.Verbose then
      begin
        FPrinter.PrepareStatic;
        WriteLn(Pfx + Colored(C_USAGE, '[' + Text + ']'));
      end;
    aeError:
      WriteError(Text);
    aeContext:
      { The context size (the agent estimate): the base of the status line. It
        arrives before the first request of the turn, after the answer is added
        to the history and after the tool results, so the base matches the actual
        context, also at the end of the turn. For a subagent it is its own
        history and prompt: before, the subagent base was 0 and the status showed
        only the tokens of the current answer. For the main session (depth 0) the
        context cache is refreshed as well: the main value in the step/analysis
        line stays fresh also after a sub-session whose turn the planner drove. }
      begin
        FTokens.SetBase(FSubAgentDepth, StrToIntDef(Text, 0));
        if FSubAgentDepth = 0 then
          UpdateMainContext;
      end;
    aeSubSessionStart:
      { Entering a planner sub-session (preliminary analysis, plan step): the
        event label ("analysis", "step s1") goes into the status line instead of
        "subagent", the token accounting depth grows (the sub-session has its own
        counters); the print prefix does not change — the "│" indent is given by
        the subagent tool only. The mark remembers the state before the entry, so
        the exit restores it even after an exception inside the step. }
      begin
        N := Length(FSubSessionMarks);
        SetLength(FSubSessionMarks, N + 1);
        FSubSessionMarks[N].Depth := FSubAgentDepth;
        FSubSessionMarks[N].PrintDepth := FPrintDepth;
        FSubSessionMarks[N].LabelText := FSubAgentLabel;
        FSubSessionMarks[N].Saved := FTokens.SavedCount;
        { The planner phases are started by the root session only, so printing
          starts at the top level: the prefix counter is zeroed. Then the step
          line goes without an indent, and the subagent tool nested in the step
          gets exactly one "│" — even if a previous subagent stayed unclosed (a
          lost aeToolResult) and the counter leaked here. The base level is kept
          in the mark and returns on aeSubSessionEnd. }
        FPrintDepth := 0;
        FPrinter.Prefix := '';
        Inc(FSubAgentDepth);
        FSubAgentLabel := Text;
        FTokens.EnterSubAgent;
      end;
    aeSubSessionEnd:
      { Leaving a planner sub-session: the status line (including the step label)
        is fixed in the log with the "done" mark — by it one can see how much
        context a finished sub-session took. Then the depth, the label
        and the counter stack return to the entry mark: everything left from an
        unclosed subagent or revise_plan is dropped, and the step values do not
        leak into the next step or the main session. A subagent nested in a step
        does not change the label: its events arrive as aeToolCall/aeToolResult,
        not as aeSubSession*; its counters are popped at aeToolResult. }
      begin
        { The status line is not erased but fixed: DoneStatusText is taken here
          while the sub-session counters and its label are still intact, so the
          scrollback gets the line with the final numbers of the finished step
          ("…] s1 done") or analysis ("…] analysis done"). The "done" mark is
          grey, like the step name and "analysis". The way of printing is chosen
          in PersistDoneStatus: an ANSI terminal fixes the drawn line, the
          non-streaming mode and a console without VT mode print it statically
          (otherwise the done line would be lost in --no-stream), headless stays
          silent. }
        PersistDoneStatus;
        N := Length(FSubSessionMarks);
        if N > 0 then
        begin
          Dec(N);
          if FSubSessionMarks[N].Depth = 0 then
            { An outer exit: the pair and everything accumulated is garbage. }
            FTokens.ResetSubSession
          else
            FTokens.UnwindTo(FSubSessionMarks[N].Saved);
          FSubAgentDepth := FSubSessionMarks[N].Depth;
          { The print prefix returns to the entry mark: an unclosed subagent
            inside the step leaves no extra "│" for the next line. }
          FPrintDepth := FSubSessionMarks[N].PrintDepth;
          FSubAgentLabel := FSubSessionMarks[N].LabelText;
          { Outside a step the step name is not needed in the status line:
            otherwise a turn failing before aeStepEnd would leave it for the next
            line. }
          if FSubAgentDepth = 0 then
            FCurrentStepName := '';
          SetLength(FSubSessionMarks, N);
        end
        else
        begin
          { An event without a matching start: the previous behaviour — drop one
            sub-session, clear the label when returning to the top level. }
          if FSubAgentDepth > 0 then
            Dec(FSubAgentDepth);
          FTokens.ExitSubSession;
          if FSubAgentDepth = 0 then
          begin
            FSubAgentLabel := '';
            FCurrentStepName := '';
          end;
        end;
        { Leaving a planner sub-session does not change the print prefix: "│"
          belongs to the subagent tool only. }
        FPrinter.Prefix := DepthPrefix(FPrintDepth);
      end;
    aeStreamStart:
      FPrinter.BeginStream(StatusText);
    aeStreamText:
      begin
        { The answer tokens are always accounted — the status reflects the whole
          context. The answer text of a plan step sub-session is printed only
          under --show-step-result or --show-reasoning: by default a step gives
          only the status line, and its result (also under the flags) is the line
          "sN: done — result" in aeStepEnd. The analysis sub-session is hidden
          unconditionally — its answer is printed once by the final output of the
          planner (InAnalysisSubSession, see also aeAssistant). Hidden text must
          not get stuck in the printer buffer: redraw the status instead of
          FeedContent. }
        FTokens.AddResponseTokens(FSubAgentDepth, (CountUTF8Chars(Text) + 3) div 4);
        if InAnalysisSubSession or
           (InStepSubSession and not StepTextVisible(FShowStepResult, FShowReasoning))
        then
        begin
          if Text <> '' then
            FPrinter.RefreshStatus(StatusText);
        end
        else
          FPrinter.FeedContent(Text, StatusText);
      end;
    aeStreamReasoning:
      begin
        { The reasoning tokens are always accounted — the status reflects the
          whole context (including the context of a plan step: the sub-session
          counters are kept separately by FSubAgentDepth). Printing the text is
          only under --show-reasoning. }
        FTokens.AddResponseTokens(FSubAgentDepth, (CountUTF8Chars(Text) + 3) div 4);
        if FShowReasoning then
          FPrinter.FeedReasoning(Text, StatusText)
        else if Text <> '' then
          { The reasoning text is hidden by the setting, but the tokens are
            already accounted: without a status line redraw they would not appear
            on the screen until the first piece of the answer (and for an answer
            without text — never). An empty portion does not change the counters,
            so there is nothing to redraw. }
          FPrinter.RefreshStatus(StatusText);
      end;
    aeStreamEnd:
      FPrinter.EndStream(StatusText);
  end;
end;

procedure TMirmidApp.LoadOrNewSession(out Plan: TPlan);
var
  Err: string;
  Msgs: TMessages;
begin
  Plan := nil;
  if FSessionId = '' then
    FSessionId := NewSessionId
  else if LoadSession(SessionDir(FCfg.WorkDir), FSessionId, Msgs, Plan, Err) and
           (Length(Msgs) > 0)
  then
  begin
    FAgent.Messages := Msgs;
    { The loaded history was already in the context before, so it is not
      counted in the "part" of the first journal record. }
    FJournalMsgs := Length(Msgs);
    { Hand the loaded plan to the planner (when it is created). }
    if (FPlanner <> nil) and (Plan <> nil) then
    begin
      FPlanner.Plan := Plan;
      Plan := nil;
    end;
  end;
end;

{ The plan changed (new plan, step status, revise_plan) — save the session. }
procedure TMirmidApp.OnPlanChanged;
begin
  SaveCurrentSession;
end;

procedure TMirmidApp.SaveCurrentSession;
var
  Err: string;
  P: TPlan;
  I, Ctx, Part: Integer;
  R: TPersistResult;
begin
  try
    { The plan (when the planner is created) is saved together with the
      session. }
    P := nil;
    if FPlanner <> nil then
      P := FPlanner.Plan;
    { Ctx is the full context size, Part is the tokens of the messages added
      since the previous journal record. Under --no-session there is nothing to
      save: the helper returns prSkipped and creates neither a session file nor
      a journal file. }
    Ctx := FAgent.ContextTokens;
    Part := 0;
    for I := FJournalMsgs to High(FAgent.Messages) do
      Inc(Part, MessageTokens(FAgent.Messages[I]));
    R := SaveSessionWithJournal(FCfg.WorkDir, FSessionId, FCfg.Model,
      FAgent.Messages, P, FNoSession, Ctx, Part, Err);
    case R of
      prSkipped:
        ; { --no-session: FJournalMsgs stays as it is — nothing was written. }
      prSessionFailed:
        WriteWarning('could not save the session: ' + Err);
      prJournalFailed:
        begin
          { The session was saved, so part of the context is already reflected
            in the session file — the next journal record starts after it. }
          FJournalMsgs := Length(FAgent.Messages);
          WriteWarning('could not write the context journal: ' + Err);
        end;
      prOk:
        FJournalMsgs := Length(FAgent.Messages);
    end;
  except
    { A write failure must not mask the original turn error (the
      session is saved even after an error or an exception). }
    on E: Exception do
      WriteWarning('could not save the session: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ Asks the host (LLM server) for the model context. When the host reports a
  value it is stored in FCfg.HostContextWindow. Errors are not fatal. }
procedure TMirmidApp.FetchHostContext;
var
  Client: TLLMClient;
  Models: TModelList;
  Err: string;
  I: Integer;
begin
  if FCfg.Model = '' then
    Exit;
  Client := TLLMClient.Create(FCfg);
  try
    if not Client.FetchModelList(Models, Err) then
      Exit;
    for I := Low(Models) to High(Models) do
    begin
      if LowerCase(Models[I].Id) = LowerCase(FCfg.Model) then
      begin
        FCfg.HostContextWindow := EffectiveContext(Models[I]);
        Break;
      end;
    end;
  finally
    Client.Free;
  end;
end;

{ Summarization of the current session: creates a new session with the
  summary. Called by a user command or automatically. }
procedure TMirmidApp.DoSummarize;
var
  Res: TSummarizeResult;
  Err: string;
  NewMsgs: TMessages;
  P: TPlan;
  NewId: string;
  Saving: Integer;
begin
  if FNoSession then
  begin
    WriteWarning('summarization is unavailable: --no-session mode');
    Exit;
  end;
  if Length(FAgent.Messages) <= 1 then
  begin
    WriteWarning('summarization: nothing to summarize (the dialog is empty)');
    Exit;
  end;

  FPrinter.PrepareStatic;
  WriteLn(Colored(C_USAGE, 'Summarizing the session...'));

  if not SummarizeSession(FCfg, FAgent.Messages, Res, Err) then
  begin
    WriteError('summarization failed: ' + Err);
    Exit;
  end;

  Saving := Res.TokensBefore - Res.TokensAfter;
  FLastSummarizeEffective := Res.Effective;
  FLastSummarizeSaving := Saving;

  { Create a new session with the summary. }
  NewId := NewSessionId;
  NewMsgs := BuildSummarizedMessages(FCfg, Res.Summary);
  FAgent.Messages := NewMsgs;
  FSessionId := NewId;
  { The base name of the auxiliary session files follows the new session id. }
  FAgent.SessionBase := NewId;
  if FPlanner <> nil then
    FPlanner.SessionBase := NewId;

  { Save the new session. }
  P := nil;
  if FPlanner <> nil then
    P := FPlanner.Plan;
  if not SaveSession(SessionDir(FCfg.WorkDir), FSessionId, FCfg.Model,
    FAgent.Messages, P, Err)
  then
    WriteWarning('could not save the new session: ' + Err);

  if Res.Effective then
    WriteLn(Colored(C_RESULT,
      Format('Session summarized: %s → %s (saved %d tokens, new session %s)',
        [CompactNumber(Res.TokensBefore), CompactNumber(Res.TokensAfter),
         Saving, FSessionId])))
  else
  begin
    { A bright red warning: summarization did not shrink the context enough. }
    WriteLn(StdErr, Colored('91',
      Format('Warning: summarization shrank the context by less than %d%% ' +
        '(saved %d tokens). The current session cannot be shrunk any further.',
        [FCfg.SummarizeMinSavingPercent, Saving])));
  end;
end;

{ Auto-summarization: checks the context fill threshold. It fires when the
  context is at or above the threshold AND the previous summarization saved
  less than 50% (or there was no summarization at all). }
procedure TMirmidApp.CheckAutoSummarize;
var
  Threshold: Integer;
  Cur: Integer;
begin
  Threshold := SummarizeThreshold(FCfg);
  if Threshold <= 0 then
    Exit;
  Cur := FAgent.ContextTokens;
  if Cur < Threshold then
    Exit;
  { If the previous summarization was effective, do not repeat it. }
  if FLastSummarizeEffective then
    Exit;
  DoSummarize;
end;

function TMirmidApp.RunOne(const Prompt: string): Integer;
var
  FinalText, Err: string;
  Msgs: TMessages;
  M: TMessage;
  N: Integer;
  Ok: Boolean;
begin
  { One turn: the prompt goes into the history at once. The session is saved in
    any case — after a model error (for example "HTTP 400 Bad Request") and
    after an exception inside the turn: otherwise the history of a
    failed turn is lost and there is nothing to investigate. }
  Result := 1;
  Ok := False;
  FAgent.AddUser(Prompt);
  { The context cache of the main session — before the request: in planning
    mode the planner drives the turn, no aeContext with depth 0 arrives at that
    time, and the analysis and step lines need the main value
    (main/sub/total format). Right after the turn the cache is refreshed once
    more — the answer and the report were added to the history. }
  UpdateMainContext;
  try
    try
      if FCfg.PlanMode then
      begin
        { Planning mode: plan → steps → report. }
        if FPlanner.RunPlannedTurn(Prompt, FAgent.Messages, FinalText, Err) then
        begin
          { The report is an assistant message in the session history. }
          Msgs := FAgent.Messages;
          M := MakeMessage(mrAssistant, FinalText);
          N := Length(Msgs);
          SetLength(Msgs, N + 1);
          Msgs[N] := M;
          FAgent.Messages := Msgs;
          Ok := True;
        end
        else
          { The planner does not emit aeError — print the error ourselves. }
          WriteError(Err);
      end
      else if FAgent.RunTurn(FinalText, Err) then
        { The turn error is printed by the aeError event. }
        Ok := True;

      if Ok then
      begin
        { The context cache of the main session — after the turn: the model
          answer and (in planning mode) the report were added to the history. }
        UpdateMainContext;
        { The final status line stays on the screen after the turn. }
        KeepContextStatus;
        CheckAutoSummarize;
      end;
    except
      on E: Exception do
      begin
        { An exception inside the turn does not kill the session: print the
          reason and go on — the session save below runs in any case. }
        FPrinter.PrepareStatic;
        WriteError('exception while running the turn: ' + E.ClassName + ': ' +
          E.Message);
      end;
    end;
  finally
    SaveCurrentSession;
  end;
  if Ok then
    Result := 0;
end;

procedure TMirmidApp.Repl;
var
  Line, Cmd, Arg, V: string;
begin
  WriteLn(Output, MIRMID_NAME, ' ', MIRMID_VERSION, ' — model: ', FCfg.Model,
    ' @ ', FCfg.BaseUrl);
  WriteLn(Output, 'Tools: ', FReg.Names);
  if (FMcp <> nil) and (FMcp.ToolCount > 0) then
    WriteLn(Output, 'MCP: ', FMcp.ServerList, ' — tools: ', FMcp.ToolCount);
  WriteLn(Output, 'Session: ', FSessionId, '   (/help — help, /exit — quit)');
  while true do
  begin
    { First erase the temporary status line (PrepareStatic clears it through
      ClearLine and flushes the tail of the unfinished line), and only then
      print the prompt: it starts on a clean line and does not stick to the
      remains of the status. }
    FPrinter.PrepareStatic;
    Write(Output, Colored(C_PROMPT, '|> '));
    Flush(Output);
    if EOF(Input) then
      break;
    ReadLn(Input, Line);
    Line := Trim(Line);
    if Line = '' then
      Continue;
    if Line[1] = '/' then
    begin
      Cmd := Line;
      Arg := '';
      if Pos(' ', Line) > 0 then
      begin
        Cmd := Copy(Line, 1, Pos(' ', Line) - 1);
        Arg := Trim(Copy(Line, Pos(' ', Line) + 1, MaxInt));
      end;
      if (Cmd = '/exit') or (Cmd = '/quit') or (Cmd = '/q') then
        Break
      else if Cmd = '/help' then
        WriteLn('Commands: /help, /exit, /reset, /tools, /mcp, /model NAME, ',
          '/system TEXT, /reasoning [MODE], /session, /plan, /history, ',
          '/summarize')
      else if Cmd = '/reset' then
      begin
        FAgent.Reset;
        { The main session cache: after clearing the history the context is
          only the system prompt and the tool schemas. }
        UpdateMainContext;
        WriteLn('Dialog cleared.');
      end
      else if Cmd = '/tools' then
        WriteLn(FReg.Names)
      else if Cmd = '/mcp' then
      begin
        if FMcp = nil then
          WriteLn('No MCP servers connected.')
        else if FMcp.ToolCount = 0 then
          WriteLn('MCP servers: ', FMcp.ServerList, ' (no tools)')
        else
        begin
          WriteLn('MCP servers: ', FMcp.ServerList);
          WriteLn(FMcp.ToolList);
        end;
      end
      else if Cmd = '/model' then
      begin
        if Arg <> '' then
        begin
          FCfg.Model := Arg;
          FAgent.Config := FCfg;
          WriteLn('Model: ', FCfg.Model);
        end
        else
          WriteLn('Current model: ', FCfg.Model);
      end
      else if Cmd = '/system' then
      begin
        FCfg.SystemPrompt := Arg;
        FAgent.Config := FCfg;
        FAgent.Reset;
        WriteLn('System prompt updated, dialog cleared.');
      end
      else if Cmd = '/reasoning' then
      begin
        if Arg = '' then
        begin
          if FCfg.Reasoning = '' then
            WriteLn('Reasoning mode: not set (provider default)')
          else
            WriteLn('Reasoning mode: ', FCfg.Reasoning);
        end
        else
        begin
          V := NormalizeReasoning(Arg);
          if V = '' then
            WriteLn('Unknown mode: ', Arg,
              ' (none, minimal, low, medium, high)')
          else
          begin
            FCfg.Reasoning := V;
            FAgent.Config := FCfg;
            WriteLn('Reasoning mode: ', V);
          end;
        end;
      end
      else if Cmd = '/session' then
        WriteLn(FSessionId)
      else if Cmd = '/plan' then
      begin
        { The current plan (planning mode) or "no plan". }
        if (FPlanner <> nil) and (FPlanner.Plan <> nil) then
          WriteLn(FPlanner.Plan.Render)
        else
          WriteLn('no plan');
      end
      else if Cmd = '/history' then
        WriteLn('Messages: ', Length(FAgent.Messages))
      else if Cmd = '/summarize' then
        DoSummarize
      else
        WriteLn('Unknown command: ', Cmd);
      Continue;
    end;
    RunOne(Line);
  end;
  SaveCurrentSession;
  WriteLn('Goodbye.');
end;

function TMirmidApp.Execute(const Cli: TCli): Integer;
var
  Prompt, Err: string;
  Plan: TPlan;
begin
  FNoSession := Cli.NoSession;
  FShowReasoning := Cli.ShowReasoning;
  FShowStepTask := Cli.ShowStepTask;
  FShowStepResult := Cli.ShowStepResult;
  FSessionId := Cli.SessionId;

  if Cli.ListSessions then
  begin
    if ListSessions(SessionDir(FCfg.WorkDir), Prompt) then
    begin
      if Prompt = '' then
        WriteLn('(no sessions yet)')
      else
        Write(Prompt);
    end
    else
      WriteError('could not list sessions');
    Exit(0);
  end;

  if Cli.PromptFile <> '' then
  begin
    if not ReadTextFile(Cli.PromptFile, Prompt, Err) then
    begin
      WriteError('could not read ' + Cli.PromptFile + ': ' + Err);
      Exit(2);
    end;
  end
  else
    Prompt := Cli.Prompt;

  LoadOrNewSession(Plan);
  { Free it when the plan was not handed to the planner (no planning mode). }
  Plan.Free;

  { Base name of the auxiliary session files (subagents, plan steps): the id
    of the main session; it is empty under --no-session, so they are not
    saved. }
  if not FNoSession then
  begin
    FAgent.SessionBase := FSessionId;
    if FPlanner <> nil then
      FPlanner.SessionBase := FSessionId;
  end;

  { Ask the host for the model context (for the effective context window). }
  FetchHostContext;

  { In interactive mode (the -i flag or a REPL without a prompt) the planner
    ends its turn after planning: the steps run on the next user command. }
  if FPlanner <> nil then
    FPlanner.Interactive := Cli.Interactive or (Prompt = '');

  if Cli.Interactive or ((Prompt = '') and (not Cli.ListModels)) then
  begin
    { The interactive mode is cyclic: a prompt given on the command line runs
      as the first turn, then the REPL continues the loop. }
    if (Cli.Interactive) and (Prompt <> '') then
      RunOne(Prompt);
    Repl;
    Exit(0);
  end;

  if Prompt = '' then
  begin
    WriteLn(StdErr, 'No prompt given. See mirmid --help');
    Exit(2);
  end;

  Result := RunOne(Prompt);
end;

{ Connects the MCP servers and prints their tools (for --list-mcp). }
function ListMcpTools(const Cfg: TMirmidConfig): Integer;
var
  Reg: TToolRegistry;
  Mcp: TMCPManager;
  Path: string;
  W: TStringList;
  I: Integer;
begin
  Path := Cfg.McpConfig;
  if Path <> '' then
    Path := ExpPath(Path, Cfg.WorkDir)
  else
    Path := DefaultMcpConfigPath(Cfg.WorkDir);
  if not FileExists(Path) then
  begin
    WriteError('MCP config file not found: ' + Path);
    Exit(1);
  end;
  Reg := TToolRegistry.Create;
  Mcp := TMCPManager.Create(Reg, Cfg.McpTimeout);
  W := TStringList.Create;
  try
    Mcp.LoadFromFile(Path, W);
    for I := 0 to W.Count - 1 do
      WriteWarning(W[I]);
    if Mcp.ToolCount = 0 then
      WriteLn('No MCP tools found.')
    else
    begin
      WriteLn('MCP servers: ', Mcp.ServerList);
      WriteLn(Mcp.ToolList);
    end;
    Result := 0;
  finally
    W.Free;
    Mcp.Free;
    Reg.Free;
  end;
end;

{ ------------------------------------------------------------------- main }

function Main: Integer;
var
  Cli: TCli;
  Cfg: TMirmidConfig;
  WorkDir, Err, Models: string;
  App: TMirmidApp;
  Client: TLLMClient;
  Args: array of string;
  I: Integer;
begin
  Err := '';
  SetLength(Args, ParamCount);
  for I := 0 to ParamCount - 1 do
    Args[I] := ParamStr(I + 1);
  if not ParseCli(Args, Cli, Err) then
  begin
    WriteError(Err);
    WriteLn(StdErr, 'See mirmid --help');
    Exit(2);
  end;

  if Cli.ShowHelp then
  begin
    WriteLn(USAGE);
    Exit(0);
  end;

  if Cli.ShowVersion then
  begin
    WriteLn(FullVersion);
    Exit(0);
  end;

  WorkDir := Cli.WorkDir;
  { An unknown key in [tools] (and any other unusable setting) is a fatal
    error before the session starts: print the reason and exit with code 1. }
  if not ResolveConfig(Cli, Cfg, WorkDir, Err) then
  begin
    WriteError(Err);
    Exit(1);
  end;

  if Cli.DoInit then
    begin
      if SaveSampleIni(ProjectConfigPath(WorkDir), Cfg, Err) then
        WriteLn('Created file: ', ProjectConfigPath(WorkDir))
      else
      begin
        WriteError(Err);
        Exit(1);
      end;
      Exit(0);
    end;

  { Diagnostics of the trust root snapshot are printed once per process,
    before the first HTTPS request (-v prints them too when the snapshot is
    fresh). The --init branch above has already exited: generating the INI does
    not use the network. }
  WarnEmbeddedRoots(Cfg);

  if Cli.ListModels then
    begin
      Client := TLLMClient.Create(Cfg);
      try
        if Client.ListModels(Models, Err) then
          Write(Models)
        else
        begin
          WriteError(Err);
          Exit(1);
        end;
      finally
        Client.Free;
      end;
      Exit(0);
    end;

    if Cli.ListMcp then
    begin
      Result := ListMcpTools(Cfg);
      Exit;
    end;

  App := TMirmidApp.Create(Cfg);
  try
    try
      Result := App.Execute(Cli);
    except
      on E: Exception do
      begin
        { An exception outside a turn (REPL, commands, planner) must not leave
          the session unsaved: print the reason and save the history already
          accumulated in the session. }
        WriteError('exception: ' + E.ClassName + ': ' + E.Message);
        App.SaveCurrentSession;
        Result := 1;
      end;
    end;
  finally
    App.Free;
  end;
end;

end.
