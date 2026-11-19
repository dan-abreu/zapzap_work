<#
.SYNOPSIS
  Instala o WhatsApp MCP (github.com/lharries/whatsapp-mcp) no Windows e configura no Claude Desktop.

.DESCRIPTION
  Rode num PowerShell NORMAL (sem "Executar como administrador"), na pasta onde salvou este arquivo:

      powershell -ExecutionPolicy Bypass -File .\instalar-whatsapp-mcp.ps1

  - Antes de cada instalacao que pode abrir o aviso de administrador (UAC), o script pergunta e espera seu "s".
  - Pode rodar de novo quantas vezes quiser: ele pula o que ja esta instalado e faz um backup novo da config.
  - Ordem: pre-requisitos, CGO/PATH, clone, dependencias Python, config do Claude Desktop, atalho .bat
    e, por ultimo, o bridge com o QR code (ele fica rodando, por isso vem no fim).

.PARAMETER AtualizarWhatsmeow
  Atualiza o whatsmeow (go get -u go.mau.fi/whatsmeow@latest) antes de rodar o bridge.
  Use se aparecer "Client outdated".

.PARAMETER PularBridge
  Faz toda a instalacao e configuracao, mas nao roda o bridge no final.

.PARAMETER Msys2Root
  Pasta do MSYS2. Padrao: C:\msys64
#>
[CmdletBinding()]
param(
    [switch]$AtualizarWhatsmeow,
    [switch]$PularBridge,
    [string]$Msys2Root = 'C:\msys64'
)

# git, go, winget e pacman escrevem progresso no stderr; com 'Stop' o Windows PowerShell 5.1 trataria isso como erro.
$ErrorActionPreference = 'Continue'

$RepoUrl   = 'https://github.com/lharries/whatsapp-mcp.git'
$RepoDir   = Join-Path $env:USERPROFILE 'whatsapp-mcp'
$BridgeDir = Join-Path $RepoDir 'whatsapp-bridge'
$ServerDir = Join-Path $RepoDir 'whatsapp-mcp-server'
$GccBin    = Join-Path $Msys2Root 'ucrt64\bin'
$MsysBash  = Join-Path $Msys2Root 'usr\bin\bash.exe'

# winget: 0x8A15002B (nenhuma atualizacao disponivel) e 0x8A150061 (ja instalado) contam como sucesso.
$WingetJaInstalado = @(-1978335189, -1978335135)

# ---------------------------------------------------------------------------------------------
# Funcoes auxiliares
# ---------------------------------------------------------------------------------------------

function Write-Passo([string]$Texto) { Write-Host ''; Write-Host "==> $Texto" -ForegroundColor Cyan }
function Write-Ok([string]$Texto)    { Write-Host "    OK  $Texto" -ForegroundColor Green }
function Write-Info([string]$Texto)  { Write-Host "    $Texto" }
function Write-Aviso([string]$Texto) { Write-Host "    !!  $Texto" -ForegroundColor Yellow }

function Stop-Script([string]$Texto) {
    Write-Host ''
    Write-Host "ERRO: $Texto" -ForegroundColor Red
    Write-Host 'Parei aqui. O que ja foi instalado continua instalado; rode o script de novo depois de resolver.' -ForegroundColor Red
    exit 1
}

function Read-SimNao([string]$Pergunta) {
    while ($true) {
        $r = "$(Read-Host "    $Pergunta (s/n)")".Trim().ToLower()
        if ($r -in @('s', 'sim', 'y', 'yes')) { return $true }
        if ($r -in @('n', 'nao', 'no')) { return $false }
    }
}

function Confirm-Admin([string]$Acao) {
    Write-Host ''
    Write-Host "    [PODE PEDIR ADMINISTRADOR] $Acao" -ForegroundColor Yellow
    Write-Host '    O Windows pode mostrar o aviso do Controle de Conta de Usuario (UAC).' -ForegroundColor Yellow
    return (Read-SimNao 'Posso executar?')
}

# Roda um programa no mesmo console, sem o PowerShell capturar a saida (mantem barras de progresso e o QR code intactos).
function Invoke-Direto([string]$Exe, [string[]]$Argumentos, [string]$Pasta) {
    if (-not $Pasta) { $Pasta = (Get-Location).Path }
    $p = Start-Process -FilePath $Exe -ArgumentList $Argumentos -WorkingDirectory $Pasta -NoNewWindow -PassThru
    $null = $p.Handle   # garante que ExitCode fique disponivel no Windows PowerShell 5.1
    $p.WaitForExit()
    return $p.ExitCode
}

