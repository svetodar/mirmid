unit test_stream;
{ Regression of TStreamPrinter (streaming output): no extra empty lines, the
  leading spaces (indentation) of lines are preserved. The scenarios are run in a
  separate bin/streamprobe process (stdout is a pipe, ANSI mode is forced), the
  raw output is checked through a simple terminal model. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry;

type
  TStreamPrinterTests = class(TTestCase)
  private
    { Runs a probe scenario and returns the raw output ('' — the probe is not
      built, the test is skipped). Cols > 0 — set the terminal width (the COLUMNS
      variable) for the probe process. }
    function RunProbe(const Scenario: string; Cols: Integer = 0): string;
    { A simple terminal model: lines, cursor (row/column). Supports CR, LF, ESC[K
      (erase to the end of the line), ESC[A (up) and plain text. AWidth > 0 — hard
      line wrapping at that width (as in a terminal): this is how the check that a
      partial line with a prefix does not overflow the terminal works. Returns the
      final screen state. }
    function SimulateTerminal(const S: string; AWidth: Integer = 0): TStringList;
    { Removes all whitespace characters (to compare the text after the word wrap,
      where the space at the break is dropped). }
    function NoSpace(const S: string): string;
  published
    procedure TestNoBlankLineForSpacesPartial;
    procedure TestIndentPreservedReasoning;
    procedure TestIndentPreservedContent;
    procedure TestPrefixWrapNotCorrupted;
    procedure TestDoneStatusKeptAfterSubSession;
    procedure TestPrepareStaticErasesStatus;
    procedure TestStepStatusWithoutPrefix;
    procedure TestStatusRedrawnOnToolCallAndResult;
    procedure TestToolOutputGating;
    procedure TestBlankLineAfterToolOutput;
    procedure TestEndStreamNoGlueBeforePrompt;
    procedure TestStatusStaysAfterTurn;
  end;

implementation

uses
  process, mirmid.util;

function TStreamPrinterTests.RunProbe(const Scenario: string;
  Cols: Integer): string;
var
  Exe: string;
  Proc: TProcess;
  Args, Env: TStringList;
  MS: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  { The executable extension comes from the test runner itself: on Windows it is
    ".exe", without it FileExists does not find the probe and the test is
    silently skipped. }
  Exe := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'streamprobe' + ExtractFileExt(ParamStr(0));
  if not FileExists(Exe) then
    Exit('');   { the probe is not built — the test is skipped }
  Args := TStringList.Create;
  Env := TStringList.Create;
  Proc := TProcess.Create(nil);
  try
    Args.Add(Scenario);
    Proc.Executable := Exe;
    Proc.Parameters := Args;
    Proc.Options := [poUsePipes];
    if Cols > 0 then
    begin
      { TProcess.Environment replaces the environment entirely, so it is filled
        with the current one plus COLUMNS for TermWidth. }
      EnvironmentToList(Env);
      Env.Values['COLUMNS'] := IntToStr(Cols);
      Proc.Environment := Env;
    end;
    Proc.Execute;
    MS := TMemoryStream.Create;
    try
      while True do
      begin
        N := Proc.Output.Read(Buf, Length(Buf));
        if N <= 0 then
          Break;
        MS.WriteBuffer(Buf, N);
      end;
      Proc.WaitOnExit(10000);
      MS.Position := 0;
      SetLength(Result, MS.Size);
      if MS.Size > 0 then
        MS.ReadBuffer(Result[1], MS.Size);
    finally
      MS.Free;
    end;
  finally
    Args.Free;
    Env.Free;
    Proc.Free;
  end;
end;

function TStreamPrinterTests.SimulateTerminal(const S: string;
  AWidth: Integer): TStringList;
var
  Row, Col, I, N: Integer;
  C: Char;
  Line: string;
begin
  Result := TStringList.Create;
  Result.Add('');
  Row := 0;
  Col := 0;
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    C := S[I];
    if C = #27 then
    begin
      if (I + 2 <= N) and (S[I + 1] = '[') then
      begin
        if S[I + 2] = 'K' then
        begin
          { Erase from the cursor to the end of the line. }
          if Col < Length(Result[Row]) then
            Result[Row] := Copy(Result[Row], 1, Col)
          else
            Result[Row] := '';
          Inc(I, 3);
          Continue;
        end
        else if S[I + 2] = 'A' then
        begin
          if Row > 0 then
            Dec(Row);
          Inc(I, 3);
          Continue;
        end;
      end;
      Inc(I);   { an unknown ESC sequence — skip it }
    end
    else if C = #13 then
    begin
      Col := 0;
      Inc(I);
    end
    else if C = #10 then
    begin
      Inc(Row);
      Col := 0;
      while Row >= Result.Count do
        Result.Add('');
      Inc(I);
    end
    else
    begin
      if (AWidth > 0) and (Col >= AWidth) then
      begin
        Inc(Row);
        Col := 0;
      end;
      while Row >= Result.Count do
        Result.Add('');
      if Col < Length(Result[Row]) then
        begin
          Line := Result[Row];
          Line[Col + 1] := C;
          Result[Row] := Line;
        end
      else
        Result[Row] := Result[Row] + C;
      Inc(Col);
      Inc(I);
    end;
  end;
end;

function TStreamPrinterTests.NoSpace(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] > ' ' then
      Result := Result + S[I];
end;

procedure TStreamPrinterTests.TestNoBlankLineForSpacesPartial;
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { The line "  word" arrives in chunks: leading spaces first, then the text. A
    partial line of spaces only must not leave an extra empty line: the screen has
    exactly the indented line, and the status line under it is temporary —
    EndStream erases it, it does not get into the log. }
  Out := RunProbe('spaces-partial');
  if Out = '' then
    Exit;
  { The status really was drawn — otherwise the screen check would be
    trivial. }
  AssertTrue('the status is drawn in the raw output', Pos('[st]', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 2, Screen.Count);
    AssertEquals('the indented line', '  word', Screen[0]);
    AssertEquals('under the text only the tail of the erased status', '',
      Screen[1]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('no rest of the status line on the screen', 0, Pos('[st]', All));
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestIndentPreservedReasoning;
var
  Out: string;
  Screen: TStringList;
begin
  { Reasoning: the leading spaces of a line (the indentation) are preserved. }
  Out := RunProbe('indent-reasoning');
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 2, Screen.Count);
    AssertEquals('the indentation is preserved', '  indented', Screen[0]);
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestIndentPreservedContent;
var
  Out: string;
  Screen: TStringList;
begin
  { Content: the leading spaces of a line (the indentation) are preserved. }
  Out := RunProbe('indent-content');
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 2, Screen.Count);
    AssertEquals('the indentation is preserved', '  indented', Screen[0]);
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestPrefixWrapNotCorrupted;
const
  { Must match WRAP_TEXT in tests/fixtures/streamprobe.pas. }
  WRAP_TEXT = 'alpha beta gamma delta epsilon zeta eta theta iota kappa ' +
              'lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega';
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { A long line arrives in small portions under the two-column subagent prefix.
    Earlier the partial line did not fit into the terminal (the prefix was not
    subtracted from the width), wrapped to the second line, and the redraw lost or
    duplicated parts of words. The scenario runs in a terminal 30 columns wide
    (COLUMNS) so that the partial line with the prefix overflows the line.
    Regression: TStreamPrinter.ContentWidth. }
  Out := RunProbe('prefix-wrap', 30);
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out, 30);
  try
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
  finally
    Screen.Free;
  end;
  All := StringReplace(All, '||', '', [rfReplaceAll]);
  All := StringReplace(All, '[st]', '', [rfReplaceAll]);
  AssertEquals('the text is not lost on the wrap with a prefix',
    NoSpace(WRAP_TEXT), NoSpace(All));
end;

procedure TStreamPrinterTests.TestDoneStatusKeptAfterSubSession;
const
  { The counters of the done line: the main context of the step, the step total
    and the model window. }
  DONE_COUNTERS = '|6k/2.2k/128k|';
var
  Out, All: string;
  Screen: TStringList;
  I, Dones: Integer;
begin
  { The end of a step sub-session: the temporary status line is
    erased (EndStream), and PersistDoneStatus fixes a done line in its place with
    the final counters and the short step name ("...] s1 done"). The previous
    status variants do not get into the log, and the static output and the next
    stream start from a clean line under the done line.
    Regression: TMirmidApp.PersistDoneStatus/DoneStatusText, StepShortName. }
  Out := RunProbe('done-status');
  if Out = '' then
    Exit;
  { The temporary status really was drawn and the done line is fixed —
    otherwise the screen check would be trivial. }
  AssertTrue('the step status is drawn in the raw output', Pos('[s1 2]', Out) > 0);
  AssertTrue('the done line with the short step name in the raw output',
    Pos('] s1 done', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 6, Screen.Count);
    AssertEquals('the first step line', '||first', Screen[0]);
    AssertEquals('the second step line', '||second', Screen[1]);
    AssertEquals('the done line under the step text', True,
      Pos('] s1 done', Screen[2]) > 0);
    AssertEquals('the done line has the final counters', True,
      Pos(DONE_COUNTERS, Screen[2]) > 0);
    AssertEquals('the static output under the done line', '||after done',
      Screen[3]);
    AssertEquals('the line of the next stream', '||third', Screen[4]);
    AssertEquals('under the last stream only the newline tail', '',
      Screen[5]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('the temporary step status is not on the screen', 0,
      Pos('[s1 2]', All));
    AssertEquals('the status line of the second stream is not on the screen', 0,
      Pos('[s2', All));
    Dones := 0;
    for I := 0 to Screen.Count - 1 do
      if Pos('] s1 done', Screen[I]) > 0 then
        Inc(Dones);
    AssertEquals('exactly one done line on the screen', 1, Dones);
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestPrepareStaticErasesStatus;
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { PrepareStatic with a drawn status line (FStatusShown=True) erases it instead
    of printing it into the scrollback. The scenario draws the status
    (BeginStream, FeedContent), calls PrepareStatic — the static line starts at
    the beginning of a clean line; then it draws the status again (DrawStatus, as
    after aeToolCall) and prepares the static output again. The final screen has
    neither the status line nor its tail, and a repeated PrepareStatic without a
    status does not leave an empty line. Regression:
    TStreamPrinter.PrepareStatic. }
  Out := RunProbe('prepare-static-status');
  if Out = '' then
    Exit;
  { The status really was drawn in the raw output — otherwise the screen check
    below would be trivial. }
  AssertTrue('the status is drawn in the raw output',
    Pos('long status tail', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 5, Screen.Count);
    AssertEquals('the text under the erased status', '||line one', Screen[0]);
    AssertEquals('the static output in place of the status',
      '||static after status', Screen[1]);
    AssertEquals('the static output in place of the drawn status',
      '||static after draw', Screen[2]);
    AssertEquals('the repeated PrepareStatic left no empty line',
      '||third static', Screen[3]);
    AssertEquals('under the last output only the newline tail', '', Screen[4]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('no rest of the status line on the screen', 0,
      Pos('long status tail', All));
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestStepStatusWithoutPrefix;
var
  Out, All: string;
  Screen: TStringList;
  I: Integer;
begin
  { A plan step sub-session is printed without the "│" prefix (print depth 0), and
    the step status line ("[HH:MM:SS|main/sub/total|%/%] name") is temporary: it is
    erased by EndStream, and on aeSubSessionEnd a done line with the short name
    "s1" and the final counters is fixed in its place. Only the nested subagent
    tool adds indentation — exactly one "│" per line; its result is printed
    statically (PrepareStatic) from the beginning of a clean line, and after it
    exits the prefix is empty again. Regression: FPrintDepth/FPrinter.Prefix, the
    FormatStepStatus format and the fixing of the done line. }
  Out := RunProbe('step-status');
  if Out = '' then
    Exit;
  { The temporary status really was drawn — otherwise the screen check would be
    trivial; its counters are main/step/window. }
  AssertTrue('the step status is drawn in the raw output',
    Pos('|6k/1.3k/128k|', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 6, Screen.Count);
    AssertEquals('the step text without indentation', 'step line', Screen[0]);
    AssertEquals('the text of the nested subagent with one │', '│sub line',
      Screen[1]);
    AssertEquals('the result of the nested subagent with one │', '│sub result',
      Screen[2]);
    AssertEquals('the step continuation without indentation', 'step tail',
      Screen[3]);
    AssertEquals('the done line of the step under the text', True,
      Pos('] s1 done', Screen[4]) > 0);
    AssertEquals('the done line has the final step counters', True,
      Pos('|6k/1.7k/128k|', Screen[4]) > 0);
    AssertEquals('under the done line only the newline tail', '', Screen[5]);
    All := '';
    for I := 0 to Screen.Count - 1 do
      All := All + Screen[I];
    AssertEquals('the temporary status (1.6k) is not on the screen', 0,
      Pos('|6k/1.6k/128k|', All));
    AssertEquals('the step name is not on the screen (only "s1" in the done line)',
      0, Pos('s1: step', All));
    AssertEquals('the [step] tag is nowhere in the output', 0, Pos('[step]', Out));
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestStatusRedrawnOnToolCallAndResult;
const
  { The step task texts from the step-task-gating scenario. }
  TASK1 = 's1: hidden task';
  TASK2 = 's2: task by flag';
  TASK3 = 's3: task by reasoning';
var
  Out, Tail, All: string;
  Screen: TStringList;
  I: Integer;
  CallPos, ResultPos: Integer;
  S1Task, S2Task, S3Task: Boolean;
  Statuses, Dones: Integer;
begin
  { The status line is temporary, but it is not lost while the tool runs: the call
    line and its result are printed in place of the drawn status (aeToolCall does
    ClearLine, aeToolResult does PrepareStaticOverStatus), and the status is then
    drawn again under them (DrawStatus). The scenario repeats these branches:
    under "[read] notes.md" a status with 3.2k is drawn, under "result text" one
    with 3.3k. By the end of the sub-session (EndStream) the temporary status is
    erased, and PersistDoneStatus fixes a done line with the short name "sN" and
    the final counters in its place — therefore there are no temporary statuses on
    the screen, and the number of done lines equals the number of finished steps.
    The status format is "[HH:MM:SS|main/sub/total|%/%] name" (the status first,
    there is no [step] tag). }
  Out := RunProbe('step-task-gating');
  if Out = '' then
    Exit;

  { Raw output: the status with the new counters is printed after the call line
    and after the result line — that is DrawStatus. }
  CallPos := Pos('[read] notes.md', Out);
  AssertTrue('the tool call line is printed', CallPos > 0);
  ResultPos := Pos('result text', Out);
  AssertTrue('the tool result line is printed', ResultPos > 0);
  Tail := Copy(Out, CallPos, ResultPos - CallPos);
  AssertTrue('the 3.2k status is drawn again under the tool call',
    Pos('3.2k', Tail) > 0);
  Tail := Copy(Out, ResultPos, Length(Out));
  AssertTrue('the 3.3k status is drawn again under the tool result',
    Pos('3.3k', Tail) > 0);

  Screen := SimulateTerminal(Out);
  try
    { The final screen: there are no temporary step statuses (EndStream erased
      them), the done lines stand under the text of every step in their place; the
      tasks (task1 gating) and the tool call/result lines also remained. After the
      last output — only the newline tail. }
    AssertEquals('lines on the screen', 12, Screen.Count);
    AssertEquals('the first step text', 'step one', Screen[0]);
    AssertEquals('the done line of the first step', True,
      Pos('] s1 done', Screen[1]) > 0);
    AssertEquals('the counters of the first step in the done line', True,
      Pos('|5k/1.2k/128k|', Screen[1]) > 0);
    AssertEquals('the task of the second step by --show-step-task', TASK2,
      Screen[2]);
    AssertEquals('the second step text', 'step two', Screen[3]);
    AssertEquals('the done line of the second step', True,
      Pos('] s2 done', Screen[4]) > 0);
    AssertEquals('the counters of the second step in the done line', True,
      Pos('|5k/2.2k/128k|', Screen[4]) > 0);
    AssertEquals('the task of the third step by --show-reasoning', TASK3,
      Screen[5]);
    AssertEquals('the third step text', 'step three', Screen[6]);
    AssertEquals('the tool call', '[read] notes.md', Screen[7]);
    AssertEquals('the tool result', 'result text', Screen[8]);
    AssertEquals('the empty separator line under the result', '',
      Screen[9]);
    AssertEquals('the done line of the third step under the result', True,
      Pos('] s3 done', Screen[10]) > 0);
    AssertEquals('the counters of the third step in the done line', True,
      Pos('|5k/3.3k/128k|', Screen[10]) > 0);
    AssertEquals('under the last output only the newline tail', '',
      Screen[11]);

    { Every line with counters on the screen is a done line: the temporary status
      variants (1.0k...3.1k) are erased, only the final ones remain. }
    All := '';
    Statuses := 0;
    Dones := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Pos('128k', Screen[I]) > 0 then
      begin
        Inc(Statuses);
        if Pos(' done', Screen[I]) > 0 then
          Inc(Dones);
      end;
    end;
    AssertEquals('exactly three lines with counters on the screen', 3, Statuses);
    AssertEquals('all of them are done lines', 3, Dones);
    AssertEquals('the temporary 3.1k status is not on the screen', 0,
      Pos('|5k/3.1k/128k|', All));

    { Gating of the step task (task1): with both flags off there is no line with
      the task (the step name was only in the erased status line); under
      --show-step-task (s2) and under --show-reasoning (s3) the task is printed as
      a separate line without the [step] tag. }
    S1Task := False;
    S2Task := False;
    S3Task := False;
    for I := 0 to Screen.Count - 1 do
    begin
      if Screen[I] = TASK1 then
        S1Task := True;
      if Screen[I] = TASK2 then
        S2Task := True;
      if Screen[I] = TASK3 then
        S3Task := True;
    end;
    AssertFalse('both flags off: there is no task of the first step', S1Task);
    AssertTrue('the task of the second step by --show-step-task', S2Task);
    AssertTrue('the task of the third step by --show-reasoning', S3Task);
    AssertEquals('the [step] tag is nowhere in the output', 0, Pos('[step]', Out));
  finally
    Screen.Free;
  end;
end;


procedure TStreamPrinterTests.TestToolOutputGating;
var
  Out, All: string;
  Screen: TStringList;
  I, Statuses, Dones, Analyzes: Integer;
begin
  { Gating of the tool output (ToolOutputVisible): the output is printed only
    together with the reasoning (--show-reasoning), in any session.
    The probe scenario: s1 — a step without --show-reasoning (the call and the
    result are hidden), s2 — the analysis with it (the shell command "$ ..." and
    the result are printed), then the main session without the flag (hidden) and
    with it (visible). The status line is redrawn (DrawStatus) even when the output
    itself is hidden, but by the end of the sub-session the temporary line is
    erased (EndStream), and in its place the done line "s1 done" / "analysis done"
    with the final counters is fixed. The main session has no fixing — its status
    is simply erased. }
  Out := RunProbe('tool-gating');
  if Out = '' then
    Exit;

  { The hidden output gets into the stream neither as a call line nor as a
    result. }
  AssertEquals('the tool call of the step is hidden', 0, Pos('[read] hidden.md',
    Out));
  AssertEquals('the tool result of the step is hidden', 0, Pos('hidden result',
    Out));
  { The main session without --show-reasoning is silent too. }
  AssertEquals('the tool call of the main session without the flag is hidden', 0,
    Pos('[write] main.txt', Out));
  AssertEquals('the tool result of the main session without the flag is hidden',
    0, Pos('main result', Out));
  { DrawStatus runs unconditionally — the status counters are visible
    (main/sub/total: 4.0k/1.3k/128k and 4.0k/1.4k/128k). }
  AssertTrue('the 1.3k status is drawn after the hidden call',
    Pos('|4k/1.3k/128k|', Out) > 0);
  AssertTrue('the 1.4k status is drawn after the hidden result',
    Pos('|4k/1.4k/128k|', Out) > 0);

  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 12, Screen.Count);
    AssertEquals('the first step text', 'step one', Screen[0]);
    AssertEquals('the done line of the step under the text', True,
      Pos('] s1 done', Screen[1]) > 0);
    AssertEquals('the counters of the step in the done line', True,
      Pos('|4k/1.4k/128k|', Screen[1]) > 0);
    AssertEquals('the analysis sub-session line', 'analysis line', Screen[2]);
    AssertEquals('the shell command of the analysis is visible', '$ echo shown',
      Screen[3]);
    AssertEquals('the tool result of the analysis is visible', 'shown result',
      Screen[4]);
    AssertEquals('the empty separator line under the result', '',
      Screen[5]);
    AssertEquals('the done line of the analysis under the separator', True,
      Pos('] analysis done', Screen[6]) > 0);
    AssertEquals('the counters of the analysis in the done line', True,
      Pos('|4.5k/500/128k|', Screen[6]) > 0);
    AssertEquals('the line of the main session without flags', 'main line',
      Screen[7]);
    AssertEquals('the line of the main session with --show-reasoning',
      'main line two', Screen[8]);
    AssertEquals('the tool call of the main session with the flag is visible',
      '[write] main2.txt', Screen[9]);
    AssertEquals('the tool result of the main session with the flag is visible',
      'main2 result', Screen[10]);
    AssertEquals('under the last output only the newline tail', '', Screen[11]);
    All := '';
    Statuses := 0;
    Dones := 0;
    Analyzes := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Pos('128k', Screen[I]) > 0 then
      begin
        Inc(Statuses);
        if Pos(' done', Screen[I]) > 0 then
          Inc(Dones);
      end;
      if Pos('] analysis done', Screen[I]) > 0 then
        Inc(Analyzes);
    end;
    { Only two done lines are on the screen (the step and the analysis): the
      temporary status variants are erased, and the main session has no status line
      at all. }
    AssertEquals('exactly two lines with counters on the screen', 2, Statuses);
    AssertEquals('both of them are done lines', 2, Dones);
    AssertEquals('the step name is not on the screen (only "s1" in the done line)',
      0, Pos('s1: hidden output', All));
    AssertEquals('the analysis label only in the done line', 1, Analyzes);
    AssertEquals('no statuses of the main session on the screen', 0,
      Pos('[main', All));
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestBlankLineAfterToolOutput;
const
  { The done line of the finished sub-session from the tool-blank scenario. }
  DONE_LINE = '[st 9 done]';
var
  Out: string;
  Screen: TStringList;
  I, Blanks, Doubles, Statuses: Integer;
begin
  { The empty line after the tool output: the result is separated from
    the next block of information — by exactly one empty line. The probe scenario
    repeats the aeToolResult/aeAssistant/aeSubSessionEnd branches: a result → a
    static answer block (the own empty line of the answer is suppressed by
    BlankSeparated), two tool results in a row, a result → the done line, and also
    the hidden output, which adds no empty lines.
    Regression: TStreamPrinter.RequestBlankLine/PrepareStatic/PersistStatus and the
    aeToolResult branch in TMirmidApp.OnAgentEvent. }
  Out := RunProbe('tool-blank');
  if Out = '' then
    Exit;
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 13, Screen.Count);
    AssertEquals('the line before the first tool', 'answer zero', Screen[0]);
    AssertEquals('the call of the first tool', '[read] a.txt', Screen[1]);
    AssertEquals('the result of the first tool', 'result a', Screen[2]);
    AssertEquals('the separator under the result', '', Screen[3]);
    AssertEquals('the model answer under the separator', 'answer one', Screen[4]);
    AssertEquals('the call of the second tool', '[read] b.txt', Screen[5]);
    AssertEquals('the result of the second tool', 'result b', Screen[6]);
    AssertEquals('the separator between the tool results', '', Screen[7]);
    AssertEquals('the call of the third tool', '[read] c.txt', Screen[8]);
    AssertEquals('the result of the third tool', 'result c', Screen[9]);
    AssertEquals('the separator before the done line', '', Screen[10]);
    AssertEquals('the done line under the separator', DONE_LINE, Screen[11]);
    AssertEquals('under the last output only the newline tail', '', Screen[12]);

    { The hidden output added no empty lines: there are exactly three empty lines
      (one per visible tool result) plus the newline tail under the last output;
      there are no two empty lines in a row (no double separator). }
    Blanks := 0;
    Doubles := 0;
    Statuses := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      if Screen[I] = '' then
      begin
        Inc(Blanks);
        if (I > 0) and (Screen[I - 1] = '') then
          Inc(Doubles);
      end;
      { No temporary status lines remain on the screen: the only line starting
        with "[st " is the fixed done line. }
      if (Copy(Screen[I], 1, 4) = '[st ') and (Pos(' done', Screen[I]) = 0) then
        Inc(Statuses);
    end;
    AssertEquals('exactly four empty lines on the screen', 4, Blanks);
    AssertEquals('no empty lines in a row (no double separator)', 0, Doubles);
    AssertEquals('no temporary status lines on the screen', 0, Statuses);
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestEndStreamNoGlueBeforePrompt;
const
  { The s1/s2 status markers from the endstream-prompt scenario. }
  TAIL_A = 'tail-a';
  TAIL_B = 'tail-b';
  PROMPT = '|> ';
var
  Out, All: string;
  Screen: TStringList;
  I, Prompts: Integer;
begin
  { The end of a stream leaves no status line in the log: the next output (the
    REPL prompt after PrepareStatic) starts at the beginning of a clean line.
    Earlier EndStream printed the status as a separate line (WriteLn), so the
    prompt ended up under the rest of the status, and the unfinished last line
    could glue to it. The scenario repeats both branches: s1 — an unfinished last
    line and a drawn status, s2 — a finished line and the status under it.
    Regression: TStreamPrinter.EndStream. }
  Out := RunProbe('endstream-prompt');
  if Out = '' then
    Exit;
  { The statuses really were drawn — otherwise the screen check below would be
    trivial. }
  AssertTrue('the s1 status is drawn in the raw output', Pos(TAIL_A, Out) > 0);
  AssertTrue('the s2 status is drawn in the raw output', Pos(TAIL_B, Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 6, Screen.Count);
    AssertEquals('the line before the unfinished one', '||first', Screen[0]);
    AssertEquals('the unfinished line stayed whole', '||pending tail',
      Screen[1]);
    AssertEquals('the prompt after the stream with the unfinished line', PROMPT,
      Screen[2]);
    AssertEquals('the finished line of the second stream', '||second', Screen[3]);
    AssertEquals('the prompt after the finished stream', PROMPT, Screen[4]);
    AssertEquals('under the last prompt only the newline', '', Screen[5]);

    { Neither a rest of the status nor an empty line from the status WriteLn is on
      the screen; there are exactly two prompts, and both stand at the beginning
      of a line. }
    All := '';
    Prompts := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Copy(Screen[I], 1, Length(PROMPT)) = PROMPT then
        Inc(Prompts);
    end;
    AssertEquals('exactly two prompts', 2, Prompts);
    AssertEquals('no rest of the s1 status on the screen', 0, Pos(TAIL_A, All));
    AssertEquals('no rest of the s2 status on the screen', 0, Pos(TAIL_B, All));
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestStatusStaysAfterTurn;
const
  { The final status lines from the persist-status scenario. }
  FINAL1 = '||[turn 1 final 2.1k/128k]';
  FINAL2 = '||[turn 2 final 2.2k/128k]';
  PROMPT = '|> ';
var
  Out, All: string;
  Screen: TStringList;
  I, Finals: Integer;
begin
  { After a turn the final status line stays on the screen: the
    temporary status is erased by EndStream, and PersistStatus (the
    KeepContextStatus branch in streaming mode) fixes the line in the log — under
    the answer, with the final counters. The next REPL prompt goes from a clean
    line under it, and there is exactly one status line per turn (the previous
    variants with smaller counters are erased). Regression:
    TStreamPrinter.PersistStatus. }
  Out := RunProbe('persist-status');
  if Out = '' then
    Exit;
  { The temporary statuses really were drawn — otherwise the screen check would be
    trivial. }
  AssertTrue('the status of the first turn is drawn in the raw output',
    Pos('[turn 1 1.0k]', Out) > 0);
  AssertTrue('the final status of the second turn is drawn',
    Pos('2.2k/128k', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 7, Screen.Count);
    AssertEquals('the first answer line', '||answer one', Screen[0]);
    AssertEquals('the unfinished answer line stayed whole', '||answer tail',
      Screen[1]);
    AssertEquals('the final status of the first turn under the answer', FINAL1,
      Screen[2]);
    AssertEquals('the prompt under the status line', PROMPT, Screen[3]);
    AssertEquals('the answer of the second turn', '||answer two', Screen[4]);
    AssertEquals('the final status of the second turn under the answer', FINAL2,
      Screen[5]);
    AssertEquals('under the last status only the newline', '', Screen[6]);

    { There are no temporary statuses on the screen: there is only one status line
      per turn — the final one (any line of the form "||[" beyond the two exact
      comparisons above is already superfluous). }
    All := '';
    Finals := 0;
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      if Copy(Screen[I], 1, 3) = '||[' then
        Inc(Finals);
    end;
    AssertEquals('exactly two status lines on the screen', 2, Finals);
    AssertEquals('the temporary status of the first turn is not on the screen', 0,
      Pos('[turn 1 1.0k]', All));
    AssertEquals('the late temporary status of the first turn is not on the screen',
      0, Pos('[turn 1 3.0k]', All));
    AssertEquals('the status of the second turn without the total is not on the '
      + 'screen', 0, Pos('[turn 2 start]', All));
  finally
    Screen.Free;
  end;
end;


initialization
  RegisterTest(TStreamPrinterTests);
end.
