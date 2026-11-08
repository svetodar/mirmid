unit test_media;
{ Тесты медиаинструментов: read_media_file, screen_shoot, window_shoot. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.tools;

type
  TMediaTests = class(TTestCase)
  private
    FDir: string;
    FReg: TToolRegistry;
    FCtx: TToolContext;
    function PathOf(const Name: string): string;
    procedure PutFile(const Name, Data: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPngInfo;
    procedure TestGifInfo;
    procedure TestBmpInfo;
    procedure TestWavByMagic;
    procedure TestPngBase64;
    procedure TestPngColors;
    procedure TestIcoTooShort;
    procedure TestNotMedia;
    procedure TestMissingFile;
    procedure TestMirmidDirDenied;
    procedure TestShotsDeniedWithoutWrite;
    procedure TestSaveBgraImage;
    procedure TestToolsRegistered;
    procedure TestScreenCapture;
    procedure TestWindowCapture;
  end;

implementation

uses
  SysUtils, Classes, base64, fpimage, fpreadpng, mirmid.types, mirmid.toolbuiltin,
  mirmid.media, mirmid.screen, mirmid.util;

{ ------------------------------------------------------------- вспомогательное }

{ Байт числа в порядке от старшего к младшему. }
function BE(V: LongWord): string;
begin
  Result := Chr((V shr 24) and $FF) + Chr((V shr 16) and $FF) +
    Chr((V shr 8) and $FF) + Chr(V and $FF);
end;

function LE2(V: LongWord): string;
begin
  Result := Chr(V and $FF) + Chr((V shr 8) and $FF);
end;

function LE4(V: LongWord): string;
begin
  Result := LE2(V) + Chr((V shr 16) and $FF) + Chr((V shr 24) and $FF);
end;

{ Минимальный заголовок PNG с заданными размерами. }
function PngHead(W, H: LongWord): string;
begin
  Result := #$89'PNG'#$0D#$0A#$1A#$0A + BE(13) + 'IHDR' + BE(W) + BE(H) +
    #$08 + #$02 + #$00 + #$00 + #$00;
end;

function GifHead(W, H: LongWord): string;
begin
  Result := 'GIF89a' + LE2(W) + LE2(H) + #$00 + #$00 + #$00;
end;

function BmpHead(W, H: LongWord): string;
begin
  Result := 'BM' + LE4(54) + LE4(0) + LE4(54) + LE4(40) + LE4(W) + LE4(H);
end;

function WavHead: string;
begin
  Result := 'RIFF' + LE4(36) + 'WAVE' + 'fmt ' + LE4(16) + LE2(1) + LE2(1) +
    LE4(8000) + LE4(8000) + LE2(1) + LE2(8) + 'data' + LE4(0);
end;

{ ------------------------------------------------------------------ TMediaTests }

procedure TMediaTests.SetUp;
var
  Cfg: TMirmidConfig;
begin
  FDir := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-media-' + IntToStr(Random(1000000));
  ForceDirectories(FDir);
  ForceDirectories(IncludeTrailingPathDelimiter(FDir) + '.mirmid');
  FReg := TToolRegistry.Create;
  RegisterBuiltinTools(FReg);
  RegisterMediaTool(FReg);
  RegisterScreenTools(FReg);
  Cfg := DefaultConfig;
  Cfg.WorkDir := FDir;
  SetToolEnabled(Cfg, 'edit_text_file', True);
  SetToolEnabled(Cfg, 'copy_file', True);
  { Инструменты этого юнита по умолчанию выключены: включаем их ключами
    [tools], иначе обработчики откажут (Invoke проверяет ключ). }
  SetToolEnabled(Cfg, 'read_media_file', True);
  SetToolEnabled(Cfg, 'screen_shoot', True);
  SetToolEnabled(Cfg, 'window_shoot', True);
  FCtx := MakeToolContext(Cfg);
end;

procedure TMediaTests.TearDown;
var
  L: TStringList;
  Err: string;
  I: Integer;
begin
  FReg.Free;
  if ListDir(FDir, True, L, Err) then
  try
    for I := L.Count - 1 downto 0 do
      if L[I][Length(L[I])] = PathDelim then
        RemoveDir(L[I])
      else
        DeleteFile(L[I]);
  finally
    L.Free;
  end;
  RemoveDir(FDir);
end;

function TMediaTests.PathOf(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + Name;
end;

procedure TMediaTests.PutFile(const Name, Data: string);
var
  Err: string;
begin
  AssertTrue('подготовка файла ' + Name, WriteTextFile(PathOf(Name), Data, Err));
end;

procedure TMediaTests.TestPngInfo;
var
  O: TToolOutcome;
begin
  PutFile('cat.png', PngHead(640, 480));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"cat.png"}', FCtx);
  AssertFalse('чтение PNG без ошибки: ' + O.Text, O.IsError);
  AssertTrue('вид — изображение', Pos('изображение', O.Text) > 0);
  AssertTrue('формат PNG', Pos('(PNG)', O.Text) > 0);
  AssertTrue('MIME image/png', Pos('image/png', O.Text) > 0);
  AssertTrue('разрешение 640x480: ' + O.Text, Pos('640x480', O.Text) > 0);
  AssertTrue('размер файла указан', Pos('байт', O.Text) > 0);
end;

procedure TMediaTests.TestGifInfo;
var
  O: TToolOutcome;
begin
  PutFile('anim.gif', GifHead(16, 8));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"anim.gif"}', FCtx);
  AssertFalse('чтение GIF без ошибки: ' + O.Text, O.IsError);
  AssertTrue('формат GIF', Pos('(GIF)', O.Text) > 0);
  AssertTrue('разрешение 16x8: ' + O.Text, Pos('16x8', O.Text) > 0);
end;

procedure TMediaTests.TestBmpInfo;
var
  O: TToolOutcome;
begin
  PutFile('pic.bmp', BmpHead(320, 200));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"pic.bmp"}', FCtx);
  AssertFalse('чтение BMP без ошибки: ' + O.Text, O.IsError);
  AssertTrue('формат BMP', Pos('(BMP)', O.Text) > 0);
  AssertTrue('разрешение 320x200: ' + O.Text, Pos('320x200', O.Text) > 0);
