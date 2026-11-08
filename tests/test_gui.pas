unit test_gui;
{ Тесты GUI-инструментов (этап 1 «глаза»): list_windows, find_window,
  window_info. Тесты устойчивы к окружению: в headless-режиме (нет DISPLAY
  или xwininfo) инструменты возвращают ошибку, и тогда проверки, зависящие от
  реальных окон, пропускаются. }

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
  AssertTrue('list_windows зарегистрирован', FReg.Has(LIST_WINDOWS_TOOL_NAME));
  AssertTrue('find_window зарегистрирован', FReg.Has(FIND_WINDOW_TOOL_NAME));
  AssertTrue('window_info зарегистрирован', FReg.Has(WINDOW_INFO_TOOL_NAME));
  AssertTrue('в наборе инструментов есть list_windows',
    Pos(LIST_WINDOWS_TOOL_NAME, FReg.Names) > 0);
end;

{ list_windows: либо список окон (строки начинаются с 0x), либо «не найдено»,
  либо (headless) ошибка про DISPLAY/xwininfo. Без исключений в любом случае. }
procedure TGuiTests.TestListWindows;
var
  O: TToolOutcome;
  L: TStringList;
  I: Integer;
begin
  O := FReg.Invoke(LIST_WINDOWS_TOOL_NAME, '{}', FCtx);
  if O.IsError then
  begin
    AssertTrue('ошибка list_windows про DISPLAY/xwininfo: ' + O.Text,
      (Pos('DISPLAY', O.Text) > 0) or (Pos('xwininfo', O.Text) > 0));
    Exit;
  end;
  if Pos('открытых окон не найдено', O.Text) > 0 then
    Exit;
  AssertTrue('есть счётчик окон: ' + O.Text, Pos('открытых окон: ', O.Text) > 0);
  L := TStringList.Create;
  try
    L.Text := O.Text;
    for I := 1 to L.Count - 1 do
      if L[I] <> '' then
        AssertTrue('строка окна начинается с 0x: ' + L[I],
          Copy(L[I], 1, 2) = '0x');
  finally
    L.Free;
  end;
end;

{ find_window без title и class — ошибка. }
procedure TGuiTests.TestFindWindowRequiresArg;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(FIND_WINDOW_TOOL_NAME, '{}', FCtx);
  AssertTrue('без аргументов — ошибка: ' + O.Text, O.IsError);
  AssertTrue('сообщение про title/class: ' + O.Text,
    Pos('задайте title', O.Text) > 0);
end;

{ find_window по несуществующему заголовку — «не найдено» (не ошибка). }
procedure TGuiTests.TestFindWindowNoMatch;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(FIND_WINDOW_TOOL_NAME,
    '{"title":"zzz_mirmid_ne_sushhestvuet_zzz"}', FCtx);
  if O.IsError then
  begin
    { headless — пропускаем }
    AssertTrue('ошибка find_window про DISPLAY/xwininfo: ' + O.Text,
      (Pos('DISPLAY', O.Text) > 0) or (Pos('xwininfo', O.Text) > 0));
    Exit;
  end;
  AssertTrue('окно не найдено: ' + O.Text, Pos('окно не найдено', O.Text) > 0);
end;

{ window_info без hwnd — ошибка. }
procedure TGuiTests.TestWindowInfoRequiresHwnd;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(WINDOW_INFO_TOOL_NAME, '{}', FCtx);
  AssertTrue('без hwnd — ошибка: ' + O.Text, O.IsError);
  AssertTrue('сообщение про hwnd: ' + O.Text, Pos('не задан hwnd', O.Text) > 0);
end;

{ window_info по реальному hwnd (из list_windows): заголовок, класс, позиция. }
procedure TGuiTests.TestWindowInfo;
var
  O, O2: TToolOutcome;
  L: TStringList;
  I, P: Integer;
  Hwnd: string;
begin
  O := FReg.Invoke(LIST_WINDOWS_TOOL_NAME, '{}', FCtx);
  if O.IsError then
    Exit;  { headless — пропускаем }
  if Pos('открытых окон не найдено', O.Text) > 0 then
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
    AssertFalse('window_info без ошибки: ' + O2.Text, O2.IsError);
    AssertTrue('есть строка окна: ' + O2.Text, Pos('окно: ', O2.Text) > 0);
    AssertTrue('есть класс: ' + O2.Text, Pos('класс: ', O2.Text) > 0);
    AssertTrue('есть позиция/размер: ' + O2.Text, Pos('позиция: ', O2.Text) > 0);
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TGuiTests);

end.
