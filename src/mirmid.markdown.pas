unit mirmid.markdown;
{ Markdown parsing for terminal output: a coloured render of the main answer
  (ANSI codes) and plain text without markup (for the reasoning). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

{ Render core: with Colored=True it is a string with ANSI codes, otherwise
  plain text without markup. Independent of TTY/NO_COLOR (the caller decides).
  MaxWidth > 0 squeezes tables to that visible width: the column widths are
  redistributed and the cells are wrapped by words. Other lines are not
  wrapped. 0 means no limit. }
function RenderMarkdownCore(const Text: string; Colored: Boolean;
  MaxWidth: Integer = 0): string;

{ Renders markdown text into a string with ANSI codes for the terminal.
  Outside a terminal (or with NO_COLOR set) it returns the source text as is.
  MaxWidth > 0 squeezes tables to that visible width, as in RenderMarkdownCore;
  0 means no limit. }
function RenderMarkdown(const Text: string; FD: Integer = 1;
  MaxWidth: Integer = 0): string;

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
  drawn with dashes of the column width. MaxWidth > 0 squeezes the column
  widths and wraps the cells by words; a cell that cannot be broken (a word or
  an inline span wider than its column) widens its column instead of being
  cut, so the table may still end up wider than MaxWidth. 0 keeps the natural
  column width. }
function RenderTable(const Lines: TStringList; Colored: Boolean;
  MaxWidth: Integer = 0): string;

const
  { Longest word a table column is widened for when wrapping a table: a longer
    word is broken instead of stretching the column (and the terminal) to it. }
  TABLE_MAX_WORD = 20;

{ Wraps a table cell to the visible width Width: breaks at spaces and tabs, and
  a word that is both wider than the column and longer than TABLE_MAX_WORD is
  broken forcibly (a break inside inline markup is refused: overflow is better
  than shown markup). ForceBreak also breaks words up to TABLE_MAX_WORD that do
  not fit, for a table that cannot fit its limit even at the word minimums.
  Returns the lines of the cell; a Width <= 0 or an empty Text gives a single
  line. }
function WrapTableCell(const Text: string; Width: Integer;
  ForceBreak: Boolean = False): TStringList;

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

  { The marker at P with length M can open a span: it starts a word (the
    previous character is a space or another marker) and is followed by a
    non-space character. The same rule as in RenderInlineBody, so a `*` or `_`
    inside a word (snake_case, 2*3) stays literal and does not affect the
    result. }
  function CanOpen(P, M: Integer): Boolean;
  begin
    if P > 1 then
      Result := IsSpaceChar(Prefix[P - 1]) or
                (Prefix[P - 1] = '*') or (Prefix[P - 1] = '_')
    else
      Result := True;
    if not Result then
      Exit(False);
    if P + M > N then
      Exit(False);
    Result := not IsSpaceChar(Prefix[P + M]);
  end;

  { A marker can close a span only when it follows a non-space character. }
  function CanClose(P: Integer): Boolean;
  begin
    Result := (P > 1) and not IsSpaceChar(Prefix[P - 1]);
  end;

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
    if Prefix[I] = #27 then
    begin
      { An ANSI sequence takes no columns and is not markup: skip it, the same
        rule as in VisibleLen and TruncateVisible, so the '[' of an SGR code is
        not taken for a link bracket. }
      Inc(I);
      if (I <= N) and ((Ord(Prefix[I]) in [$3C..$3F]) or
                       (Ord(Prefix[I]) in [$5B..$5F])) then
        Inc(I);
      while (I <= N) and (Ord(Prefix[I]) in [$20..$3F]) do
        Inc(I);
      if I <= N then
        Inc(I);
      Continue;
    end;
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
      if not Bold and CanOpen(I, 2) then
        Bold := True
      else if Bold and CanClose(I) then
        Bold := False;
      Inc(I, 2);
      Continue;
    end;
    if (I < N) and (Prefix[I] = '~') and (Prefix[I + 1] = '~') then
    begin
      if not Strike and CanOpen(I, 2) then
        Strike := True
      else if Strike and CanClose(I) then
        Strike := False;
      Inc(I, 2);
      Continue;
    end;
    if Prefix[I] = '*' then
    begin
      if not Italic and CanOpen(I, 1) then
        Italic := True
      else if Italic and CanClose(I) then
        Italic := False;
      Inc(I);
      Continue;
    end;
    if Prefix[I] = '_' then
    begin
      if not Italic and CanOpen(I, 1) then
        Italic := True
      else if Italic and CanClose(I) then
        Italic := False;
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

