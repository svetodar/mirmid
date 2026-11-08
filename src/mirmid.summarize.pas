unit mirmid.summarize;
{ Суммаризация сессии: вызывает LLM для создания краткого резюме диалога.
  Результат суммаризации используется для создания новой сессии:
  системная подсказка + сообщение-резюме + план (если есть). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mirmid.types, mirmid.tools;

type
  { Результат суммаризации. }
  TSummarizeResult = record
    Summary: string;         { текст резюме }
    TokensBefore: Integer;   { оценка токенов до суммаризации }
    TokensAfter: Integer;    { оценка токенов после (резюме + системная подсказка) }
    Effective: Boolean;      { True, если уменьшение >= порога }
  end;

{ Системная подсказка для суммаризации. }
const
  SUMMARIZE_SYSTEM_PROMPT =
    'Ты — суммаризатор диалога. Создай краткое резюме предоставленного ' +
    'диалога между пользователем и ИИ-агентом. Сохрани: ' +
    '1) основные задачи и запросы пользователя; ' +
    '2) выполненные действия и их результаты; ' +
    '3) текущее состояние и незавершённые задачи; ' +
    '4) важные решения и договорённости. ' +
    'Формат: структурированный текст на русском, без избыточных деталей. ' +
    'Не выдумывай информацию, которой нет в диалоге.';

{ Суммаризация сессии: вызывает LLM для создания краткого резюме диалога.
  Msgs — история сообщений (без системного сообщения — оно передаётся отдельно).
  Возвращает True при успехе. }
function SummarizeSession(const Cfg: TMirmidConfig; const Msgs: TMessages;
  out Res: TSummarizeResult; out Err: string): Boolean;

{ Строит новые сообщения для сессии после суммаризации:
  системная подсказка + резюме как user-сообщение. }
function BuildSummarizedMessages(const Cfg: TMirmidConfig;
  const Summary: string): TMessages;

implementation

uses
  mirmid.llm, mirmid.agent;

function BuildSummarizedMessages(const Cfg: TMirmidConfig;
  const Summary: string): TMessages;
var
  Msgs: TMessages;
  N: Integer;
begin
  N := 0;
  if Cfg.SystemPrompt <> '' then
  begin
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrSystem, Cfg.SystemPrompt);
    N := 1;
  end;
  SetLength(Msgs, N + 1);
  Msgs[N] := MakeMessage(mrUser,
    'Продолжение сессии. Резюме предыдущей сессии:' + sLineBreak + Summary);
  Result := Msgs;
end;

function SummarizeSession(const Cfg: TMirmidConfig; const Msgs: TMessages;
  out Res: TSummarizeResult; out Err: string): Boolean;
var
  LLM: TLLMClient;
  Resp: TLLMResponse;
  SumMsgs: TMessages;
  I, N: Integer;
  S: string;
begin
  Result := False;
  Err := '';
  FillChar(Res, SizeOf(Res), 0);

  { Оценка токенов до суммаризации. }
  S := '';
  for I := Low(Msgs) to High(Msgs) do
  begin
    S := S + RoleName(Msgs[I].Role) + Msgs[I].Content + Msgs[I].Reasoning;
  end;
  Res.TokensBefore := (CountUTF8Chars(S) + 3) div 4;

  { Строим сообщения для запроса суммаризации: системная подсказка
    суммаризатора + история диалога (без системного сообщения основной
    сессии — оно не нужно для резюме). }
  N := 0;
  SetLength(SumMsgs, 1);
  SumMsgs[0] := MakeMessage(mrSystem, SUMMARIZE_SYSTEM_PROMPT);
  for I := Low(Msgs) to High(Msgs) do
  begin
    if Msgs[I].Role = mrSystem then
      Continue;
    Inc(N);
    SetLength(SumMsgs, N + 1);
    SumMsgs[N] := Msgs[I];
  end;

  LLM := TLLMClient.Create(Cfg);
  try
    if not LLM.Chat(SumMsgs, nil, Resp, Err) then
      Exit(False);
    Res.Summary := Trim(Resp.Content);
    if Res.Summary = '' then
    begin
      Err := 'модель вернула пустое резюме';
      Exit(False);
    end;

    { Оценка токенов после: системная подсказка + резюме. }
    S := Cfg.SystemPrompt + 'Продолжение сессии. Резюме предыдущей сессии:' +
      sLineBreak + Res.Summary;
    Res.TokensAfter := (CountUTF8Chars(S) + 3) div 4;

    { Эффективность: уменьшение >= порога. }
    Res.Effective := (Res.TokensBefore - Res.TokensAfter) >=
      SummarizeMinSaving(Cfg);
    Result := True;
  finally
    LLM.Free;
  end;
end;

end.