unit mirmid.screen;
{ Инструменты screen_shoot и window_shoot: сохраняют снимок всего экрана
  (всех мониторов) или активного окна в файл PNG или BMP.
  На Windows снимок делается средствами GDI (без внешних программ),
  на Unix — доступными утилитами (grim, scrot, ImageMagick import,
  gnome-screenshot, spectacle). Инструменты включаются ключами screen_shoot и
  window_shoot в секции [tools] (по умолчанию выключены). }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools;

const
  SCREEN_TOOL_NAME = 'screen_shoot';
  WINDOW_TOOL_NAME = 'window_shoot';
  { Таймаут внешних утилит снимка экрана на Unix, сек. }
  SCREEN_SHOT_TIMEOUT = 30;

{ Регистрирует инструменты screen_shoot и window_shoot в реестре. }
procedure RegisterScreenTools(R: TToolRegistry);

{ Записывает изображение из буфера BGRA (4 байта на пиксель, порядок строк —
  сверху вниз) в файл. Формат — по расширению: .png (24 бита, RGBA→RGB)
  или .bmp. }
function SaveBgraImage(const Path: string; Width, Height: Integer;
  Bgra: PByte; out Err: string): Boolean;

{ Снимок экрана (Window = False) или окна (Handle = 0 — активное окно) в буфер
  BGRA; буфер выделяется через GetMem — освобождает FreeMem. На платформах без
  GDI-захвата (Unix) возвращает False: там снимок делают внешние утилиты, сразу
  записывая его в файл. }
function CaptureToBuffer(Window: Boolean; Handle: QWord; out Buf: PByte;
  out Width, Height: Integer; out Err: string): Boolean;

implementation

uses
  SysUtils, Classes, fpjson, fpimage, fpwritepng, fpwritebmp,
  mirmid.media, mirmid.types, mirmid.util, mirmid.json
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{ -------------------------------------------------- сохранение изображения }

function SaveBgraImage(const Path: string; Width, Height: Integer;
  Bgra: PByte; out Err: string): Boolean;
var
  Img: TFPMemoryImage;
  Png: TFPWriterPNG;
  Bmp: TFPWriterBMP;
  P: PByte;
  X, Y: Integer;
  C: TFPColor;
  Ext: string;
begin
  Err := '';
  Result := False;
  if (Width <= 0) or (Height <= 0) or (Bgra = nil) then
  begin
    Err := 'пустое изображение';
    Exit;
  end;
  Ext := LowerCase(ExtractFileExt(Path));
  if Ext = '' then
    Ext := '.png';
  if (Ext <> '.png') and (Ext <> '.bmp') then
  begin
    Err := 'поддерживаются файлы .png и .bmp, а не ' + Ext;
    Exit;
  end;
  if not EnsureParentDir(Path) then
  begin
    Err := 'не удалось создать каталог для ' + Path;
    Exit;
  end;

  Img := TFPMemoryImage.Create(Width, Height);
  Png := nil;
  Bmp := nil;
  try
    try
      P := Bgra;
      for Y := 0 to Height - 1 do
        for X := 0 to Width - 1 do
        begin
          { FPC-изображения хранят цвет 16 битами на канал. }
          C.Blue  := P^ * 257; Inc(P);
          C.Green := P^ * 257; Inc(P);
          C.Red   := P^ * 257; Inc(P);
          C.Alpha := $FFFF;    Inc(P);
          Img.Colors[X, Y] := C;
        end;
      if Ext = '.png' then
      begin
        Png := TFPWriterPNG.Create;
        Png.UseAlpha := False;    { прозрачность снимку не нужна }
        Png.WordSized := False;   { 8 бит на канал }
        Img.SaveToFile(Path, Png);
      end
      else
      begin
        Bmp := TFPWriterBMP.Create;
        Img.SaveToFile(Path, Bmp);
      end;
      Result := True;
    except
      on E: Exception do
      begin
        Err := Path + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    Png.Free;
    Bmp.Free;
    Img.Free;
  end;
end;

function FileSizeOf(const Path: string): Int64;
var
  F: TFileStream;
begin
  Result := 0;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := F.Size;
    finally
      F.Free;
    end;
  except
    Result := 0;
  end;
end;

{ Размеры готового снимка — из заголовка сохранённого файла (формат по
  расширению). False — если формат не PNG/BMP или заголовок не прочитать. }
function ShotDims(const Path: string; out W, H: Integer): Boolean;
var
  Head, Fmt: string;
  F: TFileStream;
