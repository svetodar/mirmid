unit mirmid.util;
{ Application helpers: paths, files, process launch, time. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

{ Temporary files directory (with a trailing slash). }
function TempDir: string;
{ Home directory (with a trailing slash). }
function HomeDir: string;
{ Expands "~" and makes the path absolute relative to Base. }
function ExpPath(const Path, Base: string): string;
{ Directory where the executable lives (with a trailing slash). }
function AppDir: string;

{ --- Numbers --- }
{ Format settings with a decimal point (independent of the system locale). }
function DotFormatSettings: TFormatSettings;
{ Parses a number with a decimal point: "0.7" and "0,7" both give 0.7 in any
  locale. An empty string or garbage - Def. }
function DotToFloat(const S: string; Def: Double): Double;
{ Formats a number with a decimal point ("0.7") in any locale. }
function FloatToDotStr(const Value: Double): string;

{ Project configuration and sessions directory: <WorkDir>/.mirmid (no trailing slash). }
function MirmidDir(const WorkDir: string): string;
{ True if Path points to <WorkDir>/.mirmid or inside it. }
function IsMirmidPath(const WorkDir, Path: string): Boolean;

{ Byte-wise reading/writing of UTF-8 text files. }
function ReadTextFile(const Path: string; out Text: string; out Err: string): Boolean;
function WriteTextFile(const Path, Text: string; out Err: string): Boolean;
{ Appends Text to the end of the file (creates the directory and the file when missing). }
function AppendTextFile(const Path, Text: string; out Err: string): Boolean;
{ Creates the parent directories of a file. True if the directory exists. }
function EnsureParentDir(const Path: string): Boolean;

{ Lists files and subdirectories. Directories are marked with a trailing "/".
  With Recursive=True subdirectories are walked. The list is sorted. }
function ListDir(const Dir: string; Recursive: Boolean;
  out Lines: TStringList; out Err: string): Boolean;

{ Runs a shell command in WorkDir: /bin/bash -lc on Unix,
  %COMSPEC% /c on Windows. The result is returned in Output (stdout+stderr).
  Returns True if the process finished by itself (even with a non-zero code).
  False on a launch error or a timeout.
  MaxOutput > 0 - limit of the accumulated output in bytes (0 - no limit);
  truncation happens at a UTF-8 character boundary (TruncateUTF8) after the
  process has finished and does not change Result/ExitCode;
  TotalBytes - how many bytes were actually read from the process. }
function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string): Boolean; overload;
function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string;
  MaxOutput: Integer; out TotalBytes: Int64): Boolean; overload;

{ Fills a list with the environment variables of the current process ("KEY=VALUE" lines). }
procedure EnvironmentToList(L: TStrings);

{ Monotonic milliseconds (for timeouts). }
function TicksMs: QWord;
{ --- Environment (for the system prompt) --- }
{ OS name: Windows - via GetVersionEx and the build number from the registry
  (22000+ - Windows 11); Unix - PRETTY_NAME from /etc/os-release. }
function OsName: string;
{ CPU architecture (x86_64, arm64, x86, ...). }
function OsArch: string;
{ Current date and time in a locale-independent format yyyy-mm-dd hh:nn:ss. }
function NowStamp: string;
{ Environment summary line for the system prompt: OS, date, time. }
function EnvironmentInfo: string;
{ Contents of AGENTS.md from the working directory (empty string if there is no file). }
function ReadAgentsMd(const WorkDir: string): string;
{ --- GUI (coordinates) --- }
{ Marks the process as DPI-aware (Windows): without it the system returns
  coordinates and sizes virtualised (scaled). A no-op on Unix (there is no DPI
  virtualisation there). The call is idempotent. }
procedure EnsureDpiAware;

{ --- Screen and ANSI colors --- }
{ Brightness of terminal colors (0..1): the Windows console palette is brighter
  than the palette of Unix terminals, so colors are dimmed on Windows; on Linux -
  full brightness. }
const
  {$IFDEF WINDOWS}
  COLOR_BRIGHTNESS = 0.6;
  {$ELSE}
  COLOR_BRIGHTNESS = 1.0;
  {$ENDIF}
{ True if the file descriptor is attached to a terminal. }
function IsTerminal(FD: Integer): Boolean;
{ True if ANSI sequences may be interleaved into stream FD: the descriptor is
  attached to a terminal and the terminal handles them. On Windows the
  ENABLE_VIRTUAL_TERMINAL_PROCESSING mode is enabled on the first call (in
  conhost it may be off, and then ESC codes are printed as plain text); if
  enabling fails - False. For descriptors outside 0..2 - False. }
function AnsiEnabled(FD: Integer = 1): Boolean;
{ Explicit initialisation of ANSI output (without it the enabling will happen
  lazily on the first AnsiEnabled/Colored call). True - ANSI codes are allowed. }
function InitConsoleAnsi: Boolean;
{ True if colors are allowed (NO_COLOR is not set) and ANSI may be written to the stream. }
function ColorsEnabled(FD: Integer): Boolean;
{ Wraps Text into the ANSI color sequence Color with a reset.
  Outside a terminal (or with an empty Color) returns Text without codes. }
function Colored(const Color, Text: string; FD: Integer = 1): string;
{ SGR code with dimmed brightness: the color parts (30..37, 90..97, 38;5;N,
  38;2;R;G;B and the background 48;...) are recalculated into a 24-bit color by
  multiplying the components by Brightness; other attributes (bold, italic,
  underline, reset) are kept. With Brightness >= 1 the code is returned unchanged. }
function DimSGR(const SGR: string; Brightness: Double = COLOR_BRIGHTNESS): string;

{ Terminal width in columns for FD (ioctl TIOCGWINSZ; fallback - the COLUMNS
  environment variable, then 80). }
function TermWidth(FD: Integer = 1): Integer;
{ Visible length of a string in columns: without ANSI sequences. Wide characters
  (CJK, emoji, fullwidth forms) count as 2 columns, zero-width ones (joiners,
  variation selectors, diacritics) - as 0. }
function VisibleLen(const S: string): Integer;
{ Truncates S to MaxCols visible columns (as VisibleLen counts them) without
  breaking a UTF-8 character or leaving a dangling ANSI sequence: an SGR
  sequence that precedes the cut is kept and the result is closed with a reset
  when S carried one. MaxCols <= 0 - S is returned as is. }
function TruncateVisible(const S: string; MaxCols: Integer): string;

{ --- UTF-8 --- }
{ Truncates S to MaxBytes bytes without breaking a multi-byte UTF-8 character:
  returns the longest prefix of whole characters not longer than MaxBytes.
  Without this guard Copy(S, 1, N) may cut a character and produce an invalid
  UTF-8 string (HTTP 400 when sending to the API). }
function TruncateUTF8(const S: string; MaxBytes: Integer): string;
{ True if S is a valid UTF-8 string (no broken bytes). }
function IsValidUTF8(const S: string): Boolean;
{ Replaces invalid UTF-8 sequences with U+FFFD so that the string is
  suitable for JSON/HTTP. }
function SanitizeUTF8(const S: string): string;

{ --- Shortening multi-line text --- }
{ Indent of the "..." marker from the start of the line (in spaces): the marker
  separates the parts of tool output and must not look like its first line
  - with indent 8 the ellipsis is printed from position 9. }
