program mirmid;
{ mirmid — an AI-agent harness written in Free Pascal / Lazarus.
  Entry point: all the logic lives in the units of the src/ directory. }

{$mode objfpc}{$H+}

uses
  SysUtils, mirmid.util, mirmid.cli;

begin
  DefaultSystemCodePage := CP_UTF8;
  { Enable ANSI escape sequence handling in the Windows console before the
    first output: if the console does not support them, colours and redraw
    are disabled. }
  InitConsoleAnsi;
  ExitCode := mirmid.cli.Main;
end.
