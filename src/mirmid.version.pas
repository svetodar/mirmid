unit mirmid.version;
{ Single place for the program name and version. }

{$mode objfpc}{$H+}

interface

const
  MIRMID_NAME    = 'mirmid';
  MIRMID_VERSION = '0.1.0';

{ A string such as "mirmid 0.1.0" for --version. }
function FullVersion: string;

implementation

function FullVersion: string;
begin
  Result := MIRMID_NAME + ' ' + MIRMID_VERSION;
end;

end.
