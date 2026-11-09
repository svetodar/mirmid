unit test_cli;
{ Regression of the CLI event formatting: FormatStepEnd (aeStepEnd) must not
  leave a "broken" byte of the UTF-8 separator " — " and shortens only the
  result. No network. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TCliFormatTests = class(TTestCase)
  published
    { The separator " — " is 5 bytes; earlier the result started at P + 3 and a
      tail byte of the dash got into the output. }
    procedure TestStepEndKeepsUtf8Separator;
    { No separator — the text is returned unchanged. }
    procedure TestStepEndNoSeparator;
    { A long result is shortened, the "s1: done" header is preserved. }
    procedure TestStepEndShortensResult;
  end;

  TCliSubAgentOutputTests = class(TTestCase)
  published
    { DepthPrefix(0) — an empty string (the root session). }
    procedure TestDepthPrefixZero;
    { DepthPrefix(1) — one grey │ character. }
    procedure TestDepthPrefixOne;
    { DepthPrefix(2) — two │ characters. }
    procedure TestDepthPrefixTwo;
    { FormatContextStatus: the format [time|current/total|percent%]. }
    procedure TestFormatContextStatus;
    { FormatContextStatus: Total=0 — an unknown total size. }
    procedure TestFormatContextStatusUnknownTotal;
    { FormatContextStatus with WithTime = False — no time (the subagent part). }
    procedure TestFormatContextStatusNoTime;
    { The percentage in the status line: rounded to 0.1 without the locale,
      '?' for an unknown model window size. }
    procedure TestFormatContextStatusPercent;
    { FormatSubAgentStatus: only the main session part prints the time. }
    procedure TestSubAgentStatusTimeOnlyInMainPart;
    { FormatSubAgentStatus with a label: "subagent" is replaced by the
      sub-session label. }
    procedure TestSubAgentStatusCustomLabel;
    { FormatAnalysisStatus: "[HH:MM:SS|main/sub/total|main-percent%/
      sub-percent%] analysis" — the analysis status first, the label second;
      there is no [analysis] tag, the percentages are counted from the common
      model window. }
    procedure TestFormatAnalysisStatus;
    { FormatAnalysisStatus with the main session context (MainCur > 0): the line
      has three counters and two percentages, as in the step line. }
    procedure TestFormatAnalysisStatusWithMain;
  end;

  { The plan step line: "[HH:MM:SS|main/sub/total|main-percent%/
    sub-percent%] name". The status comes first, then the name; there is one
    clock in the line, the step has no │ prefix and no [step] tag either. }
  TCliStepOutputTests = class(TTestCase)
  published
    { The format: the status of the step context, then the step name (no tag). }
    procedure TestFormatStepStatus;
    { main/sub/total: both counters in the line, two percentages of the common
      window. }
    procedure TestFormatStepStatusMainCounters;
    { MainCur is not passed (the parent context has not been measured) — main =
      0. }
    procedure TestFormatStepStatusWithoutMain;
    { An empty step name — only the status remains, without a trailing space. }
    procedure TestFormatStepStatusEmptyName;
    { The step sub-session is printed at zero depth: there is no │ prefix. }
    procedure TestFormatStepStatusNoDepthPrefix;
    { StepShortName: "s1: description" -> "s1" for the fixed done line. }
    procedure TestStepShortName;
  end;

  { Gating of the plan step text: the text of the step sub-session and its
    result are printed only under --show-step-result or --show-reasoning. All
    four flag combinations are checked. }
  TCliStepGatingTests = class(TTestCase)
  published
    { No flag — the step text is hidden (only the status lines are visible). }
    procedure TestStepTextHiddenByDefault;
    { Only --show-step-result — the step text is visible. }
    procedure TestStepTextShownByStepResult;
    { Only --show-reasoning — the step text is visible too. }
    procedure TestStepTextShownByReasoning;
    { Both flags — the visibility is the same (a disjunction, not XOR). }
    procedure TestStepTextShownByBoth;
  end;

  { Gating of the plan step task — the "[step] name" lines (aeStepStart): they
    are printed only under --show-step-task or --show-reasoning, with both off
    they are not printed (the name stays in the status line).
    --show-step-result does not apply to the task: it is about the answer text
    and the step result. All eight combinations of the three flags are
    iterated. }
  TCliStepTaskGatingTests = class(TTestCase)
  published
    { All eight combinations: the visibility = ShowStepTask or ShowReasoning. }
    procedure TestAllFlagCombinations;
    { No flag — the task is not printed (the default value is off). }
    procedure TestTaskHiddenByDefault;
    { Only --show-reasoning — the task is printed (regardless of
      --show-step-task). }
    procedure TestTaskShownByReasoningOnly;
    { Only --show-step-task — the task is printed. }
    procedure TestTaskShownByStepTaskOnly;
    { A single --show-step-result — the task is hidden anyway: the flag relates
      to the step text/result (StepTextVisible), not to the task. }
    procedure TestStepResultDoesNotShowTask;
    { --show-step-result does not prevent the showing when the task is enabled
      by another flag. }
    procedure TestStepResultIgnoredWhenTaskShown;
  end;

  { Gating of the tool output (the "[name] arguments", "$ command" lines and the
    aeToolResult results): task2.md — the output is printed only together with
    the reasoning (--show-reasoning), regardless of whether it is the main
    session, a subagent sub-session or a planner sub-session ("analysis",
    "step sN"). }
  TCliToolOutputGatingTests = class(TTestCase)
  published
    { Without --show-reasoning the tool output is hidden in any session. }
    procedure TestHiddenByDefault;
    { A single --show-reasoning enables the tool output. }
    procedure TestShownByReasoning;
  end;

  { Parsing of --tool-output-lines (the limit of the tool output lines: 9 by
    default, 0 — no limit). Only ParseCli is checked — no network, INI or
    environment; carrying the value over to the settings (ResolveConfig)
    depends on the configuration file and the host variables, so it is not
    touched here. }
  TCliParseToolOutputLinesTests = class(TTestCase)
  published
    { Without the flag: HasToolOutputLines = False, the value is 0 (the limit
      comes from the settings; FillChar zeroes the TCli record). }
    procedure TestDefaultOff;
    { The form with a separate argument: --tool-output-lines 15. }
    procedure TestSpaceForm;
    { The form --tool-output-lines=12 (the value after "="). }
    procedure TestInlineForm;
    { Zero — an explicit "no limit", the key counts as set. }
    procedure TestZeroMeansUnlimited;
    { No value — a parse error, Err is not empty, the key is not set. }
    procedure TestMissingValue;
    { The flag does not interfere with the parsing of the neighbouring options
      and the prompt: the other fields (ShowReasoning, Prompt) are preserved. }
    procedure TestAlongsideOtherOptions;
  end;


  { The context size for the status line: EffectiveContextWindow takes the
    minimum of the configured value and the value reported by the host (the LLM
    server), so that the percentages are not counted from an inflated size. }
  TEffectiveContextWindowTests = class(TTestCase)
  published
    { The host did not report a size (0) — the ContextWindow from the settings
      is used. }
    procedure TestHostUnsetUsesConfig;
    { The host reported a smaller size — that one is taken. }
    procedure TestHostSmallerWins;
    { The host reported a larger size — the settings value remains. }
    procedure TestHostLargerIgnored;
    { Equal values and a negative host value — the settings value. }
    procedure TestEqualAndNegativeHost;
  end;
  { Accounting of the status line tokens (regression of a defect: the subagent
    context size was wrong — the base was taken as 0). }
  TContextTokensTests = class(TTestCase)
  published
    { The subagent base comes from aeContext, not 0. }
    procedure TestSubAgentBaseFromContext;
    { The answer tokens of the main session and the subagent are not mixed. }
    procedure TestMainAndSubAccumSeparate;
    { Regression: the reasoning tokens at Depth > 0 are always counted — in
      portions, before the first aeContext and in the sub-session line (a plan
      step). }
    procedure TestReasoningTokensDepthGreaterZero;
    { Entering a subagent resets the counters of the previous subagent. }
    procedure TestEnterSubAgentResets;
    { The main session shows only one status part (no "subagent"). }
    procedure TestMainStatusHasNoSubPart;
    { MainTokens: the main session context (the base + the answer tokens) — the
      step/analysis line needs it in the main/sub/total format. }
    procedure TestMainTokensAccessor;
    { The sub-session label in Text: "subagent" is replaced by the passed
      label. }
    procedure TestTextCustomLabel;
    { The analysis line is built from the sub-session counters (SubTokens) and
      the main session context (MainTokens), as the step line; there is no
      [analysis] tag, the percentages are counted from the common model
      window. }
    procedure TestAnalysisLineMainAndSubCounters;
    { Leaving a nested sub-session restores the parent counters. }
    procedure TestExitSubSessionRestoresParent;
    { The counter stack: SavedCount grows on entering and drops on leaving. }
    procedure TestSavedCountTracksDepth;
    { UnwindTo removes the unclosed nested sub-sessions, keeping the parent. }
    procedure TestUnwindToRestoresParent;
    { ResetSubSession clears the counters and the stack (a step failure,
      revise_plan). }
    procedure TestResetSubSessionClears;
    { Leaving without entering — a simple zeroing. }
    procedure TestExitWithoutEnterZeroes;
  end;
  { The command line contract after the move to the [tools] section: the help
    describes the key model and contains no removed flags, and the removed flags
    themselves are rejected by the parser as unknown. }
  TCliToolsModelTests = class(TTestCase)
  published
    { The help has the [tools] section and no --allow-write/--no-write,
      --allow-shell/--no-shell, --allow-http/--no-http. }
    procedure TestHelpMentionsToolsSection;
    { The help has no mentions of the removed trust settings. }
    procedure TestHelpHasNoCaFile;
    { The removed flags are a parse error ("unknown option"). }
    procedure TestRemovedFlagsRejected;
  end;

  { Saving the main session after a failed turn (task2.md). An integration test
    against the built bin/mirmid: a turn with an unreachable provider fails, but
    the session must be written together with the user message. The binary is not
    built — the test is skipped (make test does not build bin/mirmid itself). }
  TCliSessionTurnTests = class(TTestCase)
  published
    procedure TestSessionSavedAfterFailedTurn;
  end;
  { A fatal error on an unknown key in the [tools] section (the built
    bin/mirmid): a typo must not silently leave a tool with its default value, so
    the start ends with code 1 and a message with the key name and the list of
    known tools. The binary is not built — the test is skipped. }
  TCliUnknownToolKeyTests = class(TTestCase)
  published
    procedure TestUnknownToolKeyExitsWithCodeOne;
    procedure TestInitRepairsBrokenToolsSection;
  end;

