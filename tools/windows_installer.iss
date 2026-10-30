; Build with tools/build_windows_installer.ps1.
#ifndef BundleDir
  #error BundleDir must point to the staged Windows release.
#endif

[Setup]
AppId={{B20BE21D-731B-4DE3-9574-4495880285C0}
AppName=Hopboard
AppVersion={#AppVersion}
AppPublisher=Hopboard
VersionInfoVersion={#FileVersion}
DefaultDirName={localappdata}\Programs\LocalClipboard
DefaultGroupName=Hopboard
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Hopboard-Setup-{#AppVersion}-x64
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\local_clipboard.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
AppMutex=Local\LocalClipboard.v1
CloseApplications=no
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: desktopicon; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Hopboard"; Filename: "{app}\local_clipboard.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Hopboard"; Filename: "{app}\local_clipboard.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\local_clipboard.exe"; WorkingDir: "{app}"; Description: "Open Hopboard"; Flags: nowait postinstall skipifsilent

[Messages]
SetupAppRunningError=Hopboard is running. Choose Quit from its system tray menu, then click OK to continue. Closing its window keeps it running.
UninstallAppRunningError=Hopboard is running. Choose Quit from its system tray menu, then click OK to continue.

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Hopboard\Received"
