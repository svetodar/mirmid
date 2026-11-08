unit mirmid.util;
{ Прикладные утилиты: пути, файлы, запуск процессов, время. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

{ Каталог для временных файлов (с концевым слэшем). }
function TempDir: string;
{ Домашний каталог (с концевым слэшем). }
function HomeDir: string;
{ Раскрывает «~» и делает путь абсолютным относительно Base. }
function ExpPath(const Path, Base: string): string;
{ Каталог, в котором лежит исполняемый файл (с концевым слэшем). }
function AppDir: string;

{ --- Числа --- }
{ Настройки формата с десятичной точкой (независимо от локали системы). }
function DotFormatSettings: TFormatSettings;
{ Разбор числа с десятичной точкой: "0.7" и "0,7" дают 0.7 при любой локали.
  Пустая строка или мусор — Def. }
function DotToFloat(const S: string; Def: Double): Double;
{ Форматирование числа с десятичной точкой ("0.7") при любой локали. }
function FloatToDotStr(const Value: Double): string;

{ Каталог конфигурации и сессий проекта: <WorkDir>/.mirmid (без концевого слэша). }
function MirmidDir(const WorkDir: string): string;
{ True, если Path указывает на <WorkDir>/.mirmid или внутрь него. }
function IsMirmidPath(const WorkDir, Path: string): Boolean;

{ Побайтовое чтение/запись текстовых файлов в UTF-8. }
function ReadTextFile(const Path: string; out Text: string; out Err: string): Boolean;
function WriteTextFile(const Path, Text: string; out Err: string): Boolean;
{ Дописывает Text в конец файла (создаёт каталог и сам файл при отсутствии). }
function AppendTextFile(const Path, Text: string; out Err: string): Boolean;
{ Создаёт родительские каталоги для файла. True, если каталог существует. }
function EnsureParentDir(const Path: string): Boolean;

{ Список файлов и подкаталогов. Каталоги помечаются концевым «/».
  При Recursive=True обходит подкаталоги. Список сортируется. }
function ListDir(const Dir: string; Recursive: Boolean;
  out Lines: TStringList; out Err: string): Boolean;

{ Запускает команду оболочки в каталоге WorkDir: на Unix — /bin/bash -lc,
  на Windows — %COMSPEC% /c. Результат возвращает в Output (stdout+stderr).
  Возвращает True, если процесс завершился сам (в т.ч. с ненулевым кодом).
  False — при ошибке запуска/таймауте.
  MaxOutput > 0 — предел накапливаемого вывода в байтах (0 — без предела);
  обрезка выполняется по границе символа UTF-8 (TruncateUTF8) после
  завершения процесса и не меняет Result/ExitCode,
  TotalBytes — сколько байт реально прочитано из процесса. }
function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string): Boolean; overload;
function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string;
  MaxOutput: Integer; out TotalBytes: Int64): Boolean; overload;

{ Заполняет список переменных окружения текущего процесса (строки «KEY=VALUE»). }
procedure EnvironmentToList(L: TStrings);

{ Монотонные миллисекунды (для таймаутов). }
function TicksMs: QWord;
{ --- Окружение (для системного промпта) --- }
{ Имя ОС: Windows — по GetVersionEx и номеру сборки из реестра
  (22000+ — Windows 11); Unix — PRETTY_NAME из /etc/os-release. }
function OsName: string;
{ Архитектура ЦП (x86_64, arm64, x86, ...). }
function OsArch: string;
{ Текущие дата и время в локаленезависимом формате yyyy-mm-dd hh:nn:ss. }
function NowStamp: string;
{ Строка сведений об окружении для системного промпта: ОС, дата, время. }
function EnvironmentInfo: string;
{ Содержимое AGENTS.md из рабочей папки (пустая строка, если файла нет). }
function ReadAgentsMd(const WorkDir: string): string;
{ --- GUI (координаты) --- }
{ Объявляет процесс DPI-осведомлённым (Windows): без этого система отдаёт
  координаты и размеры в виртуализованном (масштабированном) виде. На Unix —
  нет-оп (DPI-виртуализации нет). Вызов идемпотентен. }
procedure EnsureDpiAware;

{ --- Экран и ANSI-цвета --- }
{ Яркость терминальных цветов (0..1): палитра консоли Windows ярче, чем у
  Unix-терминалов, поэтому на Windows цвета приглушаются; на Linux — полная
  яркость. }
const
  {$IFDEF WINDOWS}
  COLOR_BRIGHTNESS = 0.6;
  {$ELSE}
  COLOR_BRIGHTNESS = 1.0;
  {$ENDIF}
{ True, если файловый дескриптор подключён к терминалу. }
function IsTerminal(FD: Integer): Boolean;
{ True, если в поток FD можно подмешивать ANSI-последовательности: дескриптор
  подключён к терминалу и терминал их обрабатывает. На Windows при первом
  обращении включается режим ENABLE_VIRTUAL_TERMINAL_PROCESSING (в conhost он
  бывает выключен, и тогда ESC-коды печатаются как обычный текст); если
  включить не удалось — False. Для дескрипторов вне 0..2 — False. }
function AnsiEnabled(FD: Integer = 1): Boolean;
{ Явная инициализация ANSI-вывода (без неё включение сделается лениво при
  первом обращении к AnsiEnabled/Colored). True — ANSI-коды допустимы. }
function InitConsoleAnsi: Boolean;
{ True, если цвета разрешены (не задан NO_COLOR) и в поток можно писать ANSI. }
function ColorsEnabled(FD: Integer): Boolean;
{ Оборачивает Text в ANSI-последовательность цвета Color со сбросом.
  Вне терминала (или при пустом Color) возвращает Text без кодов. }
function Colored(const Color, Text: string; FD: Integer = 1): string;
{ SGR-код с приглушённой яркостью: цветовые части (30..37, 90..97, 38;5;N,
  38;2;R;G;B и фоновые 48;...) пересчитываются в 24-битный цвет с умножением
  компонентов на Brightness; прочие атрибуты (жирный, курсив, подчёркивание,
  сброс) сохраняются. При Brightness >= 1 код возвращается без изменений. }
function DimSGR(const SGR: string; Brightness: Double = COLOR_BRIGHTNESS): string;

{ Ширина терминала в колонках для FD (ioctl TIOCGWINSZ; запас — переменная
  окружения COLUMNS, затем 80). }
function TermWidth(FD: Integer = 1): Integer;
{ Видимая длина строки в колонках: без ANSI-последовательностей. Широкие
  символы (CJK, эмодзи, полные формы) считаются за 2 колонки, нулевые
  (связки, вариативные селекторы, диакритика) — за 0. }
function VisibleLen(const S: string): Integer;

{ --- UTF-8 --- }
{ Обрезает S до MaxBytes байт, не разрывая многобайтовый символ UTF-8:
  возвращает самый длинный префикс из целых символов не длиннее MaxBytes.
  Без этой защиты Copy(S, 1, N) может разрезать символ и породить
  некорректную UTF-8-строку (HTTP 400 при отправке в API). }
function TruncateUTF8(const S: string; MaxBytes: Integer): string;
{ True, если S — корректная UTF-8-строка (без «битых» байтов). }
function IsValidUTF8(const S: string): Boolean;
{ Заменяет некорректные UTF-8-последовательности на U+FFFD, чтобы строка
  была пригодна для JSON/HTTP. }
function SanitizeUTF8(const S: string): string;

