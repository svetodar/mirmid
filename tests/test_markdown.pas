unit test_markdown;
{ Tests for markdown parsing (mirmid.markdown). }

{$mode objfpc}{$H+}

interface

uses
  Classes, StrUtils, fpcunit, testregistry, mirmid.markdown, mirmid.util;

type
  TMarkdownTests = class(TTestCase)
  published
    procedure TestStripPlain;
    procedure TestStripInline;
    procedure TestStripBlocks;
    procedure TestColoredHeadingsAndLists;
    procedure TestColoredCodeBlock;
    procedure TestColoredLink;
    procedure TestNestedBoldItalic;
    procedure TestNoEscapesInPlainMode;
    procedure TestTableAlignment;
    procedure TestTableInText;
    procedure TestTableNotDetected;
    procedure TestTableNeedsSeparator;
    procedure TestColoredTable;
    procedure TestVisibleLenWide;
    procedure TestTableWideChars;
    procedure TestTableStart;
    procedure TestBoxDrawingNarrow;
    procedure TestBreakSafe;
    procedure TestTableWidthsProportional;
    procedure TestTableCellWordWrap;
    procedure TestTableLongWordBreak;
    procedure TestTableWrapWideChars;
    procedure TestTableWrapInlineMarkup;
    procedure TestTableSqueezedForceBreak;
    procedure TestTableNoMaxWidth;
  end;

implementation

