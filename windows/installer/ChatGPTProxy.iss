#define ProductVersion "2.3.3"
[Setup]
AppId={{ECA2BE54-10F8-4FAE-BC1D-83279668399C}
AppName=ChatGPT Proxy
AppVersion={#ProductVersion}
AppPublisher=ChatGPT Proxy
DefaultDirName={autopf}\ChatGPT Proxy
DisableDirPage=yes
DefaultGroupName=ChatGPT Proxy
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
PrivilegesRequired=admin
OutputDir=..\..\dist
OutputBaseFilename=ChatGPT-Proxy-{#ProductVersion}-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\ChatGPTProxy.App.exe
CloseApplications=no
RestartApplications=no
[Files]
Source: "..\..\build\windows\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "owner.json,*.pdb"
Source: "..\..\scripts\install-windows.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\remove-startup-windows.ps1"; DestDir: "{app}"; Flags: ignoreversion
[Icons]
Name: "{group}\ChatGPT Proxy"; Filename: "{app}\ChatGPTProxy.App.exe"
Name: "{group}\卸载 ChatGPT Proxy"; Filename: "{uninstallexe}"
[Run]
Filename: "{app}\ChatGPTProxy.App.exe"; Description: "打开 ChatGPT Proxy"; Flags: nowait postinstall skipifsilent runasoriginaluser
[Code]
var OwnerSid: String;
function PowerShell: String;
begin Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'); end;
function RestoreAndStop: Boolean;
var Code: Integer;
begin
  Result := True;
  if FileExists(ExpandConstant('{app}\ChatGPTProxy.App.exe')) then begin
    Exec(ExpandConstant('{sys}\sc.exe'), 'start ChatGPTProxy', '', SW_HIDE, ewWaitUntilTerminated, Code);
    if Code = 1060 then begin Result := not FileExists(ExpandConstant('{commonappdata}\ChatGPT Proxy\recovery-v1.json')); Exit; end;
    Sleep(1000);
    Result := Exec(ExpandConstant('{app}\ChatGPTProxy.App.exe'), '--shutdown', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
    if Result then begin
      Exec(ExpandConstant('{sys}\sc.exe'), 'stop ChatGPTProxy', '', SW_HIDE, ewWaitUntilTerminated, Code);
      Sleep(2000);
    end;
  end;
end;
function PrepareToInstall(var NeedsRestart: Boolean): String;
var Code, Index: Integer; Value: AnsiString; Params: String;
begin
  Result := '';
  if not RestoreAndStop then begin Result := '原 DNS 配置恢复失败，已停止升级。请先在启动器中恢复 DNS。'; Exit; end;
  OwnerSid := ExpandConstant('{param:OWNERSID|}');
  if OwnerSid = '' then begin
    Params := '-NoProfile -NonInteractive -Command "[IO.File]::WriteAllText(''' + ExpandConstant('{tmp}\owner-sid.txt') + ''',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"';
    if not ExecAsOriginalUser(PowerShell, Params, '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then begin Result := '无法确认安装用户身份。'; Exit; end;
    if not LoadStringFromFile(ExpandConstant('{tmp}\owner-sid.txt'), Value) then begin Result := '无法读取安装用户身份。'; Exit; end;
    OwnerSid := Trim(String(Value));
  end;
  if Copy(OwnerSid, 1, 4) <> 'S-1-' then begin Result := '安装用户 SID 无效。'; Exit; end;
  for Index := 2 to Length(OwnerSid) do if Pos(OwnerSid[Index], '-0123456789') = 0 then begin Result := '安装用户 SID 无效。'; Exit; end;
end;
procedure CurStepChanged(CurStep: TSetupStep);
var Code: Integer; Params: String;
begin
  if CurStep = ssPostInstall then begin
    Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\install-windows.ps1') + '" -OwnerSid "' + OwnerSid + '" -Source "' + ExpandConstant('{app}') + '"';
    if not Exec(PowerShell, Params, '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then RaiseException('服务安装失败。恢复记录已保留，请重新运行安装程序修复。');
  end;
end;
function InitializeUninstall: Boolean;
var Code: Integer;
begin
  Result := RestoreAndStop;
  if not Result then begin MsgBox('DNS 恢复未完成，卸载已停止。请先恢复 DNS。', mbError, MB_OK); Exit; end;
  Result := Exec(PowerShell, '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\remove-startup-windows.ps1') + '"', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
  if not Result then Exit;
  Result := Exec(ExpandConstant('{sys}\sc.exe'), 'delete ChatGPTProxy', '', SW_HIDE, ewWaitUntilTerminated, Code) and ((Code = 0) or (Code = 1060));
end;
