#ifndef AppVersion
  #error AppVersion must be supplied by package_windows.ps1
#endif
#ifndef SourceDir
  #error SourceDir must be supplied by package_windows.ps1
#endif

[Setup]
; Keep this ID stable so future installers upgrade the same installation.
AppId=CGit.Desktop
AppName=CGit
AppVersion={#AppVersion}
AppPublisher=CGit contributors
AppPublisherURL=https://github.com/Ckales/CGit
DefaultDirName={localappdata}\Programs\CGit
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputBaseFilename=CGit-{#AppVersion}-windows-x64-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\CGit.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\CGit"; Filename: "{app}\CGit.exe"; WorkingDir: "{userdocs}"
Name: "{userdesktop}\CGit"; Filename: "{app}\CGit.exe"; WorkingDir: "{userdocs}"; Tasks: desktopicon

[Run]
Filename: "{app}\CGit.exe"; WorkingDir: "{userdocs}"; Description: "{cm:LaunchProgram,CGit}"; Flags: nowait postinstall skipifsilent