begin
  Result := False;
  W := 0;
  H := 0;
  Fmt := LowerCase(ExtractFileExt(Path));
  if Fmt = '.png' then
    Fmt := 'PNG'
  else if Fmt = '.bmp' then
    Fmt := 'BMP'
  else
    Exit;
  Head := '';
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size > MEDIA_HEAD_BYTES then
        SetLength(Head, MEDIA_HEAD_BYTES)
      else
        SetLength(Head, F.Size);
      if Length(Head) > 0 then
        F.ReadBuffer(Head[1], Length(Head));
    finally
      F.Free;
    end;
  except
    Exit;
  end;
  Result := ImageSizeFromHead(Head, Fmt, W, H);
end;

{ --------------------------------------------------- снимок: Windows (GDI) }

{$IFDEF WINDOWS}

type
  TSetProcessDPIAware = function: BOOL; stdcall;

var
  GDpiAware: Boolean = False;

type
  TDwmGetWindowAttribute = function(Wnd: HWND; Attribute: DWORD;
    Value: Pointer; Size: DWORD): HRESULT; stdcall;

const
  DWMWA_EXTENDED_FRAME_BOUNDS = 9;

{ Границы окна без тени и невидимых рамок изменения размера (DWM).
  False — вызывающий использует GetWindowRect. }
function DwmFrameRect(Wnd: HWND; out R: TRect): Boolean;
var
  H: HMODULE;
  F: TDwmGetWindowAttribute;
  B: array[0..3] of LongInt;
begin
  Result := False;
  H := GetModuleHandle('dwmapi.dll');
  if H = 0 then
    Exit;
  Pointer(F) := GetProcAddress(H, 'DwmGetWindowAttribute');
  if not Assigned(F) then
    Exit;
  try
    if F(Wnd, DWMWA_EXTENDED_FRAME_BOUNDS, @B, SizeOf(B)) <> 0 then
      Exit;
  except
    Exit;
  end;
  R.Left := B[0];
  R.Top := B[1];
  R.Right := B[2];
  R.Bottom := B[3];
  Result := (R.Right > R.Left) and (R.Bottom > R.Top);
end;

{ Дескриптор окна: десятичное число или 0x... в шестнадцатеричном виде. }
function ParseHandle(const S: string): QWord;
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

{ Процесс объявляется DPI-осведомлённым, иначе система отдаёт снимок в
  масштабе экрана. Функция появилась в Vista — вызываем динамически. }
procedure EnsureDpiAware;
var
  H: HMODULE;
  F: TSetProcessDPIAware;
begin
  if GDpiAware then
    Exit;
  GDpiAware := True;
  H := GetModuleHandle('user32.dll');
  if H = 0 then
    Exit;
  Pointer(F) := GetProcAddress(H, 'SetProcessDPIAware');
  if Assigned(F) then
    try
      F();
    except
      { нет функции или вызов запрещён — работаем как есть }
    end;
end;

{ Копирует прямоугольник экрана в буфер BGRA. }
function CaptureRect(X, Y, Width, Height: Integer; out Buf: PByte): Boolean;
var
  SrcDC, MemDC: HDC;
  Bmp: HBITMAP;
  Old: HGDIOBJ;
  BI: TBitmapInfo;
begin
  Result := False;
  Buf := nil;
  if (Width <= 0) or (Height <= 0) then
    Exit;
  SrcDC := GetDC(0);
  if SrcDC = 0 then
    Exit;
  MemDC := 0;
  Bmp := 0;
  Old := 0;
  try
    MemDC := CreateCompatibleDC(SrcDC);
    if MemDC = 0 then
      Exit;
    Bmp := CreateCompatibleBitmap(SrcDC, Width, Height);
    if Bmp = 0 then
      Exit;
    Old := SelectObject(MemDC, Bmp);
    if not BitBlt(MemDC, 0, 0, Width, Height, SrcDC, X, Y, SRCCOPY) then
      Exit;
    { GetDIBits нельзя вызывать для битмапа, ещё выбранного в DC. }
    SelectObject(MemDC, Old);
    Old := 0;
    FillChar(BI, SizeOf(BI), 0);
    BI.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
    BI.bmiHeader.biWidth := Width;
    BI.bmiHeader.biHeight := -Height;      { строки сверху вниз }
    BI.bmiHeader.biPlanes := 1;
    BI.bmiHeader.biBitCount := 32;
    BI.bmiHeader.biCompression := 0;       { BI_RGB }
    GetMem(Buf, Width * Height * 4);
    if GetDIBits(MemDC, Bmp, 0, Height, Buf, BI, DIB_RGB_COLORS) = 0 then
    begin
      FreeMem(Buf);
      Buf := nil;
      Exit;
    end;
    Result := True;
  finally
    if Old <> 0 then
      SelectObject(MemDC, Old);
    if Bmp <> 0 then
      DeleteObject(Bmp);
    if MemDC <> 0 then
      DeleteDC(MemDC);
    ReleaseDC(0, SrcDC);
  end;
