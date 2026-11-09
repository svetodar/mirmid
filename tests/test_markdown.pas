unit test_markdown;
{ Tests for markdown parsing (mirmid.markdown). }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.markdown, mirmid.util;

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
end;

procedure TMarkdownTests.TestBoxDrawingNarrow;
begin
  { Box-drawing characters occupy one column: otherwise a table is wrongly
    considered wider than the terminal and stops being aligned. }
  AssertEquals('top border', 9, VisibleLen('┌───┬───┐'));
  AssertEquals('data row', 9, VisibleLen('│ a │ b │'));
  AssertEquals('bottom border', 9, VisibleLen('└───┴───┘'));
end;

initialization
  RegisterTest(TMarkdownTests);

end.
