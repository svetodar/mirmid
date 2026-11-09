program fakemcp;
{ Minimal MCP server for the mirmid integration tests.
  stdio transport: JSON-RPC 2.0, one object per line.
  Tools: echo (returns the text), boom (isError), fail (JSON-RPC error). }

{$mode objfpc}{$H+}

uses
  SysUtils, fpjson, jsonparser;

function SVal(D: TJSONData; const Path, Def: string): string;
var
  X: TJSONData;
begin
  Result := Def;
  X := D.FindPath(Path);
  if (X <> nil) and not (X is TJSONNull) then
    Result := X.AsString;
end;

function IVal(D: TJSONData; const Path: string; Def: Integer): Integer;
var
  X: TJSONData;
begin
  Result := Def;
  X := D.FindPath(Path);
  if (X <> nil) and (X is TJSONNumber) then
    Result := X.AsInteger;
end;

function ToolSchema(const PropName: string): TJSONObject;
var
  Props: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'object');
  Props := TJSONObject.Create;
  if PropName <> '' then
    Props.Add(PropName, TJSONObject.Create(['type', 'string']));
  Result.Add('properties', Props);
end;

function TextContent(const S: string; IsErr: Boolean): TJSONObject;
var
  Arr: TJSONArray;
  Item: TJSONObject;
begin
  Arr := TJSONArray.Create;
  Item := TJSONObject.Create;
  Item.Add('type', 'text');
  Item.Add('text', S);
  Arr.Add(Item);
  Result := TJSONObject.Create;
  Result.Add('content', Arr);
  if IsErr then
    Result.Add('isError', True);
end;

function ToolsResult: TJSONObject;
var
  Arr: TJSONArray;
  O: TJSONObject;
begin
  Arr := TJSONArray.Create;
  O := TJSONObject.Create;
  O := TJSONObject.Create;
  O.Add('name', 'echo');
  O.Add('description', 'Echo text back');
  O.Add('inputSchema', ToolSchema('text'));
  Arr.Add(O);

  O := TJSONObject.Create;
  O.Add('name', 'boom');
  O.Add('description', 'Always returns tool error');
  O.Add('inputSchema', ToolSchema(''));
  Arr.Add(O);

  O := TJSONObject.Create;
  O.Add('name', 'fail');
  O.Add('description', 'Returns JSON-RPC error');
  O.Add('inputSchema', ToolSchema(''));
  Arr.Add(O);

  Result := TJSONObject.Create;
  Result.Add('tools', Arr);
end;

function ErrorObject(Code: Integer; const Msg: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('code', Code);
  Result.Add('message', Msg);
end;

var
  Line, Method, TName: string;
  D: TJSONData;
  O, Res: TJSONObject;
  Id: Integer;

begin
  DefaultSystemCodePage := CP_UTF8;
  Line := '';
  while not EOF(Input) do
  begin
    ReadLn(Line);
    if Trim(Line) = '' then
      Continue;
    D := nil;
    try
      try
        D := GetJSON(Line);
      except
        Continue;
      end;
      Method := SVal(D, 'method', '');
      if Method = 'notifications/initialized' then
        Continue;
      Id := IVal(D, 'id', -1);

      O := TJSONObject.Create;
      O.Add('jsonrpc', '2.0');
      O.Add('id', Id);

      if Method = 'initialize' then
      begin
        Res := TJSONObject.Create;
        Res.Add('protocolVersion', '2024-11-05');
        Res.Add('capabilities', TJSONObject.Create);
        Res.Add('serverInfo', TJSONObject.Create(['name', 'fake', 'version', '1.0']));
        O.Add('result', Res);
      end
      else if Method = 'tools/list' then
        O.Add('result', ToolsResult)
      else if Method = 'tools/call' then
      begin
        TName := SVal(D, 'params.name', '');
        if TName = 'fail' then
          O.Add('error', ErrorObject(-32603, 'internal server error'))
        else if TName = 'echo' then
          O.Add('result', TextContent(SVal(D, 'params.arguments.text', ''), False))
        else if TName = 'boom' then
          O.Add('result', TextContent('tool failed', True))
        else
          O.Add('result', TextContent('unknown tool', True));
      end
      else
        O.Add('error', ErrorObject(-32601, 'method not found'));

      Write(O.AsJSON);
      Write(#10);
      Flush(Output);
      O.Free;
    finally
      D.Free;
    end;
  end;
end.