procedure TMarkdownTests.TestStripPlain;
begin
  AssertEquals('plain text', 'Hello, world', StripMarkdown('Hello, world'));
  AssertEquals('line breaks are preserved', 'a' + sLineBreak + 'b',
    StripMarkdown('a' + sLineBreak + 'b'));
  AssertEquals('CRLF', 'a' + sLineBreak + 'b',
    StripMarkdown('a' + #13#10 + 'b'));
end;

procedure TMarkdownTests.TestStripInline;
begin
  AssertEquals('bold/italic/code', 'bold and italic and code',
    StripMarkdown('**bold** and *italic* and `code`'));
  AssertEquals('underscore', 'x', StripMarkdown('_x_'));
  AssertEquals('strikethrough', 'y', StripMarkdown('~~y~~'));
  AssertEquals('link: text only', 'text',
    StripMarkdown('[text](http://example.com)'));
end;

procedure TMarkdownTests.TestStripBlocks;
begin
  AssertEquals('heading', 'Heading', StripMarkdown('# Heading'));
  AssertEquals('quote', 'quote', StripMarkdown('> quote'));
  AssertEquals('list marker is preserved', '- entry',
    StripMarkdown('- entry'));
  AssertEquals('fenced block without fences', 'a = 1',
    StripMarkdown('```' + sLineBreak + 'a = 1' + sLineBreak + '```'));
end;

procedure TMarkdownTests.TestColoredHeadingsAndLists;
var
  R: string;
begin
  R := RenderMarkdownCore('# H', True);
  AssertTrue('heading code', Pos(#27 + '[' + DimSGR('1;96') + 'mH', R) > 0);
  AssertTrue('reset at the end', Pos(#27 + '[0m', R) > 0);

  R := RenderMarkdownCore('- item **b**', True);
  AssertTrue('list marker color', Pos(#27 + '[' + DimSGR('38;5;46') + 'm-', R) > 0);
  AssertTrue('bold inside a list', Pos(#27 + '[1mb', R) > 0);
end;

procedure TMarkdownTests.TestColoredCodeBlock;
var
  R: string;
begin
  R := RenderMarkdownCore('```' + sLineBreak + 'x := 1;' + sLineBreak + '```', True);
  AssertTrue('code block color', Pos(#27 + '[' + DimSGR('38;5;245') + 'mx := 1;', R) > 0);
end;

procedure TMarkdownTests.TestColoredLink;
var
  R: string;
begin
  R := RenderMarkdownCore('[link](http://x)', True);
  AssertTrue('underlined cyan', Pos(#27 + '[' + DimSGR('4;36') + 'm', R) > 0);
  AssertFalse('URL is not printed', Pos('http://x', R) > 0);
end;

procedure TMarkdownTests.TestNestedBoldItalic;
var
  R: string;
begin
  R := RenderMarkdownCore('**a *b* c**', True);
  AssertTrue('bold+italic combination', Pos(#27 + '[1;3mb', R) > 0);
end;

procedure TMarkdownTests.TestNoEscapesInPlainMode;
var
  R: string;
begin
  R := RenderMarkdownCore('# H' + sLineBreak + '**b**' + sLineBreak + '`c`' +
    sLineBreak + '[t](u)', False);
  AssertFalse('no escape codes in plain text', Pos(#27, R) > 0);
  AssertEquals('markup is stripped', 'H' + sLineBreak + 'b' + sLineBreak + 'c' +
    sLineBreak + 't', R);
end;

procedure TMarkdownTests.TestTableAlignment;
var
  R: string;
begin
  R := StripMarkdown('| a | bb |' + sLineBreak +
    '|---|----|' + sLineBreak +
    '| ccc | d |');
  AssertEquals('columns are aligned to the maximum width',
    '┌─────┬────┐' + sLineBreak +
    '│ a   │ bb │' + sLineBreak +
    '├─────┼────┤' + sLineBreak +
    '│ ccc │ d  │' + sLineBreak +
    '└─────┴────┘',
    R);
end;

procedure TMarkdownTests.TestTableInText;
var
  R: string;
begin
  R := StripMarkdown('lead' + sLineBreak +
    '| x | y |' + sLineBreak +
    '|---|---|' + sLineBreak +
    '| long | z |' + sLineBreak +
    'tail');
  AssertEquals('a table inside text is aligned as a whole',
    'lead' + sLineBreak +
    '┌──────┬───┐' + sLineBreak +
    '│ x    │ y │' + sLineBreak +
    '├──────┼───┤' + sLineBreak +
    '│ long │ z │' + sLineBreak +
    '└──────┴───┘' + sLineBreak +
    'tail',
    R);
end;

procedure TMarkdownTests.TestTableNotDetected;
begin
  AssertEquals('a single pipe is not a table', '| a', StripMarkdown('| a'));
  AssertEquals('a pipe not at the start is not a table', 'a | b', StripMarkdown('a | b'));
end;

procedure TMarkdownTests.TestTableNeedsSeparator;
var
  R: string;
begin
  { A long enough line that used to be turned into a whole table. Without a
    separator row this is plain text (GFM): otherwise every new line would be
    drawn as a separate block in streaming output. }
  R := StripMarkdown('| read_text_file / edit_text_file / copy_file | OK |');
  AssertEquals('one line without a separator is not a table',
    '| read_text_file / edit_text_file / copy_file | OK |', R);
  AssertEquals('two lines without a separator are not a table',
    '| a | b |' + sLineBreak + '| c | d |',
    StripMarkdown('| a | b |' + sLineBreak + '| c | d |'));
  { With a separator the table is still drawn. }
  R := StripMarkdown('| a | b |' + sLineBreak + '|---|---|' + sLineBreak +
    '| c | d |');
  AssertTrue('with a separator it is a table',
    Pos('┌', R) = 1);
end;

procedure TMarkdownTests.TestColoredTable;
var
  R: string;
begin
  R := RenderMarkdownCore('| a | b |' + sLineBreak + '|---|---|' + sLineBreak +
    '| c | d |', True);
  AssertTrue('top border is grey', Pos(#27 + '[' + DimSGR('90') + 'm┌───┬───┐' + #27 + '[0m', R) > 0);
  AssertTrue('separator is grey', Pos(#27 + '[' + DimSGR('90') + 'm├───┼───┤' + #27 + '[0m', R) > 0);
  AssertTrue('bottom border is grey', Pos(#27 + '[' + DimSGR('90') + 'm└───┴───┘' + #27 + '[0m', R) > 0);
  AssertTrue('vertical bar is grey', Pos(#27 + '[' + DimSGR('90') + 'm│' + #27 + '[0m', R) > 0);
end;

procedure TMarkdownTests.TestVisibleLenWide;
begin
  AssertEquals('latin: 1 column', 1, VisibleLen('a'));
  AssertEquals('accented latin: 1 column', 1, VisibleLen('é'));
  AssertEquals('emoji ✅: 2 columns', 2, VisibleLen('✅'));
  AssertEquals('CJK: 2 columns', 2, VisibleLen('中'));
  AssertEquals('fullwidth form: 2 columns', 2, VisibleLen('Ａ'));
  AssertEquals('ZWJ: 0 columns', 0, VisibleLen(#$E2#$80#$8D));
  AssertEquals('combining diacritic: 0', 1,
    VisibleLen('e' + #$CC#$81));
  AssertEquals('ANSI codes are not counted', 3,
    VisibleLen(#27 + '[1m' + 'abc' + #27 + '[0m'));
  AssertEquals('mixed string', 5, VisibleLen('a✅中'));
end;

procedure TMarkdownTests.TestTableWideChars;
var
  R: string;
begin
  { ✅ occupies 2 columns: the alignment takes that into account. }
  R := StripMarkdown('| a | bb |' + sLineBreak +
    '|---|----|' + sLineBreak +
    '| ✅ | d |');
  AssertEquals('a wide character is counted in the column width',
    '┌────┬────┐' + sLineBreak +
    '│ a  │ bb │' + sLineBreak +
    '├────┼────┤' + sLineBreak +
    '│ ✅ │ d  │' + sLineBreak +
    '└────┴────┘',
    R);
end;

procedure TMarkdownTests.TestTableStart;
begin
  AssertTrue('"|" may start a table', IsTableStart('|'));
  AssertTrue('a truncated line with "|"', IsTableStart('  | a'));
  AssertTrue('a full table line', IsTableStart('| a | b |'));
  AssertFalse('text does not start a table', IsTableStart('a | b'));
  AssertFalse('empty line', IsTableStart(''));
end;

procedure TMarkdownTests.TestBreakSafe;
begin
  AssertTrue('plain text', MarkdownBreakSafe('plain'));
  AssertFalse('inside bold', MarkdownBreakSafe('**bold'));
  AssertTrue('after bold', MarkdownBreakSafe('**bold**'));
  AssertFalse('inside italic', MarkdownBreakSafe('*italic'));
  AssertTrue('after italic', MarkdownBreakSafe('*italic*'));
  AssertFalse('inside code', MarkdownBreakSafe('`code'));
  AssertTrue('after code', MarkdownBreakSafe('`code`'));
  AssertFalse('inside strikethrough', MarkdownBreakSafe('~~text'));
  AssertTrue('after strikethrough', MarkdownBreakSafe('~~text~~'));
  AssertFalse('inside a link', MarkdownBreakSafe('[text'));
  AssertTrue('after a link', MarkdownBreakSafe('[text]'));
  { A marker inside a word is literal for the renderer, so it must not make a
    break unsafe (snake_case, 2*3): wrapping would otherwise give up and keep the
    whole cell on one overflow line. }
  AssertTrue('an underscore inside a word', MarkdownBreakSafe('see foo_bar'));
  AssertTrue('a star between digits', MarkdownBreakSafe('2*3'));
  AssertTrue('a star inside a word', MarkdownBreakSafe('foo*bar'));
  AssertFalse('an underscore opening an italic span', MarkdownBreakSafe('_italic'));
end;

procedure TMarkdownTests.TestBoxDrawingNarrow;
begin
  { Box-drawing characters occupy one column: otherwise a table is wrongly
    considered wider than the terminal and stops being aligned. }
  AssertEquals('top border', 9, VisibleLen('┌───┬───┐'));
  AssertEquals('data row', 9, VisibleLen('│ a │ b │'));
  AssertEquals('bottom border', 9, VisibleLen('└───┴───┘'));
end;

procedure TMarkdownTests.TestTableCellWordWrap;
var
  L, Parts: TStringList;
  R: string;
  I: Integer;
begin
  { A table wider than the limit (MaxWidth = 20): the column widths are squeezed
    by the volume of the text (6 and 7 columns) and long cells are wrapped at
    word boundaries. "x" and "short" share the record line by line with the
    tallest cell; the free space is padded with empty lines at the bottom
    (vertical alignment to the top). }
  L := TStringList.Create;
  try
    L.Add('| alpha beta gamma | x |');
    L.Add('|---|---|');
    L.Add('| short | delta epsilon |');
    R := RenderTable(L, False, 20);
  finally
    L.Free;
  end;
  AssertEquals('words are wrapped inside a cell',
    '┌────────┬─────────┐' + sLineBreak +
    '│ alpha  │ x       │' + sLineBreak +
    '│ beta   │         │' + sLineBreak +
    '│ gamma  │         │' + sLineBreak +
    '├────────┼─────────┤' + sLineBreak +
    '│ short  │ delta   │' + sLineBreak +
    '│        │ epsilon │' + sLineBreak +
    '└────────┴─────────┘',
    R);

  { The wrap does not tear words: three words give three physical lines. }
  Parts := WrapTableCell('alpha beta gamma', 6);
  try
    AssertEquals('number of cell lines', 3, Parts.Count);
    AssertEquals('first word', 'alpha', Parts[0]);
    AssertEquals('second word', 'beta', Parts[1]);
    AssertEquals('third word', 'gamma', Parts[2]);
  finally
    Parts.Free;
  end;

  { No physical line of the table goes past the limit. }
  Parts := TStringList.Create;
  try
    Parts.Text := R;
    for I := 0 to Parts.Count - 1 do
      AssertTrue('the line fits the limit: ' + Parts[I],
        VisibleLen(Parts[I]) <= 20);
  finally
    Parts.Free;
  end;
end;

procedure TMarkdownTests.TestTableLongWordBreak;
var
  L, Parts: TStringList;
  R: string;
  I: Integer;
begin
  { A word that is longer than TABLE_MAX_WORD (20 visible columns) and wider
    than the column is force-broken: the cell is cut into pieces of the column
    width and the continuation pieces stay glued to the same word. }
  Parts := WrapTableCell('abcdefghijklmnopqrstuvwxyz', 10);
  try
    AssertEquals('a long word is broken by the column width', 3, Parts.Count);
    AssertEquals('first piece', 'abcdefghij', Parts[0]);
    AssertEquals('second piece', 'klmnopqrst', Parts[1]);
    AssertEquals('the last piece keeps the tail', 'uvwxyz', Parts[2]);
  finally
    Parts.Free;
  end;

  { The continuation of a broken word is not separated by a space, so the next
    short word joins the tail instead of starting a line of its own. }
  Parts := WrapTableCell('abcdefghijklmnopqrstuvwxyz bc', 10);
  try
    AssertEquals('a short word joins the tail', 3, Parts.Count);
    AssertEquals('the tail keeps the following word', 'uvwxyz bc', Parts[2]);
  finally
    Parts.Free;
  end;

  { A word of exactly TABLE_MAX_WORD columns is not force-broken: it goes in
    whole (the table trims an overflowing line afterwards). }
  Parts := WrapTableCell('abcdefghijklmnopqrst', 6);
  try
    AssertEquals('a word up to the cap stays on one line', 1, Parts.Count);
    AssertEquals('the capped word is kept whole', 'abcdefghijklmnopqrst',
      Parts[0]);
  finally
    Parts.Free;
  end;

  { In a rendered table the broken word becomes several record lines. MaxWidth
    of 14 leaves 10 columns for the only column, so the 26-column word is cut
    into 10 + 10 + 6 and no physical line leaves the limit. }
  L := TStringList.Create;
  try
    L.Add('| abcdefghijklmnopqrstuvwxyz |');
    L.Add('|---|');
    L.Add('| tail |');
    R := RenderTable(L, False, 14);
  finally
    L.Free;
  end;
  AssertEquals('a long word is broken into the table lines',
    '┌────────────┐' + sLineBreak +
    '│ abcdefghij │' + sLineBreak +
    '│ klmnopqrst │' + sLineBreak +
    '│ uvwxyz     │' + sLineBreak +
    '├────────────┤' + sLineBreak +
    '│ tail       │' + sLineBreak +
    '└────────────┘',
    R);

  Parts := TStringList.Create;
  try
    Parts.Text := R;
    for I := 0 to Parts.Count - 1 do
      AssertTrue('the line fits the limit: ' + Parts[I],
        VisibleLen(Parts[I]) <= 14);
  finally
    Parts.Free;
  end;
end;

procedure TMarkdownTests.TestTableWrapWideChars;
var
  L, Parts, Output: TStringList;
  R: string;
  I: Integer;
begin
  { Wide characters (CJK, emoji) occupy two columns: the wrap and the padding
    measure them through VisibleLen, so a character is never torn and the
    columns stay aligned. }
  Parts := WrapTableCell('中文 文字', 5);
  try
    AssertEquals('CJK: two physical lines', 2, Parts.Count);
    AssertEquals('CJK: first line', '中文', Parts[0]);
    AssertEquals('CJK: second line', '文字', Parts[1]);
    AssertEquals('CJK: visible width of a line', 4, VisibleLen(Parts[0]));
  finally
    Parts.Free;
  end;

  { An emoji takes two columns as well, so "✅ ✅" does not fit a three-column
    cell and goes to two lines. }
  Parts := WrapTableCell('✅ ✅', 3);
  try
    AssertEquals('emoji: two physical lines', 2, Parts.Count);
    AssertEquals('emoji: first line', '✅', Parts[0]);
    AssertEquals('an emoji takes two columns', 2, VisibleLen(Parts[0]));
  finally
    Parts.Free;
  end;

  { A CJK table wider than the limit: the columns are squeezed by the volume of
    their text, the cells are wrapped by words, and every physical line is
    exactly 20 visible columns wide (wide characters counted as two). }
  L := TStringList.Create;
  try
    L.Add('| 中文 文字 | alpha beta gamma |');
    L.Add('|---|---|');
    L.Add('| 数据 | delta |');
    R := RenderTable(L, False, 20);
  finally
    L.Free;
  end;
  AssertEquals('CJK: wrap and alignment of wide characters',
    '┌───────┬──────────┐' + sLineBreak +
    '│ 中文  │ alpha    │' + sLineBreak +
    '│ 文字  │ beta     │' + sLineBreak +
    '│       │ gamma    │' + sLineBreak +
    '├───────┼──────────┤' + sLineBreak +
    '│ 数据  │ delta    │' + sLineBreak +
    '└───────┴──────────┘',
    R);
  Output := TStringList.Create;
  try
    Output.Text := R;
    for I := 0 to Output.Count - 1 do
      AssertEquals('a line is exactly at the limit: ' + Output[I], 20,
        VisibleLen(Output[I]));
  finally
    Output.Free;
  end;
end;

procedure TMarkdownTests.TestTableWrapInlineMarkup;
var
  L, Parts, Output: TStringList;
  R: string;
  I: Integer;
begin
  { A break is forbidden while **bold** is still open: the line grows past
    Width instead of showing the markers as text. }
  Parts := WrapTableCell('**long word** x', 5);
  try
    AssertEquals('bold: two physical lines', 2, Parts.Count);
    AssertEquals('the bold span stays whole', '**long word**', Parts[0]);
    AssertTrue('the markup of the first line is closed',
      MarkdownBreakSafe(Parts[0]));
    AssertEquals('the tail moves to the next line', 'x', Parts[1]);
  finally
    Parts.Free;
  end;

  { Inline code: the break is allowed only after the closing backtick. }
  Parts := WrapTableCell('`ab cd` e', 5);
  try
    AssertEquals('code: two physical lines', 2, Parts.Count);
    AssertEquals('the code span stays whole', '`ab cd`', Parts[0]);
    AssertEquals('the tail after the code span', 'e', Parts[1]);
  finally
    Parts.Free;
  end;

  { In a table a bold cell is wrapped together with its text, the markers are
    not shown in plain output, and every physical line fits MaxWidth. With
    MaxWidth = 12 and two columns the content budget is 5 (12 minus three
    rules and four paddings), so the columns get 4 and 1 characters. }
  L := TStringList.Create;
  try
    L.Add('| **a b** c | x |');
    L.Add('|---|---|');
    L.Add('| d | y |');
    R := RenderTable(L, False, 12);
  finally
    L.Free;
  end;
  AssertEquals('bold text in a wrapped cell',
    '┌──────┬───┐' + sLineBreak +
    '│ a b  │ x │' + sLineBreak +
    '│ c    │   │' + sLineBreak +
    '├──────┼───┤' + sLineBreak +
    '│ d    │ y │' + sLineBreak +
    '└──────┴───┘',
    R);
  AssertEquals('no ** markers left in the output', 0, Pos('**', R));
  Output := TStringList.Create;
  try
    Output.Text := R;
    for I := 0 to Output.Count - 1 do
      AssertTrue('a line fits MaxWidth: ' + Output[I],
        VisibleLen(Output[I]) <= 12);
  finally
    Output.Free;
  end;
end;

procedure TMarkdownTests.TestTableWidthsProportional;

  { Column widths are read from the top border: ┌────┬────┐. }
  procedure Measure(const Table: string; out Left, Right: Integer);
  var
    Parts: TStringList;
    First: string;
  begin
    Parts := TStringList.Create;
    try
      Parts.Text := Table;
      First := Parts[0];
    finally
      Parts.Free;
    end;
    { Pos gives a byte offset and the border character is three bytes wide in
      UTF-8, so the left column width comes from the visible length of the
      prefix: "┌" plus WLeft+2 horizontal lines. }
    Left := VisibleLen(Copy(First, 1, Pos('┬', First) - 1)) - 3;
    Right := VisibleLen(First) - Left - 7;
  end;

var
  L: TStringList;
  R: string;
  WLeft, WRight: Integer;
begin
  { Proportional to the volume: the second column holds about twice as much text
    (34 visible columns against 16), so with a content budget of 17 (MaxWidth=24
    minus three rules and four paddings) it gets 11 columns against 6. Neither
    column hits its natural width, so the proportion is visible rather than the
    minimum under the longest word. }
  L := TStringList.Create;
  try
    L.Add('| aa bb cc | gg hh ii jj kk ll |');
    L.Add('|---|---|');
    L.Add('| dd ee ff | mm nn oo pp qq rr |');
    R := RenderTable(L, False, 24);
  finally
    L.Free;
  end;
  Measure(R, WLeft, WRight);
  AssertEquals('content budget', 17, WLeft + WRight);
  AssertEquals('width of the smaller column', 6, WLeft);
  AssertEquals('width of the larger column', 11, WRight);
  AssertTrue('the larger column is wider', WRight > WLeft);

  { The column order does not matter: the same volumes on the other side give
    the same proportion. }
  L := TStringList.Create;
  try
    L.Add('| gg hh ii jj kk ll | aa bb cc |');
    L.Add('|---|---|');
    L.Add('| mm nn oo pp qq rr | dd ee ff |');
    R := RenderTable(L, False, 24);
  finally
    L.Free;
  end;
  Measure(R, WLeft, WRight);
  AssertEquals('wide column first', 11, WLeft);
  AssertEquals('narrow column second', 6, WRight);
end;

procedure TMarkdownTests.TestTableSqueezedForceBreak;
var
  L, Parts: TStringList;
  R: string;
  I: Integer;
begin
  { A word within TABLE_MAX_WORD stays whole by default: the column is
    widened for it rather than the word being cut. }
  Parts := WrapTableCell('abcdefghijklmnopqr', 6);
  try
    AssertEquals('a word within the cap is kept whole by default', 1,
      Parts.Count);
    AssertEquals('the whole word', 'abcdefghijklmnopqr', Parts[0]);
  finally
    Parts.Free;
  end;

  { When the word minimums do not fit the table limit, the table asks for a
    forced break instead of stretching the column past MaxWidth. }
  Parts := WrapTableCell('abcdefghijklmnopqr', 6, True);
  try
    AssertEquals('a forced break of an 18-column word', 3, Parts.Count);
    AssertEquals('first piece', 'abcdef', Parts[0]);
    AssertEquals('second piece', 'ghijkl', Parts[1]);
    AssertEquals('third piece', 'mnopqr', Parts[2]);
  finally
    Parts.Free;
  end;

  { The rendered table fits MaxWidth = 10 (6 content columns plus the frame):
    the word is broken and the borders stay aligned. }
  L := TStringList.Create;
  try
    L.Add('| abcdefghijklmnopqr |');
    R := RenderTable(L, False, 10);
  finally
    L.Free;
  end;
  AssertEquals('the squeezed table fits the limit',
    '┌────────┐' + sLineBreak +
    '│ abcdef │' + sLineBreak +
    '│ ghijkl │' + sLineBreak +
    '│ mnopqr │' + sLineBreak +
    '└────────┘', R);

  { A character wider than the one-column limit gets a piece of its own: the
    column is not widened to the whole 22-column word. }
  Parts := WrapTableCell('全角文字のセルは二列分', 1);
  try
    AssertEquals('every wide character becomes its own piece', 11,
      Parts.Count);
    AssertEquals('the first piece', '全', Parts[0]);
    AssertEquals('the last piece', '分', Parts[10]);
  finally
    Parts.Free;
  end;

  { A cut between the two characters of a doubled marker would show `~~` as
    text in both pieces: such a word is kept whole instead. }
  Parts := WrapTableCell('~~strike~~', 1, True);
  try
    AssertEquals('a doubled marker is not split', 1, Parts.Count);
    AssertEquals('the whole word', '~~strike~~', Parts[0]);
  finally
    Parts.Free;
  end;

  { The one-character floor of a squeezed column comes out of the budget, so the
    table does not overshoot MaxWidth: 12 = 2 columns * 3 (bar plus two padding
    spaces) + 1 closing border + 5 content columns. }
  L := TStringList.Create;
  try
    L.Add('| aaaa bbbb | c |');
    L.Add('| d | eeee ffff |');
    R := RenderTable(L, False, 12);
  finally
    L.Free;
  end;
  Parts := TStringList.Create;
  try
    Parts.Text := R;
    for I := 0 to Parts.Count - 1 do
      AssertTrue('a row stays inside the limit: ' + Parts[I],
        VisibleLen(Parts[I]) <= 12);
    AssertTrue('the table is not narrower than needed either',
      VisibleLen(Parts[0]) = 12);
  finally
    Parts.Free;
  end;
end;

procedure TMarkdownTests.TestTableNoMaxWidth;
var
  L, Parts: TStringList;
  R, Explicit: string;
  I: Integer;
begin
  { Without MaxWidth (the default 0) the table is rendered at its natural
    width: five records keep one physical line each, every column is exactly as
    wide as its longest cell, and nothing is wrapped or trimmed. }
  L := TStringList.Create;
  try
    L.Add('| name | value |');
    L.Add('|---|---|');
    L.Add('| alpha | 1 |');
    L.Add('| beta | 22 |');
    L.Add('| gamma | 333 |');
    L.Add('| delta | 4444 |');
    L.Add('| epsilon | 55555 |');
    R := RenderTable(L, False);
    { An explicit zero and a limit that is wider than the table give the same
      natural layout. }
    Explicit := RenderTable(L, False, 0);
    AssertEquals('an explicit zero matches the default', R, Explicit);
    AssertEquals('a generous limit does not change the layout', R,
      RenderTable(L, False, 80));
  finally
    L.Free;
  end;

  { The columns are seven and five columns wide and the cells are not wrapped:
    the five records stay five lines, so the table has nine lines in total
    (two borders, the header, the separator and five records). }
  AssertEquals('natural-width table',
    '┌─────────┬───────┐' + sLineBreak +
    '│ name    │ value │' + sLineBreak +
    '├─────────┼───────┤' + sLineBreak +
    '│ alpha   │ 1     │' + sLineBreak +
    '│ beta    │ 22    │' + sLineBreak +
    '│ gamma   │ 333   │' + sLineBreak +
    '│ delta   │ 4444  │' + sLineBreak +
    '│ epsilon │ 55555 │' + sLineBreak +
    '└─────────┴───────┘',
    R);

  Parts := TStringList.Create;
  try
    Parts.Text := R;
    AssertEquals('nine physical lines', 9, Parts.Count);
    for I := 0 to Parts.Count - 1 do
      AssertEquals('every line has the natural width: ' + Parts[I], 19,
        VisibleLen(Parts[I]));
  finally
    Parts.Free;
  end;
end;

initialization
  RegisterTest(TMarkdownTests);

end.