# Recarrega o PATH do registro (para enxergar o que o winget acabou de instalar) e poe o gcc do MSYS2 na frente.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
    if ((Test-Path $GccBin) -and -not (($env:Path -split ';') -contains $GccBin)) {
        $env:Path = "$GccBin;$env:Path"
    }
}

function Install-Winget {
    param([string]$Id, [string]$Nome, [bool]$Admin, [string[]]$Extra = @())

    $winget = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        Stop-Script 'winget nao encontrado. Instale o "Instalador de Aplicativo" (App Installer) pela Microsoft Store.'
    }
    if ($Admin) {
        if (-not (Confirm-Admin "winget install --id $Id   ($Nome)")) {
            Stop-Script "Voce nao autorizou a instalacao de $Nome."
        }
    } else {
        Write-Info "Instalando $Nome com winget, so para o seu usuario (nao precisa de administrador)..."
    }
    $wargs = @('install', '--id', $Id, '--exact', '--source', 'winget',
               '--accept-package-agreements', '--accept-source-agreements') + $Extra
    $code = Invoke-Direto -Exe $winget.Source -Argumentos $wargs
    Update-SessionPath
    return (($code -eq 0) -or ($WingetJaInstalado -contains $code))
}

function Get-GoVersion {
    if (-not (Get-Command go -CommandType Application -ErrorAction SilentlyContinue)) { return $null }
    $out = & go version 2>$null
    if ("$out" -match 'go(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2])" }
    return $null
}

function Get-PythonVersion {
    # 'python' pode ser so o atalho da Microsoft Store (nao imprime versao), por isso testo a saida.
    foreach ($c in @(@('py', '-3'), @('python'))) {
        $exe = $c[0]
        if (-not (Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue)) { continue }
        $a = @($c | Select-Object -Skip 1) + @('--version')
        $out = & $exe @a 2>$null
        if ($LASTEXITCODE -eq 0 -and "$out" -match 'Python (\d+)\.(\d+)') {
            return [version]"$($Matches[1]).$($Matches[2])"
        }
    }
    return $null
}

# Acrescenta uma pasta ao PATH do usuario (HKCU, sem administrador) preservando variaveis como %USERPROFILE%.
function Add-UserPath([string]$Dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $partes = @($raw -split ';' | Where-Object { $_ -ne '' })
        $alvo = $Dir.TrimEnd('\')
        $jaTem = $partes | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $alvo }
        if ($jaTem) { Write-Ok "$Dir ja estava no PATH do usuario"; return }
        $novo = (@($partes) + $Dir) -join ';'
        $key.SetValue('Path', $novo, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        $key.Close()
    }
    # Avisa o Windows que o ambiente mudou (janelas novas ja enxergam o PATH novo).
    [Environment]::SetEnvironmentVariable('WHATSAPP_MCP_TMP', '1', 'User')
    [Environment]::SetEnvironmentVariable('WHATSAPP_MCP_TMP', $null, 'User')
    Write-Ok "Adicionado ao PATH do usuario: $Dir"
}

# Mescla o servidor "whatsapp" no claude_desktop_config.json, com backup, mantendo todo o resto do arquivo.
function Set-WhatsAppServer([string]$CfgPath, [string]$Uv, [string]$Dir) {
    $pasta = Split-Path $CfgPath
    if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }

    $cfg = $null
    if (Test-Path $CfgPath) {
        $bak = "$CfgPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $CfgPath -Destination $bak -ErrorAction Stop
        Write-Ok "Backup: $bak"
        $raw = [IO.File]::ReadAllText($CfgPath)
        if ($raw.Trim()) {
            try { $cfg = $raw | ConvertFrom-Json -ErrorAction Stop }
            catch { Stop-Script "$CfgPath nao e um JSON valido, entao nao mexi nele. Corrija-o (o backup esta em $bak) e rode de novo." }
        }
    }
    if ($null -eq $cfg) { $cfg = New-Object PSObject }

    if (-not ($cfg.PSObject.Properties.Name -contains 'mcpServers') -or $null -eq $cfg.mcpServers) {
        $cfg | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue (New-Object PSObject) -Force
    }
    $outros = @($cfg.mcpServers.PSObject.Properties.Name | Where-Object { $_ -and $_ -ne 'whatsapp' })

    $entrada = [pscustomobject]@{
        command = $Uv
        args    = @('--directory', $Dir, 'run', 'main.py')
    }
    $cfg.mcpServers | Add-Member -NotePropertyName 'whatsapp' -NotePropertyValue $entrada -Force

    $json = $cfg | ConvertTo-Json -Depth 64
    $null = $json | ConvertFrom-Json -ErrorAction Stop   # confere que o resultado e JSON valido antes de gravar
    # UTF-8 SEM BOM: o Claude Desktop nao le o arquivo se tiver BOM.
    [IO.File]::WriteAllText($CfgPath, $json, (New-Object Text.UTF8Encoding $false))
    Write-Ok "Servidor 'whatsapp' gravado em $CfgPath"
    if ($outros.Count -gt 0) { Write-Ok "Servidores que ja existiam e foram mantidos: $($outros -join ', ')" }
}

