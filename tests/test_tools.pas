unit test_tools;
{ Tests of the built-in tools and of the access policies.
  The file tool contract:
   - write_text_file is removed; a file is created by edit_text_file without a
     hash (offset = 0);
   - read_text_file always returns a header ("[mirmid] file: ... | size: N
     bytes | lines: N | hash: ..."), the content starts on the second line;
   - edit_text_file replaces the line range described by offset/limit (offset -
     1-based line number, 0 - append to the end, negative - counted from the
     end; limit - how many lines to replace, not negative) and requires the
     hash from the header for an existing file. }

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
    { Full path to a file inside the working folder of the test. }
    function FullPath(const Name: string): string;
    { Body of the read_text_file answer: everything after the header line. }
    function ReadBody(const S: string): string;
    { Hash from the read_text_file header: 8 characters after "hash: ". }
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
    procedure TestReadOnlyToolDisabled;
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

{ True if the string is exactly 8 hexadecimal characters. }
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

{ Content of a file read around the tools (for the "file was not changed"
  checks). On a read error it returns a diagnostic string. }
function ReadFileText(const Path: string): string;
var
  Err: string;
begin
  Result := '';
  if not ReadTextFile(Path, Result, Err) then
    Result := '<read error: ' + Err + '>';
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
  N := Pos('hash: ', S);
  if N = 0 then
    Exit('');
  Result := Copy(S, N + Length('hash: '), 8);
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
  SetToolEnabled(Cfg, 'edit_text_file', True);
  SetToolEnabled(Cfg, 'copy_file', True);
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

{ Creating a file through edit_text_file (creation mode, no hash needed) and
  reading it through read_text_file: the header and the body are checked. }
procedure TToolTests.TestCreateAndRead;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('file creation: ' + O.Text, O.IsError);
  AssertTrue('the answer reports the creation: ' + O.Text,
    Pos('file created: ', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertFalse('file reading: ' + O.Text, O.IsError);
  AssertEquals('the first line is the header', 1, Pos('[mirmid] file: ', O.Text));
  AssertTrue('size in the header: ' + O.Text, Pos('size: 5 bytes', O.Text) > 0);
  AssertTrue('line count in the header: ' + O.Text, Pos('lines: 1', O.Text) > 0);

  Hash := ReadHash(O.Text);
  AssertTrue('the hash in the header is 8 hex characters: "' + Hash + '"', IsHex8(Hash));
  AssertEquals('file body', 'hello', ReadBody(O.Text));
end;

{ write_text_file is removed: the tool is not registered and a call is an
  error. }
procedure TToolTests.TestWriteToolRemoved;
var
  O: TToolOutcome;
begin
  AssertFalse('write_text_file is not registered', FReg.Has('write_text_file'));

  O := FReg.Invoke('write_text_file', '{"path":"a.txt","content":"hello"}', FCtx);
  AssertTrue('a call of the removed tool is an error: ' + O.Text, O.IsError);
  AssertTrue('the message reports an unknown tool: ' + O.Text,
    Pos('unknown tool', O.Text) > 0);
  AssertFalse('the file is not created', FileExists(FullPath('a.txt')));
end;

procedure TToolTests.TestReadMissing;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('read_text_file', '{"path":"missing.txt"}', FCtx);
  AssertTrue('a missing file is an error: ' + O.Text, O.IsError);
  AssertTrue('the message says "file not found": ' + O.Text,
    Pos('file not found', O.Text) > 0);
end;

{ The model may send arguments with small JSON slips (a missing colon, for
  example) - the registry has to repair them instead of failing. }
procedure TToolTests.TestInvokeRepairsMalformedArgs;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path""a.txt"}', FCtx);
  AssertFalse('the missing colon is repaired: ' + O.Text, O.IsError);
  AssertEquals('file body', 'hello', ReadBody(O.Text));

  O := FReg.Invoke('read_text_file', '{path:"a.txt",}', FCtx);
  AssertFalse('a bare key and a trailing comma: ' + O.Text, O.IsError);
  AssertEquals('file body', 'hello', ReadBody(O.Text));
end;

{ numbered=true: the line numbers match the real lines of the file. }
procedure TToolTests.TestReadNumbered;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","offset":2,"numbered":true}', FCtx);
  AssertFalse('reading with numbers: ' + O.Text, O.IsError);
  AssertEquals('the line numbers are real (offset=2)',
    '     2| b' + sLineBreak + '     3| c', ReadBody(O.Text));
end;

{ An empty range (offset past the end of the file) and an empty file: only the
  header, without a trailing line break. }
procedure TToolTests.TestReadEmptyRange;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","offset":5}', FCtx);
  AssertFalse('reading past the end of the file: ' + O.Text, O.IsError);
  AssertEquals('body of the empty selection', '', ReadBody(O.Text));
  AssertEquals('the header has no trailing line break', 0, Pos(sLineBreak, O.Text));

  { An empty file: only the header as well. }
  O := FReg.Invoke('edit_text_file', '{"path":"c.txt","content":"","offset":0}', FCtx);
  AssertFalse('creating an empty file: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"c.txt"}', FCtx);
  AssertFalse('reading the empty file: ' + O.Text, O.IsError);
  AssertTrue('size 0 bytes: ' + O.Text, Pos('size: 0 bytes', O.Text) > 0);
  AssertTrue('0 lines: ' + O.Text, Pos('lines: 0', O.Text) > 0);
  AssertEquals('body of the empty file', '', ReadBody(O.Text));
end;

{ Range edit: lines 2..3 are replaced by one line (offset=2, limit=2). }
procedure TToolTests.TestEditRange;
var
  O: TToolOutcome;
  Hash: string;
begin
  { A file of 4 lines without a trailing line break. }
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\nd","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertFalse('reading before the edit: ' + O.Text, O.IsError);
  AssertEquals('body before the edit',
    'a' + sLineBreak + 'b' + sLineBreak + 'c' + sLineBreak + 'd', ReadBody(O.Text));
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":2,"limit":2,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('range edit: ' + O.Text, O.IsError);
  AssertTrue('the report mentions the removal and the insertion: ' + O.Text,
    Pos('lines removed: 2, inserted: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('body after the edit',
    'a' + sLineBreak + 'X' + sLineBreak + 'd', ReadBody(O.Text));
end;

{ Insertion without removal (limit=0) keeps the trailing line break flag of the
  file. }
procedure TToolTests.TestEditInsertKeepsTrailingBreak;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  { The file "a\nb\n": two lines and a trailing line break. }
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\n","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('2 lines before the edit: ' + O.Text, Pos('lines: 2', O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":2,"limit":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('insertion: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'a' + sLineBreak + 'X' + sLineBreak + 'b';
  AssertTrue('3 lines after the insertion: ' + O.Text, Pos('lines: 3', O.Text) > 0);
  { read_text_file lists the lines only, so the trailing line break of the file
    is checked through the size in the header. }
  AssertTrue('the trailing line break is kept (size ' +
    IntToStr(Length(Exp) + Length(sLineBreak)) + ' bytes): ' + O.Text,
    Pos('size: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' bytes', O.Text) > 0);
  AssertEquals('body after the insertion', Exp, ReadBody(O.Text));
end;

{ Appending to the end: offset = 0. }
procedure TToolTests.TestEditAppendToEnd;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\n","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('the file has 2 lines: ' + O.Text, Pos('lines: 2', O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('appending to the end: ' + O.Text, O.IsError);
  AssertTrue('the report mentions the line count: ' + O.Text,
    Pos('total lines: 2 -> 3', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'a' + sLineBreak + 'b' + sLineBreak + 'X';
  { read_text_file lists the lines only: the trailing line break is visible
    through the size in the header alone. }
  AssertTrue('appended with a trailing line break: ' + O.Text,
    Pos('size: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' bytes', O.Text) > 0);
  AssertEquals('body after the append', Exp, ReadBody(O.Text));
end;

{ Removing a range (content = ""): the trailing line break is kept. }
procedure TToolTests.TestEditDeleteRange;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\n","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('the file has 3 lines: ' + O.Text, Pos('lines: 3', O.Text) > 0);
  Hash := ReadHash(O.Text);

  { Removing line 2: offset=2, limit=1, the content is empty. }
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"","offset":2,"limit":1,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('range removal: ' + O.Text, O.IsError);
  AssertTrue('the report mentions the removal: ' + O.Text,
    Pos('lines removed: 1, inserted: 0', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'a' + sLineBreak + 'c';
  AssertTrue('2 lines after the removal: ' + O.Text, Pos('lines: 2', O.Text) > 0);
  { read_text_file lists the lines only, so the trailing line break is checked
    through the size in the header (it must be kept). }
  AssertTrue('the trailing line break is kept, size: ' + O.Text,
    Pos('size: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' bytes', O.Text) > 0);
  AssertEquals('body after the removal', Exp, ReadBody(O.Text));
end;

{ A negative offset is counted from the end of the file. }
procedure TToolTests.TestEditNegativeIndices;
var
  O: TToolOutcome;
  Hash: string;
begin
  { offset = -1, limit = 0: insert before the last line. }
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\nd","offset":0}', FCtx);
  AssertFalse('preparing a.txt: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":-1,"limit":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('insertion by a negative index: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('inserted before the last line',
    'a' + sLineBreak + 'b' + sLineBreak + 'c' + sLineBreak + 'X' + sLineBreak + 'd',
    ReadBody(O.Text));

  { offset = -2, limit = 1: the next to last line is replaced. }
  O := FReg.Invoke('edit_text_file', '{"path":"b.txt","content":"a\nb\nc\nd","offset":0}', FCtx);
  AssertFalse('preparing b.txt: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"b.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"b.txt","content":"Z","offset":-2,"limit":1,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('replacement by a negative index: ' + O.Text, O.IsError);
  AssertTrue('the report mentions one replaced line: ' + O.Text,
    Pos('lines removed: 1, inserted: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"b.txt"}', FCtx);
  AssertEquals('the next to last line is replaced',
    'a' + sLineBreak + 'b' + sLineBreak + 'Z' + sLineBreak + 'd', ReadBody(O.Text));
end;

{ A negative limit is rejected: the file is not changed. }
procedure TToolTests.TestEditNegativeLimit;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":2,"limit":-1,"hash":"' + Hash + '"}', FCtx);
  AssertTrue('the negative limit is rejected: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the limit: ' + O.Text,
    Pos('limit must not be negative', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('the file is not changed',
    'a' + sLineBreak + 'b' + sLineBreak + 'c', ReadBody(O.Text));
end;

{ offset = 0 appends to the end: the limit does not widen the range (there are
  no lines past the end of the file). }
procedure TToolTests.TestEditOffsetZeroIgnoresLimit;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":0,"limit":5,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('appending with a limit: ' + O.Text, O.IsError);
  AssertTrue('nothing is removed: ' + O.Text,
    Pos('lines removed: 0, inserted: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('appended to the end',
    'a' + sLineBreak + 'b' + sLineBreak + 'X', ReadBody(O.Text));
end;

{ A too negative offset (before the first line) is an error and the file is not
  changed. }
procedure TToolTests.TestEditOffsetTooNegative;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":-9,"limit":1,"hash":"' + Hash + '"}', FCtx);
  AssertTrue('an offset before the first line is an error: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the range start: ' + O.Text,
    Pos('range start is outside the file', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('the file is not changed',
    'a' + sLineBreak + 'b', ReadBody(O.Text));
end;

{ A stale hash: the file changed around the tool, so the edit is rejected. }
procedure TToolTests.TestEditHashMismatch;
var
  O: TToolOutcome;
  Hash, Err: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  { The file is changed directly, around the tool: the hash becomes stale. }
  AssertTrue('the edit around the tool',
    WriteTextFile(FullPath('a.txt'), 'changed', Err));

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"world","hash":"' + Hash + '"}', FCtx);
  AssertTrue('the stale hash is rejected: ' + O.Text, O.IsError);
  AssertTrue('the message reports the hash mismatch: ' + O.Text,
    Pos('hash mismatch', O.Text) > 0);
  AssertEquals('the file is not changed', 'changed', ReadFileText(FullPath('a.txt')));
end;

{ No hash is passed while editing an existing file - an error. }
procedure TToolTests.TestEditHashRequired;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"world"}', FCtx);
  AssertTrue('an edit without a hash is rejected: ' + O.Text, O.IsError);
  AssertTrue('the message requires the hash: ' + O.Text, Pos('hash', O.Text) > 0);
  AssertEquals('the file is not changed', 'hello', ReadFileText(FullPath('a.txt')));
end;

{ The old edit_text_file contract (old/new) is no longer supported: the call is
  rejected even with a valid hash. }
procedure TToolTests.TestEditOldContractRejected;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"x x","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","old":"x","new":"y","hash":"' + Hash + '"}', FCtx);
  AssertTrue('the old/new arguments no longer work: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the old contract: ' + O.Text,
    Pos('old contract', O.Text) > 0);
  AssertEquals('the file is not changed', 'x x', ReadFileText(FullPath('a.txt')));
end;

{ Regression for "the model appended the whole file with offset = 0": the lines
  are duplicated, but the result has to warn about it and suggest offset = 1
  without a limit. }
procedure TToolTests.TestEditAppendWholeFileWarns;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"l1\nl2\nl3\nl4","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);
  AssertTrue('the creation has no warning: ' + O.Text,
    Pos('warning', O.Text) = 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"l1\nl2\nl3\nl4","offset":0,"hash":"' + Hash + '"}',
    FCtx);
  AssertFalse('the append is done: ' + O.Text, O.IsError);
  AssertTrue('the warning about the duplicates: ' + O.Text,
    Pos('lines may have been duplicated', O.Text) > 0);
  AssertTrue('the hint about replacing the whole file: ' + O.Text,
    Pos('offset=1 without limit', O.Text) > 0);
  { The dangerous behaviour is not blocked: the file really became twice as
    long. }
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('the file has 8 lines: ' + O.Text, Pos('lines: 8', O.Text) > 0);
end;

{ Regression: an offset without a limit replaces the lines up to the end of the
  file - the agent has to be warned, otherwise it loses the tail silently. }
procedure TToolTests.TestEditLimitMissingHint;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"l1\nl2\nl3\nl4\nl5","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  { No limit is passed: the range 3..5 is replaced and the tail is lost. }
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":3,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('the edit is done: ' + O.Text, O.IsError);
  AssertTrue('the lines 3..5 are removed: ' + O.Text,
    Pos('lines removed: 3', O.Text) > 0);
  AssertTrue('the warning about the missing limit: ' + O.Text,
    Pos('limit is not set', O.Text) > 0);
  AssertTrue('the hint about limit=0: ' + O.Text,
    Pos('inserting before a line', O.Text) > 0);

  { With limit=0 there must be no warning: that is a regular insertion. }
  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"Y","offset":2,"limit":0,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('the insertion is done: ' + O.Text, O.IsError);
  AssertTrue('the insertion has no warnings: ' + O.Text, Pos('warning', O.Text) = 0);
end;

{ Creation with offset <> 0 is forbidden: the file does not exist and does not
  appear. }
procedure TToolTests.TestCreateNotFromStart;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"new.txt","content":"x","offset":2}', FCtx);
  AssertTrue('creation not from the start is forbidden: ' + O.Text, O.IsError);
  AssertTrue('the message mentions offset = 0: ' + O.Text,
    Pos('offset = 0', O.Text) > 0);
  AssertFalse('the file is not created', FileExists(FullPath('new.txt')));

  O := FReg.Invoke('edit_text_file',
    '{"path":"new.txt","content":"x","offset":-1}', FCtx);
  AssertTrue('creation with a negative offset is forbidden: ' + O.Text, O.IsError);
  AssertFalse('the file is not created', FileExists(FullPath('new.txt')));
end;

{ The edit_text_file=0 key in [tools]: both the creation and the edit are
  rejected, the file does not appear and is not changed. }
procedure TToolTests.TestWriteDenied;
var
  O: TToolOutcome;
  Hash: string;
begin
  SetToolEnabled(FCtx.Cfg, 'edit_text_file', False);

  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"x"}', FCtx);
  AssertTrue('creation with edit_text_file=0 is forbidden: ' + O.Text, O.IsError);
  AssertTrue('the message names the tool: ' + O.Text,
    Pos('tool "edit_text_file" is disabled', O.Text) > 0);
  AssertFalse('the file is not created', FileExists(FullPath('a.txt')));

  { A file is prepared to check the edit ban. }
  SetToolEnabled(FCtx.Cfg, 'edit_text_file', True);
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"hello","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  SetToolEnabled(FCtx.Cfg, 'edit_text_file', False);
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"world","hash":"' + Hash + '"}', FCtx);
  AssertTrue('the edit with edit_text_file=0 is forbidden: ' + O.Text, O.IsError);
  AssertEquals('the file is not changed', 'hello', ReadFileText(FullPath('a.txt')));

  SetToolEnabled(FCtx.Cfg, 'edit_text_file', True);
end;

{ A disabled read-only tool without its own gate in the handler has to refuse as
  well: the check belongs to the registry (defence in depth), otherwise a call
  around the policy - from a test or from external code - would run the tool. }
procedure TToolTests.TestReadOnlyToolDisabled;
var
  O: TToolOutcome;
begin
  SetToolEnabled(FCtx.Cfg, 'file_list', False);
  SetToolEnabled(FCtx.Cfg, 'grep', False);
  try
    O := FReg.Invoke('file_list', '{"path":"."}', FCtx);
    AssertTrue('file_list=0 is refused: ' + O.Text, O.IsError);
    AssertTrue('the message names the tool: ' + O.Text,
      Pos('tool "file_list" is disabled', O.Text) > 0);

    O := FReg.Invoke('grep', '{"pattern":"x","path":"."}', FCtx);
    AssertTrue('grep=0 is refused: ' + O.Text, O.IsError);
    AssertTrue('the message names the tool: ' + O.Text,
      Pos('tool "grep" is disabled', O.Text) > 0);
  finally
    SetToolEnabled(FCtx.Cfg, 'file_list', True);
    SetToolEnabled(FCtx.Cfg, 'grep', True);
  end;
end;

{ The .mirmid service directory is closed for every file tool. }
procedure TToolTests.TestMirmidDirDenied;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing a file in .mirmid',
    WriteTextFile(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'secret.txt',
      'top-secret', Err));

  O := FReg.Invoke('read_text_file', '{"path":".mirmid/secret.txt"}', FCtx);
  AssertTrue('reading .mirmid is forbidden', O.IsError);
  O := FReg.Invoke('read_pascal_interface', '{"path":".mirmid/secret.txt"}', FCtx);
  AssertTrue('read_pascal_interface on .mirmid is forbidden: ' + O.Text, O.IsError);
  AssertTrue('the message reports the .mirmid ban: ' + O.Text,
    Pos('access denied', O.Text) > 0);

  O := FReg.Invoke('edit_text_file',
    '{"path":".mirmid/new.txt","content":"x"}', FCtx);
  AssertTrue('creation in .mirmid is forbidden: ' + O.Text, O.IsError);
  AssertFalse('the file in .mirmid is not created',
    FileExists(IncludeTrailingPathDelimiter(FDir) + '.mirmid' + PathDelim + 'new.txt'));

  O := FReg.Invoke('edit_text_file',
    '{"path":".mirmid/secret.txt","content":"x","hash":"00000000"}', FCtx);
  AssertTrue('the edit in .mirmid is forbidden: ' + O.Text, O.IsError);

  O := FReg.Invoke('exist_file', '{"path":".mirmid"}', FCtx);
  AssertTrue('exist_file on .mirmid is forbidden', O.IsError);

  O := FReg.Invoke('file_list', '{"path":".mirmid"}', FCtx);
  AssertTrue('file_list on .mirmid is forbidden', O.IsError);

  FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"1","offset":0}', FCtx);
  O := FReg.Invoke('file_list', '{"path":".","recursive":true}', FCtx);
  AssertFalse('the listing of the working folder', O.IsError);
  AssertTrue('the listing has no .mirmid', Pos('.mirmid', O.Text) = 0);

  O := FReg.Invoke('copy_file',
    '{"source":".mirmid/secret.txt","destination":"out.txt"}', FCtx);
  AssertTrue('copying from .mirmid is forbidden', O.IsError);

  O := FReg.Invoke('copy_file',
    '{"source":"a.txt","destination":".mirmid/out.txt"}', FCtx);
  AssertTrue('copying to .mirmid is forbidden', O.IsError);

end;

procedure TToolTests.TestFileList;
var
  O: TToolOutcome;
begin
  FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"1","offset":0}', FCtx);
  FReg.Invoke('edit_text_file', '{"path":"b.txt","content":"2","offset":0}', FCtx);
  O := FReg.Invoke('file_list', '{"path":"."}', FCtx);
  AssertFalse('the listing without an error', O.IsError);
  AssertTrue('a.txt is in the listing', Pos('a.txt', O.Text) > 0);
  AssertTrue('b.txt is in the listing', Pos('b.txt', O.Text) > 0);
end;

procedure TToolTests.TestShellPolicy;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('shell', '{"command":"echo mirmid"}', FCtx);
  AssertTrue('shell is off by default', O.IsError);
  AssertTrue('the message names the tool: ' + O.Text,
    Pos('tool "shell" is disabled', O.Text) > 0);
  SetToolEnabled(FCtx.Cfg, 'shell', True);
  O := FReg.Invoke('shell', '{"command":"echo mirmid"}', FCtx);
  AssertFalse('shell is allowed: ' + O.Text, O.IsError);
  AssertTrue('the output contains mirmid', Pos('mirmid', O.Text) > 0);
end;

procedure TToolTests.TestShellOutputLimitTruncates;
const
  Limit = 50;
  N = 2000;
var
  O: TToolOutcome;
  Cmd: string;
begin
  { The success branch of ToolShell: output longer than shell_output_limit is cut,
    but the exit code is kept and the answer gets a note with the byte count. }
  SetToolEnabled(FCtx.Cfg, 'shell', True);
  Cmd := 'echo ' + StringOfChar('x', N);

  FCtx.ShellOutputLimit := Limit;
  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertFalse('successful run: ' + O.Text, O.IsError);
  AssertTrue('the exit code is kept: ' + O.Text, Pos('exit=0', O.Text) > 0);
  AssertTrue('the truncation note: ' + O.Text,
    Pos('[... truncated: ' + IntToStr(Limit) + ' of ', O.Text) > 0);
  AssertTrue('the output is truncated (' + IntToStr(Length(O.Text)) + ' bytes)',
    Length(O.Text) < 300);

  { shell_output_limit = 0 - no limit: no note, the output comes in full. }
  FCtx.ShellOutputLimit := 0;
  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertFalse('successful run without a limit: ' + O.Text, O.IsError);
  AssertTrue('without a limit there is no truncation note: ' + O.Text,
    Pos('truncated', O.Text) = 0);
  AssertTrue('without a limit the output is complete (' +
    IntToStr(Length(O.Text)) + ' bytes)',
    Pos(StringOfChar('x', N), O.Text) > 0);
end;

{ The shell_output_limit truncation must not break a multi-byte UTF-8 character:
  with a 5-byte limit the output "äöüßéè" (12 bytes) gives "äö" (4 bytes)
  instead of "äö" plus the first byte of the next character. }
procedure TToolTests.TestShellOutputLimitUtf8;
const
  Limit = 5;
var
  O, Prep: TToolOutcome;
  Cmd, Body: string;
begin
  SetToolEnabled(FCtx.Cfg, 'shell', True);
  FCtx.ShellOutputLimit := Limit;

  { The file is printed as raw bytes (type/cat do not transcode the content), so
    the limit boundary falls inside a character for sure: the bytes of
    "äöüßéè" are C3 A4 C3 B6 C3 BC C3 9F C3 A9 C3 A8. }
  Prep := FReg.Invoke('edit_text_file',
    '{"path":"utf8.txt","content":"äöüßéè","offset":0}', FCtx);
  AssertFalse('file preparation: ' + Prep.Text, Prep.IsError);
  {$IFDEF UNIX}
  Cmd := 'cat utf8.txt';
  {$ELSE}
  Cmd := 'type utf8.txt';
  {$ENDIF}

  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertFalse('successful run: ' + O.Text, O.IsError);
  AssertTrue('the exit code is kept: ' + O.Text, Pos('exit=0', O.Text) > 0);
  AssertTrue('the whole answer is valid UTF-8', IsValidUTF8(O.Text));

  { The 5-byte limit cuts exactly before the third character: "äö" and the note
    remain. }
  Body := ReadBody(O.Text);
  AssertEquals('the character boundary is not cut', 1,
    Pos('äö' + sLineBreak, Body));
  AssertTrue('the note reports the cut 5th byte: ' + O.Text,
    Pos('[... truncated: 4 of 12 bytes shown]', O.Text) > 0);
end;


procedure TToolTests.TestShellOutputLimitOnTimeout;
const
  Limit = 20;
  N = 2000;
var
  O: TToolOutcome;
  Cmd, Reason: string;
  Nl: Integer;
begin
  { The error branch of ToolShell (a timeout): the output read before the process
    is stopped must be truncated to shell_output_limit as well, and the reason of
    the error must be kept in front of it. The wording of the reason belongs to
    RunProcess and is checked in test_util. }
  SetToolEnabled(FCtx.Cfg, 'shell', True);
  FCtx.ShellTimeout := 1;
  FCtx.ShellOutputLimit := Limit;
  {$IFDEF UNIX}
  { Prints 2000 bytes and hangs: by the timeout the output is already piped. }
  Cmd := 'printf ''' + StringOfChar('x', N) + '''; sleep 30';
  {$ELSE}
  { cmd.exe: echo prints at once, ping keeps the process until the timeout. }
  Cmd := 'echo ' + StringOfChar('x', N) + ' & ping -n 3 127.0.0.1 >nul';
  {$ENDIF}
  O := FReg.Invoke('shell', '{"command":"' + Cmd + '"}', FCtx);
  AssertTrue('the error branch: ' + O.Text, O.IsError);

  Reason := O.Text;
  Nl := Pos(sLineBreak, Reason);
  if Nl > 0 then
    Reason := Copy(Reason, 1, Nl - 1);
  AssertTrue('the reason of the error is kept: ' + O.Text, Reason <> '');
  AssertTrue('the reason comes before the command output: ' + O.Text,
    Pos('xxx', Reason) = 0);

  AssertTrue('the truncation note: ' + O.Text,
    Pos('[... truncated: ' + IntToStr(Limit) + ' of ', O.Text) > 0);
  AssertTrue('the output is truncated (' + IntToStr(Length(O.Text)) + ' bytes)',
    Length(O.Text) < 300);
end;

procedure TToolTests.TestEditWholeFileWithoutRange;
var
  O: TToolOutcome;
  Hash, Exp: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc\n","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertTrue('the file has 3 lines: ' + O.Text, Pos('lines: 3', O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X\ny","hash":"' + Hash + '"}', FCtx);
  AssertFalse('a whole replacement without a range: ' + O.Text, O.IsError);
  AssertTrue('all 3 lines are replaced: ' + O.Text,
    Pos('lines removed: 3, inserted: 2', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Exp := 'X' + sLineBreak + 'y';
  AssertTrue('2 lines after the replacement: ' + O.Text, Pos('lines: 2', O.Text) > 0);
  { The trailing line break of the source file is kept - visible by the size. }
  AssertTrue('the trailing line break is kept: ' + O.Text,
    Pos('size: ' + IntToStr(Length(Exp) + Length(sLineBreak)) + ' bytes', O.Text) > 0);
  AssertEquals('body after the whole replacement', Exp, ReadBody(O.Text));
end;

{ A limit past the end of the file does not hurt: the range is clipped to the
  end. }
procedure TToolTests.TestEditLimitBeyondEnd;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb\nc","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"Z","offset":2,"limit":999,"hash":"' + Hash + '"}', FCtx);
  AssertFalse('a limit past the end of the file does not hurt: ' + O.Text, O.IsError);
  AssertTrue('the lines 2..3 are replaced: ' + O.Text,
    Pos('lines removed: 2, inserted: 1', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('body after the edit', 'a' + sLineBreak + 'Z', ReadBody(O.Text));
end;

{ A large file: after the edit the lines are joined through TStringList.Text.
  The joining used to be a Text := Text + ... loop, which gave quadratic copying
  on thousands of lines; the content is checked to survive it. }
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
  AssertFalse('creating a file of ' + IntToStr(N) + ' lines: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","limit":0}', FCtx);
  AssertTrue('the file has ' + IntToStr(N) + ' lines: ' + O.Text,
    Pos('lines: ' + IntToStr(N), O.Text) > 0);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"X","offset":1000,"limit":1,"hash":"' + Hash + '"}',
    FCtx);
  AssertFalse('replacing line 1000: ' + O.Text, O.IsError);
  AssertTrue('the line count did not change: ' + O.Text,
    Pos('total lines: ' + IntToStr(N) + ' -> ' + IntToStr(N), O.Text) > 0);

  SL := TStringList.Create;
  try
    for I := 1 to N do
      if I = 1000 then
        SL.Add('X')
      else
        SL.Add('line ' + IntToStr(I));
    { The file was created with a trailing line break - it has to be kept. }
    Exp := SL.Text;
  finally
    SL.Free;
  end;

  FileText := ReadFileText(FullPath('a.txt'));
  AssertEquals('the lines are joined with the OS line break without losses',
    Exp, FileText);
  AssertEquals('the file size', Length(Exp), Length(FileText));

  O := FReg.Invoke('read_text_file', '{"path":"a.txt","limit":0}', FCtx);
  AssertFalse('reading after the edit: ' + O.Text, O.IsError);
  AssertEquals('the body is read back by the same tool',
    Copy(Exp, 1, Length(Exp) - Length(sLineBreak)), ReadBody(O.Text));
end;

{ An offset past the end of the file is an error and the file is not changed. }
procedure TToolTests.TestEditFirstLineBeyondEnd;
var
  O: TToolOutcome;
  Hash: string;
begin
  O := FReg.Invoke('edit_text_file', '{"path":"a.txt","content":"a\nb","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  Hash := ReadHash(O.Text);

  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"z","offset":9,"hash":"' + Hash + '"}', FCtx);
  AssertTrue('a range start outside the file is an error: ' + O.Text, O.IsError);
  AssertTrue('the hint about appending to the end: ' + O.Text,
    Pos('to append to the end', O.Text) > 0);

  O := FReg.Invoke('read_text_file', '{"path":"a.txt"}', FCtx);
  AssertEquals('the file is not changed', 'a' + sLineBreak + 'b', ReadBody(O.Text));
end;

{ grep: the context at the end of the file must not go past the bounds of the
  TStringList (with context > 0 it used to fail with "List index (N) out of
  bounds"). }
procedure TToolTests.TestGrepContextAtEndOfFile;
var
  O: TToolOutcome;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"aa\nbb hit\ncc hit","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('grep', '{"path":"a.txt","pattern":"hit","context":2}', FCtx);
  AssertFalse('grep with context at the end of the file: ' + O.Text, O.IsError);
  AssertTrue('line 1 is in the output: ' + O.Text, Pos('1: aa', O.Text) > 0);
  AssertTrue('line 2 is in the output: ' + O.Text, Pos('2: bb hit', O.Text) > 0);
  AssertTrue('line 3 is in the output: ' + O.Text, Pos('3: cc hit', O.Text) > 0);
  AssertTrue('3 lines in total: ' + O.Text, Pos('matches found: 3', O.Text) > 0);
end;

{ grep: a line that falls into the context of a neighbouring match is not
  duplicated. }
procedure TToolTests.TestGrepNoDuplicateLines;
var
  O: TToolOutcome;
  Body, Marker: string;
  Cnt: Integer;
begin
  O := FReg.Invoke('edit_text_file',
    '{"path":"a.txt","content":"hit one\nhit two\ntail","offset":0}', FCtx);
  AssertFalse('file preparation: ' + O.Text, O.IsError);

  O := FReg.Invoke('grep', '{"path":"a.txt","pattern":"hit","context":1}', FCtx);
  AssertFalse('grep with an overlapping context: ' + O.Text, O.IsError);
  AssertTrue('3 lines in total: ' + O.Text, Pos('matches found: 3', O.Text) > 0);

  { Line 2 is both a match and the context of line 1: printed once. }
  Body := O.Text;
  Marker := '2: hit two';
  Cnt := 0;
  while Pos(Marker, Body) > 0 do
  begin
    Inc(Cnt);
    Delete(Body, 1, Pos(Marker, Body) + Length(Marker) - 1);
  end;
  AssertEquals('line 2 is not duplicated: ' + O.Text, 1, Cnt);
end;

{ ---------------- read_pascal_interface ---------------- }

{ A unit is read up to the word implementation inclusive: the implementation
  section and the procedure bodies are not in the answer. }
procedure TToolTests.TestPascalUnitInterface;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing .pas', WriteTextFile(FullPath('demo.pas'),
    'unit Demo;' + sLineBreak +
    'interface' + sLineBreak +
    'type TFoo = class' + sLineBreak +
    'end;' + sLineBreak +
    'implementation' + sLineBreak +
    'procedure Hidden;' + sLineBreak +
    'end.', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('the unit is read: ' + O.Text, O.IsError);
  AssertEquals('the text up to implementation inclusive',
    'unit Demo;' + sLineBreak + 'interface' + sLineBreak +
    'type TFoo = class' + sLineBreak + 'end;' + sLineBreak + 'implementation',
    O.Text);
end;

{ A program is returned as a whole. }
procedure TToolTests.TestPascalProgramWhole;
var
  O: TToolOutcome;
  Err, Src: string;
begin
  Src := 'program Demo;' + sLineBreak + 'begin' + sLineBreak +
    '  writeln(''hi'');' + sLineBreak + 'end.';
  AssertTrue('preparing .dpr', WriteTextFile(FullPath('demo.dpr'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.dpr"}', FCtx);
  AssertFalse('the program is read: ' + O.Text, O.IsError);
  AssertEquals('the program is returned as a whole', Src, O.Text);
end;

{ Words in comments, strings and identifiers are not treated as keywords. }
procedure TToolTests.TestPascalIgnoresCommentsStringsAndIdents;
var
  O: TToolOutcome;
  Err, Src, Exp: string;
begin
  Src :=
    '{ program Fake }' + sLineBreak +
    'unit Noise; // unit and implementation in a comment' + sLineBreak +
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
    'unit Noise; // unit and implementation in a comment' + sLineBreak +
    '(* interface implementation *)' + sLineBreak +
    'interface' + sLineBreak +
    'type' + sLineBreak +
    '  TImplementation = class end;' + sLineBreak +
    'const' + sLineBreak +
    '  S = ''implementation'';' + sLineBreak +
    'implementation';
  AssertTrue('preparing .pas', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('comments and strings are skipped: ' + O.Text, O.IsError);
  AssertEquals('the real implementation is found', Exp, O.Text);
end;

{ An extension outside the Pascal/Delphi list is an error. }
procedure TToolTests.TestPascalBadExtension;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing .txt', WriteTextFile(FullPath('demo.txt'),
    'unit X; interface implementation', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.txt"}', FCtx);
  AssertTrue('the extension is rejected: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the extension: ' + O.Text,
    Pos('unsupported extension', O.Text) > 0);

  { .dpk is a package: by the contract it is neither a unit nor a program, so it
    is outside the list. }
  AssertTrue('preparing .dpk', WriteTextFile(FullPath('demo.dpk'),
    'package X; end.', Err));
  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.dpk"}', FCtx);
  AssertTrue('.dpk is rejected: ' + O.Text, O.IsError);
  AssertTrue('.dpk: the message mentions the extension: ' + O.Text,
    Pos('unsupported extension', O.Text) > 0);
end;

{ The file starts with neither unit nor program. }
procedure TToolTests.TestPascalNotUnitOrProgram;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing library', WriteTextFile(FullPath('nohead.pas'),
    'library Demo;' + sLineBreak + 'interface' + sLineBreak + 'implementation', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"nohead.pas"}', FCtx);
  AssertTrue('library is rejected: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the file start: ' + O.Text,
    Pos('must start with the word unit or program', O.Text) > 0);
end;

{ A unit without the interface section. }
procedure TToolTests.TestPascalMissingInterface;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing .pas', WriteTextFile(FullPath('nointf.pas'),
    'unit X;' + sLineBreak + 'type T = class end;', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"nointf.pas"}', FCtx);
  AssertTrue('a unit without interface is rejected: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the interface: ' + O.Text,
    Pos('has no interface section', O.Text) > 0);
end;

{ A unit without the implementation section. }
procedure TToolTests.TestPascalMissingImplementation;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing .pas', WriteTextFile(FullPath('noimpl.pas'),
    'unit X;' + sLineBreak + 'interface' + sLineBreak + 'type T = class end;', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"noimpl.pas"}', FCtx);
  AssertTrue('a unit without implementation is rejected: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the implementation: ' + O.Text,
    Pos('has no implementation section', O.Text) > 0);
end;

{ implementation before interface: an invalid module. }
procedure TToolTests.TestPascalImplementationBeforeInterface;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing .pas', WriteTextFile(FullPath('order.pas'),
    'unit X;' + sLineBreak + 'implementation' + sLineBreak + 'interface', Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"order.pas"}', FCtx);
  AssertTrue('the section order is checked: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the order: ' + O.Text,
    Pos('comes before the interface section', O.Text) > 0);
end;

{ implementation ends strictly at the end of the word, not at the end of the
  line: `uses Foo;` on the same line already belongs to the module body. }
procedure TToolTests.TestPascalImplementationEndsAtWord;
var
  O: TToolOutcome;
  Err, Src: string;
begin
  Src := 'unit X;' + sLineBreak + 'interface' + sLineBreak +
    'implementation uses Foo;' + sLineBreak + 'procedure Hidden;' + sLineBreak +
    'begin' + sLineBreak + 'end;' + sLineBreak + 'end.';
  AssertTrue('preparing .pas', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('the unit is read: ' + O.Text, O.IsError);
  AssertEquals('the answer ends with the word implementation',
    'unit X;' + sLineBreak + 'interface' + sLineBreak + 'implementation', O.Text);
end;

{ A UTF-8 BOM at the start of the file is not in the answer. }
procedure TToolTests.TestPascalBom;
var
  O: TToolOutcome;
  Err, Src, Exp: string;
begin
  Src := #$EF + #$BB + #$BF + 'unit X;' + sLineBreak + 'interface' +
    sLineBreak + 'implementation';
  Exp := 'unit X;' + sLineBreak + 'interface' + sLineBreak + 'implementation';
  AssertTrue('preparing .pas with a BOM', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('the file with a BOM is read: ' + O.Text, O.IsError);
  AssertEquals('the BOM is dropped', Exp, O.Text);
end;

{ A doubled quote inside a string and an &-identifier are not treated as
  keywords. }
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
  AssertTrue('preparing .pas', WriteTextFile(FullPath('demo.pas'), Src, Err));

  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertFalse('escaped names are not keywords: ' + O.Text, O.IsError);
  AssertEquals('the string with quotes and &implementation are skipped', Exp, O.Text);
end;

{ An unterminated comment and an unterminated string give a clear error instead
  of a garbage answer. }
procedure TToolTests.TestPascalUnclosed;
var
  O: TToolOutcome;
  Err: string;
begin
  AssertTrue('preparing a comment', WriteTextFile(FullPath('demo.pas'),
    'unit X;' + sLineBreak + 'interface' + sLineBreak + '{ implementation', Err));
  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertTrue('an unterminated comment is an error: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the comment: ' + O.Text,
    Pos('unterminated comment', O.Text) > 0);

  AssertTrue('preparing a string', WriteTextFile(FullPath('demo.pas'),
    'unit X;' + sLineBreak + 'interface' + sLineBreak +
    'const S = ''abc' + sLineBreak + 'implementation', Err));
  O := FReg.Invoke('read_pascal_interface', '{"path":"demo.pas"}', FCtx);
  AssertTrue('an unterminated string is an error: ' + O.Text, O.IsError);
  AssertTrue('the message mentions the string: ' + O.Text,
    Pos('unterminated string constant', O.Text) > 0);
end;

initialization
  RegisterTest(TToolTests);

end.
