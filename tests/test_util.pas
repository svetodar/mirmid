unit test_util;
{ Тесты переноса длинных строк (mirmid.util.WrapText). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, fpcunit, testregistry, mirmid.util, mirmid.markdown;

type
  TUtilTests = class(TTestCase)
  private
    { Измеряем видимую ширину — так ширина переноса совпадает с терминалом. }
    function Measure(const S: string): Integer;
    { Фильтр переноса, не рвущий markdown-разметку. }
    function Safe(const Prefix: string): Boolean;
    { Склеивает фрагменты через разделитель — для ожидаемых значений. }
    function JoinLines(const Parts: array of string; const Sep: string): string;
    { Число строк, как их видит TStringList.Text (хвостовой EOL не считается). }
    function CountLines(const S: string): Integer;
    { True, если в тексте есть LF, не входящий в пару CRLF. }
    function HasLoneLf(const S: string): Boolean;
    { Маркер сокращения середины с отступом от начала строки (task1.md):
      «…» печатается не с нулевой позиции, а после SHORTEN_ELLIPSIS_INDENT
      пробелов. }
    function Mark: string;
  published
    procedure TestWrapShortLine;
    procedure TestWrapAtSpace;
    procedure TestWrapDropsSpaceAndKeepsPunctuation;
    procedure TestWrapWideChars;
    procedure TestWrapHardBreak;
    procedure TestWrapLeadingSpace;
    procedure TestWrapKeepsIndent;
    procedure TestWrapKeepsIndentWhenWrapping;
    procedure TestWrapSpacesOnly;
    procedure TestWrapDropsExtraSpacesAfterBreak;
    procedure TestWrapAvoidsMarkup;
    procedure TestMirmidPath;
    procedure TestDotToFloat;
    procedure TestFloatToDotStrCommaLocale;
    procedure TestAnsiDisabledForUnknownFd;
    procedure TestAnsiImpliesTerminal;
    procedure TestColoredEmptyColor;
    procedure TestColoredWrapsWhenAnsiEnabled;
    procedure TestDimSGRFullBrightness;
    procedure TestDimSGRBasicColor;
    procedure TestDimSGR256Color;
    procedure TestDimSGRTrueColor;
    procedure TestDimSGRKeepsAttributes;
    procedure TestDimSGRNonColor;
    procedure TestTruncateUTF8Boundary;
    procedure TestTruncateUTF8Ascii;
    procedure TestIsValidUTF8;
    procedure TestSanitizeUTF8;
    { ShortenLinesMiddle: «…» вместо середины, CRLF/LF и UTF-8. }
    procedure TestShortenLinesMiddleNoLimit;
    procedure TestShortenLinesMiddleMarkerIndent;
    procedure TestShortenLinesMiddleDefault;
    procedure TestShortenLinesMiddleEvenLimit;
    procedure TestShortenLinesMiddleTinyLimit;
    procedure TestShortenLinesMiddleCRLF;
    procedure TestShortenLinesMiddleKeepsTrailingEol;
    procedure TestShortenLinesMiddleUTF8;
    { TrimBlankLines: пустые строки сверху и снизу снимаются (task1.md). }
    procedure TestTrimBlankLinesNoChange;
    procedure TestTrimBlankLinesEdges;
    procedure TestTrimBlankLinesKeepsInner;
    procedure TestTrimBlankLinesBlankOnly;
    procedure TestTrimBlankLinesCRLF;
    procedure TestTrimBlankLinesBlankBeforeShorten;
    procedure TestOsName;
    procedure TestOsArch;
    procedure TestNowStamp;
    procedure TestEnvironmentInfo;
    procedure TestDiffIdentical;
    procedure TestDiffCreateFromEmpty;
    procedure TestDiffDeleteToEmpty;
    procedure TestDiffFullReplace;
    procedure TestDiffPartialChange;
    procedure TestDiffContext;
    procedure TestDiffTwoRegions;
    procedure TestDiffLargeFileIsFast;
    procedure TestRunProcessExitCode;
    procedure TestRunProcessStdinEof;
    procedure TestRunProcessTimeout;
    procedure TestRunProcessMaxOutputTruncates;
    procedure TestRunProcessMaxOutputUtf8;
    procedure TestRunProcessNoTty;
  end;
implementation
procedure TUtilTests.TestTruncateUTF8Boundary;
begin
  { «привет» — по 2 байта на букву; обрезка на 5 байтах не должна рвать
    символ: остаётся «пр» (4 байта). }
  AssertEquals('середина символа', 'пр', TruncateUTF8('привет', 5));
  AssertEquals('точная граница', 'при', TruncateUTF8('привет', 6));
  AssertEquals('больше длины', 'привет', TruncateUTF8('привет', 100));
  AssertEquals('ноль байт', '', TruncateUTF8('привет', 0));
  AssertEquals('один байт', '', TruncateUTF8('привет', 1));
  AssertEquals('эмодзи (4 байта)', 'a', TruncateUTF8('a' + #$F0#$9F#$98#$80, 3));
  AssertEquals('эмодзи целиком', 'a' + #$F0#$9F#$98#$80,
    TruncateUTF8('a' + #$F0#$9F#$98#$80, 5));
  AssertTrue('результат корректен', IsValidUTF8(TruncateUTF8('привет', 5)));
end;

procedure TUtilTests.TestTruncateUTF8Ascii;
begin
  AssertEquals('ASCII не меняется', 'hello', TruncateUTF8('hello', 100));
  AssertEquals('ASCII точный префикс', 'hel', TruncateUTF8('hello', 3));
end;

procedure TUtilTests.TestIsValidUTF8;
begin
  AssertTrue('ASCII', IsValidUTF8('hello'));
  AssertTrue('кириллица', IsValidUTF8('привет'));
  AssertTrue('эмодзи', IsValidUTF8(#$F0#$9F#$98#$80));
  AssertFalse('обрезок символа', IsValidUTF8('привет'[1] + 'привет'[2] + 'привет'[3]));
  AssertFalse('одиночный continuation-байт', IsValidUTF8(#$80));
  AssertFalse('перегруженный 2-байтный', IsValidUTF8(#$C0#$80));
  AssertFalse('суррогат', IsValidUTF8(#$ED#$A0#$80));
  AssertFalse('незавершённая последовательность', IsValidUTF8(#$D0));
end;

procedure TUtilTests.TestSanitizeUTF8;
var
  Broken, Fixed: string;
begin
  Broken := 'ok' + #$D0 + 'x';   { ведущий байт без продолжения }
  Fixed := SanitizeUTF8(Broken);
  AssertTrue('стало корректной UTF-8', IsValidUTF8(Fixed));
  AssertTrue('U+FFFD подставлен', Pos(#$EF#$BF#$BD, Fixed) > 0);
  AssertEquals('корректная строка не меняется', 'привет', SanitizeUTF8('привет'));
end;
function TUtilTests.JoinLines(const Parts: array of string;
  const Sep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(Parts) to High(Parts) do
  begin
    if I > Low(Parts) then
      Result := Result + Sep;
    Result := Result + Parts[I];
  end;
end;

function TUtilTests.CountLines(const S: string): Integer;
var
  L: TStringList;
begin
  if S = '' then
    Exit(0);
  L := TStringList.Create;
  try
    L.Text := S;
    Result := L.Count;
  finally
    L.Free;
  end;
end;

function TUtilTests.HasLoneLf(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(S) do
    if (S[I] = #10) and ((I = 1) or (S[I - 1] <> #13)) then
      Exit(True);
end;

function TUtilTests.Mark: string;
begin
  { Отступ задаётся константой юнита — тест проверяет именно её применение. }
  Result := StringOfChar(' ', SHORTEN_ELLIPSIS_INDENT) + '…';
end;

procedure TUtilTests.TestShortenLinesMiddleNoLimit;
var
  S: string;
begin
  S := JoinLines(['a', 'b', 'c'], #10);
  { 0 и отрицательное — «без лимита»: текст возвращается как есть. }
  AssertEquals('ноль — без лимита', S, ShortenLinesMiddle(S, 0));
  AssertEquals('отрицательный лимит', S, ShortenLinesMiddle(S, -3));
  AssertEquals('пустой текст', '', ShortenLinesMiddle('', 9));
  AssertEquals('ровно лимит не меняется', S, ShortenLinesMiddle(S, 3));
  AssertEquals('короче лимита не меняется', S, ShortenLinesMiddle(S, 9));
  AssertEquals('одна строка', 'one', ShortenLinesMiddle('one', 1));
end;

procedure TUtilTests.TestShortenLinesMiddleMarkerIndent;
var
  S, Res: string;
  L: TStringList;
begin
  { Маркер отделяет части вывода инструмента и не должен стоять с начала
    строки (task1.md): «…» печатается после восьми пробелов (с 9-й позиции). }
  S := JoinLines(['l1', 'l2', 'l3', 'l4', 'l5'], #10);
  Res := ShortenLinesMiddle(S, 3);
  L := TStringList.Create;
  try
    L.Text := Res;
    AssertEquals('строк в результате', 3, L.Count);
    AssertEquals('средняя строка — маркер с отступом', Mark, L[1]);
    AssertEquals('отступ — восемь пробелов', 8, Length(L[1]) - Length('…'));
    AssertEquals('«…» с 9-й позиции', 9, Pos('…', L[1]));
    AssertEquals('первая строка без отступа', 'l1', L[0]);
    AssertEquals('последняя строка без отступа', 'l5', L[2]);
  finally
    L.Free;
  end;
  { Лимит 1 — только маркер: отступ сохраняется и без соседних строк. }
  AssertEquals('лимит 1 — маркер с отступом', Mark, ShortenLinesMiddle(S, 1));
end;

procedure TUtilTests.TestShortenLinesMiddleDefault;
var
  S, Res: string;
begin
  S := JoinLines(['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'l10',
    'l11'], #10);
  Res := ShortenLinesMiddle(S, 9);
  AssertEquals('9 = первые 4 + «…» + последние 4',
    JoinLines(['l1', 'l2', 'l3', 'l4', Mark, 'l8', 'l9', 'l10', 'l11'], #10), Res);
  AssertEquals('строк в результате', 9, CountLines(Res));
  AssertEquals('середина выброшена', 0, Pos('l5', Res) + Pos('l6', Res) +
    Pos('l7', Res));
end;

procedure TUtilTests.TestShortenLinesMiddleEvenLimit;
var
  S: string;
begin
  S := JoinLines(['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'l10',
    'l11'], #10);
  { При чётном лимите снизу остаётся на одну строку больше (конец важнее). }
  AssertEquals('8 = 3 + «…» + 4',
    JoinLines(['l1', 'l2', 'l3', Mark, 'l8', 'l9', 'l10', 'l11'], #10),
    ShortenLinesMiddle(S, 8));
  AssertEquals('6 = 2 + «…» + 3',
    JoinLines(['l1', 'l2', Mark, 'l9', 'l10', 'l11'], #10),
    ShortenLinesMiddle(S, 6));
end;

procedure TUtilTests.TestShortenLinesMiddleTinyLimit;
var
  S: string;
begin
  S := JoinLines(['l1', 'l2', 'l3'], #10);
  AssertEquals('1 — только маркер', Mark, ShortenLinesMiddle(S, 1));
  AssertEquals('2 — маркер и последняя строка', JoinLines([Mark, 'l3'], #10),
    ShortenLinesMiddle(S, 2));
end;

procedure TUtilTests.TestShortenLinesMiddleCRLF;
var
  S, Res: string;
begin
  S := JoinLines(['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10',
    'a11'], #13#10);
  Res := ShortenLinesMiddle(S, 9);
  AssertEquals('CRLF исходного текста сохранён',
    JoinLines(['a1', 'a2', 'a3', 'a4', Mark, 'a8', 'a9', 'a10', 'a11'], #13#10),
    Res);
  AssertFalse('одиночных LF нет (не смешиваем переводы строк)', HasLoneLf(Res));
  AssertEquals('строк в результате', 9, CountLines(Res));
end;

procedure TUtilTests.TestShortenLinesMiddleKeepsTrailingEol;
var
  S: string;
begin
  S := JoinLines(['b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8', 'b9', 'b10',
    'b11'], #10) + #10;
  AssertEquals('завершающий перевод строки сохранён',
    JoinLines(['b1', 'b2', 'b3', 'b4', Mark, 'b8', 'b9', 'b10', 'b11'], #10) +
    #10, ShortenLinesMiddle(S, 9));
end;

procedure TUtilTests.TestShortenLinesMiddleUTF8;
var
  S, Res, Emoji: string;
begin
  { Многобайтовые строки обрезаются по строкам, а не по байтам: символы
    (включая U+1F600 из 4 байт) не должны пострадать. }
  S := JoinLines(['привет1', 'привет2', 'привет3', 'привет4', 'привет5',
    'привет6', 'привет7', 'привет8', 'привет9', 'привет10', 'привет11'], #10);
  Res := ShortenLinesMiddle(S, 9);
  AssertTrue('результат — корректная UTF-8', IsValidUTF8(Res));
  AssertEquals('кириллица целыми строками',
    JoinLines(['привет1', 'привет2', 'привет3', 'привет4', Mark, 'привет8',
      'привет9', 'привет10', 'привет11'], #10), Res);
  Emoji := #$F0#$9F#$98#$80;
  S := JoinLines(['e' + Emoji, 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9',
    'l10', 'l11'], #10);
  Res := ShortenLinesMiddle(S, 9);
  AssertTrue('эмодзи не разрезан', IsValidUTF8(Res));
  AssertEquals('первая строка с эмодзи цела', 1, Pos('e' + Emoji, Res));
end;
procedure TUtilTests.TestTrimBlankLinesNoChange;
begin
  { Текст без пустых строк по краям остаётся как есть. }
  AssertEquals('пустая строка', '', TrimBlankLines(''));
  AssertEquals('одна строка', 'one', TrimBlankLines('one'));
  AssertEquals('без пустых краёв',
    JoinLines(['a', 'b', 'c'], #10), TrimBlankLines(JoinLines(['a', 'b', 'c'], #10)));
  AssertEquals('пробелы внутри строки значимы', '  a  ', TrimBlankLines('  a  '));
end;

procedure TUtilTests.TestTrimBlankLinesEdges;
begin
  { Пустые строки в начале и в конце снимаются, содержимое не меняется. }
  AssertEquals('сверху', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['', '', 'a', 'b'], #10)));
  AssertEquals('снизу', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['a', 'b', '', ''], #10)));
  AssertEquals('сверху и снизу', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['', 'a', 'b', ''], #10)));
  { Завершающий перевод строки после снятия пустых строк не остаётся. }
  AssertEquals('хвостовой EOL снят', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['a', 'b', ''], #10) + #10));
  { Строка из пробелов/табуляций — тоже пустая (вывод инструментов часто
    приходит с «пустыми» строками из отступов). }
  AssertEquals('пробельная строка сверху', 'a',
    TrimBlankLines(JoinLines(['   ', 'a'], #10)));
  AssertEquals('табуляция снизу', 'a', TrimBlankLines(JoinLines(['a', #9], #10)));
end;

procedure TUtilTests.TestTrimBlankLinesKeepsInner;
begin
  { Внутренние пустые строки не трогаем: они часть форматирования вывода. }
  AssertEquals('внутренняя пустая строка сохранена',
    JoinLines(['a', '', 'b'], #10),
    TrimBlankLines(JoinLines(['', 'a', '', 'b', ''], #10)));
end;

procedure TUtilTests.TestTrimBlankLinesBlankOnly;
begin
  { Вывод из одних пустых строк — печатать нечего. }
  AssertEquals('одна пустая', '', TrimBlankLines(#10));
  AssertEquals('несколько пустых', '', TrimBlankLines(JoinLines(['', '', ''], #10)));
  AssertEquals('пробельные', '', TrimBlankLines(JoinLines(['  ', #9, ''], #10)));
end;

procedure TUtilTests.TestTrimBlankLinesCRLF;
var
  Res: string;
begin
  { Стиль перевода строк исходного текста сохраняется, одиночных LF нет. }
  Res := TrimBlankLines(JoinLines(['', 'a', 'b', ''], #13#10));
  AssertEquals('CRLF сохранён', JoinLines(['a', 'b'], #13#10), Res);
  AssertFalse('одиночных LF нет', HasLoneLf(Res));
end;

procedure TUtilTests.TestTrimBlankLinesBlankBeforeShorten;
var
  S: string;
begin
  { Регрессия task1.md: пустые строки снимаются ДО обрезки, иначе лимит
    тратится на них и на экране остаются лишние пустые строки. }
  S := JoinLines(['', '', 'l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9',
    'l10', '', ''], #10);
  AssertEquals('обрезка после снятия пустых строк',
    JoinLines(['l1', 'l2', 'l3', Mark, 'l7', 'l8', 'l9', 'l10'], #10),
    ShortenLinesMiddle(TrimBlankLines(S), 8));
  { Без снятия пустых строк обрезка начинается с пустой строки — именно этого
    и не должно быть на экране. }
  AssertTrue('без снятия пустых строк начало пустое',
    ShortenLinesMiddle(S, 8)[1] = #10);
end;


procedure TUtilTests.TestOsName;
begin
  AssertTrue('имя ОС не пустое', OsName <> '');
end;

procedure TUtilTests.TestOsArch;
begin
  AssertTrue('архитектура не пустая', OsArch <> '');
end;

procedure TUtilTests.TestNowStamp;
var
  S: string;
begin
  S := NowStamp;
  AssertEquals('длина yyyy-mm-dd hh:nn:ss', 19, Length(S));
  AssertTrue('разделители даты', (S[5] = '-') and (S[8] = '-'));
  AssertTrue('разделители времени',
    (S[11] = ' ') and (S[14] = ':') and (S[17] = ':'));
  AssertTrue('текущий год', Copy(S, 1, 4) = IntToStr(YearOf(Now)));
end;

procedure TUtilTests.TestEnvironmentInfo;
var
  S: string;
begin
  S := EnvironmentInfo;
  AssertTrue('есть ОС', Pos('ОС ', S) > 0);
  AssertTrue('есть дата', Pos('дата ', S) > 0);
  AssertTrue('есть время', Pos('время ', S) > 0);
  AssertTrue('дата совпадает с текущей', Pos(Copy(NowStamp, 1, 10), S) > 0);
end;

procedure TUtilTests.TestMirmidPath;
var
  Root: string;
begin
  Root := IncludeTrailingPathDelimiter(GetCurrentDir);
  AssertTrue('сам каталог .mirmid', IsMirmidPath(GetCurrentDir, Root + '.mirmid'));
  AssertTrue('файл внутри .mirmid',
    IsMirmidPath(GetCurrentDir, Root + '.mirmid' + PathDelim + 'mirmid.ini'));
  AssertTrue('обход через ..',
    IsMirmidPath(GetCurrentDir,
      Root + '.mirmid' + PathDelim + '..' + PathDelim + '.mirmid' + PathDelim + 'x'));
  AssertFalse('обычный файл', IsMirmidPath(GetCurrentDir, Root + 'a.txt'));
  AssertFalse('похожее имя', IsMirmidPath(GetCurrentDir, Root + '.mirmidx'));
  AssertEquals('MirmidDir', Root + '.mirmid', MirmidDir(GetCurrentDir));
end;

procedure TUtilTests.TestDotToFloat;
begin
  AssertEquals('точка', 0.7, DotToFloat('0.7', -1), 0.0001);
  AssertEquals('запятая', 0.7, DotToFloat('0,7', -1), 0.0001);
  AssertEquals('пробелы по краям', 1.5, DotToFloat('  1.5  ', -1), 0.0001);
  AssertEquals('пустая строка — значение по умолчанию', -1.0, DotToFloat('', -1), 0.0001);
  AssertEquals('мусор — значение по умолчанию', -1.0, DotToFloat('abc', -1), 0.0001);
end;

procedure TUtilTests.TestFloatToDotStrCommaLocale;
var
  OldSep: Char;
begin
  { Локаль с запятой-разделителем не должна влиять на формат и разбор. }
  OldSep := DefaultFormatSettings.DecimalSeparator;
  DefaultFormatSettings.DecimalSeparator := ',';
  try
    AssertEquals('формат', '0.7', FloatToDotStr(0.7));
    AssertEquals('разбор', 0.7, DotToFloat('0.7', -1), 0.0001);
  finally
    DefaultFormatSettings.DecimalSeparator := OldSep;
  end;
end;

procedure TUtilTests.TestAnsiDisabledForUnknownFd;
begin
  { Нестандартные дескрипторы ANSI-вывод не получают. }
  AssertFalse('fd 7 — не стандартный поток', AnsiEnabled(7));
  AssertFalse('fd -1 — не стандартный поток', AnsiEnabled(-1));
  AssertEquals('Colored не добавляет кодов для неизвестного fd', 'txt', Colored('31', 'txt', 7));
end;

procedure TUtilTests.TestAnsiImpliesTerminal;
begin
  { ANSI-коды допустимы только в терминале: при перенаправлении вывода в файл
    AnsiEnabled даёт False, и проверять тут нечего. }
  if AnsiEnabled(1) then
    AssertTrue('ANSI только для терминала (fd 1)', IsTerminal(1));
  if AnsiEnabled(2) then
    AssertTrue('ANSI только для терминала (fd 2)', IsTerminal(2));
end;

procedure TUtilTests.TestColoredEmptyColor;
begin
  { Пустой цвет — текст без кодов в любом окружении (даже в терминале). }
  AssertEquals('пустой цвет — текст без кодов', 'txt', Colored('', 'txt'));
end;

procedure TUtilTests.TestColoredWrapsWhenAnsiEnabled;
begin
  { Точный формат обёртки проверяем лишь там, где ANSI-коды допустимы; иначе
    их ожидать нельзя (например, вывод перенаправлен в файл). Цвет
    приглушается платформенной яркостью (DimSGR). }
  if AnsiEnabled(1) then
    AssertEquals('обёртка и сброс',
      #27 + '[' + DimSGR('31') + 'm' + 'txt' + #27 + '[0m',
      Colored('31', 'txt'));
end;


function TUtilTests.Measure(const S: string): Integer;
begin
  Result := VisibleLen(S);
end;

function TUtilTests.Safe(const Prefix: string): Boolean;
begin
  Result := MarkdownBreakSafe(Prefix);
end;

procedure TUtilTests.TestWrapShortLine;
var
  L: TStringList;
begin
  L := WrapText('hello', 20, @Measure);
  try
    AssertEquals('короткая строка — один фрагмент', 1, L.Count);
    AssertEquals('текст не изменён', 'hello', L[0]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapAtSpace;
var
  L: TStringList;
begin
  L := WrapText('hello world foo', 8, @Measure);
  try
    AssertEquals('число фрагментов', 3, L.Count);
    AssertEquals('первый', 'hello', L[0]);
    AssertEquals('второй', 'world', L[1]);
    AssertEquals('третий', 'foo', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapDropsSpaceAndKeepsPunctuation;
var
  L: TStringList;
begin
  { Пробел на разрыве отбрасывается, точка остаётся при слове. }
  L := WrapText('All tests passed. Let', 17, @Measure);
  try
    AssertEquals('число фрагментов', 2, L.Count);
    AssertEquals('первый без хвостового пробела', 'All tests', L[0]);
    AssertEquals('второй без ведущего пробела и с точкой', 'passed. Let', L[1]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapWideChars;
var
  L: TStringList;
begin
  { «Привет» — 12 байт, но 6 колонок: перенос идёт по видимой ширине. }
  L := WrapText('Привет мир', 8, @Measure);
  try
    AssertEquals('число фрагментов', 2, L.Count);
    AssertEquals('первый', 'Привет', L[0]);
    AssertEquals('второй', 'мир', L[1]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapHardBreak;
var
  L: TStringList;
begin
  { Слово длиннее строки разрывается принудительно. }
  L := WrapText('abcdefghijkl', 5, @Measure);
  try
    AssertEquals('число фрагментов', 3, L.Count);
    AssertEquals('первый', 'abcd', L[0]);
    AssertEquals('второй', 'efgh', L[1]);
    AssertEquals('третий', 'ijkl', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapLeadingSpace;
var
  L: TStringList;
begin
  { Ведущие пробелы первого фрагмента (отступ) сохраняются; у следующих
    фрагментов ведущие пробелы отбрасываются. }
  L := WrapText('  foo bar', 5, @Measure);
  try
    AssertEquals('число фрагментов', 3, L.Count);
    AssertEquals('первый — с отступом', '  fo', L[0]);
    AssertEquals('второй', 'o', L[1]);
    AssertEquals('третий', 'bar', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapKeepsIndent;
var
  L: TStringList;
begin
  { Короткая строка: ведущие пробелы (отступ) не теряются. }
  L := WrapText('  indented', 20, @Measure);
  try
    AssertEquals('один фрагмент', 1, L.Count);
    AssertEquals('отступ сохранён', '  indented', L[0]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapKeepsIndentWhenWrapping;
var
  L: TStringList;
begin
  { Длинная строка с отступом: первый фрагмент сохраняет отступ,
    следующие начинаются с первого символа. }
  L := WrapText('    hello world', 12, @Measure);
  try
    AssertEquals('число фрагментов', 2, L.Count);
    AssertEquals('первый — с отступом', '    hello', L[0]);
    AssertEquals('второй — без ведущего пробела', 'world', L[1]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapSpacesOnly;
var
  L: TStringList;
begin
  { Строка из одних пробелов — одна пустая строка. }
  L := WrapText('   ', 20, @Measure);
  try
    AssertEquals('один фрагмент', 1, L.Count);
    AssertEquals('пустая строка', '', L[0]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapDropsExtraSpacesAfterBreak;
var
  L: TStringList;
begin
  { Несколько пробелов на разрыве: разделитель отбрасывается, следующий
    фрагмент не начинается с пробела. }
  L := WrapText('word  word', 5, @Measure);
  try
    AssertEquals('число фрагментов', 2, L.Count);
    AssertEquals('первый', 'word', L[0]);
    AssertEquals('второй — без ведущих пробелов', 'word', L[1]);
  finally
    L.Free;
  end;
end;
procedure TUtilTests.TestWrapAvoidsMarkup;
var
  L: TStringList;
  { Без фильтра разрыв попал бы внутрь **жирного** («aa **bb»): перенос
    должен выбрать безопасную точку — после закрывающих «**». }
begin
  L := WrapText('aa **bb cc** dd', 10, @Measure, @Safe);
  try
    AssertEquals('число фрагментов', 3, L.Count);
    AssertEquals('первый', 'aa', L[0]);
    AssertEquals('второй — цельная разметка', '**bb cc**', L[1]);
    AssertEquals('третий', 'dd', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestDimSGRFullBrightness;
begin
  { Яркость 1 — код не меняется. }
  AssertEquals('базовый', '36', DimSGR('36', 1.0));
  AssertEquals('256-цвет', '38;5;101', DimSGR('38;5;101', 1.0));
  AssertEquals('атрибуты', '1;96', DimSGR('1;96', 1.0));
  AssertEquals('сброс', '0', DimSGR('0', 1.0));
  AssertEquals('пусто', '', DimSGR('', 1.0));
end;

procedure TUtilTests.TestDimSGRBasicColor;
begin
  { 36 — голубой (5,195,195): при 0.5 → (2,98,98) (Round — к чётному). }
  AssertEquals('базовый цвет в 24-бит', '38;2;2;98;98', DimSGR('36', 0.5));
  { 90 — серый (75,75,75): при 0.5 → (38,38,38). }
  AssertEquals('яркий серый', '38;2;38;38;38', DimSGR('90', 0.5));
end;

procedure TUtilTests.TestDimSGR256Color;
begin
  { 38;5;101 — (135,135,95): при 0.5 → (68,68,48). }
  AssertEquals('куб', '38;2;68;68;48', DimSGR('38;5;101', 0.5));
  { 38;5;250 — серый градиент (188,188,188): при 0.5 → (94,94,94). }
  AssertEquals('градиент', '38;2;94;94;94', DimSGR('38;5;250', 0.5));
end;

procedure TUtilTests.TestDimSGRTrueColor;
begin
  AssertEquals('24-бит', '38;2;128;0;0', DimSGR('38;2;255;0;0', 0.5));
end;

procedure TUtilTests.TestDimSGRKeepsAttributes;
begin
  { Атрибуты (жирный, приглушение) сохраняются, цвет пересчитывается. }
  AssertEquals('жирный + яркий голубой', '1;38;2;2;128;128', DimSGR('1;96', 0.5));
  AssertEquals('приглушение + жёлтый', '2;38;2;128;128;2', DimSGR('2;93', 0.5));
  AssertEquals('цвет перед атрибутом', '38;2;68;68;48;1', DimSGR('38;5;101;1', 0.5));
end;

procedure TUtilTests.TestDimSGRNonColor;
begin
  { Нечто нецветовое возвращается как есть. }
  AssertEquals('сброс', '0', DimSGR('0', 0.5));
  AssertEquals('жирный', '1', DimSGR('1', 0.5));
  AssertEquals('курсив', '3', DimSGR('3', 0.5));
end;

procedure TUtilTests.TestDiffIdentical;
var
  A, B: TStringList;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    A.Add('hello');
    A.Add('world');
    B.Add('hello');
    B.Add('world');
    AssertEquals('идентичные списки — пустой diff', '',
      MakeUnifiedDiff(A, B, 'a/f', 'b/f'));
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TUtilTests.TestDiffCreateFromEmpty;
var
  A, B: TStringList;
  D: string;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    { A пуст, B содержит строки. }
    B.Add('line1');
    B.Add('line2');
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f');
    AssertTrue('есть заголовок ---', Pos('--- a/f', D) > 0);
    AssertTrue('есть заголовок +++', Pos('+++ b/f', D) > 0);
    AssertTrue('есть @@ -0,0 +1,2 @@', Pos('@@ -0,0 +1,2 @@', D) > 0);
    AssertTrue('строка +line1', Pos('+line1', D) > 0);
    AssertTrue('строка +line2', Pos('+line2', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TUtilTests.TestDiffDeleteToEmpty;
var
  A, B: TStringList;
  D: string;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    A.Add('line1');
    A.Add('line2');
    { B пуст. }
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f');
    AssertTrue('есть @@ -1,2 +0,0 @@', Pos('@@ -1,2 +0,0 @@', D) > 0);
    AssertTrue('строка -line1', Pos('-line1', D) > 0);
    AssertTrue('строка -line2', Pos('-line2', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TUtilTests.TestDiffFullReplace;
var
  A, B: TStringList;
  D: string;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    A.Add('old1');
    A.Add('old2');
    B.Add('new1');
    B.Add('new2');
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f');
    AssertTrue('есть -old1', Pos('-old1', D) > 0);
    AssertTrue('есть -old2', Pos('-old2', D) > 0);
    AssertTrue('есть +new1', Pos('+new1', D) > 0);
    AssertTrue('есть +new2', Pos('+new2', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TUtilTests.TestDiffPartialChange;
var
  A, B: TStringList;
  D: string;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    A.Add('same1');
    A.Add('old');
    A.Add('same2');
    B.Add('same1');
    B.Add('new');
    B.Add('same2');
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f');
    AssertTrue('контекст same1', Pos(' same1', D) > 0);
    AssertTrue('удалено old', Pos('-old', D) > 0);
    AssertTrue('добавлено new', Pos('+new', D) > 0);
    AssertTrue('контекст same2', Pos(' same2', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TUtilTests.TestDiffContext;
var
  A, B: TStringList;
  D: string;
  I: Integer;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    for I := 1 to 10 do
    begin
      A.Add('line' + IntToStr(I));
      B.Add('line' + IntToStr(I));
    end;
    { Меняем строку 5. }
    B[4] := 'CHANGED';
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f', 1, 2);
    AssertTrue('есть -line5', Pos('-line5', D) > 0);
    AssertTrue('есть +CHANGED', Pos('+CHANGED', D) > 0);
    { Контекст 2: строки 3,4 и 6,7 должны быть. }
    AssertTrue('контекст line3', Pos(' line3', D) > 0);
    AssertTrue('контекст line4', Pos(' line4', D) > 0);
    AssertTrue('контекст line6', Pos(' line6', D) > 0);
    AssertTrue('контекст line7', Pos(' line7', D) > 0);
    { Строки 1,2,8,9,10 не должны быть (вне контекста). }
    AssertFalse('line1 вне контекста', Pos(' line1', D) > 0);
    AssertFalse('line10 вне контекста', Pos(' line10', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

{ Две разнесённые правки: номера строк в ханках считаются по всему файлу,
  хотя LCS теперь строится только по «середине» (между общим префиксом и
  суффиксом). }
procedure TUtilTests.TestDiffTwoRegions;
var
  A, B: TStringList;
  D: string;
  I: Integer;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    for I := 1 to 10 do
    begin
      A.Add('a' + IntToStr(I));
      B.Add('a' + IntToStr(I));
    end;
    B[0] := 'X1';
    B[9] := 'X10';

    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f', 1, 0);
    AssertTrue('первый ханк с номерами 1 — ' + D, Pos('@@ -1,1 +1,1 @@', D) > 0);
    AssertTrue('второй ханк с номерами 10 — ' + D, Pos('@@ -10,1 +10,1 @@', D) > 0);
    AssertTrue('удалена строка 1', Pos('-a1' + sLineBreak, D) > 0);
    AssertTrue('добавлена строка X1', Pos('+X1' + sLineBreak, D) > 0);
    AssertTrue('удалена строка 10', Pos('-a10' + sLineBreak, D) > 0);
    AssertTrue('добавлена строка X10', Pos('+X10' + sLineBreak, D) > 0);

    { Стартовый номер первого ханка сдвигается аргументом OldStartLine. }
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f', 100, 1);
    AssertTrue('ханк начинается со строки 100 — ' + D, Pos('@@ -100,2 +100,2 @@', D) > 0);
    AssertTrue('ханк у конца файла — ' + D, Pos('@@ -108,2 +108,2 @@', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

{ Регрессия: LCS строился по всему файлу (N*M ячеек), и правка большого файла
  фактически зависала (8k строк — 4,3 с, 50k — больше минуты). После отсечения
  общего префикса/суффикса diff по времени линеен. }
procedure TUtilTests.TestDiffLargeFileIsFast;
const
  Lines = 20000;
var
  A, B: TStringList;
  D: string;
  I, T0: Integer;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    for I := 1 to Lines do
    begin
      A.Add('line-' + IntToStr(I));
      if I = Lines div 2 then
        B.Add('line-CHANGED')
      else
        B.Add('line-' + IntToStr(I));
    end;

    T0 := GetTickCount64;
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f');
    T0 := Integer(GetTickCount64) - T0;

    AssertTrue('изменение попало в diff — ' + D, Pos('+line-CHANGED', D) > 0);
    AssertTrue('одна ханка — ' + D, Pos('@@ -9997,7 +9997,7 @@', D) > 0);
    AssertTrue('diff по 20k строк быстрый: ' + IntToStr(T0) + ' мс', T0 < 10000);
  finally
    A.Free;
    B.Free;
  end;
end;

{ --- RunProcess: защита от зависаний --- }

procedure TUtilTests.TestRunProcessExitCode;
var
  OutText, Err: string;
  EC: Integer;
begin
  AssertTrue('процесс завершился',
    RunProcess('exit 3', '', 10, OutText, EC, Err));
  AssertTrue('ненулевой код выхода', EC <> 0);
end;

procedure TUtilTests.TestRunProcessStdinEof;
var
  OutText, Err: string;
  EC: Integer;
begin
  {$IFDEF UNIX}
  { Команда, читающая stdin, должна получить EOF (закрытый вход), а не
    ждать ввод до таймаута. Регрессия: cat висел до shell_timeout. }
  AssertTrue('чтение stdin не зависает',
    RunProcess('cat', '', 5, OutText, EC, Err));
  {$ELSE}
  AssertTrue('заглушка', True);
  {$ENDIF}
end;

procedure TUtilTests.TestRunProcessTimeout;
var
  OutText, Err: string;
  EC: Integer;
begin
  {$IFDEF UNIX}
  AssertFalse('таймаут срабатывает',
    RunProcess('sleep 30', '', 1, OutText, EC, Err));
  AssertTrue('сообщение о таймауте', Pos('превышено время', Err) > 0);
  {$ELSE}
  AssertTrue('заглушка', True);
  {$ENDIF}
end;

procedure TUtilTests.TestRunProcessNoTty;
var
  OutText, Err: string;
  EC: Integer;
begin
  {$IFDEF UNIX}
  { Дочерний процесс запускается в новой сессии и не наследует управляющий
    терминал: интерактивные команды (sudo, ssh, редакторы) не могут открыть
    /dev/tty и «зависнуть» на чтении пароля. }
  AssertTrue('процесс завершился',
    RunProcess('if [ -c /dev/tty ] && (exec 3</dev/tty) 2>/dev/null; then ' +
      'echo TTY_OPEN_OK; else echo TTY_OPEN_FAIL; fi', '', 5, OutText, EC, Err));
  AssertTrue('/dev/tty недоступен', Pos('TTY_OPEN_FAIL', OutText) > 0);
  AssertFalse('/dev/tty не открылся', Pos('TTY_OPEN_OK', OutText) > 0);
  {$ELSE}
  AssertTrue('заглушка', True);
  {$ENDIF}
end;

procedure TUtilTests.TestRunProcessMaxOutputTruncates;
var
  OutText, Err: string;
  EC: Integer;
  Total: Int64;
begin
  { Вывод длиннее предела: в Output остаётся ровно MaxOutput байт, но из
    процесса вычитывается всё (иначе он заблокируется на заполненном pipe),
    поэтому TotalBytes больше предела. }
  AssertTrue('процесс завершился',
    RunProcess('echo ' + StringOfChar('x', 200), '', 10, OutText, EC, Err, 10, Total));
  AssertEquals('вывод обрезан до предела', StringOfChar('x', 10), OutText);
  AssertTrue('прочитано больше предела: ' + IntToStr(Total), Total >= 200);

  { MaxOutput = 0 — без предела: вывод приходит целиком. }
  AssertTrue('процесс завершился (без предела)',
    RunProcess('echo abcdefghij', '', 10, OutText, EC, Err, 0, Total));
  AssertTrue('без предела вывод не обрезан', Pos('abcdefghij', OutText) > 0);
  AssertTrue('счётчик считает прочитанное: ' + IntToStr(Total), Total >= 10);
end;

procedure TUtilTests.TestRunProcessMaxOutputUtf8;
var
  OutText, Err: string;
  EC: Integer;
  Total: Int64;
begin
  {$IFDEF UNIX}
  { «привет» — 12 байт; предел 5 байт не должен рвать символ:
    остаётся «пр» (4 байта), TotalBytes считает все 12 прочитанных байт. }
  AssertTrue('процесс завершился',
    RunProcess('printf "привет"', '', 10, OutText, EC, Err, 5, Total));
  AssertEquals('обрезка по границе символа', 'пр', OutText);
  AssertTrue('корректная UTF-8', IsValidUTF8(OutText));
  AssertEquals('счётчик считает все байты', 12, Total);
  {$ELSE}
  { В cmd.exe надёжно напечатать многобайтовую UTF-8 нельзя — там счётчик и
    обрезка уже покрыты ASCII-тестом через тот же RunProcess. }
  AssertTrue('заглушка', True);
  {$ENDIF}
end;

initialization
  RegisterTest(TUtilTests);
end.