implementation

uses
  Classes, SysUtils, process, mirmid.cli, mirmid.session, mirmid.types, mirmid.util;

procedure TCliFormatTests.TestStepEndKeepsUtf8Separator;
var
  InText, OutText: string;
begin
  InText := 's1: done — ' + 'Grüße, Welt!';
  OutText := FormatStepEnd(InText);
  AssertEquals('the separator and the UTF-8 result are not damaged', InText,
    OutText);
end;

procedure TCliFormatTests.TestStepEndNoSeparator;
var
  InText: string;
begin
  InText := 's1: removed from the plan';
  AssertEquals('without a separator the text does not change', InText,
    FormatStepEnd(InText));
end;

procedure TCliFormatTests.TestStepEndShortensResult;
var
  Head, Tail, OutText: string;
begin
  Head := 's2: failed — ';
  Tail := StringOfChar('x', 500);
  OutText := FormatStepEnd(Head + Tail);
  AssertTrue('the header is preserved', Pos('s2: failed — ', OutText) = 1);
  { Shorten: 400 bytes of the result + '…' (3 UTF-8 bytes). }
  AssertEquals('the result is shortened to the limit', 400 + 3,
    Length(OutText) - Length(Head));
  AssertEquals('an ellipsis at the end', '…',
    Copy(OutText, Length(OutText) - 2, MaxInt));
end;

{ ------------------------------------------------------- subagent output }

procedure TCliSubAgentOutputTests.TestDepthPrefixZero;
begin
  AssertEquals('depth 0 — an empty prefix', '', DepthPrefix(0));
end;

procedure TCliSubAgentOutputTests.TestDepthPrefixOne;
var
  Pfx: string;
begin
  Pfx := DepthPrefix(1);
  AssertTrue('there is a │ character', Pos('│', Pfx) > 0);
end;

procedure TCliSubAgentOutputTests.TestDepthPrefixTwo;
var
  Pfx1, Pfx2: string;
begin
  Pfx1 := DepthPrefix(1);
  Pfx2 := DepthPrefix(2);
  AssertTrue('there is a │ character', Pos('│', Pfx2) > 0);
  AssertTrue('depth 2 is longer than depth 1', Length(Pfx2) > Length(Pfx1));
end;

procedure TCliSubAgentOutputTests.TestFormatContextStatus;
var
  S: string;
begin
  S := FormatContextStatus(1000, 128000);
  AssertTrue('it starts with [', S[1] = '[');
  AssertTrue('it ends with ]', S[Length(S)] = ']');
  AssertTrue('there is a | separator', Pos('|', S) > 0);
  AssertTrue('there is a % sign', Pos('%', S) > 0);
  AssertTrue('the current size is there', Pos('1k', S) > 0);
  AssertTrue('the total size is there', Pos('128k', S) > 0);
  { The percentage with tenths: 1000 out of 128000 — "0.8%" (a dot, not a
    comma). }
  AssertTrue('the percentage 0.8%', Pos('|0.8%]', S) > 0);
  { WithTime is true by default: the time (hh:nn:ss) is in the line. }
  AssertTrue('there is a clock HH:MM:SS', Pos(':', S) > 0);
end;

{ The percentage in the status line is counted from the common model window in
  tenths without the locale (a dot); the boundary values are 0.0%, 50.0% and
  100.0%; an unknown window (Total <= 0) gives '?'. }
procedure TCliSubAgentOutputTests.TestFormatContextStatusPercent;
var
  S: string;
begin
  S := FormatContextStatus(0, 128000, False);
  AssertTrue('no context — 0.0%: ' + S, Pos('|0.0%]', S) > 0);

  S := FormatContextStatus(1000, 128000, False);
  AssertTrue('0.8% (rounded to 0.1): ' + S, Pos('|0.8%]', S) > 0);

  S := FormatContextStatus(64000, 128000, False);
  AssertTrue('half the window — 50.0%: ' + S, Pos('|50.0%]', S) > 0);

  S := FormatContextStatus(128000, 128000, False);
  AssertTrue('the window is full — 100.0%: ' + S, Pos('|100.0%]', S) > 0);

  S := FormatContextStatus(500, 0, False);
  AssertTrue('an unknown window — ?: ' + S, Pos('|?]', S) > 0);
  AssertEquals('there is no comma in the percentage: ' + S, 0, Pos(',', S));
end;

procedure TCliSubAgentOutputTests.TestFormatContextStatusUnknownTotal;
var
  S: string;
begin
  S := FormatContextStatus(500, 0);
  AssertTrue('it starts with [', S[1] = '[');
  AssertTrue('an unknown total size', Pos('/?', S) > 0);
  AssertTrue('an unknown percentage', Pos('|?]', S) > 0);
end;

{ The part of the status line allotted to the subagent is printed without the
  date and the time: there is one clock (hh:nn:ss) per line. }
procedure TCliSubAgentOutputTests.TestFormatContextStatusNoTime;
var
  S: string;
