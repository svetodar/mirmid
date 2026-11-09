unit test_gui;
{ Tests for the GUI tools (stage 1 "eyes"): list_windows, find_window,
  window_info. The tests are environment-tolerant: in headless mode (no DISPLAY
  or no xwininfo) the tools return an error, and the checks that depend on real
  windows are skipped then. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.tools;

type
  TGuiTests = class(TTestCase)
  private
    FReg: TToolRegistry;
    FCtx: TToolContext;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestToolsRegistered;
    procedure TestListWindows;
    procedure TestFindWindowRequiresArg;
    procedure TestFindWindowNoMatch;
    procedure TestWindowInfoRequiresHwnd;
    procedure TestWindowInfo;
  end;

implementation

uses
  SysUtils, Classes, mirmid.types, mirmid.toolbuiltin, mirmid.gui, mirmid.util;

procedure TGuiTests.SetUp;
var
  Cfg: TMirmidConfig;
begin
  FReg := TToolRegistry.Create;
  RegisterBuiltinTools(FReg);
  RegisterGuiTools(FReg);
  Cfg := DefaultConfig;
  Cfg.WorkDir := TempDir;
  FCtx := MakeToolContext(Cfg);
end;

procedure TGuiTests.TearDown;
begin
  FReg.Free;
end;

procedure TGuiTests.TestToolsRegistered;
begin
  AssertTrue('list_windows is registered', FReg.Has(LIST_WINDOWS_TOOL_NAME));
  AssertTrue('find_window is registered', FReg.Has(FIND_WINDOW_TOOL_NAME));
  AssertTrue('window_info is registered', FReg.Has(WINDOW_INFO_TOOL_NAME));
  AssertTrue('the tool set contains list_windows',
    Pos(LIST_WINDOWS_TOOL_NAME, FReg.Names) > 0);
end;

{ list_windows: either a list of windows (lines start with 0x), or "not found",
  or (headless) an error about DISPLAY/xwininfo. No exceptions in any case. }
procedure TGuiTests.TestListWindows;
var
  O: TToolOutcome;
  L: TStringList;
  I: Integer;
begin
  O := FReg.Invoke(LIST_WINDOWS_TOOL_NAME, '{}', FCtx);
  if O.IsError then
  begin
    AssertTrue('list_windows error about DISPLAY/xwininfo: ' + O.Text,
      (Pos('DISPLAY', O.Text) > 0) or (Pos('xwininfo', O.Text) > 0));
    Exit;
  end;
  if Pos('no open windows found', O.Text) > 0 then
    Exit;
  AssertTrue('there is a window counter: ' + O.Text, Pos('open windows: ', O.Text) > 0);
  L := TStringList.Create;
  try
    L.Text := O.Text;
    for I := 1 to L.Count - 1 do
      if L[I] <> '' then
        AssertTrue('a window line starts with 0x: ' + L[I],
          Copy(L[I], 1, 2) = '0x');
  finally
    L.Free;
  end;
end;

{ find_window without title and class -- an error. }
procedure TGuiTests.TestFindWindowRequiresArg;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(FIND_WINDOW_TOOL_NAME, '{}', FCtx);
  AssertTrue('no arguments -- an error: ' + O.Text, O.IsError);
  AssertTrue('message about title/class: ' + O.Text,
    Pos('pass title', O.Text) > 0);
end;

{ find_window with a non-existent title -- "not found" (not an error). }
procedure TGuiTests.TestFindWindowNoMatch;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(FIND_WINDOW_TOOL_NAME,
    '{"title":"zzz_mirmid_no_such_window_zzz"}', FCtx);
  if O.IsError then
  begin
    { headless -- skip }
    AssertTrue('find_window error about DISPLAY/xwininfo: ' + O.Text,
      (Pos('DISPLAY', O.Text) > 0) or (Pos('xwininfo', O.Text) > 0));
    Exit;
  end;
  AssertTrue('window not found: ' + O.Text, Pos('window not found', O.Text) > 0);
end;

{ window_info without hwnd -- an error. }
procedure TGuiTests.TestWindowInfoRequiresHwnd;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(WINDOW_INFO_TOOL_NAME, '{}', FCtx);
  AssertTrue('no hwnd -- an error: ' + O.Text, O.IsError);
  AssertTrue('message about hwnd: ' + O.Text, Pos('hwnd is not set', O.Text) > 0);
end;

{ window_info for a real hwnd (taken from list_windows): title, class, position. }
procedure TGuiTests.TestWindowInfo;
var
  O, O2: TToolOutcome;
  L: TStringList;
  I, P: Integer;
  Hwnd: string;
begin
  O := FReg.Invoke(LIST_WINDOWS_TOOL_NAME, '{}', FCtx);
  if O.IsError then
    Exit;  { headless -- skip }
  if Pos('no open windows found', O.Text) > 0 then
    Exit;
  L := TStringList.Create;
  try
    L.Text := O.Text;
    Hwnd := '';
    for I := 1 to L.Count - 1 do
    begin
      if Copy(L[I], 1, 2) = '0x' then
      begin
        P := Pos(' ', L[I]);
        if P > 0 then
        begin
          Hwnd := Copy(L[I], 1, P - 1);
          Break;
        end;
      end;
    end;
    if Hwnd = '' then
      Exit;
    O2 := FReg.Invoke(WINDOW_INFO_TOOL_NAME, '{"hwnd":"' + Hwnd + '"}', FCtx);
    AssertFalse('window_info without an error: ' + O2.Text, O2.IsError);
    AssertTrue('there is a window line: ' + O2.Text, Pos('window: ', O2.Text) > 0);
    AssertTrue('there is a class: ' + O2.Text, Pos('class: ', O2.Text) > 0);
    AssertTrue('there is a position/size: ' + O2.Text, Pos('position: ', O2.Text) > 0);
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TGuiTests);

end.
