unit mirmid.anthropic;
{ Клиент Anthropic Messages API (POST /v1/messages).
  Поддерживает обычный и streaming (SSE) режимы, tools, system prompt. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, mirmid.types, mirmid.tools;
const
  { Версия API Anthropic (заголовок anthropic-version). }
  ANTHROPIC_API_VERSION = '2023-06-01';

type
  { Тип блока контента в ответе Anthropic. }
  { Модель запроса к Anthropic Messages API (POST /v1/messages).
    Соответствует документации: https://docs.anthropic.com/en/api/messages }
  TAnthropicRequest = record
    Model: string;              { required: идентификатор модели, напр. "claude-sonnet-4-20250514" }
    Messages: TMessages;        { required: массив сообщений (role + content) }
    MaxTokens: Integer;         { required: максимальное число токенов в ответе }
    System: string;             { optional: системный промпт }
    Stream: Boolean;            { optional: true — SSE-поток }
    Temperature: Double;        { optional: 0..1, 0 — не отправляется }
    TopP: Double;               { optional: 0..1, 0 — не отправляется }
    TopK: Integer;              { optional: 0 — не отправляется }
    StopSequences: array of string; { optional: последовательности остановки }
    Tools: TJSONArray;          { optional: схемы инструментов (nil — нет) }
    ToolChoice: TJSONObject;    { optional: объект type ("auto"|"any"|"tool") и name }
    Metadata: TJSONObject;      { optional: объект с полем user_id }
  end;

  TAnthropicBlockType = (abtText, abtToolUse, abtThinking, abtUnknown);

  { Один блок контента в ответе. }
  TAnthropicContentBlock = record
    BlockType: TAnthropicBlockType;
    Text: string;           { abtText: текст }
    ToolId: string;         { abtToolUse: id вызова }
    ToolName: string;       { abtToolUse: имя инструмента }
    ToolInput: string;      { abtToolUse: JSON-аргументы (сырая строка) }
    Thinking: string;       { abtThinking: текст рассуждения }
    Signature: string;      { abtThinking: подпись (extended thinking) }
  end;

  { Учёт токенов (usage) в ответе Anthropic. }
  TAnthropicUsage = record
    InputTokens: Integer;              { input_tokens }
    OutputTokens: Integer;             { output_tokens }
    CacheCreationInputTokens: Integer; { cache_creation_input_tokens }
    CacheReadInputTokens: Integer;     { cache_read_input_tokens }
  end;

  { Ответ Anthropic Messages API (не-стримовый режим).
    Соответствует: https://docs.anthropic.com/en/api/messages }
  TAnthropicResponse = record
    Id: string;             { "msg_..." }
    MsgType: string;          { всегда "message" }
    Role: string;           { всегда "assistant" }
    Model: string;
    Content: array of TAnthropicContentBlock;
    StopReason: string;     { "end_turn" | "max_tokens" | "stop_sequence" | "tool_use" }
    StopSequence: string;   { фактическая stop-последовательность (если stop_reason="stop_sequence") }
    Usage: TAnthropicUsage;
    ServiceTier: string;    { "standard" | "priority" (если задано) }
  end;
  { Ошибка Anthropic API: тип, сообщение, HTTP-статус и признак повторности.
    Формат ответа: type "error" и объект error с полями type и message. }
  TAnthropicError = record
    ErrorType: string;    { "authentication_error" | "rate_limit_error" | "api_error" | ... }
    Message: string;      { человекочитаемое сообщение }
    StatusCode: Integer;  { HTTP-статус (401, 429, 500, ...); 0 — не удалось соединиться }
    Retryable: Boolean;   { True для 429 и 5xx — запрос можно повторить }
  end;
  { Список ошибок валидации запроса. }
  TAnthropicValidationErrors = array of string;

  { Middleware-валидатор входных параметров запроса к /v1/messages.
    Вызывается клиентом до отправки HTTP-запроса и отклоняет некорректные
    запросы (400 invalid_request_error), не обращаясь к сети. }
  TAnthropicValidator = class
  public
    { Проверяет обязательные поля и диапазоны параметров. Возврат True —
      запрос валиден; иначе Errors содержит список ошибок. }
    function Validate(const Req: TAnthropicRequest;
      out Errors: TAnthropicValidationErrors): Boolean;
    { Человекочитаемое сообщение по списку ошибок (через «; »). }
    class function JoinErrors(const Errors: TAnthropicValidationErrors): string;
  end;

  { Дельта стрима Anthropic: часть текста или tool_use-аргументов. }
  TAnthropicDeltaHandler = procedure(const TextDelta, ToolInputDelta: string) of object;

  { Аккумулятор SSE-потока Anthropic. Собирает content-блоки, stop_reason, usage. }
  TAnthropicSSEAccumulator = class
  private
    FBlocks: array of TAnthropicContentBlock;
    FStopReason: string;
    FStopSequence: string;
    FUsage: TAnthropicUsage;
    FModel: string;
    FId: string;
    FDone: Boolean;
    FLineBuf: RawByteString;
    FOnDelta: TAnthropicDeltaHandler;
    procedure HandleEvent(const D: TJSONData);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    property Done: Boolean read FDone;
    property OnDelta: TAnthropicDeltaHandler read FOnDelta write FOnDelta;
    { Принимает фрагмент SSE-потока. Возврат False — поток завершён. }
    function FeedChunk(const Chunk: RawByteString): Boolean;
    function Flush: Boolean;
    function FeedLine(const Line: string): Boolean;
    procedure Collect(out Resp: TAnthropicResponse);
  end;

  { Клиент Anthropic Messages API. }
  TAnthropicClient = class
  private
    FApiKey: string;
    FBaseUrl: string;       { по умолчанию https://api.anthropic.com }
    FRequestTimeout: Integer; { мс; общий таймаут HTTP-запроса }
    FConnectTimeout: Integer; { мс; таймаут соединения }
    FAcc: TAnthropicSSEAccumulator;
    FValidator: TAnthropicValidator;
  public
    constructor Create(const AApiKey, ABaseUrl: string);
    destructor Destroy; override;
    { Один запрос к Anthropic Messages API (обычный режим). }
    function SendMessages(const Req: TAnthropicRequest;
      out Resp: TAnthropicResponse; out Err: string;
      out ErrJson: TJSONData): Boolean;
    { Запрос в потоковом режиме (SSE). }
    function SendMessagesStream(const Req: TAnthropicRequest;
      const OnDelta: TAnthropicDeltaHandler;
      out Resp: TAnthropicResponse; out Err: string;
      out ErrJson: TJSONData): Boolean;
    { Принять фрагмент SSE-потока. Возврат False — получен message_stop. }
    function SSEChunk(const Chunk: RawByteString): Boolean;
    { Middleware: валидация входных параметров до отправки HTTP-запроса.
      Возврат False — запрос отклонён, Err/ErrJson заполнены (400). }
    function ValidateRequest(const Req: TAnthropicRequest;
      out Err: string; out ErrJson: TJSONData): Boolean;
    property Accumulator: TAnthropicSSEAccumulator read FAcc;
  end;

{ Создаёт запрос с разумными значениями по умолчанию. }
function MakeAnthropicRequest(const AModel: string; const AMsgs: TMessages;
  AMaxTokens: Integer): TAnthropicRequest;

{ Формирует JSON-тело запроса к /v1/messages из модели TAnthropicRequest. }
function BuildRequestJson(const Req: TAnthropicRequest): TJSONData;

{ Разбирает JSON-ответ Anthropic в TAnthropicResponse. }
function ParseResponse(const D: TJSONData): TAnthropicResponse;

{ Склеивает все text-блоки ответа в одну строку. }
function AnthropicResponseText(const R: TAnthropicResponse): string;
{ Разбирает JSON-тело ошибки Anthropic в TAnthropicError. Если тело не JSON
  или не содержит ожидаемой структуры, тип и сообщение выводятся из статуса. }
function ParseError(const D: TJSONData; AStatusCode: Integer): TAnthropicError;

{ Строит JSON-объект ошибки для возврата вызывающему коду:
  type "error" и объект error с полями type, message, status, retryable.
  Вызывающий код обязан освободить результат. }
function BuildErrorJson(const E: TAnthropicError): TJSONObject;

{ Человекочитаемое описание ошибки (для поля Err). }
function AnthropicErrorText(const E: TAnthropicError): string;

implementation

uses
  mirmid.http, mirmid.json, mirmid.util;

{--- MakeAnthropicRequest ---}

function MakeAnthropicRequest(const AModel: string; const AMsgs: TMessages;
  AMaxTokens: Integer): TAnthropicRequest;
begin
  Result.Model         := AModel;
  Result.Messages      := AMsgs;
  Result.MaxTokens     := AMaxTokens;
  Result.System        := '';
  Result.Stream        := False;
  Result.Temperature   := 0;
  Result.TopP          := 0;
  Result.TopK          := 0;
  SetLength(Result.StopSequences, 0);
  Result.Tools         := nil;
  Result.ToolChoice    := nil;
  Result.Metadata      := nil;
end;

{--- BuildRequestJson ---}

function BuildRequestJson(const Req: TAnthropicRequest): TJSONData;
var
  J: TJSONObject;
  JMsgs, JStopSeqs: TJSONArray;
  i: Integer;
  JMsg: TJSONObject;
begin
  J := TJSONObject.Create;

  { required }
  J.Add('model', Req.Model);
  J.Add('max_tokens', Req.MaxTokens);

  { messages }
  JMsgs := TJSONArray.Create;
  for i := 0 to High(Req.Messages) do
  begin
    JMsg := TJSONObject.Create;
    JMsg.Add('role', RoleName(Req.Messages[i].Role));
    JMsg.Add('content', Req.Messages[i].Content);
    JMsgs.Add(JMsg);
  end;
  J.Add('messages', JMsgs);

  { optional: system }
  if Req.System <> '' then
    J.Add('system', Req.System);

  { optional: stream }
  if Req.Stream then
    J.Add('stream', True);

  { optional: sampling params }
  if Req.Temperature > 0 then
    J.Add('temperature', Req.Temperature);
  if Req.TopP > 0 then
    J.Add('top_p', Req.TopP);
  if Req.TopK > 0 then
    J.Add('top_k', Req.TopK);

  { optional: stop_sequences }
  if Length(Req.StopSequences) > 0 then
  begin
    JStopSeqs := TJSONArray.Create;
    for i := 0 to High(Req.StopSequences) do
      JStopSeqs.Add(Req.StopSequences[i]);
    J.Add('stop_sequences', JStopSeqs);
  end;

  { optional: tools }
  if (Req.Tools <> nil) and (Req.Tools.Count > 0) then
    J.Add('tools', Req.Tools);

  { optional: tool_choice }
  if Req.ToolChoice <> nil then
    J.Add('tool_choice', Req.ToolChoice);

  { optional: metadata }
  if Req.Metadata <> nil then
    J.Add('metadata', Req.Metadata);

  Result := J;
end;

{--- ParseResponse ---}

function ParseResponse(const D: TJSONData): TAnthropicResponse;
var
  i: Integer;
  JBlocks: TJSONData;
  JBlock: TJSONData;
  JInput: TJSONData;
begin
  Result := Default(TAnthropicResponse);
  Result.Id           := JStr(D, 'id', '');
  Result.MsgType       := JStr(D, 'type', 'message');
  Result.Role         := JStr(D, 'role', 'assistant');
  Result.Model        := JStr(D, 'model', '');
  Result.StopReason   := JStr(D, 'stop_reason', '');
  Result.StopSequence := JStr(D, 'stop_sequence', '');
  Result.ServiceTier  := JStr(D, 'service_tier', '');

  JBlocks := D.FindPath('content');
  if (JBlocks <> nil) and (JBlocks is TJSONArray) then
  begin
    SetLength(Result.Content, JBlocks.Count);
    for i := 0 to JBlocks.Count - 1 do
    begin
      JBlock := JBlocks.Items[i];
      Result.Content[i].BlockType := abtUnknown;
      case JStr(JBlock, 'type', '') of
        'text': begin
          Result.Content[i].BlockType := abtText;
          Result.Content[i].Text := JStr(JBlock, 'text', '');
        end;
        'tool_use': begin
          Result.Content[i].BlockType := abtToolUse;
          Result.Content[i].ToolId := JStr(JBlock, 'id', '');
          Result.Content[i].ToolName := JStr(JBlock, 'name', '');
          JInput := JBlock.FindPath('input');
          if JInput <> nil then
            Result.Content[i].ToolInput := JInput.AsJSON;
        end;
        'thinking': begin
          Result.Content[i].BlockType := abtThinking;
          Result.Content[i].Thinking := JStr(JBlock, 'thinking', '');
          Result.Content[i].Signature := JStr(JBlock, 'signature', '');
        end;
      end;
    end;
  end;

  Result.Usage.InputTokens := JInt(D, 'usage.input_tokens', 0);
  Result.Usage.OutputTokens := JInt(D, 'usage.output_tokens', 0);
  Result.Usage.CacheCreationInputTokens := JInt(D, 'usage.cache_creation_input_tokens', 0);
  Result.Usage.CacheReadInputTokens := JInt(D, 'usage.cache_read_input_tokens', 0);
end;

{--- AnthropicResponseText ---}

function AnthropicResponseText(const R: TAnthropicResponse): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(R.Content) do
    if R.Content[i].BlockType = abtText then
    begin
      if Result <> '' then
        Result := Result + #10;
      Result := Result + R.Content[i].Text;
    end;
end;
{--- Ошибки Anthropic API ---}

{ Тип ошибки Anthropic по HTTP-статусу (когда тело не дало свой тип). }
function ErrorTypeFromStatus(AStatusCode: Integer): string;
begin
  case AStatusCode of
    400: Result := 'invalid_request_error';
    401: Result := 'authentication_error';
    403: Result := 'permission_error';
    404: Result := 'not_found_error';
    429: Result := 'rate_limit_error';
  else
    Result := 'api_error';
  end;
end;

{ Человекочитаемое сообщение по HTTP-статусу (когда тело не дало своё). }
function ErrorMessageFromStatus(AStatusCode: Integer): string;
begin
  case AStatusCode of
    400: Result := 'некорректный запрос (400)';
    401: Result := 'неверный API-ключ (401)';
    403: Result := 'недостаточно прав (403)';
    404: Result := 'не найдено (404)';
    429: Result := 'превышен лимит запросов (429)';
  else
    if AStatusCode >= 500 then
      Result := Format('ошибка сервера Anthropic (%d)', [AStatusCode])
    else
      Result := Format('ошибка Anthropic (%d)', [AStatusCode]);
  end;
end;

function ParseError(const D: TJSONData; AStatusCode: Integer): TAnthropicError;
var
  ErrD: TJSONData;
  EType, EMsg: string;
begin
  Result.ErrorType  := '';
  Result.Message    := '';
  Result.StatusCode := AStatusCode;
  Result.Retryable  := (AStatusCode = 429) or (AStatusCode >= 500);

  { Anthropic: type "error" и объект error с полями type и message. }
  ErrD := nil;
  if (D <> nil) and (D is TJSONObject) then
    ErrD := D.FindPath('error');
  if (ErrD <> nil) and (ErrD is TJSONObject) then
  begin
    EType := JStr(ErrD, 'type', '');
    EMsg  := JStr(ErrD, 'message', '');
    if EType <> '' then
      Result.ErrorType := EType;
    if EMsg <> '' then
      Result.Message := EMsg;
  end;

  { Тело не дало тип/сообщение — выводим из HTTP-статуса. }
  if Result.ErrorType = '' then
    Result.ErrorType := ErrorTypeFromStatus(AStatusCode);
  if Result.Message = '' then
    Result.Message := ErrorMessageFromStatus(AStatusCode);
end;

function BuildErrorJson(const E: TAnthropicError): TJSONObject;
var
  JErr: TJSONObject;
begin
  JErr := TJSONObject.Create;
  JErr.Add('type', E.ErrorType);
  JErr.Add('message', E.Message);
  JErr.Add('status', E.StatusCode);
  JErr.Add('retryable', E.Retryable);

  Result := TJSONObject.Create;
  Result.Add('type', 'error');
  Result.Add('error', JErr);
end;

function AnthropicErrorText(const E: TAnthropicError): string;
begin
  Result := Format('Anthropic API: %s (HTTP %d)', [E.Message, E.StatusCode]);
  if E.ErrorType <> '' then
    Result := Result + ' [' + E.ErrorType + ']';
  if E.Retryable then
    Result := Result + ' (можно повторить)';
end;
{--- TAnthropicValidator (middleware валидации входных параметров) ---}

class function TAnthropicValidator.JoinErrors(const Errors: TAnthropicValidationErrors): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Errors) do
  begin
    if i > 0 then
      Result := Result + '; ';
    Result := Result + Errors[i];
  end;
end;

function TAnthropicValidator.Validate(const Req: TAnthropicRequest;
  out Errors: TAnthropicValidationErrors): Boolean;
var
  i: Integer;
  PrevRole: TMessageRole;
  HasPrev: Boolean;
begin
  SetLength(Errors, 0);
  Result := True;

  { model: обязательное поле. }
  if Trim(Req.Model) = '' then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] := 'model: обязательное поле не задано';
    Result := False;
  end;

  { max_tokens: обязательное, положительное. }
  if Req.MaxTokens <= 0 then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('max_tokens: должно быть положительным (получено %d)', [Req.MaxTokens]);
    Result := False;
  end;

  { messages: обязательный непустой массив. }
  if Length(Req.Messages) = 0 then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] := 'messages: обязательное поле, массив не может быть пустым';
    Result := False;
  end
  else
  begin
    HasPrev := False;
    PrevRole := mrUser;
    for i := 0 to High(Req.Messages) do
    begin
      { system-роль не допускается в messages (идёт в поле system). }
      if Req.Messages[i].Role = mrSystem then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: роль "system" не допускается в messages (используйте поле system)', [i]);
        Result := False;
      end;

      { tool-роль не поддерживается (content — строка). }
      if Req.Messages[i].Role = mrTool then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: роль "tool" не поддерживается', [i]);
        Result := False;
      end;

      { пустой контент. }
      if Trim(Req.Messages[i].Content) = '' then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: content не может быть пустым', [i]);
        Result := False;
      end;

      { первое сообщение — от user. }
      if (i = 0) and (Req.Messages[i].Role <> mrUser) then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] := 'messages[0]: первое сообщение должно быть от user';
        Result := False;
      end;

      { чередование ролей user/assistant. }
      if HasPrev and (Req.Messages[i].Role = PrevRole) then
      begin
        SetLength(Errors, Length(Errors) + 1);
        Errors[High(Errors)] :=
          Format('messages[%d]: роли должны чередоваться (user/assistant)', [i]);
        Result := False;
      end;

      PrevRole := Req.Messages[i].Role;
      HasPrev := True;
    end;
  end;

  { temperature: 0..1. }
  if (Req.Temperature > 0) and (Req.Temperature > 1) then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('temperature: должно быть в диапазоне 0..1 (получено %s)', [FloatToStr(Req.Temperature)]);
    Result := False;
  end;

  { top_p: 0..1. }
  if (Req.TopP > 0) and (Req.TopP > 1) then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('top_p: должно быть в диапазоне 0..1 (получено %s)', [FloatToStr(Req.TopP)]);
    Result := False;
  end;

  { top_k: >= 0. }
  if Req.TopK < 0 then
  begin
    SetLength(Errors, Length(Errors) + 1);
    Errors[High(Errors)] :=
      Format('top_k: должно быть неотрицательным (получено %d)', [Req.TopK]);
    Result := False;
  end;
