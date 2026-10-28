; Sharp's Windows installer, built by release.sh with NSIS 3. Like T3
; Code's (electron-builder's one-click NSIS): no wizard, no admin rights,
; installed for the current user in %LOCALAPPDATA%\Programs\Sharp, then
; started. The updater runs it with /S (silent), and /relaunch to start
; Sharp again; a silent run waits for the running Sharp to quit first.
;
; makensis -DVERSION=0.1.1 -DVERSION4=0.1.1.0 -DSTAGE=<payload> -DOUTFILE=<exe> installer.nsi

!ifndef VERSION | VERSION4 | STAGE | OUTFILE
  !error "release.sh passes VERSION, VERSION4, STAGE and OUTFILE"
!endif

Unicode true
SetCompressor /SOLID lzma
RequestExecutionLevel user
ManifestDPIAware true

!define APP "Sharp"
!define PUBLISHER "Sharp"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sharp"
!define URL "https://github.com/tinuxongit/sharp-terminal"

Name "${APP}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP}"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
Icon "sharp.ico"
UninstallIcon "sharp.ico"
BrandingText "${APP} ${VERSION}"
ShowInstDetails nevershow
ShowUninstDetails nevershow
AutoCloseWindow true

VIProductVersion "${VERSION4}"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APP} installer"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "LegalCopyright" "MIT License"

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define MUI_ICON "sharp.ico"
!define MUI_UNICON "sharp.ico"
!define MUI_INSTFILESPAGE_COLORS "FFFFFF 1E1E24"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; Wait until Sharp's programs can be replaced: the updater starts this
; installer just before Sharp quits, and Sharp's bridge for Claude Code
; ends once Sharp has. Windows lets a running program be renamed but not
; deleted, so deleting is the test. A silent run gives up after 30 s.
!macro WaitForSharp
  StrCpy $R9 0
  ${Do}
    ClearErrors
    Delete "$INSTDIR\sharp.exe"
    Delete "$INSTDIR\sharp-mcp.exe"
    Delete "$INSTDIR\OpenConsole.exe"
    Delete "$INSTDIR\conpty.dll"
    Delete "$INSTDIR\WebView2Loader.dll"
    Delete "$INSTDIR\OpenConsoleProxy.dll"
    ${IfNot} ${Errors}
      ${ExitDo}
    ${EndIf}
    IntOp $R9 $R9 + 1
    ${If} $R9 >= 60
      ${If} ${Silent}
        Abort
      ${EndIf}
      ${If} ${Cmd} `MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Close Sharp to continue." IDCANCEL`
        Abort
      ${EndIf}
      StrCpy $R9 0
    ${EndIf}
    Sleep 500
  ${Loop}
!macroend

Section "Install"
  SetOutPath "$INSTDIR"
  !insertmacro WaitForSharp
  ; The previous version's resources go, so nothing stale stays behind;
  ; settings and sessions live elsewhere (%LOCALAPPDATA%\ghostty, \Sharp).
  RMDir /r "$INSTDIR\share"
  File /r "${STAGE}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall ${APP}.exe"

  CreateShortCut "$SMPROGRAMS\${APP}.lnk" "$INSTDIR\sharp.exe"
  ; The desktop shortcut comes with a first, interactive install only, so
  ; deleting it sticks across updates.
  ${IfNot} ${Silent}
  ${AndIfNot} ${FileExists} "$DESKTOP\${APP}.lnk"
    CreateShortCut "$DESKTOP\${APP}.lnk" "$INSTDIR\sharp.exe"
  ${EndIf}

  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "${URL}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\sharp.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall ${APP}.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall ${APP}.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" $0
SectionEnd

Function .onInstSuccess
  ; Started after an interactive install, or when the updater asks.
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/relaunch" $1
  ${IfNot} ${Silent}
  ${OrIfNot} ${Errors}
    Exec '"$INSTDIR\sharp.exe"'
  ${EndIf}
FunctionEnd

; Sharp's terminal class (terminal_handoff.zig).
!define SHARP_TERMINAL "{88076DA1-582B-4D00-BB74-1CAB70E0738E}"

; Put back one delegation value as Sharp remembered it, or remove it when
; there was none ("let Windows decide").
!macro RestoreDelegation NAME
  ClearErrors
  ReadRegStr $1 HKCU "Software\Sharp\DefaultTerminal" "${NAME}"
  ${If} ${Errors}
    DeleteRegValue HKCU "Console\%%Startup" "${NAME}"
  ${Else}
    WriteRegStr HKCU "Console\%%Startup" "${NAME}" $1
  ${EndIf}
!macroend

Section "Uninstall"
  !insertmacro WaitForSharp
  ; Claude Code keeps the browser's MCP registration only while Sharp's
  ; setting is on; without Sharp it would point at a missing program.
  nsExec::Exec 'cmd.exe /d /c claude mcp remove --scope user sharp'
  Pop $0
  ; Give Windows back the terminal it had before Sharp was made the
  ; default (src/apprt/win32/default_terminal.zig), unless another was
  ; chosen since, and remove Sharp's registrations.
  ReadRegStr $0 HKCU "Console\%%Startup" "DelegationTerminal"
  ${If} $0 == "${SHARP_TERMINAL}"
    !insertmacro RestoreDelegation "DelegationConsole"
    !insertmacro RestoreDelegation "DelegationTerminal"
  ${EndIf}
  DeleteRegKey HKCU "Software\Sharp\DefaultTerminal"
  DeleteRegKey /ifempty HKCU "Software\Sharp"
  DeleteRegKey HKCU "Software\Classes\CLSID\${SHARP_TERMINAL}"
  DeleteRegKey HKCU "Software\Classes\Interface\{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}"
  DeleteRegKey HKCU "Software\Classes\CLSID\{3171DE52-6EFA-4AEF-8A9F-D02BD67E7A4F}"
  RMDir /r "$INSTDIR\share"
  Delete "$INSTDIR\*.exe"
  Delete "$INSTDIR\*.dll"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\${APP}.lnk"
  Delete "$DESKTOP\${APP}.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
