unit mirmid.tlsclient;
{ HTTPS client on top of the tls library (deps/tls — pure Pascal TLS 1.2,
  https://github.com/svetodar/tls) + TCP sockets from ssockets. Instead of the
  system OpenSSL: the units fphttpclient, opensslsockets, sslsockets are not
  used, the unit mirmid.openssl is gone.

  The unit gives mirmid.http one abstraction for the transport of a single
  HTTP-connection:
    plain TCP (scheme http) or TLS 1.2 (https). Semantics of Read:
    >0 — byte count; 0 — EOF (server closed connection); <0 — timeout/error.
  HTTP-framing (status line, headers, chunked) is the job of mirmid.http.

  Pitfall: the unit implements the interface ITLSTransport. In FPC an interface
  reference is refcounted (com3), so a field must hold the reference with type
  `ITLSTransport`, not the concrete class — otherwise the refcount drops to 0
  after the first call and the object is freed (access violation). The state
  "reason of the last failure" is passed through the unit variable
  TLSLastReadReason. }

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
  { TLS transport over a TCP socket: implements the interface ITLSTransport
    (Read/Write/BytesAvailable) on top of TInetSocket. The reason of the last
    failure (0 — ok, -1 — socket timeout/error, 1 — EOF) is written to
    TLSLastReadReason, because the object is accessed only through the
    interface reference. }
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
    function DoHandshake(const AHost: string): Boolean;
  public
    constructor Create(ASecure: Boolean);
    destructor Destroy; override;
    { Connect: TCP + handshake TLS 1.2 (for https). Trust source: the root
      snapshot embedded into the exe (tls.roots), and if it is missing — the OS
      store (Windows only). There is no auto-discovery of a PEM bundle next to
      the program and no external bundle is plugged in; if neither store is
      available this is an error, never a silent fallback. Returns False +
      LastError. }
    function Connect(const AHost: string; APort: Integer;
      AConnectTimeoutMs, AIOTimeoutMs: Integer): Boolean;
    { Send request (headers + body): for TLS — fragmenting records. }
    function Send(const AData: RawByteString): Boolean;
    { Read plaintext: >0 — count, 0 — EOF, <0 — timeout. }
    function Read(var ABuffer; ACount: LongInt): LongInt;
    property LastError: string read FErrText;
  end;

  { Source of the trusted root certificates used to verify a TLS chain. }
  TTrustStoreSource = (
    tssEmbedded,  { root snapshot embedded into the exe (tls.roots, RT_RCDATA) }
    tssSystem,    { OS store (Windows CryptoAPI) }
    tssMissing    { no store: snapshot unavailable and no system store }
  );

  { Diagnostics of the embedded root snapshot (tls.roots) for the CLI: is the
    snapshot available, at which date it was taken and whether it is stale.
    Available = False means there is no snapshot (built without tlsroots.res or
    with -dTLS_NO_EMBEDDED_ROOTS, or the resource is damaged); then
    SnapshotDate = 0 and the reason is kept in ErrText. Stale is only a flag:
    chain verification still works with a stale snapshot. }
  TEmbeddedRootsInfo = record
    Available: Boolean;
    SnapshotDate: TDateTime;  { snapshot date (UTC, date only); 0 — no snapshot }
    Stale: Boolean;           { older than MaxAgeDays }
    MaxAgeDays: LongInt;      { threshold used to compute Stale }
    ErrText: string;          { reason of the failure; '' — all good }
  end;


var
  { Reason of the last TLS-transport failure: 0 — ok, -1 — timeout/error,
    1 — EOF. Set by TSocketTlsTransport.Read. }
  TLSLastReadReason: Integer = 0;

{ Pure selection of the trust store source: no file system and no environment
  access — the availability of the stores is passed in as flags.
  AEmbeddedAvailable — the embedded root snapshot (tls.roots) is available;
  AAllowSystemStore — the OS store (Windows) is available. Trust order: the
  embedded root snapshot first, then the OS store; if neither exists this is
  tssMissing (nothing to verify the chain with — an error, the caller decides). }
function SelectTrustStore(AEmbeddedAvailable,
  AAllowSystemStore: Boolean): TTrustStoreSource;
const
  { Default staleness threshold of the embedded root snapshot, in days. The
    snapshot date is fixed by `make roots`; roots live for years, so a year
    without an update is a reason to warn, not an error. }
  EMBEDDED_ROOTS_MAX_AGE_DAYS = 365;

{ Diagnostics of the embedded root snapshot without exceptions: reads the
  resource through tls.roots (lazily, once per process) and returns the
  availability, the snapshot date and the staleness flag. Never raises: a read
  or parse failure lands in ErrText with Available = False. Used for CLI
  warnings at startup and before HTTPS; it does not influence the trust store
  choice (SelectTrustStore does that).

  AMaxAgeDays — staleness threshold in days (EMBEDDED_ROOTS_MAX_AGE_DAYS by
  default); a negative value raises EArgumentOutOfRangeException (the check is
  done by tls.roots). }
function GetEmbeddedRootsInfo(
  AMaxAgeDays: LongInt = EMBEDDED_ROOTS_MAX_AGE_DAYS): TEmbeddedRootsInfo;

{ Diagnostic text of the snapshot for CLI warnings. Snapshot present: "embedded
  root snapshot of 2026-06-01 (144 days, stale: threshold 365 days)" or without
  the stale note; no snapshot: "embedded root snapshot unavailable (<reason>)".
}
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

function SelectTrustStore(AEmbeddedAvailable,
  AAllowSystemStore: Boolean): TTrustStoreSource;
begin
  { The embedded root snapshot does not depend on the OS or on the state of the
    system store, so it comes first; the OS store (Windows only) is the
    fallback. If neither exists there is nothing to verify the chain with. }
  if AEmbeddedAvailable then
    Result := tssEmbedded
  else if AAllowSystemStore then
    Result := tssSystem
  else
    Result := tssMissing;
end;

{ --- Availability of the embedded root snapshot --- }

var
  { Cache of "the embedded root snapshot is available": tls.roots reads and
    parses the resource lazily once per process, so repeated HTTPS connections
    do not repeat the check. There is no snapshot when the exe was built
    without tlsroots.res or with -dTLS_NO_EMBEDDED_ROOTS, or when the resource
    is damaged (SHA-256 mismatch). }
  GEmbeddedRootsChecked: Boolean = False;
  GEmbeddedRootsUsable: Boolean = False;
  GEmbeddedRootsErr: string = '';
  { Date of the snapshot that was read (0 — no snapshot). Cached together with
    the availability flag: the resource is parsed once per process. }
  GEmbeddedRootsDateVal: TDateTime = 0;

function EmbeddedRootsUsable: Boolean;
begin
  if not GEmbeddedRootsChecked then
  begin
    GEmbeddedRootsUsable := False;
    GEmbeddedRootsErr := '';
    GEmbeddedRootsDateVal := 0;
    try
      { The store is returned and cached by the tls.roots unit itself — it must
        not be freed. }
      EmbeddedRoots;
      { EmbeddedRootsDate takes the table from the same tls.roots cache, so the
        resource is not read a second time. }
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

{ --- Embedded root snapshot diagnostics (for CLI warnings) --- }

function GetEmbeddedRootsInfo(AMaxAgeDays: LongInt): TEmbeddedRootsInfo;
begin
  { A negative threshold is a caller error; the check is done by tls.roots, so
    its exception is re-raised as is (snapshot availability is unrelated). }
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
    { The threshold and the age arithmetic live in tls.roots: they are not
      duplicated here, otherwise the two places would drift apart. }
    Result.Stale := EmbeddedRootsIsStale(Now, AMaxAgeDays);
  except
    on E: Exception do
    begin
      { The snapshot is available but the age could not be computed; this is
        diagnostics, so the caller is not crashed — the reason is shown. }
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
    Result := 'embedded root snapshot unavailable';
    if AInfo.ErrText <> '' then
      Result := Result + ' (' + AInfo.ErrText + ')';
    Exit;
  end;

  { The age is counted in calendar days: the snapshot date is UTC without the
    time of day, while Now is local time; a difference in hours is invisible to
    the eye, and "144 days" reads better than a fractional number. }
  AgeDays := Trunc(Int(Now)) - Trunc(Int(AInfo.SnapshotDate));
  if AgeDays < 0 then
    AgeDays := 0;
  Result := 'embedded root snapshot of ' +
    FormatDateTime('yyyy-mm-dd', AInfo.SnapshotDate) +
    Format(' (%d days', [AgeDays]);
  if AInfo.Stale then
    Result := Result + Format(', stale: threshold %d days', [AInfo.MaxAgeDays])
  else if AInfo.MaxAgeDays > 0 then
    Result := Result + Format(', threshold %d days', [AInfo.MaxAgeDays]);
  Result := Result + ')';
  if AInfo.ErrText <> '' then
    Result := Result + ' (' + AInfo.ErrText + ')';
end;

{$ifdef windows}
var
  { Lazy cache of the Windows system store: Root/CA are enumerated through
    crypt32 once on the first access and live until the finalization of the
    unit, so every new HTTPS connection does not parse hundreds of certificates
    again. The store is shared: the unit owns it, the caller must not free the
    returned pointer. }
  GSystemTrustStore: TCertStore = nil;

{ Return the system trust store (Windows only), loading it on the first access;
  a repeated call returns the same instance. Load errors
  (TWinCertStoreError/EASN1Error) are not cached — the next call retries. The
  unit owns the result (see finalization). }
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
  { The handler frees the TSocketStream itself (FreeAndNil in its destructor),
    so with a live socket the reference is only dropped here — otherwise it
    would be a double free. }
  if FSocket <> nil then
  begin
    FHandler := nil;
    FSocket.Free;    { closes socket }
    FSocket := nil;
  end
  else
  begin
    { The socket was not created (exception in TInetSocket.Create) — we own the
      handler. }
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
  Trust source: the embedded root snapshot (tls.roots) or, when it is missing,
  the OS store (Windows only): both are unit-level caches, they are not freed
  here. There is no auto-discovery of a bundle next to the program and no
  external bundle. }
