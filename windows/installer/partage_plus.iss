; Installeur Windows (setup.exe) de Partage+, compilé avec Inno Setup 6.
;
; 1. flutter build windows --release --dart-define=API_BASE_URL=...
; 2. iscc /DAppVersion=1.0.0 windows\installer\partage_plus.iss
;    → build\installer\partage-plus-setup-1.0.0.exe
;
; En CI : job « windows » de .github/workflows/deploy.yml (tags v*).

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName "Partage+"
#define AppExe "repo_partage_plus.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Identifiant fixe : les nouvelles versions remplacent l'ancienne.
AppId={{8B2E4F61-3C7A-4D19-A5E2-6F0B9C1D7E43}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppName}
DefaultDirName={autopf}\PartagePlus
DefaultGroupName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
OutputDir=..\..\build\installer
OutputBaseFilename=partage-plus-setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Installation pour l'utilisateur courant possible sans droits admin.
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
