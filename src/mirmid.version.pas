unit mirmid.version;
{ Центральное место с версией и именем программы. }

{$mode objfpc}{$H+}

interface

const
  MIRMID_NAME    = 'mirmid';
  MIRMID_VERSION = '0.1.0';

{ Строка вида «mirmid 0.1.0» для --version. }
function FullVersion: string;

implementation

function FullVersion: string;
begin
  Result := MIRMID_NAME + ' ' + MIRMID_VERSION;
end;

end.