end;

{ Снимок экрана или окна в буфер BGRA: реализация через GDI. }
function CaptureToBuffer(Window: Boolean; Handle: QWord; out Buf: PByte;
  out Width, Height: Integer; out Err: string): Boolean;
var
  R: TRect;
  Wnd: HWND;
  X, Y, VX, VY, VW, VH: Integer;
begin
  Result := False;
  Buf := nil;
  Width := 0;
  Height := 0;
  Err := '';
  EnsureDpiAware;

  if Window then
  begin
    Wnd := HWND(Handle);
    if Wnd = 0 then
      Wnd := GetForegroundWindow;
    if Wnd = 0 then
    begin
      Err := 'не удалось определить активное окно';
      Exit;
    end;
    if IsIconic(Wnd) then
    begin
      Err := 'окно свёрнуто — снимок невозможен';
      Exit;
    end;
    if not DwmFrameRect(Wnd, R) then
    if not GetWindowRect(Wnd, R) then
    begin
      Err := 'не удалось определить размеры окна';
      Exit;
    end;
    X := R.Left;
    Y := R.Top;
    Width := R.Right - R.Left;
    Height := R.Bottom - R.Top;
  end
  else
  begin
    X := GetSystemMetrics(SM_XVIRTUALSCREEN);
    Y := GetSystemMetrics(SM_YVIRTUALSCREEN);
    Width := GetSystemMetrics(SM_CXVIRTUALSCREEN);
    Height := GetSystemMetrics(SM_CYVIRTUALSCREEN);
  end;

  if (Width <= 0) or (Height <= 0) then
  begin
    Err := 'пустая область снимка';
    Exit;
  end;

  { Обрезаем область по виртуальному экрану. }
  VX := GetSystemMetrics(SM_XVIRTUALSCREEN);
  VY := GetSystemMetrics(SM_YVIRTUALSCREEN);
  VW := GetSystemMetrics(SM_CXVIRTUALSCREEN);
  VH := GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if X < VX then
  begin
    Dec(Width, VX - X);
    X := VX;
  end;
  if Y < VY then
  begin
    Dec(Height, VY - Y);
    Y := VY;
  end;
  if X + Width > VX + VW then
    Width := VX + VW - X;
  if Y + Height > VY + VH then
    Height := VY + VH - Y;
  if (Width <= 0) or (Height <= 0) then
  begin
    Err := 'окно вне экрана — снимок невозможен';
    Exit;
  end;

  if not CaptureRect(X, Y, Width, Height, Buf) then
  begin
    Err := 'не удалось скопировать изображение экрана';
    Exit;
  end;
  Result := True;
end;

{$ELSE}

{ --------------------------------------------------- снимок: Unix (утилиты) }

type
  TShotCmd = record
    Tool: string;
    Args: string;
  end;

const
  { Команды снимка всего экрана, проверяются по порядку. }
  ScreenCmds: array[0..4] of TShotCmd = (
    (Tool: 'grim';             Args: ''),
    (Tool: 'scrot';            Args: '-o'),
    (Tool: 'import';           Args: '-window root'),
    (Tool: 'gnome-screenshot'; Args: '-f'),
    (Tool: 'spectacle';        Args: '-b -n -o'));

  { Команды снимка активного окна. }
  WindowCmds: array[0..2] of TShotCmd = (
    (Tool: 'scrot';            Args: '-u -o'),
    (Tool: 'gnome-screenshot'; Args: '-w -f'),
    (Tool: 'import';           Args: '-window "$(xdotool getactivewindow)"'));

{ Заключает строку в апострофы для оболочки (bash). }
function ShellQuote(const S: string): string;
const
  Q = #39;   { апостроф }