end;

procedure TMediaTests.TestWavByMagic;
var
  O: TToolOutcome;
begin
  { Расширение неизвестно: вид определяется по сигнатуре RIFF/WAVE. }
  PutFile('sound.dat', WavHead);
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"sound.dat"}', FCtx);
  AssertFalse('чтение WAV без ошибки: ' + O.Text, O.IsError);
  AssertTrue('вид — звук: ' + O.Text, Pos('звук', O.Text) > 0);
  AssertTrue('формат WAV', Pos('(WAV)', O.Text) > 0);
end;

procedure TMediaTests.TestPngBase64;
var
  O: TToolOutcome;
  Data, B64: string;
  P: Integer;
begin
  Data := PngHead(3, 2);
  PutFile('pic.png', Data);
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"pic.png","base64":true}', FCtx);
  AssertFalse('чтение с base64 без ошибки: ' + O.Text, O.IsError);
  P := Pos('base64:', O.Text);
  AssertTrue('есть строка base64: ' + O.Text, P > 0);
  B64 := Trim(Copy(O.Text, P + Length('base64:'), MaxInt));
  AssertEquals('содержимое совпадает с файлом', Data, DecodeStringBase64(B64));

  { Ограничение max_bytes: кодируется только начало файла. }
  O := FReg.Invoke(MEDIA_TOOL_NAME,
    '{"path":"pic.png","base64":true,"max_bytes":8}', FCtx);
  AssertFalse('чтение с max_bytes без ошибки: ' + O.Text, O.IsError);
  AssertTrue('есть пометка об усечении', Pos('увеличьте max_bytes', O.Text) > 0);
  P := Pos('base64:', O.Text);
  B64 := Trim(Copy(O.Text, P + Length('base64:'), MaxInt));
  AssertEquals('закодированы первые 8 байт', Copy(Data, 1, 8),
    DecodeStringBase64(B64));