begin
  S := FormatContextStatus(1000, 128000, False);
  AssertTrue('it starts with [', S[1] = '[');
  AssertEquals('there is no time', 0, Pos(':', S));
  AssertTrue('the current size is in place', Pos('1k', S) > 0);
  AssertTrue('the total size is in place', Pos('128k', S) > 0);
  AssertTrue('the percentage is in place', Pos('%', S) > 0);

  { An unknown total size — no time either. }
  S := FormatContextStatus(500, 0, False);
  AssertEquals('there is no time with an unknown total size either', 0, Pos(':', S));
  AssertTrue('an unknown total size', Pos('/?', S) > 0);
end;

{ The subagent status line: the word "subagent", the sizes of both sessions, the
  time — only in the main session part (two colons from hh:nn:ss). }
procedure TCliSubAgentOutputTests.TestSubAgentStatusTimeOnlyInMainPart;
var
  S: string;
  I, Colons: Integer;
begin
  S := FormatSubAgentStatus(1000, 2000, 128000);
  AssertTrue('the word "subagent" is there', Pos('subagent', S) > 0);
  AssertTrue('the main session context', Pos('1k', S) > 0);
  AssertTrue('the subagent context', Pos('2k', S) > 0);
  Colons := 0;
  for I := 1 to Length(S) do
    if S[I] = ':' then
      Inc(Colons);
  AssertEquals('the time only in the main session part', 2, Colons);
end;

{ The sub-session label is parameterised: the planner passes "step s1"/
  "analysis", the subagent — the default value "subagent". }
procedure TCliSubAgentOutputTests.TestSubAgentStatusCustomLabel;
var
  S: string;
begin
  S := FormatSubAgentStatus(1000, 2000, 128000, 'analysis');
  AssertTrue('the analysis label: ' + S, Pos('analysis', S) > 0);
  AssertEquals('there is no "subagent" word', 0, Pos('subagent', S));
  AssertTrue('the main session part is in place', Pos('1k', S) > 0);
  AssertTrue('the sub-session part is in place', Pos('2k', S) > 0);

  S := FormatSubAgentStatus(1000, 2000, 128000);
  AssertTrue('the default label is "subagent"', Pos('subagent', S) > 0);
end;
{ Removes the ANSI colour sequences: the text of the line is checked, so it does
  not matter whether the colours are enabled in the test environment. }
