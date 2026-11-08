unit test_tlsclient;
{ Тесты выбора источника trust store (mirmid.tlsclient.SelectTrustStore) и
  встроенного снимка корней (tls.roots через обёртки mirmid.tlsclient).

  Первая группа проверяет чистую функцию SelectTrustStore: она не трогает
  ФС/окружение/платформу, поэтому все сочетания проверяются флагами без сети
  и без реальных файлов.

  Политика доверия (см. src/mirmid.tlsclient.pas): встроенный снимок корней
  (tls.roots), при его отсутствии — системное хранилище ОС (только Windows),
  иначе ошибка. Внешний PEM-бандл не подключается: соответствующей настройки нет, а
  автопоиска ca-bundle.pem (рядом с exe, Git for Windows, /etc/ssl) нет,
  поэтому DefaultCaFile в API отсутствует.

  Вторая группа смотрит на настоящий артефакт сборки — снимок корней,
  вкомпилированный в exe (RT_RCDATA, `make roots`): стор непустой, известный
  публичный корень (ISRG Root X1) находится по CN и совпадает по
  SubjectKeyIdentifier, дата снимка лежит без времени суток и не в будущем, а
  диагностика GetEmbeddedRootsInfo сообщает доступность, сохраняет запрошенный
  порог устаревания, помечает снимок устаревшим только по этому порогу и
  отвергает отрицательный порог. Как и в tests/test_roots.pas библиотеки tls,
  при сборке с -dTLS_NO_EMBEDDED_ROOTS эти случаи не компилируются: ресурса в
  exe тогда нет. }

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
    { --- Встроенный снимок корней (tls.roots) --- }
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

{ Встроенный снимок важнее системного хранилища: проверка не зависит от
  состояния ОС. }
procedure TTlsClientTests.TestEmbeddedWinsOverSystemStore;
begin
  AssertEquals('снимок корней — tssEmbedded', Ord(tssEmbedded),
    Ord(SelectTrustStore(True, True)));
  AssertEquals('снимок корней без системного хранилища', Ord(tssEmbedded),
    Ord(SelectTrustStore(True, False)));
end;

{ Сборка без tlsroots.res (или -dTLS_NO_EMBEDDED_ROOTS): остаётся системное
  хранилище ОС. }
procedure TTlsClientTests.TestSystemStoreWhenEmbeddedMissing;
begin
  AssertEquals('снимка нет — системное хранилище', Ord(tssSystem),
    Ord(SelectTrustStore(False, True)));
end;

{ Ни снимка, ни системного хранилища: проверять цепочку нечем — tssMissing,
  вызывающий превращает это в ошибку. }
procedure TTlsClientTests.TestNoStoreAtAll;
begin
  AssertEquals('ни снимка, ни системного хранилища — tssMissing',
    Ord(tssMissing), Ord(SelectTrustStore(False, False)));
end;

{$ifndef TLS_NO_EMBEDDED_ROOTS}

const
  { Имя атрибута Subject по X.520 (RFC 4514): CN = 2.5.4.3. }
  OID_COMMON_NAME = '2.5.4.3';
  { ISRG Root X1 — корень Let's Encrypt, он есть в снимке certifi. CN и
    SubjectKeyIdentifier — свойства самого сертификата, а не этой сборки,
    поэтому константы переживают обновление снимка (те же значения
    закреплены в tests/test_roots.pas библиотеки tls). }
  ISRG_ROOT_X1_CN = 'ISRG Root X1';
  ISRG_ROOT_X1_SKI = '79b459e67bb6e5e40173800888c81a58f6e99b6e';

{ Нижний регистр hex — форма, в которой tls.x509 отдаёт SKI (и в которой
  опубликован отпечаток ISRG Root X1). }
