# otimizar-windows

Script PowerShell de limpeza e otimização do Windows 11: temporários, caches de dev/GPU/HuggingFace/Cursor,
registro órfão, bloatware da Store, Copilot, políticas anti-reinstalação, serviços e itens de inicialização.

Cada etapa pergunta antes de rodar. Pede admin sozinho e gera log em `Documentos\otimizar-windows-<data>.log`.

## Uso rápido

PowerShell:

```powershell
# interativo (pergunta s/n por etapa)
irm https://raw.githubusercontent.com/luizfbalves/otimizar-windows/main/otimizar-windows.ps1 | iex

# com parâmetros
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/luizfbalves/otimizar-windows/main/otimizar-windows.ps1))) -DryRun
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/luizfbalves/otimizar-windows/main/otimizar-windows.ps1))) -Yes -Skip Cursor,GpuCache
```

cmd / curl:

```bat
curl -fsSL https://raw.githubusercontent.com/luizfbalves/otimizar-windows/main/otimizar-windows.ps1 -o %TEMP%\otimizar-windows.ps1 && powershell -ExecutionPolicy Bypass -File %TEMP%\otimizar-windows.ps1
```

## Parâmetros

| Parâmetro | Descrição |
|---|---|
| `-DryRun` | Só mostra o que faria, sem apagar/alterar nada |
| `-Yes` | Roda todas as etapas sem perguntar |
| `-Only Etapa1,Etapa2` | Roda só essas etapas |
| `-Skip Etapa1,Etapa2` | Pula essas etapas |
| `-CursorKeepDays N` | Mantém chats do Cursor dos últimos N dias (padrão 30) |

## Etapas

| Etapa | O que faz |
|---|---|
| `Temp` | Temporários (>2 dias), CrashDumps, relatórios de erro, Lixeira |
| `DevCaches` | npm, pip, pnpm, yarn, uv, Docker build cache + imagens soltas |
| `GpuCache` | Cache de shaders NVIDIA/AMD/DirectX (jogos recompilam na 1ª abertura) |
| `HuggingFace` | Modelos/datasets/token do HuggingFace |
| `Cursor` | Caches, versões antigas do agente, projetos inexistentes, chats antigos (backup + integrity check; precisa de Python) |
| `Registry` | Entradas de programas desinstalados que ficaram no registro (backup `.reg`) |
| `Bloatware` | Bing, Paciência, Widgets, Teams, Outlook novo, Phone Link, Clipchamp, Candy Crush etc. (todos os usuários + provisionados) |
| `Copilot` | Desinstala o app Copilot |
| `Policies` | Bloqueia reinstalação de bloat, sugestões/anúncios, Widgets, Copilot, Teams auto-install |
| `Services` | Desativa MapsBroker e Localização (lfsvc) |
| `Startup` | Desativa tarefas de telemetria do Edge/SoftLanding e autostart do Docker Desktop |
| `Report` | Lista o que inicia com o Windows, serviços de terceiros e programas instalados (só leitura) |

Mantidos de propósito: Xbox/Gaming Services, Fotos, Calculadora, Bloco de Notas, Ferramenta de Captura, Câmera, Media Player, Store, Terminal.

> Use por sua conta e risco. Rode `-DryRun` primeiro.
