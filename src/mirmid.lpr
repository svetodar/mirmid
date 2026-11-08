program mirmid;
{ mirmid — харнесс ИИ-агента на Free Pascal / Lazarus.
  Точка входа: вся логика находится в модулях каталога src/. }

{$mode objfpc}{$H+}

uses
  SysUtils, mirmid.util, mirmid.cli;

begin
  DefaultSystemCodePage := CP_UTF8;
  { Включаем обработку ANSI-последовательностей в консоли Windows до первого
    вывода: если консоль их не поддерживает, цвета и перерисовка отключатся. }
  InitConsoleAnsi;
  ExitCode := mirmid.cli.Main;
end.
