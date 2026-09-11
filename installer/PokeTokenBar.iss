; Inno Setup script for the Windows build of PokeTokenBar.
; Per-user install (no admin) to %LOCALAPPDATA%\Programs\PokeTokenBar, Start-menu shortcut (so it is
; searchable), Add/Remove Programs uninstaller, and launch-after-install. Built by scripts via:
;   ISCC /DSrcDir=<portable folder> /DAppVer=<x.y.z.w> /DOutDir=<out> installer\PokeTokenBar.iss
; The three /D defines are required.

#ifndef SrcDir
  #error "Define SrcDir (the portable build folder) with /DSrcDir=..."
#endif
#ifndef AppVer
  #define AppVer "0.0.0.0"
#endif
#ifndef OutDir
  #define OutDir "."
#endif

[Setup]
; A stable AppId keeps upgrades replacing the same install (and one Add/Remove Programs entry).
AppId={{7C1B9F3A-2E4D-4B6A-9C21-PKTKNBARWIN01}}
AppName=PokeTokenBar
AppVersion={#AppVer}
AppPublisher=PokeTokenBar
DefaultDirName={localappdata}\Programs\PokeTokenBar
DefaultGroupName=PokeTokenBar
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename=PokeTokenBar-Setup-{#AppVer}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=PokeTokenBar
UninstallDisplayIcon={app}\PokeTokenBar.exe
; Detect / close a running instance (matches the app's single-instance mutex) so files can be replaced.
AppMutex=Local\PokeTokenBar-SingleInstance
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
; Start-menu shortcut → shows up in Windows Search. Desktop shortcut is opt-in.
Name: "{userprograms}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; Comment: "PokeTokenBar — AI token usage in the tray"
Name: "{userdesktop}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
; Interactive installs offer launch; silent validation/deployment must not start a tray process.
Filename: "{app}\PokeTokenBar.exe"; Description: "Launch PokeTokenBar"; Flags: nowait postinstall skipifsilent

[Code]
var
  WSLPage: TInputOptionWizardPage;
  WSLDistroNames: TStringList;
  WSLSelected: string;

function WSLConfigPath(): string;
begin
  Result := ExpandConstant('{userappdata}\PokeTokenBar\wsl-distro.txt');
end;

function ReadTextFile(const FileName: string): string;
var
  Lines: TArrayOfString;
  Line: string;
  I: Integer;
begin
  Result := '';
  if not FileExists(FileName) then Exit;
  if not LoadStringsFromFile(FileName, Lines) then Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Lines[I];
    { Older wsl.exe builds can write UTF-16-ish output when stdout is redirected. }
    StringChangeEx(Line, #0, '', True);
    if Result <> '' then Result := Result + #10;
    Result := Result + Line;
  end;
  Result := Trim(Result);
end;

function ReadWSLDistros(): TStringList;
var
  TempFile, Raw, Line: string;
  ResultCode, P: Integer;
begin
  Result := TStringList.Create;
  TempFile := ExpandConstant('{tmp}\poketokenbar-wsl-distros.txt');
  DeleteFile(TempFile);
  if not Exec(
    ExpandConstant('{sys}\cmd.exe'),
    '/C ""' + ExpandConstant('{sys}\wsl.exe') + '" --list --quiet > "' + TempFile + '" 2>nul"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then Exit;
  if (ResultCode <> 0) or not FileExists(TempFile) then Exit;
  Raw := ReadTextFile(TempFile);
  StringChangeEx(Raw, #13#10, #10, True);
  StringChangeEx(Raw, #13, #10, True);
  while Raw <> '' do begin
    P := Pos(#10, Raw);
    if P = 0 then begin
      Line := Trim(Raw);
      Raw := '';
    end else begin
      Line := Trim(Copy(Raw, 1, P - 1));
      Delete(Raw, 1, P);
    end;
    while (Length(Line) > 0) and (Line[1] = '*') do begin
      Delete(Line, 1, 1);
      Line := Trim(Line);
    end;
    if (Line <> '') and (Pos('no installed distributions', Lowercase(Line)) = 0) and
       (Result.IndexOf(Line) < 0) then
      Result.Add(Line);
  end;
end;

procedure InitializeWizard;
var
  Existing: string;
  I, ExistingIndex: Integer;
begin
  WSLSelected := ReadTextFile(WSLConfigPath());
  WSLDistroNames := ReadWSLDistros();

  WSLPage := CreateInputOptionPage(
    wpSelectDir,
    'WSL usage data',
    'Choose the WSL distribution to include',
    'PokeTokenBar will read Claude, Codex, and Gemini logs from the selected Linux home. ' +
    'Choose Windows files only if you do not want WSL logs included.',
    True, False);
  WSLPage.Add('Windows files only (do not scan WSL)');
  for I := 0 to WSLDistroNames.Count - 1 do
    WSLPage.Add(WSLDistroNames[I]);

  Existing := WSLSelected;
  ExistingIndex := WSLDistroNames.IndexOf(Existing);
  if (Existing <> '') and (ExistingIndex >= 0) then
    WSLPage.SelectedValueIndex := ExistingIndex + 1
  else
    WSLPage.SelectedValueIndex := 0;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (WSLPage <> nil) and (CurPageID = WSLPage.ID) then begin
    if WSLPage.SelectedValueIndex <= 0 then
      WSLSelected := ''
    else
      WSLSelected := WSLDistroNames[WSLPage.SelectedValueIndex - 1];
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigDir: string;
  Values: TArrayOfString;
begin
  if CurStep <> ssInstall then Exit;
  { Silent upgrades keep the previous selection; interactive installs use the page value. }
  if (WSLPage <> nil) and (WSLPage.SelectedValueIndex >= 0) and not WizardSilent then begin
    if WSLPage.SelectedValueIndex = 0 then
      WSLSelected := ''
    else
      WSLSelected := WSLDistroNames[WSLPage.SelectedValueIndex - 1];
  end;
  ConfigDir := ExpandConstant('{userappdata}\PokeTokenBar');
  ForceDirectories(ConfigDir);
  SetArrayLength(Values, 1);
  Values[0] := WSLSelected;
  SaveStringsToUTF8FileWithoutBOM(WSLConfigPath(), Values, False);
end;