function StripAnsi(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
    if (S[I] = #27) and (I < Length(S)) and (S[I + 1] = '[') then
    begin
      Inc(I, 2);
      while (I <= Length(S)) and (S[I] <> 'm') do
        Inc(I);
      Inc(I);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
end;

{ -------------------------------------------- plan analysis line }

{ The analysis sub-session line: "[HH:MM:SS|main/sub/total|main-percent%/
  sub-percent%] analysis" — the same order as the step line
  (FormatStepStatus): first the status with the main session context and the
  analysis sub-session context, then the grey "analysis" label after one space.
  There is no [analysis] tag; there is one clock; the percentages are counted
  from the common model window, so there are two of them. Without a passed
  MainCur the parent context is zero (headless). }
procedure TCliSubAgentOutputTests.TestFormatAnalysisStatus;
const
  LabelText = 'analysis';
var
  S, StatusPart: string;
  I, Colons, StatusEnd, Brackets: Integer;
begin
  S := StripAnsi(FormatAnalysisStatus(1500, 128000));
  AssertEquals('the line starts with the status: ' + S, '[', Copy(S, 1, 1));
  AssertTrue('the status and the label are separated by one space: ' + S,
    Pos('] ' + LabelText, S) > 0);
  AssertEquals('the analysis label closes the line: ' + S, LabelText,
    Copy(S, Length(S) - Length(LabelText) + 1, MaxInt));
  AssertEquals('no [analysis] tag: ' + S, 0, Pos('[' + LabelText + ']', S));
  AssertEquals('no "subagent" word: ' + S, 0, Pos('subagent', S));
  { main/sub/total: without the parent context main = 0. }
  AssertTrue('the main/sub/total counters (0/1.5k/128k): ' + S,
    Pos('0/1.5k/128k', S) > 0);
  AssertTrue('the total size (128k): ' + S, Pos('128k', S) > 0);
  { Two percentages from one window: main 0 -> 0.0%, the sub-session -> 1.2%. }
  AssertTrue('two percentages of the common window: ' + S, Pos('|0.0%/1.2%', S) > 0);
  { One status — so there is no second [ bracket (the sub-session parts are not
    printed separately, as in FormatSubAgentStatus). }
  Brackets := 0;
  for I := 1 to Length(S) do
    if S[I] = '[' then
      Inc(Brackets);
  AssertEquals('one status in the line: ' + S, 1, Brackets);
  { The clock (two colons) is in the status part before the closing bracket, not
    in the label or the counters. }
  StatusEnd := Pos(']', S);
  AssertTrue('the status is closed by a square bracket: ' + S, StatusEnd > 0);
  StatusPart := Copy(S, 1, StatusEnd);
  Colons := 0;
  for I := 1 to Length(StatusPart) do
    if StatusPart[I] = ':' then
      Inc(Colons);
  AssertEquals('one clock in the line (HH:MM:SS)', 2, Colons);
  { An unknown total size — the same order, without the [analysis] tag. }
  S := StripAnsi(FormatAnalysisStatus(500, 0));
  AssertTrue('an unknown total size: ' + S, Pos('0/500/?|?/?]', S) > 0);
  AssertEquals('the analysis label with an unknown size too: ' + S, LabelText,
    Copy(S, Length(S) - Length(LabelText) + 1, MaxInt));
  AssertEquals('no [analysis] tag: ' + S, 0, Pos('[' + LabelText + ']', S));
end;

{ The main session context is passed (plan mode: the main turn has already been
  measured by the CLI cache) — the analysis line contains all three counters and
  two percentages, like the step line. }
procedure TCliSubAgentOutputTests.TestFormatAnalysisStatusWithMain;
var
  S: string;
begin
  S := StripAnsi(FormatAnalysisStatus(1500, 128000, 7000));
  AssertTrue('the main session context in the line (7k/1.5k/128k): ' + S,
    Pos('7k/1.5k/128k', S) > 0);
  AssertTrue('the percentages of both counters (5.5%/1.2%): ' + S,
    Pos('|5.5%/1.2%', S) > 0);
  AssertEquals('the analysis label closes the line: ' + S, 'analysis',
    Copy(S, Length(S) - Length('analysis') + 1, MaxInt));
end;

{ ------------------------------------------------ plan step line }

{ The step line: "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%] name". The
  status comes first, then the step name after one space; there is no [step] tag,
  there is one clock, there is no │ indentation — the step sub-session is printed
  at zero depth. The counters: the main session context (MainCur), the step
  (Cur) and the common model window (Total); the percentage is counted from Total
  for every counter separately. }
procedure TCliStepOutputTests.TestFormatStepStatus;
const
  StepName = 's1: update README';
var
  S, StatusPart: string;
  I, Colons, StatusEnd: Integer;
begin
  S := StripAnsi(FormatStepStatus(StepName, 1200, 128000, 8000));
  AssertEquals('the line starts with the status: ' + S, '[', Copy(S, 1, 1));
  AssertEquals('the [step] tag is gone: ' + S, 0, Pos('[step]', S));
  AssertEquals('the step name closes the line: ' + S, StepName,
    Copy(S, Length(S) - Length(StepName) + 1, MaxInt));
  AssertTrue('the status and the name are separated by one space: ' + S,
    Pos('] ' + StepName, S) > 0);
  AssertTrue('there is a | separator: ' + S, Pos('|', S) > 0);
  AssertTrue('there is a % sign: ' + S, Pos('%', S) > 0);
  { main/sub/total: the main session context, the step and the model window. }
  AssertTrue('the main/sub/total counters (8k/1.2k/128k): ' + S,
    Pos('8k/1.2k/128k', S) > 0);
  AssertTrue('the total size (128k): ' + S, Pos('128k', S) > 0);
  { Two percentages from one window: main 8k -> 6.3%, step 1.2k -> 0.9%. }
  AssertTrue('two percentages of the common window (6.3%/0.9%): ' + S,
    Pos('|6.3%/0.9%', S) > 0);
  AssertEquals('the step has no │ prefix: ' + S, 0, Pos('│', S));
  { The clock (two colons) is only in the status part before the first ']', not
    in the step name ("s1: ..." contains a colon too). }
  StatusEnd := Pos(']', S);
  AssertTrue('the status is closed by a square bracket: ' + S, StatusEnd > 0);
  StatusPart := Copy(S, 1, StatusEnd);
  Colons := 0;
  for I := 1 to Length(StatusPart) do
    if StatusPart[I] = ':' then
      Inc(Colons);
  AssertEquals('one clock in the line (HH:MM:SS)', 2, Colons);
end;

{ The percentages are counted from one model window: with a full main session
  context the first percentage is 100.0%, the step percentage is from the same
  Total. The main value comes first, the step second. }
procedure TCliStepOutputTests.TestFormatStepStatusMainCounters;
var
  S: string;
begin
  S := StripAnsi(FormatStepStatus('s3: tests', 1000, 128000, 128000));
  AssertTrue('main/sub/total (128k/1k/128k): ' + S,
    Pos('128k/1k/128k', S) > 0);
  AssertTrue('percentages from one window (100.0%/0.8%): ' + S,
    Pos('|100.0%/0.8%', S) > 0);
  AssertTrue('the step name is there: ' + S, Pos('] s3: tests', S) > 0);
end;

{ The parent context has not been measured yet (MainCur is not passed): the line
  keeps the main/sub/total format, but main is zero — the step does not
  substitute foreign counters for the main session context. }
procedure TCliStepOutputTests.TestFormatStepStatusWithoutMain;
var
  S: string;
begin
  S := StripAnsi(FormatStepStatus('s1: update README', 1200, 128000));
  AssertTrue('main is 0 by default (0/1.2k/128k): ' + S,
    Pos('0/1.2k/128k', S) > 0);
  AssertTrue('the percentages (0.0%/0.9%): ' + S, Pos('|0.0%/0.9%', S) > 0);
end;

{ An empty name (a step without a description) — only the status line remains:
  without the [step] tag and without a trailing space. }
procedure TCliStepOutputTests.TestFormatStepStatusEmptyName;
var
  S: string;
  I, Colons: Integer;
begin
  S := StripAnsi(FormatStepStatus('', 500, 0));
  AssertEquals('the line starts with the status: ' + S, '[', Copy(S, 1, 1));
  { main/sub/total with an unknown window: "0/500/?|?/?". }
  AssertTrue('an unknown total size: ' + S, Pos('0/500/?|?/?]', S) > 0);
  AssertEquals('the line is closed by the status, without a trailing space: ' + S,
    ']', Copy(S, Length(S), 1));
  AssertEquals('no [step] tag: ' + S, 0, Pos('[step]', S));
  AssertEquals('no │ prefix: ' + S, 0, Pos('│', S));
  Colons := 0;
  for I := 1 to Length(S) do
    if S[I] = ':' then
      Inc(Colons);
  AssertEquals('one clock in the line and no name', 2, Colons);
end;
{ A plan step has no │ prefix: its sub-session is printed at zero depth, so the
  line starts with the status, and there is no indentation "chevron" from
  DepthPrefix either before it or inside the line; there is no [step] tag
  either. }
procedure TCliStepOutputTests.TestFormatStepStatusNoDepthPrefix;
const
  Names: array[0..2] of string = ('s1: update README', 's2: tests', '');
  Curs: array[0..2] of Integer = (1200, 0, 99999);
  Totals: array[0..2] of Integer = (128000, 0, 1000000);
var
  I: Integer;
  S: string;
begin
  for I := Low(Names) to High(Names) do
  begin
    S := StripAnsi(FormatStepStatus(Names[I], Curs[I], Totals[I]));
    AssertEquals('the step line starts with the status, without the │ indent: ' + S,
      '[', Copy(S, 1, 1));
    AssertEquals('no │ prefix in the step line: ' + S, 0, Pos('│', S));
    { DepthPrefix(1) — the grey │ that marks nested subagents. }
    AssertEquals('the step print depth is zero: ' + S, 0, Pos(DepthPrefix(1), S));
    { The "subagent" label — a sign of the second part of a sub-session
      status. }
    AssertEquals('the step has no subagent sub-session label: ' + S,
      0, Pos('subagent', S));
    AssertEquals('no [step] tag: ' + S, 0, Pos('[step]', S));
    if Names[I] = '' then
      AssertEquals('an empty name — the line is closed by the status: ' + S,
        ']', Copy(S, Length(S), 1))
    else
      AssertEquals('the step name closes the line: ' + S, Names[I],
        Copy(S, Length(S) - Length(Names[I]) + 1, MaxInt));
  end;
end;
{ StepShortName — the short name for the fixed done line: from "s1: description"
  only the identifier remains; without a colon the name is unchanged, an empty
  one stays empty (outside a step). }
procedure TCliStepOutputTests.TestStepShortName;
begin
  AssertEquals('the description is dropped', 's1',
    StepShortName('s1: update README'));
  AssertEquals('the spaces around the identifier are trimmed', 's2',
    StepShortName('  s2 : tests  '));
  AssertEquals('without a colon — as it is', 's3', StepShortName('s3'));
  AssertEquals('an empty name stays empty', '', StepShortName(''));
  { A colon inside the description: only the part before the first one is
    taken. }
  AssertEquals('the first colon is the boundary', 's4',
    StepShortName('s4: edit: context.md'));
end;
{ ------------------------------------ gating of the plan step text }

{ Neither --show-step-result nor --show-reasoning: the text of the step
  sub-session and its result are hidden, only the status lines remain of the
  step. }
procedure TCliStepGatingTests.TestStepTextHiddenByDefault;
begin
  AssertFalse('without flags the step text is hidden', StepTextVisible(False, False));
end;

{ A single --show-step-result enables the step text (and the result in
  aeStepEnd). }
procedure TCliStepGatingTests.TestStepTextShownByStepResult;
begin
  AssertTrue('--show-step-result shows the step text',
    StepTextVisible(True, False));
end;

{ A single --show-reasoning enables the step text by the same condition: aeStreamText
  and aeStepEnd check the disjunction of the flags. }
procedure TCliStepGatingTests.TestStepTextShownByReasoning;
begin
  AssertTrue('--show-reasoning shows the step text',
    StepTextVisible(False, True));
end;

{ Both flags: the result is the same — the visibility does not depend on the
  second flag (an "or" condition, not XOR). }
procedure TCliStepGatingTests.TestStepTextShownByBoth;
begin
  AssertTrue('both flags show the step text',
    StepTextVisible(True, True));
end;

{ ---------------------------------- gating of the plan step task }

{ All eight combinations of the three flags: the "[step] name" line is visible
  exactly when --show-step-task or --show-reasoning is on; --show-step-result
  does not affect the step task. }
procedure TCliStepTaskGatingTests.TestAllFlagCombinations;
var
  Task, Reason, Res, Shown: Boolean;
  I, J, K: Integer;
  S: string;
begin
  for I := 0 to 1 do
    for J := 0 to 1 do
      for K := 0 to 1 do
      begin
        Task := I = 1;
        Reason := J = 1;
        Res := K = 1;
        Shown := StepTaskVisible(Task, Reason, Res);
        S := Format('task=%d reasoning=%d step-result=%d',
          [Ord(Task), Ord(Reason), Ord(Res)]);
        AssertTrue('ShowStepTask or ShowReasoning was expected: ' + S,
          Shown = (Task or Reason));
      end;
end;

{ The defaults (all flags off): the step task is not printed — only the status
  line with the step name is visible. }
procedure TCliStepTaskGatingTests.TestTaskHiddenByDefault;
begin
  AssertFalse('without flags the step task is hidden',
    StepTaskVisible(False, False, False));
end;

{ A single --show-reasoning enables the step task regardless of
  --show-step-task. }
procedure TCliStepTaskGatingTests.TestTaskShownByReasoningOnly;
begin
  AssertTrue('--show-reasoning shows the step task',
    StepTaskVisible(False, True, False));
end;

{ A single --show-step-task enables the step task. }
procedure TCliStepTaskGatingTests.TestTaskShownByStepTaskOnly;
begin
  AssertTrue('--show-step-task shows the step task',
    StepTaskVisible(True, False, False));
end;

{ A single --show-step-result does not show the step task: that flag is about the
  answer text and the step result (StepTextVisible), not about the task itself. }
procedure TCliStepTaskGatingTests.TestStepResultDoesNotShowTask;
begin
  AssertFalse('--show-step-result does not show the step task',
    StepTaskVisible(False, False, True));
end;

{ --show-step-result does not cancel the showing of a task enabled by another
  flag. }
procedure TCliStepTaskGatingTests.TestStepResultIgnoredWhenTaskShown;
begin
  AssertTrue('--show-step-task + --show-step-result',
    StepTaskVisible(True, False, True));
  AssertTrue('--show-reasoning + --show-step-result',
    StepTaskVisible(False, True, True));
end;

{ ------------------------------ gating of the tool output }

{ By default (--show-reasoning off) the tool output is hidden everywhere: in the
  main session, in the subagent and in the planner sub-sessions — as in the plan
  steps. Only the status lines and the final text are printed. }
procedure TCliToolOutputGatingTests.TestHiddenByDefault;
begin
  AssertFalse('without --show-reasoning the tool output is hidden',
    ToolOutputVisible(False));
end;

{ A single --show-reasoning enables the tool output in all sessions: the gating
  no longer depends on the sub-session label (task2.md). }
procedure TCliToolOutputGatingTests.TestShownByReasoning;
begin
  AssertTrue('--show-reasoning shows the tool output',
    ToolOutputVisible(True));
end;

{ ---------------------------------- the effective context size }

{ The host did not report a size (0) — EffectiveContextWindow returns the value
  from the settings; the default one is meaningful too (> 0). }
procedure TEffectiveContextWindowTests.TestHostUnsetUsesConfig;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  AssertEquals('the default ContextWindow is 128k', 128000, Cfg.ContextWindow);
  AssertEquals('the host did not report a size', 0, Cfg.HostContextWindow);
  AssertEquals('the settings value is taken', Cfg.ContextWindow,
    EffectiveContextWindow(Cfg));

  Cfg.ContextWindow := 32000;
  AssertEquals('the settings value, not DEFAULT', 32000,
    EffectiveContextWindow(Cfg));
end;

{ The host reported a smaller size — the status line needs exactly that one,
  otherwise the percentages are counted from an inflated context. }
procedure TEffectiveContextWindowTests.TestHostSmallerWins;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  Cfg.ContextWindow := 128000;
  Cfg.HostContextWindow := 32000;
  AssertEquals('the minimum of the settings and the host', 32000,
    EffectiveContextWindow(Cfg));

  Cfg.ContextWindow := 16000;
  Cfg.HostContextWindow := 9000;
  AssertEquals('the minimum does not depend on the order of the values', 9000,
    EffectiveContextWindow(Cfg));
end;

{ The host reported a size larger than the configured one (or equal) — the
  settings value remains: EffectiveContextWindow never increases the context. }
procedure TEffectiveContextWindowTests.TestHostLargerIgnored;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  Cfg.ContextWindow := 128000;
  Cfg.HostContextWindow := 200000;
  AssertEquals('a larger host size is ignored', 128000,
    EffectiveContextWindow(Cfg));

  Cfg.ContextWindow := 8000;
  Cfg.HostContextWindow := 8001;
  AssertEquals('one greater — the settings value too', 8000,
    EffectiveContextWindow(Cfg));
end;

{ Equal values give the same number, and a negative host value is treated as
  "not reported". }
procedure TEffectiveContextWindowTests.TestEqualAndNegativeHost;
var
  Cfg: TMirmidConfig;
begin
  Cfg := DefaultConfig;
  Cfg.ContextWindow := 64000;
  Cfg.HostContextWindow := 64000;
  AssertEquals('equal values — no change', 64000,
    EffectiveContextWindow(Cfg));

  Cfg.HostContextWindow := -1;
  AssertEquals('a negative host value — the settings value', 64000,
    EffectiveContextWindow(Cfg));
end;
{ ------------------------------------------------- status token accounting }

{ The subagent base is the size of its own context from aeContext. Earlier the
  CLI forcibly zeroed it, and the status showed only the tokens of the current
  answer. }
procedure TContextTokensTests.TestSubAgentBaseFromContext;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 5000);            { main session: 5k }
    T.SetBase(1, 1200);            { subagent: 1.2k }
    T.AddResponseTokens(1, 300);   { + answer tokens }
    S := T.Text(128000, 1);
    AssertTrue('the subagent size from aeContext (1.5k): ' + S, Pos('1.5k', S) > 0);
    AssertTrue('the main session is there (5k): ' + S, Pos('5k', S) > 0);
  finally
    T.Free;
  end;
end;

{ The answer tokens of different sessions are not mixed. }
procedure TContextTokensTests.TestMainAndSubAccumSeparate;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 1000);
    T.AddResponseTokens(0, 100);
    T.SetBase(1, 2000);
    T.AddResponseTokens(1, 200);
    S := T.Text(128000, 1);
    AssertTrue('the main session 1.1k: ' + S, Pos('1.1k', S) > 0);
    AssertTrue('the subagent 2.2k: ' + S, Pos('2.2k', S) > 0);
  finally
    T.Free;
  end;
