unit test_tools;
{ Тесты встроенных инструментов и политик безопасности.
  Новый контракт файловых инструментов:
   - write_text_file удалён; файл создаётся edit_text_file без hash
     (offset = 0);
   - read_text_file всегда возвращает шапку («[mirmid] файл: ... | размер: N байт |
     строк: N | хеш: ...»), а со второй строки — содержимое;
   - edit_text_file правит диапазон строк, описываемый offset/limit (offset —
     1-базированный номер строки, 0 — дописать в конец, отрицательный — отсчёт
     от конца; limit — сколько строк заменить, не отрицательное) и требует
     hash из шапки для существующего файла. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, mirmid.tools;

type
  TToolTests = class(TTestCase)
  private
    FDir: string;
    FReg: TToolRegistry;
    FCtx: TToolContext;
    { Полный путь к файлу внутри рабочей папки теста. }
    function FullPath(const Name: string): string;
    { Тело ответа read_text_file: всё после первой строки-шапки. }
    function ReadBody(const S: string): string;
    { Хеш из шапки ответа read_text_file: 8 символов после «хеш: ». }
    function ReadHash(const S: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestCreateAndRead;
    procedure TestWriteToolRemoved;
    procedure TestReadMissing;
    procedure TestInvokeRepairsMalformedArgs;
    procedure TestReadEmptyRange;
    procedure TestReadNumbered;
    procedure TestEditRange;
    procedure TestEditInsertKeepsTrailingBreak;
    procedure TestEditAppendToEnd;
    procedure TestEditWholeFileWithoutRange;
    procedure TestEditLimitBeyondEnd;
    procedure TestEditManyLinesJoin;
    procedure TestEditFirstLineBeyondEnd;
    procedure TestEditDeleteRange;
    procedure TestEditNegativeIndices;
    procedure TestEditNegativeLimit;
    procedure TestEditOffsetZeroIgnoresLimit;
    procedure TestEditOffsetTooNegative;
    procedure TestEditHashMismatch;
    procedure TestEditHashRequired;
    procedure TestEditOldContractRejected;
    procedure TestEditAppendWholeFileWarns;
    procedure TestEditLimitMissingHint;
    procedure TestCreateNotFromStart;
    procedure TestWriteDenied;
    procedure TestMirmidDirDenied;
    procedure TestFileList;
    procedure TestShellPolicy;
    procedure TestShellOutputLimitUtf8;
    procedure TestShellOutputLimitTruncates;
    procedure TestShellOutputLimitOnTimeout;
    procedure TestGrepContextAtEndOfFile;
    procedure TestPascalUnitInterface;
    procedure TestPascalProgramWhole;
    procedure TestPascalIgnoresCommentsStringsAndIdents;
    procedure TestPascalBadExtension;
    procedure TestPascalNotUnitOrProgram;
    procedure TestPascalMissingInterface;
    procedure TestPascalMissingImplementation;
    procedure TestPascalImplementationBeforeInterface;
    procedure TestPascalImplementationEndsAtWord;
    procedure TestPascalBom;
    procedure TestPascalEscapedAndDoubledQuote;
    procedure TestPascalUnclosed;
    procedure TestGrepNoDuplicateLines;
  end;

implementation

uses
  Classes, SysUtils, mirmid.types, mirmid.toolbuiltin, mirmid.util;

{ True, если строка — ровно 8 шестнадцатеричных символов. }
function IsHex8(const S: string): Boolean;
var
  I: Integer;
begin
  Result := Length(S) = 8;
  if not Result then
    Exit;
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

{ Содержимое файла, прочитанное в обход инструментов (для проверок «файл не
  изменён»). При ошибке чтения возвращает диагностическую строку. }
function ReadFileText(const Path: string): string;
var
  Err: string;
begin
  Result := '';
  if not ReadTextFile(Path, Result, Err) then
    Result := '<ошибка чтения: ' + Err + '>';
end;

function TToolTests.FullPath(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + Name;
end;

function TToolTests.ReadBody(const S: string): string;
var
  N: Integer;
begin
  N := Pos(sLineBreak, S);
  if N = 0 then
    Exit('');
  Result := Copy(S, N + Length(sLineBreak), MaxInt);
end;

function TToolTests.ReadHash(const S: string): string;
var
  N: Integer;
begin
  N := Pos('хеш: ', S);
  if N = 0 then
    Exit('');
  Result := Copy(S, N + Length('хеш: '), 8);
end;

procedure TToolTests.SetUp;
var
  Cfg: TMirmidConfig;
begin
  FDir := IncludeTrailingPathDelimiter(TempDir) + 'mirmid-test-' + IntToStr(Random(1000000));
  ForceDirectories(FDir);
  ForceDirectories(IncludeTrailingPathDelimiter(FDir) + '.mirmid');
  FReg := TToolRegistry.Create;
  RegisterBuiltinTools(FReg);
  Cfg := DefaultConfig;
  Cfg.WorkDir := FDir;
  Cfg.AllowWrite := True;
  Cfg.AllowShell := False;
  Cfg.ShellTimeout := 10;
  FCtx := MakeToolContext(Cfg);
end;

procedure TToolTests.TearDown;
begin
  FReg.Free;
  DeleteFile(FullPath('a.txt'));
  DeleteFile(FullPath('b.txt'));
  DeleteFile(FullPath('c.txt'));
  DeleteFile(FullPath('demo.pas'));
  DeleteFile(FullPath('demo.dpr'));
  DeleteFile(FullPath('utf8.txt'));
  DeleteFile(FullPath('demo.txt'));
  DeleteFile(FullPath('demo.dpk'));
  DeleteFile(FullPath('nohead.pas'));
  DeleteFile(FullPath('nointf.pas'));
  DeleteFile(FullPath('noimpl.pas'));
  DeleteFile(FullPath('order.pas'));
  DeleteFile(FullPath('new.txt'));
  DeleteFile(FullPath('out.txt'));
  DeleteFile(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'secret.txt');
  DeleteFile(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'new.txt');
  RemoveDir(IncludeTrailingPathDelimiter(FDir) + '.mirmid');
  RemoveDir(FDir);
end;

{ Создание файла через edit_text_file (режим создания, hash не нужен) и чтение
  через read_text_file: проверяем шапку и тело. }
procedure TToolTests.TestCreateAndRead;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('создание файла: ' + O.Text, O.IsError);
  AssertTrue('ответ сообщает о создании: ' + O.Text, Pos('создан файл: ', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertFalse('чтение файла: ' + O.Text, O.IsError);
  AssertEquals('первая строка — шапка', 1, Pos('[mirmid] файл: ', O.Text));
  AssertTrue('размер в шапке: ' + O.Text, Pos('размер: 5 байт', O.Text) > 0);
  AssertTrue('число строк в шапке: ' + O.Text, Pos('строк: 1', O.Text) > 0);

  Hash := ReadHash(O.Text);
  AssertTrue('хеш в шапке — 8 hex-символов: "' + Hash + '"', IsHex8(Hash));
  AssertEquals('тело файла', 'hello', ReadBody(O.Text));
end;

{ write_text_file удалён: инструмент не зарегистрирован, вызов — ошибка. }
procedure TToolTests.TestWriteToolRemoved;
var
  O: TToolOutcome;
begin
  AssertFalse('write_text_file не зарегистрирован', FReg.Has('write_text_file'));

  O := FReg.Invoke('write_text_file', '{"path":"a.txt","content":"hello"}', FCtx);
  AssertTrue('вызов удалённого инструмента — ошибка: ' + O.Text, O.IsError);
  AssertTrue('сообщение о неизвестном инструменте: ' + O.Text,
    Pos('неизвестный инструмент', O.Text) > 0);
  AssertFalse('файл не создан', FileExists(FullPath('a.txt')));
end;

procedure TToolTests.TestReadMissing;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('read_text_file', '{"path":"missing.txt"}', FCtx);
  AssertTrue('несуществующий файл — ошибка: ' + O.Text, O.IsError);
  AssertTrue('сообщение «файл не найден»: ' + O.Text,
    Pos('файл не найден', O.Text) > 0);
end;

{ Модель может прислать аргументы с мелкими огрехами JSON (например,
  пропущенным двоеточием) — реестр должен их починить, а не падать. }
procedure TToolTests.TestInvokeRepairsMalformedArgs;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path""a.txt"}', FCtx);
  AssertFalse('пропущенное двоеточие исправлено: ' + O.Text, O.IsError);
  AssertEquals('тело файла', 'hello', ReadBody(O.Text));

  O := FReg.Invoke('read_text_file', '{path:"a.txt",}', FCtx);
  AssertFalse('ключ без кавычек и висячая запятая: ' + O.Text, O.IsError);
  AssertEquals('тело файла', 'hello', ReadBody(O.Text));
end;

{ numbered=true: номера строк соответствуют реальным строкам файла. }
procedure TToolTests.TestReadNumbered;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","offset":2,"numbered":true}', FCtx);
  AssertFalse('чтение с нумерацией: ' + O.Text, O.IsError);
  AssertEquals('номера строк реальные (offset=2)',
    '     2| b' + sLineBreak + '     3| c', ReadBody(O.Text));
end;

{ Пустой диапазон (offset за концом файла) и пустой файл: только шапка, без
  перевода строки в конце. }
procedure TToolTests.TestReadEmptyRange;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","offset":5}', FCtx);
  AssertFalse('чтение за концом файла: ' + O.Text, O.IsError);
  AssertEquals('тело пустой выборки', '', ReadBody(O.Text));
  AssertEquals('шапка без перевода строки в конце', 0, Pos(sLineBreak, O.Text));

  { Пустой файл: тоже только шапка. }
  O := FReg.Invoke('edit_text_file', '{"path":"c.txt","content":"","offset":0}', FCtx);
  AssertFalse('создание пустого файла: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"c.txt"}', FCtx);
  AssertFalse('чтение пустого файла: ' + O.Text, O.IsError);
  AssertTrue('размер 0 байт: ' + O.Text, Pos('размер: 0 байт', O.Text) > 0);
  AssertTrue('строк 0: ' + O.Text, Pos('строк: 0', O.Text) > 0);
  AssertEquals('тело пустого файла', '', ReadBody(O.Text));
end;

{ Правка диапазона: строки 2..3 заменяются одной (offset=2, limit=2). }
procedure TToolTests.TestEditRange;
var
  O: TToolOutcome;
  Hash: string;
begin
  { Файл из 4 строк без завершающего перевода строки. }
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\nd","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertFalse('чтение до правки: ' + O.Text, O.IsError);
  AssertEquals('тело до правки',
    'a' + sLineBreak + 'b' + sLineBreak + 'c' + sLineBreak + 'd', ReadBody(O.Text));
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":2,"limit":2,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('правка диапазона: ' + O.Text, O.IsError);
  AssertTrue('отчёт об удалении и вставке: ' + O.Text,
    Pos('удалено строк: 2, вставлено: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('тело после правки',
    'a' + sLineBreak + 'X' + sLineBreak + 'd', ReadBody(O.Text));
end;

{ Вставка без удаления (limit=0) сохраняет признак перевода строки в конце
  файла. }
procedure TToolTests.TestEditInsertKeepsTrailingBreak;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  { Файл «a\nb\n»: две строки и перевод строки в конце. }
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\n","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('до правки строк: 2 — ' + O.Text, Pos('строк: 2', O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":2,"limit":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('вставка: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'a' + sLineBreak + 'X' + sLineBreak + 'b';
  AssertTrue('после вставки строк: 3 — ' + O.Text, Pos('строк: 3', O.Text) > 0);
  { read_text_file перечисляет только строки, поэтому сохранение перевода строки
    в конце файла проверяем по размеру из шапки. }
  AssertTrue('завершающий перевод строки сохранён (размер ' +
    IntToStr(Length(Exp) + Length(sLineBreak)) + ' байт) — ' + O.Text,
    Pos('размер: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' байт', O.Text) > 0);
  AssertEquals('тело после вставки', Exp, ReadBody(O.Text));
end;

{ Дописывание в конец: offset = 0. }
procedure TToolTests.TestEditAppendToEnd;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\n","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('в файле 2 строки — ' + O.Text, Pos('строк: 2', O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('дописывание в конец: ' + O.Text, O.IsError);
  AssertTrue('отчёт о числе строк: ' + O.Text, Pos('всего строк: 2 -> 3', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'a' + sLineBreak + 'b' + sLineBreak + 'X';
  { read_text_file перечисляет только строки: концевой перевод строки виден
    только по размеру в шапке. }
  AssertTrue('дописано с концевым переводом строки — ' + O.Text,
    Pos('размер: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' байт', O.Text) > 0);
  AssertEquals('тело после дописывания', Exp, ReadBody(O.Text));
end;

{ Удаление диапазона (content = ""): завершающий перевод строки сохраняется. }
procedure TToolTests.TestEditDeleteRange;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\n","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('в файле 3 строки — ' + O.Text, Pos('строк: 3', O.Text) > 0);
  Hash := ReadHash(O.Text);

  { Удаляем строку 2: offset=2, limit=1, content пуст. }
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"","offset":2,"limit":1,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('удаление диапазона: ' + O.Text, O.IsError);
  AssertTrue('отчёт об удалении: ' + O.Text,
    Pos('удалено строк: 1, вставлено: 0', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'a' + sLineBreak + 'c';
  AssertTrue('после удаления строк: 2 — ' + O.Text, Pos('строк: 2', O.Text) > 0);
  { read_text_file перечисляет только строки, поэтому концевой перевод строки
    проверяем по размеру из шапки (он должен сохраниться). }
  AssertTrue('завершающий перевод строки сохранён, размер — ' + O.Text,
    Pos('размер: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' байт', O.Text) > 0);
  AssertEquals('тело после удаления', Exp, ReadBody(O.Text));
end;

{ Отрицательный offset считается с конца файла. }
procedure TToolTests.TestEditNegativeIndices;
var
  O: TToolOutcome;
  Hash: string;
begin
  { offset = -1, limit = 0: вставка перед последней строкой. }
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\nd","offset":0}', FCtx);
  AssertFalse('подготовка a.txt: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":-1,"limit":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('вставка по отрицательному индексу: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('вставка перед последней строкой',
    'a' + sLineBreak + 'b' + sLineBreak + 'c' + sLineBreak + 'X' + sLineBreak + 'd',
    ReadBody(O.Text));

  { offset = -2, limit = 1: заменяем предпоследнюю строку. }
  O := FReg.Invoke('edit_text_file', '{"path":"b.txt","content":"a\nb\nc\nd","offset":0}', FCtx);
  AssertFalse('подготовка b.txt: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"b.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"b.txt","content":"Z","offset":-2,"limit":1,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('замена по отрицательному индексу: ' + O.Text, O.IsError);
  AssertTrue('отчёт о замене одной строки: ' + O.Text,
    Pos('удалено строк: 1, вставлено: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"b.txt"}', FCtx);
  AssertEquals('заменена предпоследняя строка',
    'a' + sLineBreak + 'b' + sLineBreak + 'Z' + sLineBreak + 'd', ReadBody(O.Text));
end;

{ Отрицательный limit отклоняется: файл не меняется. }
procedure TToolTests.TestEditNegativeLimit;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":2,"limit":-1,"hash":"' + Hash + '"}', FCtx);
  AssertTrue('отрицательный limit отклонён: ' + O.Text, O.IsError);
  AssertTrue('сообщение про limit: ' + O.Text,
    Pos('limit не может быть отрицательным', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('файл не изменён',
    'a' + sLineBreak + 'b' + sLineBreak + 'c', ReadBody(O.Text));
end;

{ offset = 0 — дописывание в конец: limit не расширяет диапазон (строк после
  конца файла нет). }
procedure TToolTests.TestEditOffsetZeroIgnoresLimit;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":0,"limit":5,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('дописывание с limit: ' + O.Text, O.IsError);
  AssertTrue('ничего не удалено: ' + O.Text,
    Pos('удалено строк: 0, вставлено: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('дописано в конец',
    'a' + sLineBreak + 'b' + sLineBreak + 'X', ReadBody(O.Text));
end;

{ Слишком отрицательный offset (до первой строки) — ошибка, файл не меняется. }
procedure TToolTests.TestEditOffsetTooNegative;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":-9,"limit":1,"hash":"' + Hash + '"}', FCtx);
  AssertTrue('offset до первой строки — ошибка: ' + O.Text, O.IsError);
  AssertTrue('сообщение про начало диапазона: ' + O.Text,
    Pos('начало диапазона вне файла', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('файл не изменён',
    'a' + sLineBreak + 'b', ReadBody(O.Text));
end;

{ Устаревший хеш: файл изменился в обход инструмента — правка отклоняется. }
procedure TToolTests.TestEditHashMismatch;
var
  O: TToolOutcome;
  Hash, Err: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  { Меняем файл напрямую, минуя инструмент: хеш становится устаревшим. }
  AssertTrue('правка в обход инструмента',
    WriteTextFile(FullPath('a.txt'), 'changed', Err));

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"world","hash":"' + Hash + '"}', FCtx);
  AssertTrue('устаревший хеш отклонён: ' + O.Text, O.IsError);
  AssertTrue('сообщение о несовпадении хеша: ' + O.Text,
    Pos('хеш не совпадает', O.Text) > 0);
  AssertEquals('файл не изменён', 'changed', ReadFileText(FullPath('a.txt')));
end;

{ Хеш не передан при правке существующего файла — ошибка. }
procedure TToolTests.TestEditHashRequired;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"world"}', FCtx);
  AssertTrue('правка без hash отклонена: ' + O.Text, O.IsError);
  AssertTrue('сообщение требует hash: ' + O.Text, Pos('hash', O.Text) > 0);
  AssertEquals('файл не изменён', 'hello', ReadFileText(FullPath('a.txt')));
end;

{ Старый контракт edit_text_file (old/new) больше не поддерживается: вызов
  отклоняется даже с действующим хешем. }
procedure TToolTests.TestEditOldContractRejected;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"x x","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","old":"x","new":"y","hash":"' + Hash + '"}', FCtx);
  AssertTrue('аргументы old/new больше не работают: ' + O.Text, O.IsError);
  AssertTrue('сообщение про старый контракт: ' + O.Text,
    Pos('старый контракт', O.Text) > 0);
  AssertEquals('файл не изменён', 'x x', ReadFileText(FullPath('a.txt')));
end;

{ Регрессия на «модель дописала файл целиком с offset = 0»: строки дублируются,
  но результат должен предупредить об этом и подсказать offset = 1 без limit. }
procedure TToolTests.TestEditAppendWholeFileWarns;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"l1\nl2\nl3\nl4","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);
  AssertTrue('создание файла без предупреждения: ' + O.Text,
    Pos('внимание', O.Text) = 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"l1\nl2\nl3\nl4","offset":0,"hash":"' + Hash + '"}',
    FCtx);
  AssertFalse('дописывание выполнено: ' + O.Text, O.IsError);
  AssertTrue('предупреждение о дублях: ' + O.Text, Pos('строки могли продублироваться', O.Text) > 0);
  AssertTrue('подсказка про замену целиком: ' + O.Text,
    Pos('offset=1 без limit', O.Text) > 0);
  { Опасное поведение не блокируем: файл действительно стал вдвое длиннее. }
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('строк стало 8 — ' + O.Text, Pos('строк: 8', O.Text) > 0);
end;

{ Регрессия: offset без limit заменяет строки до конца файла — об этом нужно
  предупредить, иначе агент теряет хвост файла молча. }
procedure TToolTests.TestEditLimitMissingHint;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"l1\nl2\nl3\nl4\nl5","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  { limit не передан: заменяется диапазон 3..5, хвост файла теряется. }
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":3,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('правка выполнена: ' + O.Text, O.IsError);
  AssertTrue('удалены строки 3..5: ' + O.Text, Pos('удалено строк: 3', O.Text) > 0);
  AssertTrue('предупреждение про отсутствующий limit: ' + O.Text,
    Pos('limit не задан', O.Text) > 0);
  AssertTrue('подсказка про limit=0: ' + O.Text, Pos('вставка перед строкой', O.Text) > 0);

  { А с limit=0 предупреждения быть не должно: это штатная вставка. }
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"Y","offset":2,"limit":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('вставка выполнена: ' + O.Text, O.IsError);
  AssertTrue('вставка без предупреждений: ' + O.Text, Pos('внимание', O.Text) = 0);
end;

{ Создание с offset <> 0 запрещено: файла нет и он не появляется. }
procedure TToolTests.TestCreateNotFromStart;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"new.txt","content":"x","offset":2}', FCtx);
  AssertTrue('создание не с начала файла запрещено: ' + O.Text, O.IsError);
  AssertTrue('сообщение про offset = 0: ' + O.Text,
    Pos('offset = 0', O.Text) > 0);
  AssertFalse('файл не создан', FileExists(FullPath('new.txt')));

  O := FReg.Invoke('edit_text_file',
    '{"path":"new.txt","content":"x","offset":-1}', FCtx);
  AssertTrue('создание с отрицательным offset запрещено: ' + O.Text, O.IsError);
  AssertFalse('файл не создан', FileExists(FullPath('new.txt')));
end;

{ AllowWrite=False: и создание, и правка отклоняются, файл не появляется/не
  меняется. }
procedure TToolTests.TestWriteDenied;
var
  O: TToolOutcome;
  Hash: string;
begin
  FCtx.AllowWrite := False;

  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"x"}', FCtx);
  AssertTrue('создание при AllowWrite=False запрещено: ' + O.Text, O.IsError);
  AssertTrue('сообщение о запрете записи: ' + O.Text, Pos('запрещена', O.Text) > 0);
  AssertFalse('файл не создан', FileExists(FullPath('a.txt')));

  { Готовим файл, чтобы проверить запрет правки. }
  FCtx.AllowWrite := True;
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  FCtx.AllowWrite := False;
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"world","hash":"' + Hash + '"}', FCtx);
  AssertTrue('правка при AllowWrite=False запрещена: ' + O.Text, O.IsError);
  AssertEquals('файл не изменён', 'hello', ReadFileText(FullPath('a.txt')));

  FCtx.AllowWrite := True;
end;

{ Служебный каталог .mirmid закрыт для всех файловых инструментов. }
procedure TToolTests.TestMirmidDirDenied;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка файла в .mirmid',
    WriteTextFile(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'secret.txt',
      'top-secret', Err));

  O := FReg.Invoke('read_text_file', '{"path":".mirmid/secret.txt"}', FCtx);
  AssertTrue('чтение .mirmid запрещено', O.IsError);
  O := FReg.Invoke('read_pascal_interface', '{"path":".mirmid/secret.txt"}', FCtx);
  AssertTrue('read_pascal_interface .mirmid запрещён: ' + O.Text, O.IsError);
  AssertTrue('сообщение о запрете .mirmid: ' + O.Text, Pos('запрещён', O.Text) > 0);

  O := FReg.Invoke('edit_text_file',
    '{"path":".mirmid/new.txt","content":"x"}', FCtx);
  AssertTrue('создание в .mirmid запрещено: ' + O.Text, O.IsError);
  AssertFalse('файл в .mirmid не создан',
    FileExists(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'new.txt'));

  O := FReg.Invoke('edit_text_file',
    '{"path":".mirmid/secret.txt","content":"x","hash":"00000000"}', FCtx);
  AssertTrue('правка в .mirmid запрещена: ' + O.Text, O.IsError);

  O := FReg.Invoke('exist_file', '{"path":".mirmid"}', FCtx);
  AssertTrue('exist_file .mirmid запрещён', O.IsError);

  O := FReg.Invoke('file_list', '{"path":".mirmid"}', FCtx);
  AssertTrue('file_list .mirmid запрещён', O.IsError);

  FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"1","offset":0}', FCtx);
  O := FReg.Invoke('file_list', '{"path":".","recursive":true}', FCtx);
  AssertFalse('листинг рабочей папки', O.IsError);
  AssertTrue('в листинге нет .mirmid', Pos('.mirmid', O.Text) = 0);

  O := FReg.Invoke('copy_file',
    '{"source":".mirmid/secret.txt","destination":"out.txt"}', FCtx);
  AssertTrue('копирование из .mirmid запрещено', O.IsError);

  O := FReg.Invoke('copy_file',
    '{"source":"a.txt","destination":".mirmid/out.txt"}', FCtx);
  AssertTrue('копирование в .mirmid запрещено', O.IsError);

end;

procedure TToolTests.TestFileList;
var
  O: TToolOutcome;
begin
  FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"1","offset":0}', FCtx);
  FReg.Invoke('edit_text_file', '{"path":"b.txt","content":"2","offset":0}', FCtx);
  O := FReg.Invoke('file_list', '{"path":"."}', FCtx);
  AssertFalse('список без ошибки', O.IsError);
  AssertTrue('в списке a.txt', Pos('a.txt', O.Text) > 0);
  AssertTrue('в списке b.txt', Pos('b.txt', O.Text) > 0);
end;

procedure TToolTests.TestShellPolicy;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('shell', '{"command":"echo mirmid"}', FCtx);
  AssertTrue('shell запрещён по умолчанию', O.IsError);

  FCtx.AllowShell := True;
  O := FReg.Invoke('shell', '{"command":"echo mirmid"}', FCtx);
  AssertFalse('shell разрешён: ' + O.Text, O.IsError);
  AssertTrue('вывод содержит mirmid', Pos('mirmid', O.Text) > 0);
end;

procedure TToolTests.TestShellOutputLimitTruncates;
const
  Limit = 50;
  N = 2000;
var
  O: TToolOutcome;
  Cmd: string;
begin
  { Успешная ветка ToolShell: вывод длиннее shell_output_limit режется, но код
    возврата сохраняется, а в ответе остаётся пометка с числом байт. }
  FCtx.AllowShell := True;
  Cmd := 'echo ' + StringOfChar('x', N);

  FCtx.ShellOutputLimit := Limit;
  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertFalse('успешный запуск: ' + O.Text, O.IsError);
  AssertTrue('код возврата сохранён: ' + O.Text, Pos('exit=0', O.Text) > 0);
  AssertTrue('пометка обрезки: ' + O.Text,
    Pos('[… обрезано: показано ' + IntToStr(Limit) + ' из ', O.Text) > 0);
  AssertTrue('вывод обрезан (' + IntToStr(Length(O.Text)) + ' байт)',
    Length(O.Text) < 300);

  { shell_output_limit = 0 — без предела: пометки нет, вывод приходит целиком. }
  FCtx.ShellOutputLimit := 0;
  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertFalse('успешный запуск без предела: ' + O.Text, O.IsError);
  AssertTrue('без предела пометки обрезки нет: ' + O.Text,
    Pos('обрезано', O.Text) = 0);
  AssertTrue('без предела вывод целиком (' + IntToStr(Length(O.Text)) + ' байт)',
    Pos(StringOfChar('x', N), O.Text) > 0);
end;

{ Обрезка shell_output_limit не должна рвать многобайтовый символ UTF-8:
  при пределе 5 байт вывод «привет» (12 байт) даёт «пр» (4 байта), а не
  «пр» + первый байт буквы «и». }
procedure TToolTests.TestShellOutputLimitUtf8;
const
  Limit = 5;
var
  O, Prep: TToolOutcome;
  Cmd, Body: string;
begin
  FCtx.AllowShell := True;
  FCtx.ShellOutputLimit := Limit;

  { Печатаем файл сырыми байтами (type/cat не перекодируют содержимое),
    поэтому граница предела заведомо попадает внутрь буквы «и»: байты
    «привет» — D0 BF D1 80 D0 B8 D0 B2 D0 B5 D1 82. }
  Prep := FReg.Invoke('edit_text_file',
    '{"path":"utf8.txt","content":"привет","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + Prep.Text, Prep.IsError);
  {$IFDEF UNIX}
  Cmd := 'cat utf8.txt';
  {$ELSE}
  Cmd := 'type utf8.txt';
  {$ENDIF}

  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertFalse('успешный запуск: ' + O.Text, O.IsError);
  AssertTrue('код возврата сохранён: ' + O.Text, Pos('exit=0', O.Text) > 0);
  AssertTrue('весь ответ — корректный UTF-8', IsValidUTF8(O.Text));

  { 5-байтовый предел режет ровно перед «и»: остаётся «пр» и пометка. }
  Body := ReadBody(O.Text);
  AssertEquals('граница символа не разрезана', 1,
    Pos('пр' + sLineBreak, Body));
  AssertTrue('пометка обрезала 5-й байт: ' + O.Text,
    Pos('[… обрезано: показано 4 из 12 байт]', O.Text) > 0);
end;


procedure TToolTests.TestShellOutputLimitOnTimeout;
const
  Limit = 20;
  N = 2000;
var
  O: TToolOutcome;
  Cmd: string;
begin
  { Ветка ошибки ToolShell (таймаут): прочитанный до остановки процесса вывод
    тоже обязан обрезаться до shell_output_limit, а причина ошибки — сохраниться. }
  FCtx.AllowShell := True;
  FCtx.ShellTimeout := 1;
  FCtx.ShellOutputLimit := Limit;
  {$IFDEF UNIX}
  { Печатает 2000 байт и зависает: к моменту таймаута вывод уже в канале. }
  Cmd := 'printf ''' + StringOfChar('x', N) + '''; sleep 30';
  {$ELSE}
  { cmd.exe: echo печатает сразу, ping держит процесс до срабатывания таймаута. }
  Cmd := 'echo ' + StringOfChar('x', N) + ' & ping -n 3 127.0.0.1 >nul';
  {$ENDIF}
  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertTrue('ветка ошибки: ' + O.Text, O.IsError);
  AssertTrue('причина — таймаут: ' + O.Text,
    Pos('превышено время', O.Text) > 0);
  AssertTrue('пометка обрезки: ' + O.Text,
    Pos('[… обрезано: показано ' + IntToStr(Limit) + ' из ', O.Text) > 0);
  AssertTrue('вывод обрезан (' + IntToStr(Length(O.Text)) + ' байт)',
    Length(O.Text) < 300);
end;

procedure TToolTests.TestEditWholeFileWithoutRange;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\n","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('в файле 3 строки — ' + O.Text, Pos('строк: 3', O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X\ny","hash":"' + Hash + '"}', FCtx);
  AssertFalse('полная замена без диапазона: ' + O.Text, O.IsError);
  AssertTrue('заменены все 3 строки: ' + O.Text,
    Pos('удалено строк: 3, вставлено: 2', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'X' + sLineBreak + 'y';
  AssertTrue('после замены строк: 2 — ' + O.Text, Pos('строк: 2', O.Text) > 0);
  { Концевой перевод строки исходного файла сохраняется — видно по размеру. }
  AssertTrue('концевой перевод строки сохранён — ' + O.Text,
    Pos('размер: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' байт', O.Text) > 0);
  AssertEquals('тело после полной замены', Exp, ReadBody(O.Text));
end;

{ limit за концом файла не мешает: диапазон обрезается до конца. }
procedure TToolTests.TestEditLimitBeyondEnd;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"Z","offset":2,"limit":999,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('limit за концом файла не мешает: ' + O.Text, O.IsError);
  AssertTrue('заменены строки 2..3: ' + O.Text,
    Pos('удалено строк: 2, вставлено: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('тело после правки', 'a' + sLineBreak + 'Z', ReadBody(O.Text));
end;

{ Большой файл: после правки строки склеиваются через TStringList.Text.
  Раньше склейка шла циклом Text := Text + …, что на тысячах строк давало
  квадратичное копирование; проверяем, что содержимое при этом не портится. }
procedure TToolTests.TestEditManyLinesJoin;
const
  N = 2000;
var
  O: TToolOutcome;
  SL: TStringList;
  Hash, Json, Exp, FileText: string;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    for I := 1 to N do
      SL.Add('line ' + IntToStr(I));
    Json := StringReplace(SL.Text, sLineBreak, '\n', [rfReplaceAll]);
  finally
    SL.Free;
  end;

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"' + Json + '","offset":0}', FCtx);
  AssertFalse('создание файла из ' + IntToStr(N) + ' строк: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","limit":0}', FCtx);
  AssertTrue('в файле ' + IntToStr(N) + ' строк — ' + O.Text,
    Pos('строк: ' + IntToStr(N), O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":1000,"limit":1,"hash":"' + Hash + '"}',
    FCtx);
  AssertFalse('замена 1000-й строки: ' + O.Text, O.IsError);
  AssertTrue('число строк не изменилось: ' + O.Text,
    Pos('всего строк: ' + IntToStr(N) + ' -> ' + IntToStr(N), O.Text) > 0);

  SL := TStringList.Create;
  try
    for I := 1 to N do
      if I = 1000 then
        SL.Add('X')
      else
        SL.Add('line ' + IntToStr(I));
    { Файл создавался с концевым переводом строки — он и должен сохраниться. }
    Exp := SL.Text;
  finally
    SL.Free;
  end;

  FileText := ReadFileText(FullPath('a.txt'));
  AssertEquals('строки склеены переводом строки ОС без потерь', Exp, FileText);
  AssertEquals('размер файла', Length(Exp), Length(FileText));

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","limit":0}', FCtx);
  AssertFalse('чтение после правки: ' + O.Text, O.IsError);
  AssertEquals('тело прочитано тем же инструментом',
    Copy(Exp, 1, Length(Exp) - Length(sLineBreak)), ReadBody(O.Text));
end;

{ offset за концом файла — ошибка, файл не меняется. }
procedure TToolTests.TestEditFirstLineBeyondEnd;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"z","offset":9,"hash":"' + Hash + '"}', FCtx);
  AssertTrue('начало диапазона вне файла — ошибка: ' + O.Text, O.IsError);
  AssertTrue('подсказка про дописывание в конец: ' + O.Text,
    Pos('дописать в конец', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('файл не изменён', 'a' + sLineBreak + 'b', ReadBody(O.Text));
end;

{ grep: контекст у конца файла не должен выходить за границы TStringList
  (раньше при context > 0 падало с «List index (N) out of bounds»). }
procedure TToolTests.TestGrepContextAtEndOfFile;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"aa\nbb hit\ncc hit","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('grep', '{"path":"a.txt","pattern":"hit","context":2}', FCtx);
  AssertFalse('grep с контекстом у конца файла: ' + O.Text, O.IsError);
  AssertTrue('строка 1 в выводе: ' + O.Text, Pos('1: aa', O.Text) > 0);
  AssertTrue('строка 2 в выводе: ' + O.Text, Pos('2: bb hit', O.Text) > 0);
  AssertTrue('строка 3 в выводе: ' + O.Text, Pos('3: cc hit', O.Text) > 0);
  AssertTrue('итого 3 строки: ' + O.Text, Pos('найдено совпадений: 3', O.Text) > 0);
end;

{ grep: строка, попавшая в контекст соседнего совпадения, не дублируется. }
procedure TToolTests.TestGrepNoDuplicateLines;
var
  O: TToolOutcome;
  Body, Marker: string;
  Cnt: Integer;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"hit one\nhit two\ntail","offset":0}', FCtx);
  AssertFalse('подготовка файла: ' + O.Text, O.IsError);

  O := FReg.Invoke('grep', '{"path":"a.txt","pattern":"hit","context":1}', FCtx);
  AssertFalse('grep с перекрывающимся контекстом: ' + O.Text, O.IsError);
  AssertTrue('итого 3 строки: ' + O.Text, Pos('найдено совпадений: 3', O.Text) > 0);

  { Строка 2 — и совпадение, и контекст строки 1: должна печататься один раз. }
  Body := O.Text;
  Marker := '2: hit two';
  Cnt := 0;
  while Pos(Marker, Body) > 0 do
  begin
    Inc(Cnt);
    Delete(Body, 1, Pos(Marker, Body) + Length(Marker) - 1);
  end;
  AssertEquals('строка 2 не дублируется: ' + O.Text, 1, Cnt);
end;

{ ---------------- read_pascal_interface ---------------- }

{ unit читается до слова implementation включительно: секция implementation и
  тела процедур в ответ не попадают. }
procedure TToolTests.TestPascalUnitInterface;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка .pas', WriteTextFile(FullPath('demo.pas'),
    'unit Demo;' + sLineBreak +
    'interface' + sLineBreak +
    'type TFoo = class' + sLineBreak +
    'end;' + sLineBreak +
    'implementation' + sLineBreak +
    'procedure Hidden;' + sLineBreak +
    'end.', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('unit читается: ' + O.Text, O.IsError);
  AssertEquals('текст до implementation включительно',
    'unit Demo;' + sLineBreak + 'interface' + sLineBreak +
    'type TFoo = class' + sLineBreak + 'end;' + sLineBreak + 'implementation',
    O.Text);
end;

{ program возвращается целиком. }
procedure TToolTests.TestPascalProgramWhole;
var
  O: TToolOutcome;
  Err, Src: string;
begin
  Src := 'program Demo;' + sLineBreak + 'begin' + sLineBreak +
    '  writeln(''hi'');' + sLineBreak + 'end.';
  AssertTrue('подготовка .dpr', WriteTextFile(FullPath('demo.dpr'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.dpr"}', FCtx);
  AssertFalse('program читается: ' + O.Text, O.IsError);
  AssertEquals('program возвращается целиком', Src, O.Text);
end;

{ Слова в комментариях, строках и идентификаторах не считаются ключевыми. }
procedure TToolTests.TestPascalIgnoresCommentsStringsAndIdents;
var
  O: TToolOutcome;
  Err, Src, Exp: string;
begin
  Src :=
    '{ program Fake }' + sLineBreak +
    'unit Noise; // unit и implementation в комментарии' + sLineBreak +
    '(* interface implementation *)' + sLineBreak +
    'interface' + sLineBreak +
    'type' + sLineBreak +
    '  TImplementation = class end;' + sLineBreak +
    'const' + sLineBreak +
    '  S = ''implementation'';' + sLineBreak +
    'implementation' + sLineBreak +
    'end.';
  Exp :=
    '{ program Fake }' + sLineBreak +
    'unit Noise; // unit и implementation в комментарии' + sLineBreak +
    '(* interface implementation *)' + sLineBreak +
    'interface' + sLineBreak +
    'type' + sLineBreak +
    '  TImplementation = class end;' + sLineBreak +
    'const' + sLineBreak +
    '  S = ''implementation'';' + sLineBreak +
    'implementation';
  AssertTrue('подготовка .pas', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('комментарии и строки пропущены: ' + O.Text, O.IsError);
  AssertEquals('настоящий implementation найден', Exp, O.Text);
end;

{ Расширение не из списка Pascal/Delphi — ошибка. }
procedure TToolTests.TestPascalBadExtension;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка .txt', WriteTextFile(FullPath('demo.txt'),
    'unit X; interface implementation', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.txt"}', FCtx);
  AssertTrue('расширение отклонено: ' + O.Text, O.IsError);
  AssertTrue('сообщение про расширение: ' + O.Text, Pos('расширение', O.Text) > 0);

  { .dpk — package: по контракту это ни unit, ни program, поэтому вне списка. }
  AssertTrue('подготовка .dpk', WriteTextFile(FullPath('demo.dpk'),
    'package X; end.', Err));
  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.dpk"}', FCtx);
  AssertTrue('.dpk отклонён: ' + O.Text, O.IsError);
  AssertTrue('.dpk: сообщение про расширение: ' + O.Text,
    Pos('расширение', O.Text) > 0);
end;

{ Файл начинается не с unit и не с program. }
procedure TToolTests.TestPascalNotUnitOrProgram;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка library', WriteTextFile(FullPath('nohead.pas'),
    'library Demo;' + sLineBreak + 'interface' + sLineBreak + 'implementation', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"nohead.pas"}', FCtx);
  AssertTrue('library отклонён: ' + O.Text, O.IsError);
  AssertTrue('сообщение про начало файла: ' + O.Text, Pos('начинаться', O.Text) > 0);
end;

{ unit без раздела interface. }
procedure TToolTests.TestPascalMissingInterface;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка .pas', WriteTextFile(FullPath('nointf.pas'),
    'unit X;' + sLineBreak + 'type T = class end;', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"nointf.pas"}', FCtx);
  AssertTrue('unit без interface отклонён: ' + O.Text, O.IsError);
  AssertTrue('сообщение про interface: ' + O.Text,
    Pos('отсутствует раздел interface', O.Text) > 0);
end;

{ unit без раздела implementation. }
procedure TToolTests.TestPascalMissingImplementation;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка .pas', WriteTextFile(FullPath('noimpl.pas'),
    'unit X;' + sLineBreak + 'interface' + sLineBreak + 'type T = class end;', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"noimpl.pas"}', FCtx);
  AssertTrue('unit без implementation отклонён: ' + O.Text, O.IsError);
  AssertTrue('сообщение про implementation: ' + O.Text,
    Pos('отсутствует раздел implementation', O.Text) > 0);
end;

{ implementation раньше interface — некорректный модуль. }
procedure TToolTests.TestPascalImplementationBeforeInterface;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка .pas', WriteTextFile(FullPath('order.pas'),
    'unit X;' + sLineBreak + 'implementation' + sLineBreak + 'interface', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"order.pas"}', FCtx);
  AssertTrue('порядок разделов проверен: ' + O.Text, O.IsError);
  AssertTrue('сообщение про порядок: ' + O.Text, Pos('раньше', O.Text) > 0);
end;

{ implementation — строго до конца слова, а не до конца строки: `uses Foo;`
  на той же строке уже относится к телу модуля. }
procedure TToolTests.TestPascalImplementationEndsAtWord;
var
  O: TToolOutcome;
  Err, Src: string;
begin
  Src := 'unit X;' + sLineBreak + 'interface' + sLineBreak +
    'implementation uses Foo;' + sLineBreak + 'procedure Hidden;' + sLineBreak +
    'begin' + sLineBreak + 'end;' + sLineBreak + 'end.';
  AssertTrue('подготовка .pas', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('unit читается: ' + O.Text, O.IsError);
  AssertEquals('ответ заканчивается словом implementation',
    'unit X;' + sLineBreak + 'interface' + sLineBreak + 'implementation', O.Text);
end;

{ UTF-8 BOM в начале файла не попадает в ответ. }
procedure TToolTests.TestPascalBom;
var
  O: TToolOutcome;
  Err, Src, Exp: string;
begin
  Src := #$EF + #$BB + #$BF + 'unit X;' + sLineBreak + 'interface' +
    sLineBreak + 'implementation';
  Exp := 'unit X;' + sLineBreak + 'interface' + sLineBreak + 'implementation';
  AssertTrue('подготовка .pas с BOM', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('файл с BOM читается: ' + O.Text, O.IsError);
  AssertEquals('BOM отброшен', Exp, O.Text);
end;

{ Удвоенная кавычка в строке и &-идентификатор не считаются ключевыми словами. }
procedure TToolTests.TestPascalEscapedAndDoubledQuote;
var
  O: TToolOutcome;
  Err, Src, Exp: string;
begin
  Src :=
    'unit X;' + sLineBreak +
    'interface' + sLineBreak +
    'const' + sLineBreak +
    '  S = ''it''''s interface implementation'';' + sLineBreak +
    '  Q = &implementation;' + sLineBreak +
    'implementation' + sLineBreak +
    'end.';
  Exp :=
    'unit X;' + sLineBreak +
    'interface' + sLineBreak +
    'const' + sLineBreak +
    '  S = ''it''''s interface implementation'';' + sLineBreak +
    '  Q = &implementation;' + sLineBreak +
    'implementation';
  AssertTrue('подготовка .pas', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('экранированные имена не ключевые: ' + O.Text, O.IsError);
  AssertEquals('строка с кавычками и &implementation пропущены', Exp, O.Text);
end;

{ Незакрытые комментарий и строка — понятная ошибка, а не мусорный ответ. }
procedure TToolTests.TestPascalUnclosed;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('подготовка комментария', WriteTextFile(FullPath('demo.pas'),
    'unit X;' + sLineBreak + 'interface' + sLineBreak + '{ implementation', Err));
  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertTrue('незакрытый комментарий — ошибка: ' + O.Text, O.IsError);
  AssertTrue('сообщение про комментарий: ' + O.Text,
    Pos('незакрытый комментарий', O.Text) > 0);

  AssertTrue('подготовка строки', WriteTextFile(FullPath('demo.pas'),
    'unit X;' + sLineBreak + 'interface' + sLineBreak +
    'const S = ''abc' + sLineBreak + 'implementation', Err));
  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertTrue('незакрытая строка — ошибка: ' + O.Text, O.IsError);
  AssertTrue('сообщение про строку: ' + O.Text,
    Pos('незакрытая строковая', O.Text) > 0);
end;

initialization
  RegisterTest(TToolTests);

end.
