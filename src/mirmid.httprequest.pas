unit mirmid.httprequest;
{ Инструмент http_request: доступ к сайтам по HTTP-протоколу (GET/POST).
  По умолчанию выключен: включается ключом http_request=1 в секции [tools] INI
  (см. mirmid.tools) и только тогда попадает в набор инструментов сессии. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools;

const
  HTTP_TOOL_NAME = 'http_request';
  { Сколько байт тела ответа показывать модели (больше — обрезается). }
  MAX_HTTP_BODY = 100000;

{ Регистрирует инструмент http_request в реестре. }
procedure RegisterHttpTool(R: TToolRegistry);

implementation

uses
  SysUtils, fpjson, mirmid.types, mirmid.http, mirmid.json;

function ToolHttpRequest(const A: TJSONObject; const Ctx: TToolContext): TToolOutcome;
var
  Url, Method, Body, Out2: string;
  TimeoutSec, TimeoutMs: Integer;
  HR: THttpResult;
begin
  { Гейт в обработчике: набор инструментов фильтруется при регистрации, но
    субагенты, шаги плана и прямой вызов обработчика обходят её. }
  if not ToolEnabled(Ctx.Cfg, HTTP_TOOL_NAME) then
    Exit(ToolDisabled(HTTP_TOOL_NAME));

  Url := Trim(JStr(A, 'url', ''));
  if Url = '' then
    Exit(ErrResult('не задан url'));

  Method := UpperCase(Trim(JStr(A, 'method', 'GET')));
  if (Method <> 'GET') and (Method <> 'POST') then
    Exit(ErrResult('метод должен быть GET или POST'));

  Body := JStr(A, 'body', '');

  TimeoutSec := JInt(A, 'timeout', 0);
  if TimeoutSec > 0 then
    TimeoutMs := TimeoutSec * 1000
  else
    TimeoutMs := Ctx.Cfg.RequestTimeout;

  HR := HttpRequest(Method, Url, '', Body, TimeoutMs, Ctx.Cfg.ConnectTimeout);
  if HR.StatusCode = 0 then
    Exit(ErrResult(HR.Error));

  Out2 := Format('HTTP %d', [HR.StatusCode]);
  if Trim(HR.StatusText) <> '' then
    Out2 := Out2 + ' ' + Trim(HR.StatusText);
  if Length(HR.Body) > MAX_HTTP_BODY then
  begin
    Out2 := Out2 + sLineBreak + Copy(HR.Body, 1, MAX_HTTP_BODY) + sLineBreak +
      Format('[… обрезано: показано %d из %d байт]', [MAX_HTTP_BODY, Length(HR.Body)]);
  end
  else if HR.Body <> '' then
    Out2 := Out2 + sLineBreak + HR.Body;

  Result := OkResult(Out2);
end;

procedure RegisterHttpTool(R: TToolRegistry);
begin
  R.Add(HTTP_TOOL_NAME,
    'Выполняет HTTP-запрос к сайту и возвращает статус и тело ответа.',
    SchemaObject(
      TJSONObject.Create([
        'url', PropStr('Полный URL (http:// или https://)'),
        'method', PropStr('Метод: GET или POST (по умолчанию GET)'),
        'body', PropStr('Тело запроса для POST'),
        'timeout', PropInt('Таймаут в секундах (по умолчанию — из конфигурации)')]),
      ['url']),
    @ToolHttpRequest);
end;

end.