{ --- Сокращение многострочного текста --- }
{ Отступ маркера «…» от начала строки (в пробелах): маркер отделяет части
  вывода инструмента, а не выглядит его первой строкой (task1.md) — для
  отступа 8 троеточие печатается с 9-й позиции. }
const
  SHORTEN_ELLIPSIS_INDENT = 8;
{ Сокращает S до MaxLines строк за счёт середины: остаются первые
  (MaxLines - 1) div 2 строк, маркер «…» (с отступом SHORTEN_ELLIPSIS_INDENT)
  и остаток строк снизу (при чётном лимите снизу на одну строку больше).
  Для MaxLines = 9 это 4 + «…» + 4.
  MaxLines = 1 — только «…»; MaxLines = 2 — «…» + последняя строка.
  MaxLines <= 0 (0 и отрицательные — «без лимита») — S возвращается как есть;
  S короче лимита — тоже как есть. Переводы строк сохраняются
  (CRLF/LF исходного текста), завершающий перевод не добавляется. }
function ShortenLinesMiddle(const S: string; MaxLines: Integer): string;
{ Убирает пустые строки в начале и в конце текста (task1.md: вывод
  инструмента перед обрезкой по лимиту строк должен начинаться и заканчиваться
  содержимым, иначе лимит тратится на пустые строки, а на экране остаются
  лишние пустые строки). Пустой считается строка из одних пробелов/табуляций;
  внутренние пустые строки сохраняются. Стиль перевода строк исходного текста
  (CRLF/LF) сохраняется, завершающий перевод не добавляется: текст из одних
  пустых строк даёт '' (печатать нечего). }
function TrimBlankLines(const S: string): string;

{ --- Перенос длинных строк --- }
{ Функция измерения видимой ширины строки (например, VisibleLen для чистого
  текста или VisibleLen(RenderMarkdown(...)) для размеченного). }
type
  TTextMeasure = function(const S: string): Integer of object;
  { Разрешён ли разрыв перед пробелом (Prefix — текст до пробела). nil —
    разрешён любой пробел. }
  TBreakAllowed = function(const Prefix: string): Boolean of object;

{ Переносит строку S по словам так, чтобы каждый фрагмент был уже Width
  колонок по Measure. Разрыв делается по пробелу, сам пробел отбрасывается;
  знаки препинания остаются при предыдущем слове. Слово длиннее строки
  разрывается принудительно. Ведущие пробелы строки (отступ) сохраняются
  в первом фрагменте. BreakAllowed (необязательно) отсеивает разрывы внутри
  разметки (например, внутри **жирного**). Возвращает список фрагментов
  (минимум один). }
function WrapText(const S: string; Width: Integer; Measure: TTextMeasure;
  BreakAllowed: TBreakAllowed = nil): TStringList;

{ --- Diff --- }
{ Генерирует unified diff между двумя списками строк.
  OldLines — исходные строки, NewLines — новые строки.
  OldName/NewName — имена для заголовка (например, "a/file" и "b/file").
  OldStartLine — 1-базированный номер первой строки OldLines в файле
    (по умолчанию 1).
  Context — количество контекстных строк вокруг изменений (по умолчанию 3).
  Возвращает строку с unified diff; пустая строка, если списки идентичны. }
function MakeUnifiedDiff(const OldLines, NewLines: TStringList;
  const OldName, NewName: string; OldStartLine: Integer = 1;
  Context: Integer = 3): string;

implementation

uses
  Process, DateUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  {$IFDEF UNIX}, baseunix{$ENDIF};

{$IFDEF WINDOWS}
var
  UGuiDpiAware: Boolean = False;

type
  TUtilSetProcessDPIAware = function: BOOL; stdcall;
{$ENDIF}

procedure EnsureDpiAware;
{$IFDEF WINDOWS}
var
  H: HMODULE;
  F: TUtilSetProcessDPIAware;
begin
  if UGuiDpiAware then
    Exit;
  UGuiDpiAware := True;
  H := GetModuleHandle('user32.dll');
  if H = 0 then
    Exit;
  Pointer(F) := GetProcAddress(H, 'SetProcessDPIAware');
  if Assigned(F) then
    try
      F();
    except
      { нет функции или вызов запрещён — работаем как есть }
    end;
end;
{$ELSE}
begin
  { На Unix DPI-виртуализации нет — ничего делать не нужно. }
end;
{$ENDIF}

function TempDir: string;
begin
  { GetTempDir учитывает TMPDIR/TEMP/TMP и возвращает путь с концевым слэшем. }
  Result := GetTempDir;
end;

function HomeDir: string;
begin
  Result := GetUserDir;
end;

function AppDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0)));
end;

{ --- Числа --- }

function DotFormatSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function DotToFloat(const S: string; Def: Double): Double;
var
  T: string;
begin
  T := Trim(S);
  if T = '' then
    Exit(Def);
  { Принимаем и запятую: конфиг мог быть сохранён в локали с запятой. }
  T := StringReplace(T, ',', '.', [rfReplaceAll]);
  Result := StrToFloatDef(T, Def, DotFormatSettings);
end;

function FloatToDotStr(const Value: Double): string;
begin
  Result := FloatToStr(Value, DotFormatSettings);
end;

