unit mirmid.markdown;
{ Markdown parsing for terminal output: a coloured render of the main answer
  (ANSI codes) and plain text without markup (for the reasoning). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

{ Render core: with Colored=True it is a string with ANSI codes, otherwise
  plain text without markup. Independent of TTY/NO_COLOR (the caller decides). }
function RenderMarkdownCore(const Text: string; Colored: Boolean): string;

{ Renders markdown text into a string with ANSI codes for the terminal.
  Outside a terminal (or with NO_COLOR set) it returns the source text as is. }
function RenderMarkdown(const Text: string; FD: Integer = 1): string;

{ Strips the markdown markup, leaving readable plain text. }
function StripMarkdown(const Text: string): string;

{ Splits the text into lines (LF, CR and CRLF). }
function SplitLines(const Text: string): TStringList;

{ True if the line looks like a table line: after the trim it starts with "|"
  and contains at least one more "|". }
function IsTableLine(const S: string): Boolean;

{ True if the line may turn out to be the start of a table: after the trim it
  starts with "|". Lets a partial table line stay hidden row by row. }
function IsTableStart(const S: string): Boolean;

{ True if the line is a table separator line: the cells consist only of "-",
  ":" and spaces, and there is at least one "-". }
function IsTableSeparator(const S: string): Boolean;

{ True if a break after Prefix does not tear the inline markup: not inside
  `code`, **bold**, *italic*, ~~strikethrough~~ and not inside [a link]. It is
  a filter for the wrap points: a wrap inside markup would show "**" as text. }
function MarkdownBreakSafe(const Prefix: string): Boolean;

{ Renders a table: aligns the columns by the maximum visible width of the
  cells (missing cells are padded with empty ones). The separator lines are
  drawn with dashes of the column width. }
function RenderTable(const Lines: TStringList; Colored: Boolean): string;

implementation

uses
  mirmid.util;

{ Forward: RenderTable (below) uses RenderStyled, which is defined later. }
function RenderStyled(const S: string; const BaseExtra: string;
  Colored: Boolean): string; forward;

const
  { SGR palette for the main output (different colours, one per element). }
  C_MD_HEADING = '1;96';      { bold bright cyan — headings #..###### }
  C_MD_CODE    = '38;5;209';  { orange — `inline code` }
  C_MD_CODEBLK = '38;5;245';  { grey — fenced blocks ```...``` }
  C_MD_LINK    = '4;36';      { underlined cyan — [text](url) }
  C_MD_QUOTE   = '2;93';      { dimmed yellow — quotes > }
  C_MD_BULLET  = '38;5;46';   { green — list markers - * + N. }
  C_MD_HRULE   = '90';        { grey — horizontal rule --- }

{ --------------------------------------------------------------- helpers }

function IsSpaceChar(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

{ Joins the non-empty SGR parts with ';'. }
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

{ Current SGR code from the active attributes and the base context of the line. }
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
  { The colour is dimmed by the platform brightness (COLOR_BRIGHTNESS). }
  Out := Out + #27 + '[' + DimSGR(Code) + 'm';
end;

{ Splits the text into lines (LF, CR and CRLF). }
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

{ Position of the character C in S starting from From (0 — not found). }
function FindChar(C: Char; const S: string; From: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := From to Length(S) do
    if S[I] = C then
      Exit(I);
end;

{ True if S is a horizontal rule: three or more identical -, * or _. }
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

{ Splits a table row into cells: strips the outer "|", trims the spaces.
  "\|" is treated as a literal pipe inside a cell. }
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

  { Builds a border line: Left + ─*(w+2) + Mid + ─*(w+2) + ... + Right.
    With Colored=True it is wrapped in the SGR code C_MD_HRULE. }
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
  { Column width — the maximum visible width of a cell without markup
    (the separator lines are not taken into account). }
  for I := 0 to N - 1 do
    if not IsTableSeparator(Lines[I]) then
      for J := 0 to Rows[I].Count - 1 do
      begin
        W := VisibleLen(StripMarkdown(Rows[I][J]));
        if W > Widths[J] then
          Widths[J] := W;
      end;

  { Top border: ┌───┬───┐ }
  R := '';
  BuildBorder('┌', '┬', '┐');
  Result := R;

  for I := 0 to N - 1 do
  begin
    Sep := IsTableSeparator(Lines[I]);
    R := '';
    if Sep then
    begin
      { Separator: ├───┼───┤ }
      BuildBorder('├', '┼', '┤');
    end
    else
    begin
      { Data row: │ cell │ cell │; the vertical bars are grey }
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

  { Bottom border: └───┴───┘ }
  R := '';
  BuildBorder('└', '┴', '┘');
  Result := Result + sLineBreak + R;

  for I := 0 to N - 1 do
    Rows[I].Free;
end;

{ --------------------------------------------------------------- inline }

{ Scans the string character by character, stripping the inline markup. With
  Colored=True it emits SGR codes when the attributes change. BaseExtra is the
  base context of the line (the heading colour etc.). It does not emit the
  initial/final code — RenderStyled does that. }
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

  { A marker of length M at position P can be an opening one. }
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

  { A marker at position P can be a closing one. }
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
      { Inside an inline code span the markup is not parsed. }
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
      { **bold** }
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
      { *italic* }
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
      { _italic_ }
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
      { ~~strikethrough~~ }
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
      { `inline code` }
      InCode := True;
      Extra := JoinSGR([BaseExtra, C_MD_CODE]);
      Emit(Bold, Italic, Strike, Extra);
      Inc(I);
    end
    else if S[I] = '[' then
    begin
      { [text](url) — a link: underlined text, the URL is not printed. }
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

{ Renders a line in the BaseExtra base context: the initial code, the content,
  the reset. An empty string — no codes. }
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
      { Fenced code block: ``` or ~~~. }
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
      { Heading: 1-6 "#" at the start of the line. }
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
      { Horizontal rule. }
      if IsHRule(T) then
      begin
        AddLine(RenderStyled(T, C_MD_HRULE, Colored));
        Continue;
      end;
      { Quote: one or more ">" at the start of the line. }
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
      { Table: a sequence of lines starting with "|", where the second line is
        the separator (header + "|---|"). Without a separator this is ordinary
        text: otherwise a single line with "|" would be rendered as a whole
        table (in a stream — every new arrival as a separate block). }
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
      { List item: "- ", "* ", "+ " or "N. ". }
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
      { An ordinary line. }
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