const
  SHORTEN_ELLIPSIS_INDENT = 8;
{ Shortens S to MaxLines lines by cutting the middle: the first
  (MaxLines - 1) div 2 lines stay, then the "..." marker (indented by
  SHORTEN_ELLIPSIS_INDENT) and the tail lines below (with an even limit the
  bottom keeps one line more). For MaxLines = 9 that is 4 + "..." + 4.
  MaxLines = 1 - only "..."; MaxLines = 2 - "..." + the last line.
  MaxLines <= 0 (0 and negative mean "no limit") - S is returned as is;
  S shorter than the limit - also as is. Line breaks are preserved
  (CRLF/LF of the source text), no trailing break is added. }
function ShortenLinesMiddle(const S: string; MaxLines: Integer): string;
{ Removes blank lines at the start and at the end of the text (tool
  output must start and end with content before the line limit is applied,
  otherwise the limit is spent on blank lines and extra blank lines remain on
  the screen). A line of only spaces/tabs counts as blank; inner blank lines
  are kept. The line break style of the source text (CRLF/LF) is preserved, no
  trailing break is added: text of blank lines only gives an empty string
  (nothing to print). }
function TrimBlankLines(const S: string): string;

{ --- Wrapping long lines --- }
{ Visible width measuring function (for example VisibleLen for plain text or
  VisibleLen(RenderMarkdown(...)) for marked-up text). }
type
  TTextMeasure = function(const S: string): Integer of object;
{ Whether a break before a space is allowed (Prefix - the text before the
    space). nil - any space is allowed. }
  TBreakAllowed = function(const Prefix: string): Boolean of object;

{ Wraps line S by words so that every fragment is narrower than Width columns
  according to Measure. The break is made at a space and the space itself is
  dropped; punctuation stays with the previous word. A word longer than the
  line is broken forcibly. Leading spaces of the line (the indent) are kept in
  the first fragment. BreakAllowed (optional) filters out breaks inside markup
  (for example inside **bold**). Returns the list of fragments
  (at least one). }
function WrapText(const S: string; Width: Integer; Measure: TTextMeasure;
  BreakAllowed: TBreakAllowed = nil): TStringList;

{ --- Diff --- }
{ Generates a unified diff between two line lists.
  OldLines - the original lines, NewLines - the new lines.
  OldName/NewName - names for the header (for example "a/file" and "b/file").
  OldStartLine - 1-based number of the first line of OldLines in the file
    (1 by default).
  Context - number of context lines around the changes (3 by default).
  Returns a string with the unified diff; an empty string if the lists match. }
function MakeUnifiedDiff(const OldLines, NewLines: TStringList;
  const OldName, NewName: string; OldStartLine: Integer = 1;
  Context: Integer = 3): string;

implementation

uses
  Process, DateUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  {$IFDEF UNIX}, baseunix{$ENDIF};

{$IFDEF WINDOWS}
var
  UGuiDpiAware: Boolean = False;

type
  TUtilSetProcessDPIAware = function: BOOL; stdcall;
{$ENDIF}

procedure EnsureDpiAware;
{$IFDEF WINDOWS}
var
  H: HMODULE;
  F: TUtilSetProcessDPIAware;
begin
  if UGuiDpiAware then
    Exit;
  UGuiDpiAware := True;
  H := GetModuleHandle('user32.dll');
  if H = 0 then
    Exit;
  Pointer(F) := GetProcAddress(H, 'SetProcessDPIAware');
  if Assigned(F) then
    try
      F();
    except
      { no such function or the call is forbidden - work as is }
    end;
end;
{$ELSE}
begin
  { On Unix there is no DPI virtualisation - nothing to do. }
end;
{$ENDIF}

function TempDir: string;
begin
  { GetTempDir honours TMPDIR/TEMP/TMP and returns a path with a trailing slash. }
  Result := GetTempDir;
end;

function HomeDir: string;
begin
  Result := GetUserDir;
end;

function AppDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0)));
end;

{ --- Numbers --- }

function DotFormatSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function DotToFloat(const S: string; Def: Double): Double;
var
  T: string;
begin
  T := Trim(S);
  if T = '' then
    Exit(Def);
  { Accept a comma too: the config may have been saved in a comma locale. }
  T := StringReplace(T, ',', '.', [rfReplaceAll]);
  Result := StrToFloatDef(T, Def, DotFormatSettings);
end;

function FloatToDotStr(const Value: Double): string;
begin
  Result := FloatToStr(Value, DotFormatSettings);
end;

