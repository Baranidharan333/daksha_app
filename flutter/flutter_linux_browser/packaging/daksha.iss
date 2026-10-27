; Inno Setup script for the Windows installer. Run via packaging\build_windows.ps1,
; which passes the version: ISCC /DAppVersion=1.0.0 packaging\daksha.iss
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6E2B7C1A-4D0F-4B8E-9A51-DAC5A0000001}
AppName=daksha
AppVersion={#AppVersion}
AppPublisher=Daksha
DefaultDirName={autopf}\daksha
DefaultGroupName=daksha
UninstallDisplayIcon={app}\daksha.exe
SetupIconFile=..\windows\runner\resources\app_icon.ico
OutputDir=..\build\windows-installer
OutputBaseFilename=daksha_{#AppVersion}_setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\daksha"; Filename: "{app}\daksha.exe"
Name: "{group}\Uninstall daksha"; Filename: "{uninstallexe}"
Name: "{autodesktop}\daksha"; Filename: "{app}\daksha.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\daksha.exe"; Description: "{cm:LaunchProgram,daksha}"; Flags: nowait postinstall skipifsilent
