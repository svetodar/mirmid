unit test_util;
{ Tests for long line wrapping and the other mirmid.util helpers. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, fpcunit, testregistry, mirmid.util, mirmid.markdown;

type
  TUtilTests = class(TTestCase)
  private
    { Measure the visible width - so the wrap width matches the terminal. }
    function Measure(const S: string): Integer;
    { Wrap filter that does not break markdown markup. }
    function Safe(const Prefix: string): Boolean;
    { Joins fragments with a separator - for expected values. }
    function JoinLines(const Parts: array of string; const Sep: string): string;
    { Number of lines as TStringList.Text sees them (a trailing EOL is not counted). }
    function CountLines(const S: string): Integer;
    { True if the text has an LF that is not part of a CRLF pair. }
    function HasLoneLf(const S: string): Boolean;
    { The middle truncation marker indented from the start of the line (task1.md):
      the ellipsis is printed not from position zero but after SHORTEN_ELLIPSIS_INDENT
      spaces. }
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
    { ShortenLinesMiddle: the ellipsis instead of the middle, CRLF/LF and UTF-8. }
    procedure TestShortenLinesMiddleNoLimit;
    procedure TestShortenLinesMiddleMarkerIndent;
    procedure TestShortenLinesMiddleDefault;
    procedure TestShortenLinesMiddleEvenLimit;
    procedure TestShortenLinesMiddleTinyLimit;
    procedure TestShortenLinesMiddleCRLF;
    procedure TestShortenLinesMiddleKeepsTrailingEol;
    procedure TestShortenLinesMiddleUTF8;
    { TrimBlankLines: blank lines at the top and the bottom are removed (task1.md). }
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
  { "äöüßéè" - 2 bytes per letter; truncation at 5 bytes must not break
    a character: "äö" (4 bytes) remains. }
  AssertEquals('middle of a character', 'äö', TruncateUTF8('äöüßéè', 5));
  AssertEquals('exact boundary', 'äöü', TruncateUTF8('äöüßéè', 6));
  AssertEquals('longer than the string', 'äöüßéè', TruncateUTF8('äöüßéè', 100));
  AssertEquals('zero bytes', '', TruncateUTF8('äöüßéè', 0));
  AssertEquals('one byte', '', TruncateUTF8('äöüßéè', 1));
  AssertEquals('emoji (4 bytes)', 'a', TruncateUTF8('a' + #$F0#$9F#$98#$80, 3));
  AssertEquals('whole emoji', 'a' + #$F0#$9F#$98#$80,
    TruncateUTF8('a' + #$F0#$9F#$98#$80, 5));
  AssertTrue('the result is valid', IsValidUTF8(TruncateUTF8('äöüßéè', 5)));
end;

procedure TUtilTests.TestTruncateUTF8Ascii;
begin
  AssertEquals('ASCII unchanged', 'hello', TruncateUTF8('hello', 100));
  AssertEquals('ASCII exact prefix', 'hel', TruncateUTF8('hello', 3));
end;

procedure TUtilTests.TestIsValidUTF8;
begin
  AssertTrue('ASCII', IsValidUTF8('hello'));
  AssertTrue('multi-byte letters', IsValidUTF8('äöüßéè'));
  AssertTrue('emoji', IsValidUTF8(#$F0#$9F#$98#$80));
  AssertFalse('cut character', IsValidUTF8('äöüßéè'[1] + 'äöüßéè'[2] + 'äöüßéè'[3]));
  AssertFalse('single continuation byte', IsValidUTF8(#$80));
  AssertFalse('overlong 2-byte sequence', IsValidUTF8(#$C0#$80));
  AssertFalse('surrogate', IsValidUTF8(#$ED#$A0#$80));
  AssertFalse('unfinished sequence', IsValidUTF8(#$D0));
end;

procedure TUtilTests.TestSanitizeUTF8;
var
  Broken, Fixed: string;
begin
  Broken := 'ok' + #$D0 + 'x';   { lead byte without a continuation }
  Fixed := SanitizeUTF8(Broken);
  AssertTrue('became valid UTF-8', IsValidUTF8(Fixed));
  AssertTrue('U+FFFD substituted', Pos(#$EF#$BF#$BD, Fixed) > 0);
  AssertEquals('a valid string is unchanged', 'äöüßéè', SanitizeUTF8('äöüßéè'));
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
  { The indent comes from the unit constant - the test checks exactly its use. }
  Result := StringOfChar(' ', SHORTEN_ELLIPSIS_INDENT) + '…';
end;

procedure TUtilTests.TestShortenLinesMiddleNoLimit;
var
  S: string;
begin
  S := JoinLines(['a', 'b', 'c'], #10);
  { 0 and negative mean "no limit": the text is returned as is. }
  AssertEquals('zero - no limit', S, ShortenLinesMiddle(S, 0));
  AssertEquals('negative limit', S, ShortenLinesMiddle(S, -3));
  AssertEquals('empty text', '', ShortenLinesMiddle('', 9));
  AssertEquals('exactly the limit - unchanged', S, ShortenLinesMiddle(S, 3));
  AssertEquals('shorter than the limit - unchanged', S, ShortenLinesMiddle(S, 9));
  AssertEquals('one line', 'one', ShortenLinesMiddle('one', 1));
end;

procedure TUtilTests.TestShortenLinesMiddleMarkerIndent;
var
  S, Res: string;
  L: TStringList;
begin
  { The marker separates the parts of tool output and must not sit at the start
    of a line (task1.md): the ellipsis is printed after eight spaces (position 9). }
  S := JoinLines(['l1', 'l2', 'l3', 'l4', 'l5'], #10);
  Res := ShortenLinesMiddle(S, 3);
  L := TStringList.Create;
  try
    L.Text := Res;
    AssertEquals('lines in the result', 3, L.Count);
    AssertEquals('the middle line is the indented marker', Mark, L[1]);
    AssertEquals('indent is eight spaces', 8, Length(L[1]) - Length('…'));
    AssertEquals('ellipsis from position 9', 9, Pos('…', L[1]));
    AssertEquals('first line without indent', 'l1', L[0]);
    AssertEquals('last line without indent', 'l5', L[2]);
  finally
    L.Free;
  end;
  { Limit 1 - only the marker: the indent is kept even without neighbouring lines. }
  AssertEquals('limit 1 - indented marker', Mark, ShortenLinesMiddle(S, 1));
end;

procedure TUtilTests.TestShortenLinesMiddleDefault;
var
  S, Res: string;
begin
  S := JoinLines(['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'l10',
    'l11'], #10);
  Res := ShortenLinesMiddle(S, 9);
  AssertEquals('9 = first 4 + ellipsis + last 4',
    JoinLines(['l1', 'l2', 'l3', 'l4', Mark, 'l8', 'l9', 'l10', 'l11'], #10), Res);
  AssertEquals('lines in the result', 9, CountLines(Res));
  AssertEquals('the middle is dropped', 0, Pos('l5', Res) + Pos('l6', Res) +
    Pos('l7', Res));
end;

procedure TUtilTests.TestShortenLinesMiddleEvenLimit;
var
  S: string;
begin
  S := JoinLines(['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'l10',
    'l11'], #10);
  { With an even limit the bottom keeps one line more (the end is more important). }
  AssertEquals('8 = 3 + ellipsis + 4',
    JoinLines(['l1', 'l2', 'l3', Mark, 'l8', 'l9', 'l10', 'l11'], #10),
    ShortenLinesMiddle(S, 8));
  AssertEquals('6 = 2 + ellipsis + 3',
    JoinLines(['l1', 'l2', Mark, 'l9', 'l10', 'l11'], #10),
    ShortenLinesMiddle(S, 6));
end;

procedure TUtilTests.TestShortenLinesMiddleTinyLimit;
var
  S: string;
begin
  S := JoinLines(['l1', 'l2', 'l3'], #10);
  AssertEquals('1 - only the marker', Mark, ShortenLinesMiddle(S, 1));
  AssertEquals('2 - the marker and the last line', JoinLines([Mark, 'l3'], #10),
    ShortenLinesMiddle(S, 2));
end;

procedure TUtilTests.TestShortenLinesMiddleCRLF;
var
  S, Res: string;
begin
  S := JoinLines(['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10',
    'a11'], #13#10);
  Res := ShortenLinesMiddle(S, 9);
  AssertEquals('CRLF of the source text is kept',
    JoinLines(['a1', 'a2', 'a3', 'a4', Mark, 'a8', 'a9', 'a10', 'a11'], #13#10),
    Res);
  AssertFalse('no lone LF (line break styles are not mixed)', HasLoneLf(Res));
  AssertEquals('lines in the result', 9, CountLines(Res));
end;

procedure TUtilTests.TestShortenLinesMiddleKeepsTrailingEol;
var
  S: string;
begin
  S := JoinLines(['b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8', 'b9', 'b10',
    'b11'], #10) + #10;
  AssertEquals('the trailing line break is kept',
    JoinLines(['b1', 'b2', 'b3', 'b4', Mark, 'b8', 'b9', 'b10', 'b11'], #10) +
    #10, ShortenLinesMiddle(S, 9));
end;

procedure TUtilTests.TestShortenLinesMiddleUTF8;
var
  S, Res, Emoji: string;
begin
  { Multi-byte lines are truncated by lines, not by bytes: the characters
    (including the 4-byte U+1F600) must not be damaged. }
  S := JoinLines(['äöüßéè1', 'äöüßéè2', 'äöüßéè3', 'äöüßéè4', 'äöüßéè5',
    'äöüßéè6', 'äöüßéè7', 'äöüßéè8', 'äöüßéè9', 'äöüßéè10', 'äöüßéè11'], #10);
  Res := ShortenLinesMiddle(S, 9);
  AssertTrue('the result is valid UTF-8', IsValidUTF8(Res));
  AssertEquals('multi-byte lines kept whole',
    JoinLines(['äöüßéè1', 'äöüßéè2', 'äöüßéè3', 'äöüßéè4', Mark, 'äöüßéè8',
      'äöüßéè9', 'äöüßéè10', 'äöüßéè11'], #10), Res);
  Emoji := #$F0#$9F#$98#$80;
  S := JoinLines(['e' + Emoji, 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9',
    'l10', 'l11'], #10);
  Res := ShortenLinesMiddle(S, 9);
  AssertTrue('the emoji is not cut', IsValidUTF8(Res));
  AssertEquals('the first line with the emoji is intact', 1, Pos('e' + Emoji, Res));
end;
procedure TUtilTests.TestTrimBlankLinesNoChange;
begin
  { Text without blank lines at the edges stays as is. }
  AssertEquals('empty string', '', TrimBlankLines(''));
  AssertEquals('one line', 'one', TrimBlankLines('one'));
  AssertEquals('no blank edges',
    JoinLines(['a', 'b', 'c'], #10), TrimBlankLines(JoinLines(['a', 'b', 'c'], #10)));
  AssertEquals('inner spaces are significant', '  a  ', TrimBlankLines('  a  '));
end;

procedure TUtilTests.TestTrimBlankLinesEdges;
begin
  { Blank lines at the start and at the end are removed, the content is unchanged. }
  AssertEquals('at the top', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['', '', 'a', 'b'], #10)));
  AssertEquals('at the bottom', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['a', 'b', '', ''], #10)));
  AssertEquals('at the top and at the bottom', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['', 'a', 'b', ''], #10)));
  { No trailing line break remains after the blank lines are removed. }
  AssertEquals('the trailing EOL is removed', JoinLines(['a', 'b'], #10),
    TrimBlankLines(JoinLines(['a', 'b', ''], #10) + #10));
  { A line of spaces/tabs is blank too (tool output often comes with
    "blank" lines made of indentation). }
  AssertEquals('a whitespace line at the top', 'a',
    TrimBlankLines(JoinLines(['   ', 'a'], #10)));
  AssertEquals('a tab at the bottom', 'a', TrimBlankLines(JoinLines(['a', #9], #10)));
end;

procedure TUtilTests.TestTrimBlankLinesKeepsInner;
begin
  { Inner blank lines are left alone: they are part of the output formatting. }
  AssertEquals('the inner blank line is kept',
    JoinLines(['a', '', 'b'], #10),
    TrimBlankLines(JoinLines(['', 'a', '', 'b', ''], #10)));
end;

procedure TUtilTests.TestTrimBlankLinesBlankOnly;
begin
  { Output of blank lines only - nothing to print. }
  AssertEquals('one blank line', '', TrimBlankLines(#10));
  AssertEquals('several blank lines', '', TrimBlankLines(JoinLines(['', '', ''], #10)));
  AssertEquals('whitespace lines', '', TrimBlankLines(JoinLines(['  ', #9, ''], #10)));
end;

procedure TUtilTests.TestTrimBlankLinesCRLF;
var
  Res: string;
begin
  { The line break style of the source text is kept, there are no lone LFs. }
  Res := TrimBlankLines(JoinLines(['', 'a', 'b', ''], #13#10));
  AssertEquals('CRLF is kept', JoinLines(['a', 'b'], #13#10), Res);
  AssertFalse('no lone LF', HasLoneLf(Res));
end;

procedure TUtilTests.TestTrimBlankLinesBlankBeforeShorten;
var
  S: string;
begin
  { Regression task1.md: blank lines are removed BEFORE truncation, otherwise the
    line limit is spent on them and extra blank lines remain on the screen. }
  S := JoinLines(['', '', 'l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9',
    'l10', '', ''], #10);
  AssertEquals('truncation after the blank lines are removed',
    JoinLines(['l1', 'l2', 'l3', Mark, 'l7', 'l8', 'l9', 'l10'], #10),
    ShortenLinesMiddle(TrimBlankLines(S), 8));
  { Without removing the blank lines the truncation starts with a blank line -
    exactly what must not appear on the screen. }
  AssertTrue('without removing the blank lines the start is empty',
    ShortenLinesMiddle(S, 8)[1] = #10);
end;


procedure TUtilTests.TestOsName;
begin
  AssertTrue('the OS name is not empty', OsName <> '');
end;

procedure TUtilTests.TestOsArch;
begin
  AssertTrue('the architecture is not empty', OsArch <> '');
end;

procedure TUtilTests.TestNowStamp;
var
  S: string;
begin
  S := NowStamp;
  AssertEquals('length yyyy-mm-dd hh:nn:ss', 19, Length(S));
  AssertTrue('date separators', (S[5] = '-') and (S[8] = '-'));
  AssertTrue('time separators',
    (S[11] = ' ') and (S[14] = ':') and (S[17] = ':'));
  AssertTrue('the current year', Copy(S, 1, 4) = IntToStr(YearOf(Now)));
end;

procedure TUtilTests.TestEnvironmentInfo;
var
  S: string;
begin
  S := EnvironmentInfo;
  AssertTrue('OS present', Pos('OS ', S) > 0);
  AssertTrue('date present', Pos('date ', S) > 0);
  AssertTrue('time present', Pos('time ', S) > 0);
  AssertTrue('the date matches the current one', Pos(Copy(NowStamp, 1, 10), S) > 0);
end;

procedure TUtilTests.TestMirmidPath;
var
  Root: string;
begin
  Root := IncludeTrailingPathDelimiter(GetCurrentDir);
  AssertTrue('the .mirmid directory itself', IsMirmidPath(GetCurrentDir, Root + '.mirmid'));
  AssertTrue('a file inside .mirmid',
    IsMirmidPath(GetCurrentDir, Root + '.mirmid' + PathDelim + 'mirmid.ini'));
  AssertTrue('traversal via ..',
    IsMirmidPath(GetCurrentDir,
      Root + '.mirmid' + PathDelim + '..' + PathDelim + '.mirmid' + PathDelim + 'x'));
  AssertFalse('a normal file', IsMirmidPath(GetCurrentDir, Root + 'a.txt'));
  AssertFalse('a similar name', IsMirmidPath(GetCurrentDir, Root + '.mirmidx'));
  AssertEquals('MirmidDir', Root + '.mirmid', MirmidDir(GetCurrentDir));
end;

procedure TUtilTests.TestDotToFloat;
begin
  AssertEquals('decimal point', 0.7, DotToFloat('0.7', -1), 0.0001);
  AssertEquals('comma', 0.7, DotToFloat('0,7', -1), 0.0001);
  AssertEquals('spaces around', 1.5, DotToFloat('  1.5  ', -1), 0.0001);
  AssertEquals('empty string - the default value', -1.0, DotToFloat('', -1), 0.0001);
  AssertEquals('garbage - the default value', -1.0, DotToFloat('abc', -1), 0.0001);
end;

procedure TUtilTests.TestFloatToDotStrCommaLocale;
var
  OldSep: Char;
begin
  { A comma-decimal locale must not influence the format or the parsing. }
  OldSep := DefaultFormatSettings.DecimalSeparator;
  DefaultFormatSettings.DecimalSeparator := ',';
  try
    AssertEquals('format', '0.7', FloatToDotStr(0.7));
    AssertEquals('parsing', 0.7, DotToFloat('0.7', -1), 0.0001);
  finally
    DefaultFormatSettings.DecimalSeparator := OldSep;
  end;
end;

procedure TUtilTests.TestAnsiDisabledForUnknownFd;
begin
  { Non-standard descriptors get no ANSI output. }
  AssertFalse('fd 7 is not a standard stream', AnsiEnabled(7));
  AssertFalse('fd -1 is not a standard stream', AnsiEnabled(-1));
  AssertEquals('Colored adds no codes for an unknown fd', 'txt', Colored('31', 'txt', 7));
end;

procedure TUtilTests.TestAnsiImpliesTerminal;
begin
  { ANSI codes are allowed only in a terminal: when the output is redirected to a
    file AnsiEnabled gives False and there is nothing to check here. }
  if AnsiEnabled(1) then
    AssertTrue('ANSI only for a terminal (fd 1)', IsTerminal(1));
  if AnsiEnabled(2) then
    AssertTrue('ANSI only for a terminal (fd 2)', IsTerminal(2));
end;

procedure TUtilTests.TestColoredEmptyColor;
begin
  { An empty color means text without codes in any environment (even in a terminal). }
  AssertEquals('empty color - text without codes', 'txt', Colored('', 'txt'));
end;

procedure TUtilTests.TestColoredWrapsWhenAnsiEnabled;
begin
  { The exact wrapper format is checked only where ANSI codes are allowed;
    otherwise they cannot be expected (for example when the output is redirected
    to a file). The color is dimmed by the platform brightness (DimSGR). }
  if AnsiEnabled(1) then
    AssertEquals('wrapper and reset',
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
    AssertEquals('short line - one fragment', 1, L.Count);
    AssertEquals('the text is unchanged', 'hello', L[0]);
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
    AssertEquals('number of fragments', 3, L.Count);
    AssertEquals('first', 'hello', L[0]);
    AssertEquals('second', 'world', L[1]);
    AssertEquals('third', 'foo', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapDropsSpaceAndKeepsPunctuation;
var
  L: TStringList;
begin
  { The space at the break is dropped, the full stop stays with the word. }
  L := WrapText('All tests passed. Let', 17, @Measure);
  try
    AssertEquals('number of fragments', 2, L.Count);
    AssertEquals('first without a trailing space', 'All tests', L[0]);
    AssertEquals('second without a leading space, with the full stop', 'passed. Let', L[1]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapWideChars;
var
  L: TStringList;
begin
  { "äöüßéè" - 12 bytes but 6 columns: wrapping uses the visible width. }
  L := WrapText('äöüßéè Welt', 8, @Measure);
  try
    AssertEquals('number of fragments', 2, L.Count);
    AssertEquals('first', 'äöüßéè', L[0]);
    AssertEquals('second', 'Welt', L[1]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapHardBreak;
var
  L: TStringList;
begin
  { A word longer than the line is broken forcibly. }
  L := WrapText('abcdefghijkl', 5, @Measure);
  try
    AssertEquals('number of fragments', 3, L.Count);
    AssertEquals('first', 'abcd', L[0]);
    AssertEquals('second', 'efgh', L[1]);
    AssertEquals('third', 'ijkl', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapLeadingSpace;
var
  L: TStringList;
begin
  { The leading spaces of the first fragment (the indent) are kept; the following
    fragments drop their leading spaces. }
  L := WrapText('  foo bar', 5, @Measure);
  try
    AssertEquals('number of fragments', 3, L.Count);
    AssertEquals('first - with the indent', '  fo', L[0]);
    AssertEquals('second', 'o', L[1]);
    AssertEquals('third', 'bar', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapKeepsIndent;
var
  L: TStringList;
begin
  { Short line: the leading spaces (the indent) are not lost. }
  L := WrapText('  indented', 20, @Measure);
  try
    AssertEquals('one fragment', 1, L.Count);
    AssertEquals('the indent is kept', '  indented', L[0]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapKeepsIndentWhenWrapping;
var
  L: TStringList;
begin
  { Long indented line: the first fragment keeps the indent,
    the following ones start with the first character. }
  L := WrapText('    hello world', 12, @Measure);
  try
    AssertEquals('number of fragments', 2, L.Count);
    AssertEquals('first - with the indent', '    hello', L[0]);
    AssertEquals('second - without a leading space', 'world', L[1]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapSpacesOnly;
var
  L: TStringList;
begin
  { A line of only spaces - one empty line. }
  L := WrapText('   ', 20, @Measure);
  try
    AssertEquals('one fragment', 1, L.Count);
    AssertEquals('empty line', '', L[0]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestWrapDropsExtraSpacesAfterBreak;
var
  L: TStringList;
begin
  { Several spaces at the break: the separator is dropped, the next
    fragment does not start with a space. }
  L := WrapText('word  word', 5, @Measure);
  try
    AssertEquals('number of fragments', 2, L.Count);
    AssertEquals('first', 'word', L[0]);
    AssertEquals('second - without leading spaces', 'word', L[1]);
  finally
    L.Free;
  end;
end;
procedure TUtilTests.TestWrapAvoidsMarkup;
var
  L: TStringList;
  { Without the filter the break would land inside **bold** ("aa **bb"): the wrap
    must pick a safe point - after the closing "**". }
begin
  L := WrapText('aa **bb cc** dd', 10, @Measure, @Safe);
  try
    AssertEquals('number of fragments', 3, L.Count);
    AssertEquals('first', 'aa', L[0]);
    AssertEquals('second - markup kept whole', '**bb cc**', L[1]);
    AssertEquals('third', 'dd', L[2]);
  finally
    L.Free;
  end;
end;

procedure TUtilTests.TestDimSGRFullBrightness;
begin
  { Brightness 1 - the code is unchanged. }
  AssertEquals('basic', '36', DimSGR('36', 1.0));
  AssertEquals('256-color', '38;5;101', DimSGR('38;5;101', 1.0));
  AssertEquals('attributes', '1;96', DimSGR('1;96', 1.0));
  AssertEquals('reset', '0', DimSGR('0', 1.0));
  AssertEquals('empty', '', DimSGR('', 1.0));
end;

procedure TUtilTests.TestDimSGRBasicColor;
begin
  { 36 is cyan (5,195,195): at 0.5 -> (2,98,98) (Round rounds to even). }
  AssertEquals('basic color as 24-bit', '38;2;2;98;98', DimSGR('36', 0.5));
  { 90 is gray (75,75,75): at 0.5 -> (38,38,38). }
  AssertEquals('bright gray', '38;2;38;38;38', DimSGR('90', 0.5));
end;

procedure TUtilTests.TestDimSGR256Color;
begin
  { 38;5;101 is (135,135,95): at 0.5 -> (68,68,48). }
  AssertEquals('cube', '38;2;68;68;48', DimSGR('38;5;101', 0.5));
  { 38;5;250 is the gray gradient (188,188,188): at 0.5 -> (94,94,94). }
  AssertEquals('gradient', '38;2;94;94;94', DimSGR('38;5;250', 0.5));
end;

procedure TUtilTests.TestDimSGRTrueColor;
begin
  AssertEquals('24-bit', '38;2;128;0;0', DimSGR('38;2;255;0;0', 0.5));
end;

procedure TUtilTests.TestDimSGRKeepsAttributes;
begin
  { Attributes (bold, dim) are kept, the color is recalculated. }
  AssertEquals('bold + bright cyan', '1;38;2;2;128;128', DimSGR('1;96', 0.5));
  AssertEquals('dim + yellow', '2;38;2;128;128;2', DimSGR('2;93', 0.5));
  AssertEquals('color before an attribute', '38;2;68;68;48;1', DimSGR('38;5;101;1', 0.5));
end;

procedure TUtilTests.TestDimSGRNonColor;
begin
  { Non-color attributes are returned as is. }
  AssertEquals('reset', '0', DimSGR('0', 0.5));
  AssertEquals('bold', '1', DimSGR('1', 0.5));
  AssertEquals('italic', '3', DimSGR('3', 0.5));
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
    AssertEquals('identical lists - an empty diff', '',
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
    { A is empty, B has lines. }
    B.Add('line1');
    B.Add('line2');
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f');
    AssertTrue('--- header present', Pos('--- a/f', D) > 0);
    AssertTrue('+++ header present', Pos('+++ b/f', D) > 0);
    AssertTrue('@@ -0,0 +1,2 @@ present', Pos('@@ -0,0 +1,2 @@', D) > 0);
    AssertTrue('+line1 line', Pos('+line1', D) > 0);
    AssertTrue('+line2 line', Pos('+line2', D) > 0);
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
    { B is empty. }
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f');
    AssertTrue('@@ -1,2 +0,0 @@ present', Pos('@@ -1,2 +0,0 @@', D) > 0);
    AssertTrue('-line1 line', Pos('-line1', D) > 0);
    AssertTrue('-line2 line', Pos('-line2', D) > 0);
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
    AssertTrue('-old1 present', Pos('-old1', D) > 0);
    AssertTrue('-old2 present', Pos('-old2', D) > 0);
    AssertTrue('+new1 present', Pos('+new1', D) > 0);
    AssertTrue('+new2 present', Pos('+new2', D) > 0);
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
    AssertTrue('context same1', Pos(' same1', D) > 0);
    AssertTrue('old removed', Pos('-old', D) > 0);
    AssertTrue('new added', Pos('+new', D) > 0);
    AssertTrue('context same2', Pos(' same2', D) > 0);
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
    { Change line 5. }
    B[4] := 'CHANGED';
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f', 1, 2);
    AssertTrue('-line5 present', Pos('-line5', D) > 0);
    AssertTrue('+CHANGED present', Pos('+CHANGED', D) > 0);
    { Context 2: lines 3,4 and 6,7 must be present. }
    AssertTrue('context line3', Pos(' line3', D) > 0);
    AssertTrue('context line4', Pos(' line4', D) > 0);
    AssertTrue('context line6', Pos(' line6', D) > 0);
    AssertTrue('context line7', Pos(' line7', D) > 0);
    { Lines 1,2,8,9,10 must not be present (outside the context). }
    AssertFalse('line1 outside the context', Pos(' line1', D) > 0);
    AssertFalse('line10 outside the context', Pos(' line10', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

{ Two distant edits: the line numbers in the hunks are counted over the whole file
  although the LCS is now built only for the "middle" (between the common prefix
  and suffix). }
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
    AssertTrue('the first hunk with numbers 1 - ' + D, Pos('@@ -1,1 +1,1 @@', D) > 0);
    AssertTrue('the second hunk with numbers 10 - ' + D, Pos('@@ -10,1 +10,1 @@', D) > 0);
    AssertTrue('line 1 removed', Pos('-a1' + sLineBreak, D) > 0);
    AssertTrue('line X1 added', Pos('+X1' + sLineBreak, D) > 0);
    AssertTrue('line 10 removed', Pos('-a10' + sLineBreak, D) > 0);
    AssertTrue('line X10 added', Pos('+X10' + sLineBreak, D) > 0);

    { The start number of the first hunk is shifted by the OldStartLine argument. }
    D := MakeUnifiedDiff(A, B, 'a/f', 'b/f', 100, 1);
    AssertTrue('the hunk starts at line 100 - ' + D, Pos('@@ -100,2 +100,2 @@', D) > 0);
    AssertTrue('the hunk at the end of the file - ' + D, Pos('@@ -108,2 +108,2 @@', D) > 0);
  finally
    A.Free;
    B.Free;
  end;
end;

{ Regression: the LCS was built over the whole file (N*M cells) and editing a large
  file practically hung (8k lines - 4.3 s, 50k - more than a minute). After cutting
  the common prefix/suffix the diff is linear in time. }
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

    AssertTrue('the change got into the diff - ' + D, Pos('+line-CHANGED', D) > 0);
    AssertTrue('a single hunk - ' + D, Pos('@@ -9997,7 +9997,7 @@', D) > 0);
    AssertTrue('diff over 20k lines is fast: ' + IntToStr(T0) + ' ms', T0 < 10000);
  finally
    A.Free;
    B.Free;
  end;
end;

{ --- RunProcess: protection against hangs --- }

procedure TUtilTests.TestRunProcessExitCode;
var
  OutText, Err: string;
  EC: Integer;
begin
  AssertTrue('the process finished',
    RunProcess('exit 3', '', 10, OutText, EC, Err));
  AssertTrue('non-zero exit code', EC <> 0);
end;

procedure TUtilTests.TestRunProcessStdinEof;
var
  OutText, Err: string;
  EC: Integer;
begin
  {$IFDEF UNIX}
  { A command reading stdin must get EOF (a closed input) instead of
    waiting for input until the timeout. Regression: cat hung until shell_timeout. }
  AssertTrue('reading stdin does not hang',
    RunProcess('cat', '', 5, OutText, EC, Err));
  {$ELSE}
  AssertTrue('stub', True);
  {$ENDIF}
end;

procedure TUtilTests.TestRunProcessTimeout;
var
  OutText, Err: string;
  EC: Integer;
begin
  {$IFDEF UNIX}
  AssertFalse('the timeout fires',
    RunProcess('sleep 30', '', 1, OutText, EC, Err));
  AssertTrue('timeout message', Pos('timed out', Err) > 0);
  {$ELSE}
  AssertTrue('stub', True);
  {$ENDIF}
end;

procedure TUtilTests.TestRunProcessNoTty;
var
  OutText, Err: string;
  EC: Integer;
begin
  {$IFDEF UNIX}
  { The child process starts in a new session and does not inherit the controlling
    terminal: interactive commands (sudo, ssh, editors) cannot open
    /dev/tty and hang waiting for a password. }
  AssertTrue('the process finished',
    RunProcess('if [ -c /dev/tty ] && (exec 3</dev/tty) 2>/dev/null; then ' +
      'echo TTY_OPEN_OK; else echo TTY_OPEN_FAIL; fi', '', 5, OutText, EC, Err));
  AssertTrue('/dev/tty is not reachable', Pos('TTY_OPEN_FAIL', OutText) > 0);
  AssertFalse('/dev/tty did not open', Pos('TTY_OPEN_OK', OutText) > 0);
  {$ELSE}
  AssertTrue('stub', True);
  {$ENDIF}
end;

procedure TUtilTests.TestRunProcessMaxOutputTruncates;
var
  OutText, Err: string;
  EC: Integer;
  Total: Int64;
begin
  { The output is longer than the limit: Output keeps exactly MaxOutput bytes, but
    everything is drained from the process (otherwise it blocks on a full pipe),
    so TotalBytes is greater than the limit. }
  AssertTrue('the process finished',
    RunProcess('echo ' + StringOfChar('x', 200), '', 10, OutText, EC, Err, 10, Total));
  AssertEquals('the output is truncated to the limit', StringOfChar('x', 10), OutText);
  AssertTrue('more than the limit was read: ' + IntToStr(Total), Total >= 200);

  { MaxOutput = 0 means no limit: the output arrives in full. }
  AssertTrue('the process finished (no limit)',
    RunProcess('echo abcdefghij', '', 10, OutText, EC, Err, 0, Total));
  AssertTrue('without a limit the output is not truncated', Pos('abcdefghij', OutText) > 0);
  AssertTrue('the counter counts what was read: ' + IntToStr(Total), Total >= 10);
end;

procedure TUtilTests.TestRunProcessMaxOutputUtf8;
var
  OutText, Err: string;
  EC: Integer;
  Total: Int64;
begin
  {$IFDEF UNIX}
  { "äöüßéè" - 12 bytes; a 5-byte limit must not break a character:
    "äö" (4 bytes) remains, TotalBytes counts all 12 bytes read. }
  AssertTrue('the process finished',
    RunProcess('printf "äöüßéè"', '', 10, OutText, EC, Err, 5, Total));
  AssertEquals('truncation at a character boundary', 'äö', OutText);
  AssertTrue('valid UTF-8', IsValidUTF8(OutText));
  AssertEquals('the counter counts all bytes', 12, Total);
  {$ELSE}
  { Printing multi-byte UTF-8 reliably is impossible in cmd.exe - the counter and
    the truncation are already covered by the ASCII test through the same RunProcess. }
  AssertTrue('stub', True);
  {$ENDIF}
end;

initialization
  RegisterTest(TUtilTests);
end.
