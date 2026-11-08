unit mirmid.toolbuiltin;
{ Встроенные инструменты харнесса. Регистрируются в реестре mirmid.tools. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools;

{ Добавляет все встроенные инструменты в реестр. }
procedure RegisterBuiltinTools(R: TToolRegistry);

implementation

uses
  SysUtils, Classes, fpjson, md5, mirmid.types, mirmid.util, mirmid.json;

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

{ True, если аргумент передан и не равен null. }
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

{ Отказ в доступе к каталогу .mirmid: там лежат конфигурация и сессии. }
function MirmidDirDenied(const Path: string): TToolOutcome;
begin
  Result := ErrResult('доступ запрещён: ' + Path +
    ' находится в служебном каталоге .mirmid');
end;

{ True, если путь не указывает на .mirmid и не лежит внутри него. }
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
    { Служебный каталог .mirmid не показываем в листинге. }
    I := L.Count - 1;
    while I >= 0 do
    begin
      if IsMirmidPath(Ctx.WorkDir, ExcludeTrailingPathDelimiter(L[I])) then
        L.Delete(I);
      Dec(I);
    end;
    if L.Count = 0 then
      Result := OkResult('(каталог пуст)')
    else begin
      I := L.Count;
      while L.Count > 100 do
        L.Pop;
      if I > 100 then
        L.Add('...')
      else
        L.Add('');
      L.Add(Format('Всего %d файлов и папок', [I]));
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
    Exit(ErrResult('не задан path'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));
  if FileExists(P) then
    Result := OkResult('файл существует: ' + P)
  else if DirectoryExists(P) then
    Result := OkResult('каталог существует: ' + P)
  else
    Result := OkResult('не существует: ' + P);
end;

{ --------------------------------------------------------- файл: хелперы }

{ Приводит к нижнему регистру только латиницу: многобайтовый UTF-8 (русские
  буквы) не портится. }
function LowerASCII(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in ['A'..'Z'] then
      Result[I] := Chr(Ord(Result[I]) or $20);
end;

{ True, если символ — шестнадцатеричная цифра. }
function IsHexChar(const C: Char): Boolean;
begin
  Result := ((C >= '0') and (C <= '9')) or ((C >= 'a') and (C <= 'f')) or
            ((C >= 'A') and (C <= 'F'));
end;

{ Короткий хеш содержимого файла: первые 4 байта MD5, то есть 8 hex-символов.
  Это же значение отдаёт read_text_file и проверяет edit_text_file. }
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

{ Хеш из аргумента hash: принимается и сам короткий хеш, и строка-шапка
  read_text_file целиком. Возвращает '' — если хеша в строке не нашлось. }
function NormHash(const S: string): string;
var
  T: string;
  P, I: Integer;
begin
  T := Trim(S);
  P := Pos('хеш', T);
  if P > 0 then
    I := P + Length('хеш')
  else
  begin
    P := Pos('hash', LowerASCII(T));
    if P > 0 then
      I := P + Length('hash')
    else
      I := 1;
  end;
  while (I <= Length(T)) and not IsHexChar(T[I]) do
    Inc(I);
  P := I;
  while (I <= Length(T)) and IsHexChar(T[I]) do
    Inc(I);
  Result := LowerASCII(Copy(T, P, I - P));
  if Length(Result) <> 8 then
    Result := '';
end;

{ Разбивает текст на строки; переводы строк — любые (LF, CRLF, CR).
  HadBreak — текст заканчивался переводом строки. }
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

{ Приводит переводы строк текста к формату текущей ОС. }
function ToNativeEOL(const S: string): string;
begin
  Result := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #10, sLineBreak, [rfReplaceAll]);
end;

{ Заменяет строки диапазона, описанного offset/limit, на NewLines.
  offset — 1-базированный номер первой строки диапазона; 0 — дописать в конец
  файла; отрицательный — отсчёт от конца (-1 — последняя строка). limit —
  сколько строк заменить, не отрицательное (0 — вставка без удаления);
  диапазон за концом файла обрезается до конца. Число удалённых строк
  возвращается в Removed. }
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
    Err := 'limit не может быть отрицательным';
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
    Err := Format('начало диапазона вне файла: offset=%d (всего строк %d; чтобы ' +
      'дописать в конец, задайте offset = 0)', [Offset, N]);
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
    Exit(ErrResult('не задан path'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));
  if not FileExists(P) then
    Exit(ErrResult('файл не найден: ' + P));
  if not ReadTextFile(P, Text, Err) then
    Exit(ErrResult('не удалось прочитать файл: ' + Err));

  Offset := ArgInt(A, 'offset', 1);
  Limit := ArgInt(A, 'limit', 400);
  Numbered := ArgBool(A, 'numbered', False);

  SL := TStringList.Create;
  try
    SplitLines(Text, SL, HadBreak);
    Total := SL.Count;
    { Шапка описывает файл целиком (размер и хеш всего содержимого): хеш
      нужен инструменту edit_text_file. }
    Head := Format('[mirmid] файл: %s | размер: %d байт | строк: %d | хеш: %s',
      [P, Length(Text), Total, ShortHash(Text)]);

    if Offset < 1 then
      Offset := 1;
    { Тело копим в TStringList и склеиваем через Text: склейка Body := Body +
      на каждой строке даёт квадратичный объём копирования. SkipLastLineBreak —
      чтобы ответ не получал перевод строки в конце. }
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

{ True, если расширение (в нижнем регистре) — исходник Delphi/Pascal. }
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

{ Символы, допустимые в идентификаторе Pascal. Байты >= $80 считаем частью
  идентификатора (многобайтовый UTF-8): иначе хвост имени мог бы сойти за
  отдельное слово. }
function IsPascalIdentChar(const C: Char): Boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '0'..'9', '_']) or (Ord(C) >= $80);
end;

