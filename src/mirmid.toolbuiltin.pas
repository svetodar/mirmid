unit mirmid.toolbuiltin;
{ Built-in harness tools. They are registered in the mirmid.tools registry. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools;

{ Adds all built-in tools to the registry. }
procedure RegisterBuiltinTools(R: TToolRegistry);

implementation

uses
  SysUtils, Classes, fpjson, md5, mirmid.types, mirmid.util, mirmid.json;

const
  { Tool names whose [tools] gate lives in the handler itself: the same strings
    are needed at registration time, so they are kept as constants — a typo in
    the gate would disable a tool forever (fail-closed), and a drift between the
    gate, the registration and the mirmid.tools table would go unnoticed. }
  EDIT_TOOL_NAME = 'edit_text_file';
  COPY_TOOL_NAME = 'copy_file';
  SHELL_TOOL_NAME = 'shell';

{ ------------------------------------------------------------------ helpers }

function ArgStr(const A: TJSONObject; const Name, Def: string): string;
begin
  Result := JStr(A, Name, Def);
end;

function ArgInt(const A: TJSONObject; const Name: string; Def: Integer): Integer;
begin
  Result := JInt(A, Name, Def);
end;

function ArgBool(const A: TJSONObject; const Name: string; Def: Boolean): Boolean;
begin
  Result := JBool(A, Name, Def);
end;

{ True if the argument is present and is not null. }
function ArgPresent(const A: TJSONObject; const Name: string): Boolean;
var
  D: TJSONData;
begin
  D := A.FindPath(Name);
  Result := (D <> nil) and not (D is TJSONNull);
end;

function ResolvePath(const Ctx: TToolContext; const A: TJSONObject;
  const Name: string): string;
var
  S: string;
begin
  S := ArgStr(A, Name, '');
  if S = '' then
    Exit('');
  Result := ExpPath(S, Ctx.WorkDir);
end;

{ Denied access to the .mirmid directory: it holds the configuration and the
  sessions. }
function MirmidDirDenied(const Path: string): TToolOutcome;
begin
  Result := ErrResult('access denied: ' + Path +
    ' is inside the .mirmid service directory');
end;

{ True if the path does not point to .mirmid and is not inside it. }
function AllowedPath(const Ctx: TToolContext; const P: string): Boolean;
begin
  Result := not IsMirmidPath(Ctx.WorkDir, P);
end;

{ ------------------------------------------------------------- file_list }

function ToolFileList(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Dir, Err: string;
  Recursive: Boolean;
  L: TStringList;
  I: Integer;
begin
  Dir := ResolvePath(Ctx, A, 'path');
  if Dir = '' then
    Dir := Ctx.WorkDir;
  Recursive := ArgBool(A, 'recursive', False);
  if not AllowedPath(Ctx, Dir) then
    Exit(MirmidDirDenied(Dir));
  if not ListDir(Dir, Recursive, L, Err) then
    Exit(ErrResult(Err));
  try
    { The .mirmid service directory is not shown in the listing. }
    I := L.Count - 1;
    while I >= 0 do
    begin
      if IsMirmidPath(Ctx.WorkDir, ExcludeTrailingPathDelimiter(L[I])) then
        L.Delete(I);
      Dec(I);
    end;
    if L.Count = 0 then
      Result := OkResult('(directory is empty)')
    else begin
      I := L.Count;
      while L.Count > 100 do
        L.Pop;
      if I > 100 then
        L.Add('...')
      else
        L.Add('');
      L.Add(Format('Total: %d files and folders', [I]));
      Result := OkResult(L.Text);
    end;
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------- exist_file }

function ToolExistFile(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  P: string;
begin
  P := ResolvePath(Ctx, A, 'path');
  if P = '' then
    Exit(ErrResult('path is not set'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));
  if FileExists(P) then
    Result := OkResult('file exists: ' + P)
  else if DirectoryExists(P) then
    Result := OkResult('directory exists: ' + P)
  else
    Result := OkResult('does not exist: ' + P);
end;

{ --------------------------------------------------------- files: helpers }

{ Lowercases ASCII letters only: multi-byte UTF-8 sequences stay intact. }
function LowerASCII(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in ['A'..'Z'] then
      Result[I] := Chr(Ord(Result[I]) or $20);
end;

{ True if the character is a hexadecimal digit. }
function IsHexChar(const C: Char): Boolean;
begin
  Result := ((C >= '0') and (C <= '9')) or ((C >= 'a') and (C <= 'f')) or
            ((C >= 'A') and (C <= 'F'));
end;

{ Short content hash of a file: the first 4 bytes of MD5, that is 8 hex
  characters. read_text_file returns the same value and edit_text_file checks
  it. }
function ShortHash(const Data: RawByteString): string;
var
  D: TMD5Digest;
  B: RawByteString;
begin
  if Data = '' then
    Exit('00000000');
  B := Data;
  D := MD5Buffer(B[1], Length(B));
  Result := LowerASCII(IntToHex(D[0], 2) + IntToHex(D[1], 2) +
    IntToHex(D[2], 2) + IntToHex(D[3], 2));
end;

{ Hash from the hash argument: both the short hash itself and the whole header
  line of read_text_file are accepted. Returns '' if no hash was found. }
function NormHash(const S: string): string;
var
  T: string;
  P, I: Integer;
begin
  T := Trim(S);
  P := Pos('hash', LowerASCII(T));
  if P > 0 then
    I := P + Length('hash')
  else
    I := 1;
  while (I <= Length(T)) and not IsHexChar(T[I]) do
    Inc(I);
  P := I;
  while (I <= Length(T)) and IsHexChar(T[I]) do
    Inc(I);
  Result := LowerASCII(Copy(T, P, I - P));
  if Length(Result) <> 8 then
    Result := '';
end;

{ Splits the text into lines; line breaks may be any kind (LF, CRLF, CR).
  HadBreak — the text ended with a line break. }
procedure SplitLines(const Text: string; Lines: TStringList; out HadBreak: Boolean);
var
  I, N: Integer;
  Cur: string;
begin
  Lines.Clear;
  HadBreak := False;
  Cur := '';
  N := Length(Text);
  I := 1;
  while I <= N do
    if (Text[I] = #10) or (Text[I] = #13) then
    begin
      Lines.Add(Cur);
      Cur := '';
      HadBreak := True;
      if (Text[I] = #13) and (I < N) and (Text[I + 1] = #10) then
        Inc(I);
      Inc(I);
    end
    else
    begin
      Cur := Cur + Text[I];
      HadBreak := False;
      Inc(I);
    end;
  if Cur <> '' then
    Lines.Add(Cur);
end;

{ Converts the line breaks of the text to the format of the current OS. }
function ToNativeEOL(const S: string): string;
begin
  Result := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #10, sLineBreak, [rfReplaceAll]);
end;

{ Replaces the lines of the range described by offset/limit with NewLines.
  offset — 1-based number of the first line of the range; 0 — append to the end
  of the file; negative — counted from the end (-1 is the last line). limit —
  how many lines to replace, not negative (0 — insert without deleting); a range
  past the end of the file is clipped to the end. The number of removed lines is
  returned in Removed. }
function SpliceRange(Lines, NewLines: TStrings; Offset, Limit: Integer;
  out Removed: Integer; out Err: string): Boolean;
var
  I, N, First, Last: Integer;
begin
  Err := '';
  Removed := 0;
  N := Lines.Count;
  if Limit < 0 then
  begin
    Err := 'limit must not be negative';
    Exit(False);
  end;
  if Offset = 0 then
    First := N + 1
  else if Offset > 0 then
    First := Offset
  else
    First := N + Offset + 1;
  if (First < 1) or (First > N + 1) then
  begin
    Err := Format('range start is outside the file: offset=%d (total lines %d; ' +
      'to append to the end pass offset = 0)', [Offset, N]);
    Exit(False);
  end;
  if Limit >= N + 1 - First then
    Last := N + 1
  else
    Last := First + Limit;
  Removed := Last - First;
  Lines.BeginUpdate;
  try
    for I := 1 to Removed do
      Lines.Delete(First - 1);
    for I := NewLines.Count - 1 downto 0 do
      Lines.Insert(First - 1, NewLines[I]);
  finally
    Lines.EndUpdate;
  end;
  Result := True;
end;

{ --------------------------------------------------------- read_text_file }

function ToolReadText(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  P, Text, Err, Head, Body: string;
  Offset, Limit, I, Total: Integer;
  Numbered: Boolean;
  SL, BodyLines: TStringList;
  HadBreak: Boolean;
begin
  P := ResolvePath(Ctx, A, 'path');
  if P = '' then
    Exit(ErrResult('path is not set'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));
  if not FileExists(P) then
    Exit(ErrResult('file not found: ' + P));
  if not ReadTextFile(P, Text, Err) then
    Exit(ErrResult('cannot read file: ' + Err));

  Offset := ArgInt(A, 'offset', 1);
  Limit := ArgInt(A, 'limit', 400);
  Numbered := ArgBool(A, 'numbered', False);

  SL := TStringList.Create;
  try
    SplitLines(Text, SL, HadBreak);
    Total := SL.Count;
    { The header describes the whole file (the size and the hash of the entire
      content): edit_text_file needs this hash. }
    Head := Format('[mirmid] file: %s | size: %d bytes | lines: %d | hash: %s',
      [P, Length(Text), Total, ShortHash(Text)]);

    if Offset < 1 then
      Offset := 1;
    { The body is accumulated in a TStringList and joined through Text:
      appending Body := Body + on every line gives quadratic copying volume.
      SkipLastLineBreak keeps the answer from getting a trailing line break. }
    BodyLines := TStringList.Create;
    try
      BodyLines.LineBreak := sLineBreak;
      BodyLines.SkipLastLineBreak := True;
      I := Offset - 1;
      while (I < Total) and ((Limit <= 0) or (I < Offset - 1 + Limit)) do
      begin
        if Numbered then
          BodyLines.Add(Format('%6d| %s', [I + 1, SL[I]]))
        else
          BodyLines.Add(SL[I]);
        Inc(I);
      end;
      Body := BodyLines.Text;
    finally
      BodyLines.Free;
    end;

    if Body = '' then
      Result := OkResult(Head)
    else
      Result := OkResult(Head + sLineBreak + Body);
  finally
    SL.Free;
  end;
end;

{ ------------------------------------------------ read_pascal_interface }

{ True if the extension (in lower case) is a Delphi/Pascal source one. }
function IsPascalSourceExt(const Ext: string): Boolean;
const
  Exts: array[0..4] of string =
    ('.pas', '.pp', '.p', '.dpr', '.lpr');
var
  I: Integer;
begin
  for I := Low(Exts) to High(Exts) do
    if Ext = Exts[I] then
      Exit(True);
  Result := False;
end;

{ Characters allowed in a Pascal identifier. Bytes >= $80 are treated as part of
  an identifier (multi-byte UTF-8): otherwise the tail of a name could pass for
  a separate word. }
function IsPascalIdentChar(const C: Char): Boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '0'..'9', '_']) or (Ord(C) >= $80);
end;

function IsPascalIdentStart(const C: Char): Boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '_']) or (Ord(C) >= $80);
end;

{ Skips spaces, comments ({...} including the {$...} directives, (*...*) and
  //...) and string literals. Returns False if a comment or a string is not
  closed before the end of the file. }
function SkipPascalNoise(const Text: string; var P: Integer;
  out Err: string): Boolean;
var
  N: Integer;
begin
  Err := '';
  Result := True;
  N := Length(Text);
  while P <= N do
    case Text[P] of
      ' ', #9, #10, #13, #12:
        Inc(P);

      '{':
        begin
          Inc(P);
          while (P <= N) and (Text[P] <> '}') do
            Inc(P);
          if P > N then
          begin
            Err := 'unterminated comment { ... }';
            Exit(False);
          end;
          Inc(P);
        end;

      '(':
        if (P < N) and (Text[P + 1] = '*') then
        begin
          Inc(P, 2);
          while (P < N) and not ((Text[P] = '*') and (Text[P + 1] = ')')) do
            Inc(P);
          if P >= N then
          begin
            Err := 'unterminated comment (* ... *)';
            Exit(False);
          end;
          Inc(P, 2);
        end
        else
          Inc(P);

      '/':
        if (P < N) and (Text[P + 1] = '/') then
        begin
          while (P <= N) and not (Text[P] in [#10, #13]) do
            Inc(P);
        end
        else
          Inc(P);

      '''':
        begin
          { Opening quote; inside a string '' is an escaped quote. }
          Inc(P);
          while True do
          begin
            while (P <= N) and (Text[P] <> '''') do
              Inc(P);
            if P > N then
            begin
              Err := 'unterminated string constant';
              Exit(False);
            end;
            if (P < N) and (Text[P + 1] = '''') then
              Inc(P, 2) { a pair '' inside a string — keep going }
            else
            begin
              Inc(P); { closing quote }
              Break;
            end;
          end;
        end;
    else
      Break;
    end;
end;

{ The next Pascal word outside comments and strings. Separators (;, ., ( and so
  on) are skipped. The word is lowercased in ASCII; Escaped — the word is
  written as &identifier, so it is not a keyword. }
function NextPascalWord(const Text: string; var P: Integer;
  out Word: string; out Escaped: Boolean; out Err: string): Boolean;
var
  N, Start: Integer;
begin
  Result := False;
  Word := '';
  Escaped := False;
  N := Length(Text);
  while True do
  begin
    if not SkipPascalNoise(Text, P, Err) then
      Exit;
    if P > N then
      Exit;
    if (Text[P] = '&') or IsPascalIdentStart(Text[P]) then
      Break;
    Inc(P);
  end;
  if Text[P] = '&' then
  begin
    Escaped := True;
    Inc(P);
  end;
  Start := P;
  while (P <= N) and IsPascalIdentChar(Text[P]) do
    Inc(P);
  if P = Start then
    Exit; { a lone & is not a word }
  Word := LowerASCII(Copy(Text, Start, P - Start));
  Result := True;
end;

{ The first significant word of the file. Unlike NextPascalWord the separators
  are not skipped: only spaces and comments are allowed before the word. }
function FirstPascalWord(const Text: string; out Word: string;
  out WordEnd: Integer; out Err: string): Boolean;
var
  N, P, Start: Integer;
begin
  Result := False;
  Word := '';
  WordEnd := 0;
  Err := '';
  N := Length(Text);

  { A UTF-8 BOM at the start of the file is not part of the text. }
  P := 1;
  if (N >= 3) and (Text[1] = #$EF) and (Text[2] = #$BB) and (Text[3] = #$BF) then
    P := 4;

  if not SkipPascalNoise(Text, P, Err) then
    Exit;
  if (P > N) or not IsPascalIdentStart(Text[P]) then
  begin
    Err := 'the file does not start with the word unit or program';
    Exit;
  end;
  Start := P;
  while (P <= N) and IsPascalIdentChar(Text[P]) do
    Inc(P);
  Word := LowerASCII(Copy(Text, Start, P - Start));
  WordEnd := P;
  Result := True;
end;

{ Searches for the interface and implementation sections starting at StartPos.
  Returns the position of the last included character — the end of the word
  implementation. An error if the word implementation comes before interface or
  if one of the sections is missing. }
function PascalInterfaceEnd(const Text: string; StartPos: Integer;
  out EndPos: Integer; out Err: string): Boolean;
var
  P: Integer;
  Word: string;
  Escaped, SeenInterface: Boolean;
begin
  Result := False;
  EndPos := 0;
  Err := '';
  SeenInterface := False;
  P := StartPos;
  while NextPascalWord(Text, P, Word, Escaped, Err) do
  begin
    if Escaped then
      Continue;
    if Word = 'interface' then
      SeenInterface := True
    else if Word = 'implementation' then
    begin
      if not SeenInterface then
      begin
        Err := 'in the unit the implementation section comes before the interface section';
        Exit;
      end;
      { Strictly up to the end of the word: the rest of the line (for example
        `uses Foo;` in a one-line unit) already belongs to the implementation
        body. }
      EndPos := P - 1;
      Result := True;
      Exit;
    end;
  end;
  if Err <> '' then
    Exit;
  if not SeenInterface then
    Err := 'the unit has no interface section'
  else
    Err := 'the unit has no implementation section';
end;

function ToolReadPascalInterface(const A: TJSONObject;
  const Ctx: TToolContext): TToolOutcome;
var
  P, Ext, Text, Word, Err: string;
  FirstEnd, EndPos, TextStart: Integer;
begin
  P := ResolvePath(Ctx, A, 'path');
  if P = '' then
    Exit(ErrResult('path is not set'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));

  Ext := LowerASCII(ExtractFileExt(P));
  if not IsPascalSourceExt(Ext) then
    Exit(ErrResult(Format('unsupported extension "%s": expected one of ' +
      '.pas, .pp, .p, .dpr, .lpr', [Ext])));
  if not FileExists(P) then
    Exit(ErrResult('file not found: ' + P));
  if not ReadTextFile(P, Text, Err) then
    Exit(ErrResult('cannot read file: ' + Err));

  { A UTF-8 BOM is not part of the source: do not return it. }
  TextStart := 1;
  if (Length(Text) >= 3) and (Text[1] = #$EF) and (Text[2] = #$BB) and
     (Text[3] = #$BF) then
    TextStart := 4;

  if not FirstPascalWord(Text, Word, FirstEnd, Err) then
    Exit(ErrResult(Err));

  { A program is returned as a whole: its body is part of its interface. }
  if Word = 'program' then
    Exit(OkResult(Copy(Text, TextStart, MaxInt)));
  if Word <> 'unit' then
    Exit(ErrResult(Format('the file must start with the word unit or program ' +
      '(found: "%s")', [SanitizeUTF8(Word)])));

  if not PascalInterfaceEnd(Text, FirstEnd, EndPos, Err) then
    Exit(ErrResult(Err));
  Result := OkResult(Copy(Text, TextStart, EndPos - TextStart + 1));
end;

{ --------------------------------------------------------- edit_text_file }

function ToolEditText(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  P, Content, Hash, Text, Err, Diff, Hint: string;
  Offset, Limit, SizeBefore, SizeAfter, Removed, TotalBefore: Integer;
  Lines, Add, OldLines: TStringList;
  HadBreak, AddHadBreak: Boolean;
  LimitGiven: Boolean;
begin
  { Gate in the handler: the edit_text_file key of the [tools] section. }
  if not ToolEnabled(Ctx.Cfg, EDIT_TOOL_NAME) then
    Exit(ToolDisabled(EDIT_TOOL_NAME));
  P := ResolvePath(Ctx, A, 'path');
  if P = '' then
    Exit(ErrResult('path is not set'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));

  Content := ArgStr(A, 'content', '');
  Offset := ArgInt(A, 'offset', 1);
  { Without limit the range runs to the end of the file: a call with only path,
    content and hash replaces the whole content (like the former
    write_text_file). }
  Limit := ArgInt(A, 'limit', MaxInt);
  LimitGiven := ArgPresent(A, 'limit');
  Hash := ArgStr(A, 'hash', '');
  { The old contract (old/new) is no longer supported: an explicit error
    instead of silently overwriting the whole file. }
  if ArgPresent(A, 'old') or ArgPresent(A, 'new') then
    Exit(ErrResult('the old contract (old/new) is no longer supported: ' +
      'use offset/limit'));

  { Creation mode: the file does not exist yet, offset must be strictly zero. }
  if not FileExists(P) then
  begin
    if DirectoryExists(P) then
      Exit(ErrResult('the path is occupied by a directory: ' + P));
    if Offset <> 0 then
      Exit(ErrResult(Format('the file does not exist and offset=%d: creation is ' +
        'possible only with offset = 0', [Offset])));
    Text := ToNativeEOL(Content);
    if not WriteTextFile(P, Text, Err) then
      Exit(ErrResult('cannot create file: ' + Err));
    { Diff: from the empty file to the new content. }
    OldLines := TStringList.Create;
    Add := TStringList.Create;
    try
      SplitLines(ToNativeEOL(Content), Add, AddHadBreak);
      Diff := MakeUnifiedDiff(OldLines, Add, 'a/' + P, 'b/' + P);
    finally
      OldLines.Free;
      Add.Free;
    end;
    if Diff <> '' then
      Exit(OkResult(Format('file created: %s | size: %d bytes | hash: %s%s%s',
        [P, Length(Text), ShortHash(Text), sLineBreak, Diff])))
    else
      Exit(OkResult(Format('file created: %s | size: %d bytes | hash: %s',
        [P, Length(Text), ShortHash(Text)])));
  end;

  if not ReadTextFile(P, Text, Err) then
    Exit(ErrResult('cannot read file: ' + Err));

  if NormHash(Hash) = '' then
    Exit(ErrResult('hash is not set: the file already exists — pass the hash ' +
      'from read_text_file (8 characters) to edit it, or pass a non-existent ' +
      'path to create a new file'));
  if NormHash(Hash) <> ShortHash(Text) then
    Exit(ErrResult(Format('hash mismatch (passed %s, current %s): the file has ' +
      'changed — re-read it with the read_text_file tool',
      [NormHash(Hash), ShortHash(Text)])));

  SizeBefore := Length(Text);
  Lines := TStringList.Create;
  Add := TStringList.Create;
  OldLines := TStringList.Create;
  try
    SplitLines(Text, Lines, HadBreak);
    TotalBefore := Lines.Count;
    SplitLines(ToNativeEOL(Content), Add, AddHadBreak);

    { Keep the old lines before the splice to generate the diff. }
    OldLines.Assign(Lines);

    if not SpliceRange(Lines, Add, Offset, Limit, Removed, Err) then
      Exit(ErrResult(Err));

    { Hints about the most common call mistakes (the file is already changed, so
      this is a warning in the result rather than a refusal): appending the full
      text with offset=0 duplicates lines, and offset without limit cuts off the
      tail of the file. }
    Hint := '';
    if (Offset = 0) and (TotalBefore >= 3) and (Add.Count >= TotalBefore) then
      Hint := sLineBreak + 'warning: more lines were appended than the file had ' +
        '(' + IntToStr(Add.Count) + ' against ' + IntToStr(TotalBefore) +
        ') — lines may have been duplicated; replacing the whole file is offset=1 ' +
        'without limit, appending is a short fragment with offset=0';
    if (Offset <> 0) and (Offset <> 1) and not LimitGiven and (Removed > 0) then
      Hint := Hint + sLineBreak + 'warning: limit is not set, so every line from ' +
        'line ' + IntToStr(Offset) + ' to the end of the file was replaced (' +
        IntToStr(Removed) + ' removed); inserting before a line is limit=0';
    { Lines are joined with the line break of the current OS; whether the file
      ends with a line break stays as it was. Joining goes through
      TStringList.Text (one pass, one allocation) instead of Text := Text + ...
      in a loop: on files with thousands of lines that gave quadratic copying. }
    Lines.LineBreak := sLineBreak;
    Text := Lines.Text;
    if (Text <> '') and not HadBreak then
      SetLength(Text, Length(Text) - Length(sLineBreak));
    SizeAfter := Length(Text);

    if not WriteTextFile(P, Text, Err) then
      Exit(ErrResult('cannot write file: ' + Err));

    { Generate a unified diff between the old and the new content. }
    Diff := MakeUnifiedDiff(OldLines, Lines, 'a/' + P, 'b/' + P);

    if Diff <> '' then
      Result := OkResult(Format(
        'file changed: %s | lines removed: %d, inserted: %d | total lines: %d -> %d | ' +
        'size: %d -> %d bytes | hash: %s%s%s%s',
        [P, Removed, Add.Count, TotalBefore, Lines.Count, SizeBefore, SizeAfter,
         ShortHash(Text), Hint, sLineBreak, Diff]))
    else
      Result := OkResult(Format(
        'file changed: %s | lines removed: %d, inserted: %d | total lines: %d -> %d | ' +
        'size: %d -> %d bytes | hash: %s%s',
        [P, Removed, Add.Count, TotalBefore, Lines.Count, SizeBefore, SizeAfter,
         ShortHash(Text), Hint]));
  finally
    Add.Free;
    Lines.Free;
    OldLines.Free;
  end;
end;

{ -------------------------------------------------------------- copy_file }

function ToolCopyFile(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Src, Dst, Data, Err: string;
begin
  { Gate in the handler: the copy_file key of the [tools] section. }
  if not ToolEnabled(Ctx.Cfg, COPY_TOOL_NAME) then
    Exit(ToolDisabled(COPY_TOOL_NAME));
  Src := ResolvePath(Ctx, A, 'source');
  Dst := ResolvePath(Ctx, A, 'destination');
  if (Src = '') or (Dst = '') then
    Exit(ErrResult('the source and destination arguments are required'));
  if not AllowedPath(Ctx, Src) then
    Exit(MirmidDirDenied(Src));
  if not AllowedPath(Ctx, Dst) then
    Exit(MirmidDirDenied(Dst));
  if not ReadTextFile(Src, Data, Err) then
    Exit(ErrResult('cannot read the source: ' + Err));
  if not WriteTextFile(Dst, Data, Err) then
    Exit(ErrResult('cannot write the destination: ' + Err));
  Result := OkResult(Format('copied %d bytes: %s -> %s', [Length(Data), Src, Dst]));
end;

{ ------------------------------------------------------------------ shell }

function ToolShell(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Cmd, OutText, Err: string;
  EC, OrigLen: Integer;
begin
  { Gate in the handler: the shell key of the [tools] section. }
  if not ToolEnabled(Ctx.Cfg, SHELL_TOOL_NAME) then
    Exit(ToolDisabled(SHELL_TOOL_NAME));
  Cmd := ArgStr(A, 'command', '');
  if Cmd = '' then
    Exit(ErrResult('command is not set'));
  if RunProcess(Cmd, Ctx.WorkDir, Ctx.ShellTimeout, OutText, EC, Err) then
  begin
    OrigLen := Length(OutText);
    if (Ctx.ShellOutputLimit > 0) and (OrigLen > Ctx.ShellOutputLimit) then
    begin
      { Cut on a UTF-8 character boundary — otherwise a broken sequence would
        reach the model answer (HTTP 400 ill-formed UTF-8 byte). }
      OutText := TruncateUTF8(OutText, Ctx.ShellOutputLimit);
      OutText := OutText +
        Format(sLineBreak + '[... truncated: %d of %d bytes shown]',
          [Length(OutText), OrigLen]);
    end;
    Result := OkResult(Format('exit=%d%s%s', [EC, sLineBreak, OutText]))
  end
  else
  begin
    OrigLen := Length(OutText);
    if (Ctx.ShellOutputLimit > 0) and (OrigLen > Ctx.ShellOutputLimit) then
    begin
      OutText := TruncateUTF8(OutText, Ctx.ShellOutputLimit);
      OutText := OutText +
        Format(sLineBreak + '[... truncated: %d of %d bytes shown]',
          [Length(OutText), OrigLen]);
    end;
    Result := ErrResult(Err + sLineBreak + OutText);
  end;
end;

{ ------------------------------------------------------------------ grep }

{ Searches for a substring in the lines; returns the line numbers (1-based) in
  a TStringList (each line is a number). IgnoreCase — case-insensitive search. }
function FindMatches(const Lines: TStrings; const Pattern: string;
  IgnoreCase: Boolean): TStringList;
var
  I, P: Integer;
  Line, Pat: string;
begin
  Result := TStringList.Create;
  Pat := Pattern;
  if IgnoreCase then
    Pat := LowerCase(Pat);
  if Pat = '' then
    Exit;
  for I := 0 to Lines.Count - 1 do
  begin
    Line := Lines[I];
    if IgnoreCase then
      Line := LowerCase(Line);
    P := Pos(Pat, Line);
    if P > 0 then
      Result.Add(IntToStr(I + 1));
  end;
end;

{ Formats one grep result line: [path:]number: content. Prefix — the path
  prefix (empty for a single file). }
function GrepLine(const Prefix, Line: string; Num: Integer): string;
begin
  if Prefix = '' then
    Result := Format('%d: %s', [Num, Line])
  else
    Result := Format('%s:%d: %s', [Prefix, Num, Line]);
end;

{ Searches for pattern in one file. Prefix — the path prefix for the output
  (empty when searching a single file). Context — context lines around a match.
  MaxResults — the limit of lines in the output. }
function GrepOneFile(const FilePath, Pattern, Prefix: string;
  IgnoreCase, ShowPath: Boolean; Context, MaxResults: Integer;
  out Out: string; out Err: string): Integer;
var
  Text, Line: string;
  SL, Matches: TStringList;
  HadBreak: Boolean;
  I, J, J2, K, S, Total: Integer;
  PrevEnd: Integer;
  HasNull: Boolean;
  F: TFileStream;
  B: RawByteString;
  ReadSize: Integer;
begin
  Out := '';
  Err := '';
  Total := 0;

  { Quick binary file check: read the first 8K and look for #0. }
  try
    F := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
    try
      ReadSize := F.Size;
      if ReadSize > 8192 then
        ReadSize := 8192;
      SetLength(B, ReadSize);
      if ReadSize > 0 then
        F.ReadBuffer(B[1], ReadSize);
    finally
      F.Free;
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit(0);
    end;
  end;
  HasNull := False;
  for I := 1 to Length(B) do
    if B[I] = #0 then
    begin
      HasNull := True;
      Break;
    end;
  if HasNull then
    Exit(0); { binary file — skip it }

  if not ReadTextFile(FilePath, Text, Err) then
    Exit(0);

  SL := TStringList.Create;
  Matches := nil;
  try
    SplitLines(Text, SL, HadBreak);
    Matches := FindMatches(SL, Pattern, IgnoreCase);
    if Matches.Count = 0 then
      Exit(0);

    { Collect the result with context. PrevEnd — the number of the last line
      already emitted: it prevents repeating lines and going past the end of the
      file (otherwise TStringList raises "List index out of bounds"). }
    PrevEnd := 0;
    for I := 0 to Matches.Count - 1 do
    begin
      if Total >= MaxResults then
        Break;
      J := StrToInt(Matches[I]); { 1-based line number }

      { Context before the match: lines J-Context .. J-1. }
      K := J - Context;
      if K < 1 then
        K := 1;
      if K <= PrevEnd then
        K := PrevEnd + 1;
      for J2 := K to J - 1 do
      begin
        if Total >= MaxResults then
          Break;
        Line := SL[J2 - 1];
        if ShowPath then
          Out := Out + GrepLine(Prefix, Line, J2)
        else
          Out := Out + Format('%d: %s', [J2, Line]);
        if Out <> '' then
          Out := Out + sLineBreak;
        Inc(Total);
      end;

      { The match itself: print it only if it was not covered by the context of
        the previous match. }
      if (J > PrevEnd) and (Total < MaxResults) then
      begin
        Line := SL[J - 1];
        if ShowPath then
          Out := Out + GrepLine(Prefix, Line, J)
        else
          Out := Out + Format('%d: %s', [J, Line]);
        if Out <> '' then
          Out := Out + sLineBreak;
        Inc(Total);
      end;
      if J > PrevEnd then
        PrevEnd := J;

      { Context after the match: lines J+1 .. J+Context, not going past the end
        of the file and not repeating already emitted lines. }
      K := J + Context;
      if K > SL.Count then
        K := SL.Count;
      S := J + 1;
      if S <= PrevEnd then
        S := PrevEnd + 1;
      while (S <= K) and (Total < MaxResults) do
      begin
        Line := SL[S - 1];
        if ShowPath then
          Out := Out + GrepLine(Prefix, Line, S)
        else
          Out := Out + Format('%d: %s', [S, Line]);
        if Out <> '' then
          Out := Out + sLineBreak;
        Inc(Total);
        Inc(S);
      end;
      if K > PrevEnd then
        PrevEnd := K;
    end;
  finally
    SL.Free;
    if Matches <> nil then
      Matches.Free;
  end;
  Result := Total;
end;

{ Directory walk for grep. Recursive — whether to descend into subdirectories. }
procedure GrepDirRec(const Dir, Pattern, Prefix: string;
  IgnoreCase, Recursive: Boolean; Context, MaxResults: Integer;
  out Out: string; out Total: Integer);
var
  SR: TSearchRec;
  Full, Name, Rel, SubOut, Err: string;
  N: Integer;
begin
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      Name := SR.Name;
      if (Name = '.') or (Name = '..') then
        Continue;
      Full := IncludeTrailingPathDelimiter(Dir) + Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        { Skip the .mirmid service directory. }
        if (Name = '.mirmid') then
          Continue;
        if Recursive then
          GrepDirRec(Full, Pattern, Prefix, IgnoreCase, True, Context, MaxResults, Out, Total);
      end
      else
      begin
        if Total >= MaxResults then
          Break;
        { Relative path from Prefix (when Prefix is set). }
        if Prefix <> '' then
          Rel := Copy(Full, Length(Prefix) + 1, MaxInt)
        else
          Rel := Full;
        SubOut := '';
        N := GrepOneFile(Full, Pattern, Rel, IgnoreCase, True, Context,
          MaxResults - Total, SubOut, Err);
        if N > 0 then
        begin
          if Out <> '' then
            Out := Out + sLineBreak;
          Out := Out + SubOut;
          Inc(Total, N);
        end;
      end;
    until SysUtils.FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function ToolGrep(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  P, Pattern, Out, Err: string;
  Recursive, IgnoreCase: Boolean;
  Context, MaxResults, Total: Integer;
begin
  Pattern := ArgStr(A, 'pattern', '');
  if Pattern = '' then
    Exit(ErrResult('pattern is not set'));
  P := ResolvePath(Ctx, A, 'path');
  if P = '' then
    P := Ctx.WorkDir;
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));
  Recursive := ArgBool(A, 'recursive', False);
  IgnoreCase := ArgBool(A, 'ignore_case', False);
  Context := ArgInt(A, 'context', 0);
  MaxResults := ArgInt(A, 'max_results', 200);

  if FileExists(P) then
  begin
    { A single file. }
    Total := GrepOneFile(P, Pattern, '', IgnoreCase, False, Context,
      MaxResults, Out, Err);
    if Total = 0 then
      Result := OkResult('no matches found')
    else
      Result := OkResult(Format('matches found: %d%s%s', [Total, sLineBreak, Out]));
  end
  else if DirectoryExists(P) then
  begin
    { A directory. }
    Total := 0;
    Out := '';
    GrepDirRec(P, Pattern, P, IgnoreCase, Recursive, Context, MaxResults, Out, Total);
    if Total = 0 then
      Result := OkResult('no matches found')
    else
      Result := OkResult(Format('matches found: %d%s%s', [Total, sLineBreak, Out]));
  end
  else
    Result := ErrResult('path not found: ' + P);
end;
{ -------------------------------------------------------------- registration }

procedure RegisterBuiltinTools(R: TToolRegistry);
begin
  R.Add('file_list',
    'Lists files and subdirectories. Directories end with "/".',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Directory (the working folder by default)'),
        'recursive', PropBool('Whether to walk subdirectories (off by default)')]),
      ['path']),
    @ToolFileList);

  R.Add('exist_file',
    'Checks whether a file or a directory exists at the given path.',
    SchemaObject(
      TJSONObject.Create(['path', PropStr('Path to check')]),
      ['path']),
    @ToolExistFile);

  R.Add('read_text_file',
    'Reads a text file (UTF-8). The first line of the answer is a header ' +
    '"[mirmid] file: <path> | size: <N> bytes | lines: <N> | hash: <8 characters>"; ' +
    'edit_text_file needs this hash. The content follows; a line range and line ' +
    'numbers can be requested (the numbers match the lines of the file).',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Path to the file'),
        'offset', PropInt('First line, 1-based (1 by default)'),
        'limit', PropInt('How many lines to read, 0 — all (400 by default)'),
        'numbered', PropBool('Whether to add line numbers (off by default)')]),
      ['path']),
    @ToolReadText);
  R.Add('read_pascal_interface',
    'Reads the interface part of a Delphi/Pascal source. For a unit it returns ' +
    'the text up to the word implementation inclusive (the implementation ' +
    'section and procedure bodies are not in the answer), for a program the ' +
    'whole file. The file must start with the word unit or program (outside ' +
    'comments and strings), and a unit must contain the interface and ' +
    'implementation sections. The extensions .pas, .pp, .p, .dpr, .lpr are ' +
    'accepted.',
    SchemaObject(
      TJSONObject.Create(['path', PropStr('Path to the Pascal/Delphi source')]),
      ['path']),
    @ToolReadPascalInterface);

  R.Add(EDIT_TOOL_NAME,
    'Creates a file or replaces the line range described by offset/limit in it ' +
    'with content. offset — 1-based number of the first line of the range; 0 — ' +
    'append to the end of the file; negative — counted from the end (-1 is the ' +
    'last line). limit — how many lines to replace (not negative; 0 — insert ' +
    'without deleting); a range past the end of the file is clipped. Without ' +
    'offset/limit the whole file is replaced. To create a new file offset must ' +
    'be strictly 0. For an existing file the hash from read_text_file is ' +
    'required: if the file has changed, the edit is rejected. content = "" ' +
    'deletes the range. Line breaks in content are converted to the OS format. ' +
    'Important: offset = 0 appends to the end rather than replacing the file ' +
    '(the full text with offset = 0 duplicates lines); without limit the range ' +
    'runs to the end of the file, so to insert before line N pass limit = 0; ' +
    'content holds only the new lines of the range, without neighbouring lines ' +
    'from the read_text_file output.',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Path to the file'),
        'content', PropStr('New text of the range (an empty string deletes the range)'),
        'offset', PropInt('First line of the range, 1-based; 0 — append to the end (not a file replacement); negative — counted from the end (-1 is the last line). 1 by default. To create a new file — strictly 0'),
        'limit', PropInt('How many lines to replace, not negative (0 — insert without deleting). By default — to the end of the file'),
        'hash', PropStr('Hash from read_text_file (8 characters); required for an existing file')]),
      ['path']),
    @ToolEditText);

  R.Add(COPY_TOOL_NAME,
    'Copies a file from source to destination.',
    SchemaObject(
      TJSONObject.Create([
        'source', PropStr('Source file'),
        'destination', PropStr('Destination file')]),
      ['source', 'destination']),
    @ToolCopyFile);

  R.Add(SHELL_TOOL_NAME,
    'Runs a command in the system shell (bash on Unix, cmd.exe on Windows) and ' +
    'returns stdout+stderr and the exit code.',
    SchemaObject(
      TJSONObject.Create(['command', PropStr('Shell command')]),
      ['command']),
    @ToolShell);

  R.Add('grep',
    'Searches for a substring (pattern) in text files. path — a file or a ' +
    'directory (the working folder by default). recursive — walk ' +
    'subdirectories. ignore_case — case-insensitive search. context — context ' +
    'lines around a match. max_results — limit of lines in the output (200 by ' +
    'default). Binary files are skipped.',
    SchemaObject(
      TJSONObject.Create([
        'pattern', PropStr('Substring to search for (required)'),
        'path', PropStr('File or directory (the working folder by default)'),
        'recursive', PropBool('Whether to walk subdirectories (off by default)'),
        'ignore_case', PropBool('Case-insensitive search (off by default)'),
        'context', PropInt('Context lines around a match (0 by default)'),
        'max_results', PropInt('Maximum lines in the output (200 by default)')]),
      ['pattern']),
    @ToolGrep);
end;

end.