begin
  Result := Q + StringReplace(S, Q, Q + '\' + Q + Q, [rfReplaceAll]) + Q;
end;

function ToolAvailable(const Tool: string): Boolean;
var
  OutText, Err: string;
  EC: Integer;
begin
  Result := RunProcess('command -v ' + ShellQuote(Tool) + ' >/dev/null 2>&1',
    '', 5, OutText, EC, Err) and (EC = 0);
end;

function TryShots(const Cmds: array of TShotCmd; const Path: string;
  out Err: string): Boolean;
var
  I: Integer;
  OutText, E: string;
  EC: Integer;
begin
  Result := False;
  Err := '';
  for I := Low(Cmds) to High(Cmds) do
  begin
    if not ToolAvailable(Cmds[I].Tool) then
    begin
      Err := 'утилита «' + Cmds[I].Tool + '» не найдена';
      Continue;
    end;
    if FileExists(Path) then
      DeleteFile(Path);
    if RunProcess(Cmds[I].Tool + ' ' + Cmds[I].Args + ' ' + ShellQuote(Path),
      '', SCREEN_SHOT_TIMEOUT, OutText, EC, E) and (EC = 0) and FileExists(Path) then
    begin
      Result := True;
      Exit;
    end;
    Err := 'не удалось выполнить «' + Cmds[I].Tool + '»: ' +
      Trim(OutText + ' ' + E);
  end;
end;

function TakeShot(const Path: string; Window: Boolean; out Err: string): Boolean;
begin
  if Window then
    Result := TryShots(WindowCmds, Path, Err)
  else
    Result := TryShots(ScreenCmds, Path, Err);
end;

{ На Unix снимок сразу пишут внешние утилиты, буфер не используется. }
function CaptureToBuffer(Window: Boolean; Handle: QWord; out Buf: PByte;
  out Width, Height: Integer; out Err: string): Boolean;
begin
  Result := False;
  Buf := nil;
  Width := 0;
  Height := 0;
  Err := 'захват экрана в буфер не поддерживается на этой платформе';
end;

{$ENDIF}

{ --------------------------------------------------------------- инструмент }

function DoShoot(const A: TJSONObject; const Ctx: TToolContext;
  Window: Boolean; const ToolName: string): TToolOutcome;
var
  P, Err, Fmt, Info: string;
  W, H: Integer;
  Ext: string;
  Buf: PByte;
begin
  { Гейт в обработчике: у screen_shoot и window_shoot свои ключи [tools]. }
  if not ToolEnabled(Ctx.Cfg, ToolName) then
    Exit(ToolDisabled(ToolName));
  P := Trim(JStr(A, 'path', ''));
  if P = '' then
    Exit(ErrResult('не задан path'));
  P := ExpPath(P, Ctx.WorkDir);
  if IsMirmidPath(Ctx.WorkDir, P) then
    Exit(ErrResult('доступ запрещён: ' + P +
      ' находится в служебном каталоге .mirmid'));
  Ext := LowerCase(ExtractFileExt(P));
  if Ext = '' then
  begin
    Ext := '.png';
    P := P + Ext;
  end;
  if (Ext <> '.png') and (Ext <> '.bmp') then
    Exit(ErrResult('поддерживаются файлы .png и .bmp, а не ' + Ext));

  W := 0;
  H := 0;
  {$IFDEF WINDOWS}
  if not CaptureToBuffer(Window, ParseHandle(JStr(A, 'hwnd', '')),
    Buf, W, H, Err) then
    Exit(ErrResult(Err));
  try
    if not SaveBgraImage(P, W, H, Buf, Err) then
      Exit(ErrResult(Err));
  finally
    FreeMem(Buf);
  end;
  {$ELSE}
  if not EnsureParentDir(P) then
    Exit(ErrResult('не удалось создать каталог для ' + P));
  if not TakeShot(P, Window, Err) then
    Exit(ErrResult('не удалось сделать снимок: ' + Err +
      ' (нужна утилита grim, scrot, ImageMagick import, gnome-screenshot или spectacle)'));
  if not ShotDims(P, W, H) then
  begin
    W := 0;
    H := 0;
  end;
  {$ENDIF}

  Fmt := UpperCase(Copy(Ext, 2, MaxInt));
  Info := Format('%s, %d байт', [Fmt, FileSizeOf(P)]);
  if (W > 0) and (H > 0) then
    Info := Format('%dx%d, ', [W, H]) + Info;
  if Window then
    Result := OkResult('снимок активного окна сохранён: ' + P + ' (' + Info + ')')
  else
    Result := OkResult('снимок экрана сохранён: ' + P + ' (' + Info + ')');
end;

function ToolScreenShoot(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
begin
  Result := DoShoot(A, Ctx, False, SCREEN_TOOL_NAME);
end;

function ToolWindowShoot(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
begin
  Result := DoShoot(A, Ctx, True, WINDOW_TOOL_NAME);
end;

procedure RegisterScreenTools(R: TToolRegistry);
begin
  R.Add(SCREEN_TOOL_NAME,
    'Сохраняет снимок всего экрана (всех мониторов) в файл .png или .bmp. ' +
    'Нужен включённый инструмент (ключ screen_shoot в секции [tools]).',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Путь к файлу снимка (.png или .bmp; без расширения — .png)')]),
      ['path']),
    @ToolScreenShoot);

  R.Add(WINDOW_TOOL_NAME,
    'Сохраняет снимок активного окна в файл .png или .bmp. ' +
    'Нужен включённый инструмент (ключ window_shoot в секции [tools]).',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Путь к файлу снимка (.png или .bmp; без расширения — .png)'),
        'hwnd', PropStr('Дескриптор окна (по умолчанию — активное окно)')]),
      ['path']),
    @ToolWindowShoot);
end;

end.