end;

{ Цвета буфера BGRA должны попадать в файл без искажений. }
procedure TMediaTests.TestPngColors;
var
  Buf: array[0..3] of Byte;
  Err: string;
  Ok: Boolean;
  Img: TFPMemoryImage;
  C: TFPColor;
begin
  Buf[0] := 10;   { синий }
  Buf[1] := 20;   { зелёный }
  Buf[2] := 30;   { красный }
  Buf[3] := 255;
  Ok := SaveBgraImage(PathOf('one.png'), 1, 1, @Buf, Err);
  AssertTrue('PNG сохранён: ' + Err, Ok);

  Img := TFPMemoryImage.Create(0, 0);
  try
    AssertTrue('PNG прочитан обратно', Img.LoadFromFile(PathOf('one.png')));
    C := Img.Colors[0, 0];
    AssertEquals('синий канал', 10 * 257, Integer(C.Blue));
    AssertEquals('зелёный канал', 20 * 257, Integer(C.Green));
    AssertEquals('красный канал', 30 * 257, Integer(C.Red));
  finally
    Img.Free;
  end;
end;

{ Слишком короткий файл с расширением .ico: разрешение выдумывать нельзя. }
procedure TMediaTests.TestIcoTooShort;
var
  O: TToolOutcome;
begin
  PutFile('bad.ico', #$00 + #$00 + #$01 + #$00);
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"bad.ico"}', FCtx);
  AssertFalse('чтение без ошибки: ' + O.Text, O.IsError);
  AssertTrue('формат ICO: ' + O.Text, Pos('(ICO)', O.Text) > 0);
  AssertTrue('нет выдуманного разрешения: ' + O.Text, Pos('разрешение', O.Text) = 0);
end;

procedure TMediaTests.TestNotMedia;
var
  O: TToolOutcome;
begin
  PutFile('note.txt', 'просто текст');
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"note.txt"}', FCtx);
  AssertTrue('текстовый файл — не медиа', O.IsError);
  AssertTrue('подсказка про read_text_file: ' + O.Text,
    Pos('read_text_file', O.Text) > 0);
end;

procedure TMediaTests.TestMissingFile;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"nope.png"}', FCtx);
  AssertTrue('отсутствующий файл — ошибка', O.IsError);
  AssertTrue('сообщение о ненайденном файле: ' + O.Text, Pos('не найден', O.Text) > 0);
end;

procedure TMediaTests.TestMirmidDirDenied;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка файла в служебном каталоге',
    WriteTextFile(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'pic.png',
      PngHead(2, 2), Err));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":".mirmid/pic.png"}', FCtx);
  AssertTrue('доступ в служебный каталог запрещён', O.IsError);
  O := FReg.Invoke(SCREEN_TOOL_NAME, '{"path":".mirmid/s.png"}', FCtx);
  AssertTrue('снимок в служебный каталог запрещён', O.IsError);
end;

{ Ключи screen_shoot=0 и window_shoot=0: обработчики отказывают, файлы не
  создаются (раньше снимки наследовали общую настройку записи). }
procedure TMediaTests.TestShotsDeniedWithoutWrite;
var
  O: TToolOutcome;
begin
  SetToolEnabled(FCtx.Cfg, 'screen_shoot', False);
  SetToolEnabled(FCtx.Cfg, 'window_shoot', False);
  O := FReg.Invoke(SCREEN_TOOL_NAME, '{"path":"screen.png"}', FCtx);
  AssertTrue('снимок экрана при screen_shoot=0 запрещён', O.IsError);
  AssertTrue('сообщение называет инструмент: ' + O.Text,
    Pos('tool "screen_shoot" is disabled', O.Text) > 0);
  O := FReg.Invoke(WINDOW_TOOL_NAME, '{"path":"window.png"}', FCtx);
  AssertTrue('снимок окна при window_shoot=0 запрещён', O.IsError);
  AssertFalse('файлы не созданы', FileExists(PathOf('screen.png')) or
    FileExists(PathOf('window.png')));
  SetToolEnabled(FCtx.Cfg, 'screen_shoot', True);
  SetToolEnabled(FCtx.Cfg, 'window_shoot', True);
