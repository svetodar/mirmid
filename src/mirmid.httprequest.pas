unit mirmid.httprequest;
{ The http_request tool: access to sites over the HTTP protocol (GET/POST).
  Disabled by default: it is enabled by the http_request=1 key in the [tools]
  section of the INI file (see mirmid.tools) and only then gets into the session
  tool set. }

{$mode objfpc}{$H+}

interface

uses
  mirmid.tools;

const
  HTTP_TOOL_NAME = 'http_request';
  { How many bytes of the response body to show the model (more is truncated). }
  MAX_HTTP_BODY = 100000;

{ Registers the http_request tool in the registry. }
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
  { Handler gate: the tool set is filtered at registration, but subagents,
    plan steps and a direct handler call bypass that filter. }
  if not ToolEnabled(Ctx.Cfg, HTTP_TOOL_NAME) then
    Exit(ToolDisabled(HTTP_TOOL_NAME));

  Url := Trim(JStr(A, 'url', ''));
  if Url = '' then
    Exit(ErrResult('url is not set'));

  Method := UpperCase(Trim(JStr(A, 'method', 'GET')));
  if (Method <> 'GET') and (Method <> 'POST') then
    Exit(ErrResult('method must be GET or POST'));

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
      Format('[... truncated: %d of %d bytes shown]', [MAX_HTTP_BODY, Length(HR.Body)]);
  end
  else if HR.Body <> '' then
    Out2 := Out2 + sLineBreak + HR.Body;

  Result := OkResult(Out2);
end;

procedure RegisterHttpTool(R: TToolRegistry);
begin
  R.Add(HTTP_TOOL_NAME,
    'Performs an HTTP request to a site and returns the status and the response body.',
    SchemaObject(
      TJSONObject.Create([
        'url', PropStr('Full URL (http:// or https://)'),
        'method', PropStr('Method: GET or POST (default GET)'),
        'body', PropStr('Request body for POST'),
        'timeout', PropInt('Timeout in seconds (default — from the configuration)')]),
      ['url']),
    @ToolHttpRequest);
end;

end.
