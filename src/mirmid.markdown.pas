unit mirmid.markdown;
{ Разбор разметки Markdown для вывода в терминал: цветной рендер основного
  ответа (ANSI-коды) и чистый текст без разметки (для размышлений). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

{ Ядро рендера: при Colored=True — строка с ANSI-кодами, иначе чистый текст
  без разметки. Не зависит от TTY/NO_COLOR (управляет вызывающий код). }
function RenderMarkdownCore(const Text: string; Colored: Boolean): string;

{ Рендерит markdown-текст в строку с ANSI-кодами для терминала.
  Вне терминала (или при заданной NO_COLOR) возвращает исходный текст как есть. }
function RenderMarkdown(const Text: string; FD: Integer = 1): string;

{ Убирает разметку markdown, оставляя читаемый чистый текст. }
function StripMarkdown(const Text: string): string;

{ Разбивает текст на строки (LF, CR и CRLF). }
function SplitLines(const Text: string): TStringList;

{ True, если строка похожа на строку таблицы: после обреза начинается с «|»
  и содержит хотя бы ещё одну «|». }
function IsTableLine(const S: string): Boolean;

{ True, если строка может оказаться началом таблицы: после обреза начинается
  с «|». Позволяет не показывать частичную строку таблицы построчно. }
function IsTableStart(const S: string): Boolean;

{ True, если строка — разделительная строка таблицы: ячейки состоят только
  из «-», «:» и пробелов, и есть хотя бы один «-». }
function IsTableSeparator(const S: string): Boolean;

{ True, если разрыв после Prefix не рвёт инлайн-разметку: не внутри `кода`,
  **жирного**, *курсива*, ~~зачёркнутого~~ и не внутри [ссылки]. Служит
  фильтром точек переноса: перенос внутри разметки показал бы «**» как текст. }
function MarkdownBreakSafe(const Prefix: string): Boolean;

{ Рендерит таблицу: выравнивает колонки по максимальной видимой ширине
  ячеек (недостающие ячейки дополняются пустыми). Разделительные строки
  рисуются дефисами шириной колонки. }
function RenderTable(const Lines: TStringList; Colored: Boolean): string;

implementation

uses
  mirmid.util;

{ Forward: RenderTable (ниже) использует RenderStyled, определённый позже. }
function RenderStyled(const S: string; const BaseExtra: string;
  Colored: Boolean): string; forward;

const
  { SGR-палитра для основного вывода (разные цвета под разные элементы). }
  C_MD_HEADING = '1;96';      { жирный ярко-голубой — заголовки #..###### }
  C_MD_CODE    = '38;5;209';  { оранжевый — `инлайн-код` }
  C_MD_CODEBLK = '38;5;245';  { серый — ограждённые блоки ```...``` }
  C_MD_LINK    = '4;36';      { подчёркнутый голубой — [текст](url) }
  C_MD_QUOTE   = '2;93';      { приглушённый жёлтый — цитаты > }
  C_MD_BULLET  = '38;5;46';   { зелёный — маркеры списков - * + N. }
  C_MD_HRULE   = '90';        { серый — горизонтальная линия --- }

{ --------------------------------------------------------------- helpers }

function IsSpaceChar(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

{ Склеивает непустые SGR-части через ';'. }
function JoinSGR(const Parts: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(Parts) to High(Parts) do
    if Parts[I] <> '' then
      if Result = '' then
        Result := Parts[I]
      else
        Result := Result + ';' + Parts[I];
end;

{ Текущий SGR-код из активных атрибутов и базового контекста строки. }
function SGRFor(Bold, Italic, Strike: Boolean; const Extra: string): string;
var
  P: array[0..3] of string;
begin
  P[0] := Extra;
  if Bold then P[1] := '1' else P[1] := '';
  if Italic then P[2] := '3' else P[2] := '';
  if Strike then P[3] := '9' else P[3] := '';
  Result := JoinSGR(P);
  if Result = '' then
    Result := '0';
end;

procedure EmitSGR(var Out: string; const Code: string);
begin
  { Цвет приглушается платформенной яркостью (COLOR_BRIGHTNESS). }
  Out := Out + #27 + '[' + DimSGR(Code) + 'm';
end;

{ Разбивает текст на строки (LF, CR и CRLF). }
function SplitLines(const Text: string): TStringList;
var
  I, Start: Integer;
begin
  Result := TStringList.Create;
  Start := 1;
  while Start <= Length(Text) do
  begin
    I := Start;
    while (I <= Length(Text)) and (Text[I] <> #10) and (Text[I] <> #13) do
      Inc(I);
    if I > Start then
      Result.Add(Copy(Text, Start, I - Start));
    if I > Length(Text) then
      Break;
    if (Text[I] = #13) and (I < Length(Text)) and (Text[I + 1] = #10) then
      Start := I + 2
    else
      Start := I + 1;
  end;
end;

{ Позиция символа C в S начиная с From (0 — не найден). }
function FindChar(C: Char; const S: string; From: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := From to Length(S) do
    if S[I] = C then
      Exit(I);
end;

{ True, если S — горизонтальная линия: три и более одинаковых -, * или _. }
function IsHRule(const S: string): Boolean;
var
  I: Integer;
begin
  Result := Length(S) >= 3;
  if not Result then
    Exit;
  for I := 2 to Length(S) do
    if S[I] <> S[1] then
      Exit(False);
  Result := (S[1] = '-') or (S[1] = '*') or (S[1] = '_');
end;

{ --------------------------------------------------------------- tables }

{ Разбивает строку таблицы на ячейки: снимает крайние «|», обрезает
  пробелы. «\|» считается литеральной пипой внутри ячейки. }
function SplitTableRow(const S: string): TStringList;
var
  I, Start: Integer;
  T: string;
begin
  Result := TStringList.Create;
  T := Trim(S);
  if (Length(T) > 0) and (T[1] = '|') then
    Delete(T, 1, 1);
  if (Length(T) > 0) and (T[Length(T)] = '|') then
    Delete(T, Length(T), 1);
  Start := 1;
  I := 1;
  while I <= Length(T) do
  begin
    if (T[I] = '|') and ((I = 1) or (T[I - 1] <> '\')) then
    begin
      Result.Add(Trim(Copy(T, Start, I - Start)));
      Start := I + 1;
    end;
    Inc(I);
  end;
  Result.Add(Trim(Copy(T, Start, MaxInt)));
end;

function IsTableLine(const S: string): Boolean;
var
  T: string;
begin
  T := Trim(S);
  Result := (Length(T) >= 2) and (T[1] = '|') and
            (Pos('|', Copy(T, 2, MaxInt)) > 0);
end;

function IsTableStart(const S: string): Boolean;
var
  T: string;
begin
  T := Trim(S);
  Result := (Length(T) > 0) and (T[1] = '|');
end;

function IsTableSeparator(const S: string): Boolean;
var
  Cells: TStringList;
  I, P: Integer;
  HasDash: Boolean;
begin
  Result := False;
  if not IsTableLine(S) then
    Exit;
  Cells := SplitTableRow(S);
  try
    Result := True;
    HasDash := False;
    for I := 0 to Cells.Count - 1 do
    begin
      P := 1;
      while P <= Length(Cells[I]) do
      begin
        if Cells[I][P] = '-' then
          HasDash := True
        else if not (Cells[I][P] in ['-', ':', ' ']) then
        begin
          Result := False;
          Break;
        end;
        Inc(P);
      end;
      if not Result then
        Break;
    end;
    Result := Result and HasDash;
  finally
    Cells.Free;
  end;
end;

function MarkdownBreakSafe(const Prefix: string): Boolean;
var
  I, N: Integer;
  InCode, Bold, Italic, Strike: Boolean;
  Bracket: Integer;
begin
  InCode := False;
  Bold := False;
  Italic := False;
  Strike := False;
  Bracket := 0;
  N := Length(Prefix);
  I := 1;
  while I <= N do
  begin
    if InCode then
    begin
      if Prefix[I] = '`' then
        InCode := False;
      Inc(I);
      Continue;
    end;
    if Prefix[I] = '`' then
    begin
      InCode := True;
      Inc(I);
      Continue;
    end;
    if (I < N) and (Prefix[I] = '*') and (Prefix[I + 1] = '*') then
    begin
      Bold := not Bold;
      Inc(I, 2);
      Continue;
    end;
    if (I < N) and (Prefix[I] = '~') and (Prefix[I + 1] = '~') then
    begin
      Strike := not Strike;
      Inc(I, 2);
      Continue;
    end;
    if Prefix[I] = '*' then
    begin
      Italic := not Italic;
      Inc(I);
      Continue;
    end;
    if Prefix[I] = '_' then
    begin
      Italic := not Italic;
      Inc(I);
      Continue;
    end;
    if Prefix[I] = '[' then
      Inc(Bracket)
    else if Prefix[I] = ']' then
      Dec(Bracket);
    Inc(I);
  end;
  Result := (not InCode) and (not Bold) and (not Italic) and (not Strike) and
            (Bracket = 0);
end;

function RenderTable(const Lines: TStringList; Colored: Boolean): string;
var
  I, J, N, W: Integer;
  Rows: array of TStringList;
  Widths: array of Integer;
  R, Cell, B: string;
  Sep: Boolean;
  NCols: Integer;

  { Строит строку границы: Left + ─*(w+2) + Mid + ─*(w+2) + ... + Right.
    При Colored=True обёрнута в SGR-код C_MD_HRULE. }
  procedure BuildBorder(const Left, Mid, Right: string);
  var
    K, M: Integer;
  begin
    B := Left;
    for K := 0 to NCols - 1 do
    begin
      M := Widths[K] + 2;
      while M > 0 do
      begin
        B := B + '─';
        Dec(M);
      end;
      if K < NCols - 1 then
        B := B + Mid
      else
        B := B + Right;
    end;
    if Colored then
    begin
      EmitSGR(R, C_MD_HRULE);
      R := R + B;
      EmitSGR(R, '0');
    end
    else
      R := R + B;
  end;

begin
  Result := '';
  N := Lines.Count;
  if N = 0 then
    Exit;
  SetLength(Rows, N);
  SetLength(Widths, 0);
  for I := 0 to N - 1 do
  begin
    Rows[I] := SplitTableRow(Lines[I]);
    if Rows[I].Count > Length(Widths) then
    begin
      SetLength(Widths, Rows[I].Count);
      for J := Length(Widths) - Rows[I].Count to Length(Widths) - 1 do
        Widths[J] := 0;
    end;
  end;
  NCols := Length(Widths);
  { Ширина колонки — максимальная видимая ширина ячейки без разметки
    (разделительные строки в расчёт не идут). }
  for I := 0 to N - 1 do
    if not IsTableSeparator(Lines[I]) then
      for J := 0 to Rows[I].Count - 1 do
      begin
        W := VisibleLen(StripMarkdown(Rows[I][J]));
        if W > Widths[J] then
          Widths[J] := W;
      end;

  { Верхняя граница: ┌───┬───┐ }
  R := '';
  BuildBorder('┌', '┬', '┐');
  Result := R;

  for I := 0 to N - 1 do
  begin
    Sep := IsTableSeparator(Lines[I]);
    R := '';
    if Sep then
    begin
      { Разделитель: ├───┼───┤ }
      BuildBorder('├', '┼', '┤');
    end
    else
    begin
      { Строка данных: │ cell │ cell │; вертикальные черты серые }
      if Colored then
      begin
        EmitSGR(R, C_MD_HRULE);
        R := R + '│';
        EmitSGR(R, '0');
      end
      else
        R := '│';
      for J := 0 to NCols - 1 do
      begin
        if J < Rows[I].Count then
          Cell := Rows[I][J]
        else
          Cell := '';
        W := VisibleLen(StripMarkdown(Cell));
        if W < Widths[J] then
          Cell := Cell + StringOfChar(' ', Widths[J] - W);
        if Colored then
        begin
          R := R + ' ' + RenderStyled(Cell, '', Colored) + ' ';
          EmitSGR(R, C_MD_HRULE);
          R := R + '│';
          EmitSGR(R, '0');
        end
        else
          R := R + ' ' + RenderStyled(Cell, '', Colored) + ' │';
      end;
    end;
    Result := Result + sLineBreak + R;
  end;

  { Нижняя граница: └───┴───┘ }
  R := '';
  BuildBorder('└', '┴', '┘');
  Result := Result + sLineBreak + R;

  for I := 0 to N - 1 do
    Rows[I].Free;
end;

{ --------------------------------------------------------------- inline }

{ Сканирует строку по символам, снимая инлайн-разметку. При Colored=True
  печатает SGR-коды при смене атрибутов. BaseExtra — базовый контекст строки
  (цвет заголовка и т.п.). Начальный/конечный код не печатает — это делает
  RenderStyled. }
function RenderInlineBody(const S: string; const BaseExtra: string;
  Colored: Boolean): string;
var
  I, N: Integer;
  Bold, Italic, Strike, InCode: Boolean;
  J, K: Integer;
  LinkText, Extra: string;

  procedure Emit(const B, It, St: Boolean; const E: string);
  begin
    if Colored then
      EmitSGR(Result, SGRFor(B, It, St, E));
  end;

  { Маркер длиной M в позиции P может быть открывающим. }
  function MarkerOpen(P, M: Integer): Boolean;
  begin
    if P > 1 then
      Result := IsSpaceChar(S[P - 1]) or (S[P - 1] = '*') or (S[P - 1] = '_')
    else
      Result := True;
    if not Result then
      Exit(False);
    if P + M > N then
      Exit(False);
    Result := not IsSpaceChar(S[P + M]);
  end;

  { Маркер в позиции P может быть закрывающим. }
  function MarkerClose(P: Integer): Boolean;
  begin
    Result := (P > 1) and not IsSpaceChar(S[P - 1]);
  end;

begin
  Result := '';
  N := Length(S);
  I := 1;
  Bold := False;
  Italic := False;
  Strike := False;
  InCode := False;
  while I <= N do
  begin
    if InCode then
    begin
      { Внутри кодовой вставки разметку не разбираем. }
      if S[I] = '`' then
      begin
        InCode := False;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I);
      end
      else
      begin
        Result := Result + S[I];
        Inc(I);
      end;
    end
    else if (I < N) and (S[I] = '*') and (S[I + 1] = '*') then
    begin
      { **жирный** }
      if not Bold and MarkerOpen(I, 2) then
      begin
        Bold := True;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I, 2);
      end
      else if (Bold) and MarkerClose(I) then
      begin
        Bold := False;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I, 2);
      end
      else
      begin
        Result := Result + '**';
        Inc(I, 2);
      end;
    end
    else if S[I] = '*' then
    begin
      { *курсив* }
      if not Italic and MarkerOpen(I, 1) then
      begin
        Italic := True;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I);
      end
      else if (Italic) and MarkerClose(I) then
      begin
        Italic := False;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I);
      end
      else
      begin
        Result := Result + '*';
        Inc(I);
      end;
    end
    else if S[I] = '_' then
    begin
      { _курсив_ }
      if not Italic and MarkerOpen(I, 1) then
      begin
        Italic := True;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I);
      end
      else if (Italic) and MarkerClose(I) then
      begin
        Italic := False;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I);
      end
      else
      begin
        Result := Result + '_';
        Inc(I);
      end;
    end
    else if (I < N) and (S[I] = '~') and (S[I + 1] = '~') then
    begin
      { ~~зачёркнутый~~ }
      if not Strike and MarkerOpen(I, 2) then
      begin
        Strike := True;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I, 2);
      end
      else if (Strike) and MarkerClose(I) then
      begin
        Strike := False;
        Emit(Bold, Italic, Strike, BaseExtra);
        Inc(I, 2);
      end
      else
      begin
        Result := Result + '~~';
        Inc(I, 2);
      end;
    end
    else if S[I] = '`' then
    begin
      { `инлайн-код` }
      InCode := True;
      Extra := JoinSGR([BaseExtra, C_MD_CODE]);
      Emit(Bold, Italic, Strike, Extra);
      Inc(I);
    end
    else if S[I] = '[' then
    begin
      { [текст](url) — ссылка: подчёркнутый текст, URL не печатается. }
      J := FindChar(']', S, I + 1);
      K := 0;
      if (J > 0) and (J < N) and (S[J + 1] = '(') then
        K := FindChar(')', S, J + 2);
      if K > J + 1 then
      begin
        LinkText := Copy(S, I + 1, J - I - 1);
        Extra := JoinSGR([BaseExtra, C_MD_LINK]);
        Emit(Bold, Italic, Strike, Extra);
        Result := Result + RenderInlineBody(LinkText, Extra, Colored);
        Emit(Bold, Italic, Strike, BaseExtra);
        I := K + 1;
      end
      else
      begin
        Result := Result + '[';
        Inc(I);
      end;
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

{ Рендерит строку в базовом контексте BaseExtra: начальный код, содержимое,
  сброс. Пустая строка — без кодов. }
function RenderStyled(const S: string; const BaseExtra: string;
  Colored: Boolean): string;
begin
  Result := '';
  if S = '' then
    Exit;
  if not Colored then
    Exit(RenderInlineBody(S, '', False));
  EmitSGR(Result, SGRFor(False, False, False, BaseExtra));
  Result := Result + RenderInlineBody(S, BaseExtra, True);
  EmitSGR(Result, '0');
end;

{ --------------------------------------------------------------- blocks }

function RenderMarkdownCore(const Text: string; Colored: Boolean): string;
var
  Lines, TList: TStringList;
  I, P, Q, Level, Skip: Integer;
  L, T, Rest, Marker: string;
  InCodeBlock: Boolean;

  procedure AddLine(const S: string);
  begin
    if Result <> '' then
      Result := Result + sLineBreak;
    Result := Result + S;
  end;

begin
  Result := '';
  Lines := SplitLines(Text);
  try
    InCodeBlock := False;
    Skip := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      if Skip > 0 then
      begin
        Dec(Skip);
        Continue;
      end;
      L := Lines[I];
      T := Trim(L);
      { Ограждённый блок кода: ``` или ~~~. }
      if (Pos('```', T) = 1) or (Pos('~~~', T) = 1) then
      begin
        InCodeBlock := not InCodeBlock;
        Continue;
      end;
      if InCodeBlock then
      begin
        AddLine(RenderStyled(L, C_MD_CODEBLK, Colored));
        Continue;
      end;
      { Заголовок: 1–6 «#» в начале строки. }
      P := 1;
      Level := 0;
      while (P <= Length(L)) and (L[P] = '#') do
      begin
        Inc(Level);
        Inc(P);
      end;
      if (Level > 0) and (Level <= 6) and
         ((P > Length(L)) or (L[P] = ' ')) then
      begin
        Rest := Trim(Copy(L, P + 1, MaxInt));
        AddLine(RenderStyled(Rest, C_MD_HEADING, Colored));
        Continue;
      end;
      { Горизонтальная линия. }
      if IsHRule(T) then
      begin
        AddLine(RenderStyled(T, C_MD_HRULE, Colored));
        Continue;
      end;
      { Цитата: одна или несколько «>» в начале строки. }
      P := 1;
      while (P <= Length(L)) and (L[P] = '>') do
        Inc(P);
      if P > 1 then
      begin
        Rest := Copy(L, P, MaxInt);
        if (Length(Rest) > 0) and (Rest[1] = ' ') then
          Delete(Rest, 1, 1);
        AddLine(RenderStyled(Rest, C_MD_QUOTE, Colored));
        Continue;
      end;
      { Таблица: последовательность строк, начинающихся с «|», где вторая
        строка — разделитель (заголовок + «|---|»). Без разделителя это
        обычный текст: иначе одиночная строка с «|» рисовалась бы целой
        таблицей (в потоке — каждое новое поступление отдельным блоком). }
      if IsTableLine(L) and (I + 1 < Lines.Count) and
         IsTableSeparator(Lines[I + 1]) then
      begin
        Q := I;
        while (Q < Lines.Count) and IsTableLine(Lines[Q]) do
          Inc(Q);
        TList := TStringList.Create;
        try
          for P := I to Q - 1 do
            TList.Add(Lines[P]);
          AddLine(RenderTable(TList, Colored));
        finally
          TList.Free;
        end;
        Skip := Q - I - 1;
        Continue;
      end;
      { Элемент списка: «- », «* », «+ » или «N. ». }
      P := 1;
      while (P <= Length(L)) and (L[P] = ' ') do
        Inc(P);
      if P <= Length(L) then
      begin
        Marker := '';
        if ((L[P] = '-') or (L[P] = '+') or
            ((L[P] = '*') and (P < Length(L)) and (L[P + 1] = ' '))) and
           (P < Length(L)) and (L[P + 1] = ' ') then
          Marker := L[P]
        else if (L[P] >= '0') and (L[P] <= '9') then
        begin
          Q := P;
          while (Q <= Length(L)) and (L[Q] >= '0') and (L[Q] <= '9') do
            Inc(Q);
          if (Q < Length(L)) and ((L[Q] = '.') or (L[Q] = ')')) and
             ((Q + 1 > Length(L)) or (L[Q + 1] = ' ')) then
            Marker := Copy(L, P, Q - P + 1);
        end;
        if Marker <> '' then
        begin
          Rest := TrimLeft(Copy(L, P + Length(Marker), MaxInt));
          if Rest = '' then
            AddLine(RenderStyled(Marker, C_MD_BULLET, Colored))
          else
            AddLine(RenderStyled(Marker, C_MD_BULLET, Colored) + ' ' +
                    RenderStyled(Rest, '', Colored));
          Continue;
        end;
      end;
      { Обычная строка. }
      AddLine(RenderStyled(L, '', Colored));
    end;
  finally
    Lines.Free;
  end;
end;

{ --------------------------------------------------------------- interface }

function RenderMarkdown(const Text: string; FD: Integer = 1): string;
begin
  if not ColorsEnabled(FD) then
    Exit(Text);
  Result := RenderMarkdownCore(Text, True);
end;

function StripMarkdown(const Text: string): string;
begin
  Result := RenderMarkdownCore(Text, False);
end;

end.