end;

procedure TMediaTests.TestSaveBgraImage;
var
  Buf: array[0..15] of Byte;
  Err: string;
  Ok: Boolean;
  O: TToolOutcome;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  Buf[2] := 255;   { пиксель (0,0): красный (порядок BGRA) }
  Buf[6] := 255;   { пиксель (1,0): зелёный }

  Ok := SaveBgraImage(PathOf('shot.png'), 2, 2, @Buf, Err);
  AssertTrue('PNG сохранён: ' + Err, Ok);
  AssertTrue('файл PNG создан', FileExists(PathOf('shot.png')));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"shot.png"}', FCtx);
  AssertFalse('снимок читается: ' + O.Text, O.IsError);
  AssertTrue('размеры PNG 2x2: ' + O.Text, Pos('2x2', O.Text) > 0);

  AssertTrue('BMP сохранён: ' + Err, SaveBgraImage(PathOf('shot.bmp'), 2, 2, @Buf, Err));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"shot.bmp"}', FCtx);
  AssertFalse('BMP читается: ' + O.Text, O.IsError);
  AssertTrue('размеры BMP 2x2: ' + O.Text, Pos('2x2', O.Text) > 0);

  AssertFalse('формат .gif не поддерживается',
    SaveBgraImage(PathOf('bad.gif'), 2, 2, @Buf, Err));
  AssertTrue('сообщение о поддерживаемых форматах: ' + Err, Pos('.png', Err) > 0);
end;

procedure TMediaTests.TestToolsRegistered;
begin
  AssertTrue('read_media_file зарегистрирован', FReg.Has(MEDIA_TOOL_NAME));
  AssertTrue('screen_shoot зарегистрирован', FReg.Has(SCREEN_TOOL_NAME));
  AssertTrue('window_shoot зарегистрирован', FReg.Has(WINDOW_TOOL_NAME));
  AssertTrue('в наборе инструментов есть read_media_file',
    Pos(MEDIA_TOOL_NAME, FReg.Names) > 0);
end;

{ Снимок реального экрана: если рабочий стол недоступен (служба, Unix),
  тест пропускается. Проверяются размеры и запись буфера в PNG. }
procedure TMediaTests.TestScreenCapture;
var
  Buf: PByte;
  W, H: Integer;
  Err: string;
begin
  if not CaptureToBuffer(False, 0, Buf, W, H, Err) then
    Exit;
  try
    AssertTrue('размеры снимка положительны', (W > 0) and (H > 0));
    AssertTrue('буфер снимка выделен', Buf <> nil);
    AssertTrue('снимок записывается в PNG: ' + Err,
      SaveBgraImage(PathOf('screen.png'), W, H, Buf, Err));
    AssertTrue('файл снимка создан', FileExists(PathOf('screen.png')));
  finally
    FreeMem(Buf);
  end;
end;

{ Снимок активного окна: если окно недоступно (Unix, нет рабочего стола,
  окно свёрнуто), тест пропускается. }
procedure TMediaTests.TestWindowCapture;
var
  Buf: PByte;
  W, H: Integer;
  Err: string;
begin
  if not CaptureToBuffer(True, 0, Buf, W, H, Err) then
    Exit;
  try
    AssertTrue('размеры снимка окна положительны', (W > 0) and (H > 0));
    AssertTrue('буфер снимка окна выделен', Buf <> nil);
  finally
    FreeMem(Buf);
  end;
end;

initialization
  RegisterTest(TMediaTests);

end.