{ Force-breaks a word that does not fit into Limit visible columns. The word is
  cut by TruncateVisible, which never splits a UTF-8 character. A cut inside
  the inline markup (or between the two characters of a doubled marker) is
  tried with a smaller width first: showing "**" as text is worse than overflow,
  so such a word is returned whole. A single character wider than Limit (a CJK
  ideograph at Limit = 1) is put on its own line instead of giving up on the
  whole word. Limit < 1 is treated as 1. }
function BreakTableWord(const Word: string; Limit: Integer): TStringList;
var
  Rest, Chunk: string;
  W, Kept: Integer;

  { The byte length of the first UTF-8 character of S (0 for an empty string). }
  function FirstCharLen(const S: string): Integer;
  var
    B: Byte;
  begin
    if S = '' then
      Exit(0);
    B := Ord(S[1]);
    if B < $80 then
      Result := 1
    else if (B and $E0) = $C0 then
      Result := 2
    else if (B and $F0) = $E0 then
      Result := 3
    else if (B and $F8) = $F0 then
      Result := 4
    else
      Result := 1;
    if Result > Length(S) then
      Result := Length(S);
  end;

  { True when the cut after Consumed bytes of Src falls between the two
    characters of a doubled marker (two stars, underscores, tildes or
    backticks): both pieces would then show the marker as text. }
  function SplitsMarker(Consumed: Integer; const Src: string): Boolean;
  begin
    Result := (Consumed > 0) and (Consumed < Length(Src)) and
              (Src[Consumed] in ['*', '_', '~', '`']) and
              (Src[Consumed + 1] = Src[Consumed]);
  end;