function HexOf(const AData: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Length(AData) - 1 do
    Result := Result + LowerCase(Format('%.2x', [AData[I]]));
end;

{ Первый сертификат стора с CN = ACN, nil — если такого нет. Стор индексирует
  Subject и SKI целиком, но не отдельные атрибуты, поэтому известный корень
  ищется перебором — так же, как в tests/test_roots.pas библиотеки tls. }
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
  { Стор принадлежит юниту tls.roots и кэшируется там: вызывающий его не
    освобождает. }
  Store := EmbeddedRoots;
  AssertNotNull('EmbeddedRoots вернул nil', Store);
  AssertTrue('встроенный снимок корней не должен быть пустым',
    Store.Count > 0);
end;

procedure TTlsClientTests.TestEmbeddedRootsKnownRoot;
var
  Store: TCertStore;
  Cert: TX509Cert;
begin
  Store := EmbeddedRoots;
  Cert := FindByCommonName(Store, ISRG_ROOT_X1_CN);
  AssertNotNull('в снимке нет известного корня ISRG Root X1', Cert);
  AssertEquals('SubjectKeyIdentifier ISRG Root X1', ISRG_ROOT_X1_SKI,
    HexOf(Cert.GetSubjectKeyIdentifier));
  AssertTrue('ISRG Root X1 должен быть CA', Cert.GetBasicConstraints.IsCA);
  { Индекс Subject тоже обязан находить этот корень — по нему ходит
    VerifyChain при построении цепочки. }
  AssertTrue('корень должен находиться по Subject',
    Cert = Store.FindBySubject(Cert.Subject.ToNameString));
end;

procedure TTlsClientTests.TestEmbeddedRootsDate;
var
  Info: TEmbeddedRootsInfo;
  D: TDateTime;
begin
  D := EmbeddedRootsDate;
  AssertTrue('дата снимка должна быть положительной', D > 0);
  AssertTrue('дата снимка должна быть без времени суток', Frac(D) = 0);
  AssertTrue('дата снимка не должна быть в будущем', D < Now + 1);

  { Диагностика читает ту же дату из того же кэша tls.roots. }
  Info := GetEmbeddedRootsInfo;
  AssertTrue('снимок должен быть доступен', Info.Available);
  AssertEquals('EmbeddedRootsDate и SnapshotDate из GetEmbeddedRootsInfo',
    FormatDateTime('yyyy-mm-dd', D),
    FormatDateTime('yyyy-mm-dd', Info.SnapshotDate));
end;

procedure TTlsClientTests.TestEmbeddedRootsInfoAvailable;
var
  Info: TEmbeddedRootsInfo;
begin
  Info := GetEmbeddedRootsInfo;
  AssertTrue('встроенный снимок должен быть доступен', Info.Available);
  AssertEquals('причина недоступности', '', Info.ErrText);
  AssertEquals('порог устаревания по умолчанию',
    EMBEDDED_ROOTS_MAX_AGE_DAYS, Info.MaxAgeDays);
  AssertTrue('дата снимка прочитана', Info.SnapshotDate > 0);
end;

procedure TTlsClientTests.TestEmbeddedRootsInfoStaleByThreshold;
var
  Info0, Info: TEmbeddedRootsInfo;
begin
  { Порог 0 дней: дата снимка — полночь, а сейчас позже неё, поэтому возраст
    больше нуля и снимок помечается устаревшим. Ожидание не зависит от того,
    когда снят снимок, если только он не датирован будущим
    (TestEmbeddedRootsDate). }
  Info0 := GetEmbeddedRootsInfo(0);
  AssertTrue('порог 0 дней — снимок устарел', Info0.Stale);
  AssertEquals('запрошенный порог 0 сохранён в Info', 0, Info0.MaxAgeDays);
  AssertEquals('причина недоступности', '', Info0.ErrText);

  { Порог 100 лет: ни один снимок не бывает настолько старым, флага нет. }
  Info := GetEmbeddedRootsInfo(36500);
  AssertFalse('порог 100 лет — снимок не устарел', Info.Stale);
  AssertEquals('запрошенный порог 36500 сохранён в Info',
    36500, Info.MaxAgeDays);
  AssertEquals('причина недоступности', '', Info.ErrText);
end;

procedure TTlsClientTests.TestEmbeddedRootsInfoRejectsNegativeAge;
begin
  try
    GetEmbeddedRootsInfo(-1);
    Fail('отрицательный порог устаревания должен быть отвергнут');
  except
    on E: EArgumentOutOfRangeException do
      AssertTrue('исключение должно называть AMaxAgeDays',
        Pos('AMaxAgeDays', E.Message) > 0);
  end;
end;

{$endif}

initialization
  RegisterTest(TTlsClientTests);

end.