end;

{--- TAnthropicSSEAccumulator ---}

constructor TAnthropicSSEAccumulator.Create;
begin
  inherited Create;
  FLineBuf := '';
  FDone := False;
end;

destructor TAnthropicSSEAccumulator.Destroy;
begin
  FBlocks := nil;
  inherited Destroy;
end;

procedure TAnthropicSSEAccumulator.Reset;
begin
  FBlocks := nil;
  FStopReason := '';
  FStopSequence := '';
  FUsage := Default(TAnthropicUsage);
  FModel := '';
  FId := '';
  FDone := False;
  FLineBuf := '';
end;

procedure TAnthropicSSEAccumulator.HandleEvent(const D: TJSONData);
var
  EType: string;
  JMsg, JDelta, JBlock: TJSONData;
  i: Integer;
  LastIdx: Integer;
begin
  EType := JStr(D, 'type', '');
  case EType of
    'message_start':
    begin
      JMsg := D.FindPath('message');
      if JMsg <> nil then
      begin
        FId := JStr(JMsg, 'id', '');
        FModel := JStr(JMsg, 'model', '');
        FUsage.InputTokens := JInt(JMsg, 'usage.input_tokens', 0);
        FUsage.CacheCreationInputTokens := JInt(JMsg, 'usage.cache_creation_input_tokens', 0);
        FUsage.CacheReadInputTokens := JInt(JMsg, 'usage.cache_read_input_tokens', 0);
      end;
    end;
    'content_block_start':
    begin
      { Новый блок контента: text, tool_use или thinking. }
      SetLength(FBlocks, Length(FBlocks) + 1);
      LastIdx := Length(FBlocks) - 1;
      FBlocks[LastIdx].BlockType := abtUnknown;
      JBlock := D.FindPath('content_block');
      if JBlock <> nil then
      begin
        case JStr(JBlock, 'type', '') of
          'text':
            FBlocks[LastIdx].BlockType := abtText;
          'tool_use':
          begin
            FBlocks[LastIdx].BlockType := abtToolUse;
            FBlocks[LastIdx].ToolId := JStr(JBlock, 'id', '');
            FBlocks[LastIdx].ToolName := JStr(JBlock, 'name', '');
          end;
          'thinking':
            FBlocks[LastIdx].BlockType := abtThinking;
        end;
      end;
    end;
    'content_block_delta':
    begin
      JDelta := D.FindPath('delta');
      if JDelta <> nil then
      begin
        LastIdx := Length(FBlocks) - 1;
        case JStr(JDelta, 'type', '') of
          'text_delta':
            begin
              if LastIdx >= 0 then
                FBlocks[LastIdx].Text := FBlocks[LastIdx].Text + JStr(JDelta, 'text', '');
              if FOnDelta <> nil then
                FOnDelta(JStr(JDelta, 'text', ''), '');
            end;
          'input_json_delta':
            { Аргументы tool_use приходят фрагментами JSON. }
            if LastIdx >= 0 then
              FBlocks[LastIdx].ToolInput :=
                FBlocks[LastIdx].ToolInput + JStr(JDelta, 'partial_json', '');
          'thinking_delta':
            if LastIdx >= 0 then
              FBlocks[LastIdx].Thinking :=
                FBlocks[LastIdx].Thinking + JStr(JDelta, 'thinking', '');
        end;
      end;
    end;
    'content_block_stop':
      ;   { блок завершён — данные уже накоплены }
    'message_delta':
    begin
      JDelta := D.FindPath('delta');
      if JDelta <> nil then
      begin
        FStopReason := JStr(JDelta, 'stop_reason', '');
        FStopSequence := JStr(JDelta, 'stop_sequence', '');
      end;
      FUsage.OutputTokens := JInt(D, 'usage.output_tokens', 0);
    end;
    'message_stop':
      FDone := True;
  end;
