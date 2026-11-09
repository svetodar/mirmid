unit test_media;
{ Tests for the media tools: read_media_file, screen_shoot, window_shoot. }

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

{ ---------------------------------------------------------------- helpers }

{ The bytes of a number, most significant first. }
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

{ A minimal PNG header with the given dimensions. }
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
  { The tools of this unit are disabled by default: switch them on with the
    [tools] keys, otherwise the handlers refuse (Invoke checks the key). }
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
  AssertTrue('preparing the file ' + Name, WriteTextFile(PathOf(Name), Data, Err));
end;

procedure TMediaTests.TestPngInfo;
var
  O: TToolOutcome;
begin
  PutFile('cat.png', PngHead(640, 480));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"cat.png"}', FCtx);
  AssertFalse('reading a PNG without an error: ' + O.Text, O.IsError);
  AssertTrue('the kind is an image', Pos('kind: image', O.Text) > 0);
  AssertTrue('the format is PNG', Pos('(PNG)', O.Text) > 0);
  AssertTrue('MIME image/png', Pos('image/png', O.Text) > 0);
  AssertTrue('resolution 640x480: ' + O.Text, Pos('640x480', O.Text) > 0);
  AssertTrue('the file size is reported', Pos('bytes', O.Text) > 0);
end;

procedure TMediaTests.TestGifInfo;
var
  O: TToolOutcome;
begin
  PutFile('anim.gif', GifHead(16, 8));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"anim.gif"}', FCtx);
  AssertFalse('reading a GIF without an error: ' + O.Text, O.IsError);
  AssertTrue('the format is GIF', Pos('(GIF)', O.Text) > 0);
  AssertTrue('resolution 16x8: ' + O.Text, Pos('16x8', O.Text) > 0);
end;

procedure TMediaTests.TestBmpInfo;
var
  O: TToolOutcome;
begin
  PutFile('pic.bmp', BmpHead(320, 200));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"pic.bmp"}', FCtx);
  AssertFalse('reading a BMP without an error: ' + O.Text, O.IsError);
  AssertTrue('the format is BMP', Pos('(BMP)', O.Text) > 0);
  AssertTrue('resolution 320x200: ' + O.Text, Pos('320x200', O.Text) > 0);
end;

procedure TMediaTests.TestWavByMagic;
var
  O: TToolOutcome;
begin
  { The extension is unknown: the kind is detected by the RIFF/WAVE signature. }
  PutFile('sound.dat', WavHead);
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"sound.dat"}', FCtx);
  AssertFalse('reading a WAV without an error: ' + O.Text, O.IsError);
  AssertTrue('the kind is audio: ' + O.Text, Pos('kind: audio', O.Text) > 0);
  AssertTrue('the format is WAV', Pos('(WAV)', O.Text) > 0);
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
  AssertFalse('reading with base64 without an error: ' + O.Text, O.IsError);
  P := Pos('base64:', O.Text);
  AssertTrue('there is a base64 line: ' + O.Text, P > 0);
  B64 := Trim(Copy(O.Text, P + Length('base64:'), MaxInt));
  AssertEquals('the content matches the file', Data, DecodeStringBase64(B64));

  { The max_bytes limit: only the beginning of the file is encoded. }
  O := FReg.Invoke(MEDIA_TOOL_NAME,
    '{"path":"pic.png","base64":true,"max_bytes":8}', FCtx);
  AssertFalse('reading with max_bytes without an error: ' + O.Text, O.IsError);
  AssertTrue('there is a truncation note', Pos('increase max_bytes', O.Text) > 0);
  P := Pos('base64:', O.Text);
  B64 := Trim(Copy(O.Text, P + Length('base64:'), MaxInt));
  AssertEquals('the first 8 bytes are encoded', Copy(Data, 1, 8),
    DecodeStringBase64(B64));
end;

{ The colours of the BGRA buffer must reach the file undistorted. }
procedure TMediaTests.TestPngColors;
var
  Buf: array[0..3] of Byte;
  Err: string;
  Ok: Boolean;
  Img: TFPMemoryImage;
  C: TFPColor;
begin
  Buf[0] := 10;   { blue }
  Buf[1] := 20;   { green }
  Buf[2] := 30;   { red }
  Buf[3] := 255;
  Ok := SaveBgraImage(PathOf('one.png'), 1, 1, @Buf, Err);
  AssertTrue('the PNG is saved: ' + Err, Ok);

  Img := TFPMemoryImage.Create(0, 0);
  try
    AssertTrue('the PNG is read back', Img.LoadFromFile(PathOf('one.png')));
    C := Img.Colors[0, 0];
    AssertEquals('blue channel', 10 * 257, Integer(C.Blue));
    AssertEquals('green channel', 20 * 257, Integer(C.Green));
    AssertEquals('red channel', 30 * 257, Integer(C.Red));
  finally
    Img.Free;
  end;
end;

{ A too short file with the .ico extension: the resolution must not be made
  up. }
procedure TMediaTests.TestIcoTooShort;
var
  O: TToolOutcome;
begin
  PutFile('bad.ico', #$00 + #$00 + #$01 + #$00);
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"bad.ico"}', FCtx);
  AssertFalse('reading without an error: ' + O.Text, O.IsError);
  AssertTrue('the format is ICO: ' + O.Text, Pos('(ICO)', O.Text) > 0);
  AssertTrue('there is no invented resolution: ' + O.Text,
    Pos('resolution', O.Text) = 0);
