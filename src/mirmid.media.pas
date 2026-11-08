unit mirmid.media;
{ Инструмент read_media_file: знакомит модель с медиафайлами (изображения,
  звук, видео). Модель работает с текстом, поэтому инструмент возвращает
  описание файла: вид, формат, MIME-тип, размер и — для изображений —
  разрешение; по запросу содержимое кодируется в base64.
  Вид определяется по сигнатуре (первым байтам) файла, при неудаче — по
  расширению имени. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools;

const
  MEDIA_TOOL_NAME = 'read_media_file';
  { Предел размера base64-вывода по умолчанию: сколько байт исходного файла
    кодировать (0 — файл целиком). }
  MAX_MEDIA_BASE64 = 262144;
  { Сколько байт читать для определения формата (сигнатура и заголовки). }
  MEDIA_HEAD_BYTES = 65536;

{ Регистрирует инструмент read_media_file в реестре. }
procedure RegisterMediaTool(R: TToolRegistry);

{ Вид медиа по расширению имени файла: 'image' | 'audio' | 'video' | ''.
  Формат и MIME-тип возвращаются в Fmt и Mime. }
function MediaKindByExt(const FileName: string; out Fmt, Mime: string): string;

{ Вид медиа по сигнатуре (первым байтам файла): 'image' | 'audio' | 'video' | ''.
  Формат и MIME-тип возвращаются в Fmt и Mime. }
function MediaKindByMagic(const Head: string; out Fmt, Mime: string): string;

{ Размеры изображения из заголовка файла (Fmt — значение, полученное от
  MediaKindByMagic/MediaKindByExt). True, если размеры удалось разобрать. }
function ImageSizeFromHead(const Head, Fmt: string;
  out Width, Height: Integer): Boolean;

implementation

uses
  SysUtils, Classes, fpjson, base64, mirmid.types, mirmid.util, mirmid.json;

{ ------------------------------------------------------------------ helpers }

{ Совпадает ли фрагмент Sig с байтами Head, начиная со смещения Off (0-based). }
function SigAt(const S: string; Off: Integer; const Sig: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (Off < 0) or (Off + Length(Sig) > Length(S)) then
    Exit;
  for I := 1 to Length(Sig) do
    if S[Off + I] <> Sig[I] then
      Exit;
  Result := True;
end;

{ Байт по смещению Off (0-based); за пределами данных — 0. }
function ByteAt(const S: string; Off: Integer): LongWord;
begin
  if (Off < 0) or (Off >= Length(S)) then
    Result := 0
  else
    Result := Byte(S[Off + 1]);
end;

function LE16(const S: string; Off: Integer): LongWord;
begin
  Result := ByteAt(S, Off) or (ByteAt(S, Off + 1) shl 8);
end;

function BE16(const S: string; Off: Integer): LongWord;
begin
  Result := (ByteAt(S, Off) shl 8) or ByteAt(S, Off + 1);
end;

function LE24(const S: string; Off: Integer): LongWord;
begin
  Result := ByteAt(S, Off) or (ByteAt(S, Off + 1) shl 8) or
    (ByteAt(S, Off + 2) shl 16);
end;

function LE32(const S: string; Off: Integer): LongWord;
begin
  Result := LE24(S, Off) or (ByteAt(S, Off + 3) shl 24);
end;

function BE32(const S: string; Off: Integer): LongWord;
begin
  Result := (ByteAt(S, Off) shl 24) or (ByteAt(S, Off + 1) shl 16) or
    (ByteAt(S, Off + 2) shl 8) or ByteAt(S, Off + 3);
end;

{ ------------------------------------------------------ вид медиа по имени }

function MediaKindByExt(const FileName: string; out Fmt, Mime: string): string;
var
  E: string;
begin
  Result := '';
  Fmt := '';
  Mime := '';
  E := LowerCase(ExtractFileExt(FileName));
  if (E <> '') and (E[1] = '.') then
    Delete(E, 1, 1);
  if E = '' then
    Exit;
  case E of
    'png':                begin Result := 'image'; Fmt := 'PNG';  Mime := 'image/png'; end;
    'jpg', 'jpeg', 'jpe': begin Result := 'image'; Fmt := 'JPEG'; Mime := 'image/jpeg'; end;
    'gif':                begin Result := 'image'; Fmt := 'GIF';  Mime := 'image/gif'; end;
    'bmp':                begin Result := 'image'; Fmt := 'BMP';  Mime := 'image/bmp'; end;
    'webp':               begin Result := 'image'; Fmt := 'WEBP'; Mime := 'image/webp'; end;
    'tif', 'tiff':        begin Result := 'image'; Fmt := 'TIFF'; Mime := 'image/tiff'; end;
    'ico':                begin Result := 'image'; Fmt := 'ICO';  Mime := 'image/x-icon'; end;
    'avif':               begin Result := 'image'; Fmt := 'AVIF'; Mime := 'image/avif'; end;
    'heic', 'heif':       begin Result := 'image'; Fmt := 'HEIC'; Mime := 'image/heic'; end;
    'mp3':                begin Result := 'audio'; Fmt := 'MP3';  Mime := 'audio/mpeg'; end;
    'wav':                begin Result := 'audio'; Fmt := 'WAV';  Mime := 'audio/wav'; end;
    'ogg', 'oga':         begin Result := 'audio'; Fmt := 'OGG';  Mime := 'audio/ogg'; end;
    'opus':               begin Result := 'audio'; Fmt := 'OPUS'; Mime := 'audio/opus'; end;
    'flac':               begin Result := 'audio'; Fmt := 'FLAC'; Mime := 'audio/flac'; end;
    'm4a':                begin Result := 'audio'; Fmt := 'M4A';  Mime := 'audio/mp4'; end;
    'aac':                begin Result := 'audio'; Fmt := 'AAC';  Mime := 'audio/aac'; end;
    'wma':                begin Result := 'audio'; Fmt := 'WMA';  Mime := 'audio/x-ms-wma'; end;
    'mid', 'midi', 'rmi': begin Result := 'audio'; Fmt := 'MIDI'; Mime := 'audio/midi'; end;
    'mp4', 'm4v':         begin Result := 'video'; Fmt := 'MP4';  Mime := 'video/mp4'; end;
    'mkv':                begin Result := 'video'; Fmt := 'MKV';  Mime := 'video/x-matroska'; end;
    'webm':               begin Result := 'video'; Fmt := 'WEBM'; Mime := 'video/webm'; end;
    'avi':                begin Result := 'video'; Fmt := 'AVI';  Mime := 'video/x-msvideo'; end;
    'mov':                begin Result := 'video'; Fmt := 'MOV';  Mime := 'video/quicktime'; end;
    'wmv':                begin Result := 'video'; Fmt := 'WMV';  Mime := 'video/x-ms-wmv'; end;
    'flv':                begin Result := 'video'; Fmt := 'FLV';  Mime := 'video/x-flv'; end;
    'mpg', 'mpeg':        begin Result := 'video'; Fmt := 'MPEG'; Mime := 'video/mpeg'; end;
    'ogv':                begin Result := 'video'; Fmt := 'OGV';  Mime := 'video/ogg'; end;
    '3gp':                begin Result := 'video'; Fmt := '3GP';  Mime := 'video/3gpp'; end;
  end;
end;

{ Разбирает бренд контейнера ISO-BMFF (ftyp) в вид, формат и MIME. }
procedure IsoBrand(const Head: string; out Kind, Fmt, Mime: string);
var
  Brand: string;
begin
  Brand := UpperCase(Trim(Copy(Head, 9, 4)));
  Kind := 'video';
  Fmt := 'ISO-BMFF';
  Mime := 'video/mp4';
  if (Brand = 'M4A') or (Brand = 'M4B') or (Brand = 'M4P') then
  begin
    Kind := 'audio';
    Fmt := 'M4A';
    Mime := 'audio/mp4';
  end
  else if (Brand = 'QT') then
  begin
    Fmt := 'MOV';
    Mime := 'video/quicktime';
  end
  else if Brand = 'AVIF' then
  begin
    Kind := 'image';
    Fmt := 'AVIF';
    Mime := 'image/avif';
  end
  else if (Brand = 'HEIC') or (Brand = 'HEIX') or (Brand = 'HEVC') or
    (Brand = 'MIF1') or (Brand = 'MSF1') then
  begin
    Kind := 'image';
    Fmt := 'HEIC';
    Mime := 'image/heic';
  end
  else if (Brand = 'MP4') or (Brand = 'ISOM') or (Brand = 'MP42') or
    (Brand = 'AVC1') or (Brand = 'DASH') or (Brand = '3GP') then
  begin
    Fmt := 'MP4';
    Mime := 'video/mp4';
  end;
end;

{ -------------------------------------------------- вид медиа по сигнатуре }

function MediaKindByMagic(const Head: string; out Fmt, Mime: string): string;
begin
  Result := '';
  Fmt := '';
  Mime := '';
  if SigAt(Head, 0, #$89'PNG'#$0D#$0A#$1A#$0A) then
  begin
    Result := 'image'; Fmt := 'PNG'; Mime := 'image/png';
  end
  else if SigAt(Head, 0, #$FF#$D8#$FF) then
  begin
    Result := 'image'; Fmt := 'JPEG'; Mime := 'image/jpeg';
  end
  else if SigAt(Head, 0, 'GIF87a') or SigAt(Head, 0, 'GIF89a') then
  begin
    Result := 'image'; Fmt := 'GIF'; Mime := 'image/gif';
  end
  else if SigAt(Head, 0, 'BM') and (LE32(Head, 14) > 0) then
  begin
    { Слабая сигнатура: принимаем только при правдоподобном размере
      заголовка DIB (12, 40, 52, 56, 108, 124). }
    case LE32(Head, 14) of
      12, 40, 52, 56, 64, 108, 124:
        begin Result := 'image'; Fmt := 'BMP'; Mime := 'image/bmp'; end;
    end;
  end
  else if SigAt(Head, 0, 'RIFF') and SigAt(Head, 8, 'WEBP') then
  begin
    Result := 'image'; Fmt := 'WEBP'; Mime := 'image/webp';
  end
  else if SigAt(Head, 0, 'RIFF') and SigAt(Head, 8, 'WAVE') then
  begin
    Result := 'audio'; Fmt := 'WAV'; Mime := 'audio/wav';
  end
  else if SigAt(Head, 0, 'RIFF') and SigAt(Head, 8, 'AVI ') then
  begin
    Result := 'video'; Fmt := 'AVI'; Mime := 'video/x-msvideo';
  end
  else if SigAt(Head, 0, #$1A#$45#$DF#$A3) then
  begin
    { EBML: Matroska или WebM — различаем по DocType. }
    if Pos('webm', LowerCase(Head)) > 0 then
    begin
      Result := 'video'; Fmt := 'WEBM'; Mime := 'video/webm';
    end
    else
    begin
      Result := 'video'; Fmt := 'MKV'; Mime := 'video/x-matroska';
    end;
  end
  else if SigAt(Head, 4, 'ftyp') then
  begin
    IsoBrand(Head, Result, Fmt, Mime);
  end
  else if SigAt(Head, 0, 'ID3') then
  begin
    Result := 'audio'; Fmt := 'MP3'; Mime := 'audio/mpeg';
  end
  else if SigAt(Head, 0, #$FF#$FB) or SigAt(Head, 0, #$FF#$F3) or
    SigAt(Head, 0, #$FF#$F2) or SigAt(Head, 0, #$FF#$FA) then
  begin
    Result := 'audio'; Fmt := 'MP3'; Mime := 'audio/mpeg';
  end
  else if SigAt(Head, 0, 'fLaC') then
  begin
    Result := 'audio'; Fmt := 'FLAC'; Mime := 'audio/flac';
  end
  else if SigAt(Head, 0, 'OggS') then
  begin
    Result := 'audio'; Fmt := 'OGG'; Mime := 'audio/ogg';
  end
  else if SigAt(Head, 0, #$30#$26#$B2#$75) then
  begin
    { ASF: WMA (звук) или WMV (видео) — различаем по расширению позже. }
    Result := 'audio'; Fmt := 'ASF'; Mime := 'audio/x-ms-wma';
  end
  else if SigAt(Head, 0, 'FLV'#$01) then
  begin
    Result := 'video'; Fmt := 'FLV'; Mime := 'video/x-flv';
  end
  else if SigAt(Head, 0, 'FORM') and SigAt(Head, 8, 'AIFF') then
  begin
    Result := 'audio'; Fmt := 'AIFF'; Mime := 'audio/aiff';
  end
  else if SigAt(Head, 0, 'MThd') then
  begin
    Result := 'audio'; Fmt := 'MIDI'; Mime := 'audio/midi';
  end
  else if SigAt(Head, 0, 'II'#$2A#$00) or SigAt(Head, 0, 'MM'#$00#$2A) then
  begin
    Result := 'image'; Fmt := 'TIFF'; Mime := 'image/tiff';
  end
  else if SigAt(Head, 0, #$00#$00#$01#$00) then
  begin
    Result := 'image'; Fmt := 'ICO'; Mime := 'image/x-icon';
  end;
end;

{ ---------------------------------------------------- размеры изображения }

function JpegSize(const S: string; out W, H: Integer): Boolean;
var
  I: Integer;
  Marker: Byte;
  Len: Integer;
begin
  Result := False;
  W := 0;
  H := 0;
  I := 2;                       { пропускаем SOI (FF D8) }
  while I + 1 <= Length(S) do
  begin
    if ByteAt(S, I) <> $FF then
    begin
      Inc(I);
      Continue;
    end;
    Marker := ByteAt(S, I + 1);
    if Marker = $FF then       { выравнивающие FF перед маркером }
    begin
      Inc(I);
      Continue;
    end;
    if (Marker = $D8) or (Marker = $01) or ((Marker >= $D0) and (Marker <= $D7)) then
    begin
      Inc(I, 2);                { маркеры без полезной нагрузки }
      Continue;
    end;
    if (Marker = $D9) or (Marker = $DA) then
      Exit;                     { конец файла или начало сжатых данных }
    if (Marker >= $C0) and (Marker <= $CF) and (Marker <> $C4) and
      (Marker <> $C8) and (Marker <> $CC) then
    begin
      H := BE16(S, I + 5);      { SOF: длина, точность, высота, ширина }
      W := BE16(S, I + 7);
      Exit((W > 0) and (H > 0));
    end;
    Len := BE16(S, I + 2);
    if Len < 2 then
      Exit;
    Inc(I, 2 + Len);
  end;
end;

function WebpSize(const S: string; out W, H: Integer): Boolean;
var
  FourCC: string;
  V: LongWord;
begin
  Result := False;
  W := 0;
  H := 0;
  if not (SigAt(S, 0, 'RIFF') and SigAt(S, 8, 'WEBP')) then
    Exit;
  FourCC := Copy(S, 13, 4);
  if FourCC = 'VP8X' then          { расширенный формат: размеры холста }
  begin
    W := LE24(S, 24) + 1;
    H := LE24(S, 27) + 1;
  end
  else if FourCC = 'VP8 ' then     { с потерями }
  begin
    if not SigAt(S, 23, #$9D#$01#$2A) then
      Exit;
    W := LE16(S, 26) and $3FFF;
    H := LE16(S, 28) and $3FFF;
  end
  else if FourCC = 'VP8L' then     { без потерь }
  begin
    if ByteAt(S, 20) <> $2F then
      Exit;
    V := LE32(S, 21);
    W := (V and $3FFF) + 1;
    H := ((V shr 14) and $3FFF) + 1;
  end;
  Result := (W > 0) and (H > 0);
end;

function ImageSizeFromHead(const Head, Fmt: string;
  out Width, Height: Integer): Boolean;
var
  DIB: LongWord;
  IH, IW: LongInt;
begin
  Result := False;
  Width := 0;
  Height := 0;

  if Fmt = 'PNG' then
  begin
    if not SigAt(Head, 12, 'IHDR') then
      Exit;
    Width := BE32(Head, 16);
    Height := BE32(Head, 20);
  end
  else if Fmt = 'GIF' then
  begin
    Width := LE16(Head, 6);
    Height := LE16(Head, 8);
  end
  else if Fmt = 'BMP' then
  begin
    DIB := LE32(Head, 14);
    if DIB = 12 then
    begin
      Width := LE16(Head, 18);
      Height := LE16(Head, 20);
    end
    else
    begin
      IW := LongInt(LE32(Head, 18));
      IH := LongInt(LE32(Head, 22));
      if IH < 0 then                  { отрицательная высота — строки сверху вниз }
        IH := -IH;
      Width := IW;
      Height := IH;
    end;
  end
  else if Fmt = 'JPEG' then
  begin
    Result := JpegSize(Head, Width, Height);
    Exit;
  end
  else if Fmt = 'WEBP' then
  begin
    Result := WebpSize(Head, Width, Height);
    Exit;
  end
  else if Fmt = 'ICO' then
  begin
    { Запись каталога ICO: ширина и высота — байты 6 и 7 (0 означает 256).
      Если файл короче 8 байт, данных о размере нет. }
    if Length(Head) < 8 then
      Exit(False);
    Width := ByteAt(Head, 6);
    Height := ByteAt(Head, 7);
    if Width = 0 then
      Width := 256;
    if Height = 0 then
      Height := 256;
  end;

  Result := (Width > 0) and (Height > 0);
end;

{ --------------------------------------------------------------- инструмент }

function KindRu(const Kind: string): string;
begin
  if Kind = 'image' then
    Result := 'изображение'
  else if Kind = 'audio' then
    Result := 'звук'
  else if Kind = 'video' then
    Result := 'видео'
  else
    Result := Kind;
end;

{ Читает не более Limit байт файла (Limit <= 0 — весь файл). }
function ReadFilePart(const Path: string; Limit: Integer; out Data: string;
  out Err: string): Boolean;
var
  F: TFileStream;
begin
  Data := '';
  Err := '';
  Result := False;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if (Limit <= 0) or (Limit > F.Size) then
        Limit := F.Size;
      SetLength(Data, Limit);
      if Limit > 0 then
        F.ReadBuffer(Data[1], Limit);
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      Err := Path + ': ' + E.Message;
  end;
end;

function ToolReadMedia(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  P, Head, Kind, Fmt, Mime, Info, Err, Data: string;
  EKind, EFmt, EMime: string;
  W, H, Limit: Integer;
  Size: Int64;
  F: TFileStream;
begin
  { Гейт в обработчике: ключ read_media_file в секции [tools]. }
  if not ToolEnabled(Ctx.Cfg, MEDIA_TOOL_NAME) then
    Exit(ToolDisabled(MEDIA_TOOL_NAME));
  P := Trim(JStr(A, 'path', ''));
  if P = '' then
    Exit(ErrResult('не задан path'));
  P := ExpPath(P, Ctx.WorkDir);
  if IsMirmidPath(Ctx.WorkDir, P) then
    Exit(ErrResult('доступ запрещён: ' + P +
      ' находится в служебном каталоге .mirmid'));
  if DirectoryExists(P) then
    Exit(ErrResult('это каталог, а не файл: ' + P));
  if not FileExists(P) then
    Exit(ErrResult('файл не найден: ' + P));

  { Для определения формата достаточно заголовка: файл целиком не читаем
    (медиафайлы бывают очень большими). }
  try
    F := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
      Exit(ErrResult('не удалось открыть файл: ' + P + ': ' + E.Message));
  end;
  try
    Size := F.Size;
    if Size > MEDIA_HEAD_BYTES then
      SetLength(Head, MEDIA_HEAD_BYTES)
    else
      SetLength(Head, Size);
    if Length(Head) > 0 then
      F.ReadBuffer(Head[1], Length(Head));
  finally
    F.Free;
  end;

  { Сигнатура надёжна для изображений; у контейнеров звука и видео (MP4,
    MKV, ASF) вид уточняем по расширению имени. }
  Kind := MediaKindByMagic(Head, Fmt, Mime);
  EKind := MediaKindByExt(P, EFmt, EMime);
  if (Kind = '') or ((EKind <> '') and (Kind <> 'image')) then
  begin
    Kind := EKind;
    Fmt := EFmt;
    Mime := EMime;
  end;
  if Kind = '' then
    Exit(ErrResult('не медиафайл: ' + P +
      ' (для текстовых форматов используйте read_text_file)'));

  Info := 'файл: ' + P + sLineBreak +
          'вид: ' + KindRu(Kind) + ' (' + Fmt + ')' + sLineBreak +
          'MIME: ' + Mime + sLineBreak +
          'размер: ' + IntToStr(Size) + ' байт';
  if Kind = 'image' then
    if ImageSizeFromHead(Head, Fmt, W, H) then
      Info := Info + sLineBreak + Format('разрешение: %dx%d', [W, H]);

  if JBool(A, 'base64', False) then
  begin
    Limit := JInt(A, 'max_bytes', MAX_MEDIA_BASE64);
    if Limit < 0 then
      Limit := 0;
    if (Limit > 0) and (Size > Limit) then
      Info := Info + sLineBreak +
        Format('[… закодированы первые %d из %d байт: увеличьте max_bytes, ' +
          'чтобы получить файл целиком]', [Limit, Size]);
    if not ReadFilePart(P, Limit, Data, Err) then
      Exit(ErrResult('не удалось прочитать файл: ' + Err));
    Info := Info + sLineBreak + 'base64:' + sLineBreak + EncodeStringBase64(Data);
  end;

  Result := OkResult(Info);
end;

procedure RegisterMediaTool(R: TToolRegistry);
begin
  R.Add(MEDIA_TOOL_NAME,
    'Читает медиафайл (изображение, звук, видео): вид, формат, MIME-тип, ' +
    'размер и разрешение изображения; при base64=true возвращает содержимое ' +
    'в base64.',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Путь к медиафайлу'),
        'base64', PropBool('Вернуть содержимое файла в base64 (по умолчанию нет)'),
        'max_bytes', PropInt('Предел base64 (в байтах исходного файла); 0 — файл целиком (по умолчанию 262144)')]),
      ['path']),
    @ToolReadMedia);
end;

end.
