program streamprobe;
{ Probe of TStreamPrinter (streaming output): runs a scenario and writes the raw
  output (with ANSI codes) to stdout. Used by tests/test_stream.pas.
  Argument: the scenario name. }

{$mode objfpc}{$H+}

uses
  SysUtils, mirmid.cli;

procedure RunScenario(const Name: string);
const
  { A long line for the prefix-wrap scenario (longer than 80 columns). }
  WRAP_TEXT = 'alpha beta gamma delta epsilon zeta eta theta iota kappa ' +
              'lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega';
  { Context of the main session (the main counter) for the planner scenarios: in
    plan mode the main session does not call the model, so the value comes from
    the agent estimate cache. The numbers differ per scenario so that the raw
    output shows the main counter substitution; the status line format is
    "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%]". }
  MAIN_CTX_STEP = 6000;
  MAIN_CTX_TASK = 5000;
  MAIN_CTX_TOOL = 4000;
  MAIN_CTX_ANALYSIS = 4500;
var
  P: TStreamPrinter;
  I, N: Integer;
  { The variants of the long status in the long-status scenario (the counters
    grow from one draw to the next, as in a real sub-session). }
  S1, S2, S3: string;
begin
  P := TStreamPrinter.Create;
  try
    P.Live := True;   { force ANSI mode: stdout may be a pipe }
    P.BeginStream('[st]');
    if Name = 'spaces-partial' then
    begin
      { The line arrives in three chunks: leading spaces first, then the text,
        then the newline. }
      P.FeedReasoning('  ', '[st]');
      P.FeedReasoning('word', '[st]');
      P.FeedReasoning(#10, '[st]');
    end
    else if Name = 'indent-reasoning' then
      P.FeedReasoning('  indented' + #10, '[st]')
    else if Name = 'indent-content' then
      P.FeedContent('  indented' + #10, '[st]')
    else if Name = 'prefix-wrap' then
    begin
      { Subagent prefix of two columns: a partial line must wrap taking the
        prefix into account and must not occupy two terminal lines (otherwise
        the redraw lost and duplicated parts of words). }
      P.Prefix := '||';
      N := Length(WRAP_TEXT);
      I := 1;
      while I <= N do
      begin
        P.FeedContent(Copy(WRAP_TEXT, I, 5), '[st]');
        Inc(I, 5);
      end;
      P.FeedContent(#10, '[st]');
    end
    else if Name = 'done-status' then
    begin
      { End of a step sub-session: the temporary status line is
        erased (EndStream), and PersistStatus fixes a done line in its place with
        the final counters and the short step name
        ("[HH:MM:SS|main/sub/total|%/%] s1 done"). The previous status variant
        "[s1 2]" does not get into the log, and the static output and the next
        stream start from a clean line under the done line. Regression:
        TMirmidApp.PersistDoneStatus/DoneStatusText, StepShortName,
        TStreamPrinter.PersistStatus/EndStream/PrepareStatic. }
      P.Prefix := '||';
      P.BeginStream('[s1 start]');
      P.FeedContent('first' + #10, '[s1 1]');
      P.FeedContent('second' + #10, '[s1 2]');
      P.EndStream('[s1 end]');
      { aeSubSessionEnd: DoneStatusText + ' done' via PersistStatus. }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: step'), 2200, 128000,
        MAIN_CTX_STEP) + ' done');
      { Static output (like aeToolResult) starts on a clean line under the fixed
        done line. }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'after done');
      P.BeginStream('[s2]');
      P.FeedContent('third' + #10, '[s2 1]');
      P.EndStream('[s2 end]');
    end
    else if Name = 'prepare-static-status' then
    begin
      { PrepareStatic with a drawn status line (FStatusShown=True) erases it
        instead of printing it into the scrollback. The scenario repeats the
        aeToolResult/static output branch: the status is drawn (BeginStream,
        FeedContent) — the static line takes its place from the start of a clean
        line; the status is drawn again (DrawStatus, as after aeToolCall) —
        PrepareStatic erases it again. A repeated PrepareStatic without a status
        does not leave an empty line. Regression: TStreamPrinter.PrepareStatic. }
      P.Prefix := '||';
      P.BeginStream('[s1 start long status tail]');
      P.FeedContent('line one' + #10, '[s1 1 long status tail]');
      { Static output with a drawn status (the aeToolResult branch). }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'static after status');
      { The status is drawn again (DrawStatus after the call line) — erase it. }
      P.DrawStatus('[s1 2 long status tail]');
      P.PrepareStatic;
      WriteLn(P.Prefix + 'static after draw');
      { No status: PrepareStatic prints nothing and adds no line. }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'third static');
    end
    else if Name = 'endstream-prompt' then
    begin
      { The end of a stream leaves no status line, so the next output (the REPL
        prompt after PrepareStatic) starts at the beginning of a clean line. The
        scenario repeats the Repl branches: s1 — a stream with an unfinished last
        line and a status drawn under it (EndStream prints it as a complete line
        and erases the status); s2 — a stream with a finished last line (only the
        status is erased). The "|> " prompt is printed without a status tail and
        does not glue to the stream text. Regression:
        TStreamPrinter.EndStream. }
      P.Prefix := '||';
      P.BeginStream('[s1 1 tail-a]');
      P.FeedContent('first' + #10, '[s1 2 tail-a]');
      { Unfinished last line: drawn, the status under it. }
      P.FeedContent('pending tail', '[s1 3 tail-a]');
      P.EndStream('[s1 4 tail-a]');
      { Repl: clear the status, then the prompt. }
      P.PrepareStatic;
      Write('|> ');
      WriteLn;   { the user pressed Enter }

      { s2: the last line is finished by a newline — only the text and the
        status drawn under it are on the screen. }
      P.BeginStream('[s2 1 tail-b]');
      P.FeedContent('second' + #10, '[s2 2 tail-b]');
      P.EndStream('[s2 3 tail-b]');
      P.PrepareStatic;
      Write('|> ');
      WriteLn;
    end
    else if Name = 'step-status' then
    begin
      { A plan step sub-session is printed without the "│" prefix (print depth
        0): the step status line is "[HH:MM:SS|main/sub/total|main-percent%/
        sub-percent%] name" (the status first, no [step] tag) — and the step text
        goes from the beginning of the line. The first counter is the main
        session context from the estimate cache (MAIN_CTX_STEP), the second and
        the third are the step and the common model window. The status line is
        temporary: EndStream erases it, and on aeSubSessionEnd PersistDoneStatus
        fixes a done line in its place with the short step name ("...] s1 done")
        and the final counters — the previous status variants do not get into the
        log. Only the subagent tool adds indentation — a subagent nested in a
        step gets exactly one "│", and its result is printed as a static line in
        place of the erased status; after it exits the prefix is empty again.
        Regression: FPrintDepth/FPrinter.Prefix, the FormatStepStatus format and
        PersistStatus. }
      P.Prefix := '';
      P.BeginStream(FormatStepStatus('s1: step', 1200, 128000, MAIN_CTX_STEP));
      P.FeedContent('step line' + #10,
        FormatStepStatus('s1: step', 1300, 128000, MAIN_CTX_STEP));
      { Nested subagent tool: the only place with a prefix. }
      P.Prefix := DepthPrefix(1);
      P.BeginStream('sub status');
      P.FeedContent('sub line' + #10, 'sub status');
      P.EndStream('sub status');   { the drawn subagent status is erased }
      { aeToolResult of the subagent: the ready answer (with the prefix) takes
        the place of the erased status — the line starts with "│", there is no
        status tail. }
      P.PrepareStatic;
      WriteLn(P.Prefix + 'sub result');
      { Back to the step level: the print prefix is empty again. }
      P.Prefix := '';
      P.BeginStream(FormatStepStatus('s1: step', 1500, 128000, MAIN_CTX_STEP));
      P.FeedContent('step tail' + #10,
        FormatStepStatus('s1: step', 1600, 128000, MAIN_CTX_STEP));
      P.EndStream(FormatStepStatus('s1: step', 1700, 128000, MAIN_CTX_STEP));
      { aeSubSessionEnd: the step line is erased, and a done line with the short
        name "s1" and the final counters is fixed in its place. }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: step'), 1700, 128000,
        MAIN_CTX_STEP) + ' done');
    end
    else if Name = 'step-task-gating' then
    begin
      { Gating of the plan step task (task1) and the fixing of the done line.
        The scenario repeats the aeStepStart/aeToolCall/aeToolResult branches:
        the step name (the task) is printed without the [step] tag only when
        StepTaskVisible is true (that is under --show-step-task or
        --show-reasoning, with both off it is not printed), and it is printed
        statically, in place of the erased status. The step name in the status
        line (FormatStepStatus: the status
        "[HH:MM:SS|main/sub/total|main-percent%/sub-percent%]" first, then the
        name) lives only in the terminal: EndStream erases it, and on
        aeSubSessionEnd PersistDoneStatus fixes the done line with the short name
        "sN" and the final counters — there are no temporary status lines in the
        log, only the done lines of the finished steps remain. The first counter
        of the line is the main session context (MAIN_CTX_TASK), the second is
        the step, the third is the common model window. The tool call and the
        result are printed in place of the drawn status
        (PrepareStatic/PrepareStaticOverStatus), and the status is then drawn
        again (DrawStatus) — the counters grow under them. }
      P.Prefix := '';

      { s1: both flags are off — there is no task, the step work starts right
        with the status line (the step name is still in it, but it is temporary
        and is replaced by the done line when the step finishes). }
      if StepTaskVisible(False, False, False) then
      begin
        P.PrepareStatic;
        WriteLn('s1: hidden task');
      end;
      P.BeginStream(FormatStepStatus('s1: hidden task', 1000, 128000,
        MAIN_CTX_TASK));
      P.FeedContent('step one' + #10,
        FormatStepStatus('s1: hidden task', 1100, 128000, MAIN_CTX_TASK));
      P.EndStream(FormatStepStatus('s1: hidden task', 1200, 128000,
        MAIN_CTX_TASK));
      { aeSubSessionEnd: the temporary step line is erased, and PersistStatus
        fixes the done line "s1 done" with the final counters. }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: hidden task'), 1200,
        128000, MAIN_CTX_TASK) + ' done');

      { s2: only --show-step-task is on — the task is printed before the step
        work, from the beginning of a clean line (the step status is already
        erased). }
      if StepTaskVisible(True, False, False) then
      begin
        P.PrepareStatic;
        WriteLn('s2: task by flag');
      end;
      P.BeginStream(FormatStepStatus('s2: task by flag', 2000, 128000,
        MAIN_CTX_TASK));
      P.FeedContent('step two' + #10,
        FormatStepStatus('s2: task by flag', 2100, 128000, MAIN_CTX_TASK));
      P.EndStream(FormatStepStatus('s2: task by flag', 2200, 128000,
        MAIN_CTX_TASK));
      P.PersistStatus(FormatStepStatus(StepShortName('s2: task by flag'), 2200,
        128000, MAIN_CTX_TASK) + ' done');

      { s3: only --show-reasoning is on (--show-step-result is set too, but it
        does not affect the task) — the task is printed. }
      if StepTaskVisible(False, True, True) then
      begin
        P.PrepareStatic;
        WriteLn('s3: task by reasoning');
      end;
      P.BeginStream(FormatStepStatus('s3: task by reasoning', 3000, 128000,
        MAIN_CTX_TASK));
      P.FeedContent('step three' + #10,
        FormatStepStatus('s3: task by reasoning', 3100, 128000,
          MAIN_CTX_TASK));
      P.EndStream(FormatStepStatus('s3: task by reasoning', 3100, 128000,
        MAIN_CTX_TASK));

      { aeToolCall: after the end of the stream the status is no longer on the
        screen (EndStream erased it), so the call line is printed from the
        beginning of a clean line — without gluing to the status tail. The
        application ClearLine is private, here it is emulated with CR + ESC[K.
        Then DrawStatus draws the status with the new counters (3.1k → 3.2k) so
        that it does not disappear while the tool runs. }
      P.PrepareStatic;
      Write(#13, #27, '[K');
      WriteLn('[read] notes.md');
      P.DrawStatus(FormatStepStatus('s3: task by reasoning', 3200, 128000,
        MAIN_CTX_TASK));

      { aeToolResult: the drawn status is erased, the result takes its place,
        the status is drawn again under the result. }
      P.PrepareStaticOverStatus;
      WriteLn('result text');
      { Separator after the tool output. }
      P.RequestBlankLine;
      P.DrawStatus(FormatStepStatus('s3: task by reasoning', 3300, 128000,
        MAIN_CTX_TASK));
      { aeSubSessionEnd: the last variant of the temporary status (3.3k) is
        erased and replaced by the done line "s3 done" — the counters 3.2k/3.3k
        remain only in the raw output. }
      P.PersistStatus(FormatStepStatus(StepShortName('s3: task by reasoning'),
        3300, 128000, MAIN_CTX_TASK) + ' done');
    end
    else if Name = 'tool-gating' then
    begin
      { Gating of the tool output (ToolOutputVisible): the tool call and result
        lines are printed only together with the reasoning — --show-reasoning.
        The session role plays no part: in a step and in the main session
        without the flag the output is hidden, in the analysis and in the main
        session with the flag it is visible. The scenario repeats the
        aeToolCall/aeShellCommand/aeToolResult branches: the status line is
        temporary, EndStream erases it, and on aeSubSessionEnd PersistDoneStatus
        fixes a done line with the final counters (the main session from this
        scenario has no fixing — there the status is simply erased).
        ClearLine/DrawStatus (the private ClearLine is emulated with
        CR + ESC[K) run unconditionally — therefore the hidden output leaves no
        empty lines, and the visible one takes the place of the erased status. }
      P.Prefix := '';

      { s1: a step sub-session without --show-reasoning — the call and the result
        are hidden, the step text and the done line remain on the screen; the
        status counters (main/sub/total: 4.0k/1.0k → 1.4k/128k) are visible in
        the raw output, while only the final ones get into the log — from the
        done line. }
      P.BeginStream(FormatStepStatus('s1: hidden output', 1000, 128000,
        MAIN_CTX_TOOL));
      P.FeedContent('step one' + #10,
        FormatStepStatus('s1: hidden output', 1100, 128000, MAIN_CTX_TOOL));
      P.EndStream(FormatStepStatus('s1: hidden output', 1200, 128000,
        MAIN_CTX_TOOL));
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(False) then
        WriteLn('[read] hidden.md');
      P.DrawStatus(FormatStepStatus('s1: hidden output', 1300, 128000,
        MAIN_CTX_TOOL));
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(False) then
        WriteLn('hidden result');
      P.DrawStatus(FormatStepStatus('s1: hidden output', 1400, 128000,
        MAIN_CTX_TOOL));
      { aeSubSessionEnd: the temporary step line is replaced by the done line
        "s1". }
      P.PersistStatus(FormatStepStatus(StepShortName('s1: hidden output'), 1400,
        128000, MAIN_CTX_TOOL) + ' done');

      { s2: an analysis sub-session with --show-reasoning — the tool output is
        visible: the shell command line ("$ ...", the aeShellCommand branch) and
        the result are printed, each in place of the erased status. The analysis
        line has the same format as the step one: main (MAIN_CTX_ANALYSIS), the
        analysis sub-session, the common window and two percentages. }
      P.BeginStream(FormatAnalysisStatus(0, 128000, MAIN_CTX_ANALYSIS));
      P.FeedContent('analysis line' + #10,
        FormatAnalysisStatus(200, 128000, MAIN_CTX_ANALYSIS));
      P.EndStream(FormatAnalysisStatus(300, 128000, MAIN_CTX_ANALYSIS));
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(True) then
        WriteLn('$ echo shown');
      P.DrawStatus(FormatAnalysisStatus(400, 128000, MAIN_CTX_ANALYSIS));
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(True) then
      begin
        WriteLn('shown result');
        { Separator after the tool output. }
        P.RequestBlankLine;
      end;
      P.DrawStatus(FormatAnalysisStatus(500, 128000, MAIN_CTX_ANALYSIS));
      { aeSubSessionEnd of the analysis: the temporary status is replaced by the
        done line "analysis done" with the final counters (main/sub/total from
        MAIN_CTX_ANALYSIS and 500). }
      P.PersistStatus(FormatAnalysisStatus(500, 128000, MAIN_CTX_ANALYSIS) +
        ' done');

      { The main session without flags — the call and the result are hidden too
        (the gating is the same for all sessions); the status is
        erased instead of staying a line in the log: only sub-sessions fix a
        done line. }
      P.BeginStream('[main]');
      P.FeedContent('main line' + #10, '[main 1]');
      P.EndStream('[main 2]');
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(False) then
        WriteLn('[write] main.txt');
      P.DrawStatus('[main 3]');
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(False) then
        WriteLn('main result');
      P.DrawStatus('[main 4]');
      P.FreezeStatus('');

      { The main session with --show-reasoning — the output is visible, as in the
        analysis. }
      P.BeginStream('[main2]');
      P.FeedContent('main line two' + #10, '[main2 1]');
      P.EndStream('[main2 2]');
      P.PrepareStatic;
      Write(#13, #27, '[K');
      if ToolOutputVisible(True) then
        WriteLn('[write] main2.txt');
      P.DrawStatus('[main2 3]');
      P.PrepareStaticOverStatus;
      if ToolOutputVisible(True) then
      begin
        WriteLn('main2 result');
        { Separator after the tool output. }
        P.RequestBlankLine;
      end;
      P.DrawStatus('[main2 4]');
      P.FreezeStatus('');
    end
    else if Name = 'tool-blank' then
    begin
      { The empty line after the tool output: the result is separated
        from the next block of information. The scenario repeats the
        aeToolCall/aeToolResult/aeAssistant/aeSubSessionEnd branches:
        1) a tool result, then a static block (the model answer) — exactly one
           empty line between them (the answer suppresses its own empty line by
           BlankSeparated, a second one does not appear);
        2) two tool results in a row — also one empty line;
        3) a result, then the done line (PersistStatus) — an empty line before
           it too;
        4) hidden output (ToolOutputVisible = False) adds no empty lines: there
           is nothing to order the separator for.
        Regression: TStreamPrinter.RequestBlankLine/PrepareStatic/PersistStatus
        and the aeToolResult branch in TMirmidApp.OnAgentEvent. }
      P.Prefix := '';
      P.BeginStream('[st start]');
      P.FeedContent('answer zero' + #10, '[st 1]');
      P.EndStream('[st 2]');

      { aeToolCall + aeToolResult of the first tool (the output is visible). }
      P.PrepareStatic;
      Write(#13, #27, '[K');
      WriteLn('[read] a.txt');
      P.DrawStatus('[st 3]');
      P.PrepareStaticOverStatus;
      WriteLn('result a');
      P.RequestBlankLine;
      P.DrawStatus('[st 4]');

      { aeAssistant: PrepareStatic has already printed the separator, a second
        empty line is not needed (the BlankSeparated check). }
      P.PrepareStatic;
      if not P.BlankSeparated then
        WriteLn;
      WriteLn('answer one');

      { The second tool: there is no separator before the call line — nobody
        ordered it. }
      P.PrepareStatic;
      WriteLn('[read] b.txt');
      P.DrawStatus('[st 5]');
      P.PrepareStaticOverStatus;
      WriteLn('result b');
      P.RequestBlankLine;
      P.DrawStatus('[st 6]');

      { The third tool in a row: exactly one empty line between the results. }
      P.PrepareStatic;
      WriteLn('[read] c.txt');
      P.DrawStatus('[st 7]');
      P.PrepareStaticOverStatus;
      WriteLn('result c');
      P.RequestBlankLine;
      P.DrawStatus('[st 8]');

      { aeSubSessionEnd: the done line goes under the separator. }
      P.PersistStatus('[st 9 done]');

      { Hidden output: neither call/result lines nor empty lines. }
      P.PrepareStatic;
      Write(#13, #27, '[K');
      P.DrawStatus('[st 10]');
      P.PrepareStaticOverStatus;
      P.DrawStatus('[st 11]');
      P.PrepareStatic;
      Write(#13, #27, '[K');
      P.DrawStatus('[st 12]');
      P.FreezeStatus('');
    end
    else if Name = 'persist-status' then
    begin
      { The end of a turn: the final status line stays on the screen.
        The scenario repeats the TMirmidApp.KeepContextStatus branch in streaming
        mode: after EndStream (it erased the temporary status) the printer fixes
        the line with the final counters (PersistStatus), and the next output —
        the REPL prompt after PrepareStatic — goes from a clean line under it.
        Two turns in a row: each has exactly one status line in the log, and it
        stands under the answer, not instead of it. Regression:
        TStreamPrinter.PersistStatus. }
      P.Prefix := '||';
      P.BeginStream('[turn 1 start]');
      P.FeedContent('answer one' + #10, '[turn 1 1.0k]');
      { The unfinished last line: it becomes a complete line in EndStream, the
        status under it is temporary. }
      P.FeedContent('answer tail', '[turn 1 2.0k]');
      P.EndStream('[turn 1 3.0k]');
      { KeepContextStatus (stream): fix the final line in the log. }
      P.PersistStatus('[turn 1 final 2.1k/128k]');
      { Repl: the prompt under the fixed line. }
      P.PrepareStatic;
      Write('|> ');
      WriteLn;

      P.BeginStream('[turn 2 start]');
      P.FeedContent('answer two' + #10, '[turn 2 1.0k]');
      P.EndStream('[turn 2 2.0k]');
      P.PersistStatus('[turn 2 final 2.2k/128k]');
      P.PrepareStatic;
    end
    else if Name = 'long-status' then
    begin
      { A status wider than the terminal (PrintStatus): it is cut to the content
        width minus one column, so it takes exactly one terminal line, and the
        next redraw (ClearLine + PrintStatus) replaces the whole line instead of
        clearing only the last of its wrapped lines — the tail of the old status
        does not stay in the scrollback. The scenario repeats the
        aeStepStart/aeToolCall/aeAssistant/aeSubSessionEnd branches of a step
        sub-session: the long step task ends with "TailMarker", which must never
        reach the screen, and the status is drawn with grown counters after every
        static block. The step text and the static lines must not glue to the
        remains of the status, and the fixed done line (PersistStatus) is cut the
        same way. Regression: TStreamPrinter.PrintStatus/ContentWidth and
        TruncateVisible. }
      P.Prefix := '';
      S1 := FormatStepStatus('s1: ' + StringOfChar('x', 60) + 'TailMarker',
        1000, 128000, MAIN_CTX_STEP);
      S2 := FormatStepStatus('s1: ' + StringOfChar('x', 60) + 'TailMarker',
        1100, 128000, MAIN_CTX_STEP);
      S3 := FormatStepStatus('s1: ' + StringOfChar('x', 60) + 'TailMarker',
        1200, 128000, MAIN_CTX_STEP);
      { aeStepStart: the drawn status and the step text under it. }
      P.BeginStream(S1);
      P.FeedContent('step line one' + #10, S1);
      P.FeedContent('step line two' + #10, S2);
      { aeToolCall: the drawn status is erased, the call line takes its place,
        and the status is drawn again with grown counters. }
      P.PrepareStatic;
      WriteLn('[read] notes.md');
      P.DrawStatus(S2);
      { A redraw without any text (DrawStatus after the result): the whole
        status line is replaced, the old counters do not stay above it. }
      P.DrawStatus(S3);
      { aeAssistant: the answer line takes the place of the erased status. }
      P.PrepareStatic;
      WriteLn('answer one');
      P.DrawStatus(S3);
      { aeSubSessionEnd: the temporary status is erased, and the done line with
        the final counters is fixed in its place. }
      P.EndStream(S3);
      P.PersistStatus(FormatStepStatus('s1: ' + StringOfChar('x', 60) +
        'TailMarker', 1300, 128000, MAIN_CTX_STEP) + ' done');
      P.PrepareStatic;
      WriteLn('after long status');
    end
    else
      Halt(2);
    P.EndStream('[st]');
  finally
    P.Free;
  end;
end;

begin
  if ParamCount < 1 then
    Halt(2);
  RunScenario(ParamStr(1));
end.
