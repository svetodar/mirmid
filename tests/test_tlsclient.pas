unit test_tlsclient;
{ Tests of the trust store source selection (mirmid.tlsclient.SelectTrustStore)
  and of the embedded root snapshot (tls.roots via the mirmid.tlsclient wrappers).

  The first group checks the pure function SelectTrustStore: it does not touch
  the file system, the environment or the platform, so all combinations are
  checked with flags - no network, no real files.

  Trust policy (see src/mirmid.tlsclient.pas): the embedded root snapshot
  (tls.roots); when it is missing, the OS store (Windows only); otherwise an
  error. No external PEM bundle is supported: there is no such setting, and
  there is no auto-discovery of ca-bundle.pem (next to the exe, Git for
  Windows, /etc/ssl), so the API has no DefaultCaFile.

  The second group looks at a real build artefact - the root snapshot
  compiled into the exe (RT_RCDATA, `make roots`): the store is not empty, a
  known public root (ISRG Root X1) is found by CN and matches by
  SubjectKeyIdentifier, the snapshot date has no time of day and is not in the
  future, and the GetEmbeddedRootsInfo diagnostics report availability, keep the
  requested staleness threshold, mark the snapshot stale only by that threshold
  and reject a negative threshold. As in the tls library tests/test_roots.pas,
  when building with -dTLS_NO_EMBEDDED_ROOTS these cases do not compile: the
  resource is absent from the exe. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.tlsclient;

type
  TTlsClientTests = class(TTestCase)
  published
    procedure TestEmbeddedWinsOverSystemStore;
    procedure TestSystemStoreWhenEmbeddedMissing;
    procedure TestNoStoreAtAll;
{$ifndef TLS_NO_EMBEDDED_ROOTS}
    { --- Embedded root snapshot (tls.roots) --- }
    procedure TestEmbeddedRootsCount;
    procedure TestEmbeddedRootsKnownRoot;
    procedure TestEmbeddedRootsDate;
    procedure TestEmbeddedRootsInfoAvailable;
    procedure TestEmbeddedRootsInfoStaleByThreshold;
    procedure TestEmbeddedRootsInfoRejectsNegativeAge;
{$endif}
  end;

implementation

uses
  SysUtils,
  tls.roots, tls.certstore, tls.x509;

{ The embedded snapshot wins over the system store: the check does not
  depend on the state of the OS. }
procedure TTlsClientTests.TestEmbeddedWinsOverSystemStore;
begin
  AssertEquals('root snapshot is tssEmbedded', Ord(tssEmbedded),
    Ord(SelectTrustStore(True, True)));
  AssertEquals('root snapshot without a system store', Ord(tssEmbedded),
    Ord(SelectTrustStore(True, False)));
end;

{ A build without tlsroots.res (or with -dTLS_NO_EMBEDDED_ROOTS): the system
  OS store is used instead. }
procedure TTlsClientTests.TestSystemStoreWhenEmbeddedMissing;
begin
  AssertEquals('no snapshot - system store', Ord(tssSystem),
    Ord(SelectTrustStore(False, True)));
end;

{ Neither a snapshot nor a system store: there is nothing to verify a chain
  with - tssMissing, which the caller turns into an error. }
procedure TTlsClientTests.TestNoStoreAtAll;
begin
  AssertEquals('neither snapshot nor system store - tssMissing',
    Ord(tssMissing), Ord(SelectTrustStore(False, False)));
end;

{$ifndef TLS_NO_EMBEDDED_ROOTS}

const
  { Subject attribute name per X.520 (RFC 4514): CN = 2.5.4.3. }
  OID_COMMON_NAME = '2.5.4.3';
  { ISRG Root X1 is the Let's Encrypt root and is present in the certifi
    snapshot. CN and SubjectKeyIdentifier are properties of the certificate
    itself, not of this build, so the constants survive a snapshot update (the
    same values are pinned in the tls library tests/test_roots.pas). }
  ISRG_ROOT_X1_CN = 'ISRG Root X1';
  ISRG_ROOT_X1_SKI = '79b459e67bb6e5e40173800888c81a58f6e99b6e';

{ Lowercase hex is the form in which tls.x509 returns the SKI (and in which
  the published ISRG Root X1 fingerprint is given). }
function HexOf(const AData: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Length(AData) - 1 do
    Result := Result + LowerCase(Format('%.2x', [AData[I]]));
end;

{ The first store certificate with CN = ACN, nil if there is none. The store
  indexes Subject and SKI as a whole but not individual attributes, so a known
  root is searched by iteration - the same way as in the tls library
  tests/test_roots.pas. }
function FindByCommonName(const AStore: TCertStore;
  const ACN: string): TX509Cert;
var
  I: LongInt;
  Cert: TX509Cert;
begin
  Result := nil;
  for I := 0 to AStore.Count - 1 do
  begin
    Cert := AStore.At(I);
    if Cert.Subject.GetByOID(OID_COMMON_NAME) = ACN then
      Exit(Cert);
  end;
end;

procedure TTlsClientTests.TestEmbeddedRootsCount;
var
  Store: TCertStore;
begin
  { The store belongs to the tls.roots unit and is cached there: the caller
    does not free it. }
  Store := EmbeddedRoots;
  AssertNotNull('EmbeddedRoots returned nil', Store);
  AssertTrue('the embedded root snapshot must not be empty',
    Store.Count > 0);
end;

procedure TTlsClientTests.TestEmbeddedRootsKnownRoot;
var
  Store: TCertStore;
  Cert: TX509Cert;
begin
  Store := EmbeddedRoots;
  Cert := FindByCommonName(Store, ISRG_ROOT_X1_CN);
  AssertNotNull('the snapshot has no known root ISRG Root X1', Cert);
  AssertEquals('SubjectKeyIdentifier ISRG Root X1', ISRG_ROOT_X1_SKI,
    HexOf(Cert.GetSubjectKeyIdentifier));
  AssertTrue('ISRG Root X1 must be a CA', Cert.GetBasicConstraints.IsCA);
  { The Subject index must find this root too - VerifyChain walks it when
    building the chain. }
  AssertTrue('the root must be found by Subject',
    Cert = Store.FindBySubject(Cert.Subject.ToNameString));
end;

procedure TTlsClientTests.TestEmbeddedRootsDate;
var
  Info: TEmbeddedRootsInfo;
  D: TDateTime;
begin
  D := EmbeddedRootsDate;
  AssertTrue('the snapshot date must be positive', D > 0);
  AssertTrue('the snapshot date must have no time of day', Frac(D) = 0);
  AssertTrue('the snapshot date must not be in the future', D < Now + 1);

  { The diagnostics read the same date from the same tls.roots cache. }
  Info := GetEmbeddedRootsInfo;
  AssertTrue('the snapshot must be available', Info.Available);
  AssertEquals('EmbeddedRootsDate and SnapshotDate from GetEmbeddedRootsInfo',
    FormatDateTime('yyyy-mm-dd', D),
    FormatDateTime('yyyy-mm-dd', Info.SnapshotDate));
end;

procedure TTlsClientTests.TestEmbeddedRootsInfoAvailable;
var
  Info: TEmbeddedRootsInfo;
begin
  Info := GetEmbeddedRootsInfo;
  AssertTrue('the embedded snapshot must be available', Info.Available);
  AssertEquals('unavailability reason', '', Info.ErrText);
  AssertEquals('default staleness threshold',
    EMBEDDED_ROOTS_MAX_AGE_DAYS, Info.MaxAgeDays);
  AssertTrue('the snapshot date was read', Info.SnapshotDate > 0);
end;

procedure TTlsClientTests.TestEmbeddedRootsInfoStaleByThreshold;
var
  Info0, Info: TEmbeddedRootsInfo;
begin
  { Threshold of 0 days: the snapshot date is midnight and now is later than
    it, so the age is greater than zero and the snapshot is marked stale. The
    expectation does not depend on when the snapshot was taken, unless it is dated
    (TestEmbeddedRootsDate). }
  Info0 := GetEmbeddedRootsInfo(0);
  AssertTrue('threshold 0 days - snapshot is stale', Info0.Stale);
  AssertEquals('the requested threshold 0 is kept in Info', 0, Info0.MaxAgeDays);
  AssertEquals('unavailability reason', '', Info0.ErrText);

  { Threshold of 100 years: no snapshot is that old, so there is no stale flag. }
  Info := GetEmbeddedRootsInfo(36500);
  AssertFalse('threshold 100 years - snapshot is not stale', Info.Stale);
  AssertEquals('the requested threshold 36500 is kept in Info',
    36500, Info.MaxAgeDays);
  AssertEquals('unavailability reason', '', Info.ErrText);
end;

procedure TTlsClientTests.TestEmbeddedRootsInfoRejectsNegativeAge;
begin
  try
    GetEmbeddedRootsInfo(-1);
    Fail('a negative staleness threshold must be rejected');
  except
    on E: EArgumentOutOfRangeException do
      AssertTrue('the exception must name AMaxAgeDays',
        Pos('AMaxAgeDays', E.Message) > 0);
  end;
end;

{$endif}

initialization
  RegisterTest(TTlsClientTests);

end.