function MirmidDir(const WorkDir: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(ExpPath('.mirmid', WorkDir));
end;

function IsMirmidPath(const WorkDir, Path: string): Boolean;
var
  Base, Sub, P: string;
begin
  if Path = '' then
    Exit(False);
  Base := ExpPath(WorkDir, GetCurrentDir);
  if Base = '' then
    Base := GetCurrentDir;
  Base := IncludeTrailingPathDelimiter(Base);
  Sub := MirmidDir(Base);
  P := ExpPath(Path, Base);
  if P = '' then
    Exit(False);
  {$IFDEF WINDOWS}
  Result := SameText(P, Sub) or SameText(Copy(P, 1, Length(Sub) + 1), Sub + PathDelim);
  {$ELSE}
  Result := (P = Sub) or (Copy(P, 1, Length(Sub) + 1) = Sub + PathDelim);
  {$ENDIF}
end;

{ True if the path is absolute on the current platform. }
function PathIsAbsolute(const P: string): Boolean;
begin
  Result := False;
  if P = '' then
    Exit;
  {$IFDEF WINDOWS}
  if (Length(P) >= 2) and (P[2] = ':') then
    Exit(True);
  {$ENDIF}
  Result := (P[1] = PathDelim) or (P[1] = '/') or (P[1] = '\');
end;

function ExpPath(const Path, Base: string): string;
var
  P: string;
begin
  P := Trim(Path);
  if P = '' then
    Exit('');
  if (P = '~') or ((Length(P) >= 2) and (P[1] = '~') and (P[2] in ['/', '\'])) then
    P := HomeDir + Copy(P, 3, MaxInt);
  if not PathIsAbsolute(P) then
    P := IncludeTrailingPathDelimiter(Base) + P;
  Result := ExpandFileName(P);
end;

{ Collects the environment of the current process into a "KEY=VALUE" list. }
procedure EnvironmentToList(L: TStrings);
{$IFDEF WINDOWS}
var
  P, Q: PWideChar;
  S: WideString;
begin
  { Take the Unicode version: DefaultSystemCodePage = UTF-8, so the environment
    strings must be UTF-8 (not ANSI/OEM encoded). }
  P := GetEnvironmentStringsW;
  if P = nil then
    Exit;
  try
    Q := P;
    while Q^ <> #0 do
    begin
      S := Q;
      L.Add(UTF8Encode(S));
      Inc(Q, Length(S) + 1);
    end;
  finally
    FreeEnvironmentStringsW(P);
  end;
end;
{$ELSE}
var
  P: PPChar;
begin
  P := envp;
  while (P <> nil) and (P^ <> nil) do
  begin
    L.Add(StrPas(P^));
    Inc(P);
  end;
end;
{$ENDIF}

function ReadTextFile(const Path: string; out Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  B: RawByteString;
begin
  Text := '';
  Err := '';
  Result := False;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(B, F.Size);
      if F.Size > 0 then
        F.ReadBuffer(B[1], F.Size);
      Text := B;
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      Err := Format('%s: %s', [Path, E.Message]);
  end;
end;

function WriteTextFile(const Path, Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  B: RawByteString;
begin
  Err := '';
  Result := False;
  if not EnsureParentDir(Path) then
  begin
    Err := 'cannot create directory for ' + Path;
    Exit;
  end;
  B := Text;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Length(B) > 0 then
        F.WriteBuffer(B[1], Length(B));
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      Err := Format('%s: %s', [Path, E.Message]);
  end;
end;

function AppendTextFile(const Path, Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  B: RawByteString;
begin
  Err := '';
  Result := False;
  B := Text;
  if Length(B) = 0 then
    Exit(True);
  if not EnsureParentDir(Path) then
  begin
    Err := 'cannot create directory for ' + Path;
    Exit;
  end;
  try
    { fmOpenWrite does not create the file - create it explicitly when missing. }
    if FileExists(Path) then
      F := TFileStream.Create(Path, fmOpenWrite)
    else
      F := TFileStream.Create(Path, fmCreate);
    try
      F.Seek(0, soEnd);
      F.WriteBuffer(B[1], Length(B));
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      Err := Format('%s: %s', [Path, E.Message]);
  end;
end;

function EnsureParentDir(const Path: string): Boolean;
var
  D: string;
begin
  D := ExtractFileDir(Path);
  if (D = '') or DirectoryExists(D) then
    Exit(True);
  Result := ForceDirectories(D);
end;

procedure ListDirRec(const Dir: string; Recursive: Boolean; Lines: TStringList);
var
  SR: TSearchRec;
  Full, Name: string;
begin
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      Name := SR.Name;
      if (Name = '.') or (Name = '..') then
        Continue;
      Full := IncludeTrailingPathDelimiter(Dir) + Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        Lines.Add(Full + PathDelim);
        if Recursive then
          ListDirRec(Full, True, Lines);
      end
      else
        Lines.Add(Full);
    until SysUtils.FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function ListDir(const Dir: string; Recursive: Boolean;
  out Lines: TStringList; out Err: string): Boolean;
begin
  Err := '';
  Lines := TStringList.Create;
  Lines.Sorted := True;
  Lines.Duplicates := dupIgnore;
  if not DirectoryExists(Dir) then
  begin
    Err := 'directory not found: ' + Dir;
    Exit(False);
  end;
  try
    ListDirRec(Dir, Recursive, Lines);
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

{$IFDEF UNIX}
type
  { Detaches the child process from the controlling terminal: OnForkEvent is
    called in the child after fork and before exec. Without it interactive
    commands (sudo, ssh, editors) open /dev/tty, print the prompt straight
    into the terminal and block on reading - the shell tool hangs
    until the timeout (and with a zero timeout - forever). }
  TDetachFromTerminal = class
    procedure OnFork(Sender: TObject);
  end;

procedure TDetachFromTerminal.OnFork(Sender: TObject);
begin
  { New session: the controlling terminal is not inherited. }
  FpSetsid;
end;
{$ENDIF}

function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string): Boolean; overload;
var
  TotalBytes: Int64;
begin
  Result := RunProcess(Cmd, WorkDir, TimeoutSec, Output, ExitCode, Err, 0, TotalBytes);
end;

function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string;
  MaxOutput: Integer; out TotalBytes: Int64): Boolean; overload;
var
  P: TProcess;
  {$IFDEF UNIX}
  Detach: TDetachFromTerminal;
  {$ENDIF}
  Buf: array[0..8191] of Byte;
  N: LongInt;
  Chunk: RawByteString;
  Deadline: QWord;
  TimedOut: Boolean;

  procedure Drain;
  var
    Room, Keep: LongInt;
  begin
    while P.Output.NumBytesAvailable > 0 do
    begin
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N <= 0 then
        Break;
      Inc(TotalBytes, N);
      { Accumulation limit: extra bytes are still drained from the pipe
        (otherwise the process blocks on a full pipe) but not appended to
        Output. Keep a reserve of 3 bytes (the maximum length of a UTF-8
        character minus one) so that the final TruncateUTF8 call can step
        back from the boundary to the leading byte of the last character. }
      if MaxOutput > 0 then
      begin
        Room := MaxOutput + 3 - Length(Output);
        if Room <= 0 then
          Continue;
        if N > Room then
          Keep := Room
        else
          Keep := N;
      end
      else
        Keep := N;
      SetLength(Chunk, Keep);
      Move(Buf[0], Chunk[1], Keep);
      Output := Output + Chunk;
    end;
  end;

begin
  Output := '';
  Err := '';
  ExitCode := -1;
  TotalBytes := 0;
  TimedOut := False;
  Result := False;
  P := TProcess.Create(nil);
  {$IFDEF UNIX}
  Detach := TDetachFromTerminal.Create;
  {$ENDIF}
  try
    {$IFDEF WINDOWS}
    P.Executable := SysUtils.GetEnvironmentVariable('COMSPEC');
    if P.Executable = '' then
      P.Executable := 'cmd.exe';
    P.Parameters.Add('/c');
    P.Parameters.Add(Cmd);
    {$ELSE}
    P.Executable := '/bin/bash';
    P.Parameters.Add('-lc');
    P.Parameters.Add(Cmd);
    {$ENDIF}
    if WorkDir <> '' then
      P.CurrentDirectory := WorkDir;
    P.Options := [poUsePipes, poStderrToOutPut];
    {$IFDEF UNIX}
    P.OnForkEvent := @Detach.OnFork;
    {$ENDIF}
    try
      P.Execute;
    except
      on E: Exception do
      begin
        Err := 'cannot start process: ' + E.Message;
        Exit;
      end;
    end;
    { Close our half of the stdin pipe: commands reading stdin get EOF
      instead of waiting for input until the timeout. }
    P.CloseInput;
    Deadline := TicksMs + QWord(TimeoutSec) * 1000;
    while True do
    begin
      Drain;
      if not P.Running then
        Break;
      if (TimeoutSec > 0) and (TicksMs >= Deadline) then
      begin
        TimedOut := True;
        P.Terminate(1);
        Break;
      end;
      Sleep(15);
    end;
    Drain;
    { Truncate the collected output at a UTF-8 character boundary - only now,
      when the process has already finished (or was stopped by the timeout):
      a byte-wise Copy could cut a multi-byte character. Neither the Result
      flag nor the ExitCode is changed by the truncation. }
    if MaxOutput > 0 then
      Output := TruncateUTF8(Output, MaxOutput);
    if TimedOut then
    begin
      Err := Format('command timed out (%d s)', [TimeoutSec]);
      Output := Output + sLineBreak + '[mirmid] ' + Err;
      Exit;
    end;
    ExitCode := P.ExitStatus;
    Result := True;
  finally
    {$IFDEF UNIX}
    Detach.Free;
    {$ENDIF}
    P.Free;
  end;
end;

function TicksMs: QWord;
begin
  Result := GetTickCount64;
end;
{ --- Environment (for the system prompt) --- }

{$IFDEF WINDOWS}
{ Windows build number from the registry (0 if unavailable). }
function WindowsBuildNumber: Integer;
var
  K: HKEY;
  T: DWORD;
  N: DWORD;
  Buf: array[0..63] of AnsiChar;
begin
  Result := 0;
  if RegOpenKeyEx(HKEY_LOCAL_MACHINE,
      'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 0, KEY_READ, K)
      <> ERROR_SUCCESS then
    Exit;
  try
    N := SizeOf(Buf);
    if RegQueryValueEx(K, 'CurrentBuildNumber', nil, @T,
          PByte(@Buf), @N) = ERROR_SUCCESS then
      Result := StrToIntDef(Trim(AnsiString(PAnsiChar(@Buf))), 0);
  finally
    RegCloseKey(K);
  end;
end;
{$ENDIF}

function OsName: string;
{$IFDEF WINDOWS}
var
  B: Integer;
begin
  { GetVersionEx is unreliable on modern Windows (it returns 6.0 for
     8/10/11), so rely on the build number from the registry. }
  B := WindowsBuildNumber;
  if B >= 22000 then
    Result := 'Windows 11'
  else if B >= 10240 then
    Result := 'Windows 10'
  else if B >= 9200 then
    Result := 'Windows 8.1'
  else if B >= 7600 then
    Result := 'Windows 8'
  else if B > 0 then
    Result := 'Windows 7'
  else
    Result := 'Windows';
end;
{$ELSE}
var
  T, Line, Val: string;
  Err: string;
  L: TStringList;
begin
  Result := 'Linux';
  if not ReadTextFile('/etc/os-release', T, Err) then
    Exit;
  L := TStringList.Create;
  try
    L.Text := T;
    for Line in L do
      if Copy(Line, 1, 12) = 'PRETTY_NAME=' then
      begin
        Val := Copy(Line, 13, MaxInt);
        if (Length(Val) >= 2) and (Val[1] in ['"', '''']) and
           (Val[Length(Val)] = Val[1]) then
          Val := Copy(Val, 2, Length(Val) - 2);
        Val := Trim(Val);
        if Val <> '' then
          Result := Val;
        Break;
      end;
  finally
    L.Free;
  end;
end;
{$ENDIF}

function OsArch: string;
{$IFDEF WINDOWS}
const
  { Architecture values missing in the Windows unit of this FPC build. }
  PROC_ARCH_AMD64 = 9;
  PROC_ARCH_IA64  = 6;
  PROC_ARCH_ARM64 = 14;
var
  SI: SYSTEM_INFO;
begin
  GetNativeSystemInfo(@SI);
  case SI.wProcessorArchitecture of
    PROC_ARCH_AMD64:               Result := 'x86_64';
    PROC_ARCH_ARM64:               Result := 'arm64';
    PROC_ARCH_IA64:                Result := 'ia64';
    PROCESSOR_ARCHITECTURE_INTEL:  Result := 'x86';
  else
    Result := 'unknown';
  end;
end;
{$ELSE}
var
  U: utsname;
begin
  if fpuname(U) = 0 then
    Result := StrPas(U.machine)
  else
    Result := 'unknown';
end;
{$ENDIF}

function NowStamp: string;
var
  D: TDateTime;
  { Two digits with a leading zero: FPC pads Format output with a space. }
  function Pad2(V: Integer): string;
  begin
    if V < 10 then
      Result := '0' + IntToStr(V)
    else
      Result := IntToStr(V);
  end;
begin
  D := Now;
  { Manual formatting: FormatDateTime depends on locale separators. }
  Result := IntToStr(YearOf(D)) + '-' + Pad2(MonthOf(D)) + '-' + Pad2(DayOf(D)) +
            ' ' + Pad2(HourOf(D)) + ':' + Pad2(MinuteOf(D)) + ':' + Pad2(SecondOf(D));
end;

function EnvironmentInfo: string;
begin
  Result := 'Environment: OS ' + OsName + ' (' + OsArch + '); ' +
            'date ' + Copy(NowStamp, 1, 10) + '; ' +
            'time ' + Copy(NowStamp, 12, 8);
end;
function ReadAgentsMd(const WorkDir: string): string;
var
  Path, Text, Err: string;
begin
  Result := '';
  if WorkDir = '' then
    Exit;
  Path := ExpPath('AGENTS.md', WorkDir);
  if ReadTextFile(Path, Text, Err) then
    Result := Trim(Text);
end;

{ --------------------------------------------------------------- colors }
var
  FColorsAllowed: Boolean;
  FAnsiChecked: Boolean;
  { By descriptor index (0..2): whether ANSI sequences may be written. }
  FAnsiOK: array[0..2] of Boolean;

{ RGB of the basic 16-color palette (xterm). }
const
  BASIC_RGB: array[0..15, 0..2] of Byte = (
    (0, 0, 0),       (195, 5, 5),   (5, 195, 5),   (195, 195, 5),
    (5, 5, 195),     (195, 5, 195), (5, 195, 195), (195, 195, 195),
    (75, 75, 75),    (255, 5, 5),   (5, 255, 5),   (255, 255, 5),
    (5, 5, 255),     (255, 5, 255), (5, 255, 255), (255, 255, 255));

{ Component steps in the 6x6x6 cube (indices 16..231). }
  CUBE_STEP: array[0..5] of Byte = (0, 95, 135, 175, 215, 255);

{ RGB components of a 256-color palette entry by index N (0..255):
   0..15 - the basic palette, 16..231 - the 6x6x6 cube, 232..255 - the gray gradient. }
function PaletteRGB(N: Integer; out R, G, B: Byte): Boolean;
begin
  if (N < 0) or (N > 255) then
    Exit(False);
  if N <= 15 then
  begin
    R := BASIC_RGB[N, 0];
    G := BASIC_RGB[N, 1];
    B := BASIC_RGB[N, 2];
  end
  else if N <= 231 then
  begin
    N := N - 16;
    R := CUBE_STEP[N div 36];
    G := CUBE_STEP[(N div 6) mod 6];
    B := CUBE_STEP[N mod 6];
  end
  else
  begin
    R := Byte(8 + 10 * (N - 232));
    G := R;
    B := R;
  end;
  Result := True;
end;

{ Index of the basic 16-color palette by an SGR foreground code
  (30..37 - dark, 90..97 - bright); -1 if the code is not a basic color. }
function BasicColorIndex(const P: string): Integer;
begin
  Result := -1;
  if Length(P) <> 2 then
    Exit;
  if (P[1] = '3') and (P[2] >= '0') and (P[2] <= '7') then
    Result := Ord(P[2]) - Ord('0')
  else if (P[1] = '9') and (P[2] >= '0') and (P[2] <= '7') then
    Result := 8 + Ord(P[2]) - Ord('0');
end;

function DimSGR(const SGR: string; Brightness: Double = COLOR_BRIGHTNESS): string;
var
  Parts: TStringList;
  I: Integer;
  R, G, B: Byte;
  N, Idx: Integer;
  P: string;

  { Color component multiplied by Brightness (0..255). }
  function Scale(C: Byte): Byte;
  var
    V: LongInt;
  begin
    V := Round(C * Brightness);
    if V < 0 then
      V := 0
    else if V > 255 then
      V := 255;
    Result := Byte(V);
  end;

  { 24-bit SGR code with dimmed components. }
  function ScaledColor(const Prefix: string; R, G, B: Byte): string;
  begin
    Result := Prefix + ';2;' + IntToStr(Scale(R)) + ';' +
              IntToStr(Scale(G)) + ';' + IntToStr(Scale(B));
  end;

begin
  if (Brightness >= 1.0) or (SGR = '') then
    Exit(SGR);
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := SGR;
    I := 0;
    while I < Parts.Count do
    begin
      P := Parts[I];
      Idx := BasicColorIndex(P);
      if Idx >= 0 then
      begin
        P := ScaledColor('38', BASIC_RGB[Idx, 0], BASIC_RGB[Idx, 1],
                         BASIC_RGB[Idx, 2]);
        Inc(I);
      end
      else if (P = '38') or (P = '48') then
      begin
        if (I + 2 < Parts.Count) and (Parts[I + 1] = '5') then
        begin
          N := StrToIntDef(Parts[I + 2], -1);
          if PaletteRGB(N, R, G, B) then
          begin
            P := ScaledColor(P, R, G, B);
            Inc(I, 3);
          end
          else
            Inc(I);
        end
        else if (I + 4 < Parts.Count) and (Parts[I + 1] = '2') then
        begin
          R := StrToIntDef(Parts[I + 2], 0);
          G := StrToIntDef(Parts[I + 3], 0);
          B := StrToIntDef(Parts[I + 4], 0);
          P := ScaledColor(P, R, G, B);
          Inc(I, 5);
        end
        else
          { Unrecognised 38/48 - pass it through as is. }
          Inc(I);
      end
      else
        Inc(I);
      if Result <> '' then
        Result := Result + ';';
      Result := Result + P;
    end;
  finally
    Parts.Free;
  end;
end;
{$IFDEF WINDOWS}
{ Standard stream handle: 0 - input, 2 - errors, otherwise output. }
function StdHandleFor(FD: Integer): THandle;
begin
  case FD of
    0: Result := GetStdHandle(STD_INPUT_HANDLE);
    2: Result := GetStdHandle(STD_ERROR_HANDLE);
  else
    Result := GetStdHandle(STD_OUTPUT_HANDLE);
  end;
end;

function IsTerminal(FD: Integer): Boolean;
var
  H: THandle;
  Mode: DWORD;
begin
  H := StdHandleFor(FD);
  Result := (H <> 0) and (H <> INVALID_HANDLE_VALUE) and (GetConsoleMode(H, Mode) <> False);
end;

{ True if the console will handle ESC sequences in this stream. If
  ENABLE_VIRTUAL_TERMINAL_PROCESSING is not set, enable it ourselves - otherwise
  ANSI codes are printed as plain text (the buffer shows a raw escape sequence).
  False - the stream is not a console (file, pipe) or enabling the mode failed. }
function ConsoleAnsiSupported(FD: Integer): Boolean;
var
  H: THandle;
  Mode: DWORD;
begin
  Result := False;
  H := StdHandleFor(FD);
  if (H = 0) or (H = INVALID_HANDLE_VALUE) then
    Exit;
  if GetConsoleMode(H, Mode) = False then
    Exit;
  if (Mode and ENABLE_VIRTUAL_TERMINAL_PROCESSING) <> 0 then
    Exit(True);
  Result := SetConsoleMode(H, Mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING) <> False;
end;
{$ELSE}
function isatty(fd: Integer): Integer; cdecl; external 'c';

function IsTerminal(FD: Integer): Boolean;
begin
  Result := (isatty(FD) <> 0);
end;

{ On Unix the VT mode need not be enabled - the terminal always parses ANSI. }
function ConsoleAnsiSupported(FD: Integer): Boolean;
begin
  Result := IsTerminal(FD);
end;
{$ENDIF}

function AnsiEnabled(FD: Integer = 1): Boolean;
var
  I: Integer;
begin
  if (FD < 0) or (FD > 2) then
    Exit(False);
  if not FAnsiChecked then
  begin
    { Lazy initialisation: the console mode is checked/enabled once. }
    FAnsiOK[0] := IsTerminal(0);
    for I := 1 to 2 do
      FAnsiOK[I] := ConsoleAnsiSupported(I);
    FAnsiChecked := True;
  end;
  Result := FAnsiOK[FD];
end;

function InitConsoleAnsi: Boolean;
begin
  Result := AnsiEnabled(1);
end;

function ColorsEnabled(FD: Integer): Boolean;
begin
  Result := FColorsAllowed and AnsiEnabled(FD);
end;

function Colored(const Color, Text: string; FD: Integer = 1): string;
begin
  if (Color = '') or not ColorsEnabled(FD) then
    Exit(Text);
  { The color is dimmed by the platform brightness (COLOR_BRIGHTNESS). }
  Result := #27 + '[' + DimSGR(Color) + 'm' + Text + #27 + '[0m';
end;

{$IFDEF WINDOWS}
{ Console window width (GetConsoleScreenBufferInfo); fallback - COLUMNS, then 80. }
function TermWidth(FD: Integer = 1): Integer;
var
  H: THandle;
  Info: TConsoleScreenBufferInfo;
  S: string;
begin
  case FD of
    0: H := GetStdHandle(STD_INPUT_HANDLE);
    2: H := GetStdHandle(STD_ERROR_HANDLE);
  else
    H := GetStdHandle(STD_OUTPUT_HANDLE);
  end;
  if (H <> 0) and (H <> INVALID_HANDLE_VALUE) and
     (GetConsoleScreenBufferInfo(H, Info) <> False) then
  begin
    Result := Info.srWindow.Right - Info.srWindow.Left + 1;
    if Result > 0 then
      Exit;
  end;
  S := SysUtils.GetEnvironmentVariable('COLUMNS');
  Result := StrToIntDef(S, 80);
  if Result <= 0 then
    Result := 80;
end;
{$ELSE}
type
  TWinsize = record
    ws_row, ws_col: Word;
  end;

const
  TIOCGWINSZ = $5413;   { terminal size query (Linux) }

function ioctl(fd: Integer; request: LongInt; arg: Pointer): Integer; cdecl; external 'c';

{ Terminal width in columns. }
function TermWidth(FD: Integer = 1): Integer;
var
  WS: TWinsize;
  S: string;
begin
  if (ioctl(FD, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) then
    Exit(Integer(WS.ws_col));
  S := SysUtils.GetEnvironmentVariable('COLUMNS');
  Result := StrToIntDef(S, 80);
  if Result <= 0 then
    Result := 80;
end;
{$ENDIF}

{ True if the code point is zero-width: joiners (ZWJ/ZWNJ),
  variation selectors, combining diacritics, skin tone modifiers,
  invisible format characters. }
function IsZeroWidthCP(CP: Integer): Boolean;
begin
  Result :=
    ((CP >= $0300) and (CP <= $036F)) or  { combining diacritics }
    ((CP >= $0483) and (CP <= $0489)) or
    ((CP >= $0591) and (CP <= $05BD)) or
    ((CP >= $0610) and (CP <= $061A)) or
    ((CP >= $064B) and (CP <= $065F)) or
    ((CP >= $0670) and (CP <= $0670)) or
    ((CP >= $06D6) and (CP <= $06DC)) or
    ((CP >= $0900) and (CP <= $0902)) or
    ((CP >= $1100) and (CP <= $115F)) or  { Hangul: combining parts }
    ((CP >= $1F3FB) and (CP <= $1F3FF)) or  { skin tone }
    ((CP >= $200B) and (CP <= $200F)) or  { ZWSP/ZWNJ/ZWJ/LRM/RLM }
    ((CP >= $202A) and (CP <= $202E)) or
    ((CP >= $2060) and (CP <= $206F)) or
    ((CP >= $FE00) and (CP <= $FE0F)) or  { variation selectors }
    (CP = $FEFF) or
    ((CP >= $E0100) and (CP <= $E01EF));
end;

{ True if the code point is wide (2 columns in a terminal): CJK, fullwidth
  forms, plus symbols and emoji that terminals draw wide. }
function IsWideCP(CP: Integer): Boolean;
begin
  Result :=
    ((CP >= $1100) and (CP <= $115F)) or    { Hangul: jamo }
    ((CP >= $2E80) and (CP <= $2FFF)) or    { CJK radicals, symbols }
    ((CP >= $3000) and (CP <= $303E)) or
    ((CP >= $3041) and (CP <= $33FF)) or    { hiragana, katakana, CJK }
    ((CP >= $3400) and (CP <= $4DBF)) or    { CJK ext A }
    ((CP >= $4E00) and (CP <= $9FFF)) or    { CJK unified }
    ((CP >= $A000) and (CP <= $A4CF)) or    { Yi }
    ((CP >= $A960) and (CP <= $A97F)) or    { Hangul ext A }
    ((CP >= $AC00) and (CP <= $D7A3)) or    { Hangul: syllables }
    ((CP >= $F900) and (CP <= $FAFF)) or    { CJK compat }
    ((CP >= $FF00) and (CP <= $FF60)) or    { fullwidth forms }
    ((CP >= $FFE0) and (CP <= $FFFD)) or    { fullwidth punctuation }
    ((CP >= $20000) and (CP <= $3FFFD)) or  { CJK ext B+ }
    { Symbols and emoji: in practice they are drawn in 2 columns. }
    ((CP >= $2600) and (CP <= $27BF)) or    { symbols, dingbats }
    ((CP >= $2900) and (CP <= $29FF)) or
    ((CP >= $2B00) and (CP <= $2BFF)) or
    ((CP >= $1F000) and (CP <= $1FAFF));    { emoji and extra symbols }
end;

{ Visible length of a string in columns: without ANSI sequences. }
function VisibleLen(const S: string): Integer;
var
  I, J, N, CP, Len: Integer;
begin
  Result := 0;
  N := Length(S);
  I := 1;
  while I <= N do
  begin
    if S[I] = #27 then
    begin
      { Skip the ANSI sequence: ESC, the lead byte ($3C..$3F, $5B..$5F),
        the parameter ($30..$3F) and intermediate ($20..$2F) bytes - up to
        the final byte ($40..$7E). }
      Inc(I);
      if (I <= N) and ((Ord(S[I]) in [$3C..$3F]) or (Ord(S[I]) in [$5B..$5F])) then
        Inc(I);
      while (I <= N) and (Ord(S[I]) in [$20..$3F]) do
        Inc(I);
      if I <= N then
        Inc(I);
    end
    else if Ord(S[I]) < $80 then
    begin
      Inc(Result);
      Inc(I);
    end
    else if (Ord(S[I]) and $C0) <> $C0 then
    begin
      { A continuation byte without a lead byte - count it as one character. }
      Inc(Result);
      Inc(I);
    end
    else
    begin
      { Decode the UTF-8 code point. }
      CP := Ord(S[I]);
      if CP < $E0 then
      begin
        Len := 2;
        CP := CP and $1F;
      end
      else if CP < $F0 then
      begin
        Len := 3;
        CP := CP and $0F;
      end
      else
      begin
        Len := 4;
        CP := CP and $07;
      end;
      if I + Len - 1 > N then
      begin
        { Truncated sequence - count it as one character. }
        Inc(Result);
        Inc(I);
        Continue;
      end;
      for J := 2 to Len do
        CP := (CP shl 6) or (Ord(S[I + J - 1]) and $3F);
      if IsWideCP(CP) then
        Inc(Result, 2)
      else if not IsZeroWidthCP(CP) then
        Inc(Result);
      Inc(I, Len);
    end;
  end;
end;

{ Truncates S to MaxCols visible columns without breaking a UTF-8 character
  and without leaving a dangling ANSI sequence. The result never exceeds
  MaxCols columns: a wide character that does not fit (MaxCols - 1 columns
  used, 2 columns needed) is dropped instead of being cut. ANSI sequences
  before the cut are kept byte for byte and, if the kept prefix carries any,
  the result is closed with an SGR reset so the rest of the line is not
  repainted. MaxCols <= 0 - S is returned unchanged. }
function TruncateVisible(const S: string; MaxCols: Integer): string;
var
  I, J, N, CP, Len, W, Cols, Keep, KeepLast: Integer;
  HasAnsi, KeepAnsi: Boolean;
begin
  if MaxCols <= 0 then
    Exit(S);
  N := Length(S);
  Cols := 0;
  Keep := 0;
  KeepLast := 0;
  HasAnsi := False;
  KeepAnsi := False;
  I := 1;
  while I <= N do
  begin
    if S[I] = #27 then
    begin
      { Skip the whole ANSI sequence (the same rule as in VisibleLen): it
        takes no columns and is kept only if the cut comes after it. }
      Inc(I);
      if (I <= N) and ((Ord(S[I]) in [$3C..$3F]) or (Ord(S[I]) in [$5B..$5F])) then
        Inc(I);
      while (I <= N) and (Ord(S[I]) in [$20..$3F]) do
        Inc(I);
      if I <= N then
        Inc(I);
      Keep := I - 1;
      HasAnsi := True;
      Continue;
    end;
    if Ord(S[I]) < $80 then
    begin
      { Plain ASCII character: 1 column, 1 byte. }
      W := 1;
      Len := 1;
    end
    else if (Ord(S[I]) and $C0) <> $C0 then
    begin
      { A continuation byte without a lead byte - one column, one byte. }
      W := 1;
      Len := 1;
    end
    else
    begin
      { Decode the UTF-8 code point. }
      CP := Ord(S[I]);
      if CP < $E0 then
      begin
        Len := 2;
        CP := CP and $1F;
      end
      else if CP < $F0 then
      begin
        Len := 3;
        CP := CP and $0F;
      end
      else
      begin
        Len := 4;
        CP := CP and $07;
      end;
      if I + Len - 1 > N then
      begin
        { Truncated sequence - count it as one character. }
        W := 1;
        Len := 1;
      end
      else
      begin
        for J := 2 to Len do
          CP := (CP shl 6) or (Ord(S[I + J - 1]) and $3F);
        if IsWideCP(CP) then
          W := 2
        else if IsZeroWidthCP(CP) then
          W := 0
        else
          W := 1;
      end;
    end;
    if Cols + W > MaxCols then
    begin
      { The character does not fit: cut before the trailing ANSI sequences, so
        an SGR that follows the last visible character is not kept. }
      Keep := KeepLast;
      HasAnsi := KeepAnsi;
      Break;
    end;
    Inc(Cols, W);
    Inc(I, Len);
    Keep := I - 1;
    KeepLast := Keep;
    KeepAnsi := HasAnsi;
  end;
  { The whole string fitted - return it unchanged (no reset is added). }
  if Keep >= N then
    Exit(S);
  Result := Copy(S, 1, Keep);
  if HasAnsi then
    Result := Result + #27 + '[0m';
end;

{ Wraps a line by words: the last space before which the fragment still fits
  into Width becomes the break point; the space itself goes into neither the
  previous nor the next fragment. If there are no spaces (or none fits) -
  a forced break at the largest fitting prefix. }
function WrapText(const S: string; Width: Integer; Measure: TTextMeasure;
  BreakAllowed: TBreakAllowed): TStringList;
var
  Rem, Prefix: string;
  I, IStart, BestP, L: Integer;
  First: Boolean;
begin
  Result := TStringList.Create;
  if Width < 1 then
    Width := 1;
  Rem := S;
  First := True;
  while Rem <> '' do
  begin
    if First then
    begin
      { Keep the leading spaces of the line (the indent) - they belong to
        the first word. A line of only spaces is an empty line. }
      if TrimLeft(Rem) = '' then
      begin
        Result.Add('');
        Break;
      end;
    end
    else
      { A fragment after a break must not start with a space. }
      while (Rem <> '') and (Rem[1] = ' ') do
        Delete(Rem, 1, 1);
    if Rem = '' then
      Break;
    if Measure(Rem) < Width then
    begin
      Result.Add(Rem);
      Break;
    end;
    { Break points are spaces. For the first fragment the leading spaces
      (the indent) are not break points: they stay with the first word. }
    IStart := 1;
    if First then
      while (IStart <= Length(Rem)) and (Rem[IStart] = ' ') do
        Inc(IStart);
    { The last space before which the fragment still fits and where a break
      is allowed. Check every space (no early exit): the visible width is not
      always monotonic because of closing markup. }
    BestP := 0;
    for I := IStart to Length(Rem) do
      if Rem[I] = ' ' then
      begin
        Prefix := Copy(Rem, 1, I - 1);
        if (Measure(Prefix) < Width) and
           ((BreakAllowed = nil) or BreakAllowed(Prefix)) then
          BestP := I;
      end;
    if BestP > 1 then
    begin
      Result.Add(Copy(Rem, 1, BestP - 1));
      Rem := Copy(Rem, BestP + 1, MaxInt);
    end
    else if BestP = 1 then
      Rem := Copy(Rem, 2, MaxInt)   { leading space - drop it }
    else
    begin
      { No safe space: the largest prefix that fits into the line. The break
        may land inside markup, but the main thing is kept - the fragment is
        not wider than the line (otherwise a partial line cannot be redrawn). }
      L := 0;
      for I := 1 to Length(Rem) do
      begin
        Prefix := Copy(Rem, 1, I);
        if Measure(Prefix) < Width then
          L := I
        else if L > 0 then
          Break;
      end;
      if L = 0 then
        L := 1;   { at least one character, otherwise an endless loop }
      if First and (L < IStart) then
        L := IStart;   { do not lose the indent: at least up to the first word }
      Result.Add(Copy(Rem, 1, L));
      Rem := Copy(Rem, L + 1, MaxInt);
    end;
    First := False;
  end;
  if Result.Count = 0 then
    Result.Add('');
end;

{ Number of bytes in a UTF-8 sequence by its lead byte; 1 - for
  ASCII and for an invalid lead byte. }
function UTF8SeqLenByLead(Lead: Byte): Integer;
begin
  if Lead < $80 then
    Result := 1
  else if (Lead and $E0) = $C0 then
    Result := 2
  else if (Lead and $F0) = $E0 then
    Result := 3
  else if (Lead and $F8) = $F0 then
    Result := 4
  else
    Result := 1;
end;

function UTF8SeqValid(const S: string; I: Integer): Boolean;
var
  B: Byte;
  N, J: Integer;
begin
  Result := False;
  if (I < 1) or (I > Length(S)) then
    Exit;
  B := Byte(S[I]);
  if B < $80 then
  begin
    Result := True;
    Exit;
  end;
  N := UTF8SeqLenByLead(B);
  if (N < 2) or (I + N - 1 > Length(S)) then
    Exit;
  for J := 1 to N - 1 do
    if (Byte(S[I + J]) and $C0) <> $80 then
      Exit;
  { Filter out overlong sequences and surrogates. }
  if N = 2 then
    Result := B >= $C2
  else if N = 3 then
    Result := not (((B = $E0) and (Byte(S[I + 1]) < $A0)) or
                   ((B = $ED) and (Byte(S[I + 1]) >= $A0)))
  else
    Result := (B <= $F4) and
              not ((B = $F0) and (Byte(S[I + 1]) < $90)) and
              not ((B = $F4) and (Byte(S[I + 1]) >= $90));
end;

function TruncateUTF8(const S: string; MaxBytes: Integer): string;
var
  I, N: Integer;
begin
  if MaxBytes <= 0 then
    Exit('');
  if Length(S) <= MaxBytes then
    Exit(S);
  { Byte MaxBytes may be a continuation of a multi-byte character:
    step back to its lead byte. }
  I := MaxBytes;
  while (I >= 1) and ((Byte(S[I]) and $C0) = $80) do
    Dec(I);
  if I = 0 then
    Exit('');
  N := UTF8SeqLenByLead(Byte(S[I]));
  if I + N - 1 <= MaxBytes then
    Result := Copy(S, 1, I + N - 1)
  else
    Result := Copy(S, 1, I - 1);
end;

function IsValidUTF8(const S: string): Boolean;
var
  I: Integer;
begin
  I := 1;
  while I <= Length(S) do
  begin
    if not UTF8SeqValid(S, I) then
      Exit(False);
    if Byte(S[I]) < $80 then
      Inc(I)
    else
      Inc(I, UTF8SeqLenByLead(Byte(S[I])));
  end;
  Result := True;
end;

function SanitizeUTF8(const S: string): string;
var
  I, N: Integer;
begin
  if IsValidUTF8(S) then
    Exit(S);
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if UTF8SeqValid(S, I) then
    begin
      if Byte(S[I]) < $80 then
        N := 1
      else
        N := UTF8SeqLenByLead(Byte(S[I]));
      Result := Result + Copy(S, I, N);
      Inc(I, N);
    end
    else
    begin
      Result := Result + #$EF#$BF#$BD;   { U+FFFD instead of the broken byte }
      Inc(I);
    end;
  end;
end;
function ShortenLinesMiddle(const S: string; MaxLines: Integer): string;
var
  Lines: TStringList;
  I, Head, Tail: Integer;
  Sep: string;
  HadEol: Boolean;
begin
  if (MaxLines <= 0) or (S = '') then
    Exit(S);
  Lines := TStringList.Create;
  try
    { Text splits at CRLF/LF/CR; a trailing line break does not produce
      an extra empty line. }
    Lines.Text := S;
    if Lines.Count <= MaxLines then
      Exit(S);
    { The N result lines consist of N - 1 content lines and the "..." marker;
      with an even N one line more is kept at the bottom (the end of the output
      is usually more important). For N = 9 that gives 4 + "..." + 4. }
    Head := (MaxLines - 1) div 2;
    Tail := (MaxLines - 1) - Head;
    { Keep the line break style of the source text. }
    if Pos(#13#10, S) > 0 then
      Sep := #13#10
    else if Pos(#10, S) > 0 then
      Sep := #10
    else
      Sep := LineEnding;
    HadEol := (S[Length(S)] = #10) or (S[Length(S)] = #13);
    Result := '';
    for I := 0 to Head - 1 do
      Result := Result + Lines[I] + Sep;
    { The truncation marker is printed with an indent (SHORTEN_ELLIPSIS_INDENT):
      otherwise the ellipsis sits flush with the start of the line and reads as
      the first line of the output instead of a separator. }
    Result := Result + StringOfChar(' ', SHORTEN_ELLIPSIS_INDENT) + '…' + Sep;
    for I := Lines.Count - Tail to Lines.Count - 1 do
      Result := Result + Lines[I] + Sep;
    if not HadEol then
      Delete(Result, Length(Result) - Length(Sep) + 1, Length(Sep));
  finally
    Lines.Free;
  end;
end;

function TrimBlankLines(const S: string): string;
var
  Lines: TStringList;
  I, First, Last: Integer;
  Sep: string;
begin
  if S = '' then
    Exit('');
  Lines := TStringList.Create;
  try
    { Text splits at CRLF/LF/CR; a trailing line break does not produce
      an extra empty line. }
    Lines.Text := S;
    First := 0;
    while (First < Lines.Count) and (Trim(Lines[First]) = '') do
      Inc(First);
    { The whole text is blank lines - nothing to print. }
    if First >= Lines.Count then
      Exit('');
    Last := Lines.Count - 1;
    while (Last > First) and (Trim(Lines[Last]) = '') do
      Dec(Last);
    { Keep the line break style of the source text. }
    if Pos(#13#10, S) > 0 then
      Sep := #13#10
    else if Pos(#10, S) > 0 then
      Sep := #10
    else
      Sep := LineEnding;
    Result := '';
    for I := First to Last - 1 do
      Result := Result + Lines[I] + Sep;
    Result := Result + Lines[Last];
  finally
    Lines.Free;
  end;
end;

{ --- Diff --- }

function MakeUnifiedDiff(const OldLines, NewLines: TStringList;
  const OldName, NewName: string; OldStartLine: Integer = 1;
  Context: Integer = 3): string;
const
  { LCS table size limit: 8 million cells (~32 MB) - about 0.3 s. }
  LCS_MAX_CELLS = 8 * 1000 * 1000;
var
  N, M: Integer;
  Prefix, Suffix: Integer;
  OldMid, NewMid: TStringList;
  NoLcs: Boolean;
  Cells: Int64;
  LCS: array of array of Integer;
  I, J: Integer;
  Ops: TStringList;
  OldPos, NewPos: Integer;
  DiffLines: TStringList;
  HunkStart, HunkEnd, ChangeEnd: Integer;
  OldLineNum, NewLineNum: Integer;
  OldCount, NewCount: Integer;
  OldStart, NewStart: Integer;
  Line: string;
begin
  N := OldLines.Count;
  M := NewLines.Count;

  if (N = 0) and (M = 0) then
    Exit('');

  { Cut off the common prefix and suffix: a normal edit touches one place, and
    the LCS is enough for the "middle". Without cutting, the table is built for
    the whole file (N*M cells): 10k lines - 400 MB and seconds, 50k lines -
    an edit that practically hangs. }
  Prefix := 0;
  while (Prefix < N) and (Prefix < M) and
        (OldLines[Prefix] = NewLines[Prefix]) do
    Inc(Prefix);
  Suffix := 0;
  while (Suffix < N - Prefix) and (Suffix < M - Prefix) and
        (OldLines[N - 1 - Suffix] = NewLines[M - 1 - Suffix]) do
    Inc(Suffix);

  OldMid := TStringList.Create;
  NewMid := TStringList.Create;
  Ops := TStringList.Create;
  DiffLines := TStringList.Create;
  DiffLines.LineBreak := sLineBreak;
  try
    for I := Prefix to N - Suffix - 1 do
      OldMid.Add(OldLines[I]);
    for I := Prefix to M - Suffix - 1 do
      NewMid.Add(NewLines[I]);
    N := OldMid.Count;
    M := NewMid.Count;

    { Fully equal - no changes. }
    if (N = 0) and (M = 0) then
      Exit('');

    { If one side is empty or the middle is too large (the edit rewrote
      almost the whole file), do not compute the LCS - return it as a full replacement. }
    Cells := Int64(N) * Int64(M);
    NoLcs := (N = 0) or (M = 0) or (Cells > LCS_MAX_CELLS);

    if not NoLcs then
    begin
      { LCS table: LCS[i,j] = length of the longest common subsequence
        of OldMid[i..N-1] and NewMid[j..M-1]. }
      SetLength(LCS, N + 1, M + 1);
      for I := N - 1 downto 0 do
        for J := M - 1 downto 0 do
          if OldMid[I] = NewMid[J] then
            LCS[I, J] := LCS[I + 1, J + 1] + 1
          else
            if LCS[I + 1, J] >= LCS[I, J + 1] then
              LCS[I, J] := LCS[I + 1, J]
            else
              LCS[I, J] := LCS[I, J + 1];
    end;

    { List of operations (' ' - match, '-' - removed from Old,
      '+' - added from New) for the whole file: prefix, middle, suffix. }
    for I := 1 to Prefix do
      Ops.Add(' ');

    if NoLcs then
    begin
      for I := 1 to N do
        Ops.Add('-');
      for I := 1 to M do
        Ops.Add('+');
    end
    else
    begin
      OldPos := 0;
      NewPos := 0;
      while (OldPos < N) or (NewPos < M) do
      begin
        if (OldPos < N) and (NewPos < M) and
           (OldMid[OldPos] = NewMid[NewPos]) then
        begin
          Ops.Add(' ');
          Inc(OldPos);
          Inc(NewPos);
        end
        else if (OldPos < N) and
                ((NewPos >= M) or
                 (LCS[OldPos + 1, NewPos] >= LCS[OldPos, NewPos + 1])) then
        begin
          Ops.Add('-');
          Inc(OldPos);
        end
        else
        begin
          Ops.Add('+');
          Inc(NewPos);
        end;
      end;
    end;

    for I := 1 to Suffix do
      Ops.Add(' ');

    { No changes - an empty diff. }
    I := 0;
    while (I < Ops.Count) and (Ops[I] = ' ') do
      Inc(I);
    if I = Ops.Count then
      Exit('');

    { Build the unified diff. Accumulate lines in a TStringList: gluing
      S := S + ... on every line of the file gives quadratic copying volume. }
    if OldName <> '' then
      DiffLines.Add('--- ' + OldName);
    if NewName <> '' then
      DiffLines.Add('+++ ' + NewName);

    I := 0;
    while I < Ops.Count do
    begin
      if Ops[I] = ' ' then
      begin
        Inc(I);
        Continue;
      end;

      { Start of the change block; extend it to the left with context. }
      HunkStart := I;
      while (HunkStart > 0) and (Ops[HunkStart - 1] = ' ') and
            (I - HunkStart < Context) do
        Dec(HunkStart);


      { End of the change block. }
      ChangeEnd := I;
      while (ChangeEnd < Ops.Count) and (Ops[ChangeEnd] <> ' ') do
        Inc(ChangeEnd);
      HunkEnd := ChangeEnd;

      { Extend to the right with context (counted from the end of the change block). }
      while (HunkEnd < Ops.Count) and (Ops[HunkEnd] = ' ') and
            (HunkEnd - ChangeEnd < Context) do
        Inc(HunkEnd);

      { Line numbers at the start of the hunk (0-based indices). }
      OldLineNum := 0;
      NewLineNum := 0;
      for J := 0 to HunkStart - 1 do
      begin
        if (Ops[J] = ' ') or (Ops[J] = '-') then
          Inc(OldLineNum);
        if (Ops[J] = ' ') or (Ops[J] = '+') then
          Inc(NewLineNum);
      end;

      { Number of lines in the hunk. }
      OldCount := 0;
      NewCount := 0;
      for J := HunkStart to HunkEnd - 1 do
      begin
        if (Ops[J] = ' ') or (Ops[J] = '-') then
          Inc(OldCount);
        if (Ops[J] = ' ') or (Ops[J] = '+') then
          Inc(NewCount);
      end;

      { Hunk header: @@ -old_start,old_count +new_start,new_count @@ }
      OldStart := OldLineNum + OldStartLine;
      NewStart := NewLineNum + OldStartLine;
      if OldCount = 0 then
        Dec(OldStart);
      if NewCount = 0 then
        Dec(NewStart);

      DiffLines.Add('@@ -' + IntToStr(OldStart) + ',' + IntToStr(OldCount) +
        ' +' + IntToStr(NewStart) + ',' + IntToStr(NewCount) + ' @@');

      { Hunk body. }
      for J := HunkStart to HunkEnd - 1 do
      begin
        Line := Ops[J];
        if Line = ' ' then
        begin
          DiffLines.Add(' ' + OldLines[OldLineNum]);
          Inc(OldLineNum);
          Inc(NewLineNum);
        end
        else if Line = '-' then
        begin
          DiffLines.Add('-' + OldLines[OldLineNum]);
          Inc(OldLineNum);
        end
        else
        begin
          DiffLines.Add('+' + NewLines[NewLineNum]);
          Inc(NewLineNum);
        end;
      end;

      I := HunkEnd;
    end;

    Result := DiffLines.Text;
  finally
    NewMid.Free;
    OldMid.Free;
    Ops.Free;
    DiffLines.Free;
  end;
end;
initialization
  FColorsAllowed := SysUtils.GetEnvironmentVariable('NO_COLOR') = '';
  FAnsiChecked := False;

end.