function THttpTransport.DoHandshake(const AHost: string): Boolean;
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
  EmbeddedErr: string;            { reason why the embedded snapshot cannot be read }
  SysStoreErr: string;            { reason of the Windows system store failure }
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
      { Trust source: the embedded tls.roots snapshot or, when it is missing,
        the OS store (Windows only). Both are lazy unit-level caches and must
        not be freed. There are no silent fallbacks: if neither is available,
        chain verification fails with an error. }
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
            'trust store unavailable: the embedded root snapshot cannot be ' +
            'read (' + EmbeddedErr + '), the Windows system store — ' +
            SysStoreErr);
        {$else}
        raise ETLS12Error.Create(
          'trust store unavailable: the embedded root snapshot cannot be ' +
          'read (' + EmbeddedErr + '); the OS store is available ' +
          'only on Windows');
        {$endif}
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
        FErrText := 'trust store: ' + E.Message;
      on E: ESocketError do
        FErrText := 'socket: ' + E.Message;
      on E: Exception do
        FErrText := E.ClassName + ': ' + E.Message;
    end;
  finally
    if Chain <> nil then Chain.Free;
    if Buffer <> nil then Buffer.Free;
    { The embedded root snapshot and the system store are shared caches of the
      units tls.roots / mirmid.tlsclient: their finalization sections free them,
      nothing is freed here. }
  end;