# go get -u do whatsmeow + ajuste do main.go para a API nova (que exige context.Context em 5 chamadas).
function Update-Whatsmeow {
    Write-Passo 'Atualizando o whatsmeow (corrige "Client outdated")'
    Push-Location $BridgeDir
    try {
        & $GoExe get -u 'go.mau.fi/whatsmeow@latest'
        if ($LASTEXITCODE -ne 0) { Stop-Script 'go get -u go.mau.fi/whatsmeow@latest falhou (veja a mensagem acima).' }
        & $GoExe mod tidy
        if ($LASTEXITCODE -ne 0) { Stop-Script 'go mod tidy falhou (veja a mensagem acima).' }

        $main = Join-Path $BridgeDir 'main.go'
        $src  = [IO.File]::ReadAllText($main)
        $orig = $src
        $src = $src -creplace 'client\.Download\(downloader\)',                'client.Download(context.Background(), downloader)'
        $src = $src -creplace 'sqlstore\.New\("sqlite3"',                      'sqlstore.New(context.Background(), "sqlite3"'
        $src = $src -creplace 'container\.GetFirstDevice\(\)',                 'container.GetFirstDevice(context.Background())'
        $src = $src -creplace 'client\.GetGroupInfo\(jid\)',                   'client.GetGroupInfo(context.Background(), jid)'
        $src = $src -creplace 'client\.Store\.Contacts\.GetContact\(jid\)',    'client.Store.Contacts.GetContact(context.Background(), jid)'
        if ($src -cne $orig) {
            [IO.File]::WriteAllText($main, $src, (New-Object Text.UTF8Encoding $false))
            Write-Ok 'main.go ajustado para a API nova do whatsmeow (context.Context).'
        }

        & $GoExe build -o whatsapp-bridge.exe .
        if ($LASTEXITCODE -ne 0) { Stop-Script 'O bridge nao compilou com o whatsmeow novo. Copie a mensagem acima e me mande.' }
        Write-Ok 'whatsmeow atualizado e bridge compilando.'
    } finally {
        Pop-Location
    }
}

function Show-Resumo {
    Write-Host ''
    Write-Host '------------------------------------------------------------------------' -ForegroundColor Green
    Write-Host ' Instalacao e configuracao concluidas.' -ForegroundColor Green
    Write-Host "   Repositorio ........ $RepoDir"
    Write-Host "   uv.exe ............. $UvExe"
    foreach ($c in $Configs) { Write-Host "   Config do Claude ... $c" }
    Write-Host "   Atalho do bridge ... $BatPath"
    Write-Host ''
    Write-Host ' Depois de conectar o WhatsApp: feche o Claude Desktop por completo'
    Write-Host ' (icone perto do relogio > Sair) e abra de novo.'
    Write-Host ' O bridge precisa estar rodando sempre que for usar o WhatsApp no Claude.'
    Write-Host '------------------------------------------------------------------------' -ForegroundColor Green
}

# ---------------------------------------------------------------------------------------------
# Inicio
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Instalador do WhatsApp MCP para o Claude Desktop' -ForegroundColor White
Write-Host "  Repositorio: $RepoUrl"
Write-Host "  Destino:     $RepoDir"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Aviso 'Este PowerShell esta como administrador. O ideal e um PowerShell normal:'
    Write-Aviso 'o que precisa de administrador pede sozinho, um item de cada vez, depois de voce confirmar.'
    if (-not (Read-SimNao 'Continuar mesmo assim?')) { exit 1 }
}