function MirmidDir(const WorkDir: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(ExpPath('.mirmid', WorkDir));
end;

function IsMirmidPath(const WorkDir, Path: string): Boolean;
var
  Base, Sub, P: string;
begin
  if Path = '' then
    Exit(False);
  Base := ExpPath(WorkDir, GetCurrentDir);
  if Base = '' then
    Base := GetCurrentDir;
  Base := IncludeTrailingPathDelimiter(Base);
  Sub := MirmidDir(Base);
  P := ExpPath(Path, Base);
  if P = '' then
    Exit(False);
  {$IFDEF WINDOWS}
  Result := SameText(P, Sub) or SameText(Copy(P, 1, Length(Sub) + 1), Sub + PathDelim);
  {$ELSE}
  Result := (P = Sub) or (Copy(P, 1, Length(Sub) + 1) = Sub + PathDelim);
  {$ENDIF}
end;

{ True, если путь абсолютный на текущей платформе. }
function PathIsAbsolute(const P: string): Boolean;
begin
  Result := False;
  if P = '' then
    Exit;
  {$IFDEF WINDOWS}
  if (Length(P) >= 2) and (P[2] = ':') then
    Exit(True);
  {$ENDIF}
  Result := (P[1] = PathDelim) or (P[1] = '/') or (P[1] = '\');
end;

function ExpPath(const Path, Base: string): string;
var
  P: string;
begin
  P := Trim(Path);
  if P = '' then
    Exit('');
  if (P = '~') or ((Length(P) >= 2) and (P[1] = '~') and (P[2] in ['/', '\'])) then
    P := HomeDir + Copy(P, 3, MaxInt);
  if not PathIsAbsolute(P) then
    P := IncludeTrailingPathDelimiter(Base) + P;
  Result := ExpandFileName(P);
end;

{ Собирает окружение текущего процесса в список «KEY=VALUE». }
procedure EnvironmentToList(L: TStrings);
{$IFDEF WINDOWS}
var
  P, Q: PWideChar;
  S: WideString;
begin
  { Берём Unicode-версию: DefaultSystemCodePage = UTF-8, поэтому строки
    окружения должны быть в UTF-8 (не в ANSI/OEM-кодировке). }
  P := GetEnvironmentStringsW;
  if P = nil then
    Exit;
  try
    Q := P;
    while Q^ <> #0 do
    begin
      S := Q;
      L.Add(UTF8Encode(S));
      Inc(Q, Length(S) + 1);
    end;
  finally
    FreeEnvironmentStringsW(P);
  end;
end;
{$ELSE}
var
  P: PPChar;
begin
  P := envp;
  while (P <> nil) and (P^ <> nil) do
  begin
    L.Add(StrPas(P^));
    Inc(P);
  end;
end;
{$ENDIF}

function ReadTextFile(const Path: string; out Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  B: RawByteString;
begin
  Text := '';
  Err := '';
  Result := False;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(B, F.Size);
      if F.Size > 0 then
        F.ReadBuffer(B[1], F.Size);
      Text := B;
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      Err := Format('%s: %s', [Path, E.Message]);
  end;
end;

function WriteTextFile(const Path, Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  B: RawByteString;
begin
  Err := '';
  Result := False;
  if not EnsureParentDir(Path) then
  begin
    Err := 'не удалось создать каталог для ' + Path;
    Exit;
  end;
  B := Text;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Length(B) > 0 then
        F.WriteBuffer(B[1], Length(B));
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      Err := Format('%s: %s', [Path, E.Message]);
  end;
end;

function AppendTextFile(const Path, Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  B: RawByteString;
begin
  Err := '';
  Result := False;
  B := Text;
  if Length(B) = 0 then
    Exit(True);
  if not EnsureParentDir(Path) then
  begin
    Err := 'не удалось создать каталог для ' + Path;
    Exit;
  end;
  try
    { fmOpenWrite не создаёт файл — поэтому при отсутствии создаём его явно. }
    if FileExists(Path) then
      F := TFileStream.Create(Path, fmOpenWrite)
    else
      F := TFileStream.Create(Path, fmCreate);
    try
      F.Seek(0, soEnd);
      F.WriteBuffer(B[1], Length(B));
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      Err := Format('%s: %s', [Path, E.Message]);
  end;
end;

function EnsureParentDir(const Path: string): Boolean;
var
  D: string;
begin
  D := ExtractFileDir(Path);
  if (D = '') or DirectoryExists(D) then
    Exit(True);
  Result := ForceDirectories(D);
end;

procedure ListDirRec(const Dir: string; Recursive: Boolean; Lines: TStringList);
var
  SR: TSearchRec;
  Full, Name: string;
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
        Lines.Add(Full + PathDelim);
        if Recursive then
          ListDirRec(Full, True, Lines);
      end
      else
        Lines.Add(Full);
    until SysUtils.FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function ListDir(const Dir: string; Recursive: Boolean;
  out Lines: TStringList; out Err: string): Boolean;
begin
  Err := '';
  Lines := TStringList.Create;
  Lines.Sorted := True;
  Lines.Duplicates := dupIgnore;
  if not DirectoryExists(Dir) then
  begin
    Err := 'каталог не найден: ' + Dir;
    Exit(False);
  end;
  try
    ListDirRec(Dir, Recursive, Lines);
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

{$IFDEF UNIX}
type
  { Отсоединяет дочерний процесс от управляющего терминала: OnForkEvent
    вызывается в потомке после fork и до exec. Без этого интерактивные
    команды (sudo, ssh, редакторы) открывают /dev/tty, печатают приглашение
    прямо в терминал и блокируются на чтении — инструмент shell «зависает»
    до срабатывания таймаута (а при нулевом таймауте — навсегда). }
  TDetachFromTerminal = class
    procedure OnFork(Sender: TObject);
  end;

procedure TDetachFromTerminal.OnFork(Sender: TObject);
begin
  { Новая сессия: управляющий терминал не наследуется. }
  FpSetsid;
end;
{$ENDIF}

function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string): Boolean; overload;
var
  TotalBytes: Int64;
begin
  Result := RunProcess(Cmd, WorkDir, TimeoutSec, Output, ExitCode, Err, 0, TotalBytes);
end;

function RunProcess(const Cmd, WorkDir: string; TimeoutSec: Integer;
  out Output: string; out ExitCode: Integer; out Err: string;
  MaxOutput: Integer; out TotalBytes: Int64): Boolean; overload;
var
  P: TProcess;
  {$IFDEF UNIX}
  Detach: TDetachFromTerminal;
  {$ENDIF}
  Buf: array[0..8191] of Byte;
  N: LongInt;
  Chunk: RawByteString;
  Deadline: QWord;
  TimedOut: Boolean;

  procedure Drain;
  var
    Room, Keep: LongInt;
  begin
    while P.Output.NumBytesAvailable > 0 do
    begin
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N <= 0 then
        Break;
      Inc(TotalBytes, N);
      { Предел накопления: лишние байты всё равно вычитываем из канала
        (иначе процесс заблокируется на заполненном pipe), но в Output
        не добавляем. Держим запас в 3 байта (максимальная длина символа
        UTF-8 минус один), чтобы финальная обрезка TruncateUTF8 могла
        отступить от границы к ведущему байту последнего символа. }
      if MaxOutput > 0 then
      begin
        Room := MaxOutput + 3 - Length(Output);
        if Room <= 0 then
          Continue;
        if N > Room then
          Keep := Room
        else
          Keep := N;
      end
      else
        Keep := N;
      SetLength(Chunk, Keep);
      Move(Buf[0], Chunk[1], Keep);
      Output := Output + Chunk;
    end;
  end;

begin
  Output := '';
  Err := '';
  ExitCode := -1;
  TotalBytes := 0;
  TimedOut := False;
  Result := False;
  P := TProcess.Create(nil);
  {$IFDEF UNIX}
  Detach := TDetachFromTerminal.Create;
  {$ENDIF}
  try
    {$IFDEF WINDOWS}
    P.Executable := SysUtils.GetEnvironmentVariable('COMSPEC');
    if P.Executable = '' then
      P.Executable := 'cmd.exe';
    P.Parameters.Add('/c');
    P.Parameters.Add(Cmd);
    {$ELSE}
    P.Executable := '/bin/bash';
    P.Parameters.Add('-lc');
    P.Parameters.Add(Cmd);
    {$ENDIF}
    if WorkDir <> '' then
      P.CurrentDirectory := WorkDir;
    P.Options := [poUsePipes, poStderrToOutPut];
    {$IFDEF UNIX}
    P.OnForkEvent := @Detach.OnFork;
    {$ENDIF}
    try
      P.Execute;
    except
      on E: Exception do
      begin
        Err := 'не удалось запустить процесс: ' + E.Message;
        Exit;
      end;
    end;
    { Закрываем свою половину stdin-канала: команды, читающие stdin,
      получают EOF, а не ждут ввод до срабатывания таймаута. }
    P.CloseInput;
    Deadline := TicksMs + QWord(TimeoutSec) * 1000;
    while True do
    begin
      Drain;
      if not P.Running then
        Break;
      if (TimeoutSec > 0) and (TicksMs >= Deadline) then
      begin
        TimedOut := True;
        P.Terminate(1);
        Break;
      end;
      Sleep(15);
    end;
    Drain;
    { Обрезаем собранный вывод по границе символа UTF-8 — только теперь,
      когда процесс уже завершён (или остановлен по таймауту): Copy по
      байту мог бы разрезать многобайтовый символ. Ни флаг Result, ни код
      возврата ExitCode обрезка не меняет. }
    if MaxOutput > 0 then
      Output := TruncateUTF8(Output, MaxOutput);
    if TimedOut then
    begin
      Err := Format('превышено время выполнения команды (%d c)', [TimeoutSec]);
      Output := Output + sLineBreak + '[mirmid] ' + Err;
      Exit;
    end;
    ExitCode := P.ExitStatus;
    Result := True;
  finally
    {$IFDEF UNIX}
    Detach.Free;
    {$ENDIF}
    P.Free;
  end;
end;

function TicksMs: QWord;
begin
  Result := GetTickCount64;
end;
{ --- Окружение (для системного промпта) --- }

{$IFDEF WINDOWS}
{ Номер сборки Windows из реестра (0, если недоступен). }
function WindowsBuildNumber: Integer;
var
  K: HKEY;
  T: DWORD;
  N: DWORD;
  Buf: array[0..63] of AnsiChar;
begin
  Result := 0;
  if RegOpenKeyEx(HKEY_LOCAL_MACHINE,
      'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 0, KEY_READ, K)
      <> ERROR_SUCCESS then
    Exit;
  try
    N := SizeOf(Buf);
    if RegQueryValueEx(K, 'CurrentBuildNumber', nil, @T,
          PByte(@Buf), @N) = ERROR_SUCCESS then
      Result := StrToIntDef(Trim(AnsiString(PAnsiChar(@Buf))), 0);
  finally
    RegCloseKey(K);
  end;
end;
{$ENDIF}

function OsName: string;
{$IFDEF WINDOWS}
var
  B: Integer;
begin
  { GetVersionEx на современных Windows ненадёжен (возвращает 6.0 для
    8/10/11), поэтому опираемся на номер сборки из реестра. }
  B := WindowsBuildNumber;
  if B >= 22000 then
    Result := 'Windows 11'
  else if B >= 10240 then
    Result := 'Windows 10'
  else if B >= 9200 then
    Result := 'Windows 8.1'
  else if B >= 7600 then
    Result := 'Windows 8'
  else if B > 0 then
    Result := 'Windows 7'
  else
    Result := 'Windows';
end;
{$ELSE}
var
  T, Line, Val: string;
  Err: string;
  L: TStringList;
begin
  Result := 'Linux';
  if not ReadTextFile('/etc/os-release', T, Err) then
    Exit;
  L := TStringList.Create;
  try
    L.Text := T;
    for Line in L do
      if Copy(Line, 1, 12) = 'PRETTY_NAME=' then
      begin
        Val := Copy(Line, 13, MaxInt);
        if (Length(Val) >= 2) and (Val[1] in ['"', '''']) and
           (Val[Length(Val)] = Val[1]) then
          Val := Copy(Val, 2, Length(Val) - 2);
        Val := Trim(Val);
        if Val <> '' then
          Result := Val;
        Break;
      end;
  finally
    L.Free;
  end;
end;
{$ENDIF}

function OsArch: string;
{$IFDEF WINDOWS}
const
  { Значения архитектур, отсутствующие в юните Windows этой сборки FPC. }
  PROC_ARCH_AMD64 = 9;
  PROC_ARCH_IA64  = 6;
  PROC_ARCH_ARM64 = 14;
var
  SI: SYSTEM_INFO;
begin
  GetNativeSystemInfo(@SI);
  case SI.wProcessorArchitecture of
    PROC_ARCH_AMD64:               Result := 'x86_64';
    PROC_ARCH_ARM64:               Result := 'arm64';
    PROC_ARCH_IA64:                Result := 'ia64';
    PROCESSOR_ARCHITECTURE_INTEL:  Result := 'x86';
  else
    Result := 'unknown';
  end;
end;
{$ELSE}
var
  U: utsname;
begin
  if fpuname(U) = 0 then
    Result := StrPas(U.machine)
  else
    Result := 'unknown';
end;
{$ENDIF}

function NowStamp: string;
var
  D: TDateTime;
  { Две цифры с ведущим нулём: Format('%02d') в FPC дополняет пробелом. }
  function Pad2(V: Integer): string;
  begin
    if V < 10 then
      Result := '0' + IntToStr(V)
    else
      Result := IntToStr(V);
  end;
begin
  D := Now;
  { Ручное форматирование: FormatDateTime зависит от разделителей локали. }
  Result := IntToStr(YearOf(D)) + '-' + Pad2(MonthOf(D)) + '-' + Pad2(DayOf(D)) +
            ' ' + Pad2(HourOf(D)) + ':' + Pad2(MinuteOf(D)) + ':' + Pad2(SecondOf(D));
end;

function EnvironmentInfo: string;
begin
  Result := 'Окружение: ОС ' + OsName + ' (' + OsArch + '); ' +
            'дата ' + Copy(NowStamp, 1, 10) + '; ' +
            'время ' + Copy(NowStamp, 12, 8);
end;
function ReadAgentsMd(const WorkDir: string): string;
var
  Path, Text, Err: string;
begin
  Result := '';
  if WorkDir = '' then
    Exit;
  Path := ExpPath('AGENTS.md', WorkDir);
  if ReadTextFile(Path, Text, Err) then
    Result := Trim(Text);
end;

{ --------------------------------------------------------------- colors }
var
  FColorsAllowed: Boolean;
  FAnsiChecked: Boolean;
  { По индексу дескриптора (0..2): можно ли писать ANSI-последовательности. }
  FAnsiOK: array[0..2] of Boolean;

{ RGB базовой 16-цветной палитры (xterm). }
const
  BASIC_RGB: array[0..15, 0..2] of Byte = (
    (0, 0, 0),       (195, 5, 5),   (5, 195, 5),   (195, 195, 5),
    (5, 5, 195),     (195, 5, 195), (5, 195, 195), (195, 195, 195),
    (75, 75, 75),    (255, 5, 5),   (5, 255, 5),   (255, 255, 5),
    (5, 5, 255),     (255, 5, 255), (5, 255, 255), (255, 255, 255));

{ Шаги компонента в кубе 6x6x6 (индексы 16..231). }
  CUBE_STEP: array[0..5] of Byte = (0, 95, 135, 175, 215, 255);

{ RGB-компоненты цвета 256-цветной палитры по индексу N (0..255):
  0..15 — базовая палитра, 16..231 — куб 6x6x6, 232..255 — серый градиент. }
function PaletteRGB(N: Integer; out R, G, B: Byte): Boolean;
begin
  if (N < 0) or (N > 255) then
    Exit(False);
  if N <= 15 then
  begin
    R := BASIC_RGB[N, 0];
    G := BASIC_RGB[N, 1];
    B := BASIC_RGB[N, 2];
  end
  else if N <= 231 then
  begin
    N := N - 16;
    R := CUBE_STEP[N div 36];
    G := CUBE_STEP[(N div 6) mod 6];
    B := CUBE_STEP[N mod 6];
  end
  else
  begin
    R := Byte(8 + 10 * (N - 232));
    G := R;
    B := R;
  end;
  Result := True;
end;

{ Индекс базовой 16-цветной палитры по SGR-коду переднего цвета
  (30..37 — тёмные, 90..97 — яркие); -1, если код не базовый цвет. }
function BasicColorIndex(const P: string): Integer;
begin
  Result := -1;
  if Length(P) <> 2 then
    Exit;
  if (P[1] = '3') and (P[2] >= '0') and (P[2] <= '7') then
    Result := Ord(P[2]) - Ord('0')
  else if (P[1] = '9') and (P[2] >= '0') and (P[2] <= '7') then
    Result := 8 + Ord(P[2]) - Ord('0');
end;

function DimSGR(const SGR: string; Brightness: Double = COLOR_BRIGHTNESS): string;
var
  Parts: TStringList;
  I: Integer;
  R, G, B: Byte;
  N, Idx: Integer;
  P: string;

  { Компонент цвета, умноженный на Brightness (0..255). }
  function Scale(C: Byte): Byte;
  var
    V: LongInt;
  begin
    V := Round(C * Brightness);
    if V < 0 then
      V := 0
    else if V > 255 then
      V := 255;
    Result := Byte(V);
  end;

  { 24-битный SGR-код с приглушёнными компонентами. }
  function ScaledColor(const Prefix: string; R, G, B: Byte): string;
  begin
    Result := Prefix + ';2;' + IntToStr(Scale(R)) + ';' +
              IntToStr(Scale(G)) + ';' + IntToStr(Scale(B));
  end;

begin
  if (Brightness >= 1.0) or (SGR = '') then
    Exit(SGR);
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := SGR;
    I := 0;
    while I < Parts.Count do
    begin
      P := Parts[I];
      Idx := BasicColorIndex(P);
      if Idx >= 0 then
      begin
        P := ScaledColor('38', BASIC_RGB[Idx, 0], BASIC_RGB[Idx, 1],
                         BASIC_RGB[Idx, 2]);
        Inc(I);
      end
      else if (P = '38') or (P = '48') then
      begin
        if (I + 2 < Parts.Count) and (Parts[I + 1] = '5') then
        begin
          N := StrToIntDef(Parts[I + 2], -1);
          if PaletteRGB(N, R, G, B) then
          begin
            P := ScaledColor(P, R, G, B);
            Inc(I, 3);
          end
          else
            Inc(I);
        end
        else if (I + 4 < Parts.Count) and (Parts[I + 1] = '2') then
        begin
          R := StrToIntDef(Parts[I + 2], 0);
          G := StrToIntDef(Parts[I + 3], 0);
          B := StrToIntDef(Parts[I + 4], 0);
          P := ScaledColor(P, R, G, B);
          Inc(I, 5);
        end
        else
          { Нераспознанный 38/48 — пропускаем как есть. }
          Inc(I);
      end
      else
        Inc(I);
      if Result <> '' then
        Result := Result + ';';
      Result := Result + P;
    end;
  finally
    Parts.Free;
  end;
end;
{$IFDEF WINDOWS}
{ Дескриптор стандартного потока: 0 — ввод, 2 — ошибки, иначе вывод. }
function StdHandleFor(FD: Integer): THandle;
begin
  case FD of
    0: Result := GetStdHandle(STD_INPUT_HANDLE);
    2: Result := GetStdHandle(STD_ERROR_HANDLE);
  else
    Result := GetStdHandle(STD_OUTPUT_HANDLE);
  end;
end;

function IsTerminal(FD: Integer): Boolean;
var
  H: THandle;
  Mode: DWORD;
begin
  H := StdHandleFor(FD);
  Result := (H <> 0) and (H <> INVALID_HANDLE_VALUE) and (GetConsoleMode(H, Mode) <> False);
end;

{ True, если консоль обработает ESC-последовательности в этом потоке. Если
  ENABLE_VIRTUAL_TERMINAL_PROCESSING не выставлен, включаем его сами — иначе
  ANSI-коды печатаются как обычный текст (в буфере видно «←[38;5;101m»).
  False — поток не консоль (файл, канал) или включить режим не удалось. }
function ConsoleAnsiSupported(FD: Integer): Boolean;
var
  H: THandle;
  Mode: DWORD;
begin
  Result := False;
  H := StdHandleFor(FD);
  if (H = 0) or (H = INVALID_HANDLE_VALUE) then
    Exit;
  if GetConsoleMode(H, Mode) = False then
    Exit;
  if (Mode and ENABLE_VIRTUAL_TERMINAL_PROCESSING) <> 0 then
    Exit(True);
  Result := SetConsoleMode(H, Mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING) <> False;
end;
{$ELSE}
function isatty(fd: Integer): Integer; cdecl; external 'c';

function IsTerminal(FD: Integer): Boolean;
begin
  Result := (isatty(FD) <> 0);
end;

{ На Unix VT-режим включать не нужно — терминал всегда разбирает ANSI. }
function ConsoleAnsiSupported(FD: Integer): Boolean;
begin
  Result := IsTerminal(FD);
end;
{$ENDIF}

function AnsiEnabled(FD: Integer = 1): Boolean;
var
  I: Integer;
begin
  if (FD < 0) or (FD > 2) then
    Exit(False);
  if not FAnsiChecked then
  begin
    { Ленивая инициализация: режим консоли проверяется/включается один раз. }
    FAnsiOK[0] := IsTerminal(0);
    for I := 1 to 2 do
      FAnsiOK[I] := ConsoleAnsiSupported(I);
    FAnsiChecked := True;
  end;
  Result := FAnsiOK[FD];
end;

function InitConsoleAnsi: Boolean;
begin
  Result := AnsiEnabled(1);
end;

function ColorsEnabled(FD: Integer): Boolean;
begin
  Result := FColorsAllowed and AnsiEnabled(FD);
end;

function Colored(const Color, Text: string; FD: Integer = 1): string;
begin
  if (Color = '') or not ColorsEnabled(FD) then
    Exit(Text);
  { Цвет приглушается платформенной яркостью (COLOR_BRIGHTNESS). }
  Result := #27 + '[' + DimSGR(Color) + 'm' + Text + #27 + '[0m';
end;

{$IFDEF WINDOWS}
{ Ширина окна консоли (GetConsoleScreenBufferInfo); запас — COLUMNS, затем 80. }
function TermWidth(FD: Integer = 1): Integer;
var
  H: THandle;
  Info: TConsoleScreenBufferInfo;
  S: string;
begin
  case FD of
    0: H := GetStdHandle(STD_INPUT_HANDLE);
    2: H := GetStdHandle(STD_ERROR_HANDLE);
  else
    H := GetStdHandle(STD_OUTPUT_HANDLE);
  end;
  if (H <> 0) and (H <> INVALID_HANDLE_VALUE) and
     (GetConsoleScreenBufferInfo(H, Info) <> False) then
  begin
    Result := Info.srWindow.Right - Info.srWindow.Left + 1;
    if Result > 0 then
      Exit;
  end;
  S := SysUtils.GetEnvironmentVariable('COLUMNS');
  Result := StrToIntDef(S, 80);
  if Result <= 0 then
    Result := 80;
end;
{$ELSE}
type
  TWinsize = record
    ws_row, ws_col: Word;
  end;

const
  TIOCGWINSZ = $5413;   { запрос размера терминала (Linux) }

function ioctl(fd: Integer; request: LongInt; arg: Pointer): Integer; cdecl; external 'c';

{ Ширина терминала в колонках. }
function TermWidth(FD: Integer = 1): Integer;
var
  WS: TWinsize;
  S: string;
begin
  if (ioctl(FD, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) then
    Exit(Integer(WS.ws_col));
  S := SysUtils.GetEnvironmentVariable('COLUMNS');
  Result := StrToIntDef(S, 80);
  if Result <= 0 then
    Result := 80;
end;
{$ENDIF}

{ True, если кодовая точка нулевая по ширине: связки (ZWJ/ZWNJ),
  вариативные селекторы, комбинируемая диакритика, модификаторы тона
  кожи, невидимые форматные символы. }
function IsZeroWidthCP(CP: Integer): Boolean;
begin
  Result :=
    ((CP >= $0300) and (CP <= $036F)) or  { комбинируемая диакритика }
    ((CP >= $0483) and (CP <= $0489)) or
    ((CP >= $0591) and (CP <= $05BD)) or
    ((CP >= $0610) and (CP <= $061A)) or
    ((CP >= $064B) and (CP <= $065F)) or
    ((CP >= $0670) and (CP <= $0670)) or
    ((CP >= $06D6) and (CP <= $06DC)) or
    ((CP >= $0900) and (CP <= $0902)) or
    ((CP >= $1100) and (CP <= $115F)) or  { хангыль: комбинируемые части }
    ((CP >= $1F3FB) and (CP <= $1F3FF)) or  { тон кожи }
    ((CP >= $200B) and (CP <= $200F)) or  { ZWSP/ZWNJ/ZWJ/LRM/RLM }
    ((CP >= $202A) and (CP <= $202E)) or
    ((CP >= $2060) and (CP <= $206F)) or
    ((CP >= $FE00) and (CP <= $FE0F)) or  { вариативные селекторы }
    (CP = $FEFF) or
    ((CP >= $E0100) and (CP <= $E01EF));
end;

{ True, если кодовая точка широкая (2 колонки в терминале): CJK, полные
  формы, а также символы и эмодзи, которые терминалы рисуют широкими. }
function IsWideCP(CP: Integer): Boolean;
begin
  Result :=
    ((CP >= $1100) and (CP <= $115F)) or    { хангыль: джамо }
    ((CP >= $2E80) and (CP <= $2FFF)) or    { CJK-радикалы, символы }
    ((CP >= $3000) and (CP <= $303E)) or
    ((CP >= $3041) and (CP <= $33FF)) or    { хирагана, катакана, CJK }
    ((CP >= $3400) and (CP <= $4DBF)) or    { CJK ext A }
    ((CP >= $4E00) and (CP <= $9FFF)) or    { CJK unified }
    ((CP >= $A000) and (CP <= $A4CF)) or    { и }
    ((CP >= $A960) and (CP <= $A97F)) or    { хангыль ext A }
    ((CP >= $AC00) and (CP <= $D7A3)) or    { хангыль: слоговые }
    ((CP >= $F900) and (CP <= $FAFF)) or    { CJK compat }
    ((CP >= $FF00) and (CP <= $FF60)) or    { полные формы }
    ((CP >= $FFE0) and (CP <= $FFFD)) or    { полные пунктуация }
    ((CP >= $20000) and (CP <= $3FFFD)) or  { CJK ext B+ }
    { Символы и эмодзи: на практике рисуются в 2 колонки. }
    ((CP >= $2600) and (CP <= $27BF)) or    { символы, dingbats (✅) }
    ((CP >= $2900) and (CP <= $29FF)) or
    ((CP >= $2B00) and (CP <= $2BFF)) or
    ((CP >= $1F000) and (CP <= $1FAFF));    { эмодзи и доп. символы }
end;

{ Видимая длина строки в колонках: без ANSI-последовательностей. }
function VisibleLen(const S: string): Integer;
var
  I, J, N, CP, Len: Integer;
begin
  Result := 0;
  N := Length(S);
  I := 1;
  while I <= N do
  begin
    if S[I] = #27 then
    begin
      { Пропускаем ANSI-последовательность: ESC, введущий байт
        ($3C..$3F, $5B..$5F), параметрные ($30..$3F) и промежуточные
        ($20..$2F) байты — до конечного байта ($40..$7E). }
      Inc(I);
      if (I <= N) and ((Ord(S[I]) in [$3C..$3F]) or (Ord(S[I]) in [$5B..$5F])) then
        Inc(I);
      while (I <= N) and (Ord(S[I]) in [$20..$3F]) do
        Inc(I);
      if I <= N then
        Inc(I);
    end
    else if Ord(S[I]) < $80 then
    begin
      Inc(Result);
      Inc(I);
    end
    else if (Ord(S[I]) and $C0) <> $C0 then
    begin
      { Байт продолжения без стартового — считаем за один символ. }
      Inc(Result);
      Inc(I);
    end
    else
    begin
      { Декодируем кодовую точку UTF-8. }
      CP := Ord(S[I]);
      if CP < $E0 then
      begin
        Len := 2;
        CP := CP and $1F;
      end
      else if CP < $F0 then
      begin
        Len := 3;
        CP := CP and $0F;
      end
      else
      begin
        Len := 4;
        CP := CP and $07;
      end;
      if I + Len - 1 > N then
      begin
        { Обрыв последовательности — считаем за один символ. }
        Inc(Result);
        Inc(I);
        Continue;
      end;
      for J := 2 to Len do
        CP := (CP shl 6) or (Ord(S[I + J - 1]) and $3F);
      if IsWideCP(CP) then
        Inc(Result, 2)
      else if not IsZeroWidthCP(CP) then
        Inc(Result);
      Inc(I, Len);
    end;
  end;
end;

{ Переносит строку по словам: последний пробел, перед которым фрагмент ещё
  влезает в Width, становится точкой разрыва; сам пробел не попадает ни в
  предыдущий, ни в следующий фрагмент. Если пробелов нет (или ни один не
  подходит) — принудительный разрыв по наибольшему влезающему префиксу. }
function WrapText(const S: string; Width: Integer; Measure: TTextMeasure;
  BreakAllowed: TBreakAllowed): TStringList;
var
  Rem, Prefix: string;
  I, IStart, BestP, L: Integer;
  First: Boolean;
begin
  Result := TStringList.Create;
  if Width < 1 then
    Width := 1;
  Rem := S;
  First := True;
  while Rem <> '' do
  begin
    if First then
    begin
      { Ведущие пробелы строки (отступ) сохраняем — они принадлежат
        первому слову. Строка из одних пробелов — пустая строка. }
      if TrimLeft(Rem) = '' then
      begin
        Result.Add('');
        Break;
      end;
    end
    else
      { Фрагмент после разрыва не должен начинаться с пробела. }
      while (Rem <> '') and (Rem[1] = ' ') do
        Delete(Rem, 1, 1);
    if Rem = '' then
      Break;
    if Measure(Rem) < Width then
    begin
      Result.Add(Rem);
      Break;
    end;
    { Точки разрыва — пробелы. Для первого фрагмента ведущие пробелы
      (отступ) точками разрыва не являются: они остаются при первом слове. }
    IStart := 1;
    if First then
      while (IStart <= Length(Rem)) and (Rem[IStart] = ' ') do
        Inc(IStart);
    { Последний пробел, перед которым фрагмент ещё влезает и разрыв в этой
      точке разрешён. Проверяем все пробелы (без раннего выхода): видимая
      ширина не всегда монотонна из-за закрывающей разметки. }
    BestP := 0;
    for I := IStart to Length(Rem) do
      if Rem[I] = ' ' then
      begin
        Prefix := Copy(Rem, 1, I - 1);
        if (Measure(Prefix) < Width) and
           ((BreakAllowed = nil) or BreakAllowed(Prefix)) then
          BestP := I;
      end;
    if BestP > 1 then
    begin
      Result.Add(Copy(Rem, 1, BestP - 1));
      Rem := Copy(Rem, BestP + 1, MaxInt);
    end
    else if BestP = 1 then
      Rem := Copy(Rem, 2, MaxInt)   { ведущий пробел — отбросить }
    else
    begin
      { Безопасного пробела нет: наибольший префикс, влезающий в строку.
        Разрыв внутри разметки возможен, но сохраняется главное — фрагмент
        не шире строки (иначе частичную строку нельзя перерисовать). }
      L := 0;
      for I := 1 to Length(Rem) do
      begin
        Prefix := Copy(Rem, 1, I);
        if Measure(Prefix) < Width then
          L := I
        else if L > 0 then
          Break;
      end;
      if L = 0 then
        L := 1;   { хотя бы один символ, иначе зацикливание }
      if First and (L < IStart) then
        L := IStart;   { отступ не терять: хотя бы до первого слова }
      Result.Add(Copy(Rem, 1, L));
      Rem := Copy(Rem, L + 1, MaxInt);
    end;
    First := False;
  end;
  if Result.Count = 0 then
    Result.Add('');
end;

{ Число байтов в UTF-8-последовательности по ведущему байту; 1 — для
  ASCII и для некорректного ведущего байта. }
function UTF8SeqLenByLead(Lead: Byte): Integer;
begin
  if Lead < $80 then
    Result := 1
  else if (Lead and $E0) = $C0 then
    Result := 2
  else if (Lead and $F0) = $E0 then
    Result := 3
  else if (Lead and $F8) = $F0 then
    Result := 4
  else
    Result := 1;
end;

function UTF8SeqValid(const S: string; I: Integer): Boolean;
var
  B: Byte;
  N, J: Integer;
begin
  Result := False;
  if (I < 1) or (I > Length(S)) then
    Exit;
  B := Byte(S[I]);
  if B < $80 then
  begin
    Result := True;
    Exit;
  end;
  N := UTF8SeqLenByLead(B);
  if (N < 2) or (I + N - 1 > Length(S)) then
    Exit;
  for J := 1 to N - 1 do
    if (Byte(S[I + J]) and $C0) <> $80 then
      Exit;
  { Отсеиваем перегруженные последовательности и суррогаты. }
  if N = 2 then
    Result := B >= $C2
  else if N = 3 then
    Result := not (((B = $E0) and (Byte(S[I + 1]) < $A0)) or
                   ((B = $ED) and (Byte(S[I + 1]) >= $A0)))
  else
    Result := (B <= $F4) and
              not ((B = $F0) and (Byte(S[I + 1]) < $90)) and
              not ((B = $F4) and (Byte(S[I + 1]) >= $90));
end;

function TruncateUTF8(const S: string; MaxBytes: Integer): string;
var
  I, N: Integer;
begin
  if MaxBytes <= 0 then
    Exit('');
  if Length(S) <= MaxBytes then
    Exit(S);
  { Байт MaxBytes может быть продолжением многобайтового символа:
    отступаем к его ведущему байту. }
  I := MaxBytes;
  while (I >= 1) and ((Byte(S[I]) and $C0) = $80) do
    Dec(I);
  if I = 0 then
    Exit('');
  N := UTF8SeqLenByLead(Byte(S[I]));
  if I + N - 1 <= MaxBytes then
    Result := Copy(S, 1, I + N - 1)
  else
    Result := Copy(S, 1, I - 1);
end;

function IsValidUTF8(const S: string): Boolean;
var
  I: Integer;
begin
  I := 1;
  while I <= Length(S) do
  begin
    if not UTF8SeqValid(S, I) then
      Exit(False);
    if Byte(S[I]) < $80 then
      Inc(I)
    else
      Inc(I, UTF8SeqLenByLead(Byte(S[I])));
  end;
  Result := True;
end;

function SanitizeUTF8(const S: string): string;
var
  I, N: Integer;
begin
  if IsValidUTF8(S) then
    Exit(S);
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if UTF8SeqValid(S, I) then
    begin
      if Byte(S[I]) < $80 then
        N := 1
      else
        N := UTF8SeqLenByLead(Byte(S[I]));
      Result := Result + Copy(S, I, N);
      Inc(I, N);
    end
    else
    begin
      Result := Result + #$EF#$BF#$BD;   { U+FFFD вместо «битого» байта }
      Inc(I);
    end;
  end;
end;
function ShortenLinesMiddle(const S: string; MaxLines: Integer): string;
var
  Lines: TStringList;
  I, Head, Tail: Integer;
  Sep: string;
  HadEol: Boolean;
begin
  if (MaxLines <= 0) or (S = '') then
    Exit(S);
  Lines := TStringList.Create;
  try
    { Text делит по CRLF/LF/CR; завершающий перевод строки не порождает
      лишнюю пустую строку. }
    Lines.Text := S;
    if Lines.Count <= MaxLines then
      Exit(S);
    { В N строк результата входят N - 1 строка содержимого и маркер «…»;
      при чётном N на одну строку больше оставляем снизу (конец вывода
      обычно важнее). Для N = 9 получается 4 + «…» + 4. }
    Head := (MaxLines - 1) div 2;
    Tail := (MaxLines - 1) - Head;
    { Сохраняем стиль перевода строки исходного текста. }
    if Pos(#13#10, S) > 0 then
      Sep := #13#10
    else if Pos(#10, S) > 0 then
      Sep := #10
    else
      Sep := LineEnding;
    HadEol := (S[Length(S)] = #10) or (S[Length(S)] = #13);
    Result := '';
    for I := 0 to Head - 1 do
      Result := Result + Lines[I] + Sep;
    { Маркер сокращения печатается с отступом (SHORTEN_ELLIPSIS_INDENT):
      иначе троеточие стоит вплотную к началу строки и читается как первая
      строка вывода, а не как разделитель его частей (task1.md). }
    Result := Result + StringOfChar(' ', SHORTEN_ELLIPSIS_INDENT) + '…' + Sep;
    for I := Lines.Count - Tail to Lines.Count - 1 do
      Result := Result + Lines[I] + Sep;
    if not HadEol then
      Delete(Result, Length(Result) - Length(Sep) + 1, Length(Sep));
  finally
    Lines.Free;
  end;
end;

function TrimBlankLines(const S: string): string;
var
  Lines: TStringList;
  I, First, Last: Integer;
  Sep: string;
begin
  if S = '' then
    Exit('');
  Lines := TStringList.Create;
  try
    { Text делит по CRLF/LF/CR; завершающий перевод строки не порождает
      лишнюю пустую строку. }
    Lines.Text := S;
    First := 0;
    while (First < Lines.Count) and (Trim(Lines[First]) = '') do
      Inc(First);
    { Весь текст из пустых строк — печатать нечего. }
    if First >= Lines.Count then
      Exit('');
    Last := Lines.Count - 1;
    while (Last > First) and (Trim(Lines[Last]) = '') do
      Dec(Last);
    { Сохраняем стиль перевода строки исходного текста. }
    if Pos(#13#10, S) > 0 then
      Sep := #13#10
    else if Pos(#10, S) > 0 then
      Sep := #10
    else
      Sep := LineEnding;
    Result := '';
    for I := First to Last - 1 do
      Result := Result + Lines[I] + Sep;
    Result := Result + Lines[Last];
  finally
    Lines.Free;
  end;
end;

{ --- Diff --- }

function MakeUnifiedDiff(const OldLines, NewLines: TStringList;
  const OldName, NewName: string; OldStartLine: Integer = 1;
  Context: Integer = 3): string;
const
  { Предел размера таблицы LCS: 8 млн ячеек (~32 МБ) — примерно 0,3 с. }
  LCS_MAX_CELLS = 8 * 1000 * 1000;
var
  N, M: Integer;
  Prefix, Suffix: Integer;
  OldMid, NewMid: TStringList;
  NoLcs: Boolean;
  Cells: Int64;
  LCS: array of array of Integer;
  I, J: Integer;
  Ops: TStringList;
  OldPos, NewPos: Integer;
  DiffLines: TStringList;
  HunkStart, HunkEnd, ChangeEnd: Integer;
  OldLineNum, NewLineNum: Integer;
  OldCount, NewCount: Integer;
  OldStart, NewStart: Integer;
  Line: string;
begin
  N := OldLines.Count;
  M := NewLines.Count;

  if (N = 0) and (M = 0) then
    Exit('');

  { Отсекаем общий префикс и суффикс: обычная правка затрагивает один участок,
    и LCS достаточно считать для «середины». Без отсечения таблица строится по
    всему файлу (N*M ячеек): 10k строк — 400 МБ и секунды, 50k строк —
    практическое зависание правки. }
  Prefix := 0;
  while (Prefix < N) and (Prefix < M) and
        (OldLines[Prefix] = NewLines[Prefix]) do
    Inc(Prefix);
  Suffix := 0;
  while (Suffix < N - Prefix) and (Suffix < M - Prefix) and
        (OldLines[N - 1 - Suffix] = NewLines[M - 1 - Suffix]) do
    Inc(Suffix);

  OldMid := TStringList.Create;
  NewMid := TStringList.Create;
  Ops := TStringList.Create;
  DiffLines := TStringList.Create;
  DiffLines.LineBreak := sLineBreak;
  try
    for I := Prefix to N - Suffix - 1 do
      OldMid.Add(OldLines[I]);
    for I := Prefix to M - Suffix - 1 do
      NewMid.Add(NewLines[I]);
    N := OldMid.Count;
    M := NewMid.Count;

    { Совпали целиком — изменений нет. }
    if (N = 0) and (M = 0) then
      Exit('');

    { Если одна из сторон пуста или середина слишком велика (правка переписала
      почти весь файл), LCS не считаем — отдаём её сплошной заменой. }
    Cells := Int64(N) * Int64(M);
    NoLcs := (N = 0) or (M = 0) or (Cells > LCS_MAX_CELLS);

    if not NoLcs then
    begin
      { Таблица LCS: LCS[i,j] = длина наибольшей общей подпоследовательности
        OldMid[i..N-1] и NewMid[j..M-1]. }
      SetLength(LCS, N + 1, M + 1);
      for I := N - 1 downto 0 do
        for J := M - 1 downto 0 do
          if OldMid[I] = NewMid[J] then
            LCS[I, J] := LCS[I + 1, J + 1] + 1
          else
            if LCS[I + 1, J] >= LCS[I, J + 1] then
              LCS[I, J] := LCS[I + 1, J]
            else
              LCS[I, J] := LCS[I, J + 1];
    end;

    { Список операций (' ' — совпадение, '-' — удалено из Old,
      '+' — добавлено из New) по всему файлу: префикс, середина, суффикс. }
    for I := 1 to Prefix do
      Ops.Add(' ');

    if NoLcs then
    begin
      for I := 1 to N do
        Ops.Add('-');
      for I := 1 to M do
        Ops.Add('+');
    end
    else
    begin
      OldPos := 0;
      NewPos := 0;
      while (OldPos < N) or (NewPos < M) do
      begin
        if (OldPos < N) and (NewPos < M) and
           (OldMid[OldPos] = NewMid[NewPos]) then
        begin
          Ops.Add(' ');
          Inc(OldPos);
          Inc(NewPos);
        end
        else if (OldPos < N) and
                ((NewPos >= M) or
                 (LCS[OldPos + 1, NewPos] >= LCS[OldPos, NewPos + 1])) then
        begin
          Ops.Add('-');
          Inc(OldPos);
        end
        else
        begin
          Ops.Add('+');
          Inc(NewPos);
        end;
      end;
    end;

    for I := 1 to Suffix do
      Ops.Add(' ');

    { Нет изменений — пустой diff. }
    I := 0;
    while (I < Ops.Count) and (Ops[I] = ' ') do
      Inc(I);
    if I = Ops.Count then
      Exit('');

    { Формируем unified diff. Строки копим в TStringList: склейка
      S := S + … на каждой строке файла даёт квадратичный объём копирования. }
    if OldName <> '' then
      DiffLines.Add('--- ' + OldName);
    if NewName <> '' then
      DiffLines.Add('+++ ' + NewName);

    I := 0;
    while I < Ops.Count do
    begin
      if Ops[I] = ' ' then
      begin
        Inc(I);
        Continue;
      end;

      { Начало блока изменений; расширяем влево контекстом. }
      HunkStart := I;
      while (HunkStart > 0) and (Ops[HunkStart - 1] = ' ') and
            (I - HunkStart < Context) do
        Dec(HunkStart);


      { Конец блока изменений. }
      ChangeEnd := I;
      while (ChangeEnd < Ops.Count) and (Ops[ChangeEnd] <> ' ') do
        Inc(ChangeEnd);
      HunkEnd := ChangeEnd;

      { Расширяем вправо контекстом (отсчёт от конца блока изменений). }
      while (HunkEnd < Ops.Count) and (Ops[HunkEnd] = ' ') and
            (HunkEnd - ChangeEnd < Context) do
        Inc(HunkEnd);

      { Номера строк на момент начала ханка (0-базированные индексы). }
      OldLineNum := 0;
      NewLineNum := 0;
      for J := 0 to HunkStart - 1 do
      begin
        if (Ops[J] = ' ') or (Ops[J] = '-') then
          Inc(OldLineNum);
        if (Ops[J] = ' ') or (Ops[J] = '+') then
          Inc(NewLineNum);
      end;

      { Число строк в ханке. }
      OldCount := 0;
      NewCount := 0;
      for J := HunkStart to HunkEnd - 1 do
      begin
        if (Ops[J] = ' ') or (Ops[J] = '-') then
          Inc(OldCount);
        if (Ops[J] = ' ') or (Ops[J] = '+') then
          Inc(NewCount);
      end;

      { Заголовок ханка: @@ -old_start,old_count +new_start,new_count @@ }
      OldStart := OldLineNum + OldStartLine;
      NewStart := NewLineNum + OldStartLine;
      if OldCount = 0 then
        Dec(OldStart);
      if NewCount = 0 then
        Dec(NewStart);

      DiffLines.Add('@@ -' + IntToStr(OldStart) + ',' + IntToStr(OldCount) +
        ' +' + IntToStr(NewStart) + ',' + IntToStr(NewCount) + ' @@');

      { Тело ханка. }
      for J := HunkStart to HunkEnd - 1 do
      begin
        Line := Ops[J];
        if Line = ' ' then
        begin
          DiffLines.Add(' ' + OldLines[OldLineNum]);
          Inc(OldLineNum);
          Inc(NewLineNum);
        end
        else if Line = '-' then
        begin
          DiffLines.Add('-' + OldLines[OldLineNum]);
          Inc(OldLineNum);
        end
        else
        begin
          DiffLines.Add('+' + NewLines[NewLineNum]);
          Inc(NewLineNum);
        end;
      end;

      I := HunkEnd;
    end;

    Result := DiffLines.Text;
  finally
    NewMid.Free;
    OldMid.Free;
    Ops.Free;
    DiffLines.Free;
  end;
end;
initialization
  FColorsAllowed := SysUtils.GetEnvironmentVariable('NO_COLOR') = '';
  FAnsiChecked := False;

end.