end;

function THttpTransport.Connect(const AHost: string; APort: Integer;
  AConnectTimeoutMs, AIOTimeoutMs: Integer): Boolean;
var
  AllowSystem: Boolean;
  Store: TTrustStoreSource;
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

  { Trust source selection happens before the handshake. Order: embedded root
    snapshot -> OS store -> error. There is no auto-discovery of a PEM bundle
    next to the exe and no external bundle can be configured. }
  AllowSystem := False;
  {$ifdef windows}
  AllowSystem := True;
  {$endif}
  Store := SelectTrustStore(EmbeddedRootsUsable, AllowSystem);
  if Store = tssMissing then
  begin
    { No embedded snapshot; on Windows the system store would have been picked
      up by SelectTrustStore, so we only get here on other platforms. The reason
      why the snapshot is unavailable is shown as is — otherwise the "built
      without tlsroots.res" diagnosis stays invisible. }
    FErrText := 'trust store is not configured: the embedded root snapshot ' +
      'is unavailable';
    if GEmbeddedRootsErr <> '' then
      FErrText := FErrText + ' (' + GEmbeddedRootsErr + ')';
    {$ifndef windows}
    FErrText := FErrText +
      '; the OS store is available only on Windows';
    {$endif}
    Exit(False);
  end;
  Result := DoHandshake(AHost);
end;


finalization
  {$ifdef windows}
  { Free the shared cache of the system store (see GetSystemTrustStore). }
  FreeAndNil(GSystemTrustStore);
  {$endif windows}
end.
