unit test_http;
{ Tests for the Transfer-Encoding: chunked decoder (mirmid.http).
  Providers (DeepSeek and others) deliver the SSE stream chunk-framed, and a
  chunk boundary may split a `data:` line — without decoding such deltas are
  lost. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TChunkedDecoderTests = class(TTestCase)
  private
    FData: RawByteString;
    FStopAt: Integer;   { >0 — the handler returns False on this chunk }
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
    AssertTrue('first fragment', D.Feed('data: hello'#10));
    AssertTrue('second fragment', D.Feed('data: world'#10));
  finally
    D.Free;
  end;
  AssertEquals('without chunked the data passes through as is',
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
    { 0x7 "data: A", 0xc "BCDEFGHIJKLM", 0x3 "xyz", terminator. }
    AssertTrue('body', D.Feed(
      '7'#13#10'data: A'#13#10 +
      'c'#13#10'BCDEFGHIJKLM'#13#10 +
      '3'#13#10'xyz'#13#10 +
      '0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('data reassembled without frames', 'data: ABCDEFGHIJKLMxyz', FData);
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
    { An SSE line is split by a chunk boundary — it used to be lost entirely. }
    AssertTrue(D.Feed('b'#13#10'data: {"a":'#13#10));
    AssertTrue(D.Feed('4'#13#10'"b"}'#13#10));
    AssertTrue(D.Feed('0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('split line restored', 'data: {"a":"b"}', FData);
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
    { The chunk size and its data are spread over network fragments. }
    AssertTrue(D.Feed('b'));
    AssertTrue(D.Feed(#13#10'hello'));
    AssertTrue(D.Feed(' world'#13#10));
    AssertTrue(D.Feed('0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('size reassembled from pieces', 'hello world', FData);
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
  AssertEquals('trailers after 0 are ignored', 'abc', FData);
end;

procedure TChunkedDecoderTests.TestStopFromHandler;
var
  D: TBodyDecoder;
begin
  FData := '';
  FStopAt := 1;   { stop after the first payload chunk }
  FChunks := 0;
  D := TBodyDecoder.Create(True, @Collect);
  try
    AssertFalse('handler stopped reading',
      D.Feed('3'#13#10'abc'#13#10'3'#13#10'def'#13#10'0'#13#10#13#10));
  finally
    D.Free;
  end;
  AssertEquals('no data is read after the stop', 'abc', FData);
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
    AssertTrue('body is not finished yet', D.Feed('3'#13#10'abc'#13#10));
    AssertFalse('Done before the terminator', D.Done);
    AssertTrue('terminator', D.Feed('0'#13#10#13#10));
    AssertTrue('Done after the terminator', D.Done);
  finally
    D.Free;
  end;
  AssertEquals('data before the terminator', 'abc', FData);
end;

procedure TChunkedDecoderTests.TestParseChunkSize;
begin
  AssertEquals('hex', 419, ParseChunkSize('1a3'));
  AssertEquals('upper case with extension', 419, ParseChunkSize('1A3;ext=1'));
  AssertEquals('zero', 0, ParseChunkSize('0'));
end;

procedure TChunkedDecoderTests.TestHeaderHasChunked;
begin
  AssertTrue('chunked found',
    HeaderHasChunked('HTTP/1.1 200 OK'#13#10 +
      'Transfer-Encoding: chunked'#13#10#13#10));
  AssertTrue('case and spaces',
    HeaderHasChunked('transfer-encoding:   Chunked  '#13#10#13#10));
  AssertFalse('plain response',
    HeaderHasChunked('HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10));
end;

procedure TChunkedDecoderTests.TestHeaderContentLength;
begin
  AssertEquals('plain', 123, HeaderContentLength(
    'HTTP/1.1 200 OK'#13#10'Content-Length: 123'#13#10#13#10));
  AssertEquals('case and spaces', 7, HeaderContentLength(
    'content-length:   7  '#13#10#13#10));
  AssertEquals('empty body', 0, HeaderContentLength(
    'Content-Length: 0'#13#10#13#10));
  AssertEquals('no header', -1, HeaderContentLength(
    'HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10));
end;

initialization
  RegisterTest(TChunkedDecoderTests);

end.
