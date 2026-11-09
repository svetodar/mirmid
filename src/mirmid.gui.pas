unit mirmid.gui;
{ GUI automation tools (stage 1, the "eyes"): list_windows, find_window,
  window_info. On Windows -- natively through the WinAPI (EnumWindows,
  GetWindowTextW, GetClassNameW, GetWindowRect, EnumChildWindows); on Unix --
  through the xwininfo/xprop utilities (x11-utils package) via shell. The tools
  only read the window state: they write no files and need no separate
  permission. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools;

const
  LIST_WINDOWS_TOOL_NAME = 'list_windows';
  FIND_WINDOW_TOOL_NAME  = 'find_window';
  WINDOW_INFO_TOOL_NAME  = 'window_info';

{ Registers the list_windows, find_window and window_info tools in the registry. }
procedure RegisterGuiTools(R: TToolRegistry);

implementation

uses
  SysUtils, Classes, fpjson, mirmid.util, mirmid.json
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{ ------------------------------------------------------- common formatting }

{ Window line: hwnd  "title"  [class]  (x, y)  WxH. }
function FormatWinLine(const HwndStr, Title, Cls: string;
  X, Y, W, H: Integer): string;
begin
  Result := HwndStr + '  "' + Title + '"  [' + Cls + ']  (' +
    IntToStr(X) + ', ' + IntToStr(Y) + ')  ' + IntToStr(W) + 'x' + IntToStr(H);
end;

{ Does Needle match Hay: Exact -- exact match, otherwise a substring search.
  An empty Needle does not filter (it matches). }
function MatchStr(const Needle, Hay: string; Exact: Boolean): Boolean;
begin
  if Needle = '' then
    Exit(True);
  if Exact then
    Exit(Hay = Needle);
  Result := Pos(Needle, Hay) > 0;
end;

{ Platform backend functions (implemented below, in the IFDEF block). }
function GuiListWindows(var Lines: TStringList; out Err: string): Boolean; forward;
function GuiFindWindow(const Title, Cls: string; Exact: Boolean;
  var Lines: TStringList; out Err: string): Boolean; forward;
function GuiWindowInfo(const HwndStr: string; IncludeChildren: Boolean;
  out Info: string; out Err: string): Boolean; forward;

{ ================================================================ Windows }

{$IFDEF WINDOWS}

{ Window title (Unicode -> UTF-8). }
function WinTitle(Wnd: HWND): string;
var
  Buf: array[0..4095] of WideChar;
  N: Integer;
  WS: WideString;
begin
  N := GetWindowTextW(Wnd, @Buf, Length(Buf));
  if N > 0 then
  begin
    SetLength(WS, N);
    Move(Buf, WS[1], N * SizeOf(WideChar));
    Result := UTF8Encode(WS);
  end
  else
    Result := '';
end;

{ Window class (Unicode -> UTF-8). }
function WinClass(Wnd: HWND): string;
var
  Buf: array[0..255] of WideChar;
  N: Integer;
  WS: WideString;
begin
  N := GetClassNameW(Wnd, @Buf, Length(Buf));
  if N > 0 then
  begin
    SetLength(WS, N);
    Move(Buf, WS[1], N * SizeOf(WideChar));
    Result := UTF8Encode(WS);
  end
  else
    Result := '';
end;

{ Window handle in hexadecimal form (0x...), without leading zeros. }
function HwndHex(Wnd: HWND): string;
const
  HexChars = '0123456789abcdef';
var
  V: QWord;
  I: Integer;
  D: Byte;
  S: string;
begin
  V := QWord(Wnd);
  if V = 0 then
    Exit('0x0');
  S := '';
  for I := 15 downto 0 do
  begin
    D := Byte((V shr (I * 4)) and $F);
    S := S + HexChars[D + 1];
  end;
  I := 1;
  while (I < Length(S)) and (S[I] = '0') do
    Inc(I);
  Result := '0x' + Copy(S, I, MaxInt);
end;

{ Parses hwnd: 0x... (hex) or a decimal number. 0 -- invalid. }
function ParseHwnd(const S: string): QWord;
var
  T: string;
  V: Int64;
  Code: Integer;
begin
  T := Trim(S);
  if Copy(T, 1, 2) = '0x' then
  begin
    Val('$' + Copy(T, 3, MaxInt), V, Code);
    if Code = 0 then
      Exit(QWord(V));
    Exit(0);
  end;
  Result := StrToQWordDef(T, 0);
end;

{ Window line. }
function WinLine(Wnd: HWND): string;
var
  R: TRect;
begin
  R.Left := 0;
  R.Top := 0;
  R.Right := 0;
  R.Bottom := 0;
  GetWindowRect(Wnd, R);
  Result := FormatWinLine(HwndHex(Wnd), WinTitle(Wnd), WinClass(Wnd),
    R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top);
end;

{ --- enumerating top-level windows --- }

function EnumTopProc(Wnd: HWND; Param: LPARAM): WINBOOL; stdcall;
var
  L: TStringList;
begin
  L := TStringList(Pointer(Param));
  if IsWindowVisible(Wnd) then
    L.Add(WinLine(Wnd));
  Result := True;
end;

function GuiListWindows(var Lines: TStringList; out Err: string): Boolean;
begin
  Err := '';
  EnsureDpiAware;
  EnumWindows(@EnumTopProc, LPARAM(Lines));
  Result := True;
end;

{ --- finding a window by title/class --- }

type
  TFindState = record
    Title: string;
    Cls: string;
    Exact: Boolean;
    Lines: TStringList;
  end;
  PFindState = ^TFindState;

function FindProc(Wnd: HWND; Param: LPARAM): WINBOOL; stdcall;
var
  S: PFindState;
  T, C: string;
begin
  S := PFindState(Pointer(Param));
  if IsWindowVisible(Wnd) then
  begin
    T := WinTitle(Wnd);
    C := WinClass(Wnd);
    if MatchStr(S^.Title, T, S^.Exact) and MatchStr(S^.Cls, C, S^.Exact) then
      S^.Lines.Add(WinLine(Wnd));
  end;
  Result := True;
end;

function GuiFindWindow(const Title, Cls: string; Exact: Boolean;
  var Lines: TStringList; out Err: string): Boolean;
var
  S: TFindState;
begin
  EnsureDpiAware;
  Err := '';
  S.Title := Title;
  S.Cls := Cls;
  S.Exact := Exact;
  S.Lines := Lines;
  EnumWindows(@FindProc, LPARAM(@S));
  Result := True;
end;

{ --- window details and child controls --- }

function EnumChildProc(Wnd: HWND; Param: LPARAM): WINBOOL; stdcall;
var
  L: TStringList;
begin
  L := TStringList(Pointer(Param));
  L.Add('  ' + WinLine(Wnd));
  Result := True;
end;

function GuiWindowInfo(const HwndStr: string; IncludeChildren: Boolean;
  out Info: string; out Err: string): Boolean;
var
  Wnd: HWND;
  R: TRect;
  H: QWord;
  Children: TStringList;
begin
  EnsureDpiAware;
  Err := '';
  Info := '';
  H := ParseHwnd(HwndStr);
  if H = 0 then
  begin
    Err := 'invalid hwnd: ' + HwndStr;
    Exit(False);
  end;
  Wnd := HWND(H);
  if not IsWindow(Wnd) then
  begin
    Err := 'window not found: ' + HwndStr;
    Exit(False);
  end;
  R.Left := 0;
  R.Top := 0;
  R.Right := 0;
  R.Bottom := 0;
  GetWindowRect(Wnd, R);
  Info := 'window: ' + HwndHex(Wnd) + '  "' + WinTitle(Wnd) + '"' + sLineBreak +
    'class: ' + WinClass(Wnd) + sLineBreak +
    Format('position: (%d, %d), size: %dx%d',
      [R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top]);
  if IncludeChildren then
  begin
    Children := TStringList.Create;
    try
      EnumChildWindows(Wnd, @EnumChildProc, LPARAM(Children));
      if Children.Count > 0 then
        Info := Info + sLineBreak +
          Format('child controls: %d', [Children.Count]) +
          sLineBreak + Children.Text
      else
        Info := Info + sLineBreak + 'child controls: 0';
    finally
      Children.Free;
    end;
  end;
  Result := True;
end;

{$ELSE}
{ ================================================================== Unix }

const
  { Timeout of the external X utilities, sec. }
  X_TIMEOUT = 15;

{ Runs a command, returns stdout+stderr and the exit code. False on a start
  failure (timeout/could not start). }
function RunXCode(const Cmd: string; out Out: string;
  out ExitCode: Integer): Boolean;
var
  Err: string;
begin
  Out := '';
  ExitCode := 0;
  Result := RunProcess(Cmd, '', X_TIMEOUT, Out, ExitCode, Err);
  if not Result then
    Out := Err;
end;

{ Runs a command, returns stdout+stderr (without the exit code). }
function RunX(const Cmd: string; out Out: string): Boolean;
var
  ExitCode: Integer;
begin
  Result := RunXCode(Cmd, Out, ExitCode);
end;

{ Is the utility available in PATH? }
function ToolAvailable(const Name: string): Boolean;
var
  Out: string;
  ExitCode: Integer;
  Err: string;
begin
  Result := False;
  if RunProcess('command -v ' + Name, '', 5, Out, ExitCode, Err) then
    Result := Trim(Out) <> '';
end;

{ Is an X display available? }
function DisplayAvailable: Boolean;
begin
  Result := (GetEnvironmentVariable('DISPLAY') <> '');
end;

{ The n-th quoted string in S (1-based). Empty if there is none. }
function ExtractNthQuoted(const S: string; N: Integer): string;
var
  Pos, Open, Close: Integer;
  Count: Integer;
begin
  Result := '';
  Count := 0;
  Pos := 1;
  while True do
  begin
    Open := 0;
    for Pos := Pos to Length(S) do
      if S[Pos] = '"' then
      begin
        Open := Pos;
        Break;
      end;
    if Open = 0 then
      Break;
    Close := 0;
    for Pos := Open + 1 to Length(S) do
      if S[Pos] = '"' then
      begin
        Close := Pos;
        Break;
      end;
    if Close = 0 then
      Break;
    Inc(Count);
    if Count = N then
    begin
      Result := Copy(S, Open + 1, Close - Open - 1);
      Exit;
    end;
    Pos := Close + 1;
  end;
end;

{ xwininfo geometry: "WxH+X+Y  +X+Y" -> W, H (from the first part) and the
  absolute X, Y. }
procedure ParseGeometry(const S: string; out X, Y, W, H: Integer);
var
  L: TStringList;
  T1, T2: string;
  P, Q: Integer;
begin
  X := 0; Y := 0; W := 0; H := 0;
  L := TStringList.Create;
  try
    L.Delimiter := ' ';
    L.StrictDelimiter := False;
    L.DelimitedText := S;
    if L.Count < 2 then
      Exit;
    T1 := L[L.Count - 2];   { WxH+X+Y }
    T2 := L[L.Count - 1];   { +X+Y }
    P := Pos('x', T1);
    if P > 0 then
    begin
      W := StrToIntDef(Copy(T1, 1, P - 1), 0);
      Q := Pos('+', Copy(T1, P + 1, MaxInt));
      if Q > 0 then
        H := StrToIntDef(Copy(T1, P + 1, Q - 1), 0);
    end;
    Q := Pos('+', Copy(T2, 2, MaxInt));
    if Q > 0 then
    begin
      X := StrToIntDef(Copy(T2, 2, Q - 1), 0);
      Y := StrToIntDef(Copy(T2, 2 + Q, MaxInt), 0);
    end;
  finally
    L.Free;
  end;
end;

type
  TGuiWin = record
    HwndStr, Title, Cls: string;
    X, Y, W, H: Integer;
  end;
  TGuiWinArr = array of TGuiWin;

{ Parses a xwininfo -children line:
  "     0x400003 ""ibus-xim"": (""i"" ""c"")  2x2+0+0  +0+0". }
function ParseXwininfoLine(const Line: string; out W: TGuiWin): Boolean;
var
  T, Rest, Inner, Geo: string;
  P: Integer;
begin
  Result := False;
  W.HwndStr := ''; W.Title := ''; W.Cls := '';
  W.X := 0; W.Y := 0; W.W := 0; W.H := 0;
  T := Trim(Line);
  if Copy(T, 1, 2) <> '0x' then
    Exit;
  P := Pos(' ', T);
  if P = 0 then
    Exit;
  W.HwndStr := Copy(T, 1, P - 1);
  Rest := Trim(Copy(T, P + 1, MaxInt));
  if Copy(Rest, 1, 1) = '"' then
  begin
    P := Pos('"', Copy(Rest, 2, MaxInt));
    if P = 0 then
      Exit;
    W.Title := Copy(Rest, 2, P - 1);
    Rest := Trim(Copy(Rest, P + 2, MaxInt));
  end
  else if Copy(Rest, 1, 13) = '(has no name)' then
  begin
    W.Title := '';
    Rest := Trim(Copy(Rest, 14, MaxInt));
  end
  else
    Exit;
  if Copy(Rest, 1, 2) <> ': ' then
    Exit;
  Rest := Trim(Copy(Rest, 3, MaxInt));
  if Copy(Rest, 1, 1) <> '(' then
    Exit;
  P := Pos(')', Rest);
  if P = 0 then
    Exit;
  Inner := Copy(Rest, 2, P - 2);
  W.Cls := ExtractNthQuoted(Inner, 2);
  if W.Cls = '' then
    W.Cls := ExtractNthQuoted(Inner, 1);
  Geo := Trim(Copy(Rest, P + 1, MaxInt));
  ParseGeometry(Geo, W.X, W.Y, W.W, W.H);
  Result := True;
end;

{ Reads the list of top-level windows (xwininfo -root -children). }
function ReadAllWindows(out Wins: TGuiWinArr; out Err: string): Boolean;
var
  Out: string;
  L: TStringList;
  I: Integer;
  W: TGuiWin;
begin
  Err := '';
  Result := False;
  SetLength(Wins, 0);
  if not DisplayAvailable then
  begin
    Err := 'no X display (DISPLAY is not set)';
    Exit;
  end;
  if not ToolAvailable('xwininfo') then
  begin
    Err := 'the xwininfo utility is required (x11-utils package)';
    Exit;
  end;
  if not RunX('xwininfo -root -children', Out) then
  begin
    Err := 'failed to run xwininfo: ' + Out;
    Exit;
  end;
  L := TStringList.Create;
  try
    L.Text := Out;
    for I := 0 to L.Count - 1 do
      if ParseXwininfoLine(L[I], W) then
      begin
        SetLength(Wins, Length(Wins) + 1);
        Wins[Length(Wins) - 1] := W;
      end;
    Result := True;
  finally
    L.Free;
  end;
end;

function GuiListWindows(var Lines: TStringList; out Err: string): Boolean;
var
  Wins: TGuiWinArr;
  I: Integer;
begin
  if not ReadAllWindows(Wins, Err) then
    Exit(False);
  for I := 0 to High(Wins) do
    Lines.Add(FormatWinLine(Wins[I].HwndStr, Wins[I].Title, Wins[I].Cls,
      Wins[I].X, Wins[I].Y, Wins[I].W, Wins[I].H));
  Result := True;
end;

function GuiFindWindow(const Title, Cls: string; Exact: Boolean;
  var Lines: TStringList; out Err: string): Boolean;
var
  Wins: TGuiWinArr;
  I: Integer;
begin
  if not ReadAllWindows(Wins, Err) then
    Exit(False);
  for I := 0 to High(Wins) do
    if MatchStr(Title, Wins[I].Title, Exact) and
       MatchStr(Cls, Wins[I].Cls, Exact) then
      Lines.Add(FormatWinLine(Wins[I].HwndStr, Wins[I].Title, Wins[I].Cls,
        Wins[I].X, Wins[I].Y, Wins[I].W, Wins[I].H));
  Result := True;
end;

{ Value of a string xprop property: "PROP(TYPE) = ""value""". }
function XpropValue(const Out, Prop: string): string;
var
  L: TStringList;
  I, P, Q: Integer;
  Line: string;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Out;
    for I := 0 to L.Count - 1 do
    begin
      Line := L[I];
      if (Length(Line) > Length(Prop) + 1) and
         (Copy(Line, 1, Length(Prop)) = Prop) and
         (Line[Length(Prop) + 1] = '(') then
      begin
        P := Pos('"', Line);
        if P > 0 then
        begin
          Q := Pos('"', Copy(Line, P + 1, MaxInt));
          if Q > 0 then
          begin
            Result := Copy(Line, P + 1, Q - 1);
            Exit;
          end;
        end;
      end;
    end;
  finally
    L.Free;
  end;
end;

{ Window class from xprop: WM_CLASS = "instance", "class" -> class (or instance). }
function XpropClass(const Out: string): string;
var
  L: TStringList;
  I: Integer;
  Line: string;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Out;
    for I := 0 to L.Count - 1 do
    begin
      Line := L[I];
      if (Length(Line) > Length('WM_CLASS') + 1) and
         (Copy(Line, 1, Length('WM_CLASS')) = 'WM_CLASS') and
         (Line[Length('WM_CLASS') + 1] = '(') then
      begin
        Result := ExtractNthQuoted(Line, 2);
        if Result = '' then
          Result := ExtractNthQuoted(Line, 1);
        Exit;
      end;
    end;
  finally
    L.Free;
  end;
end;

{ xwininfo field: "  Field:  value" -> value. }
function XwininfoField(const Out, Field: string): string;
var
  L: TStringList;
  I, P: Integer;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Out;
    for I := 0 to L.Count - 1 do
    begin
      P := Pos(Field, L[I]);
      if P > 0 then
      begin
        Result := Trim(Copy(L[I], P + Length(Field), MaxInt));
        Exit;
      end;
    end;
  finally
    L.Free;
  end;
end;

function GuiWindowInfo(const HwndStr: string; IncludeChildren: Boolean;
  out Info: string; out Err: string): Boolean;
var
  Out, Name, Cls, Xs, Ys, Ws, Hs: string;
  X, Y, W, H, ExitCode: Integer;
  Children: TStringList;
  L: TStringList;
  I: Integer;
  Cw: TGuiWin;
begin
  Err := '';
  Info := '';
  Result := False;
  if not DisplayAvailable then
  begin
    Err := 'no X display (DISPLAY is not set)';
    Exit;
  end;
  if not ToolAvailable('xprop') then
  begin
    Err := 'the xprop utility is required (x11-utils package)';
    Exit;
  end;
  if not RunXCode('xprop -id ' + HwndStr, Out, ExitCode) then
  begin
    Err := 'failed to run xprop: ' + Out;
    Exit;
  end;
  if ExitCode <> 0 then
  begin
    Err := 'window not found: ' + HwndStr;
    Exit;
  end;
  Name := XpropValue(Out, '_NET_WM_NAME');
  if Name = '' then
    Name := XpropValue(Out, 'WM_NAME');
  Cls := XpropClass(Out);
  X := 0; Y := 0; W := 0; H := 0;
  if ToolAvailable('xwininfo') and RunX('xwininfo -id ' + HwndStr, Out) then
  begin
    Xs := XwininfoField(Out, 'Absolute upper-left X:');
    Ys := XwininfoField(Out, 'Absolute upper-left Y:');
    Ws := XwininfoField(Out, 'Width:');
    Hs := XwininfoField(Out, 'Height:');
    X := StrToIntDef(Xs, 0);
    Y := StrToIntDef(Ys, 0);
    W := StrToIntDef(Ws, 0);
    H := StrToIntDef(Hs, 0);
  end;
  Info := 'window: ' + HwndStr + '  "' + Name + '"' + sLineBreak +
    'class: ' + Cls + sLineBreak +
    Format('position: (%d, %d), size: %dx%d', [X, Y, W, H]);
  if IncludeChildren and ToolAvailable('xwininfo') then
  begin
    Children := TStringList.Create;
    try
      if RunX('xwininfo -id ' + HwndStr + ' -children', Out) then
      begin
        L := TStringList.Create;
        try
          L.Text := Out;
          for I := 0 to L.Count - 1 do
            if ParseXwininfoLine(L[I], Cw) then
              Children.Add('  ' + FormatWinLine(Cw.HwndStr, Cw.Title, Cw.Cls,
                Cw.X, Cw.Y, Cw.W, Cw.H));
        finally
          L.Free;
        end;
      end;
      if Children.Count > 0 then
        Info := Info + sLineBreak +
          Format('child controls: %d', [Children.Count]) +
          sLineBreak + Children.Text
      else
        Info := Info + sLineBreak + 'child controls: 0';
    finally
      Children.Free;
    end;
  end;
  Result := True;
end;

{$ENDIF}

{ ============================================================ tool handlers }

function ToolListWindows(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Lines: TStringList;
  Err: string;
  Limit: Integer;
  I: Integer;
  Out: string;
begin
  Limit := JInt(A, 'limit', 0);
  Lines := TStringList.Create;
  try
    if not GuiListWindows(Lines, Err) then
      Exit(ErrResult(Err));
    if Lines.Count = 0 then
      Exit(OkResult('no open windows found'));
    Out := Format('open windows: %d', [Lines.Count]);
    I := 0;
    while (I < Lines.Count) and ((Limit <= 0) or (I < Limit)) do
    begin
      Out := Out + sLineBreak + Lines[I];
      Inc(I);
    end;
    if (Limit > 0) and (Lines.Count > Limit) then
      Out := Out + sLineBreak +
        Format('... and %d more (pass limit to show all)',
          [Lines.Count - Limit]);
    Result := OkResult(Out);
  finally
    Lines.Free;
  end;
end;

function ToolFindWindow(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Title, Cls: string;
  Exact: Boolean;
  Lines: TStringList;
  Err: string;
  Out: string;
begin
  Title := JStr(A, 'title', '');
  Cls := JStr(A, 'class', '');
  Exact := JBool(A, 'exact', False);
  if (Title = '') and (Cls = '') then
    Exit(ErrResult('pass title and/or class'));
  Lines := TStringList.Create;
  try
    if not GuiFindWindow(Title, Cls, Exact, Lines, Err) then
      Exit(ErrResult(Err));
    if Lines.Count = 0 then
      Exit(OkResult(Format('window not found (title="%s", class="%s")',
        [Title, Cls])));
    if Lines.Count = 1 then
      Out := 'window: ' + Lines[0]
    else
      Out := Format('windows found: %d', [Lines.Count]) + sLineBreak + Lines.Text;
    Result := OkResult(Out);
  finally
    Lines.Free;
  end;
end;

function ToolWindowInfo(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  HwndStr: string;
  IncludeChildren: Boolean;
  Info, Err: string;
begin
  HwndStr := Trim(JStr(A, 'hwnd', ''));
  if HwndStr = '' then
    Exit(ErrResult('hwnd is not set'));
  IncludeChildren := JBool(A, 'children', True);
  if not GuiWindowInfo(HwndStr, IncludeChildren, Info, Err) then
    Exit(ErrResult(Err));
  Result := OkResult(Info);
end;

{ ============================================================ registration }

procedure RegisterGuiTools(R: TToolRegistry);
begin
  R.Add(LIST_WINDOWS_TOOL_NAME,
    'Lists the open windows: hwnd, title, class, position (x, y) and size ' +
    'WxH. On Windows -- natively (EnumWindows), on Unix -- via xwininfo/xprop. ' +
    'limit -- maximum number of lines (0 -- all).',
    SchemaObject(
      TJSONObject.Create([
        'limit', PropInt('Maximum windows in the output (0 -- all, the default is 0)')]),
      []),
    @ToolListWindows);

  R.Add(FIND_WINDOW_TOOL_NAME,
    'Finds a window by a title substring (title) and/or a class substring ' +
    '(class) and returns its hwnd. exact=true -- exact match. Pass title, class ' +
    'or both.',
    SchemaObject(
      TJSONObject.Create([
        'title', PropStr('Window title substring'),
        'class', PropStr('Window class substring'),
        'exact', PropBool('Exact match (default: no)')]),
      []),
    @ToolFindWindow);

  R.Add(WINDOW_INFO_TOOL_NAME,
    'Window details by hwnd: title, class, position, size and the list of child ' +
    'controls (hwnd, title, class, position, size). children=false -- without ' +
    'child controls.',
    SchemaObject(
      TJSONObject.Create([
        'hwnd', PropStr('Window handle (0x... or decimal)'),
        'children', PropBool('Include child controls (default: yes)')]),
      ['hwnd']),
    @ToolWindowInfo);
end;

end.