end;

function TAnthropicSSEAccumulator.FeedLine(const Line: string): Boolean;
var
  D: TJSONData;
  S: string;
begin
  Result := True;
  S := Line;
  if S = '' then Exit;
  if Copy(S, 1, 5) = 'data:' then
    Delete(S, 1, 5);
  S := Trim(S);
  if S = '' then Exit;
  try
    D := GetJSON(S);
    if D <> nil then
    begin
      HandleEvent(D);
      D.Free;
    end;
  except
    { повреждённый чанк — пропускаем }
  end;
  Result := not FDone;
end;

function TAnthropicSSEAccumulator.FeedChunk(const Chunk: RawByteString): Boolean;
var
  P: Integer;
  Line: string;
begin
  FLineBuf := FLineBuf + Chunk;
  Result := True;
  while True do
  begin
    P := Pos(#10, FLineBuf);
    if P = 0 then Break;
    Line := Copy(FLineBuf, 1, P - 1);
    Delete(FLineBuf, 1, P);
    if not FeedLine(Line) then
    begin
      Result := False;
      Break;
    end;
  end;
end;

function TAnthropicSSEAccumulator.Flush: Boolean;
begin
  Result := FeedLine(FLineBuf);
  FLineBuf := '';
end;

procedure TAnthropicSSEAccumulator.Collect(out Resp: TAnthropicResponse);
begin
  Resp := Default(TAnthropicResponse);
  Resp.Id := FId;
  Resp.MsgType := 'message';
  Resp.Role := 'assistant';
  Resp.Model := FModel;
  Resp.StopReason := FStopReason;
  Resp.StopSequence := FStopSequence;
  Resp.Usage := FUsage;
  Resp.Content := FBlocks;
end;

{--- TAnthropicClient ---}

constructor TAnthropicClient.Create(const AApiKey, ABaseUrl: string);
begin
  inherited Create;
  FApiKey := AApiKey;
  if ABaseUrl = '' then
    FBaseUrl := 'https://api.anthropic.com'
  else
    FBaseUrl := ABaseUrl;
  FRequestTimeout := 1800000;
  FConnectTimeout := 10000;
  FAcc := TAnthropicSSEAccumulator.Create;
  FValidator := TAnthropicValidator.Create;
end;

destructor TAnthropicClient.Destroy;
begin
  FAcc.Free;
  FValidator.Free;
  inherited Destroy;
end;
function TAnthropicClient.ValidateRequest(const Req: TAnthropicRequest;
  out Err: string; out ErrJson: TJSONData): Boolean;
var
  VErrors: TAnthropicValidationErrors;
  AE: TAnthropicError;
begin
  Err := '';
  ErrJson := nil;
  SetLength(VErrors, 0);
  if FValidator.Validate(Req, VErrors) then
  begin
    Result := True;
    Exit;
  end;
  AE.ErrorType  := 'invalid_request_error';
  AE.Message    := TAnthropicValidator.JoinErrors(VErrors);
  AE.StatusCode := 400;
  AE.Retryable  := False;
  Err := AnthropicErrorText(AE);
  ErrJson := BuildErrorJson(AE);
  Result := False;
end;

function TAnthropicClient.SendMessages(const Req: TAnthropicRequest;
  out Resp: TAnthropicResponse; out Err: string;
  out ErrJson: TJSONData): Boolean;
var
  Body: TJSONData;
  BodyStr, Url: string;
  HR: THttpResult;
  D, ErrD: TJSONData;
  AE: TAnthropicError;
  Headers: array[0..3] of string;
begin
  Result := False;
  Err := '';
  ErrJson := nil;
  Resp := Default(TAnthropicResponse);
  { Middleware: валидация входных параметров до обращения к сети. }
  if not ValidateRequest(Req, Err, ErrJson) then
    Exit;

  { Тело запроса строится из модели TAnthropicRequest (шаг 2). }
  Body := BuildRequestJson(Req);
  try
    BodyStr := Body.AsJSON;
  finally
    Body.Free;
  end;

  { Эндпоинт Anthropic Messages API: POST <base>/v1/messages.
    Anthropic использует x-api-key (не Authorization: Bearer) и
    требует заголовок anthropic-version. }
  Url := JoinUrl(FBaseUrl, '/v1/messages');
  Headers[0] := 'Content-Type: application/json; charset=utf-8';
  Headers[1] := 'Accept: application/json';
  Headers[2] := 'x-api-key: ' + FApiKey;
  Headers[3] := 'anthropic-version: ' + ANTHROPIC_API_VERSION;
  HR := HttpRequestEx('POST', Url, BodyStr, Headers,
    FRequestTimeout, FConnectTimeout);

  { Не-2xx или сбой соединения: разбираем JSON-ошибку Anthropic и
    возвращаем её (401 — неверный ключ, 429 — лимит, 500 — сервер). }
  if not HR.Ok then
  begin
    D := nil;
    if HR.StatusCode = 0 then
    begin
      { Соединение не установлено: HTTP-ответа нет, статус 0. }
      AE.ErrorType  := 'connection_error';
      AE.Message    := Trim(HR.Error);
      AE.StatusCode := 0;
      AE.Retryable  := True;
    end
    else
    begin
      if Trim(HR.Body) <> '' then
        ParseJSON(HR.Body, D, Err);
      AE := ParseError(D, HR.StatusCode);
    end;
    if D <> nil then
      D.Free;
    Err := AnthropicErrorText(AE);
    ErrJson := BuildErrorJson(AE);
    Exit;
  end;

  if not ParseJSON(HR.Body, D, Err) then
  begin
    Err := 'не удалось разобрать ответ API: ' + Err;
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      Err := 'ответ API не является JSON-объектом';
      Exit;
    end;
    { Anthropic возвращает ошибки как type "error" и объект error (type, message). }
    ErrD := D.FindPath('error');
    if (ErrD <> nil) and (not (ErrD is TJSONNull)) then
    begin
      AE := ParseError(D, HR.StatusCode);
      Err := AnthropicErrorText(AE);
      ErrJson := BuildErrorJson(AE);
      Exit;
    end;
    Resp := ParseResponse(D);
    Result := True;
  finally
    D.Free;
  end;
end;

function TAnthropicClient.SendMessagesStream(const Req: TAnthropicRequest;
  const OnDelta: TAnthropicDeltaHandler;
  out Resp: TAnthropicResponse; out Err: string;
  out ErrJson: TJSONData): Boolean;
var
  Body: TJSONData;
  BodyStr, Url: string;
  Code: Integer;
  StatusText: string;
  Headers: array[0..3] of string;
  AE: TAnthropicError;
  D: TJSONData;
  ErrBody: string;
  P: Integer;
begin
  Result := False;
  Err := '';
  ErrJson := nil;
  Resp := Default(TAnthropicResponse);
  { Middleware: валидация входных параметров до обращения к сети. }
  if not ValidateRequest(Req, Err, ErrJson) then
    Exit;

  FAcc.Reset;
  FAcc.OnDelta := OnDelta;

  Body := BuildRequestJson(Req);
  try
    BodyStr := Body.AsJSON;
  finally
    Body.Free;
  end;

  Url := JoinUrl(FBaseUrl, '/v1/messages');
  Headers[0] := 'Content-Type: application/json; charset=utf-8';
  Headers[1] := 'x-api-key: ' + FApiKey;
  Headers[2] := 'anthropic-version: ' + ANTHROPIC_API_VERSION;

  if not HttpRequestStreamEx('POST', Url, BodyStr, Headers,
    FRequestTimeout, FConnectTimeout, @SSEChunk, Code, StatusText, Err) then
  begin
    { Ошибка соединения или не-2xx статус: разбираем JSON-ошибку. }
    if Code = 0 then
    begin
      AE.ErrorType  := 'connection_error';
      AE.Message    := Trim(Err);
      AE.StatusCode := 0;
      AE.Retryable  := True;
    end
    else
    begin
      { Err содержит "HTTP <status> <text>\n<body>" — извлекаем JSON-тело. }
      ErrBody := Err;
      P := Pos('{', ErrBody);
      if P > 0 then
        ErrBody := Copy(ErrBody, P, MaxInt);
      D := nil;
      if Trim(ErrBody) <> '' then
        ParseJSON(ErrBody, D, Err);
      AE := ParseError(D, Code);
      if D <> nil then
        D.Free;
    end;
    Err := AnthropicErrorText(AE);
    ErrJson := BuildErrorJson(AE);
    Exit;
  end;

  { Таймаут в середине потока: 2xx-статус получен, но Err заполнен. }
  if Err <> '' then
    Exit(False);

  { Последняя строка может не иметь завершающего перевода строки. }
  FAcc.Flush;
  if not FAcc.Done then
  begin
    Err := 'соединение с сервером разорвано до завершения ответа (не получен message_stop)';
    Exit(False);
  end;
  FAcc.Collect(Resp);
  Result := True;
end;

function TAnthropicClient.SSEChunk(const Chunk: RawByteString): Boolean;
begin
  Result := FAcc.FeedChunk(Chunk);
end;

end.
