unit mirmid.summarize;
{ Session summarisation: calls the LLM to produce a short summary of a dialog.
  The summarisation result is used to build a new session:
  system prompt + summary message + plan (if any). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mirmid.types, mirmid.tools;

type
  { Result of summarisation. }
  TSummarizeResult = record
    Summary: string;         { summary text }
    TokensBefore: Integer;   { estimated tokens before summarisation }
    TokensAfter: Integer;    { estimated tokens after (summary + system prompt) }
    Effective: Boolean;      { True if the reduction reaches the threshold }
  end;

{ System prompt for summarisation. }
const
  SUMMARIZE_SYSTEM_PROMPT =
    'You are a dialog summariser. Produce a concise summary of the provided ' +
    'dialog between the user and an AI agent. Preserve: ' +
    '1) the main tasks and requests of the user; ' +
    '2) the actions performed and their results; ' +
    '3) the current state and unfinished tasks; ' +
    '4) important decisions and agreements. ' +
    'Format: structured plain text, without excessive detail. ' +
    'Do not invent information that is not in the dialog.';

{ Summarise a session: calls the LLM to produce a short summary of the dialog.
  Msgs — message history (without the system message — it is passed separately).
  Returns True on success. }
function SummarizeSession(const Cfg: TMirmidConfig; const Msgs: TMessages;
  out Res: TSummarizeResult; out Err: string): Boolean;

{ Builds the new messages for the session after summarisation:
  system prompt + the summary as a user message. }
function BuildSummarizedMessages(const Cfg: TMirmidConfig;
  const Summary: string): TMessages;

implementation

uses
  mirmid.llm, mirmid.agent;

const
  CONTINUATION_PREFIX = 'Session continuation. Summary of the previous session:';

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
  Msgs[N] := MakeMessage(mrUser, CONTINUATION_PREFIX + sLineBreak + Summary);
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

  { Estimate the tokens before summarisation. }
  S := '';
  for I := Low(Msgs) to High(Msgs) do
  begin
    S := S + RoleName(Msgs[I].Role) + Msgs[I].Content + Msgs[I].Reasoning;
  end;
  Res.TokensBefore := (CountUTF8Chars(S) + 3) div 4;

  { Build the messages for the summarisation request: the summariser system
    prompt + the dialog history (without the system message of the main
    session — it is not needed for the summary). }
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
      Err := 'model returned an empty summary';
      Exit(False);
    end;

    { Estimate the tokens after: system prompt + summary. }
    S := Cfg.SystemPrompt + CONTINUATION_PREFIX +
      sLineBreak + Res.Summary;
    Res.TokensAfter := (CountUTF8Chars(S) + 3) div 4;

    { Efficiency: the reduction reaches the threshold. }
    Res.Effective := (Res.TokensBefore - Res.TokensAfter) >=
      SummarizeMinSaving(Cfg);
    Result := True;
  finally
    LLM.Free;
  end;
end;

end.