begin
  Result := TStringList.Create;
  if Limit < 1 then
    Limit := 1;
  Rest := Word;
  while VisibleLen(StripMarkdown(Rest)) > Limit do
  begin
    { The longest prefix not wider than Limit on which the markup is intact. }
    Chunk := '';
    Kept := 0;
    W := Limit;
    while W >= 1 do
    begin
      Chunk := TruncateVisible(Rest, W);
      { TruncateVisible closes a coloured piece with an SGR reset; the reset
        belongs to the piece and is not a byte of the source prefix. }
      Kept := Length(Chunk);
      if (Kept >= 4) and (Copy(Chunk, Kept - 3, 4) = #27 + '[0m') then
        Dec(Kept, 4);
      if (Kept > 0) and MarkdownBreakSafe(Chunk) and
         not SplitsMarker(Kept, Rest) then
        Break;
      Chunk := '';
      Kept := 0;
      Dec(W);
    end;
    if Chunk = '' then
    begin
      { Nothing fits: the first character alone is wider than the limit. Take
        one whole character so the column does not grow to the full word; only
        when that would split markup does the word stay whole. }
      Kept := FirstCharLen(Rest);
      Chunk := Copy(Rest, 1, Kept);
      if not MarkdownBreakSafe(Chunk) or SplitsMarker(Kept, Rest) then
      begin
        Result.Add(Rest);
        Exit;
      end;
    end;
    Result.Add(Chunk);
    Rest := Copy(Rest, Kept + 1, MaxInt);
  end;
  if Rest <> '' then
    Result.Add(Rest);
end;

function WrapTableCell(const Text: string; Width: Integer;
  ForceBreak: Boolean): TStringList;
var
  P, Start: Integer;
  Word, Line, Cand: string;

  { Puts a word into the current line or starts a new one; Line is owned by
    the caller. Glue joins the word without a space (a continuation of a
    force-broken word). }
  procedure PutWord(const W: string; Glue: Boolean);
  begin
    if Line = '' then
      Cand := W
    else if Glue then
      Cand := Line + W
    else
      Cand := Line + ' ' + W;
    if (Line = '') or (VisibleLen(StripMarkdown(Cand)) <= Width) then
      { It fits (or it is the first word of the line: then it goes in anyway). }
      Line := Cand
    else if MarkdownBreakSafe(Line) then
    begin
      { Break on a word boundary: the markup in Line is closed, cutting here
        is safe. }
      Result.Add(Line);
      Line := W;
    end
    else
      { A break here would split **, `code` or [a link] — keep the line
        growing: overflow is better than shown markup. }
      Line := Cand;
  end;

  { A word that does not fit into Width is broken forcibly when it is longer
    than TABLE_MAX_WORD, or on request (ForceBreak, a table that cannot fit its
    limit even at the word minimums): the first piece goes in as a word, the
    rest continue the same word (glued without a space when they fit). }
  procedure PutMaybeBrokenWord(const W: string);
  var
    Pieces: TStringList;
    K, Limit: Integer;
  begin
    if (VisibleLen(StripMarkdown(W)) <= Width) or
       ((not ForceBreak) and
        (VisibleLen(StripMarkdown(W)) <= TABLE_MAX_WORD)) then
    begin
      PutWord(W, False);
      Exit;
    end;
    Limit := Width;
    if Limit > TABLE_MAX_WORD then
      Limit := TABLE_MAX_WORD;
    Pieces := BreakTableWord(W, Limit);
    try
      for K := 0 to Pieces.Count - 1 do
        PutWord(Pieces[K], K > 0);
    finally
      Pieces.Free;
    end;
  end;

begin
  Result := TStringList.Create;
  if Width < 1 then
    Width := 1;
  Line := '';
  P := 1;
  while P <= Length(Text) do
  begin
    { The next word: up to a space or a tab. }
    while (P <= Length(Text)) and ((Text[P] = ' ') or (Text[P] = #9)) do
      Inc(P);
    Start := P;
    while (P <= Length(Text)) and (Text[P] <> ' ') and (Text[P] <> #9) do
      Inc(P);
    if P <= Start then
      Break;
    Word := Copy(Text, Start, P - Start);
    PutMaybeBrokenWord(Word);
  end;
  Result.Add(Line);
end;


type
  { Per-column statistics of a table: they drive the width distribution when
    the table has to be wrapped. }
  TTableColStat = record
    Volume: Integer;   { sum of the visible cell widths without markup }
    MaxWord: Integer;  { longest word, capped at TABLE_MAX_WORD }
  end;
  TTableColStats = array of TTableColStat;
  { Column widths of a table: content only, no borders and side padding. }
  TTableColWidths = array of Integer;

{ ------------------------------------------------ table width distribution }
{ Collects per-column statistics: the total visible volume of the cell text
  (without markup) and the longest word. The word length is capped at
  TABLE_MAX_WORD, so a single huge token cannot claim the whole table width;
  longer words are force-broken later. Separator rows are skipped. }
function CollectTableStats(const Lines: TStringList;
  const Rows: array of TStringList): TTableColStats;
var
  I, J, NCols, W, P, Start: Integer;
  Plain, Word: string;
begin
  Result := nil;
  if Length(Rows) = 0 then
    Exit;
  NCols := 0;
  for I := 0 to High(Rows) do
    if Rows[I].Count > NCols then
      NCols := Rows[I].Count;
  SetLength(Result, NCols);
  for I := 0 to High(Rows) do
  begin
    if (I < Lines.Count) and IsTableSeparator(Lines[I]) then
      Continue;
    for J := 0 to Rows[I].Count - 1 do
    begin
      Plain := StripMarkdown(Rows[I][J]);
      Inc(Result[J].Volume, VisibleLen(Plain));
      { Words are separated by spaces and tabs; the length is counted in
        visible columns. }
      P := 1;
      while P <= Length(Plain) do
      begin
        while (P <= Length(Plain)) and ((Plain[P] = ' ') or (Plain[P] = #9)) do
          Inc(P);
        Start := P;
        while (P <= Length(Plain)) and (Plain[P] <> ' ') and (Plain[P] <> #9) do
          Inc(P);
        if P > Start then
        begin
          Word := Copy(Plain, Start, P - Start);
          W := VisibleLen(Word);
          if W > TABLE_MAX_WORD then
            W := TABLE_MAX_WORD;
          if W > Result[J].MaxWord then
            Result[J].MaxWord := W;
        end;
      end;
    end;
  end;
end;

{ Distributes the column widths when the table is wider than the terminal.
  Every column first gets the minimum that fits its longest word
  (CollectTableStats has already capped it at TABLE_MAX_WORD); the rest is
  shared in proportion to the visible volume of text in the column, but never
  above Natural (the width of the widest cell), because a column with short
  text gains nothing from extra space. When even the minimums do not fit, the
  budget is split by volume right away: the widths add up to the budget and
  the caller force-breaks the words that no longer fit, so the table stays
  inside the terminal.
  Budget is the width available for the content only, without borders and
  side padding; Natural may be shorter than Stats. }
function DistributeTableWidths(const Stats: TTableColStats;
  const Natural: TTableColWidths; Budget: Integer): TTableColWidths;
var
  I, N, OpenCount, Best, Room, Remaining: Integer;
  SumNat, SumMin, SumVol, Share, Given, W, BestVol: Int64;

  { Natural width of column J (0 when the array is too short). }
  function NatOf(J: Integer): Integer;
  begin
    if (J >= 0) and (J < Length(Natural)) and (Natural[J] > 0) then
      Result := Natural[J]
    else
      Result := 0;
  end;

  { Weight of column J — the volume of its text (0 for an empty column). }
  function VolOf(J: Integer): Int64;
  begin
    if (J >= 0) and (J < Length(Stats)) and (Stats[J].Volume > 0) then
      Result := Stats[J].Volume
    else
      Result := 0;
  end;

begin
  N := Length(Stats);
  Result := nil;
  SetLength(Result, N);
  if (N = 0) or (Budget <= 0) then
    Exit;
  { The natural width fits as a whole — nothing has to be squeezed. }
  SumNat := 0;
  for I := 0 to N - 1 do
  begin
    Result[I] := NatOf(I);
    Inc(SumNat, Result[I]);
  end;
  if SumNat <= Budget then
    Exit;
  { The minimum of a column is its longest word, but never more than the
    natural width. }
  SumMin := 0;
  for I := 0 to N - 1 do
  begin
    W := Stats[I].MaxWord;
    if W > NatOf(I) then
      W := NatOf(I);
    if W < 0 then
      W := 0;
    Inc(SumMin, W);
  end;
  if SumMin <= Budget then
  begin
    { The word minimums fit — start from them, so no word has to be broken. }
    Remaining := Budget;
    for I := 0 to N - 1 do
    begin
      W := Stats[I].MaxWord;
      if W > NatOf(I) then
        W := NatOf(I);
      if W < 0 then
        W := 0;
      Result[I] := W;
      Dec(Remaining, Integer(W));
    end;
  end
  else
  begin
    { Less space than the sum of the minimums: every non-empty column keeps one
      character (the widest share the budget can deny it) and the rest is split
      by volume; the caller force-breaks the words that no longer fit, so the
      widths still add up to the budget and the table stays inside the
      terminal. }
    Remaining := Budget;
    for I := 0 to N - 1 do
      if NatOf(I) > 0 then
      begin
        Result[I] := 1;
        Dec(Remaining);
      end
      else
        Result[I] := 0;
    if Remaining < 0 then
      Remaining := 0;
  end;
  { The rest goes in proportion to the volume, capped by the natural width. }
  while Remaining > 0 do
  begin
    SumVol := 0;
    OpenCount := 0;
    for I := 0 to N - 1 do
      if Result[I] < NatOf(I) then
      begin
        Inc(SumVol, VolOf(I));
        Inc(OpenCount);
      end;
    if (OpenCount = 0) or (SumVol <= 0) then
      Break;
    Given := 0;
    for I := 0 to N - 1 do
    begin
      if Result[I] >= NatOf(I) then
        Continue;
      Share := (Int64(Remaining) * VolOf(I)) div SumVol;
      Room := NatOf(I) - Result[I];
      if Share > Room then
        Share := Room;
      if Share > 0 then
      begin
        Inc(Result[I], Integer(Share));
        Inc(Given, Share);
      end;
    end;
    if Given = 0 then
      Break;
    Dec(Remaining, Integer(Given));
  end;
  { Columns left short by the rounding down get the remaining units, the one
    with the largest volume first. }
  while Remaining > 0 do
  begin
    Best := -1;
    BestVol := 0;
    for I := 0 to N - 1 do
      if Result[I] < NatOf(I) then
      begin
        W := VolOf(I);
        if (Best < 0) or (W > BestVol) then
        begin
          Best := I;
          BestVol := W;
        end;
      end;
    if Best < 0 then
      Break;
    Inc(Result[Best]);
    Dec(Remaining);
  end;
end;


function RenderTable(const Lines: TStringList; Colored: Boolean;
  MaxWidth: Integer): string;
var
  I, J, K, N, W, RowH, Q: Integer;
  Rows: array of TStringList;
  CellLines: array of TStringList;
  Pieces: TStringList;
  Widths, Natural: TTableColWidths;
  Stats: TTableColStats;
  R, Cell, B: string;
  Sep: Boolean;
  NCols, Budget, NatSum, SumMin: Integer;
  Squeezed: Boolean;

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
  Squeezed := False;
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
  { Natural column width — the maximum visible width of a cell without markup
    (the separator lines are not taken into account). }
  for I := 0 to N - 1 do
    if not IsTableSeparator(Lines[I]) then
      for J := 0 to Rows[I].Count - 1 do
      begin
        W := VisibleLen(StripMarkdown(Rows[I][J]));
        if W > Widths[J] then
          Widths[J] := W;
      end;

  { Compression under MaxWidth: when the table is wider than the limit, the
    natural widths are redistributed by the volume of the cell text (with the
    longest word as the minimum), and the cells are wrapped by words; when even
    the minimums exceed the budget, the words that no longer fit their column
    are force-broken. A column takes Widths[J] + 2 characters (one space of
    padding on either side) plus one vertical bar, so MaxWidth leaves
    MaxWidth - 3*NCols - 1 for content; the budget is kept at one character per
    column so that the borders still line up. Without MaxWidth, or when the
    natural sum already fits, nothing is squeezed: one line per record, borders
    exactly around the content. }
  Natural := Copy(Widths, 0, NCols);
  if (MaxWidth > 0) and (NCols > 0) then
  begin
    Budget := MaxWidth - 3 * NCols - 1;
    if Budget < NCols then
      Budget := NCols;
    NatSum := 0;
    for J := 0 to NCols - 1 do
      Inc(NatSum, Natural[J]);
    if NatSum > Budget then
    begin
      Stats := CollectTableStats(Lines, Rows);
      Widths := DistributeTableWidths(Stats, Natural, Budget);
      if Length(Widths) < NCols then
        SetLength(Widths, NCols);
      for J := 0 to NCols - 1 do
        if (Widths[J] < 1) and (Natural[J] > 0) then
          Widths[J] := 1;
      { When even the word minimums do not fit the budget, the widths come
        from the volume split and are narrower than some words: those words
        are force-broken, otherwise they would stretch the column and the
        table past MaxWidth. }
      SumMin := 0;
      for J := 0 to NCols - 1 do
      begin
        W := Stats[J].MaxWord;
        if W > Natural[J] then
          W := Natural[J];
        if W < 0 then
          W := 0;
        Inc(SumMin, W);
      end;
      Squeezed := SumMin > Budget;
    end;
  end;
  { A cell can still be wider than its squeezed column: an inline span (a long
    **bold** or `code` run) that cannot be broken without showing the markup,
    or a word whose break would do the same. Cutting it would tear the markup,
    and cutting the finished line would swallow the right border and the
    columns after it. Such a column is widened to its widest physical line
    instead: no text is lost and the borders stay aligned, but the table may
    end up wider than MaxWidth (the caller decides what to do with it). The
    pass runs twice, so the widths are stable after the columns have grown. }
  if MaxWidth > 0 then
    for Q := 1 to 2 do
      for I := 0 to N - 1 do
        if not IsTableSeparator(Lines[I]) then
          for J := 0 to NCols - 1 do
          begin
            if J < Rows[I].Count then
              Cell := Rows[I][J]
            else
              Cell := '';
            if VisibleLen(StripMarkdown(Cell)) <= Widths[J] then
              Continue;
            Pieces := WrapTableCell(Cell, Widths[J], Squeezed);
            try
              for K := 0 to Pieces.Count - 1 do
              begin
                W := VisibleLen(StripMarkdown(Pieces[K]));
                if W > Widths[J] then
                  Widths[J] := W;
              end;
            finally
              Pieces.Free;
            end;
          end;

  { Top border: ┌───┬───┐ }
  R := '';
  BuildBorder('┌', '┬', '┐');
  Result := R;

  SetLength(CellLines, NCols);
  for I := 0 to N - 1 do
  begin
    Sep := IsTableSeparator(Lines[I]);
    if Sep then
    begin
      { Separator: ├───┼───┤ }
      R := '';
      BuildBorder('├', '┼', '┤');
      Result := Result + sLineBreak + R;
      Continue;
    end;

    { Data row: every cell is split into physical lines, the height of the row
      follows its tallest cell, and the shorter cells are padded with empty
      lines at the bottom (vertical alignment to the top). A cell that fits its
      column is kept on one line, so tabs and repeated spaces survive. }
    RowH := 1;
    for J := 0 to NCols - 1 do
    begin
      if J < Rows[I].Count then
        Cell := Rows[I][J]
      else
        Cell := '';
      if VisibleLen(StripMarkdown(Cell)) > Widths[J] then
        CellLines[J] := WrapTableCell(Cell, Widths[J], Squeezed)
      else
      begin
        CellLines[J] := TStringList.Create;
        CellLines[J].Add(Cell);
      end;
      if CellLines[J].Count > RowH then
        RowH := CellLines[J].Count;
    end;

    for K := 0 to RowH - 1 do
    begin
      { Physical line: │ cell │ cell │; the vertical bars are grey }
      R := '';
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
        if K < CellLines[J].Count then
          Cell := CellLines[J][K]
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
      Result := Result + sLineBreak + R;
    end;

    for J := 0 to NCols - 1 do
      CellLines[J].Free;
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

function RenderMarkdownCore(const Text: string; Colored: Boolean;
  MaxWidth: Integer): string;
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
          AddLine(RenderTable(TList, Colored, MaxWidth));
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

function RenderMarkdown(const Text: string; FD: Integer;
  MaxWidth: Integer): string;
begin
  if not ColorsEnabled(FD) then
    Exit(Text);
  Result := RenderMarkdownCore(Text, True, MaxWidth);
end;

function StripMarkdown(const Text: string): string;
begin
  Result := RenderMarkdownCore(Text, False);
end;

end.
