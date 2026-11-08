unit mirmid.tlsclient;
{ HTTPS-клиент на верх библиотеки tls (deps/tls — pure Pascal TLS 1.2,
  https://github.com/svetodar/tls) + TCP-сокета ssockets. Вместо системного
  OpenSSL: юниты fphttpclient, opensslsockets, sslsockets не используются,
  юнит mirmid.openssl удалён.

  Юнит даё одно абстращи для mirmid.http — «transport» one HTTP-connection:
    plain TCP (scheme http) или TLS 1.2 (https). Semantics Read:
    >0 — byte count; 0 — EOF (server closed connection); <0 — timeout/error.
  HTTP-framing (status line, headers, chunked) — job of mirmid.http.

  Грабли: юнит реализи interface ITLSTransport. В FPC reference к interface
  counted (com3), поэтому field держав reference типом `ITLSTransport`,
  не типом конкрет class — иначе refcount drop 0 после первой call и object
  freed (access violation). Состоя «reason послед failure» passed through
  unit variable TLSLastReadReason. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ssockets,
  tls.tls12, tls.prf, tls.rand, tls.hmac, tls.asn1, tls.x509, tls.certstore,
  tls.roottable, tls.roots;

const
  { Maximum plaintext of one TLS record (RFC 5246, 6.2.1). }
  MAX_TLS_RECORD_PLAIN = 1 shl 14;

type
  { Transport TLS over TCP-socket: реализо interface ITLSTransport
    (Read/Write/BytesAvailable) поверх TInetSocket. Seбаб послед failure
    (0 — ok, -1 — таймаут/ошибка socket, 1 — EOF) writes to TLSLastReadReason,
    because object accessed only through interface reference. }
  TSocketTlsTransport = class(TInterfacedObject, ITLSTransport)
  private
    FSocket: TInetSocket;
  public
    constructor Create(ASock: TInetSocket);
    function Read(var ABuffer; ACount: LongInt): LongInt;
    function Write(const ABuffer; ACount: LongInt): LongInt;
    function BytesAvailable: LongInt;
  end;

  { Transport one HTTP-connection: plain TCP (http) or TLS 1.2 (https).
    Connect — TCP + (for https) handshake TLS 1.2; Send — request;
    Read — plaintext decrypted response. LastError — reason failure. }
  THttpTransport = class
  private
    FTls: Boolean;
    FSocket: TInetSocket;
    FHandler: TSocketHandler;
    FTrans: ITLSTransport;       { reference to TLS transport (refcounted) }
    FMode: TTLSAEADMode;
    FKey, FIV: TBytes;           { server keys (read) }
    FClientKey, FClientIV: TBytes;
    FSeqServer, FSeqClient: QWord;
    FPlainBuf: RawByteString;    { decrypted plaintext, not consumed }
    FPlainPos: Integer;
    FEnded: Boolean;
    FErrText: string;
    function NextPlainRecord: Integer;  { 1 — data; 0 — end; -1 — timeout }
    function DoHandshake(const AHost, ACaFile: string): Boolean;
  public
    constructor Create(ASecure: Boolean);
    destructor Destroy; override;
    { Connect: TCP + handshake TLS 1.2 (for https). Источник доверия:
      ACAFile — явно заданный PEM-бандл (ca_file из конфига); пустой путь —
      встроенный в exe снимок корней (tls.roots), а если его нет — системное
      хранилище ОС (Windows). Автопоиска PEM-бандла рядом с программой нет:
      явный ca_file без файла и отсутствие хоть какого-то хранилища — ошибка
      без тихого отката. Возвращает False + LastError. }
    function Connect(const AHost: string; APort: Integer;
      AConnectTimeoutMs, AIOTimeoutMs: Integer;
      const ACAFile: string): Boolean;
    { Send request (headers + body): for TLS — fragmenting records. }
    function Send(const AData: RawByteString): Boolean;
    { Read plaintext: >0 — count, 0 — EOF, <0 — timeout. }
    function Read(var ABuffer; ACount: LongInt): LongInt;
    property LastError: string read FErrText;
  end;

  { Источник доверенных корневых сертификатов для проверки цепочки TLS. }
  TTrustStoreSource = (
    tssEmbedded,  { встроенный в exe снимок корней (tls.roots, RT_RCDATA) }
    tssSystem,    { системное хранилище ОС (Windows CryptoAPI) }
    tssBundle,    { PEM-бандл, заданный явно через ca_file }
    tssMissing    { хранилища нет: ca_file не задан либо файл не найден }
  );

  { Решение о trust store. Path заполнен только для tssBundle;
    Explicit — ca_file был задан пользователем явно. }
  TTrustStoreChoice = record
    Source: TTrustStoreSource;
    Path: string;
    Explicit: Boolean;
  end;
  { Диагностика встроенного снимка корней (tls.roots) для CLI: доступен ли
    снимок, на какую дату он снят и не устарел ли. Available = False —
    снимка нет (сборка без tlsroots.res или с -dTLS_NO_EMBEDDED_ROOTS, либо
    ресурс повреждён); тогда SnapshotDate = 0, а причина лежит в ErrText.
    Stale — только флаг, проверка цепочки с устаревшим снимком работает. }
  TEmbeddedRootsInfo = record
    Available: Boolean;
    SnapshotDate: TDateTime;  { дата снимка (UTC, без времени); 0 — нет снимка }
    Stale: Boolean;           { возраст больше MaxAgeDays }
    MaxAgeDays: LongInt;      { порог, с которым считался Stale }
    ErrText: string;          { причина недоступности/сбоя; '' — всё хорошо }
  end;


var
  { Причина последнего сбоя TLS-transport: 0 — ok, -1 — таймаут/ошибка,
    1 — EOF. Set by TSocketTlsTransport.Read. }
  TLSLastReadReason: Integer = 0;

{ Чистый выбор источника trust store: без обращения к файловой системе,
  окружению и платформе — наличие файлов и ресурсов передаётся флагами.
  ACAFile — ca_file из конфига ('' — не задан); AEmbeddedAvailable — доступен
  ли встроенный снимок корней (tls.roots); AAllowSystemStore — доступно ли
  системное хранилище ОС (Windows); AExplicitExists — существует ли файл по
  ca_file. Порядок доверия: явно заданный ca_file с файлом — tssBundle; явно
  заданный ca_file без файла — tssMissing (без тихого отката на другое
  хранилище, иначе опечатка в пути осталась бы незамеченной); при пустом
  ca_file — tssEmbedded, если снимок доступен, иначе tssSystem при доступном
  системном хранилище, иначе tssMissing (делать проверку нечем — ошибка
  конфигурации, решает вызывающий). }
function SelectTrustStore(const ACAFile: string;
  AEmbeddedAvailable, AAllowSystemStore,
  AExplicitExists: Boolean): TTrustStoreChoice;
const
  { Порог устаревания встроенного снимка корней по умолчанию, дней. Дата
    снимка фиксируется при `make roots`; корни живут годами, поэтому год без
    обновления — повод предупредить, а не ошибка. }
  EMBEDDED_ROOTS_MAX_AGE_DAYS = 365;

{ Диагностика встроенного снимка корней без исключений: читает ресурс через
  tls.roots (лениво, один раз на процесс) и возвращает доступность, дату
  снимка и флаг устаревания. Никогда не бросает: сбой чтения/разбора попадает
  в ErrText, Available = False. Служит для предупреждений CLI при старте и
  перед HTTPS; на выбор trust store не влияет (его делает SelectTrustStore).

  AMaxAgeDays — порог устаревания в днях (по умолчанию
  EMBEDDED_ROOTS_MAX_AGE_DAYS); отрицательное значение —
  EArgumentOutOfRangeException (проверку делает tls.roots). }
function GetEmbeddedRootsInfo(
  AMaxAgeDays: LongInt = EMBEDDED_ROOTS_MAX_AGE_DAYS): TEmbeddedRootsInfo;

{ Текст диагностики снимка для предупреждений CLI. Снимок есть:
  «встроенный снимок корней от 2026-06-01 (144 дн., устарел: порог 365 дн.)»
  либо без пометки об устаревании; снимка нет: «встроенный снимок корней
  недоступен (<причина>)». }
function EmbeddedRootsInfoText(const AInfo: TEmbeddedRootsInfo): string;

implementation

{ --- Helpers: string <-> TBytes (library does not export these) --- }

function StrBytes(const S: RawByteString): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Byte(Ord(S[I]));
end;

function BytesToStr(const B: TBytes): RawByteString;
var
  I: Integer;
begin
  SetLength(Result, Length(B));
  for I := 0 to High(B) do
    Result[I + 1] := AnsiChar(B[I]);
end;

{ --- SelectTrustStore --- }

function SelectTrustStore(const ACAFile: string;
  AEmbeddedAvailable, AAllowSystemStore,
  AExplicitExists: Boolean): TTrustStoreChoice;
begin
  Result.Source := tssMissing;
  Result.Path := '';
  Result.Explicit := ACAFile <> '';
  if Result.Explicit then
  begin
    { Явный ca_file: отката на другое хранилище нет — иначе опечатка в пути
      молча осталась бы незамеченной. }
    if AExplicitExists then
    begin
      Result.Source := tssBundle;
      Result.Path := ACAFile;
    end;
    Exit;
  end;
  { Порядок доверия без явного ca_file: встроенный снимок корней (не зависит
    от ОС, файлов рядом с exe и состояния системного хранилища), затем
    системное хранилище ОС. }
  if AEmbeddedAvailable then
    Result.Source := tssEmbedded
  else if AAllowSystemStore then
    Result.Source := tssSystem;
end;

{ --- Доступность встроенного снимка корней --- }

var
  { Кэш «встроенный снимок корней доступен»: tls.roots читает и разбирает
    ресурс лениво один раз на процесс, поэтому повторные HTTPS-соединения
    проверку не повторяют. Снимка нет, когда exe собран без tlsroots.res или
    с -dTLS_NO_EMBEDDED_ROOTS, либо ресурс повреждён (не сошлась SHA-256). }
  GEmbeddedRootsChecked: Boolean = False;
  GEmbeddedRootsUsable: Boolean = False;
  GEmbeddedRootsErr: string = '';
  { Дата прочитанного снимка (0 — снимка нет). Кэшируется вместе с флагом
    доступности: ресурс разбирается один раз на процесс. }
  GEmbeddedRootsDateVal: TDateTime = 0;

function EmbeddedRootsUsable: Boolean;
begin
  if not GEmbeddedRootsChecked then
  begin
    GEmbeddedRootsUsable := False;
    GEmbeddedRootsErr := '';
    GEmbeddedRootsDateVal := 0;
    try
      { Стор возвращает и кэширует сам юнит tls.roots — освобождать нельзя. }
      EmbeddedRoots;
      { EmbeddedRootsDate берёт таблицу из того же кэша tls.roots, так что
        повторного чтения ресурса нет. }
      GEmbeddedRootsDateVal := EmbeddedRootsDate;
      GEmbeddedRootsUsable := True;
    except
      on E: Exception do
      begin
        GEmbeddedRootsErr := E.Message;
        GEmbeddedRootsUsable := False;
        GEmbeddedRootsDateVal := 0;
      end;
    end;
    GEmbeddedRootsChecked := True;
  end;
  Result := GEmbeddedRootsUsable;
end;

{ --- Диагностика встроенного снимка корней (для предупреждений CLI) --- }

function GetEmbeddedRootsInfo(AMaxAgeDays: LongInt): TEmbeddedRootsInfo;
begin
  { Отрицательный порог — ошибка вызывающего; проверку делает tls.roots,
    пробрасываем её исключение как есть (доступность снимка тут ни при чём). }
  if AMaxAgeDays < 0 then
    raise EArgumentOutOfRangeException.Create('AMaxAgeDays');

  Result.Available := EmbeddedRootsUsable;
  Result.SnapshotDate := 0;
  Result.Stale := False;
  Result.MaxAgeDays := AMaxAgeDays;
  Result.ErrText := '';
  if not Result.Available then
  begin
    Result.ErrText := GEmbeddedRootsErr;
    Exit;
  end;

  Result.SnapshotDate := GEmbeddedRootsDateVal;
  try
    { Порог и арифметику возраста держит tls.roots: не дублируем её здесь,
      иначе два места разойдутся. }
    Result.Stale := EmbeddedRootsIsStale(Now, AMaxAgeDays);
  except
    on E: Exception do
    begin
      { Снимок доступен, но возраст посчитать не удалось — это диагностика,
        поэтому не роняем вызывающего, а показываем причину. }
      Result.ErrText := E.Message;
      Result.Stale := False;
    end;
  end;
end;

function EmbeddedRootsInfoText(const AInfo: TEmbeddedRootsInfo): string;
var
  AgeDays: Integer;
begin
  if not AInfo.Available then
  begin
    Result := 'встроенный снимок корней недоступен';
    if AInfo.ErrText <> '' then
      Result := Result + ' (' + AInfo.ErrText + ')';
    Exit;
  end;

  { Возраст считаем по календарным дням: дата снимка — UTC без времени, а
    Now — локальное время; разница в часах на глаз не видна, а «144 дн.»
    читается лучше, чем дробное число. }
  AgeDays := Trunc(Int(Now)) - Trunc(Int(AInfo.SnapshotDate));
  if AgeDays < 0 then
    AgeDays := 0;
  Result := 'встроенный снимок корней от ' +
    FormatDateTime('yyyy-mm-dd', AInfo.SnapshotDate) +
    Format(' (%d дн.', [AgeDays]);
  if AInfo.Stale then
    Result := Result + Format(', устарел: порог %d дн.', [AInfo.MaxAgeDays])
  else if AInfo.MaxAgeDays > 0 then
    Result := Result + Format(', порог %d дн.', [AInfo.MaxAgeDays]);
  Result := Result + ')';
  if AInfo.ErrText <> '' then
    Result := Result + ' (' + AInfo.ErrText + ')';
end;

{$ifdef windows}
var
  { Ленивый кэш системного хранилища Windows: Root/CA перебираются через
    crypt32 один раз при первом обращении и живут до finalization юнита,
    поэтому каждое новое HTTPS-соединение не парсит сотни сертификатов
    заново. Хранилище разделяемое: владелец — юнит, вызывающий не должен
    освобождать возвращённый указатель. }
  GSystemTrustStore: TCertStore = nil;

{ Вернуть системное хранилище доверия (только Windows), загрузив его при
  первом обращении; повторный вызов возвращает тот же экземпляр. Ошибки
  загрузки (TWinCertStoreError/EASN1Error) не кэшируются — следующий вызов
  повторит попытку. Владелец результата — юнит (см. finalization). }
function GetSystemTrustStore: TCertStore;
begin
  if GSystemTrustStore = nil then
    GSystemTrustStore := LoadWindowsSystemStore;
  Result := GSystemTrustStore;
end;
{$endif windows}
{ --- TSocketTlsTransport --- }

constructor TSocketTlsTransport.Create(ASock: TInetSocket);
begin
  inherited Create;
  FSocket := ASock;
end;

function TSocketTlsTransport.Read(var ABuffer; ACount: LongInt): LongInt;
begin
  TLSLastReadReason := 0;
  Result := FSocket.Read(ABuffer, ACount);
  if Result = 0 then
    TLSLastReadReason := 1
  else if Result < 0 then
    TLSLastReadReason := -1;
end;

function TSocketTlsTransport.Write(const ABuffer; ACount: LongInt): LongInt;
begin
  Result := FSocket.Write(ABuffer, ACount);
end;

function TSocketTlsTransport.BytesAvailable: LongInt;
begin
  { Protocol code does not use this method (only Read/Write). }
  Result := 0;
end;

{ --- THttpTransport --- }

constructor THttpTransport.Create(ASecure: Boolean);
begin
  inherited Create;
  FTls := ASecure;
  FSocket := nil;
  FHandler := nil;
  FTrans := nil;
  FSeqServer := 0;
  FSeqClient := 0;
  FPlainBuf := '';
  FPlainPos := 1;
  FEnded := False;
  FErrText := '';
end;

destructor THttpTransport.Destroy;
begin
  { Interface reference: assigning nil releases (refcount). }
  FTrans := nil;
  { Handler освобождает сам TSocketStream (FreeAndNil в своём деструкторе),
    поэтому при живом сокете здесь только забываем ссылку — иначе double free. }
  if FSocket <> nil then
  begin
    FHandler := nil;
    FSocket.Free;    { closes socket }
    FSocket := nil;
  end
  else
  begin
    { Сокет не создался (исключение в TInetSocket.Create) — владелец мы. }
    FHandler.Free;
    FHandler := nil;
  end;
  inherited Destroy;
end;

{ Read next application record and decrypt. Result: 1 — FPlainBuf new;
  0 — stream ended; -1 — timeout (socket remains working). }
function THttpTransport.NextPlainRecord: Integer;
var
  Rec: TTLSRecord;
  Plain: TBytes;
begin
  Result := 0;
  while True do
  begin
    try
      Rec := ReadTLSRecord(FTrans);
    except
      on E: ETLS12Error do
      begin
        { Distinguish timeout (retry) from EOF (connection closed). }
        if TLSLastReadReason < 0 then
          Exit(-1);
        FEnded := True;
        Exit(0);
      end;
    end;
    if Rec.ContentType = ctAlert then
    begin
      { close_notify: server closed stream. }
      FEnded := True;
      Exit(0);
    end;
    if Rec.ContentType <> ctApplicationData then
      Continue;
    if not TLSAEADDecryptFragment(FMode, FKey, FIV, FSeqServer,
      Rec.ContentType, Rec.Version, Rec.Fragment, Plain) then
    begin
      FErrText := 'TLS: failed to decrypt server record (bad tag)';
      FEnded := True;
      Exit(0);
    end;
    Inc(FSeqServer);
    FPlainBuf := BytesToStr(Plain);
    FPlainPos := 1;
    Exit(1);
  end;
end;

function THttpTransport.Read(var ABuffer; ACount: LongInt): LongInt;
var
  P: PByte;
  Got, S: Integer;
begin
  Result := 0;
  if not FTls then
  begin
    { Plain TCP: socket already has these semantics (>0/0/<0). }
    Exit(FSocket.Read(ABuffer, ACount));
  end;
  if FEnded or (ACount <= 0) then
    Exit(0);
  P := @ABuffer;
  Got := 0;
  while Got < ACount do
  begin
    if FPlainPos > Length(FPlainBuf) then
    begin
      if FEnded then
        Break;
      S := NextPlainRecord;
      if S < 0 then
      begin
        if Got = 0 then
          Result := -1
        else
          Result := Got;
        Exit;
      end;
      if S = 0 then
        Break;
    end;
    while (Got < ACount) and (FPlainPos <= Length(FPlainBuf)) do
    begin
      P[Got] := Byte(Ord(FPlainBuf[FPlainPos]));
      Inc(FPlainPos);
      Inc(Got);
    end;
  end;
  Result := Got;
end;

{ Send request: for TLS — fragmenting records ≤ 2^14 bytes, each
  with own seq_num (RFC 5246, 6.2.3). }
function THttpTransport.Send(const AData: RawByteString): Boolean;
var
  Raw, Part, Frag: TBytes;
  Off, Total, Chunk: Integer;
begin
  Result := False;
  if Length(AData) = 0 then
    Exit(True);
  if not FTls then
  begin
    try
      FSocket.WriteBuffer(AData[1], Length(AData));
      Result := True;
    except
      on E: Exception do
        FErrText := 'socket write error: ' + E.Message;
    end;
    Exit;
  end;
  Raw := StrBytes(AData);
  Off := 0;
  Total := Length(Raw);
  try
    while Off < Total do
    begin
      Chunk := Total - Off;
      if Chunk > MAX_TLS_RECORD_PLAIN then
        Chunk := MAX_TLS_RECORD_PLAIN;
      SetLength(Part, Chunk);
      Move(Raw[Off], Part[0], Chunk);
      Frag := TLSAEADEncryptFragment(FMode, FClientKey, FClientIV,
        FSeqClient, ctApplicationData, TLS12Version, Part);
      { Encrypted fragment = plaintext + explicit nonce + AEAD tag, so the
        record limit is 2^14+2048 (RFC 5246, 6.2.3), not the plaintext 2^14. }
      WriteTLSRecord(FTrans, ctApplicationData, Frag, TLS12Version,
        TLSRecordMaxCiphertext);
      Inc(FSeqClient);
      Inc(Off, Chunk);
    end;
    Result := True;
  except
    on E: ETLS12Error do
      FErrText := 'TLS: ' + E.Message;
    on E: ESocketError do
      FErrText := 'socket write error: ' + E.Message;
  end;
end;

{ Handshake TLS 1.2: ClientHello -> ServerHello/Certificate/
  ServerKeyExchange/ServerHelloDone -> verify -> ClientKeyExchange ->
  CCS/Finished. Sequence matches test_tls12_e2e of library tls.
  ACaFile — явно заданный PEM-бандл доверия (владеем, Free в finally);
  пустая строка — встроенный снимок корней (tls.roots) либо, если его нет,
  системное хранилище ОС (только Windows): оба — кэши уровня юнита, их не
  освобождаем. Автопоиска бандла рядом с программой больше нет. }
function THttpTransport.DoHandshake(const AHost, ACaFile: string): Boolean;
var
  ClientRandom, HelloBody, CKEBody, Premaster, SessionHash, Master: TBytes;
  ClientVD, FinishedBody, FinMsg, Frag, Plain: TBytes;
  Options: TTLSClientHelloOptions;
  Buffer: TTLSHandshakeBuffer;
  ServerMsgs: TTLSHandshakeMessages;
  Hello: TTLSServerHello;
  CertMsg: TTLSCertificateMessage;
  SKE: TTLSServerKeyExchange;
  HasCert, HasSKE: Boolean;
  Chain: TTLS12CertChain;
  Store: TCertStore;
  OwnsStore: Boolean;             { Store загружен нами (PEM-бандл) и требует Free }
  EmbeddedErr: string;            { причина, по которой встроенный снимок не читается }
  SysStoreErr: string;            { причина сбоя системного хранилища Windows (Windows) }
  VR: TVerifyResult;
  EKey: TTLS12ECDHEClientKey;
  DKey: TTLS12DHEClientKey;
  KB: TTLS12KeyBlock;
  HashKind: THashKind;
  Rec: TTLSRecord;
  Fin: TTLSHandshakeMessage;
begin
  Result := False;
  Chain := nil;
  Buffer := nil;
  Store := nil;
  OwnsStore := False;
  FTrans := TSocketTlsTransport.Create(FSocket);
  try
    try
      { --- ClientHello --- }
      RandomBytes(ClientRandom, 32);
      Options := DefaultTLS12ClientHelloOptions;
      Options.ServerName := AHost;
      Options.ClientRandom := ClientRandom;
      Buffer := TTLSHandshakeBuffer.Create;
      HelloBody := BuildTLS12ClientHelloBody(Options);
      WriteTLSHandshakeMessage(FTrans, htClientHello, HelloBody);
      Buffer.AppendTranscript(htClientHello, HelloBody);

      { --- Server flight --- }
      if not ReadTLSHandshakeFlight(FTrans, Buffer,
        [htServerHelloDone], ServerMsgs) then
        raise ETLS12Error.Create('server closed connection before ServerHelloDone');
      if not ParseTLS12ServerFlight(ServerMsgs, Hello, CertMsg, SKE,
        HasCert, HasSKE) then
        raise ETLS12Error.Create('failed to parse server flight');
      if not HasCert then
        raise ETLS12Error.Create('server did not send Certificate');
      if not HasSKE then
        raise ETLS12Error.Create('server did not send ServerKeyExchange');
      if not TLS12CipherSuiteSupported(Hello.CipherSuite) then
        raise ETLS12Error.CreateFmt(
          'server selected unsupported suite %x (only AEAD ECDHE/DHE)',
          [Hello.CipherSuite]);

      { --- Verify certificate chain and host --- }
      Chain := ParseTLS12CertChain(CertMsg);
      { Источник доверия — в том же порядке, что в Connect/SelectTrustStore:
        явный ca_file (PEM-бандл; владеем, Free в finally) → встроенный снимок
        корней tls.roots → системное хранилище ОС. Встроенный снимок и
        системное хранилище — ленивые кэши уровня юнита, освобождать их нельзя
        (OwnsStore остаётся False). Тихих откатов нет: если и снимок, и
        системное хранилище недоступны, это ошибка с подсказкой задать ca_file. }
      Store := nil;
      if ACaFile <> '' then
      begin
        Store := LoadBundle(ACaFile);
        OwnsStore := True;
      end
      else
      begin
        EmbeddedErr := '';
        try
          Store := EmbeddedRoots;
        except
          on E: Exception do
            EmbeddedErr := E.Message;
        end;
        if Store = nil then
        begin
          {$ifdef windows}
          SysStoreErr := '';
          try
            Store := GetSystemTrustStore;
          except
            on E: TWinCertStoreError do
              SysStoreErr := E.Message;
            on E: EASN1Error do
              SysStoreErr := E.Message;
          end;
          if Store = nil then
            raise ETLS12Error.Create(
              'хранилище доверия недоступно: встроенный снимок корней не ' +
              'читается (' + EmbeddedErr + '), системное хранилище Windows — ' +
              SysStoreErr + '; задайте ca_file в секции [llm] INI или в ' +
              'переменной MIRMID_CA_FILE');
          {$else}
          raise ETLS12Error.Create(
            'хранилище доверия недоступно: встроенный снимок корней не ' +
            'читается (' + EmbeddedErr + '); задайте ca_file в секции [llm] INI ' +
            'или в переменной MIRMID_CA_FILE (системное хранилище ОС доступно ' +
            'только на Windows)');
          {$endif}
        end;
      end;
      VR := Chain.Verify(Store);
      if not VR.OK then
        raise ETLS12Error.Create('certificate chain verification failed: ' +
          VR.Reason);
      if not CertMatchesHost(Chain.Leaf, AHost) then
        raise ETLS12Error.CreateFmt(
          'certificate does not match host %s', [AHost]);
      if not VerifyTLS12ServerKeyExchange(Chain, ClientRandom,
        Hello.ServerRandom, SKE) then
        raise ETLS12Error.Create('signature of ServerKeyExchange is invalid');

      { --- ClientKeyExchange --- }
      if SKE.Algorithm = keaECDHE then
      begin
        EKey := TTLS12ECDHEClientKey.Create(SKE.NamedCurve);
        try
          CKEBody := EKey.ClientKeyExchangeBody;
          Premaster := EKey.PremasterSecret(SKE.ECDHEPublicKey);
        finally
          EKey.Free;
        end;
      end
      else if SKE.Algorithm = keaDHE then
      begin
        DKey := TTLS12DHEClientKey.Create;
        try
          DKey.InitFromServerParams(SKE.DHPrime, SKE.DHGenerator);
          CKEBody := DKey.ClientKeyExchangeBody;
          Premaster := DKey.PremasterSecret(SKE.DHPublic);
        finally
          DKey.Free;
        end;
      end
      else
        raise ETLS12Error.Create('unsupported key exchange algorithm');
      WriteTLSHandshakeMessage(FTrans, htClientKeyExchange, CKEBody);
      Buffer.AppendTranscript(htClientKeyExchange, CKEBody);

      { --- Keys --- }
      HashKind := TLS12CipherSuiteHashKind(Hello.CipherSuite);
      FMode := TLS12CipherSuiteAEADMode(Hello.CipherSuite);
      if Hello.ExtendedMasterSecret then
      begin
        SessionHash := TLS12TranscriptHash(HashKind, Buffer.Transcript);
        Master := TLS12ExtendedMasterSecret(HashKind, Premaster, SessionHash);
      end
      else
        Master := TLS12MasterSecret(HashKind, Premaster, ClientRandom,
          Hello.ServerRandom);
      KB := TLS12KeyBlock(HashKind, Master, Hello.ServerRandom, ClientRandom,
        0, TLSAEADKeyLength(FMode), TLSAEADFixedIvLength(FMode));
      FKey := KB.ServerWriteKey;
      FIV := KB.ServerWriteIV;
      FClientKey := KB.ClientWriteKey;
      FClientIV := KB.ClientWriteIV;

      { --- Client CCS + Finished (seq = 0) --- }
      ClientVD := TLS12VerifyData(HashKind, Master, TLSFinishedLabelClient,
        Buffer.Transcript);
      FinishedBody := EncodeTLS12FinishedBody(ClientVD);
      Buffer.AppendTranscript(htFinished, FinishedBody);
      FinMsg := BuildTLS12Finished(ClientVD);
      WriteTLS12ChangeCipherSpec(FTrans);
      Frag := TLSAEADEncryptFragment(FMode, FClientKey, FClientIV,
        QWord(0), ctHandshake, TLS12Version, FinMsg);
      WriteTLSRecord(FTrans, ctHandshake, Frag, TLS12Version,
        TLSRecordMaxCiphertext);

      { --- Server CCS + Finished --- }
      ReadTLS12ChangeCipherSpec(FTrans);
      Rec := ReadTLSRecord(FTrans);
      if Rec.ContentType <> ctHandshake then
        raise ETLS12Error.Create('expected handshake record after CCS');
      if not TLSAEADDecryptFragment(FMode, FKey, FIV, QWord(0),
        Rec.ContentType, Rec.Version, Rec.Fragment, Plain) then
        raise ETLS12Error.Create('failed to decrypt server Finished');
      Fin := DecodeTLSHandshakeMessage(Plain);
      if Fin.MsgType <> htFinished then
        raise ETLS12Error.Create('server did not send Finished');
      if not TLS12VerifyFinished(HashKind, Master, TLSFinishedLabelServer,
        Buffer.Transcript, ParseTLS12FinishedBody(Fin.Body)) then
        raise ETLS12Error.Create('server VerifyData mismatch');

      { Application data starts with seq = 1 in both directions. }
      FSeqServer := 1;
      FSeqClient := 1;
      Result := True;
    except
      on E: ETLS12Error do
        FErrText := 'TLS: ' + E.Message;
      on E: EASN1Error do
        FErrText := 'хранилище доверия: ' + E.Message;
      on E: ESocketError do
        FErrText := 'socket: ' + E.Message;
      on E: Exception do
        FErrText := E.ClassName + ': ' + E.Message;
    end;
  finally
    if Chain <> nil then Chain.Free;
    if Buffer <> nil then Buffer.Free;
    { Встроенный снимок корней и системное хранилище (OwnsStore = False) —
      разделяемые кэши юнитов tls.roots / mirmid.tlsclient, их освобождают
      finalization-секции, здесь только забываем ссылку. }
    if OwnsStore and (Store <> nil) then Store.Free;
  end;
end;

function THttpTransport.Connect(const AHost: string; APort: Integer;
  AConnectTimeoutMs, AIOTimeoutMs: Integer;
  const ACAFile: string): Boolean;
var
  AllowSystem: Boolean;
  Choice: TTrustStoreChoice;
begin
  Result := False;
  FErrText := '';
  try
    FHandler := TSocketHandler.Create;
    { Handler passed explicitly: constructor with handler does not connect
      itself (unlike 2-arg constructor), timeout applied in Connect. }
    FSocket := TInetSocket.Create(AHost, APort, AConnectTimeoutMs, FHandler);
  except
    on E: Exception do
    begin
      FErrText := 'could not connect to ' + AHost + ':' + IntToStr(APort) +
        ': ' + E.Message;
      Exit(False);
    end;
  end;
  if AConnectTimeoutMs > 0 then
    FSocket.ConnectTimeout := AConnectTimeoutMs;
  if AIOTimeoutMs > 0 then
    FSocket.IOTimeout := AIOTimeoutMs;
  try
    FSocket.Connect;
  except
    on E: Exception do
    begin
      FErrText := 'could not connect to ' + AHost + ':' + IntToStr(APort) +
        ': ' + E.Message;
      Exit(False);
    end;
  end;

  if not FTls then
    Exit(True);

   { Выбор источника доверия — до handshake. Порядок: явный ca_file →
     встроенный снимок корней → системное хранилище ОС → ошибка. Явно заданный
     ca_file без файла даёт ошибку «файл не найден» (без тихого отката и без
     автопоиска PEM-бандла рядом с exe). }
   AllowSystem := False;
   {$ifdef windows}
   AllowSystem := True;
   {$endif}
   Choice := SelectTrustStore(ACAFile, EmbeddedRootsUsable, AllowSystem,
     (ACAFile <> '') and FileExists(ACAFile));
   if Choice.Source = tssMissing then
   begin
     if Choice.Explicit then
       FErrText := 'хранилище доверия: файл ca_file не найден (' + ACAFile + ')'
     else
     begin
       { Пустой ca_file и нет встроенного снимка; на Windows системное
         хранилище подхватилось бы в SelectTrustStore, так что сюда попадаем
         только на прочих платформах. Причину недоступности снимка показываем
         как есть — иначе диагноз «сборка без tlsroots.res» не виден. }
       FErrText := 'хранилище доверия не настроено: встроенный снимок корней ' +
         'недоступен';
       if GEmbeddedRootsErr <> '' then
         FErrText := FErrText + ' (' + GEmbeddedRootsErr + ')';
       {$ifndef windows}
       FErrText := FErrText +
         '; системное хранилище ОС доступно только на Windows';
       {$endif}
       FErrText := FErrText + '; задайте ca_file в секции [llm] INI или в ' +
         'переменной MIRMID_CA_FILE';
     end;
     Exit(False);
   end;
  { tssBundle — Path указывает на файл; tssEmbedded и tssSystem — пустая
    строка (DoHandshake возьмёт встроенный снимок или системное хранилище). }
  Result := DoHandshake(AHost, Choice.Path);
end;


finalization
  {$ifdef windows}
  { Освобождаем разделяемый кэш системного хранилища (см. GetSystemTrustStore). }
  FreeAndNil(GSystemTrustStore);
  {$endif windows}
end.