end;

{ Regression of the reasoning token accounting at Depth > 0: the reasoning comes
  in separate portions (sometimes before the first aeContext of the sub-session)
  and must be added to the sub-session counters without touching the main
  session. Earlier, with hidden text, the portions could be lost, and the plan
  step line showed an underestimated context size. }
procedure TContextTokensTests.TestReasoningTokensDepthGreaterZero;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 5000);            { main session: 5k }
    T.SetBase(1, 1200);            { step sub-session: 1.2k }
    T.AddResponseTokens(1, 90);    { reasoning in three portions }
    T.AddResponseTokens(1, 150);
    T.AddResponseTokens(1, 400);
    AssertEquals('the reasoning tokens are counted in the sub-session',
      1840, T.SubTokens);
    S := T.Text(128000, 1, 'step s1');
    AssertTrue('the sub-session status contains 1.8k: ' + S, Pos('1.8k', S) > 0);
    AssertTrue('the main session is there (5k): ' + S, Pos('5k', S) > 0);
    AssertEquals('the reasoning did not get into the main session',
      0, Pos('5.6k', S));
    { Entering a new sub-session: the reasoning before its first aeContext is
      counted too (base 0 + accumulated). }
    T.EnterSubAgent;
    T.AddResponseTokens(1, 250);
    AssertEquals('the reasoning before aeContext is counted', 250, T.SubTokens);
    S := T.Text(128000, 1, 'step s2');
    AssertTrue('the sub-session status contains 250: ' + S, Pos('250', S) > 0);
  finally
    T.Free;
  end;
end;

{ Entering a subagent — the counters of the previous subagent must not "leak". }
procedure TContextTokensTests.TestEnterSubAgentResets;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 2000);
    T.AddResponseTokens(1, 400);
    T.EnterSubAgent;
    S := T.Text(128000, 1);
    AssertEquals('the subagent context is reset', 0, Pos('2.4k', S));
    AssertTrue('the subagent status shows zero: ' + S, Pos('0/128k', S) > 0);
  finally
    T.Free;
  end;
end;