# O Claude Desktop pode regravar o claude_desktop_config.json se estiver aberto. (Ignora o claude.exe do Claude Code CLI.)
function Get-ClaudeDesktop {
    @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue |
      Where-Object { -not $_.Path -or $_.Path -notmatch '\\\.local\\bin\\' })
}
if ((Get-ClaudeDesktop).Count -gt 0) {
    Write-Aviso 'O Claude Desktop esta aberto. Feche-o por completo (icone perto do relogio > Sair),'
    Write-Aviso 'para ele nao sobrescrever a configuracao enquanto eu edito.'
    $null = Read-Host '    Aperte Enter quando tiver fechado'
    if ((Get-ClaudeDesktop).Count -gt 0) { Write-Aviso 'Ainda parece aberto; vou continuar, mas reabra o Claude no final.' }
}

Update-SessionPath

# ---------------------------------------------------------------------------------------------
Write-Passo 'Passo 1  Verificando Git, Go, Python 3.11+, uv e MSYS2 (gcc)'
# ---------------------------------------------------------------------------------------------

# Git
if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
    Write-Ok "Git: $(& git --version)"
} else {
    Write-Aviso 'Git nao encontrado.'
    if (-not (Install-Winget -Id 'Git.Git' -Nome 'Git' -Admin $true)) { Stop-Script 'Falha ao instalar o Git.' }
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        Stop-Script 'O Git foi instalado mas ainda nao aparece no PATH. Feche este PowerShell, abra outro e rode o script de novo.'
    }
    Write-Ok "Git: $(& git --version)"
}

# Go (1.21+ baixa sozinho a versao que o projeto pedir)
$gov = Get-GoVersion
if ($gov -and $gov -ge [version]'1.21') {
    Write-Ok "Go $gov"
} else {
    if ($gov) { Write-Aviso "Go $gov e antigo demais (precisa 1.21 ou mais novo)." } else { Write-Aviso 'Go nao encontrado.' }
    if (-not (Install-Winget -Id 'GoLang.Go' -Nome 'Go' -Admin $true)) { Stop-Script 'Falha ao instalar o Go.' }
    $gov = Get-GoVersion
    if (-not $gov) { Stop-Script 'O Go foi instalado mas ainda nao aparece no PATH. Feche este PowerShell, abra outro e rode o script de novo.' }
    Write-Ok "Go $gov"
}
$GoExe = (Get-Command go -CommandType Application | Select-Object -First 1).Source

# Python 3.11+
$pyv = Get-PythonVersion
if ($pyv -and $pyv -ge [version]'3.11') {
    Write-Ok "Python $pyv"
} else {
    if ($pyv) { Write-Aviso "Python $pyv e antigo demais (precisa 3.11+)." } else { Write-Aviso 'Python 3.11+ nao encontrado.' }
    $ok = Install-Winget -Id 'Python.Python.3.11' -Nome 'Python 3.11' -Admin $false -Extra @('--scope', 'user')
    if (-not $ok) {
        Write-Aviso 'A instalacao so para o seu usuario falhou; da para tentar a instalacao para todos os usuarios.'
        $ok = Install-Winget -Id 'Python.Python.3.11' -Nome 'Python 3.11 (todos os usuarios)' -Admin $true
    }
    if (-not $ok) { Stop-Script 'Falha ao instalar o Python 3.11.' }
    $pyv = Get-PythonVersion
    if ($pyv) { Write-Ok "Python $pyv" } else { Write-Ok 'Python 3.11 instalado (o uv o encontra mesmo fora do PATH).' }
}

# uv
$uvCmd = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uvCmd) {
    Write-Aviso 'uv nao encontrado.'
    if (-not (Install-Winget -Id 'astral-sh.uv' -Nome 'uv' -Admin $false)) { Stop-Script 'Falha ao instalar o uv.' }
    $uvCmd = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $uvCmd) {
        $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\uv.exe'
        if (Test-Path $link) { $uvCmd = Get-Command $link }
    }
    if (-not $uvCmd) { Stop-Script 'O uv foi instalado mas nao o encontrei. Feche este PowerShell, abra outro e rode o script de novo.' }
}
$UvExe = $uvCmd.Source
Write-Ok "uv: $UvExe"

# MSYS2
if (Test-Path $MsysBash) {
    Write-Ok "MSYS2 em $Msys2Root"
} else {
    Write-Aviso "MSYS2 nao encontrado em $Msys2Root."
    if (-not (Install-Winget -Id 'MSYS2.MSYS2' -Nome 'MSYS2' -Admin $true)) { Stop-Script 'Falha ao instalar o MSYS2.' }
    if (-not (Test-Path $MsysBash)) {
        Stop-Script "MSYS2 instalado, mas nao achei $MsysBash. Se ele foi para outra pasta, rode o script com -Msys2Root 'D:\caminho\msys64'."
    }
    Write-Ok "MSYS2 em $Msys2Root"
}

