unit test_http;
{ Тесты декодера Transfer-Encoding: chunked (mirmid.http).
  Провайдеры (DeepSeek и др.) отдают SSE-поток в chunked-кадрировании, причём
  граница чанка может разрезать строку data: — без декодирования такие дельты
  теряются. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TChunkedDecoderTests = class(TTestCase)
  private
    FData: RawByteString;
    FStopAt: Integer;   { >0 — обработчик вернёт False на этом чанке }
    FChunks: Integer;
  public
    function Collect(const C: RawByteString): Boolean;
  published
    procedure TestNonChunkedPassthrough;
    procedure TestChunkedReassemble;
    procedure TestChunkBoundaryMidLine;
    procedure TestSizeLineSplitAcrossFeeds;
    procedure TestTerminatorAndTrailer;
    procedure TestStopFromHandler;
    procedure TestDoneAfterTerminator;
    procedure TestParseChunkSize;
    procedure TestHeaderHasChunked;
    procedure TestHeaderContentLength;
  end;

implementation

uses
  SysUtils, mirmid.http;

function TChunkedDecoderTests.Collect(const C: RawByteString): Boolean;
begin
  FData := FData + C;
  Inc(FChunks);
  Result := (FStopAt <= 0) or (FChunks < FStopAt);
end;

procedure TChunkedDecoderTests.TestNonChunkedPassthrough;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 0;
  FChunks := 0;
  D := TBodyDecoder.Create(False, @Collect);
  try
    AssertTrue('первый фрагмент', D.Feed('data: hello'#10));
    AssertTrue('второй фрагмент', D.Feed('data: world'#10));
  finally
    D.Free;
  end;
  AssertEquals('без chunked данные идут как есть',
    'data: hello'#10'data: world'#10, FData);
end;

procedure TChunkedDecoderTests.TestChunkedReassemble;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 0;
  FChunks := 0;
  D := TBodyDecoder.Create(True, @Collect);
  try
    { 0x7 «data: A», 0xc «BCDEFGHIJKLM», 0x3 «xyz», терминатор. }
    AssertTrue('тело', D.Feed(
      '7'#13#10'data: A'#13#10 +
      'c'#13#10'BCDEFGHIJKLM'#13#10 +
      '3'#13#10'xyz'#13#10 +
      '0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('данные собраны без кадров', 'data: ABCDEFGHIJKLMxyz', FData);
end;

procedure TChunkedDecoderTests.TestChunkBoundaryMidLine;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 0;
  FChunks := 0;
  D := TBodyDecoder.Create(True, @Collect);
  try
    { Строка SSE разрезана границей чанка — раньше она терялась целиком. }
    AssertTrue(D.Feed('b'#13#10'data: {"a":'#13#10));
    AssertTrue(D.Feed('4'#13#10'"b"}'#13#10));
    AssertTrue(D.Feed('0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('разрезанная строка восстановлена', 'data: {"a":"b"}', FData);
end;

procedure TChunkedDecoderTests.TestSizeLineSplitAcrossFeeds;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 0;
  FChunks := 0;
  D := TBodyDecoder.Create(True, @Collect);
  try
    { Размер чанка и его данные разнесены по сетевым фрагментам. }
    AssertTrue(D.Feed('b'));
    AssertTrue(D.Feed(#13#10'hello'));
    AssertTrue(D.Feed(' world'#13#10));
    AssertTrue(D.Feed('0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('размер, собранный по кускам', 'hello world', FData);
end;

procedure TChunkedDecoderTests.TestTerminatorAndTrailer;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 0;
  FChunks := 0;
  D := TBodyDecoder.Create(True, @Collect);
  try
    AssertTrue(D.Feed('3'#13#10'abc'#13#10'0'#13#10'X-Trailer: 1'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('трейлеры после 0 игнорируются', 'abc', FData);
end;

procedure TChunkedDecoderTests.TestStopFromHandler;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 1;   { остановиться после первого полезного чанка }
  FChunks := 0;
  D := TBodyDecoder.Create(True, @Collect);
  try
    AssertFalse('обработчик остановил чтение',
      D.Feed('3'#13#10'abc'#13#10'3'#13#10'def'#13#10'0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('после остановки данные не читаются', 'abc', FData);
end;

procedure TChunkedDecoderTests.TestDoneAfterTerminator;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 0;
  FChunks := 0;
  D := TBodyDecoder.Create(True, @Collect);
  try
    AssertTrue('тело ещё не завершено', D.Feed('3'#13#10'abc'#13#10));
    AssertFalse('Done до терминатора', D.Done);
    AssertTrue('терминатор', D.Feed('0'#13#10#13#10));
    AssertTrue('Done после терминатора', D.Done);
  finally
    D.Free;
  end;
  AssertEquals('данные до терминатора', 'abc', FData);
end;

procedure TChunkedDecoderTests.TestParseChunkSize;
begin
  AssertEquals('hex', 419, ParseChunkSize('1a3'));
  AssertEquals('верхний регистр с расширением', 419, ParseChunkSize('1A3;ext=1'));
  AssertEquals('ноль', 0, ParseChunkSize('0'));
end;

procedure TChunkedDecoderTests.TestHeaderHasChunked;
begin
  AssertTrue('chunked найден',
    HeaderHasChunked('HTTP/1.1 200 OK'#13#10 +
      'Transfer-Encoding: chunked'#13#10#13#10));
  AssertTrue('регистр и пробелы',
    HeaderHasChunked('transfer-encoding:   Chunked  '#13#10#13#10));
  AssertFalse('обычный ответ',
    HeaderHasChunked('HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10));
end;

procedure TChunkedDecoderTests.TestHeaderContentLength;
begin
  AssertEquals('обычный', 123, HeaderContentLength(
    'HTTP/1.1 200 OK'#13#10'Content-Length: 123'#13#10#13#10));
  AssertEquals('регистр и пробелы', 7, HeaderContentLength(
    'content-length:   7  '#13#10#13#10));
  AssertEquals('нулевое тело', 0, HeaderContentLength(
    'Content-Length: 0'#13#10#13#10));
  AssertEquals('заголовка нет', -1, HeaderContentLength(
    'HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10));
end;

initialization
  RegisterTest(TChunkedDecoderTests);

end.