{ The main session has no "subagent" part. }
procedure TContextTokensTests.TestMainStatusHasNoSubPart;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 3000);
    S := T.Text(128000, 0);
    AssertEquals('no "subagent" word', 0, Pos('subagent', S));
    AssertTrue('the main session size (3k): ' + S, Pos('3k', S) > 0);
  finally
    T.Free;
  end;
end;

{ MainTokens — the main session context (the base from its aeContext plus the
  accumulated tokens of the current answer). The step/analysis line needs it in
  the main/sub/total format: SubTokens returns only the sub-session, so without a
  separate accessor the parent context could not be taken. }
procedure TContextTokensTests.TestMainTokensAccessor;
var
  T: TContextTokens;
begin
  T := TContextTokens.Create;
  try
    AssertEquals('the context is 0 before the events', 0, T.MainTokens);
    T.SetBase(0, 5000);            { aeContext of the main session }
    AssertEquals('the main session base', 5000, T.MainTokens);
    T.AddResponseTokens(0, 300);   { the tokens of the current answer }
    AssertEquals('the base + the answer tokens', 5300, T.MainTokens);
    { The sub-session tokens do not get into the main one. }
    T.SetBase(1, 1200);
    T.AddResponseTokens(1, 200);
    AssertEquals('the main session did not change', 5300, T.MainTokens);
    AssertEquals('the sub-session counters separately', 1400, T.SubTokens);
    { Leaving the sub-session does not touch the main session. }
    T.ExitSubSession;
    AssertEquals('after the exit — the same 5300', 5300, T.MainTokens);
  finally
    T.Free;
  end;
end;

{ The sub-session label in the status line: the planner passes "step s2"/
  "analysis". Text keeps the nested-session format (depth > 1): the main session
  + the label + the sub-session; the analysis line at depth 1 is built separately
  — FormatAnalysisStatus (see TestAnalysisLineMainAndSubCounters). }
procedure TContextTokensTests.TestTextCustomLabel;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 1200);
    S := T.Text(128000, 1, 'step s2');
    AssertTrue('the step label: ' + S, Pos('step s2', S) > 0);
    AssertEquals('no "subagent" word', 0, Pos('subagent', S));
    AssertTrue('the sub-session size (1.2k): ' + S, Pos('1.2k', S) > 0);

    S := T.Text(128000, 1, 'analysis');
    AssertTrue('the analysis label: ' + S, Pos('analysis', S) > 0);
    AssertTrue('the sub-session size (1.2k): ' + S, Pos('1.2k', S) > 0);

    S := T.Text(128000, 1);
    AssertTrue('the default label is "subagent"', Pos('subagent', S) > 0);
  finally
    T.Free;
  end;
end;

{ The analysis line (depth 1) is built by FormatAnalysisStatus from the
  sub-session counters (SubTokens) and the main session context (MainTokens), as
  the step line: main/sub/total and two percentages of the common window. There
  is no [analysis] tag, the order is the status first, then the label. The
  previous look (main session + label + sub-session) stayed in Text for nested
  sessions (depth > 1), so both paths are checked. }
procedure TContextTokensTests.TestAnalysisLineMainAndSubCounters;
var
  T: TContextTokens;
  S, Legacy: string;
  I, Colons: Integer;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 7000);            { main session: 7k }
    T.SetBase(1, 1200);
    T.AddResponseTokens(1, 300);   { the analysis answer tokens: 1.5k }
    S := StripAnsi(FormatAnalysisStatus(T.SubTokens, 128000, T.MainTokens));
    AssertEquals('the status comes first: ' + S, '[', Copy(S, 1, 1));
    { Both counters in the line: the parent context and the analysis
      sub-session. }
    AssertTrue('the main/sub/total counters (7k/1.5k/128k): ' + S,
      Pos('7k/1.5k/128k', S) > 0);
    { The percentages of both counters — from one model window. }
    AssertTrue('two percentages (5.5%/1.2%): ' + S, Pos('|5.5%/1.2%', S) > 0);
    AssertTrue('the analysis label is there: ' + S, Pos('analysis', S) > 0);
    AssertEquals('no [analysis] tag: ' + S, 0, Pos('[analysis]', S));
    AssertEquals('no "subagent" word: ' + S, 0, Pos('subagent', S));
    Colons := 0;
    for I := 1 to Length(S) do
      if S[I] = ':' then
        Inc(Colons);
    AssertEquals('one clock in the line (HH:MM:SS)', 2, Colons);

    { The previous look (main session + label + sub-session) stays in Text: it
      prints a nested session (depth > 1). }
    Legacy := StripAnsi(T.Text(128000, 1, 'analysis'));
    AssertTrue('Text keeps the main session part (7k): ' + Legacy,
      Pos('7k', Legacy) > 0);
    AssertTrue('Text keeps the analysis counters (1.5k): ' + Legacy,
      Pos('1.5k', Legacy) > 0);
  finally
    T.Free;
  end;
end;

{ "plan step → subagent": leaving the subagent restores the step counters,
  otherwise the step would show 0 after the nested session. }
procedure TContextTokensTests.TestExitSubSessionRestoresParent;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 1500);
    T.AddResponseTokens(1, 200);   { step: 1.7k }
    T.EnterSubAgent;               { inside the step — a subagent }
    T.SetBase(1, 400);
    S := T.Text(128000, 1, 'step s1');
    AssertTrue('the subagent 400: ' + S, Pos('400', S) > 0);
    AssertEquals('the step counters are not visible from inside', 0,
      Pos('1.7k', S));

    T.ExitSubSession;
    S := T.Text(128000, 1, 'step s1');
    AssertTrue('the step counters are restored (1.7k): ' + S, Pos('1.7k', S) > 0);
  finally
    T.Free;
  end;
end;

{ The counter stack: SavedCount grows on entering and drops on leaving. }
procedure TContextTokensTests.TestSavedCountTracksDepth;
var
  T: TContextTokens;
begin
  T := TContextTokens.Create;
  try
    AssertEquals('the stack is empty', 0, T.SavedCount);
    T.EnterSubAgent;
    AssertEquals('one level', 1, T.SavedCount);
    T.EnterSubAgent;
    AssertEquals('two levels', 2, T.SavedCount);
    T.ExitSubSession;
    AssertEquals('back to the step level', 1, T.SavedCount);
    T.ResetSubSession;
    AssertEquals('the reset cleared the stack', 0, T.SavedCount);
  finally
    T.Free;
  end;
end;

{ An unpaired entry into a nested sub-session (the subagent failed, aeToolResult
  never came): UnwindTo by the entry mark removes the extra pairs, keeping the
  step counters. }
procedure TContextTokensTests.TestUnwindToRestoresParent;
var
  T: TContextTokens;
  S: string;
  Mark: Integer;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 1000);            { step }
    Mark := T.SavedCount;          { the mark of the step entry: 0 }
    T.EnterSubAgent;
    T.SetBase(1, 300);
    T.EnterSubAgent;               { an unclosed nested subagent }
    T.SetBase(1, 50);
    AssertEquals('two nesting levels', 2, T.SavedCount);

    T.UnwindTo(Mark);              { roll back to the state before the step entry }
    AssertEquals('the stack is unwound to the mark', 0, T.SavedCount);
    S := T.Text(128000, 1, 'step s1');
    AssertTrue('the step counters are restored (1k): ' + S, Pos('1k', S) > 0);
    AssertEquals('the nested session values did not leak', 0, Pos('300', S));
  finally
    T.Free;
  end;
end;

{ Leaving the outer sub-session (step/analysis), including after a step failure
  or revise_plan: the counters and the stack are cleared, the main session is
  intact. }