function IsPascalIdentStart(const C: Char): Boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '_']) or (Ord(C) >= $80);
end;

{ Пропускает пробелы, комментарии ({...} в том числе директивы {$...},
  (*...*) и //...) и строковые литералы. Возвращает False, если комментарий
  или строка не закрыты до конца файла. }
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
            Err := 'незакрытый комментарий { ... }';
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
            Err := 'незакрытый комментарий (* ... *)';
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
          { Открывающая кавычка; внутри строки '' — экранированная кавычка. }
          Inc(P);
          while True do
          begin
            while (P <= N) and (Text[P] <> '''') do
              Inc(P);
            if P > N then
            begin
              Err := 'незакрытая строковая константа';
              Exit(False);
            end;
            if (P < N) and (Text[P + 1] = '''') then
              Inc(P, 2) { пара '' внутри строки — продолжаем }
            else
            begin
              Inc(P); { закрывающая кавычка }
              Break;
            end;
          end;
        end;
    else
      Break;
    end;
end;

{ Очередное слово Pascal вне комментариев и строк. Разделители (;, ., ( и
  т. п.) пропускаются. Слово приводится к нижнему регистру ASCII; Escaped —
  слово записано как &идентификатор, то есть ключевым словом не является. }
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
    Exit; { одинокий & — не слово }
  Word := LowerASCII(Copy(Text, Start, P - Start));
  Result := True;
end;

{ Первое значимое слово файла. В отличие от NextPascalWord разделители не
  пропускаются: перед словом допустимы только пробелы и комментарии. }
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

  { UTF-8 BOM в начале файла — не часть текста. }
  P := 1;
  if (N >= 3) and (Text[1] = #$EF) and (Text[2] = #$BB) and (Text[3] = #$BF) then
    P := 4;

  if not SkipPascalNoise(Text, P, Err) then
    Exit;
  if (P > N) or not IsPascalIdentStart(Text[P]) then
  begin
    Err := 'файл не начинается со слова unit или program';
    Exit;
  end;
  Start := P;
  while (P <= N) and IsPascalIdentChar(Text[P]) do
    Inc(P);
  Word := LowerASCII(Copy(Text, Start, P - Start));
  WordEnd := P;
  Result := True;
end;

{ Ищет разделы interface и implementation начиная с позиции StartPos.
  Возвращает позицию последнего включаемого символа — конца слова
  implementation. Ошибка, если слово implementation встретилось раньше
  interface или какой-то из разделов отсутствует. }
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
        Err := 'в модуле раздел implementation идёт раньше раздела interface';
        Exit;
      end;
      { Строго по конец слова: остаток строки (например, `uses Foo;` в
        однострочном модуле) уже относится к телу реализации. }
      EndPos := P - 1;
      Result := True;
      Exit;
    end;
  end;
  if Err <> '' then
    Exit;
  if not SeenInterface then
    Err := 'в модуле отсутствует раздел interface'
  else
    Err := 'в модуле отсутствует раздел implementation';
end;

function ToolReadPascalInterface(const A: TJSONObject;
  const Ctx: TToolContext): TToolOutcome;
var
  P, Ext, Text, Word, Err: string;
  FirstEnd, EndPos, TextStart: Integer;
begin
  P := ResolvePath(Ctx, A, 'path');
  if P = '' then
    Exit(ErrResult('не задан path'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));

  Ext := LowerASCII(ExtractFileExt(P));
  if not IsPascalSourceExt(Ext) then
    Exit(ErrResult(Format('неподдерживаемое расширение «%s»: ожидается одно из ' +
      '.pas, .pp, .p, .dpr, .lpr', [Ext])));
  if not FileExists(P) then
    Exit(ErrResult('файл не найден: ' + P));
  if not ReadTextFile(P, Text, Err) then
    Exit(ErrResult('не удалось прочитать файл: ' + Err));

  { UTF-8 BOM — не часть исходника: не отдаём его обратно. }
  TextStart := 1;
  if (Length(Text) >= 3) and (Text[1] = #$EF) and (Text[2] = #$BB) and
     (Text[3] = #$BF) then
    TextStart := 4;

  if not FirstPascalWord(Text, Word, FirstEnd, Err) then
    Exit(ErrResult(Err));

  { Программа возвращается целиком: тело — часть её интерфейса. }
  if Word = 'program' then
    Exit(OkResult(Copy(Text, TextStart, MaxInt)));
  if Word <> 'unit' then
    Exit(ErrResult(Format('файл должен начинаться со слова unit или program ' +
      '(найдено: «%s»)', [SanitizeUTF8(Word)])));

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
  if not Ctx.AllowWrite then
    Exit(ErrResult('правка файлов запрещена (запустите с --allow-write)'));
  P := ResolvePath(Ctx, A, 'path');
  if P = '' then
    Exit(ErrResult('не задан path'));
  if not AllowedPath(Ctx, P) then
    Exit(MirmidDirDenied(P));

  Content := ArgStr(A, 'content', '');
  Offset := ArgInt(A, 'offset', 1);
  { Без limit диапазон идёт до конца файла: вызов только с path, content и
    hash заменяет содержимое целиком (как прежний write_text_file). }
  Limit := ArgInt(A, 'limit', MaxInt);
  LimitGiven := ArgPresent(A, 'limit');
  Hash := ArgStr(A, 'hash', '');
  { Старый контракт (old/new) больше не поддерживается: явная ошибка вместо
    молчаливой перезаписи всего файла. }
  if ArgPresent(A, 'old') or ArgPresent(A, 'new') then
    Exit(ErrResult('старый контракт (old/new) больше не поддерживается: ' +
      'используйте offset/limit'));

  { Режим создания: файла ещё нет, offset обязан быть строго равен нулю. }
  if not FileExists(P) then
  begin
    if DirectoryExists(P) then
      Exit(ErrResult('путь занят каталогом: ' + P));
    if Offset <> 0 then
      Exit(ErrResult(Format('файл не существует, а offset=%d: создание возможно ' +
        'только с offset = 0', [Offset])));
    Text := ToNativeEOL(Content);
    if not WriteTextFile(P, Text, Err) then
      Exit(ErrResult('не удалось создать файл: ' + Err));
    { Diff: от пустого файла к новому содержимому. }
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
      Exit(OkResult(Format('создан файл: %s | размер: %d байт | хеш: %s%s%s',
        [P, Length(Text), ShortHash(Text), sLineBreak, Diff])))
    else
      Exit(OkResult(Format('создан файл: %s | размер: %d байт | хеш: %s',
        [P, Length(Text), ShortHash(Text)])));
  end;

  if not ReadTextFile(P, Text, Err) then
    Exit(ErrResult('не удалось прочитать файл: ' + Err));

  if NormHash(Hash) = '' then
    Exit(ErrResult('не задан hash: файл уже существует — для правки передайте ' +
      'хеш из read_text_file (8 символов), для создания нового файла укажите ' +
      'несуществующий путь'));
  if NormHash(Hash) <> ShortHash(Text) then
    Exit(ErrResult(Format('хеш не совпадает (передан %s, сейчас %s): файл изменился — ' +
      'перечитайте его инструментом read_text_file', [NormHash(Hash), ShortHash(Text)])));

  SizeBefore := Length(Text);
  Lines := TStringList.Create;
  Add := TStringList.Create;
  OldLines := TStringList.Create;
  try
    SplitLines(Text, Lines, HadBreak);
    TotalBefore := Lines.Count;
    SplitLines(ToNativeEOL(Content), Add, AddHadBreak);

    { Сохраняем старые строки до splice для генерации diff. }
    OldLines.Assign(Lines);

    if not SpliceRange(Lines, Add, Offset, Limit, Removed, Err) then
      Exit(ErrResult(Err));

    { Подсказки про самые частые ошибки вызова (файл уже изменён, поэтому это
      не отказ, а предупреждение в результате): дописывание полного текста
      через offset=0 даёт дубли строк, а offset без limit срезает хвост файла. }
    Hint := '';
    if (Offset = 0) and (TotalBefore >= 3) and (Add.Count >= TotalBefore) then
      Hint := sLineBreak + 'внимание: дописано строк больше, чем было в файле ' +
        '(' + IntToStr(Add.Count) + ' против ' + IntToStr(TotalBefore) +
        ') — строки могли продублироваться; замена файла целиком — это offset=1 ' +
        'без limit, дописывание — короткий фрагмент с offset=0';
    if (Offset <> 0) and (Offset <> 1) and not LimitGiven and (Removed > 0) then
      Hint := Hint + sLineBreak + 'внимание: limit не задан, поэтому заменены все ' +
        'строки с ' + IntToStr(Offset) + '-й до конца файла (удалено ' +
        IntToStr(Removed) + '); вставка перед строкой — это limit=0';
    { Строки соединяются переводом строк текущей ОС; признак перевода строки в
      конце файла сохраняется таким, каким он был. Склейка идёт через
      TStringList.Text (один проход и одно выделение памяти), а не через
      Text := Text + … в цикле: на файлах в тысячи строк то давало
      квадратичное копирование. }
    Lines.LineBreak := sLineBreak;
    Text := Lines.Text;
    if (Text <> '') and not HadBreak then
      SetLength(Text, Length(Text) - Length(sLineBreak));
    SizeAfter := Length(Text);

    if not WriteTextFile(P, Text, Err) then
      Exit(ErrResult('не удалось записать файл: ' + Err));

    { Генерируем unified diff между старым и новым содержимым. }
    Diff := MakeUnifiedDiff(OldLines, Lines, 'a/' + P, 'b/' + P);

    if Diff <> '' then
      Result := OkResult(Format(
        'изменён файл: %s | удалено строк: %d, вставлено: %d | всего строк: %d -> %d | ' +
        'размер: %d -> %d байт | хеш: %s%s%s%s',
        [P, Removed, Add.Count, TotalBefore, Lines.Count, SizeBefore, SizeAfter,
         ShortHash(Text), Hint, sLineBreak, Diff]))
    else
      Result := OkResult(Format(
        'изменён файл: %s | удалено строк: %d, вставлено: %d | всего строк: %d -> %d | ' +
        'размер: %d -> %d байт | хеш: %s%s',
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
  if not Ctx.AllowWrite then
    Exit(ErrResult('копирование запрещено (запустите с --allow-write)'));
  Src := ResolvePath(Ctx, A, 'source');
  Dst := ResolvePath(Ctx, A, 'destination');
  if (Src = '') or (Dst = '') then
    Exit(ErrResult('нужны аргументы source и destination'));
  if not AllowedPath(Ctx, Src) then
    Exit(MirmidDirDenied(Src));
  if not AllowedPath(Ctx, Dst) then
    Exit(MirmidDirDenied(Dst));
  if not ReadTextFile(Src, Data, Err) then
    Exit(ErrResult('не удалось прочитать источник: ' + Err));
  if not WriteTextFile(Dst, Data, Err) then
    Exit(ErrResult('не удалось записать назначение: ' + Err));
  Result := OkResult(Format('скопировано %d байт: %s -> %s', [Length(Data), Src, Dst]));
end;

{ ------------------------------------------------------------------ shell }

function ToolShell(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Cmd, OutText, Err: string;
  EC, OrigLen: Integer;
begin
  if not Ctx.AllowShell then
    Exit(ErrResult('выполнение команд запрещено (запустите с --allow-shell)'));
  Cmd := ArgStr(A, 'command', '');
  if Cmd = '' then
    Exit(ErrResult('не задан command'));
  if RunProcess(Cmd, Ctx.WorkDir, Ctx.ShellTimeout, OutText, EC, Err) then
  begin
    OrigLen := Length(OutText);
    if (Ctx.ShellOutputLimit > 0) and (OrigLen > Ctx.ShellOutputLimit) then
    begin
      { Режем по границе символа UTF-8 — иначе в ответ модели уедет
        «битая» последовательность (HTTP 400 ill-formed UTF-8 byte). }
      OutText := TruncateUTF8(OutText, Ctx.ShellOutputLimit);
      OutText := OutText +
        Format(sLineBreak + '[… обрезано: показано %d из %d байт]',
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
        Format(sLineBreak + '[… обрезано: показано %d из %d байт]',
          [Length(OutText), OrigLen]);
    end;
    Result := ErrResult(Err + sLineBreak + OutText);
  end;
end;

{ ------------------------------------------------------------------ grep }

{ Ищет подстроку в строках; возвращает номера строк (1-базированные) в
  TStringList (каждая строка — число). IgnoreCase — регистронезависимый поиск. }
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

{ Форматирует одну строку результата grep: [путь:]номер: содержимое.
  Prefix — префикс пути (пустой для одиночного файла). }
function GrepLine(const Prefix, Line: string; Num: Integer): string;
begin
  if Prefix = '' then
    Result := Format('%d: %s', [Num, Line])
  else
    Result := Format('%s:%d: %s', [Prefix, Num, Line]);
end;

{ Ищет pattern в одном файле. Prefix — префикс пути для вывода (пустой,
  если ищем один файл). Context — строки контекста вокруг совпадения.
  MaxResults — предел строк в выводе. }
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

  { Быстрая проверка на бинарный файл: читаем первые 8K и ищем #0. }
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
    Exit(0); { бинарный файл — пропускаем }

  if not ReadTextFile(FilePath, Text, Err) then
    Exit(0);

  SL := TStringList.Create;
  Matches := nil;
  try
    SplitLines(Text, SL, HadBreak);
    Matches := FindMatches(SL, Pattern, IgnoreCase);
    if Matches.Count = 0 then
      Exit(0);

    { Собираем результат с контекстом. PrevEnd — номер последней уже
      выданной строки: он не даёт повторять строки и выходить за пределы
      файла (иначе TStringList даёт «List index out of bounds»). }
    PrevEnd := 0;
    for I := 0 to Matches.Count - 1 do
    begin
      if Total >= MaxResults then
        Break;
      J := StrToInt(Matches[I]); { 1-базированный номер строки }

      { Контекст до совпадения: строки J-Context .. J-1. }
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

      { Само совпадение: печатаем, только если оно не попало в контекст
        предыдущего совпадения. }
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

      { Контекст после совпадения: строки J+1 .. J+Context, не выходя за
        конец файла и не повторяя уже выданные строки. }
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

{ Обход каталога для grep. Recursive — заходить ли в подкаталоги. }
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
        { Пропускаем служебный каталог .mirmid. }
        if (Name = '.mirmid') then
          Continue;
        if Recursive then
          GrepDirRec(Full, Pattern, Prefix, IgnoreCase, True, Context, MaxResults, Out, Total);
      end
      else
      begin
        if Total >= MaxResults then
          Break;
        { Относительный путь от Prefix (если Prefix задан). }
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
    Exit(ErrResult('не задан pattern'));
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
    { Один файл. }
    Total := GrepOneFile(P, Pattern, '', IgnoreCase, False, Context,
      MaxResults, Out, Err);
    if Total = 0 then
      Result := OkResult('совпадений не найдено')
    else
      Result := OkResult(Format('найдено совпадений: %d%s%s', [Total, sLineBreak, Out]));
  end
  else if DirectoryExists(P) then
  begin
    { Каталог. }
    Total := 0;
    Out := '';
    GrepDirRec(P, Pattern, P, IgnoreCase, Recursive, Context, MaxResults, Out, Total);
    if Total = 0 then
      Result := OkResult('совпадений не найдено')
    else
      Result := OkResult(Format('найдено совпадений: %d%s%s', [Total, sLineBreak, Out]));
  end
  else
    Result := ErrResult('путь не найден: ' + P);
end;
{ -------------------------------------------------------------- registration }

procedure RegisterBuiltinTools(R: TToolRegistry);
begin
  R.Add('file_list',
    'Список файлов и подкаталогов. Каталоги помечены концевым «/».',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Каталог (по умолчанию — рабочая папка)'),
        'recursive', PropBool('Обходить ли подкаталоги (по умолчанию нет)')]),
      ['path']),
    @ToolFileList);

  R.Add('exist_file',
    'Проверяет, существует ли файл или каталог по указанному пути.',
    SchemaObject(
      TJSONObject.Create(['path', PropStr('Путь для проверки')]),
      ['path']),
    @ToolExistFile);

  R.Add('read_text_file',
    'Читает текстовый файл (UTF-8). Первая строка ответа — шапка ' +
    '«[mirmid] файл: <путь> | размер: <N> байт | строк: <N> | хеш: <8 символов>»; ' +
    'этот хеш нужен инструменту edit_text_file. Далее идёт содержимое; можно ' +
    'задать диапазон строк и нумерацию строк (номера соответствуют строкам файла).',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Путь к файлу'),
        'offset', PropInt('Начальная строка, 1-базированная (по умолчанию 1)'),
        'limit', PropInt('Сколько строк прочитать, 0 — все (по умолчанию 400)'),
        'numbered', PropBool('Добавлять номера строк (по умолчанию нет)')]),
      ['path']),
    @ToolReadText);
  R.Add('read_pascal_interface',
    'Читает интерфейсную часть исходника Delphi/Pascal. Для unit возвращает ' +
    'текст до слова implementation включительно (секция implementation и тела ' +
    'процедур не попадают в ответ), для program — файл целиком. Файл должен ' +
    'начинаться со слова unit или program (вне комментариев и строк), а unit — ' +
    'содержать разделы interface и implementation. Принимаются расширения ' +
    '.pas, .pp, .p, .dpr, .lpr.',
    SchemaObject(
      TJSONObject.Create(['path', PropStr('Путь к исходнику Pascal/Delphi')]),
      ['path']),
    @ToolReadPascalInterface);

  R.Add('edit_text_file',
    'Создаёт файл или меняет в нём диапазон строк, описываемый offset/limit, ' +
    'на content. offset — 1-базированный номер первой строки диапазона; 0 — ' +
    'дописать в конец файла; отрицательный — отсчёт от конца (-1 — последняя ' +
    'строка). limit — сколько строк заменить (не отрицательное; 0 — вставка ' +
    'без удаления); диапазон за концом файла обрезается. Без offset/limit ' +
    'заменяется весь файл. Для создания нового файла offset должен быть ' +
    'строго равен 0. Для существующего файла обязателен hash из read_text_file: ' +
    'если файл изменился, правка отклоняется. content = "" удаляет диапазон. ' +
    'Переводы строк content приводятся к формату ОС. Важно: offset = 0 — это ' +
    'дописывание в конец, а не замена файла (полный текст с offset = 0 даст ' +
    'дубли строк); без limit диапазон идёт до конца файла, поэтому для вставки ' +
    'перед строкой N указывайте limit = 0; content — только новые строки ' +
    'диапазона, без соседних строк из вывода read_text_file.',
    SchemaObject(
      TJSONObject.Create([
        'path', PropStr('Путь к файлу'),
        'content', PropStr('Новый текст диапазона (пустая строка — удалить диапазон)'),
        'offset', PropInt('Первая строка диапазона, 1-базированная; 0 — дописать в конец (не замена файла); отрицательный — отсчёт от конца (-1 — последняя строка). По умолчанию 1. Для создания нового файла — строго 0'),
        'limit', PropInt('Сколько строк заменить, не отрицательное (0 — вставка без удаления). По умолчанию — до конца файла'),
        'hash', PropStr('Хеш из read_text_file (8 символов); обязателен для существующего файла')]),
      ['path']),
    @ToolEditText);

  R.Add('copy_file',
    'Копирует файл из source в destination.',
    SchemaObject(
      TJSONObject.Create([
        'source', PropStr('Исходный файл'),
        'destination', PropStr('Файл назначения')]),
      ['source', 'destination']),
    @ToolCopyFile);

  R.Add('shell',
    'Выполняет команду в системной оболочке (bash на Unix, cmd.exe на Windows) ' +
    'и возвращает stdout+stderr и код выхода.',
    SchemaObject(
      TJSONObject.Create(['command', PropStr('Команда оболочки')]),
      ['command']),
    @ToolShell);

  R.Add('grep',
    'Ищет подстроку (pattern) в текстовых файлах. path — файл или каталог ' +
    '(по умолчанию — рабочая папка). recursive — обходить подкаталоги. ' +
    'ignore_case — регистронезависимый поиск. context — строки контекста ' +
    'вокруг совпадения. max_results — предел строк в выводе (по умолчанию 200). ' +
    'Бинарные файлы пропускаются.',
    SchemaObject(
      TJSONObject.Create([
        'pattern', PropStr('Подстрока для поиска (обязательно)'),
        'path', PropStr('Файл или каталог (по умолчанию — рабочая папка)'),
        'recursive', PropBool('Обходить ли подкаталоги (по умолчанию нет)'),
        'ignore_case', PropBool('Регистронезависимый поиск (по умолчанию нет)'),
        'context', PropInt('Строки контекста вокруг совпадения (по умолчанию 0)'),
        'max_results', PropInt('Максимум строк в выводе (по умолчанию 200)')]),
      ['pattern']),
    @ToolGrep);
end;

end.
