' Sobe o CodeStatus sem abrir janela de console.
'
' Este e o atalho para o uso normal e para a inicializacao automatica com o
' Windows: o app vive na bandeja, entao uma janela de terminal aberta a sessao
' inteira nao teria proposito.

Dim shell, fso, pasta
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
pasta = fso.GetParentFolderName(WScript.ScriptFullName)

' Ver o comentario em iniciar.cmd: se esta variavel vazar do processo pai, o
' electron.exe roda como Node puro e o app nao sobe.
'
' Remove, nao esvazia: o Electron so olha se a variavel existe, entao deixa-la
' definida como string vazia tem exatamente o mesmo efeito de deixa-la em 1.
On Error Resume Next
shell.Environment("PROCESS").Remove("ELECTRON_RUN_AS_NODE")
On Error Goto 0

shell.CurrentDirectory = pasta
' 0 = janela oculta, False = nao espera terminar
shell.Run """" & pasta & "\node_modules\electron\dist\electron.exe"" """ & pasta & """", 0, False