# gcc (UCRT64) dentro do MSYS2 - o go-sqlite3 precisa de compilador C com CGO
$gccExe = Join-Path $GccBin 'gcc.exe'
if (Test-Path $gccExe) {
    Write-Ok "gcc em $GccBin"
} else {
    Write-Info 'Instalando o gcc (UCRT64) pelo pacman do MSYS2. Nao precisa de administrador.'
    Write-Info 'Na primeira vez o MSYS2 se inicializa; pode levar alguns minutos...'
    & $MsysBash -lc 'pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-gcc'
    if (-not (Test-Path $gccExe)) {
        Write-Aviso 'Nao deu certo de primeira; atualizando a lista de pacotes do MSYS2 e tentando de novo...'
        & $MsysBash -lc 'pacman -Sy --needed --noconfirm mingw-w64-ucrt-x86_64-gcc'
    }
    if (-not (Test-Path $gccExe)) {
        Stop-Script "Nao consegui instalar o gcc. Abra 'MSYS2 UCRT64' no menu Iniciar, rode 'pacman -S mingw-w64-ucrt-x86_64-gcc' e depois rode este script de novo."
    }
    Write-Ok "gcc em $GccBin"
}

# ---------------------------------------------------------------------------------------------
Write-Passo 'Passo 2  Ativando o CGO e colocando o gcc do MSYS2 no PATH'
# ---------------------------------------------------------------------------------------------
& $GoExe env -w CGO_ENABLED=1
if ($LASTEXITCODE -ne 0) { Stop-Script 'go env -w CGO_ENABLED=1 falhou.' }
Write-Ok 'go env -w CGO_ENABLED=1'
Add-UserPath $GccBin
Update-SessionPath

# ---------------------------------------------------------------------------------------------
Write-Passo "Passo 3  Clonando o repositorio em $RepoDir"
# ---------------------------------------------------------------------------------------------
if (Test-Path (Join-Path $RepoDir '.git')) {
    Write-Ok 'Ja estava clonado; mantive como esta.'
} elseif (Test-Path $RepoDir) {
    Stop-Script "A pasta $RepoDir ja existe e nao e um clone do git. Renomeie essa pasta e rode o script de novo."
} else {
    & git clone $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) { Stop-Script 'git clone falhou (veja a mensagem acima).' }
    Write-Ok 'Repositorio clonado.'
}

# ---------------------------------------------------------------------------------------------
Write-Passo 'Preparando o servidor MCP em Python (uv sync)'
# ---------------------------------------------------------------------------------------------
Write-Info 'O projeto fixa Python 3.11; se voce nao tiver a 3.11, o uv baixa uma copia propria sozinho.'
& $UvExe --directory $ServerDir sync
if ($LASTEXITCODE -ne 0) { Stop-Script 'uv sync falhou (veja a mensagem acima).' }
Write-Ok 'Dependencias instaladas (assim o Claude Desktop abre o servidor sem demora).'