procedure TContextTokensTests.TestResetSubSessionClears;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(0, 4000);
    T.SetBase(1, 2000);
    T.AddResponseTokens(1, 100);
    T.EnterSubAgent;
    T.SetBase(1, 700);

    T.ResetSubSession;
    AssertEquals('the stack is cleared', 0, T.SavedCount);
    S := T.Text(128000, 1, 'analysis');
    AssertTrue('the sub-session is zeroed: ' + S, Pos('0/128k', S) > 0);
    AssertTrue('the main session is preserved (4k): ' + S, Pos('4k', S) > 0);
    AssertTrue('the sub-session label is preserved: ' + S, Pos('analysis', S) > 0);
  finally
    T.Free;
  end;
end;

{ Leaving without a paired entry — a simple zeroing, the stack is not broken. }
procedure TContextTokensTests.TestExitWithoutEnterZeroes;
var
  T: TContextTokens;
  S: string;
begin
  T := TContextTokens.Create;
  try
    T.SetBase(1, 900);
    T.ExitSubSession;
    AssertEquals('the stack is empty', 0, T.SavedCount);
    S := T.Text(128000, 1, 'analysis');
    AssertTrue('the counters are zeroed: ' + S, Pos('0/128k', S) > 0);
    AssertTrue('the analysis label: ' + S, Pos('analysis', S) > 0);
  finally
    T.Free;
  end;
end;
{ --- Session saved after a failed turn (task2.md) ------------------------

  Integration test against the built bin/mirmid binary. The turn fails (the
  provider is unreachable: 127.0.0.1:1) — the session must be stored in
  <workdir>/.mirmid/sessions/<id>.json anyway, with the user message.
  No external network is needed: the connection is refused locally. The binary is
  not built — the test is skipped (make test does not build bin/mirmid). }

function AppExePath: string;
begin
  { The extension comes from the test runner: on Windows it is ".exe". }
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'mirmid' + ExtractFileExt(ParamStr(0));
end;

{ Runs mirmid with the given arguments and waits for the exit. The host
  environment is cleaned of MIRMID_*: the test must not depend on the developer
  settings (for example MIRMID_PLAN would enable the planner). stdout and stderr
  are merged into one stream (poStderrToOutPut): the error messages are
  checked. }
function RunAppArgs(const Exe: string; const Args: array of string;
  out OutText: string; out ExitCode: Integer): Boolean;
var
  Proc: TProcess;
  Params, Env: TStringList;
  MS: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N, I: Integer;