end;

procedure TMediaTests.TestNotMedia;
var
  O: TToolOutcome;
begin
  PutFile('note.txt', 'just text');
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"note.txt"}', FCtx);
  AssertTrue('a text file is not media', O.IsError);
  AssertTrue('a hint about read_text_file: ' + O.Text,
    Pos('read_text_file', O.Text) > 0);
end;

procedure TMediaTests.TestMissingFile;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"nope.png"}', FCtx);
  AssertTrue('a missing file is an error', O.IsError);
  AssertTrue('message about the missing file: ' + O.Text,
    Pos('not found', O.Text) > 0);
end;

procedure TMediaTests.TestMirmidDirDenied;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing the file in the service directory',
    WriteTextFile(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'pic.png',
      PngHead(2, 2), Err));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":".mirmid/pic.png"}', FCtx);
  AssertTrue('access to the service directory is denied', O.IsError);
  O := FReg.Invoke(SCREEN_TOOL_NAME, '{"path":".mirmid/s.png"}', FCtx);
  AssertTrue('a screenshot into the service directory is denied', O.IsError);
end;

{ The keys screen_shoot=0 and window_shoot=0: the handlers refuse, no files are
  created (earlier the screenshots inherited the common write setting). }
procedure TMediaTests.TestShotsDeniedWithoutWrite;
var
  O: TToolOutcome;
begin
  SetToolEnabled(FCtx.Cfg, 'screen_shoot', False);
  SetToolEnabled(FCtx.Cfg, 'window_shoot', False);
  O := FReg.Invoke(SCREEN_TOOL_NAME, '{"path":"screen.png"}', FCtx);
  AssertTrue('a screenshot is denied with screen_shoot=0', O.IsError);
  AssertTrue('the message names the tool: ' + O.Text,
    Pos('tool "screen_shoot" is disabled', O.Text) > 0);
  O := FReg.Invoke(WINDOW_TOOL_NAME, '{"path":"window.png"}', FCtx);
  AssertTrue('a window capture is denied with window_shoot=0', O.IsError);
  AssertFalse('no files are created', FileExists(PathOf('screen.png')) or
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
  Buf[2] := 255;   { pixel (0,0): red (BGRA order) }
  Buf[6] := 255;   { pixel (1,0): green }

  Ok := SaveBgraImage(PathOf('shot.png'), 2, 2, @Buf, Err);
  AssertTrue('the PNG is saved: ' + Err, Ok);
  AssertTrue('the PNG file is created', FileExists(PathOf('shot.png')));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"shot.png"}', FCtx);
  AssertFalse('the capture is readable: ' + O.Text, O.IsError);
  AssertTrue('the PNG dimensions are 2x2: ' + O.Text, Pos('2x2', O.Text) > 0);

  AssertTrue('the BMP is saved: ' + Err, SaveBgraImage(PathOf('shot.bmp'), 2, 2, @Buf, Err));
  O := FReg.Invoke(MEDIA_TOOL_NAME, '{"path":"shot.bmp"}', FCtx);
  AssertFalse('the BMP is readable: ' + O.Text, O.IsError);
  AssertTrue('the BMP dimensions are 2x2: ' + O.Text, Pos('2x2', O.Text) > 0);

  AssertFalse('the .gif format is not supported',
    SaveBgraImage(PathOf('bad.gif'), 2, 2, @Buf, Err));
  AssertTrue('message about the supported formats: ' + Err, Pos('.png', Err) > 0);
end;

procedure TMediaTests.TestToolsRegistered;
begin
  AssertTrue('read_media_file is registered', FReg.Has(MEDIA_TOOL_NAME));
  AssertTrue('screen_shoot is registered', FReg.Has(SCREEN_TOOL_NAME));
  AssertTrue('window_shoot is registered', FReg.Has(WINDOW_TOOL_NAME));
  AssertTrue('the tool set contains read_media_file',
    Pos(MEDIA_TOOL_NAME, FReg.Names) > 0);
end;

{ A capture of the real screen: if the desktop is unavailable (a service, Unix),
  the test is skipped. The dimensions and the writing of the buffer to a PNG are
  verified. }
procedure TMediaTests.TestScreenCapture;
var
  Buf: PByte;
  W, H: Integer;
  Err: string;
begin
  if not CaptureToBuffer(False, 0, Buf, W, H, Err) then
    Exit;
  try
    AssertTrue('the capture dimensions are positive', (W > 0) and (H > 0));
    AssertTrue('the capture buffer is allocated', Buf <> nil);
    AssertTrue('the capture is written to a PNG: ' + Err,
      SaveBgraImage(PathOf('screen.png'), W, H, Buf, Err));
    AssertTrue('the capture file is created', FileExists(PathOf('screen.png')));
  finally
    FreeMem(Buf);
  end;
end;

{ A capture of the active window: if the window is unavailable (Unix, no
  desktop, the window is minimised), the test is skipped. }
procedure TMediaTests.TestWindowCapture;
var
  Buf: PByte;
  W, H: Integer;
  Err: string;
begin
  if not CaptureToBuffer(True, 0, Buf, W, H, Err) then
    Exit;
  try
    AssertTrue('the window capture dimensions are positive', (W > 0) and (H > 0));
    AssertTrue('the window capture buffer is allocated', Buf <> nil);
  finally
    FreeMem(Buf);
  end;
end;

initialization
  RegisterTest(TMediaTests);

end.