# ---------------------------------------------------------------------------------------------
Write-Passo 'Passo 5  Configurando o Claude Desktop (claude_desktop_config.json)'
# ---------------------------------------------------------------------------------------------
# Instalacao normal: %APPDATA%\Claude. A versao empacotada (MSIX) pode ter uma copia propria em
# %LOCALAPPDATA%\Packages\<Claude...>\LocalCache\Roaming\Claude, que tem prioridade. Se essa copia existir,
# atualizo as duas. Se nao existir, nao crio: o app empacotado continua lendo a de %APPDATA%.
$Configs = New-Object System.Collections.Generic.List[string]
$Configs.Add((Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'))
$pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
if (Test-Path $pkgRoot) {
    Get-ChildItem -Path $pkgRoot -Directory -Filter '*Claude*' -ErrorAction SilentlyContinue | ForEach-Object {
        $f = Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'
        if (Test-Path $f) { $Configs.Add($f) }
    }
}
foreach ($c in $Configs) { Set-WhatsAppServer -CfgPath $c -Uv $UvExe -Dir $ServerDir }

# ---------------------------------------------------------------------------------------------
Write-Passo 'Passo 6  Criando o atalho .bat na Area de Trabalho'
# ---------------------------------------------------------------------------------------------
# Compila um whatsapp-bridge.exe fixo em vez de "go run": com "go run" o executavel muda de pasta a cada vez
# e o Firewall do Windows perguntaria de novo em toda inicializacao.
$desktop = [Environment]::GetFolderPath('Desktop')
$BatPath = Join-Path $desktop 'Iniciar WhatsApp Bridge.bat'
$batLinhas = @(
    '@echo off',
    'title WhatsApp Bridge - deixe esta janela aberta',
    ('set "PATH={0};%PATH%"' -f $GccBin),
    'set "CGO_ENABLED=1"',
    'cd /d "%USERPROFILE%\whatsapp-mcp\whatsapp-bridge" || (echo Pasta do bridge nao encontrada & pause & exit /b 1)',
    'echo Compilando o bridge, na primeira vez demora um pouco...',
    ('"{0}" build -o whatsapp-bridge.exe .' -f $GoExe),
    'if errorlevel 1 (',
    '  echo.',
    '  echo ERRO ao compilar o bridge. Veja a mensagem acima.',
    '  pause',
    '  exit /b 1',
    ')',
    'echo Deixe esta janela aberta enquanto usar o WhatsApp no Claude. Para parar: Ctrl+C.',
    'whatsapp-bridge.exe',
    'echo.',
    'echo O bridge parou. Sem ele o WhatsApp MCP nao funciona.',
    'pause'
)
# O cmd.exe le .bat na pagina de codigo OEM do console (ex.: 850 no Brasil).
$oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
[IO.File]::WriteAllText($BatPath, (($batLinhas -join "`r`n") + "`r`n"), $oem)
Write-Ok "Atalho criado: $BatPath"

# ---------------------------------------------------------------------------------------------
# Passo 4 (por ultimo, porque o bridge fica rodando)
# ---------------------------------------------------------------------------------------------
if ($AtualizarWhatsmeow) { Update-Whatsmeow }

if ($PularBridge) {
    Show-Resumo
    Write-Host ''
    Write-Host 'Bridge nao executado (-PularBridge). Para conectar o WhatsApp, abra o atalho da Area de Trabalho.'
    exit 0
}

Show-Resumo

Write-Passo 'Passo 4  Rodando o bridge (go run main.go) para conectar seu WhatsApp'
Write-Info 'Em instantes aparece um QR code nesta janela. No celular: WhatsApp > Aparelhos conectados >'
Write-Info 'Conectar um aparelho, e aponte a camera para o QR. Ele se renova a cada ~20 s; vale o mais recente.'
Write-Info 'Se o QR ficar cortado, aumente o terminal (no VS Code: maximize o painel ou use Ctrl + - para diminuir o zoom).'
Write-Info 'Quando aparecer "Connected to WhatsApp" e "REST server is running", esta pronto. Pode deixar'
Write-Info 'esta janela aberta, ou fecha-la e usar o atalho da Area de Trabalho daqui pra frente.'
Write-Info 'A primeira sincronizacao das conversas leva alguns minutos.'
Write-Aviso 'Se o Firewall do Windows perguntar sobre acesso a rede, clique em CANCELAR. O Claude usa so o'
Write-Aviso 'localhost, e liberar deixaria qualquer um na sua rede enviar mensagens pelo seu WhatsApp'
Write-Aviso '(a API do bridge, na porta 8080, nao tem senha).'
if (-not $AtualizarWhatsmeow) {
    Write-Aviso 'Se aparecer "Client outdated": espere o bridge encerrar sozinho (ate 3 min) e responda "s" na'
    Write-Aviso 'pergunta que vem depois. Ou feche a janela e rode de novo com -AtualizarWhatsmeow.'
}
Write-Host ''

$jaAtualizou = [bool]$AtualizarWhatsmeow
while ($true) {
    $null = Invoke-Direto -Exe $GoExe -Argumentos @('run', 'main.go') -Pasta $BridgeDir
    Write-Host ''
    Write-Aviso 'O bridge encerrou.'
    if (-not $jaAtualizou) {
        if (Read-SimNao 'Apareceu "Client outdated" (ou erro 405) nas mensagens acima?') {
            Update-Whatsmeow
            $jaAtualizou = $true
            Write-Passo 'Rodando o bridge de novo, agora com o whatsmeow atualizado'
            continue
        }
    }
    Write-Info 'Se ele parou por "Timeout waiting for QR code scan", e so abrir o atalho da Area de Trabalho e escanear.'
    Write-Info 'Se foi outro erro, copie a mensagem e me mande.'
    break
}