begin
  Result := False;
  OutText := '';
  ExitCode := -1;
  Params := TStringList.Create;
  Env := TStringList.Create;
  Proc := TProcess.Create(nil);
  MS := TMemoryStream.Create;
  try
    for I := 0 to High(Args) do
      Params.Add(Args[I]);

    EnvironmentToList(Env);
    for I := Env.Count - 1 downto 0 do
      if Pos('MIRMID_', UpperCase(Env.Names[I])) = 1 then
        Env.Delete(I);

    Proc.Executable := Exe;
    Proc.Parameters := Params;
    Proc.Environment := Env;
    Proc.Options := [poUsePipes, poStderrToOutPut];
    Proc.Execute;
    while True do
    begin
      N := Proc.Output.Read(Buf, Length(Buf));
      if N <= 0 then
        Break;
      MS.WriteBuffer(Buf, N);
    end;
    if not Proc.WaitOnExit(60000) then
    begin
      Proc.Terminate(0);
      Exit;
    end;
    ExitCode := Proc.ExitStatus;
    SetLength(OutText, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.ReadBuffer(OutText[1], MS.Size);
    end;
    Result := True;
  finally
    MS.Free;
    Proc.Free;
    Env.Free;
    Params.Free;
  end;
end;

{ Runs mirmid with an unreachable provider in a separate working directory. }
function RunAppWithBadProvider(const Exe, WorkDir: string;
  out OutText: string; out ExitCode: Integer): Boolean;
begin
  Result := RunAppArgs(Exe, ['--config',
    IncludeTrailingPathDelimiter(WorkDir) + 'none.ini',
    '--workdir', WorkDir,
    '--base-url', 'http://127.0.0.1:1/v1',
    '--api-key', 'test-key',
    '--model', 'test-model',
    '--no-stream', '--no-mcp',
    '--connect-timeout', '1',
    '--timeout', '5',
    'session-save-check'], OutText, ExitCode);
end;

{ The first JSON file of the main session (the auxiliary *_sub_/_step_ ones do
  not count). }
function FirstMainSessionFile(const WorkDir: string): string;
var
  SR: TSearchRec;
  Dir: string;
  More: Boolean;
begin
  Result := '';
  Dir := SessionDir(WorkDir);
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.json', faAnyFile, SR) <> 0 then
    Exit;
  try
    { No Continue/Break: leaving the try-finally inside repeat would close the
      search, and the next FindNext would work with a closed handle. }
    More := True;
    while More do
    begin
      if ((SR.Attr and faDirectory) = 0) and not IsAuxSessionFile(SR.Name) then
      begin
        Result := IncludeTrailingPathDelimiter(Dir) + SR.Name;
        Break;
      end;
      More := FindNext(SR) = 0;
    end;
  finally
    FindClose(SR);
  end;
end;

{ Recursive removal of the temporary test directory. }
procedure RemoveTree(const Dir: string);
var
  SR: TSearchRec;
  Path: string;
  More: Boolean;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    More := True;
    while More do
    begin
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        Path := IncludeTrailingPathDelimiter(Dir) + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          RemoveTree(Path)
        else
          DeleteFile(Path);
      end;
      More := FindNext(SR) = 0;
    end;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure TCliSessionTurnTests.TestSessionSavedAfterFailedTurn;
var
  Exe, WorkDir, OutText, FileName, SessionText, Err: string;
  ExitCode: Integer;
begin
  Exe := AppExePath;
  if not FileExists(Exe) then
    Exit;   { bin/mirmid is not built — the test is skipped }

  WorkDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'mirmid_session_turn_' + FormatDateTime('hhnnsszzz', Now);
  AssertTrue('the temporary directory is created', ForceDirectories(WorkDir));
  try
    AssertTrue('the application is started', RunAppWithBadProvider(Exe, WorkDir,
      OutText, ExitCode));
    AssertTrue('the turn failed (code ' + IntToStr(ExitCode) + ')',
      ExitCode <> 0);

    FileName := FirstMainSessionFile(WorkDir);
    AssertTrue('the session is saved after the failed turn (no ' +
      SessionDir(WorkDir) + '/*.json), output: ' + OutText, FileName <> '');
    if FileName = '' then
      Exit;

    AssertTrue('the session is read', ReadTextFile(FileName, SessionText, Err));
    AssertTrue('the user prompt is saved in the session',
      Pos('session-save-check', SessionText) > 0);
  finally
    RemoveTree(WorkDir);
  end;
end;

{ --- Unknown [tools] key — a fatal error (E2E) ----------------------------

  The built bin/mirmid with an INI whose [tools] contains an unknown key must
  exit with code 1 and name the key together with the list of known tools:
  silently enabling/disabling a tool because of a typo is not acceptable. The
  test needs no network — the session does not start. }

procedure TCliUnknownToolKeyTests.TestUnknownToolKeyExitsWithCodeOne;
var
  Exe, WorkDir, IniFile, OutText, Err: string;
  ExitCode: Integer;
begin
  Exe := AppExePath;
  if not FileExists(Exe) then
    Exit;   { bin/mirmid is not built — the test is skipped }

  WorkDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'mirmid_unknown_tool_' + FormatDateTime('hhnnsszzz', Now);
  AssertTrue('the temporary directory is created', ForceDirectories(WorkDir));
  try
    IniFile := IncludeTrailingPathDelimiter(WorkDir) + 'unknown.ini';
    AssertTrue('the INI with the unknown key is written',
      WriteTextFile(IniFile, '[tools]' + LineEnding +
        'read_text_file=1' + LineEnding + 'no_such_tool=1' + LineEnding, Err));

    AssertTrue('the application is started', RunAppArgs(Exe, ['--config', IniFile,
      '--workdir', WorkDir, '--no-mcp', '--no-stream', 'hello'],
      OutText, ExitCode));
    AssertEquals('an unknown [tools] key — exit code 1, output: ' + OutText,
      1, ExitCode);
    AssertTrue('the message names the unknown key: ' + OutText,
      Pos('unknown tool "no_such_tool"', OutText) > 0);
    AssertTrue('the message lists the known tools: ' + OutText,
      Pos('known tools:', OutText) > 0);
    { The list of known tools is not empty: it contains a key from the
      registry. }
    AssertTrue('the list contains read_text_file: ' + OutText,
      Pos('read_text_file', OutText) > 0);
  finally
    RemoveTree(WorkDir);
  end;
end;

{ `--init` must repair a broken INI too: if the file contains an unknown [tools]
  key, a normal start fails, but the configuration still has to be recreated. It
  is checked against the built binary: code 0 and a sample with all [tools]
  keys. }
procedure TCliUnknownToolKeyTests.TestInitRepairsBrokenToolsSection;
var
  Exe, WorkDir, IniFile, ConfigFile, OutText, Text, Err: string;
  ExitCode: Integer;
begin
  Exe := AppExePath;
  if not FileExists(Exe) then
    Exit;   { bin/mirmid is not built — the test is skipped }

  WorkDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'mirmid_init_repair_' + FormatDateTime('hhnnsszzz', Now);
  AssertTrue('the temporary directory is created', ForceDirectories(WorkDir));
  try
    IniFile := IncludeTrailingPathDelimiter(WorkDir) + 'broken.ini';
    AssertTrue('the INI with the unknown key is written',
      WriteTextFile(IniFile, '[tools]' + LineEnding + 'shel=1' + LineEnding, Err));

    AssertTrue('the application is started', RunAppArgs(Exe, ['--init', '--config',
      IniFile, '--workdir', WorkDir], OutText, ExitCode));
    AssertEquals('--init with a broken INI — code 0, output: ' + OutText,
      0, ExitCode);

    ConfigFile := IncludeTrailingPathDelimiter(WorkDir) + '.mirmid' + PathDelim +
      'mirmid.ini';
    AssertTrue('the sample is created: ' + ConfigFile, FileExists(ConfigFile));
    AssertTrue('the sample is read', ReadTextFile(ConfigFile, Text, Err));
    AssertTrue('the sample has the [tools] section', Pos('[tools]', Text) > 0);
    AssertTrue('the sample has the shell key', Pos('shell=', Text) > 0);
  finally
    RemoveTree(WorkDir);
  end;
end;
procedure TCliParseToolOutputLinesTests.TestDefaultOff;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('the command line is parsed', ParseCli(['grüße', 'welt'], Cli, Err));
  AssertEquals('no error', '', Err);
  AssertFalse('the key is not set without the flag', Cli.HasToolOutputLines);
  AssertEquals('the default value is 0 (from the settings)', 0,
    Cli.ToolOutputLines);
  AssertEquals('the prompt is saved', 'grüße welt', Cli.Prompt);
end;

procedure TCliParseToolOutputLinesTests.TestSpaceForm;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('the command line is parsed',
    ParseCli(['--tool-output-lines', '15'], Cli, Err));
  AssertEquals('no error', '', Err);
  AssertTrue('the key is set', Cli.HasToolOutputLines);
  AssertEquals('the value from the next argument', 15, Cli.ToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestInlineForm;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('the command line is parsed',
    ParseCli(['--tool-output-lines=12'], Cli, Err));
  AssertEquals('no error', '', Err);
  AssertTrue('the key is set', Cli.HasToolOutputLines);
  AssertEquals('the value after "="', 12, Cli.ToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestZeroMeansUnlimited;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('the command line is parsed',
    ParseCli(['--tool-output-lines', '0'], Cli, Err));
  AssertEquals('no error', '', Err);
  AssertTrue('0 is an explicitly set key too', Cli.HasToolOutputLines);
  AssertEquals('0 means no limit', 0, Cli.ToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestMissingValue;
var
  Cli: TCli;
  Err: string;
begin
  AssertFalse('an option without a value is a parse error',
    ParseCli(['--tool-output-lines'], Cli, Err));
  AssertTrue('the error message is not empty', Err <> '');
  AssertTrue('the message mentions the option', Pos('--tool-output-lines', Err) > 0);
  AssertFalse('the key is not set', Cli.HasToolOutputLines);
end;

procedure TCliParseToolOutputLinesTests.TestAlongsideOtherOptions;
var
  Cli: TCli;
  Err: string;
begin
  AssertTrue('the command line is parsed',
    ParseCli(['--show-reasoning', '--tool-output-lines', '5', 'question'], Cli, Err));
  AssertEquals('no error', '', Err);
  AssertTrue('--show-reasoning is parsed', Cli.ShowReasoning);
  AssertTrue('--tool-output-lines is parsed', Cli.HasToolOutputLines);
  AssertEquals('the limit value', 5, Cli.ToolOutputLines);
  AssertEquals('the prompt is not eaten as a value', 'question', Cli.Prompt);
end;

procedure TCliToolsModelTests.TestHelpMentionsToolsSection;
var
  H: string;
begin
  H := UsageText;
  AssertTrue('the help has the [tools] section', Pos('[tools]', H) > 0);
  AssertTrue('the help describes the 1/0 keys', Pos('1/0', H) > 0);
  AssertEquals('no --allow-write', 0, Pos('--allow-write', H));
  AssertEquals('no --no-write', 0, Pos('--no-write', H));
  AssertEquals('no --allow-shell', 0, Pos('--allow-shell', H));
  AssertEquals('no --no-shell', 0, Pos('--no-shell', H));
  AssertEquals('no --allow-http', 0, Pos('--allow-http', H));
  AssertEquals('no --no-http', 0, Pos('--no-http', H));
  { The shell settings remain flags and must not disappear together with the
    switches. }
  AssertTrue('--shell-timeout is still there', Pos('--shell-timeout', H) > 0);
  AssertTrue('--tool-output-lines is still there', Pos('--tool-output-lines', H) > 0);
end;

procedure TCliToolsModelTests.TestHelpHasNoCaFile;
var
  H: string;
begin
  H := UsageText;
  AssertEquals('no trust key', 0, Pos('ca' + '_file', H));
  { The name of the environment variable with the bundle path is not in the help
    either: the string is built in parts so that the test itself does not contain
    the searched text. }
  AssertEquals('no environment variable with the bundle',
    0, Pos('CA' + '_FILE', H));
end;

procedure TCliToolsModelTests.TestRemovedFlagsRejected;
var
  Cli: TCli;
  Err: string;
begin
  AssertFalse('--allow-write is rejected',
    ParseCli(['--allow-write'], Cli, Err));
  AssertTrue('the message about the option: ' + Err, Pos('--allow-write', Err) > 0);

  AssertFalse('--allow-shell is rejected',
    ParseCli(['--allow-shell'], Cli, Err));
  AssertFalse('--no-shell is rejected', ParseCli(['--no-shell'], Cli, Err));
  AssertFalse('--allow-http is rejected',
    ParseCli(['--allow-http'], Cli, Err));
  AssertFalse('--no-http is rejected', ParseCli(['--no-http'], Cli, Err));
  AssertFalse('-w is rejected', ParseCli(['-w'], Cli, Err));
end;

initialization
  RegisterTest(TCliFormatTests);
  RegisterTest(TCliSubAgentOutputTests);
  RegisterTest(TCliStepOutputTests);
  RegisterTest(TCliStepGatingTests);
  RegisterTest(TCliStepTaskGatingTests);
  RegisterTest(TCliToolOutputGatingTests);
  RegisterTest(TCliParseToolOutputLinesTests);
  RegisterTest(TEffectiveContextWindowTests);
  RegisterTest(TContextTokensTests);
  RegisterTest(TCliToolsModelTests);
  RegisterTest(TCliSessionTurnTests);
  RegisterTest(TCliUnknownToolKeyTests);
end.
