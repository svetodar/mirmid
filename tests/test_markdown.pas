unit test_markdown;
{ Тесты разбора разметки markdown (mirmid.markdown). }

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
  AssertEquals('обычный текст', 'Привет, мир', StripMarkdown('Привет, мир'));
  AssertEquals('переносы сохраняются', 'a' + sLineBreak + 'b',
    StripMarkdown('a' + sLineBreak + 'b'));
  AssertEquals('CRLF', 'a' + sLineBreak + 'b',
    StripMarkdown('a' + #13#10 + 'b'));
end;

procedure TMarkdownTests.TestStripInline;
begin
  AssertEquals('жирный/курсив/код', 'жирный и курсив и код',
    StripMarkdown('**жирный** и *курсив* и `код`'));
  AssertEquals('подчёркивание', 'x', StripMarkdown('_x_'));
  AssertEquals('зачёркнутый', 'y', StripMarkdown('~~y~~'));
  AssertEquals('ссылка — только текст', 'текст',
    StripMarkdown('[текст](http://example.com)'));
end;

procedure TMarkdownTests.TestStripBlocks;
begin
  AssertEquals('заголовок', 'Заголовок', StripMarkdown('# Заголовок'));
  AssertEquals('цитата', 'цитата', StripMarkdown('> цитата'));
  AssertEquals('маркер списка сохраняется', '- пункт',
    StripMarkdown('- пункт'));
  AssertEquals('ограждённый блок без оград', 'a = 1',
    StripMarkdown('```' + sLineBreak + 'a = 1' + sLineBreak + '```'));
end;

procedure TMarkdownTests.TestColoredHeadingsAndLists;
var
  R: string;
begin
  R := RenderMarkdownCore('# H', True);
  AssertTrue('код заголовка', Pos(#27 + '[' + DimSGR('1;96') + 'mH', R) > 0);
  AssertTrue('сброс в конце', Pos(#27 + '[0m', R) > 0);

  R := RenderMarkdownCore('- item **b**', True);
  AssertTrue('цвет маркера списка', Pos(#27 + '[' + DimSGR('38;5;46') + 'm-', R) > 0);
  AssertTrue('жирный внутри списка', Pos(#27 + '[1mb', R) > 0);
end;

procedure TMarkdownTests.TestColoredCodeBlock;
var
  R: string;
begin
  R := RenderMarkdownCore('```' + sLineBreak + 'x := 1;' + sLineBreak + '```', True);
  AssertTrue('цвет блока кода', Pos(#27 + '[' + DimSGR('38;5;245') + 'mx := 1;', R) > 0);
end;

procedure TMarkdownTests.TestColoredLink;
var
  R: string;
begin
  R := RenderMarkdownCore('[ссылка](http://x)', True);
  AssertTrue('подчёркнутый голубой', Pos(#27 + '[' + DimSGR('4;36') + 'm', R) > 0);
  AssertFalse('URL не печатается', Pos('http://x', R) > 0);
end;

procedure TMarkdownTests.TestNestedBoldItalic;
var
  R: string;
begin
  R := RenderMarkdownCore('**a *b* c**', True);
  AssertTrue('комбинация жирный+курсив', Pos(#27 + '[1;3mb', R) > 0);
end;

procedure TMarkdownTests.TestNoEscapesInPlainMode;
var
  R: string;
begin
  R := RenderMarkdownCore('# H' + sLineBreak + '**b**' + sLineBreak + '`c`' +
    sLineBreak + '[t](u)', False);
  AssertFalse('в чистом тексте нет escape-кодов', Pos(#27, R) > 0);
  AssertEquals('разметка снята', 'H' + sLineBreak + 'b' + sLineBreak + 'c' +
    sLineBreak + 't', R);
end;

procedure TMarkdownTests.TestTableAlignment;
var
  R: string;
begin
  R := StripMarkdown('| a | bb |' + sLineBreak +
    '|---|----|' + sLineBreak +
    '| ccc | d |');
  AssertEquals('колонки выровнены по максимальной ширине',
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
  R := StripMarkdown('текст' + sLineBreak +
    '| x | y |' + sLineBreak +
    '|---|---|' + sLineBreak +
    '| long | z |' + sLineBreak +
    'хвост');
  AssertEquals('таблица внутри текста выравнивается целиком',
    'текст' + sLineBreak +
    '┌──────┬───┐' + sLineBreak +
    '│ x    │ y │' + sLineBreak +
    '├──────┼───┤' + sLineBreak +
    '│ long │ z │' + sLineBreak +
    '└──────┴───┘' + sLineBreak +
    'хвост',
    R);
end;

procedure TMarkdownTests.TestTableNotDetected;
begin
  AssertEquals('одна пипа — не таблица', '| a', StripMarkdown('| a'));
  AssertEquals('пипа не в начале — не таблица', 'a | b', StripMarkdown('a | b'));
end;

procedure TMarkdownTests.TestTableNeedsSeparator;
var
  R: string;
begin
  { Достаточно длинная строка, которая раньше превращалась в целую таблицу.
    Без строки-разделителя это обычный текст (GFM): иначе при потоковом
    выводе каждая новая строка рисовалась бы отдельным блоком. }
  R := StripMarkdown('| read_text_file / edit_text_file / copy_file | OK |');
  AssertEquals('одна строка без разделителя — не таблица',
    '| read_text_file / edit_text_file / copy_file | OK |', R);
  AssertEquals('две строки без разделителя — не таблица',
    '| a | b |' + sLineBreak + '| c | d |',
    StripMarkdown('| a | b |' + sLineBreak + '| c | d |'));
  { С разделителем таблица по-прежнему рисуется. }
  R := StripMarkdown('| a | b |' + sLineBreak + '|---|---|' + sLineBreak +
    '| c | d |');
  AssertTrue('с разделителем — таблица',
    Pos('┌', R) = 1);
end;

procedure TMarkdownTests.TestColoredTable;
var
  R: string;
begin
  R := RenderMarkdownCore('| a | b |' + sLineBreak + '|---|---|' + sLineBreak +
    '| c | d |', True);
  AssertTrue('верхняя граница серая', Pos(#27 + '[' + DimSGR('90') + 'm┌───┬───┐' + #27 + '[0m', R) > 0);
  AssertTrue('разделитель серая', Pos(#27 + '[' + DimSGR('90') + 'm├───┼───┤' + #27 + '[0m', R) > 0);
  AssertTrue('нижняя граница серая', Pos(#27 + '[' + DimSGR('90') + 'm└───┴───┘' + #27 + '[0m', R) > 0);
  AssertTrue('вертикальная черта серая', Pos(#27 + '[' + DimSGR('90') + 'm│' + #27 + '[0m', R) > 0);
end;

procedure TMarkdownTests.TestVisibleLenWide;
begin
  AssertEquals('латиница — 1 колонка', 1, VisibleLen('a'));
  AssertEquals('кириллица — 1 колонка', 1, VisibleLen('а'));
  AssertEquals('эмодзи ✅ — 2 колонки', 2, VisibleLen('✅'));
  AssertEquals('CJK — 2 колонки', 2, VisibleLen('中'));
  AssertEquals('полная форма — 2 колонки', 2, VisibleLen('Ａ'));
  AssertEquals('ZWJ — 0 колонок', 0, VisibleLen(#$E2#$80#$8D));
  AssertEquals('комбинируемая диакритика — 0', 1,
    VisibleLen('e' + #$CC#$81));
  AssertEquals('ANSI-коды не считаются', 3,
    VisibleLen(#27 + '[1m' + 'abc' + #27 + '[0m'));
  AssertEquals('смешанная строка', 5, VisibleLen('a✅中'));
end;

procedure TMarkdownTests.TestTableWideChars;
var
  R: string;
begin
  { ✅ занимает 2 колонки: выравнивание учитывает это. }
  R := StripMarkdown('| a | bb |' + sLineBreak +
    '|---|----|' + sLineBreak +
    '| ✅ | d |');
  AssertEquals('широкий символ учитывается в ширине колонки',
    '┌────┬────┐' + sLineBreak +
    '│ a  │ bb │' + sLineBreak +
    '├────┼────┤' + sLineBreak +
    '│ ✅ │ d  │' + sLineBreak +
    '└────┴────┘',
    R);
end;

procedure TMarkdownTests.TestTableStart;
begin
  AssertTrue('«|» — возможное начало таблицы', IsTableStart('|'));
  AssertTrue('обрезанная строка с «|»', IsTableStart('  | a'));
  AssertTrue('полная строка таблицы', IsTableStart('| a | b |'));
  AssertFalse('текст не начало таблицы', IsTableStart('a | b'));
  AssertFalse('пустая строка', IsTableStart(''));
end;

procedure TMarkdownTests.TestBreakSafe;
begin
  AssertTrue('обычный текст', MarkdownBreakSafe('обычный'));
  AssertFalse('внутри жирного', MarkdownBreakSafe('**жирный'));
  AssertTrue('после жирного', MarkdownBreakSafe('**жирный**'));
  AssertFalse('внутри курсива', MarkdownBreakSafe('*курсив'));
  AssertTrue('после курсива', MarkdownBreakSafe('*курсив*'));
  AssertFalse('внутри кода', MarkdownBreakSafe('`код'));
  AssertTrue('после кода', MarkdownBreakSafe('`код`'));
  AssertFalse('внутри зачёркнутого', MarkdownBreakSafe('~~текст'));
  AssertTrue('после зачёркнутого', MarkdownBreakSafe('~~текст~~'));
  AssertFalse('внутри ссылки', MarkdownBreakSafe('[текст'));
  AssertTrue('после ссылки', MarkdownBreakSafe('[текст]'));
end;

procedure TMarkdownTests.TestBoxDrawingNarrow;
begin
  { Псевдографика занимает одну колонку: иначе таблица ошибочно считается
    шире терминала и перестаёт выравниваться. }
  AssertEquals('верхняя граница', 9, VisibleLen('┌───┬───┐'));
  AssertEquals('строка данных', 9, VisibleLen('│ a │ b │'));
  AssertEquals('нижняя граница', 9, VisibleLen('└───┴───┘'));
end;

initialization
  RegisterTest(TMarkdownTests);

end.
