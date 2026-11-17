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
    { A simple terminal model: lines, cursor (row/column). Supports CR, LF, any
      CSI sequence (ESC '[' parameters final byte: colour SGR is skipped, ESC[K
      erases to the end of the line, ESC[nA moves the cursor up by n lines) and
      plain text. AWidth > 0 - hard line wrapping at that width (as in a
      terminal): this is how the check that a partial line with a prefix does not
      overflow the terminal works. Returns the final screen state. }
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
    procedure TestLongStatusTruncatedToOneLine;
    procedure TestTableFitsTerminalWidth;
    procedure TestTableRedrawShrinks;
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
  Row, Col, I, J, K, N, Count: Integer;
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
      if (I + 1 <= N) and (S[I + 1] = '[') then
      begin
        { CSI: ESC '[' parameters (0x20-0x3F), then the final byte
          (0x40-0x7E). Colour SGR sequences (the "ESC[38;2;45;45;45m" of the
          table frames) do not change the screen, so the whole sequence is
          skipped - otherwise its parameters would land in the screen text. }
        J := I + 2;
        while (J <= N) and (S[J] >= #$20) and (S[J] <= #$3F) do
          Inc(J);
        if (J > N) or (S[J] < #$40) then
        begin
          Inc(I);   { an incomplete sequence - skip the ESC }
          Continue;
        end;
        Count := 0;
        for K := I + 2 to J - 1 do
          if (S[K] >= '0') and (S[K] <= '9') then
            Count := Count * 10 + (Ord(S[K]) - Ord('0'));
        if Count = 0 then
          Count := 1;
        if S[J] = 'K' then
        begin
          { Erase from the cursor to the end of the line. }
          while Row >= Result.Count do
            Result.Add('');
          if Col < Length(Result[Row]) then
            Result[Row] := Copy(Result[Row], 1, Col)
          else
            Result[Row] := '';
        end
        else if S[J] = 'A' then
        begin
          { Cursor up by Count lines: redrawing a group moves it back over the
            lines already drawn. }
          Dec(Row, Count);
          if Row < 0 then
            Row := 0;
        end
        else if S[J] = 'B' then
        begin
          { Cursor down by Count lines: erasing the lines a shorter redraw left
            below the new bottom border. }
          Inc(Row, Count);
          while Row >= Result.Count do
            Result.Add('');
        end;
        I := J + 1;
        Continue;
      end;
      Inc(I);   { an unknown ESC sequence - skip it }
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

procedure TStreamPrinterTests.TestLongStatusTruncatedToOneLine;
const
  { The terminal width of the probe (the COLUMNS variable) and the width the
    status may occupy: the content width (40, the prefix is empty) minus one
    column — moving the cursor into the very last cell makes some terminals wrap. }
  COLS = 40;
  CONTENT = COLS - 1;
var
  Out, All: string;
  Screen, Wrapped: TStringList;
  I, Statuses: Integer;
begin
  { A status wider than the terminal is cut to ContentWidth - 1 visible columns,
    so it takes exactly one terminal line and the next redraw (ClearLine +
    PrintStatus) replaces the whole line instead of clearing only the last of its
    wrapped lines: the tail of the old status must not stay in the scrollback. The
    scenario repeats the aeStepStart/aeToolCall/aeAssistant/aeSubSessionEnd
    branches with grown counters, the long step name ends with "TailMarker", and
    the done line (PersistStatus) is cut the same way. Regression:
    TStreamPrinter.PrintStatus/ContentWidth and TruncateVisible. }
  Out := RunProbe('long-status', COLS);
  if Out = '' then
    Exit;
  { The long statuses really are drawn (the counters grow from one draw to the
    next) and the tail is cut already in the raw output. }
  AssertTrue('the 1.2k status is drawn', Pos('|6k/1.2k/128k|', Out) > 0);
  AssertTrue('the 1.3k done status is drawn', Pos('|6k/1.3k/128k|', Out) > 0);
  AssertEquals('the tail of the long status is cut off in the raw output', 0,
    Pos('TailMarker', Out));

  { A hard line wrap at the terminal width must not add a single line: every
    drawn status fits into one terminal line. }
  Screen := SimulateTerminal(Out);
  Wrapped := SimulateTerminal(Out, COLS);
  try
    AssertEquals('no status is wrapped by the terminal', Screen.Count,
      Wrapped.Count);
    Statuses := 0;
    All := '';
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      AssertTrue('no line is wider than the content width: ' + Screen[I],
        Length(Screen[I]) <= CONTENT);
      if Pos('128k', Screen[I]) > 0 then
        Inc(Statuses);
    end;

    { The static output starts on clean lines: neither the tail of a status nor
      the long step name glues to it. }
    AssertEquals('lines on the screen', 7, Screen.Count);
    AssertEquals('the first step line', 'step line one', Screen[0]);
    AssertEquals('the second step line', 'step line two', Screen[1]);
    AssertEquals('the tool call in place of the erased status', '[read] notes.md',
      Screen[2]);
    AssertEquals('the answer in place of the erased status', 'answer one', Screen[3]);
    AssertEquals('the done line is cut to the content width', CONTENT,
      Length(Screen[4]));
    AssertTrue('the done line carries the final status',
      Pos('|6k/1.3k/128k|', Screen[4]) > 0);
    AssertEquals('the static output under the done line', 'after long status',
      Screen[5]);
    AssertEquals('under the last output only the newline tail', '', Screen[6]);

    { Exactly the temporary statuses that were erased are gone: a single line with
      the final counters (the done line) remains, and the tail of the long name is
      nowhere on the screen. }
    AssertEquals('only the done line with the counters remains', 1, Statuses);
    AssertEquals('the long status tail is not on the screen', 0,
      Pos('TailMarker', All));
  finally
    Wrapped.Free;
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestTableFitsTerminalWidth;
const
  { The terminal width of the probe (the COLUMNS variable), the subagent prefix
    the table is printed under and the visible content width left for it. }
  COLS = 40;
  PREFIX = '||';
  CONTENT = COLS - Length(PREFIX);
  { The frames of the drawn table: the columns take the whole content width
    (padding and separators included), so the box drawing never runs past the
    terminal edge and the table is never wrapped by the terminal itself. }
  TOP = '||┌───────┬───────────────────┬────────┐';
  HEADER = '||│ Name  │ Description       │ Owner  │';
  RULE = '||├───────┼───────────────────┼────────┤';
  BOTTOM = '||└───────┴───────────────────┴────────┘';
  { The first visible character of a table: it counts the tables on the screen
    (the prefix is compared as a whole, the box drawing is UTF-8). }
  TOP_LEFT = '||┌';
var
  Out, All: string;
  Screen: TStringList;
  I, Tables: Integer;
begin
  { A table wider than the terminal is printed under the "||" subagent prefix: the
    cells are wrapped by words, the column widths are distributed over the content
    width, and every record takes as many physical lines as its highest cell. The
    erase-and-redraw of the streamed table moves the cursor up by the number of
    DRAWN lines, so the box drawing must never be cut by a hard terminal wrap.
    Regression: TStreamPrinter.ShowTable/ContentWidth and RenderTable(MaxWidth). }
  Out := RunProbe('table', COLS);
  if Out = '' then
    Exit;
  { The table really was drawn and the long cells really were wrapped: the whole
    description never appears on one line. }
  AssertTrue('the header is drawn', Pos('Description', Out) > 0);
  AssertTrue('the first row is drawn', Pos('alpha', Out) > 0);
  AssertTrue('the description is wrapped by words',
    Pos('first row with a', Out) > 0);
  AssertEquals('the long description never stays on one line', 0,
    Pos('first row with a longer description', Out));
  { The whole table, prefix included, takes exactly the terminal width: the content
    fills the CONTENT columns and not a single column is wasted. }
  AssertEquals('the top border fills the terminal width', COLS,
    VisibleLen(TOP));
  AssertEquals('the table body takes the whole content width', CONTENT,
    VisibleLen(Copy(TOP, Length(PREFIX) + 1, MaxInt)));

  { The screen without a hard wrap is checked line by line: a drawn line wider than
    the terminal would be wrapped by the terminal itself and the erase-and-redraw
    of the table (ESC[nA moves back by the number of DRAWN lines) would leave
    remains of the table in the scrollback. }
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 16, Screen.Count);
    AssertEquals('the paragraph above the table', PREFIX + 'answer with a table',
      Screen[0]);
    AssertEquals('the top border of the table', TOP, Screen[1]);
    AssertEquals('the header row', HEADER, Screen[2]);
    AssertEquals('the rule under the header', RULE, Screen[3]);
    { The first record is three lines high (the description is the highest cell)
      and the shorter cells are aligned to its top. }
    AssertEquals('the first line of the first record',
      '||│ alpha │ first row with a  │ team   │', Screen[4]);
    AssertEquals('the second line of the first record',
      '||│       │ longer            │ one    │', Screen[5]);
    AssertEquals('the third line of the first record',
      '||│       │ description       │        │', Screen[6]);
    AssertEquals('the first line of the second record',
      '||│ beta  │ second row of     │ team   │', Screen[7]);
    AssertEquals('the second line of the second record',
      '||│       │ text              │ two    │', Screen[8]);
    AssertEquals('the first line of the third record',
      '||│ gamma │ third row closes  │ team   │', Screen[9]);
    AssertEquals('the second line of the third record',
      '||│       │ the table         │ three  │', Screen[10]);
    AssertEquals('the bottom border of the table', BOTTOM, Screen[11]);
    { The closing paragraph, the done line and the static line start on clean lines
      under the bottom border - nothing glues to the table. }
    AssertEquals('the paragraph under the table', PREFIX + 'after the table',
      Screen[12]);
    AssertEquals('the done line under the paragraph', PREFIX + '[tbl 9 done]',
      Screen[13]);
    AssertEquals('the static line under the done line',
      PREFIX + 'static after table', Screen[14]);
    AssertEquals('under the last line only the newline tail', '', Screen[15]);

    { The drawn lines never pass the terminal edge, and only the last redraw is on
      the screen: every earlier (narrower) draw was erased, so there is exactly one
      table and none of its records is lost. }
    Tables := 0;
    All := '';
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      AssertTrue('no line is wider than the terminal: ' + Screen[I],
        VisibleLen(Screen[I]) <= COLS);
      if Copy(Screen[I], 1, Length(TOP_LEFT)) = TOP_LEFT then
        Inc(Tables);
    end;
    AssertEquals('exactly one table on the screen', 1, Tables);
    AssertTrue('the last record is on the screen', Pos('the table', All) > 0);
    AssertTrue('the wrapped tail of the description is on the screen',
      Pos('description', All) > 0);
    AssertTrue('the short cell of the first record is on the screen',
      Pos('one', All) > 0);
  finally
    Screen.Free;
  end;
end;

procedure TStreamPrinterTests.TestTableRedrawShrinks;
const
  { The terminal width of the probe, the subagent prefix and the visible content
    width left for the table. }
  COLS = 40;
  PREFIX = '||';
  { The last table row redistributes the column widths so that the drawn table
    becomes two lines SHORTER than the previous rendering. The final table is
    checked line by line: the erase-and-redraw has to clear the lines the taller
    table left below, otherwise its bottom border stays on the screen. }
  TOP = '||┌──────────────┬───────────┬─────────┐';
  BOTTOM = '||└──────────────┴───────────┴─────────┘';
  TOP_LEFT = '||┌';
var
  Out, All: string;
  Screen: TStringList;
  I, Tables: Integer;
begin
  { Regression: TStreamPrinter.ShowTable. The height of a streamed table is not
    monotone (a new line can unwrap an earlier cell), so the redraw must erase
    the remainder of the previous, taller rendering. }
  Out := RunProbe('table-shrink', COLS);
  if Out = '' then
    Exit;
  AssertTrue('the table is drawn', Pos('note text', Out) > 0);
  Screen := SimulateTerminal(Out);
  try
    AssertEquals('lines on the screen', 15, Screen.Count);
    AssertEquals('the paragraph above the table',
      PREFIX + 'answer with a shrinking table', Screen[0]);
    AssertEquals('the top border of the final table', TOP, Screen[1]);
    AssertEquals('the first header line',
      PREFIX + '│ note the     │ up        │ text    │', Screen[2]);
    AssertEquals('the second header line',
      PREFIX + '│ first item   │           │ data    │', Screen[3]);
    AssertEquals('the rule under the header',
      PREFIX + '├──────────────┼───────────┼─────────┤', Screen[4]);
    AssertEquals('the first row, first line',
      PREFIX + '│ note text    │ note text │ text    │', Screen[5]);
    AssertEquals('the first row, second line',
      PREFIX + '│ data rows    │ data rows │ data    │', Screen[6]);
    AssertEquals('the second row, first line',
      PREFIX + '│ row          │ text data │ cells   │', Screen[7]);
    AssertEquals('the second row, second line',
      PREFIX + '│              │ rows      │         │', Screen[8]);
    AssertEquals('the third row',
      PREFIX + '│ text data    │ cells     │ row     │', Screen[9]);
    AssertEquals('the bottom border of the final table', BOTTOM, Screen[10]);
    { Nothing of the taller previous table is left between the bottom border and
      the following output. }
    AssertEquals('the paragraph under the table', PREFIX + 'after the table',
      Screen[11]);
    AssertEquals('the done line under the paragraph', PREFIX + '[sh 9 done]',
      Screen[12]);
    AssertEquals('the static line under the done line',
      PREFIX + 'static after the shrinking table', Screen[13]);
    AssertEquals('under the last line only the newline tail', '', Screen[14]);

    { Only the last redraw is on the screen and every line fits the terminal. }
    Tables := 0;
    All := '';
    for I := 0 to Screen.Count - 1 do
    begin
      All := All + Screen[I];
      AssertTrue('no line is wider than the terminal: ' + Screen[I],
        VisibleLen(Screen[I]) <= COLS);
      if Copy(Screen[I], 1, Length(TOP_LEFT)) = TOP_LEFT then
        Inc(Tables);
    end;
    AssertEquals('exactly one table on the screen', 1, Tables);
  finally
    Screen.Free;
  end;
end;

initialization
  RegisterTest(TStreamPrinterTests);
end.
