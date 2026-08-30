# CodeStatus para Windows

Monitor de sessões do Claude Code que vive na bandeja do sistema. Porte do
[henriquegpb/codestatus](https://github.com/henriquegpb/codestatus), que é um app
nativo de macOS em Swift.

Ele responde uma pergunta só: **alguma sessão está esperando por mim?** O ícone
da bandeja mostra a contagem, e você recebe uma notificação quando uma sessão
passa a precisar de você.

## Instalar em outro computador

**Pré-requisito:** Node.js 18+ ([nodejs.org](https://nodejs.org)). Não é só para
montar o app — cada disparo de hook é um `node hook.js`, então sem Node o app
sobe e fica eternamente vazio. O instalador confere e para com mensagem clara.

Nesta máquina:

```powershell
powershell -ExecutionPolicy Bypass -File empacotar.ps1
```

Gera um `CodeStatus.zip` de ~53 KB na área de trabalho (use `-Destino D:\pendrive`
para mandar direto para outro lugar). No computador novo, descompacte e rode:

```powershell
powershell -ExecutionPolicy Bypass -File instalar.ps1
```

Acrescente `-ComIniciarAutomatico` para que ele suba junto com o Windows.

O instalador confere Node e Claude Code, baixa as dependências, **roda os testes
na máquina de destino** e cria os atalhos no menu iniciar e na área de trabalho.
Ele não toca no seu `settings.json` — conectar os hooks continua sendo uma ação
explícita sua, pelo menu da bandeja.

### Por que o zip é tão pequeno

`node_modules` fica de fora: são ~370 MB, e o binário do Electron é específico de
plataforma e arquitetura — copiá-lo não economiza nada e pode quebrar no destino.
O código-fonte inteiro tem 160 KB.

Um detalhe que o instalador cobre: o `npm install` instala o *pacote* electron,
mas quem baixa o binário é o postinstall dele, que falha com frequência e deixa o
npm seguir como se tivesse dado certo. O script confere e, se faltar, dispara
`node node_modules/electron/install.js` na mão.

## Instalação (esta máquina)

Já está instalado em `C:\Users\ricar\CodeStatus`, com atalhos no menu iniciar e
na área de trabalho. Para usar:

1. **Abrir o app** — dê duplo clique em `CodeStatus.vbs`. Ele sobe direto para a
   bandeja, sem janela de terminal. Um ícone cinza aparece no canto da tela.
2. **Conectar o Claude Code** — clique com o botão direito no ícone e escolha
   *Conectar Claude Code*. Isso grava os hooks no seu `~/.claude/settings.json`
   (com backup automático).
3. **Abrir uma sessão nova** do Claude Code. Sessões que já estavam abertas não
   aparecem: o Claude Code lê a configuração de hooks uma única vez, no início da
   sessão.

Para iniciar junto com o Windows, marque *Iniciar com o Windows* no mesmo menu.

Se precisar ver mensagens de erro, use `iniciar.cmd` em vez do `.vbs` — é o mesmo
app, com o console visível.

## Como ler o ícone

O macOS deixa escrever texto na barra de menu; a bandeja do Windows não, então a
contagem é desenhada dentro do ícone. A cor responde a mesma pergunta que o app
inteiro responde:

| Cor | Significado |
|---|---|
| 🟠 âmbar | alguma sessão precisa de você (aprovação, resposta ou falha) |
| 🔵 azul | sessões trabalhando |
| 🟢 verde | sessões livres, esperando um prompt |
| ⚪ cinza | nenhuma sessão ativa |

O número é a contagem da situação mais urgente presente; `+` significa mais de 9.
Passe o mouse para ver o texto completo, ou clique para abrir o painel.

No painel, clicar numa sessão traz para frente a janela do terminal dela.

## Estados

O vocabulário é o mesmo do original — é a lógica que impede o app de mentir sobre
o que uma sessão está fazendo:

- **trabalhando** — recebeu um prompt: pensando, gerando ou rodando ferramentas
- **livre** — o turno acabou e a sessão continua aberta, pronta para outro prompt
- **aguardando aprovação** — travada esperando você aprovar uma ferramenta
- **aguardando resposta** — travada esperando você responder algo
- **falhou** — o turno terminou em erro (nunca é mostrado como "livre")
- **reconectando** — o app reiniciou e o estado ainda não é confiável

Ausência de evidência é representada explicitamente, nunca chutada. Uma sessão
quieta há dez minutos no meio de uma tool call continua *trabalhando* — só a
confiança nesse estado cai. Tempo parado nunca muda o estado sozinho.

## Notificações

Três interruptores no menu da bandeja, todos ligados por padrão:

- **Avisar quando terminar** — toast quando um turno acaba, com o tempo que a
  sessão levou (*"Terminou. 4min nesta sessão."*).
- **Avisar quando precisar de você** — aprovação, resposta ou falha.
- **Som nas notificações**.

Clicar na notificação traz a janela daquela sessão para frente.

O app original **não** avisa quando termina — ele só interrompe quando há algo a
fazer. Aqui virou uma opção em vez de imposição, mas a decisão de projeto por
trás importa: "chegou em livre" não é o mesmo que "terminou". Um `SessionStart`
também chega em livre, porque uma sessão recém-aberta está ociosa esperando um
prompt. Avisar ali diria *"terminou"* no exato instante em que nada começou.

Por isso a regra olha a **origem** da transição, não o destino: só terminou o que
estava em andamento (trabalhando, ou parado esperando você destravar). Um
`reconnecting → free` depois de reiniciar o app também não conta. Há testes para
cada um desses casos, incluindo um que percorre um turno inteiro e verifica que
ele produz exatamente **uma** notificação, no `Stop`.

As preferências ficam em `%LOCALAPPDATA%\CodeStatus\state\prefs.json`.

## Privacidade

Todo o processamento é local. Não há servidor, telemetria ou rede.

O hook lê o payload que o Claude Code manda e extrai **apenas** uma allowlist de
metadados (`session_id`, `hook_event_name`, `cwd`, `tool_name`, `model`, e
poucos outros). Prompt, resposta, entrada e saída de ferramenta, mensagens e
caminho do transcript nunca cruzam o transporte. Isso é testado: veja o caso
"nenhum conteudo sensivel cruzou o transporte" em `test/transport.test.js`, que
injeta conteúdo sensível de verdade e falha se qualquer parte dele vazar.

## O que mudou em relação ao original

O núcleo — máquina de estados, ordenação de eventos, deduplicação, registro de
sessões — é um porte fiel, com os mesmos invariantes e os mesmos testes. O que
precisou mudar foi tudo que tocava o sistema operacional:

| macOS (original) | Windows (aqui) |
|---|---|
| Swift 6 + AppKit/SwiftUI | Node.js + Electron |
| Socket de domínio Unix | Named pipe (`\\.\pipe\codestatus-<usuário>`) |
| Binário `codestatus-hook` compilado | `hook/hook.js` invocado via `node` |
| `~/Library/Application Support/CodeStatus` | `%LOCALAPPDATA%\CodeStatus` |
| Texto na barra de menu | Contagem desenhada no ícone da bandeja |
| `TERM_PROGRAM` identifica o terminal | `WT_SESSION` / `VSCODE_INJECTION` |
| AppleScript seleciona a aba exata | Traz a janela do processo para frente |
| Saída de processo via kqueue | Verificação periódica do pid |

Todo o mecanismo de `sun_path` do original desapareceu: named pipes vivem num
namespace próprio e não têm limite de caminho, então o fallback para `/tmp` e a
validação de diretório não têm equivalente aqui.

### A pegadinha que custou caro: forma exec vs forma shell

A entrada de hook **precisa** usar `args`:

```json
{
  "type": "command",
  "command": "C:\\Program Files\\nodejs\\node.exe",
  "args": ["C:\\Users\\ricar\\CodeStatus\\hook\\hook.js", "--provider", "claude-code"],
  "timeout": 5,
  "async": true
}
```

Quando `args` está presente, o Claude Code spawna o binário direto (forma exec).
Quando é omitido, ele passa a linha por um shell — e no Windows esse shell pode
ser o **PowerShell**, onde uma linha começando com um caminho entre aspas é
apenas uma *string literal* que ele ecoa. Sem o operador `&`, nada executa.

A primeira versão daqui escrevia tudo numa linha só. Resultado: o hook nunca
rodava — sem erro, sem log, sem nada no spool. Só silêncio. A forma exec também
elimina de vez o problema de aspas em caminhos com espaço (`C:\Program Files`).

Há um teste de regressão para isso (`A entrada usa a forma exec (args)`), e o
detector de posse reconhece os dois formatos, para que quem instalou antes da
correção não fique com entradas duplicadas disparando o hook duas vezes.

**Codex não foi portado.** Você não tem o Codex instalado, e o instalador dele no
original existe quase inteiro para contornar um bug de parsing de caminho do
Codex no macOS, que não se aplica aqui. Se instalar o Codex depois, dá para
adicionar — o hook já aceita `--provider codex`.

**Limitação conhecida:** o Windows não expõe abas de terminal individualmente,
nem no Windows Terminal. Clicar numa sessão traz para frente a *janela* que
hospeda o processo do agente, subindo a árvore de processos até achar uma com
janela. Se nenhuma for encontrada, abre a pasta do projeto.

## Testes

```
npm test              # reducer + instalador + transporte (com o app FECHADO)
npm run test:e2e      # contra o app RODANDO de verdade
```

`npm test` sobe o próprio daemon, então precisa que o app esteja fechado — só um
processo pode segurar o named pipe. O `test:e2e` é o contrário: alimenta o app
que já está rodando.

- `test/reducer.test.js` — 19 casos portados de `StateReducerTests.swift`: os
  invariantes da máquina de estados (um `PreToolUse` atrasado não tira a sessão
  de "aguardando aprovação", nada revive uma sessão encerrada, um turno que
  falhou nunca é contado como livre, replay é idempotente).
- `test/installer.test.js` — 14 casos: instalar preserva as suas configurações e
  hooks de terceiros, reinstalar não duplica, remover só tira o que é nosso, um
  `settings.json` inválido para a instalação em vez de sobrescrever.
- `test/transport.test.js` — integração real: sobe o daemon, invoca o hook como
  o Claude Code invocaria, e confere estado, privacidade e o spool.
- `test/render-icons.js` e `test/render-hud.js` — geram PNGs em `test/icons/`
  para conferir o visual com o olho.

## Desinstalar

No menu da bandeja: *Desconectar Claude Code* (remove os hooks do
`settings.json`), depois *Sair*. Backups do seu `settings.json` ficam em
`%LOCALAPPDATA%\CodeStatus\backups`.
