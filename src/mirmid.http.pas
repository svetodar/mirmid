unit mirmid.http;
{ Minimal HTTP client: own transport (mirmid.tlsclient — plain TCP for
  scheme http, TLS 1.2 client from library tls for https). The system
  OpenSSL and FPC ssl sockets are not used. Supports GET/POST with a
  JSON body and does not raise exception at HTTP 4xx/5xx: status and body
  returned to caller.

  Streaming request (SSE) — body chunks delivered to OnChunk as they arrive;
  Transfer-Encoding: chunked is stripped in TBodyDecoder. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  THttpResult = record
    Ok: Boolean;          { status 2xx }
    StatusCode: Integer;  { 0, if not connected }
    StatusText: string;   { response status text (e.g. OK) }
    Body: string;
    Error: string;
    Location: string;     { Location header at 3xx (redirect) }
  end;

  { Handler chunk body at streaming read. Return False —
    stop reading (stream considered finished). }
  THttpChunkHandler = function(const Chunk: RawByteString): Boolean of object;

  { State decoder chunked-body. }
  TChunkState = (cstSize, cstData, cstCrlf, cstDone);

  { Receiver error body (4xx/5xx): accumulates up to STREAM_ERR_BODY_MAX. }
  TErrBodySink = class
  private
    FBody: RawByteString;
  public
    function Add(const Data: RawByteString): Boolean;
    property Body: RawByteString read FBody;
  end;

  { Accumulator body (no limit) — non-streaming response. }
  TBodyAccum = class
  private
    FBody: RawByteString;
  public
    function Add(const Data: RawByteString): Boolean;
    property Body: RawByteString read FBody;
  end;

  { HTTP body decoder: with Transfer-Encoding: chunked it strips the framing
    (hex chunk size + CRLF) and passes the payload to OnChunk. Without
    chunked the data is passed as is. The state is kept between Feed calls,
    because a frame may be split by a network read at any place.
    Public for the tests. }
  TBodyDecoder = class
  private
    FChunked: Boolean;
    FOnChunk: THttpChunkHandler;
    FState: TChunkState;
    FLine: RawByteString;
    FRemaining: Int64;
  public
    constructor Create(AChunked: Boolean; const AOnChunk: THttpChunkHandler);
    function Feed(const Data: RawByteString): Boolean;
    { Body finished: for chunked — the zero chunk was received (or the
      handler stopped reading). Lets the caller stop reading without waiting
      for the connection to close. }
    function Done: Boolean;
  end;

{ Is there Transfer-Encoding: chunked in the response header block. }
function HeaderHasChunked(const Hdr: RawByteString): Boolean;

{ Content-Length from the response header block; -1 — the header is absent
  or unparsable (then the body ends at connection close). }
function HeaderContentLength(const Hdr: RawByteString): Int64;

{ Chunked chunk size from string like "1a3" (with ";ext" suffix). }
function ParseChunkSize(const Line: RawByteString): Int64;

{ Joins base URL and path, no double slash. }
function JoinUrl(const Base, Path: string): string;


{ HTTP request. Body used only for POST; for GET pass ''. }
function HttpRequest(const Method, Url, ApiKey, Body: string;
  TimeoutMs, ConnectMs: Integer): THttpResult;

{ HTTP request with arbitrary headers. Headers — array of
  "Name: Value" strings. Base headers (Content-Type, Accept) are not added
  automatically — the caller passes them. }
function HttpRequestEx(const Method, Url, Body: string;
  const Headers: array of string;
  TimeoutMs, ConnectMs: Integer): THttpResult;
{ --- Retries on network failures -------------------------------------------

  A single transport error (DNS failure, refusal or timeout at connect,
  connection reset before the response) should not ruin the request: it is
  repeated up to HttpRetryCount times with pauses 1/2/4 s. Only a transport
  failure is repeated — HTTP 4xx/5xx statuses are returned to the caller
  without retries. A streaming request (SSE) is repeated only before the
  first body response: a repeat after delivered deltas would duplicate text. }

const
  { Number repeats after first attempt (total HttpRetryCount + 1 attempts). }
  HTTP_RETRY_COUNT = 3;
  { Base pause before first repeat, ms; before each next doubles. }
  HTTP_RETRY_BASE_DELAY_MS = 1000;

var
  { Effective repeat parameters (tests shorten pause, not wait seconds). }
  HttpRetryCount: Integer = HTTP_RETRY_COUNT;
  HttpRetryBaseDelayMs: Integer = HTTP_RETRY_BASE_DELAY_MS;

{ Same by error text — for failures already converted to a string. }
function IsRetryableNetErrorText(const S: string): Boolean;

{ Pause before repeat number ARetry (0 — before first repeat), ms. }
function HttpRetryDelayMs(ARetry: Integer): Integer;
{ Streaming HTTP request: the body is delivered chunk-by-chunk to OnChunk
  as it arrives (SSE). For 4xx/5xx statuses chunks are not passed — the
  error and the body are returned in Err. TimeoutMs — overall request
  timeout, ConnectMs — connect timeout. }
function HttpRequestStream(const Method, Url, ApiKey, Body: string;
  TimeoutMs, ConnectMs: Integer; const OnChunk: THttpChunkHandler;
  out StatusCode: Integer; out StatusText: string; out Err: string): Boolean;
{ Streaming HTTP request with arbitrary headers. Headers — array of
  "Name: Value" strings. Accept: text/event-stream and Connection: close
  are added automatically. For 4xx/5xx statuses chunks are not passed — the
  error and the body are returned in Err. }
function HttpRequestStreamEx(const Method, Url, Body: string;
  const Headers: array of string;
  TimeoutMs, ConnectMs: Integer; const OnChunk: THttpChunkHandler;
  out StatusCode: Integer; out StatusText: string; out Err: string): Boolean;

implementation

uses
  mirmid.tlsclient;

const
  { Timeout of one socket read in streaming mode: if the model "thinks"
    longer, Read returns -1 and the cycle continues until the request timeout. }
  STREAM_READ_TIMEOUT_MS = 3000000;
  { Limit accumulation error body (4xx/5xx). }
  STREAM_ERR_BODY_MAX = 100000;
  { Maximum redirects followed non-streaming. }
  MAX_REDIRECTS = 5;

function TErrBodySink.Add(const Data: RawByteString): Boolean;
begin
  FBody := FBody + Data;
  if Length(FBody) > STREAM_ERR_BODY_MAX then
    FBody := Copy(FBody, 1, STREAM_ERR_BODY_MAX);
  Result := True;
end;

function TBodyAccum.Add(const Data: RawByteString): Boolean;
begin
  FBody := FBody + Data;
  Result := True;
end;

{ Hex digit value or -1. }
function HexDigit(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ Chunked chunk size from string like "1a3" (with ";ext" suffix). }
function ParseChunkSize(const Line: RawByteString): Int64;
var
  I, H: Integer;
  S: string;
begin
  S := Line;
  Result := 0;
  for I := 1 to Length(S) do
  begin
    if S[I] = ';' then
      Break;
    H := HexDigit(S[I]);
    if H < 0 then
      Continue;   { ignore spaces and CR }
    Result := Result * 16 + H;
  end;
end;

{ Is there Transfer-Encoding: chunked in response header block. }
function HeaderHasChunked(const Hdr: RawByteString): Boolean;
var
  I, N, Start, P: Integer;
  Line, Name, Val: string;
begin
  Result := False;
  N := Length(Hdr);
  Start := 1;
  for I := 1 to N + 1 do
    if (I > N) or (Hdr[I] = #10) then
    begin
      Line := Copy(Hdr, Start, I - Start);
      Start := I + 1;
      if (Line <> '') and (Line[Length(Line)] = #13) then
        Delete(Line, Length(Line), 1);
      P := Pos(':', Line);
      if P > 0 then
      begin
        Name := LowerCase(Trim(Copy(Line, 1, P - 1)));
        Val  := LowerCase(Trim(Copy(Line, P + 1, MaxInt)));
        if (Name = 'transfer-encoding') and (Pos('chunked', Val) > 0) then
          Exit(True);
      end;
    end;
end;

{ Content-Length from response header block; -1 — header absent or
  unparsable (then the body ends at connection close). }
function HeaderContentLength(const Hdr: RawByteString): Int64;
var
  I, N, Start, P: Integer;
  Line, Name, Val: string;
begin
  Result := -1;
  N := Length(Hdr);
  Start := 1;
  for I := 1 to N + 1 do
    if (I > N) or (Hdr[I] = #10) then
    begin
      Line := Copy(Hdr, Start, I - Start);
      Start := I + 1;
      if (Line <> '') and (Line[Length(Line)] = #13) then
        Delete(Line, Length(Line), 1);
      P := Pos(':', Line);
      if P > 0 then
      begin
        Name := LowerCase(Trim(Copy(Line, 1, P - 1)));
        Val  := Trim(Copy(Line, P + 1, MaxInt));
        if Name = 'content-length' then
          Exit(StrToInt64Def(Val, -1));
      end;
    end;
end;

constructor TBodyDecoder.Create(AChunked: Boolean;
  const AOnChunk: THttpChunkHandler);
begin
  inherited Create;
  FChunked := AChunked;
  FOnChunk := AOnChunk;
  FState := cstSize;
  FLine := '';
  FRemaining := 0;
end;

function TBodyDecoder.Feed(const Data: RawByteString): Boolean;
var
  I, N, Take: Integer;
  C: Byte;
  Piece: RawByteString;
  Size: Int64;
begin
  Result := True;
  N := Length(Data);
  if N = 0 then
    Exit;
  if not FChunked then
  begin
    if Assigned(FOnChunk) then
      Result := FOnChunk(Data);
    Exit;
  end;
  I := 1;
  while I <= N do
  begin
    case FState of
      cstSize:
        begin
          C := Byte(Data[I]);
          Inc(I);
          if C = 10 then
          begin
            Size := ParseChunkSize(FLine);
            FLine := '';
            if Size <= 0 then
              { The zero chunk finishes the body: see Done. }
              FState := cstDone
            else
            begin
              FRemaining := Size;
              FState := cstData;
            end;
          end
          else
            FLine := FLine + AnsiChar(C);
        end;
      cstData:
        begin
          Take := N - I + 1;
          if Int64(Take) > FRemaining then
            Take := Integer(FRemaining);
          Piece := Copy(Data, I, Take);
          Inc(I, Take);
          Dec(FRemaining, Take);
          if FRemaining = 0 then
            FState := cstCrlf;
          if Assigned(FOnChunk) then
            if not FOnChunk(Piece) then
            begin
              FState := cstDone;
              Exit(False);
            end;
        end;
      cstCrlf:
        begin
          C := Byte(Data[I]);
          Inc(I);
          if C = 10 then
            FState := cstSize;
        end;
    else
      Exit;   { cstDone — body finished, trailers ignored }
    end;
  end;
end;

function TBodyDecoder.Done: Boolean;
begin
  Result := FState = cstDone;
end;

function JoinUrl(const Base, Path: string): string;
var
  B, P: string;
begin
  B := Trim(Base);
  while (B <> '') and (B[Length(B)] = '/') do
    Delete(B, Length(B), 1);
  P := Trim(Path);
  if (P = '') then
    Exit(B);
  if P[1] <> '/' then
    P := '/' + P;
  Result := B + P;
end;

{ Parses URL scheme://host[:port]/path[?query]. }
function ParseUrl(const Url: string; out Scheme, Host, Path: string;
  out Port: Integer): Boolean;
var
  P, Q, R: Integer;
  Rest, HostPart: string;
begin
  Result := False;
  Scheme := '';
  Host := '';
  Path := '/';
  Port := 0;
  P := Pos('://', Url);
  if P = 0 then
    Exit;
  Scheme := LowerCase(Copy(Url, 1, P - 1));
  Rest := Copy(Url, P + 3, MaxInt);
  Q := Pos('/', Rest);
  if Q > 0 then
  begin
    HostPart := Copy(Rest, 1, Q - 1);
    Path := Copy(Rest, Q, MaxInt);
  end
  else
  begin
    HostPart := Rest;
    Path := '/';
  end;
  R := Pos(':', HostPart);
  if R > 0 then
  begin
    Host := Copy(HostPart, 1, R - 1);
    Port := StrToIntDef(Copy(HostPart, R + 1, MaxInt), 0);
  end
  else
    Host := HostPart;
  Result := (Scheme = 'http') or (Scheme = 'https');
  if not Result then
    Exit;
  if Port <= 0 then
    if Scheme = 'https' then
      Port := 443
    else
      Port := 80;
end;

{ Current time in milliseconds (for general timeout request). }
function NowMs: QWord;
begin
  Result := GetTickCount64;
end;

{ Position sequence CRLF CRLF in S (0 — not found). }
function FindCrlfCrlf(const S: string): Integer;
var
  I, N: Integer;
begin
  Result := 0;
  N := Length(S);
  for I := 1 to N - 3 do
    if (S[I] = #13) and (S[I + 1] = #10) and (S[I + 2] = #13) and (S[I + 3] = #10) then
      Exit(I);
end;

{ Location header (absolute or relative) as absolute URL from BaseUrl. }
function ResolveLocation(const Loc, BaseUrl, Scheme, Host: string;
  Port: Integer): string;
var
  PortStr, L: string;
begin
  L := Trim(Loc);
  if L = '' then
    Exit('');
  if (Pos('http://', L) = 1) or (Pos('https://', L) = 1) then
    Exit(L);
  if L[1] = '/' then
  begin
    PortStr := '';
    if ((Scheme = 'http') and (Port <> 80)) or
       ((Scheme = 'https') and (Port <> 443)) then
      PortStr := ':' + IntToStr(Port);
    Exit(Scheme + '://' + Host + PortStr + L);
  end;
  Result := JoinUrl(BaseUrl, L);
end;

{ Redirect Location from BaseUrl to absolute URL. }
function HttpResolveRedirect(const BaseUrl, Loc: string): string;
var
  Scheme, Host, Path: string;
  Port: Integer;
begin
  if not ParseUrl(BaseUrl, Scheme, Host, Path, Port) then
    Exit(Loc);
  Result := ResolveLocation(Loc, BaseUrl, Scheme, Host, Port);
end;

{ --- Core HTTP exchange: connect, send request, read response -------------

  Headers — array of "Name: Value" strings (as is). At 2xx the body passes to
  OnChunk, at 4xx/5xx — to OnErrChunk. Result True — headers received and
  status 2xx. At transport failure StatusCode = 0 and Err — reason.
  Socket IOTimeout capped at STREAM_READ_TIMEOUT_MS: general timeout request
  enforced by Deadline. }
{ Position of next #13 in S after position AFrom (0 — not found). }
function FindLineEnd(const S: string; AFrom: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := AFrom to Length(S) do
    if S[I] = #13 then
      Exit(I);
end;

{ --- Core HTTP exchange: connect, send request, read response -------------

  Headers — TStringList of "Name: Value" strings (empty string — skip).
  At 2xx body passes to OnChunk, at 4xx/5xx — to OnErrChunk.
  Result True — headers received and status 2xx. At transport failure
  StatusCode = 0 and Err — reason. Socket IOTimeout capped at
  STREAM_READ_TIMEOUT_MS: general timeout request enforced by Deadline. }
function HttpExchangeOnce(const Method, Url, Body: string;
  const Headers: TStringList;
  TimeoutMs, ConnectMs: Integer;
  const OnChunk, OnErrChunk: THttpChunkHandler;
  out StatusCode: Integer; out StatusText: string; out Err: string;
  out Location: string): Boolean;
var
  Scheme, Host, Path: string;
  Port, IoTimeout, Start: Integer;
  Transport: THttpTransport;
  Req, Hdr, Chunk: RawByteString;
  Buf: array[0..65535] of Byte;
  N: LongInt;
  P, Q, R, I: Integer;
  StatusLine, Tmp, HName, HVal: string;
  HeadersDone, Is2xx, Stopped: Boolean;
  Deadline, LastFailMs: QWord;
  FastFails: Integer;
  Decoder: TBodyDecoder;
  Chunked: Boolean;
  ContentLen: Int64;   { Content-Length (-1 — not set) }
  BodyRead: Int64;     { body bytes read }
begin
  Result := False;
  StatusCode := 0;
  StatusText := '';
  Err := '';
  Location := '';
  Decoder := nil;
  Chunked := False;
  ContentLen := -1;
  BodyRead := 0;
  if not ParseUrl(Url, Scheme, Host, Path, Port) then
    Exit(False);

  Transport := THttpTransport.Create(Scheme = 'https');
  try
    if TimeoutMs < STREAM_READ_TIMEOUT_MS then
      IoTimeout := TimeoutMs
    else
      IoTimeout := STREAM_READ_TIMEOUT_MS;
    if not Transport.Connect(Host, Port, ConnectMs, IoTimeout) then
    begin
      Err := Transport.LastError;
      Exit(False);
    end;

    { Request header and body — one write. }
    Req := Method + ' ' + Path + ' HTTP/1.1' + #13#10;
    Req := Req + 'Host: ' + Host;
    if (Scheme = 'http') and (Port <> 80) then
      Req := Req + ':' + IntToStr(Port);
    if (Scheme = 'https') and (Port <> 443) then
      Req := Req + ':' + IntToStr(Port);
    Req := Req + #13#10;
    for I := 0 to Headers.Count - 1 do
    begin
      P := Pos(':', Headers.Strings[I]);
      if P > 0 then
      begin
        HName := Trim(Copy(Headers.Strings[I], 1, P - 1));
        HVal  := Trim(Copy(Headers.Strings[I], P + 1, MaxInt));
        Req := Req + HName + ': ' + HVal + #13#10;
      end;
    end;
    Req := Req + 'Connection: close' + #13#10;
    if Method = 'POST' then
      Req := Req + 'Content-Length: ' + IntToStr(Length(Body)) + #13#10;
    Req := Req + #13#10;
    if not Transport.Send(Req + Body) then
    begin
      Err := Transport.LastError;
      Exit(False);
    end;

    Hdr := '';
    HeadersDone := False;
    Is2xx := False;
    Stopped := False;
    Deadline := NowMs + QWord(TimeoutMs);
    LastFailMs := 0;
    FastFails := 0;
    while not Stopped do
    begin
      N := Transport.Read(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetLength(Chunk, N);
        Move(Buf[0], Chunk[1], N);
        if not HeadersDone then
        begin
          Hdr := Hdr + Chunk;
          P := FindCrlfCrlf(Hdr);
          if P > 0 then
          begin
            Q := Pos(#13, Hdr);
            StatusLine := Copy(Hdr, 1, Q - 1);
            { String like "HTTP/1.1 200 OK". }
            R := Pos(' ', StatusLine);
            Tmp := Copy(StatusLine, R + 1, MaxInt);
            Q := Pos(' ', Tmp);
            if Q > 0 then
            begin
              StatusCode := StrToIntDef(Copy(Tmp, 1, Q - 1), 0);
              StatusText := Trim(Copy(Tmp, Q + 1, MaxInt));
            end
            else
            begin
              StatusCode := StrToIntDef(Tmp, 0);
              StatusText := '';
            end;
            HeadersDone := True;
            Is2xx := (StatusCode >= 200) and (StatusCode < 300);
            { Transfer-Encoding: chunked — strips the body framing. }
            Chunked := HeaderHasChunked(Hdr);
            { Content-Length: the body is known to be complete by the byte
              counter — there is no need to wait for the connection to close. }
            if Chunked then
              ContentLen := -1
            else
              ContentLen := HeaderContentLength(Hdr);
            { Location at 3xx (non-streaming request follows it). }
            if (StatusCode >= 300) and (StatusCode < 400) then
            begin
              Start := 1;
              while (Start <= Length(Hdr)) and (Location = '') do
              begin
                Q := FindLineEnd(Hdr, Start);
                if Q = 0 then
                  Q := Length(Hdr) + 1;
                Tmp := Copy(Hdr, Start, Q - Start);
                if LowerCase(Copy(Tmp, 1, 8)) = 'location' then
                begin
                  R := Pos(':', Tmp);
                  if R > 0 then
                    Location := Trim(Copy(Tmp, R + 1, MaxInt));
                end;
                Start := Q + 2;
              end;
            end;
            if Is2xx then
            begin
              Result := True;
              Decoder := TBodyDecoder.Create(Chunked, OnChunk);
            end
            else
              Decoder := TBodyDecoder.Create(Chunked, OnErrChunk);
            { Rest of body in same chunk. }
            Chunk := Copy(Hdr, P + 4, MaxInt);
            Hdr := '';
          end;
        end;
        if HeadersDone then
        begin
          if Chunk <> '' then
          begin
            Inc(BodyRead, Length(Chunk));
            if not Decoder.Feed(Chunk) then
              Stopped := True;
          end;
          { The chunked body is finished by the zero chunk — do not wait for
            the connection to close (otherwise the client hangs until timeout). }
          if (not Stopped) and Decoder.Done then
            Stopped := True;
          { The body with Content-Length is fully read (including an empty
            one) — stop reading without waiting for the connection to close. }
          if (not Stopped) and (ContentLen >= 0) and
             (BodyRead >= ContentLen) then
            Stopped := True;
        end;
      end
      else if N = 0 then
        Break   { EOF: server closed connection }
      else
      begin
        { -1: timeout read or socket error. Until general timeout — continue.
          But if errors follow one after another without delay, connection
          already dead (e.g. RST from server) — waiting until general
          timeout pointless. }
        if NowMs >= Deadline then
        begin
          Err := Format('request timed out (%d s)', [TimeoutMs div 1000]);
          Break;
        end;
        if (LastFailMs > 0) and (NowMs - LastFailMs < 1000) then
          Inc(FastFails)
        else
          FastFails := 0;
        LastFailMs := NowMs;
        if FastFails >= 3 then
        begin
          Err := 'connection closed by server';
          Break;
        end;
      end;
    end;

    if (not HeadersDone) and (Err = '') then
      Err := 'no response from server';
    if HeadersDone and not Is2xx then
      Err := Format('HTTP %d %s', [StatusCode, StatusText]);
  finally
    if Decoder <> nil then
      Decoder.Free;
    Transport.Free;
  end;
end;

{ --- Internal single-exchange wrappers ------------------------------------ }

function HttpRequestOnce(const Method, Url, ApiKey, Body: string;
  TimeoutMs, ConnectMs: Integer): THttpResult;
var
  H: TStringList;
  Sink: TBodyAccum;
begin
  Result.Ok := False;
  Result.StatusCode := 0;
  Result.StatusText := '';
  Result.Body := '';
  Result.Error := '';
  Result.Location := '';
  H := TStringList.Create;
  Sink := TBodyAccum.Create;
  try
    H.Add('Content-Type: application/json; charset=utf-8');
    H.Add('Accept: application/json');
    if ApiKey <> '' then
      H.Add('Authorization: Bearer ' + ApiKey);
    Result.Ok := HttpExchangeOnce(Method, Url, Body, H, TimeoutMs,
      ConnectMs, @Sink.Add, @Sink.Add, Result.StatusCode,
      Result.StatusText, Result.Error, Result.Location);
    Result.Body := Sink.Body;
  finally
    Sink.Free;
    H.Free;
  end;
end;

function HttpRequestExOnce(const Method, Url, Body: string;
  const Headers: array of string;
  TimeoutMs, ConnectMs: Integer): THttpResult;
var
  H: TStringList;
  Sink: TBodyAccum;
  I: Integer;
begin
  Result.Ok := False;
  Result.StatusCode := 0;
  Result.StatusText := '';
  Result.Body := '';
  Result.Error := '';
  Result.Location := '';
  H := TStringList.Create;
  for I := Low(Headers) to High(Headers) do
    H.Add(Headers[I]);
  Sink := TBodyAccum.Create;
  try
    Result.Ok := HttpExchangeOnce(Method, Url, Body, H, TimeoutMs,
      ConnectMs, @Sink.Add, @Sink.Add, Result.StatusCode,
      Result.StatusText, Result.Error, Result.Location);
    Result.Body := Sink.Body;
  finally
    Sink.Free;
    H.Free;
  end;
end;

{ Streaming: error body (4xx/5xx) accumulated in sink and appended to Err. }
function HttpRequestStreamOnce(const Method, Url, ApiKey, Body: string;
  TimeoutMs, ConnectMs: Integer; const OnChunk: THttpChunkHandler;
  out StatusCode: Integer; out StatusText: string; out Err: string): Boolean;
var
  H: TStringList;
  Sink: TErrBodySink;
  Loc: string;
begin
  H := TStringList.Create;
  Sink := TErrBodySink.Create;
  try
    if Method = 'POST' then
      H.Add('Content-Type: application/json; charset=utf-8');
    if ApiKey <> '' then
      H.Add('Authorization: Bearer ' + ApiKey);
    H.Add('Accept: text/event-stream');
    Result := HttpExchangeOnce(Method, Url, Body, H, TimeoutMs,
      ConnectMs, OnChunk, @Sink.Add, StatusCode, StatusText, Err, Loc);
    if (StatusCode >= 400) and (Trim(Sink.Body) <> '') then
      Err := Err + sLineBreak + Trim(Sink.Body);
  finally
    Sink.Free;
    H.Free;
  end;
end;

{ Streaming with caller headers + Accept: text/event-stream. }
function HttpRequestStreamExOnce(const Method, Url, Body: string;
  const Headers: array of string;
  TimeoutMs, ConnectMs: Integer; const OnChunk: THttpChunkHandler;
  out StatusCode: Integer; out StatusText: string; out Err: string): Boolean;
var
  H: TStringList;
  Sink: TErrBodySink;
  I: Integer;
  Loc: string;
begin
  H := TStringList.Create;
  for I := Low(Headers) to High(Headers) do
    H.Add(Headers[I]);
  H.Add('Accept: text/event-stream');
  Sink := TErrBodySink.Create;
  try
    Result := HttpExchangeOnce(Method, Url, Body, H, TimeoutMs,
      ConnectMs, OnChunk, @Sink.Add, StatusCode, StatusText, Err, Loc);
    if (StatusCode >= 400) and (Trim(Sink.Body) <> '') then
      Err := Err + sLineBreak + Trim(Sink.Body);
  finally
    Sink.Free;
    H.Free;
  end;
end;

{ --- Public wrappers: retries on transport failures and redirects ---------

  Retry only on a transport failure (no response, StatusCode = 0).
  HTTP 4xx/5xx statuses are returned to the caller without retries. A
  redirect (3xx with Location) is followed for non-streaming requests only,
  up to MAX_REDIRECTS. }

{ Same by error text — for failures already converted to a string. The
  keywords mirror the messages produced here and in mirmid.tlsclient:
  "no response from server", "connection closed by server", "request timed
  out", "could not connect to <host>:<port>" and the socket/TLS errors of
  the transport. }
function IsRetryableNetErrorText(const S: string): Boolean;
var
  T: string;
begin
  T := LowerCase(S);
  Result := (Pos('esocketerror', T) > 0) or (Pos('sslsocketerror', T) > 0) or
    (Pos('socket error', T) > 0) or (Pos('socket write error', T) > 0) or
    (Pos('connection reset', T) > 0) or (Pos('connection refused', T) > 0) or
    (Pos('connection closed', T) > 0) or (Pos('could not connect', T) > 0) or
    (Pos('connect failed', T) > 0) or (Pos('connect timeout', T) > 0) or
    (Pos('host not found', T) > 0) or (Pos('unable to connect', T) > 0) or
    (Pos('name resolution', T) > 0) or (Pos('no response', T) > 0) or
    (Pos('timed out', T) > 0) or (Pos('timeout', T) > 0) or
    (Pos('tls:', T) > 0);
end;

{ Pause before repeat number ARetry (0 — before first repeat), ms. }
function HttpRetryDelayMs(ARetry: Integer): Integer;
begin
  Result := HttpRetryBaseDelayMs;
  while (ARetry > 0) and (Result > 0) and (Result < MaxInt div 2) do
  begin
    Result := Result * 2;
    Dec(ARetry);
  end;
end;

function HttpRequest(const Method, Url, ApiKey, Body: string;
  TimeoutMs, ConnectMs: Integer): THttpResult;
var
  Attempt, Hops: Integer;
  CurUrl: string;
begin
  Result.Error := '';
  Attempt := 0;
  repeat
    CurUrl := Url;
    Hops := 0;
    repeat
      Result := HttpRequestOnce(Method, CurUrl, ApiKey, Body, TimeoutMs,
        ConnectMs);
      if (Result.StatusCode >= 300) and (Result.StatusCode < 400) and
         (Result.Location <> '') and (Hops < MAX_REDIRECTS) then
      begin
        CurUrl := HttpResolveRedirect(CurUrl, Result.Location);
        Inc(Hops);
        Continue;
      end;
      Break;
    until False;
    if (not Result.Ok) and (Result.StatusCode = 0) and
       IsRetryableNetErrorText(Result.Error) and (Attempt < HttpRetryCount) then
    begin
      Sleep(HttpRetryDelayMs(Attempt));
      Inc(Attempt);
      Continue;
    end;
    Break;
  until False;
end;

function HttpRequestEx(const Method, Url, Body: string;
  const Headers: array of string;
  TimeoutMs, ConnectMs: Integer): THttpResult;
var
  Attempt, Hops: Integer;
  CurUrl: string;
begin
  Result.Error := '';
  Attempt := 0;
  repeat
    CurUrl := Url;
    Hops := 0;
    repeat
      Result := HttpRequestExOnce(Method, CurUrl, Body, Headers, TimeoutMs,
        ConnectMs);
      if (Result.StatusCode >= 300) and (Result.StatusCode < 400) and
         (Result.Location <> '') and (Hops < MAX_REDIRECTS) then
      begin
        CurUrl := HttpResolveRedirect(CurUrl, Result.Location);
        Inc(Hops);
        Continue;
      end;
      Break;
    until False;
    if (not Result.Ok) and (Result.StatusCode = 0) and
       IsRetryableNetErrorText(Result.Error) and (Attempt < HttpRetryCount) then
    begin
      Sleep(HttpRetryDelayMs(Attempt));
      Inc(Attempt);
      Continue;
    end;
    Break;
  until False;
end;

{ Streaming request repeats only before the first response
  (StatusCode = 0): a repeat after delivered deltas would duplicate text. }
function HttpRequestStream(const Method, Url, ApiKey, Body: string;
  TimeoutMs, ConnectMs: Integer; const OnChunk: THttpChunkHandler;
  out StatusCode: Integer; out StatusText: string; out Err: string): Boolean;
var
  Attempt: Integer;
  TryCode: Integer;
  TryText, TryErr: string;
begin
  Attempt := 0;
  repeat
    Result := HttpRequestStreamOnce(Method, Url, ApiKey, Body, TimeoutMs,
      ConnectMs, OnChunk, TryCode, TryText, TryErr);
    StatusCode := TryCode;
    StatusText := TryText;
    Err := TryErr;
    if (not Result) and (TryCode = 0) and
       IsRetryableNetErrorText(TryErr) and (Attempt < HttpRetryCount) then
    begin
      Sleep(HttpRetryDelayMs(Attempt));
      Inc(Attempt);
      Continue;
    end;
    Break;
  until False;
end;

function HttpRequestStreamEx(const Method, Url, Body: string;
  const Headers: array of string;
  TimeoutMs, ConnectMs: Integer; const OnChunk: THttpChunkHandler;
  out StatusCode: Integer; out StatusText: string; out Err: string): Boolean;
var
  Attempt: Integer;
  TryCode: Integer;
  TryText, TryErr: string;
begin
  Attempt := 0;
  repeat
    Result := HttpRequestStreamExOnce(Method, Url, Body, Headers, TimeoutMs,
      ConnectMs, OnChunk, TryCode, TryText, TryErr);
    StatusCode := TryCode;
    StatusText := TryText;
    Err := TryErr;
    if (not Result) and (TryCode = 0) and
       IsRetryableNetErrorText(TryErr) and (Attempt < HttpRetryCount) then
    begin
      Sleep(HttpRetryDelayMs(Attempt));
      Inc(Attempt);
      Continue;
    end;
    Break;
  until False;
end;
end.
