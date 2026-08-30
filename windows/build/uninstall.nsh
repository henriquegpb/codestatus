; Removes CodeStatus's hook entries before the files go.
;
; Deleting the app on its own would leave the entries behind in
; ~/.claude/settings.json, pointing at a shim that no longer exists. Claude Code
; would then try to run a missing file on every tool call — an error per event,
; from an app the user believes they have removed. The macOS build has the same
; problem and solves it the same way, from inside the app.
;
; Runs before the files are deleted, so the executable is still there. Given
; five seconds and then abandoned: an uninstall must not hang because a
; JSON file was locked, and the hook entries failing quietly is a far smaller
; problem than an uninstaller that never finishes.
!macro customUnInstall
  ${ifNot} ${isUpdated}
    nsExec::ExecToStack /TIMEOUT=5000 '"$INSTDIR\CodeStatus.exe" --uninstall-hooks'
    Pop $0
  ${endIf}
!macroend
