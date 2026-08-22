<#
.SYNOPSIS
    Motor do DEVAPP. Le o catalogo.json e responde sobre o ambiente portatil.

.DESCRIPTION
    Este script e somente leitura: ele nao baixa, nao instala, nao apaga e
    nao altera variaveis de ambiente da maquina. Serve como base para a
    interface web que vai substituir os menus do start.bat.

    Escrito em ASCII puro de proposito. O start.bat original mistura UTF-8
    com acentos e "chcp 65001", o que deixa o interpretador de lote instavel
    ao ponto de qualquer edicao poder quebrar o arquivo. A interface HTML
    pode usar acentos a vontade; este motor nao.

.PARAMETER Acao
    status  - lista as ferramentas e se estao instaladas (padrao)
    env     - mostra o mapa de variaveis de ambiente resolvido
    path    - mostra as pastas que entrariam no PATH
    json    - devolve o status em JSON (formato que a interface vai consumir)
    doutor  - aponta pendencias e riscos registrados no catalogo
    bancos  - mostra quais servidores de banco estao no ar
    extensoes - lista as categorias de extensoes do VS Code, ou instala uma (-Id java)
    iniciar - sobe um servidor de banco (-Id mariadb)
    parar   - encerra um servidor de banco (-Id mariadb)
    servir  - sobe a interface web local e abre o navegador

.PARAMETER Id
    Filtra por uma ferramenta especifica (ex: -Id mariadb).

.PARAMETER Porta
    Porta do servidor local. Se omitida, procura a primeira livre a partir de 8787.

.EXAMPLE
    .\devapp.ps1
    .\devapp.ps1 -Acao env
    .\devapp.ps1 -Acao status -Id mysql
    .\devapp.ps1 -Acao json > status.json
    .\devapp.ps1 -Acao servir
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'env', 'path', 'json', 'doutor', 'servir', 'instalar', 'iniciar', 'parar', 'bancos', 'extensoes')]
    [string]$Acao = 'status',

    [string]$Id,

    [int]$Porta = 0,

    [switch]$NaoAbrir
)

$ErrorActionPreference = 'Stop'

# Valores do bloco "ambiente" que sao configuracao, nao caminho de pasta.
$ValoresNaoCaminho = @('PGDATABASE', 'PGUSER', 'PGPORT')

# Tipos de instalacao que o motor sabe executar. Fica num lugar so para a
# interface, a validacao do servidor e o instalador nunca discordarem.
$TiposSuportados = @('zip', 'exe-direto', '7z-sfx', 'msi-admin', 'instalador')


function Import-Catalogo {
    $arquivo = Join-Path $PSScriptRoot 'catalogo.json'
    if (-not (Test-Path -LiteralPath $arquivo)) {
        throw "catalogo.json nao encontrado em: $arquivo"
    }
    $bruto = Get-Content -LiteralPath $arquivo -Raw -Encoding UTF8
    return ($bruto | ConvertFrom-Json)
}


function Resolve-Caminho {
    param([string]$Relativo)

    if ([string]::IsNullOrWhiteSpace($Relativo)) { return $null }
    if ($Relativo -eq '.') { return $PSScriptRoot }
    return (Join-Path $PSScriptRoot ($Relativo -replace '/', '\'))
}


function Get-Ambiente {
    param($Catalogo)

    $mapa = [ordered]@{}
    foreach ($prop in $Catalogo.ambiente.PSObject.Properties) {
        if ($ValoresNaoCaminho -contains $prop.Name) {
            $mapa[$prop.Name] = $prop.Value
        }
        else {
            $mapa[$prop.Name] = Resolve-Caminho $prop.Value
        }
    }

    # A raiz com barra normal, para formatos que nao aceitam a invertida.
    # Arquivos .properties do mundo Java sao o caso classico: la a barra
    # invertida e caractere de escape.
    $mapa['DEVAPP_BARRAS'] = $PSScriptRoot -replace '\\', '/'

    # Segunda passada: valores que nao sao caminho, e sim texto montado a
    # partir dos caminhos ja resolvidos. E o caso do Maven, que nao tem
    # variavel propria para o repositorio local e so aceita como argumento.
    if ($null -ne $Catalogo.ambienteTexto) {
        foreach ($prop in $Catalogo.ambienteTexto.PSObject.Properties) {
            $mapa[$prop.Name] = Expand-Modelo -Texto ([string]$prop.Value) -Mapa $mapa
        }
    }

    return $mapa
}


function Get-PathDevapp {
    param($Catalogo)

    $lista = New-Object System.Collections.Generic.List[string]

    # A propria raiz e a pasta de scripts, como o start.bat faz.
    $lista.Add($PSScriptRoot)

    foreach ($embutida in $Catalogo.ferramentasEmbutidas) {
        $abs = Resolve-Caminho $embutida.pasta
        if (-not $lista.Contains($abs)) { $lista.Add($abs) }
    }

    foreach ($ferramenta in $Catalogo.ferramentas) {
        foreach ($trecho in $ferramenta.path) {
            $abs = Resolve-Caminho $trecho
            if (-not $lista.Contains($abs)) { $lista.Add($abs) }
        }
    }

    $scripts = Resolve-Caminho 'scripts'
    if (-not $lista.Contains($scripts)) { $lista.Add($scripts) }

    return $lista
}


function Test-Instalada {
    param($Ferramenta)

    if ([string]::IsNullOrWhiteSpace($Ferramenta.detectar)) { return $false }
    return (Test-Path -LiteralPath (Resolve-Caminho $Ferramenta.detectar))
}


function Get-Status {
    param($Catalogo, [string]$Filtro)

    $resultado = New-Object System.Collections.Generic.List[object]
    $bancosNoAr = Get-EstadoBancos

    foreach ($f in $Catalogo.ferramentas) {
        if (-not [string]::IsNullOrWhiteSpace($Filtro)) {
            if ($f.id -ne $Filtro) { continue }
        }

        $implementada = $true
        if ($null -ne $f.implementado) { $implementada = [bool]$f.implementado }

        # Mais de um download so esta implementado para zip.
        $instalavel = $false
        $tipo = ''
        if ($null -ne $f.instalacao) {
            $tipo = [string]$f.instalacao.tipo
            $instalavel = ($TiposSuportados -contains $tipo)
            if ($null -ne $f.downloadExtra -and $tipo -ne 'zip') { $instalavel = $false }
        }

        $rodando = $false
        $numeroProcesso = 0
        if ($null -ne $f.servidor -and $bancosNoAr.ContainsKey($f.id)) {
            $rodando = $true
            $numeroProcesso = $bancosNoAr[$f.id].pid
        }

        $resultado.Add([pscustomobject]@{
            Instalavel     = $instalavel
            TipoInstalacao = $tipo
            # O Where-Object nao e enfeite: sem ele, uma ferramenta sem
            # dependencia sai com [null] em vez de lista vazia.
            Requer         = @($f.requer | Where-Object { $_ })
            Id           = $f.id
            Nome         = $f.nome
            Categoria    = $f.categoria
            Versao       = $f.versao
            Instalada    = (Test-Instalada $f)
            Portatil     = [bool]$f.portatil
            Implementada = $implementada
            Inferida     = [bool]$f.detectarInferido
            Detectar     = $f.detectar
            Executar     = $f.executar
            Servidor     = $f.servidor
            Rodando      = $rodando
            Pid          = $numeroProcesso
            PerfilUsuario = $f.perfilUsuario
        })
    }

    return $resultado
}


function Show-Status {
    param($Itens)

    # Com um unico item o PowerShell entrega o objeto solto em vez da lista,
    # e ai .Count vem vazio. O @() garante que sempre seja uma colecao.
    $Itens = @($Itens)

    if ($Itens.Count -eq 0) {
        Write-Host "Nenhuma ferramenta corresponde ao filtro."
        return
    }

    $instaladas = @($Itens | Where-Object { $_.Instalada }).Count

    Write-Host ""
    Write-Host "DEVAPP em: $PSScriptRoot"
    Write-Host ("Instaladas: {0} de {1}" -f $instaladas, $Itens.Count)
    Write-Host ""

    $categorias = $Itens | Select-Object -ExpandProperty Categoria -Unique
    foreach ($cat in $categorias) {
        Write-Host "--- $cat "
        foreach ($item in ($Itens | Where-Object { $_.Categoria -eq $cat })) {

            if ($item.Instalada) { $marca = '[ok]' } else { $marca = '[  ]' }

            $avisos = New-Object System.Collections.Generic.List[string]
            if (-not $item.Portatil)     { $avisos.Add('nao portatil') }
            if ($item.Inferida)          { $avisos.Add('deteccao inferida') }
            if (-not $item.Implementada) { $avisos.Add('sem rotina de instalacao') }

            $sufixo = ''
            if ($avisos.Count -gt 0) { $sufixo = '  (' + ($avisos -join ', ') + ')' }

            Write-Host ("  {0} {1,-32} {2,-14}{3}" -f $marca, $item.Nome, $item.Versao, $sufixo)
        }
        Write-Host ""
    }
}


function Show-Ambiente {
    param($Mapa)

    Write-Host ""
    Write-Host "Variaveis de ambiente que o DEVAPP definiria:"
    Write-Host ""
    foreach ($chave in $Mapa.Keys) {
        $valor = $Mapa[$chave]
        $marca = '   '
        if ($ValoresNaoCaminho -notcontains $chave) {
            if (Test-Path -LiteralPath $valor) { $marca = '[ok]' } else { $marca = '[  ]' }
        }
        Write-Host ("  {0} {1,-22} {2}" -f $marca, $chave, $valor)
    }
    Write-Host ""
    Write-Host "[ok] = a pasta existe   [  ] = ainda nao instalado"
    Write-Host ""
}


function Show-Path {
    param($Lista)

    Write-Host ""
    Write-Host "Pastas que entrariam no PATH (nesta ordem):"
    Write-Host ""
    $i = 0
    foreach ($p in $Lista) {
        $i++
        if (Test-Path -LiteralPath $p) { $marca = '[ok]' } else { $marca = '[  ]' }
        Write-Host ("  {0,2}. {1} {2}" -f $i, $marca, $p)
    }
    Write-Host ""
}


function Show-Doutor {
    param($Catalogo, $Itens)

    Write-Host ""
    Write-Host "=== Pendencias e riscos registrados no catalogo ==="
    Write-Host ""

    $inferidas = @($Itens | Where-Object { $_.Inferida })
    Write-Host ("1. Deteccao ainda nao confirmada ({0}) - deduzida, e a ferramenta nunca foi instalada aqui:" -f $inferidas.Count)
    foreach ($x in $inferidas) {
        Write-Host ("     {0,-16} -> {1}" -f $x.Id, $x.Detectar)
    }
    Write-Host ""

    $naoPortateis = @($Itens | Where-Object { -not $_.Portatil })
    Write-Host ("2. Nao portateis ({0}) - mexem fora da pasta do DEVAPP:" -f $naoPortateis.Count)
    foreach ($x in $naoPortateis) {
        Write-Host ("     {0}" -f $x.Nome)
    }
    Write-Host ""

    # Separar o que ja foi resolvido do que continua em aberto. Misturar os
    # dois faz o relatorio apontar problemas ja corrigidos, e um relatorio
    # que grita a toa e um relatorio que ninguem le.
    $redirecionadas = @($Catalogo.ferramentas | Where-Object { $_.redirecionadoPor })

    Write-Host ("3. Caches trazidos para dentro do DEVAPP ({0}):" -f $redirecionadas.Count)
    foreach ($x in $redirecionadas) {
        # "parcial" existe porque algumas ferramentas do Google guardam
        # preferencia do usuario (telemetria, aceite de termos) fora da pasta
        # por design. O volume vem para ca; esses poucos bytes nao.
        # O [string] nao e enfeite: em PowerShell, $true -eq 'parcial' da
        # VERDADEIRO, porque o lado direito e convertido para o tipo do
        # esquerdo, e uma string nao vazia vira $true. Sem o cast, tudo que
        # estivesse medido apareceria como parcial.
        $marca = [string]$x.redirecionamentoMedido
        $selo = '[no papel] '
        if ($marca -eq 'parcial')  { $selo = '[parcial]  ' }
        elseif ($marca -eq 'True') { $selo = '[medido]   ' }
        Write-Host ("     {0}{1,-22} {2}" -f $selo, $x.nome, ($x.redirecionadoPor -join ', '))
    }
    Write-Host ""

    $vazam = @($Catalogo.ferramentas | Where-Object { $_.perfilUsuario -and -not $_.redirecionadoPor })
    Write-Host ("4. Ainda escrevem no seu perfil ({0}):" -f $vazam.Count)
    foreach ($x in $vazam) {
        Write-Host ("     {0,-22} {1}" -f $x.nome, ($x.perfilUsuario -join ', '))
    }
    Write-Host ""

    $semRotina = @($Itens | Where-Object { -not $_.Implementada })
    if ($semRotina.Count -gt 0) {
        Write-Host ("5. Estao no catalogo mas nunca tiveram rotina ({0}):" -f $semRotina.Count)
        foreach ($x in $semRotina) { Write-Host ("     {0}" -f $x.Nome) }
        Write-Host ""
    }

    $conflitos = @{}
    foreach ($f in $Catalogo.ferramentas) {
        if ($null -ne $f.servidor -and $null -ne $f.servidor.porta) {
            $porta = [string]$f.servidor.porta
            if (-not $conflitos.ContainsKey($porta)) { $conflitos[$porta] = @() }
            $conflitos[$porta] += $f.nome
        }
    }
    Write-Host "6. Portas de servidor:"
    foreach ($porta in ($conflitos.Keys | Sort-Object)) {
        $donos = $conflitos[$porta]
        if ($donos.Count -gt 1) {
            Write-Host ("     {0}  CONFLITO entre: {1}" -f $porta, ($donos -join ' e '))
        }
        else {
            Write-Host ("     {0}  {1}" -f $porta, $donos[0])
        }
    }
    Write-Host ""
}


# ------------------------------------------------------------------
# Instalacao
# ------------------------------------------------------------------

$ArquivoProgresso = Join-Path $env:TEMP 'devapp-progresso.json'

# Uma instalacao pode arrastar dependencias (o Maven puxa o JDK). Estes dois
# dizem em que ponto da fila estamos, para a pagina mostrar "1 de 2".
$script:PassoAtual = 1
$script:TotalPassos = 1

function Write-Progresso {
    param(
        [string]$Id,
        [string]$Etapa,
        [int]$Porcento = -1,
        [string]$Detalhe = '',
        [switch]$Fim,
        [string]$Erro = ''
    )

    $estado = [pscustomobject]@{
        id       = $Id
        etapa    = $Etapa
        porcento = $Porcento
        detalhe  = $Detalhe
        fim      = [bool]$Fim
        erro     = $Erro
        passo    = $script:PassoAtual
        total    = $script:TotalPassos
        quando   = (Get-Date).ToString('s')
    }
    try {
        $estado | ConvertTo-Json -Compress | Set-Content -LiteralPath $ArquivoProgresso -Encoding UTF8
    }
    catch { }

    $marca = '  '
    if ($Porcento -ge 0) { $marca = ('{0,3}%' -f $Porcento) }
    $fila = ''
    if ($script:TotalPassos -gt 1) { $fila = ('[{0}/{1}] ' -f $script:PassoAtual, $script:TotalPassos) }
    Write-Host ("  {0} {1}{2} {3}" -f $marca, $fila, $Etapa, $Detalhe)
}


function Get-ArquivoComProgresso {
    <#
      Download com .NET puro para poder informar bytes recebidos. O
      Invoke-WebRequest do PowerShell 5.1 guarda a resposta inteira em
      memoria antes de gravar, o que e ruim para arquivos de centenas de MB.
    #>
    param([string]$Url, [string]$Destino, [string]$Id, [string]$Rotulo)

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

    $pedido = [Net.HttpWebRequest]::Create($Url)
    $pedido.UserAgent = 'DEVAPP'
    $pedido.AllowAutoRedirect = $true
    $pedido.Timeout = 60000

    $resposta = $pedido.GetResponse()
    $total = $resposta.ContentLength
    $entrada = $resposta.GetResponseStream()
    $saida = [IO.File]::Create($Destino)

    $buffer = New-Object byte[] 131072
    $recebido = 0L
    $ultimoAviso = -1

    try {
        while ($true) {
            $lidos = $entrada.Read($buffer, 0, $buffer.Length)
            if ($lidos -le 0) { break }
            $saida.Write($buffer, 0, $lidos)
            $recebido += $lidos

            if ($total -gt 0) {
                $pct = [int](($recebido * 100) / $total)
                if ($pct -ne $ultimoAviso -and ($pct % 5) -eq 0) {
                    $ultimoAviso = $pct
                    Write-Progresso -Id $Id -Etapa 'baixando' -Porcento $pct `
                        -Detalhe ("{0} - {1:N1} de {2:N1} MB" -f $Rotulo, ($recebido / 1MB), ($total / 1MB))
                }
            }
        }
    }
    finally {
        $saida.Close(); $entrada.Close(); $resposta.Close()
    }

    return $recebido
}


function Get-ArquivoComWget {
    <#
      Rede de seguranca. O wget que vem no projeto aceita apontar servidores
      de DNS, e o start.bat sempre usou 8.8.8.8 e 1.1.1.1 por causa de redes
      (escolas, empresas) onde o DNS local nao resolve certos hosts. O
      download nativo usa o resolvedor do sistema e nao tem esse recurso,
      entao ele fica como primeira opcao e o wget como segunda.
    #>
    param([string]$Url, [string]$Destino, [string]$Id, [string]$Rotulo)

    $wget = Join-Path $PSScriptRoot 'wget\wget.exe'
    if (-not (Test-Path -LiteralPath $wget)) { throw 'wget.exe nao encontrado para a segunda tentativa.' }

    Write-Progresso -Id $Id -Etapa 'baixando' -Porcento 50 -Detalhe ("{0} - segunda tentativa, via wget com DNS publico" -f $Rotulo)
    & $wget --dns-servers=8.8.8.8,1.1.1.1 -q -O $Destino $Url
    if ($LASTEXITCODE -ne 0) { throw ("wget tambem falhou (codigo {0})." -f $LASTEXITCODE) }
    if (-not (Test-Path -LiteralPath $Destino)) { throw 'wget nao gravou o arquivo.' }

    return (Get-Item -LiteralPath $Destino).Length
}


function Expand-Zip {
    <#
      O ExtractToDirectory do .NET Framework nao sobrescreve: ele lanca erro
      no primeiro arquivo repetido, sem opcao para mudar isso. Isso aparece
      quando uma ferramenta vem em varios pacotes que se sobrepoem -- o
      runtime do ASP.NET traz o mesmo dotnet.exe que o SDK.

      Entao: tenta o caminho rapido primeiro e, se esbarrar num arquivo que
      ja existe, refaz arquivo por arquivo sobrescrevendo. O modo lento so
      paga o custo quando e realmente necessario.
    #>
    param([string]$Arquivo, [string]$Pasta)

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force | Out-Null }

    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($Arquivo, $Pasta)
        return
    }
    catch {
        if ($_.Exception.Message -notmatch 'existe|exists') { throw }
    }

    $zip = [IO.Compression.ZipFile]::OpenRead($Arquivo)
    try {
        foreach ($entrada in $zip.Entries) {
            $destino = Join-Path $Pasta ($entrada.FullName -replace '/', '\')

            if ([string]::IsNullOrEmpty($entrada.Name)) {   # entrada de pasta
                if (-not (Test-Path -LiteralPath $destino)) {
                    New-Item -ItemType Directory -Path $destino -Force | Out-Null
                }
                continue
            }

            $pastaDele = Split-Path -Parent $destino
            if (-not (Test-Path -LiteralPath $pastaDele)) {
                New-Item -ItemType Directory -Path $pastaDele -Force | Out-Null
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entrada, $destino, $true)
        }
    }
    finally {
        $zip.Dispose()
    }
}


function Expand-SeteZip {
    <#
      O .NET so abre .zip. O PortableGit vem como .7z auto-extraivel, que
      nenhuma biblioteca nativa le, entao aqui o 7za do projeto e mesmo
      insubstituivel.
    #>
    param([string]$Arquivo, [string]$Pasta)

    $sete = Join-Path $PSScriptRoot 'sevenzip\7za.exe'
    if (-not (Test-Path -LiteralPath $sete)) { throw '7za.exe nao encontrado na pasta sevenzip.' }
    if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force | Out-Null }

    # -y responde sim a tudo: sem isso o 7za para esperando confirmacao e o
    # processo fica pendurado para sempre, sem ninguem para ver a pergunta.
    & $sete x $Arquivo ('-o' + $Pasta) -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("7za falhou (codigo {0})." -f $LASTEXITCODE) }
}


function Expand-Pacote {
    <#
      Extrai um zip conforme as instrucoes. O pacote pode trazer seu proprio
      "extrairEm"; se nao trouxer, vale o da instalacao. Sao tres formatos:
        pastaExtraida  o zip tem uma pasta com nome de versao, que e renomeada
        extrairEm      o zip nao tem pasta propria, vai direto para dentro dela
        (nenhum)       o zip ja traz a pasta certa, extrai na raiz do DEVAPP
    #>
    param($Ferramenta, $Pacote, [string]$Arquivo, [string]$Temporario, [string]$Id)

    $onde = $Pacote.extrairEm
    if ([string]::IsNullOrWhiteSpace($onde)) { $onde = $Ferramenta.instalacao.extrairEm }

    if ($Ferramenta.instalacao.pastaExtraida -and $Pacote -eq $Ferramenta.download) {
        $area = Join-Path $Temporario ('conteudo-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        Expand-Zip -Arquivo $Arquivo -Pasta $area
        $origem = Join-Path $area $Ferramenta.instalacao.pastaExtraida
        if (-not (Test-Path -LiteralPath $origem)) {
            throw ("O zip nao trouxe a pasta esperada '{0}'." -f $Ferramenta.instalacao.pastaExtraida)
        }
        $destino = Resolve-Caminho $Ferramenta.instalacao.destino
        Write-Progresso -Id $Id -Etapa 'instalando' -Porcento 92 -Detalhe ('movendo para ' + $Ferramenta.instalacao.destino)
        Move-Item -LiteralPath $origem -Destination $destino -Force
    }
    elseif ($onde) {
        Expand-Zip -Arquivo $Arquivo -Pasta (Resolve-Caminho $onde)
    }
    else {
        Expand-Zip -Arquivo $Arquivo -Pasta $PSScriptRoot
    }
}


function Invoke-PosInstalacao {
    <#
      Passos extras do catalogo. Entradas em texto sao tratadas como
      documentacao e ignoradas; so objetos com "acao" sao executados.
    #>
    param($Passos, [string]$Id)

    if ($null -eq $Passos) { return }

    foreach ($passo in $Passos) {
        if ($passo -is [string]) { continue }
        if ([string]::IsNullOrWhiteSpace($passo.acao)) { continue }

        switch ($passo.acao) {
            'criarPasta' {
                $alvo = Resolve-Caminho $passo.alvo
                Write-Progresso -Id $Id -Etapa 'ajustando' -Porcento 96 -Detalhe ('criando ' + $passo.alvo)
                New-Item -ItemType Directory -Path $alvo -Force | Out-Null
            }
            'copiar' {
                $origem = Resolve-Caminho $passo.origem
                $alvo = Resolve-Caminho $passo.alvo
                if (Test-Path -LiteralPath $origem) {
                    Write-Progresso -Id $Id -Etapa 'ajustando' -Porcento 97 -Detalhe ('copiando ' + $passo.origem)
                    $pastaAlvo = Split-Path -Parent $alvo
                    if (-not (Test-Path -LiteralPath $pastaAlvo)) { New-Item -ItemType Directory -Path $pastaAlvo -Force | Out-Null }
                    Copy-Item -LiteralPath $origem -Destination $alvo -Force
                }
            }
            'escrever' {
                $alvo = Resolve-Caminho $passo.alvo
                Write-Progresso -Id $Id -Etapa 'ajustando' -Porcento 94 -Detalhe ('escrevendo ' + $passo.alvo)
                $pastaAlvo = Split-Path -Parent $alvo
                if (-not (Test-Path -LiteralPath $pastaAlvo)) { New-Item -ItemType Directory -Path $pastaAlvo -Force | Out-Null }
                # Sem BOM de proposito: arquivos de configuracao como o ._pth
                # do Python nao toleram os bytes extras no comeco.
                $semBom = New-Object System.Text.UTF8Encoding($false)
                [IO.File]::WriteAllText($alvo, [string]$passo.conteudo, $semBom)
            }
            'baixar' {
                $alvo = Resolve-Caminho $passo.alvo
                Write-Progresso -Id $Id -Etapa 'ajustando' -Porcento 95 -Detalhe ('baixando ' + (Split-Path -Leaf $passo.alvo))
                $pastaAlvo = Split-Path -Parent $alvo
                if (-not (Test-Path -LiteralPath $pastaAlvo)) { New-Item -ItemType Directory -Path $pastaAlvo -Force | Out-Null }
                try   { Get-ArquivoComProgresso -Url $passo.url -Destino $alvo -Id $Id -Rotulo (Split-Path -Leaf $passo.alvo) | Out-Null }
                catch { Get-ArquivoComWget      -Url $passo.url -Destino $alvo -Id $Id -Rotulo (Split-Path -Leaf $passo.alvo) | Out-Null }
            }
            'rodar' {
                $programa = Resolve-Caminho $passo.programa
                if (-not (Test-Path -LiteralPath $programa)) { throw ("Passo 'rodar': nao achei {0}" -f $passo.programa) }
                $ondeRodar = $PSScriptRoot
                if ($passo.em) { $ondeRodar = Resolve-Caminho $passo.em }
                $lista = @(Split-Argumentos ([string]$passo.argumentos))
                Write-Progresso -Id $Id -Etapa 'ajustando' -Porcento 98 -Detalhe ((Split-Path -Leaf $programa) + ' ' + $passo.argumentos)
                $saida = Start-Process $programa -ArgumentList $lista -WorkingDirectory $ondeRodar -Wait -PassThru -WindowStyle Hidden
                if ($saida.ExitCode -ne 0) { throw ("Passo 'rodar' terminou com codigo {0}." -f $saida.ExitCode) }
            }
            'renomear' {
                $origem = Resolve-Caminho $passo.origem
                $alvo = Resolve-Caminho $passo.alvo
                if (Test-Path -LiteralPath $origem) {
                    Write-Progresso -Id $Id -Etapa 'ajustando' -Porcento 97 -Detalhe ('renomeando ' + $passo.origem)
                    Move-Item -LiteralPath $origem -Destination $alvo -Force
                }
            }
            default {
                Write-Progresso -Id $Id -Etapa 'ajustando' -Detalhe ('passo desconhecido: ' + $passo.acao)
            }
        }
    }
}


function Get-CadeiaInstalacao {
    <#
      Devolve, em ordem, tudo que precisa ser instalado para atender ao pedido:
      primeiro as dependencias que ainda faltam, e o pedido no fim. E o que o
      menu antigo fazia com "JDK + MAVEN", so que declarado no catalogo em vez
      de amarrado num GOTO, e valendo para qualquer combinacao.
    #>
    param($Catalogo, [string]$Id, $Vistos)

    if ($null -eq $Vistos) { $Vistos = New-Object System.Collections.Generic.List[string] }
    $ordem = New-Object System.Collections.Generic.List[string]

    if ($Vistos.Contains($Id)) { return $ordem }   # protege contra ciclo
    [void]$Vistos.Add($Id)

    $f = $Catalogo.ferramentas | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -eq $f) { return $ordem }

    foreach ($dep in @($f.requer)) {
        if ([string]::IsNullOrWhiteSpace($dep)) { continue }
        $outra = $Catalogo.ferramentas | Where-Object { $_.id -eq $dep } | Select-Object -First 1
        if ($null -eq $outra) { continue }
        if (Test-Instalada $outra) { continue }    # ja esta la, nao repete
        foreach ($x in @(Get-CadeiaInstalacao -Catalogo $Catalogo -Id $dep -Vistos $Vistos)) {
            if (-not $ordem.Contains($x)) { [void]$ordem.Add($x) }
        }
    }

    if (-not $ordem.Contains($Id)) { [void]$ordem.Add($Id) }
    return $ordem
}


function Install-Cadeia {
    param($Catalogo, [string]$Id)

    $cadeia = @(Get-CadeiaInstalacao -Catalogo $Catalogo -Id $Id)
    $script:TotalPassos = $cadeia.Count
    $script:PassoAtual = 0

    $nomes = @()
    foreach ($item in $cadeia) {
        $script:PassoAtual++
        $resultado = Install-Ferramenta -Catalogo $Catalogo -Id $item
        if (-not $resultado.ok) { return $resultado }
        $nomes += $resultado.nome
    }

    Write-Progresso -Id $Id -Etapa 'pronto' -Porcento 100 -Detalhe ($nomes -join ' + ') -Fim
    return @{ ok = $true; nome = ($nomes -join ' + ') }
}


function Install-Ferramenta {
    param($Catalogo, [string]$Id)

    $f = $Catalogo.ferramentas | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -eq $f)          { return @{ ok = $false; erro = "Ferramenta desconhecida: $Id" } }
    if ($null -eq $f.instalacao) { return @{ ok = $false; erro = "$($f.nome) nao tem receita de instalacao." } }

    $tipo = $f.instalacao.tipo
    if ($TiposSuportados -notcontains $tipo) {
        return @{ ok = $false; erro = "Instalacao do tipo '$tipo' ainda nao implementada." }
    }
    if ($null -ne $f.downloadExtra -and $tipo -ne 'zip') {
        return @{ ok = $false
                  erro = "$($f.nome) tem mais de um download, o que so esta implementado para zip." }
    }

    $temporario = Join-Path $env:TEMP ('devapp-baixa-' + $Id)
    if (Test-Path -LiteralPath $temporario) { Remove-Item -LiteralPath $temporario -Recurse -Force }
    New-Item -ItemType Directory -Path $temporario -Force | Out-Null

    try {
        Write-Progresso -Id $Id -Etapa 'preparando' -Porcento 0 -Detalhe $f.nome

        $destino = Resolve-Caminho $f.instalacao.destino
        if ($f.instalacao.limparAntes -and (Test-Path -LiteralPath $destino)) {
            Write-Progresso -Id $Id -Etapa 'limpando' -Porcento 2 -Detalhe ('removendo ' + $f.instalacao.destino)
            Remove-Item -LiteralPath $destino -Recurse -Force
        }

        $baixado = Join-Path $temporario $f.download.arquivo
        Write-Progresso -Id $Id -Etapa 'baixando' -Porcento 3 -Detalhe $f.download.arquivo
        try {
            $bytes = Get-ArquivoComProgresso -Url $f.download.url -Destino $baixado -Id $Id -Rotulo $f.download.arquivo
        }
        catch {
            Write-Progresso -Id $Id -Etapa 'baixando' -Porcento 10 -Detalhe ('falhou (' + $_.Exception.Message + ')')
            $bytes = Get-ArquivoComWget -Url $f.download.url -Destino $baixado -Id $Id -Rotulo $f.download.arquivo
        }
        if ($bytes -le 0) { throw "O download veio vazio." }

        if ($tipo -eq 'exe-direto') {
            # Nao ha o que extrair: o proprio arquivo baixado e o programa.
            Write-Progresso -Id $Id -Etapa 'instalando' -Porcento 92 -Detalhe 'copiando o executavel'
            New-Item -ItemType Directory -Path $destino -Force | Out-Null
            Copy-Item -LiteralPath $baixado -Destination (Join-Path $destino $f.download.arquivo) -Force
        }
        elseif ($tipo -eq '7z-sfx') {
            Write-Progresso -Id $Id -Etapa 'extraindo' -Porcento 85 -Detalhe 'pacote auto-extraivel (7za)'
            $ondeExtrair = $destino
            if ($f.instalacao.extrairEm) { $ondeExtrair = Resolve-Caminho $f.instalacao.extrairEm }
            Expand-SeteZip -Arquivo $baixado -Pasta $ondeExtrair
        }
        elseif ($tipo -eq 'msi-admin') {
            # Instalacao administrativa: o msiexec so desempacota os arquivos
            # no destino, sem registrar nada no sistema. E o que mantem o
            # MongoDB portatil apesar de ser distribuido como instalador.
            Write-Progresso -Id $Id -Etapa 'instalando' -Porcento 85 -Detalhe 'desempacotando o msi'
            New-Item -ItemType Directory -Path $destino -Force | Out-Null
            $saida = Start-Process 'msiexec.exe' `
                -ArgumentList @('/a', "`"$baixado`"", '/qn', "TARGETDIR=`"$destino`"") `
                -Wait -PassThru -WindowStyle Hidden
            if ($saida.ExitCode -ne 0) { throw ("msiexec falhou (codigo {0})." -f $saida.ExitCode) }
        }
        elseif ($tipo -eq 'instalador') {
            # Instalador de verdade: nao ha como evitar que mexa fora da pasta.
            Write-Progresso -Id $Id -Etapa 'instalando' -Porcento 85 -Detalhe 'rodando o instalador oficial'
            $mapaEnv = Get-Ambiente -Catalogo $Catalogo
            $listaArgs = @(Split-Argumentos (Expand-Modelo -Texto ([string]$f.instalacao.argumentos) -Mapa $mapaEnv))
            $saida = Start-Process $baixado -ArgumentList $listaArgs -Wait -PassThru
            if ($saida.ExitCode -ne 0) { throw ("O instalador terminou com codigo {0}." -f $saida.ExitCode) }
        }
        else {
            Write-Progresso -Id $Id -Etapa 'extraindo' -Porcento 80 -Detalhe ("{0:N1} MB" -f ($bytes / 1MB))
            Expand-Pacote -Ferramenta $f -Pacote $f.download -Arquivo $baixado -Temporario $temporario -Id $Id

            # Ferramentas que vem em mais de um arquivo (.NET traz SDK e
            # runtime; o SDK do Android traz cmdline-tools e platform-tools).
            # Cada pacote pode ter destino proprio.
            foreach ($extra in @($f.downloadExtra)) {
                if ($null -eq $extra) { continue }
                $outro = Join-Path $temporario $extra.arquivo
                Write-Progresso -Id $Id -Etapa 'baixando' -Porcento 85 -Detalhe $extra.arquivo
                try   { Get-ArquivoComProgresso -Url $extra.url -Destino $outro -Id $Id -Rotulo $extra.arquivo | Out-Null }
                catch { Get-ArquivoComWget      -Url $extra.url -Destino $outro -Id $Id -Rotulo $extra.arquivo | Out-Null }
                Write-Progresso -Id $Id -Etapa 'extraindo' -Porcento 90 -Detalhe $extra.arquivo
                Expand-Pacote -Ferramenta $f -Pacote $extra -Arquivo $outro -Temporario $temporario -Id $Id
            }
        }

        Invoke-PosInstalacao -Passos $f.instalacao.posInstalacao -Id $Id

        $instalada = Test-Instalada $f
        if (-not $instalada) {
            throw ("Terminou, mas o arquivo de verificacao nao apareceu: {0}" -f $f.detectar)
        }

        # Sem -Fim de proposito: quem encerra a fila e o Install-Cadeia, senao
        # a pagina pararia de acompanhar assim que a primeira peca terminasse.
        Write-Progresso -Id $Id -Etapa 'instalado' -Porcento 100 -Detalhe $f.nome
        return @{ ok = $true; nome = $f.nome }
    }
    catch {
        Write-Progresso -Id $Id -Etapa 'erro' -Porcento -1 -Detalhe $f.nome -Erro $_.Exception.Message -Fim
        return @{ ok = $false; erro = $_.Exception.Message }
    }
    finally {
        if (Test-Path -LiteralPath $temporario) {
            Remove-Item -LiteralPath $temporario -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


# ------------------------------------------------------------------
# Ambiente e execucao de ferramentas
# ------------------------------------------------------------------

function Set-Ambiente {
    <#
      Aplica as variaveis do catalogo neste processo. Como todo programa que
      o servidor abrir e filho dele, todos herdam o ambiente do DEVAPP.
      E o mesmo efeito do start.bat, que e a razao do aviso "SEMPRE EXECUTE
      OS PROGRAMAS AQUI". A alteracao vive so enquanto o processo existir:
      nada e gravado no registro nem no ambiente do Windows.
    #>
    param($Catalogo)

    $mapa = Get-Ambiente -Catalogo $Catalogo
    foreach ($nome in $mapa.Keys) {
        Set-Item -Path ('Env:' + $nome) -Value ([string]$mapa[$nome])
    }

    $pastas = @(Get-PathDevapp -Catalogo $Catalogo)
    $env:Path = ($pastas -join ';') + ';' + $env:Path

    # Arquivos de configuracao que dependem do caminho absoluto do DEVAPP.
    # Sao montados aqui, e nao na instalacao, porque o caminho muda se a
    # pasta for movida -- que e justamente o ponto de um ambiente portatil.
    $gerados = 0
    foreach ($arq in @($Catalogo.arquivosGerados)) {
        if ($null -eq $arq) { continue }
        $destino = Resolve-Caminho $arq.alvo
        $texto = Expand-Modelo -Texto ([string]$arq.conteudo) -Mapa $mapa
        $pastaDele = Split-Path -Parent $destino
        if (-not (Test-Path -LiteralPath $pastaDele)) { New-Item -ItemType Directory -Path $pastaDele -Force | Out-Null }

        # So grava se mudou: evita reescrever a cada acao do DEVAPP.
        $atual = ''
        if (Test-Path -LiteralPath $destino) { $atual = [IO.File]::ReadAllText($destino) }
        if ($atual -ne $texto) {
            [IO.File]::WriteAllText($destino, $texto, (New-Object System.Text.UTF8Encoding($false)))
        }
        $gerados++
    }

    return [pscustomobject]@{ Variaveis = $mapa.Count; Pastas = $pastas.Count; Gerados = $gerados }
}


function Expand-Modelo {
    # Troca {JAVA_HOME} e afins pelos caminhos ja resolvidos.
    param([string]$Texto, $Mapa)

    $saida = $Texto
    foreach ($nome in $Mapa.Keys) {
        $saida = $saida.Replace('{' + $nome + '}', [string]$Mapa[$nome])
    }
    return $saida
}


function Split-Argumentos {
    <#
      Quebra a linha do catalogo em partes, respeitando as aspas. Passar os
      argumentos como lista (e nao como uma string unica) evita que caminhos
      com espaco cheguem partidos ao programa.
    #>
    param([string]$Linha)

    $partes = New-Object System.Collections.Generic.List[string]
    $atual = New-Object System.Text.StringBuilder
    $entreAspas = $false

    foreach ($ch in $Linha.ToCharArray()) {
        if ($ch -eq '"') { $entreAspas = -not $entreAspas; continue }
        if ($ch -eq ' ' -and -not $entreAspas) {
            if ($atual.Length -gt 0) { $partes.Add($atual.ToString()); [void]$atual.Clear() }
            continue
        }
        [void]$atual.Append($ch)
    }
    if ($atual.Length -gt 0) { $partes.Add($atual.ToString()) }

    return $partes
}


function Start-Ferramenta {
    param($Catalogo, [string]$Id)

    $f = $Catalogo.ferramentas | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -eq $f) {
        return @{ ok = $false; erro = "Ferramenta desconhecida: $Id" }
    }
    if ([string]::IsNullOrWhiteSpace($f.executar)) {
        return @{ ok = $false; erro = "$($f.nome) nao tem comando de execucao no catalogo." }
    }
    if ($null -ne $f.servidor) {
        return @{ ok = $false; erro = "$($f.nome) e um servidor e precisa de janela propria; ainda nao suportado por aqui." }
    }
    if (-not (Test-Instalada $f)) {
        return @{ ok = $false; erro = "$($f.nome) nao esta instalado." }
    }

    $mapa = Get-Ambiente -Catalogo $Catalogo

    # O @() e obrigatorio: com um unico token o PowerShell devolveria a string
    # solta em vez da lista, e $partes[0] pegaria a primeira LETRA do caminho.
    $partes = @(Split-Argumentos (Expand-Modelo -Texto $f.executar -Mapa $mapa))

    $programa = Resolve-Caminho $partes[0]
    $argumentos = @()
    if ($partes.Count -gt 1) { $argumentos = $partes[1..($partes.Count - 1)] }

    if (-not (Test-Path -LiteralPath $programa)) {
        return @{ ok = $false; erro = "Executavel nao encontrado: $programa" }
    }

    # Arquivos .cmd e .bat nao sao executaveis para o Windows: precisam do
    # interpretador. E o caso do VS Code, que so abre por bin\code.cmd.
    $viaCmd = $programa -match '\.(cmd|bat)$'

    try {
        if ($viaCmd) {
            $lista = @('/c', $programa) + $argumentos
            Start-Process -FilePath 'cmd.exe' -ArgumentList $lista -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
        }
        elseif ($argumentos.Count -gt 0) {
            Start-Process -FilePath $programa -ArgumentList $argumentos -WorkingDirectory $PSScriptRoot | Out-Null
        }
        else {
            Start-Process -FilePath $programa -WorkingDirectory $PSScriptRoot | Out-Null
        }
        Write-Host ("  Abrindo {0}" -f $f.nome)
        return @{ ok = $true; nome = $f.nome }
    }
    catch {
        return @{ ok = $false; erro = $_.Exception.Message }
    }
}


# ------------------------------------------------------------------
# Extensoes do VS Code
# ------------------------------------------------------------------

function Get-ExtensoesInstaladas {
    <#
      O VS Code guarda cada extensao numa pasta "publicador.nome-versao", e
      as que tem build por plataforma ganham sufixo depois disso:

        eamodio.gitlens-19.0.1
        ms-python.python-2026.4.0-win32-x64

      Por isso o corte nao pode ser no ultimo hifen (viraria
      "ms-python.python-2026.4.0-win32"): o identificador e tudo que vem antes
      do numero de versao. E a informacao que o menu antigo nunca teve: la,
      reinstalar uma categoria refazia tudo as cegas.
    #>
    $pasta = Resolve-Caminho 'vscode/extensions'
    $achadas = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $pasta)) { return $achadas }

    foreach ($d in (Get-ChildItem -LiteralPath $pasta -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^(.+)-\d+\.\d+\.\d+') {
            $id = $Matches[1]
            if (-not $achadas.Contains($id)) { [void]$achadas.Add($id) }
        }
    }
    return $achadas
}


function Get-CategoriasExtensoes {
    param($Catalogo)

    $instaladas = @(Get-ExtensoesInstaladas)
    $lista = New-Object System.Collections.Generic.List[object]

    foreach ($cat in $Catalogo.extensoesVSCode) {
        $itens = @($cat.itens)
        $faltando = @($itens | Where-Object { $instaladas -notcontains $_ })
        $lista.Add([pscustomobject]@{
            Id        = $cat.id
            Nome      = $cat.nome
            Total     = $itens.Count
            Instaladas = ($itens.Count - $faltando.Count)
            Faltando  = $faltando
        })
    }
    return $lista
}


function Install-Extensoes {
    param($Catalogo, [string]$Categoria)

    $vscode = Resolve-Caminho 'vscode/bin/code.cmd'
    if (-not (Test-Path -LiteralPath $vscode)) {
        return @{ ok = $false; erro = 'O VS Code do DEVAPP nao esta instalado.' }
    }

    $cat = $Catalogo.extensoesVSCode | Where-Object { $_.id -eq $Categoria } | Select-Object -First 1
    if ($null -eq $cat) { return @{ ok = $false; erro = "Categoria desconhecida: $Categoria" } }

    $instaladas = @(Get-ExtensoesInstaladas)
    $faltando = @($cat.itens | Where-Object { $instaladas -notcontains $_ })

    if ($faltando.Count -eq 0) {
        Write-Progresso -Id $Categoria -Etapa 'pronto' -Porcento 100 -Detalhe ('Nada a fazer em ' + $cat.nome) -Fim
        return @{ ok = $true; nome = $cat.nome; instaladas = 0 }
    }

    $dirExt = Resolve-Caminho 'vscode/extensions'
    $dirUsr = Resolve-Caminho 'vscode/userdir'
    $feitas = 0
    $falhas = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $faltando.Count; $i++) {
        $ext = $faltando[$i]
        $pct = [int](($i * 100) / $faltando.Count)
        Write-Progresso -Id $Categoria -Etapa 'instalando' -Porcento $pct `
            -Detalhe ("{0}  ({1} de {2})" -f $ext, ($i + 1), $faltando.Count)

        # Uma de cada vez: no start.bat elas eram encadeadas com &&, entao a
        # primeira que falhasse levava junto todas as seguintes, em silencio.
        $r = Start-Process 'cmd.exe' -ArgumentList @('/c', $vscode,
                '--extensions-dir', $dirExt, '--user-data-dir', $dirUsr,
                '--install-extension', $ext, '--force') `
                -Wait -PassThru -WindowStyle Hidden
        if ($r.ExitCode -eq 0) { $feitas++ } else { [void]$falhas.Add($ext) }
    }

    $recado = ("{0}: {1} instalada(s)" -f $cat.nome, $feitas)
    if ($falhas.Count -gt 0) { $recado += ("; falharam: " + ($falhas -join ', ')) }
    Write-Progresso -Id $Categoria -Etapa 'pronto' -Porcento 100 -Detalhe $recado -Fim
    return @{ ok = $true; nome = $cat.nome; instaladas = $feitas; falhas = @($falhas) }
}


# ------------------------------------------------------------------
# Servidores de banco de dados
# ------------------------------------------------------------------

$ArquivoBancos = Join-Path $env:TEMP 'devapp-bancos.json'

function Resolve-Comando {
    # Uma linha do catalogo vira programa + lista de argumentos.
    param($Catalogo, [string]$Linha)

    $partes = @(Split-Argumentos (Expand-Modelo -Texto $Linha -Mapa (Get-Ambiente -Catalogo $Catalogo)))
    $argumentos = @()
    if ($partes.Count -gt 1) { $argumentos = $partes[1..($partes.Count - 1)] }
    return @{ programa = (Resolve-Caminho $partes[0]); argumentos = $argumentos }
}


function Get-EstadoBancos {
    <#
      Quem esta no ar. O arquivo sobrevive ao fechamento da interface, entao
      um banco iniciado ontem continua sendo reconhecido hoje. Processos que
      morreram sao descartados na leitura, para nao mentir "rodando".
    #>
    $estado = @{}
    if (Test-Path -LiteralPath $ArquivoBancos) {
        try {
            $bruto = Get-Content -LiteralPath $ArquivoBancos -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $bruto.PSObject.Properties) {
                $vivo = Get-Process -Id $p.Value.pid -ErrorAction SilentlyContinue
                if ($vivo) {
                    $estado[$p.Name] = @{ pid = $p.Value.pid; porta = $p.Value.porta; desde = $p.Value.desde }
                }
            }
        }
        catch { }
    }
    return $estado
}


function Save-EstadoBancos {
    param($Estado)
    try { ($Estado | ConvertTo-Json -Compress) | Set-Content -LiteralPath $ArquivoBancos -Encoding UTF8 }
    catch { }
}


function Start-Banco {
    param($Catalogo, [string]$Id)

    $f = $Catalogo.ferramentas | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -eq $f)          { return @{ ok = $false; erro = "Ferramenta desconhecida: $Id" } }
    if ($null -eq $f.servidor) { return @{ ok = $false; erro = "$($f.nome) nao e um servidor." } }
    if (-not (Test-Instalada $f)) { return @{ ok = $false; erro = "$($f.nome) nao esta instalado." } }

    $estado = Get-EstadoBancos
    if ($estado.ContainsKey($Id)) {
        return @{ ok = $false; erro = "$($f.nome) ja esta rodando (processo $($estado[$Id].pid))." }
    }

    # MySQL e MariaDB dividem a porta 3360: os dois no ar ao mesmo tempo e
    # impossivel, e a mensagem precisa dizer isso em vez de deixar o segundo
    # morrer sozinho com um erro de socket.
    foreach ($outroId in $estado.Keys) {
        if ($estado[$outroId].porta -eq $f.servidor.porta) {
            $outro = $Catalogo.ferramentas | Where-Object { $_.id -eq $outroId } | Select-Object -First 1
            return @{ ok = $false
                      erro = "A porta $($f.servidor.porta) ja esta ocupada por $($outro.nome). Pare ele antes." }
        }
    }

    try {
        # Primeira execucao: criar a base. So uma vez, e a marca no disco diz
        # se ja foi feito.
        if ($f.primeiraExecucao) {
            $jaTem = $false
            if ($f.marcaInicializado) { $jaTem = Test-Path -LiteralPath (Resolve-Caminho $f.marcaInicializado) }
            if (-not $jaTem) {
                Write-Host ("  Preparando a base de {0} (primeira vez)..." -f $f.nome)
                $ini = Resolve-Comando -Catalogo $Catalogo -Linha $f.primeiraExecucao
                $r = Start-Process $ini.programa -ArgumentList $ini.argumentos -WorkingDirectory $PSScriptRoot -Wait -PassThru -WindowStyle Hidden
                if ($r.ExitCode -ne 0) { throw ("A preparacao da base falhou (codigo {0})." -f $r.ExitCode) }
            }
        }

        $cmd = Resolve-Comando -Catalogo $Catalogo -Linha $f.executar
        if (-not (Test-Path -LiteralPath $cmd.programa)) {
            throw ("Executavel nao encontrado: {0}" -f $cmd.programa)
        }

        $proc = Start-Process $cmd.programa -ArgumentList $cmd.argumentos `
                    -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden

        Start-Sleep -Milliseconds 1500
        if ($proc.HasExited) {
            throw ("O servidor subiu e caiu na hora (codigo {0}). Confira se a porta esta livre." -f $proc.ExitCode)
        }

        $estado[$Id] = @{ pid = $proc.Id; porta = $f.servidor.porta; desde = (Get-Date).ToString('s') }
        Save-EstadoBancos $estado
        Write-Host ("  {0} no ar na porta {1} (processo {2})" -f $f.nome, $f.servidor.porta, $proc.Id)
        return @{ ok = $true; nome = $f.nome; pid = $proc.Id; porta = $f.servidor.porta }
    }
    catch {
        return @{ ok = $false; erro = $_.Exception.Message }
    }
}


function Stop-Banco {
    param($Catalogo, [string]$Id)

    $f = $Catalogo.ferramentas | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -eq $f) { return @{ ok = $false; erro = "Ferramenta desconhecida: $Id" } }

    $estado = Get-EstadoBancos
    if (-not $estado.ContainsKey($Id)) { return @{ ok = $false; erro = "$($f.nome) nao esta rodando." } }
    $numero = $estado[$Id].pid

    try {
        # Preferir sempre o comando proprio de parada: derrubar um banco no
        # tapa pode deixar a base inconsistente. O encerramento a forca fica
        # como ultimo recurso, e o Neo4j em modo console so tem esse caminho.
        if ($f.parar) {
            $cmd = Resolve-Comando -Catalogo $Catalogo -Linha $f.parar
            Start-Process $cmd.programa -ArgumentList $cmd.argumentos -WorkingDirectory $PSScriptRoot -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-Process -Id $numero -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 500
            }
        }

        $aindaVivo = Get-Process -Id $numero -ErrorAction SilentlyContinue
        $modo = 'pelo comando de parada'
        if ($aindaVivo) {
            # taskkill /T, e nao Stop-Process: quando o servidor e iniciado por
            # um .bat (Neo4j), o processo que rastreamos e o cmd.exe, e o banco
            # de verdade e um filho dele. Encerrar so o pai deixava o servidor
            # no ar enquanto o DEVAPP anunciava que tinha parado.
            & taskkill /PID $numero /T /F 2>&1 | Out-Null
            Start-Sleep -Milliseconds 800
            $modo = 'encerrado a forca'
        }

        # Confere o resultado em vez de presumir: se a porta continua ocupada,
        # alguma coisa sobreviveu e quem chamou precisa saber.
        if ($f.servidor -and $f.servidor.porta) {
            $presa = Get-NetTCPConnection -LocalPort $f.servidor.porta -State Listen -ErrorAction SilentlyContinue
            if ($presa) {
                return @{ ok = $false
                          erro = ("Mandei parar, mas a porta {0} continua ocupada. Algum processo sobreviveu." -f $f.servidor.porta) }
            }
        }

        $estado.Remove($Id)
        Save-EstadoBancos $estado
        Write-Host ("  {0} parado ({1})" -f $f.nome, $modo)
        return @{ ok = $true; nome = $f.nome; modo = $modo }
    }
    catch {
        return @{ ok = $false; erro = $_.Exception.Message }
    }
}


# ------------------------------------------------------------------
# Servidor local da interface web
# ------------------------------------------------------------------

function Get-PortaLivre {
    param([int]$Inicio = 8787, [int]$Tentativas = 25)

    for ($p = $Inicio; $p -lt ($Inicio + $Tentativas); $p++) {
        $teste = New-Object System.Net.HttpListener
        $teste.Prefixes.Add("http://127.0.0.1:$p/")
        try {
            $teste.Start()
            $teste.Stop()
            $teste.Close()
            return $p
        }
        catch {
            $teste.Close()
        }
    }
    throw "Nenhuma porta livre entre $Inicio e $($Inicio + $Tentativas - 1)."
}


function Send-Resposta {
    param($Contexto, [int]$Codigo, [string]$Tipo, [byte[]]$Corpo)

    $resposta = $Contexto.Response
    $resposta.StatusCode = $Codigo
    $resposta.ContentType = $Tipo
    $resposta.Headers.Add('Cache-Control', 'no-store')
    $resposta.ContentLength64 = $Corpo.Length
    $resposta.OutputStream.Write($Corpo, 0, $Corpo.Length)
    $resposta.OutputStream.Close()
}


function Send-Texto {
    param($Contexto, [int]$Codigo, [string]$Tipo, [string]$Texto)
    Send-Resposta $Contexto $Codigo $Tipo ([System.Text.Encoding]::UTF8.GetBytes($Texto))
}


function Start-Servidor {
    param([int]$Porta, [switch]$NaoAbrir)

    $arquivoUi = Join-Path $PSScriptRoot 'ui\index.html'
    if (-not (Test-Path -LiteralPath $arquivoUi)) {
        throw "Interface nao encontrada em: $arquivoUi"
    }

    if ($Porta -le 0) { $Porta = Get-PortaLivre }

    # Chave gerada a cada execucao. Sem ela a API responde 403, o que impede
    # qualquer pagina aberta no navegador de conversar com este servidor.
    $chave = [guid]::NewGuid().ToString('N')
    $base = "http://127.0.0.1:$Porta/"
    $endereco = $base + '?t=' + $chave

    $ambiente = [pscustomobject]@{ Variaveis = (Get-Ambiente -Catalogo (Import-Catalogo)).Count; Pastas = @(Get-PathDevapp -Catalogo (Import-Catalogo)).Count }

    # Processo ajudante da instalacao em andamento, se houver. O servidor
    # nunca baixa nada em maos proprias: se baixasse, ficaria surdo enquanto
    # isso durasse, e a propria barra de progresso deixaria de responder.
    $ajudante = $null

    $ouvinte = New-Object System.Net.HttpListener
    $ouvinte.Prefixes.Add($base)
    $ouvinte.Start()

    Write-Host ''
    Write-Host ("  Ambiente aplicado: {0} variaveis, {1} pastas no PATH." -f $ambiente.Variaveis, $ambiente.Pastas)
    Write-Host "  DEVAPP no ar em $base"
    Write-Host "  Endereco com chave: $endereco"
    Write-Host '  Acessivel somente por esta maquina (127.0.0.1).'
    Write-Host '  Para encerrar, pressione Ctrl+C nesta janela.'
    Write-Host ''

    if (-not $NaoAbrir) { Start-Process $endereco | Out-Null }

    try {
        while ($ouvinte.IsListening) {

            $contexto = $ouvinte.GetContext()
            $caminho = $contexto.Request.Url.AbsolutePath
            $chaveEnviada = $contexto.Request.QueryString['t']

            if ($caminho -eq '/' -or $caminho -eq '/index.html') {
                $html = Get-Content -LiteralPath $arquivoUi -Raw -Encoding UTF8
                Send-Texto $contexto 200 'text/html; charset=utf-8' $html
            }
            elseif ($caminho -eq '/api/status') {
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                else {
                    # Recarrega o catalogo a cada pedido: assim o botao Atualizar
                    # reflete tanto instalacoes novas quanto edicoes no JSON.
                    $atual = Import-Catalogo
                    $pacote = [pscustomobject]@{
                        raiz        = $PSScriptRoot
                        geradoEm    = (Get-Date).ToString('s')
                        ferramentas = (Get-Status -Catalogo $atual)
                        extensoes   = (Get-CategoriasExtensoes -Catalogo $atual)
                        links       = $atual.linksExternos
                    }
                    Send-Texto $contexto 200 'application/json; charset=utf-8' ($pacote | ConvertTo-Json -Depth 6)
                }
            }
            elseif ($caminho -eq '/api/instalar') {
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                elseif ($contexto.Request.HttpMethod -ne 'POST') {
                    Send-Texto $contexto 405 'text/plain; charset=utf-8' 'use POST'
                }
                elseif ($null -ne $ajudante -and -not $ajudante.HasExited) {
                    Send-Texto $contexto 409 'application/json; charset=utf-8' `
                        '{"ok":false,"erro":"Ja existe uma instalacao em andamento."}'
                }
                else {
                    $pedido = $contexto.Request.QueryString['id']
                    $cat = Import-Catalogo
                    $alvo = $cat.ferramentas | Where-Object { $_.id -eq $pedido } | Select-Object -First 1

                    $recusa = ''
                    if ($null -eq $alvo)            { $recusa = "Ferramenta desconhecida: $pedido" }
                    elseif ($null -eq $alvo.instalacao) { $recusa = "$($alvo.nome) nao tem receita de instalacao." }
                    elseif ($TiposSuportados -notcontains $alvo.instalacao.tipo) {
                        $recusa = "Instalacao do tipo '$($alvo.instalacao.tipo)' ainda nao implementada."
                    }
                    elseif ($null -ne $alvo.downloadExtra -and $alvo.instalacao.tipo -ne 'zip') {
                        $recusa = "$($alvo.nome) tem mais de um download, o que so esta implementado para zip."
                    }

                    if ($recusa -eq '') {
                        # Uma dependencia impossivel de instalar inviabiliza o
                        # pedido inteiro: melhor recusar agora do que parar no meio.
                        foreach ($passoId in @(Get-CadeiaInstalacao -Catalogo $cat -Id $pedido)) {
                            $peca = $cat.ferramentas | Where-Object { $_.id -eq $passoId } | Select-Object -First 1
                            if ($null -eq $peca.instalacao -or $TiposSuportados -notcontains $peca.instalacao.tipo) {
                                $recusa = "$($alvo.nome) depende de $($peca.nome), que ainda nao tem instalacao automatica."
                                break
                            }
                        }
                    }

                    if ($recusa -ne '') {
                        Send-Texto $contexto 400 'application/json; charset=utf-8' `
                            (@{ ok = $false; erro = $recusa } | ConvertTo-Json -Compress)
                    }
                    else {
                        # Apaga o progresso antigo para a pagina nao ler sobra.
                        if (Test-Path -LiteralPath $ArquivoProgresso) {
                            Remove-Item -LiteralPath $ArquivoProgresso -Force -ErrorAction SilentlyContinue
                        }
                        $script = Join-Path $PSScriptRoot 'devapp.ps1'
                        $ajudante = Start-Process powershell `
                            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Acao', 'instalar', '-Id', $pedido `
                            -WindowStyle Hidden -PassThru
                        Write-Host ("  Instalando {0} (processo {1})" -f $alvo.nome, $ajudante.Id)
                        Send-Texto $contexto 200 'application/json; charset=utf-8' `
                            (@{ ok = $true; nome = $alvo.nome } | ConvertTo-Json -Compress)
                    }
                }
            }
            elseif ($caminho -eq '/api/progresso') {
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                else {
                    $texto = '{"etapa":"parado"}'
                    if (Test-Path -LiteralPath $ArquivoProgresso) {
                        try { $texto = Get-Content -LiteralPath $ArquivoProgresso -Raw -Encoding UTF8 } catch { }
                    }
                    # Se o ajudante morreu sem escrever o fim, a pagina ficaria
                    # esperando para sempre. Avisa que acabou de qualquer jeito.
                    if ($null -ne $ajudante -and $ajudante.HasExited -and $texto -notmatch '"fim":true') {
                        $texto = '{"etapa":"erro","fim":true,"erro":"A instalacao terminou sem concluir. Veja a janela do servidor."}'
                    }
                    Send-Texto $contexto 200 'application/json; charset=utf-8' $texto
                }
            }
            elseif ($caminho -eq '/api/terminal') {
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                elseif ($contexto.Request.HttpMethod -ne 'POST') {
                    Send-Texto $contexto 405 'text/plain; charset=utf-8' 'use POST'
                }
                else {
                    # O ambiente ja foi aplicado neste processo, e todo filho o
                    # herda. E o "SEMPRE EXECUTE OS PROGRAMAS AQUI" do menu
                    # antigo, sem precisar passar pelo menu.
                    $saudacao = 'title DEVAPP & echo Ambiente do DEVAPP carregado: java, node, python, git e os demais ja respondem aqui. & echo.'
                    Start-Process 'cmd.exe' -ArgumentList @('/k', $saudacao) -WorkingDirectory $PSScriptRoot | Out-Null
                    Write-Host '  Terminal aberto com o ambiente do DEVAPP.'
                    Send-Texto $contexto 200 'application/json; charset=utf-8' '{"ok":true}'
                }
            }
            elseif ($caminho -eq '/api/extensoes') {
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                elseif ($contexto.Request.HttpMethod -ne 'POST') {
                    Send-Texto $contexto 405 'text/plain; charset=utf-8' 'use POST'
                }
                elseif ($null -ne $ajudante -and -not $ajudante.HasExited) {
                    Send-Texto $contexto 409 'application/json; charset=utf-8' '{"ok":false,"erro":"Ja existe uma instalacao em andamento."}'
                }
                else {
                    $qual = $contexto.Request.QueryString['categoria']
                    if (Test-Path -LiteralPath $ArquivoProgresso) {
                        Remove-Item -LiteralPath $ArquivoProgresso -Force -ErrorAction SilentlyContinue
                    }
                    $script = Join-Path $PSScriptRoot 'devapp.ps1'
                    $ajudante = Start-Process powershell `
                        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Acao', 'extensoes', '-Id', $qual `
                        -WindowStyle Hidden -PassThru
                    Write-Host ("  Instalando extensoes da categoria {0} (processo {1})" -f $qual, $ajudante.Id)
                    Send-Texto $contexto 200 'application/json; charset=utf-8' (@{ ok = $true; categoria = $qual } | ConvertTo-Json -Compress)
                }
            }
            elseif ($caminho -eq '/api/banco/iniciar' -or $caminho -eq '/api/banco/parar') {
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                elseif ($contexto.Request.HttpMethod -ne 'POST') {
                    Send-Texto $contexto 405 'text/plain; charset=utf-8' 'use POST'
                }
                else {
                    $cat = Import-Catalogo
                    $quem = $contexto.Request.QueryString['id']
                    if ($caminho -eq '/api/banco/iniciar') { $resultado = Start-Banco -Catalogo $cat -Id $quem }
                    else                                   { $resultado = Stop-Banco  -Catalogo $cat -Id $quem }
                    $codigo = 400
                    if ($resultado.ok) { $codigo = 200 }
                    Send-Texto $contexto $codigo 'application/json; charset=utf-8' ($resultado | ConvertTo-Json -Compress)
                }
            }
            elseif ($caminho -eq '/api/executar') {
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                elseif ($contexto.Request.HttpMethod -ne 'POST') {
                    Send-Texto $contexto 405 'text/plain; charset=utf-8' 'use POST'
                }
                else {
                    $resultado = Start-Ferramenta -Catalogo (Import-Catalogo) -Id $contexto.Request.QueryString['id']
                    $codigo = 400
                    if ($resultado.ok) { $codigo = 200 }
                    Send-Texto $contexto $codigo 'application/json; charset=utf-8' ($resultado | ConvertTo-Json -Compress)
                }
            }
            elseif ($caminho -eq '/api/sair') {
                # Exige POST: assim um simples GET perdido (pre-carregamento do
                # navegador, historico, link) nao consegue derrubar o servidor.
                if ($chaveEnviada -ne $chave) {
                    Send-Texto $contexto 403 'text/plain; charset=utf-8' 'chave invalida'
                }
                elseif ($contexto.Request.HttpMethod -ne 'POST') {
                    Send-Texto $contexto 405 'text/plain; charset=utf-8' 'use POST'
                }
                else {
                    # Responde primeiro, so depois desliga: senao a pagina recebe
                    # uma conexao cortada em vez da confirmacao.
                    Send-Texto $contexto 200 'application/json; charset=utf-8' '{"ok":true}'
                    Write-Host '  Encerramento pedido pela interface.'
                    $ouvinte.Stop()
                }
            }
            elseif ($caminho -eq '/favicon.ico') {
                Send-Resposta $contexto 204 'image/x-icon' (New-Object byte[] 0)
            }
            else {
                Send-Texto $contexto 404 'text/plain; charset=utf-8' 'nao encontrado'
            }
        }
    }
    finally {
        $ouvinte.Stop()
        $ouvinte.Close()
        Write-Host ''
        Write-Host '  Servidor encerrado.'
        Write-Host ''
    }
}


# ------------------------------------------------------------------
# Execucao
# ------------------------------------------------------------------

$catalogo = Import-Catalogo

# Toda acao que LANCA alguma coisa precisa do ambiente do DEVAPP aplicado.
# Faltava aqui: so o "servir" aplicava, entao "iniciar -Id neo4j" subia o
# banco com o Java do sistema em vez do JDK do DEVAPP -- e numa maquina sem
# Java instalado nem subia, apesar do JDK estar na pasta ao lado.
if (@('servir', 'instalar', 'iniciar', 'parar', 'extensoes') -contains $Acao) {
    [void](Set-Ambiente -Catalogo $catalogo)
}

switch ($Acao) {

    'status' {
        Show-Status (Get-Status -Catalogo $catalogo -Filtro $Id)
    }

    'env' {
        Show-Ambiente (Get-Ambiente -Catalogo $catalogo)
    }

    'path' {
        Show-Path (Get-PathDevapp -Catalogo $catalogo)
    }

    'json' {
        $saida = [pscustomobject]@{
            raiz        = $PSScriptRoot
            geradoEm    = (Get-Date).ToString('s')
            ambiente    = (Get-Ambiente -Catalogo $catalogo)
            path        = (Get-PathDevapp -Catalogo $catalogo)
            ferramentas = (Get-Status -Catalogo $catalogo -Filtro $Id)
            links       = $catalogo.linksExternos
        }
        $saida | ConvertTo-Json -Depth 6
    }

    'doutor' {
        Show-Doutor -Catalogo $catalogo -Itens (Get-Status -Catalogo $catalogo)
    }

    'servir' {
        Start-Servidor -Porta $Porta -NaoAbrir:$NaoAbrir
    }

    'extensoes' {
        if ([string]::IsNullOrWhiteSpace($Id)) {
            Write-Host ''
            foreach ($c in (Get-CategoriasExtensoes -Catalogo $catalogo)) {
                Write-Host ('  {0,-12} {1,-38} {2,2} de {3,2} instaladas' -f $c.Id, $c.Nome, $c.Instaladas, $c.Total)
            }
            Write-Host ''
        }
        else {
            Write-Host ''
            $r = Install-Extensoes -Catalogo $catalogo -Categoria $Id
            if (-not $r.ok) { Write-Host ('  Falhou: {0}' -f $r.erro) }
            Write-Host ''
        }
    }

    'bancos' {
        $noAr = Get-EstadoBancos
        Write-Host ''
        if ($noAr.Count -eq 0) { Write-Host '  Nenhum servidor de banco no ar.' }
        else {
            foreach ($k in $noAr.Keys) {
                $b = $Catalogo.ferramentas | Where-Object { $_.id -eq $k } | Select-Object -First 1
                Write-Host ('  {0,-12} porta {1,-6} processo {2,-7} desde {3}' -f $b.nome, $noAr[$k].porta, $noAr[$k].pid, $noAr[$k].desde)
            }
        }
        Write-Host ''
    }

    'iniciar' {
        if ([string]::IsNullOrWhiteSpace($Id)) { throw 'Informe qual banco. Exemplo: .\devapp.ps1 -Acao iniciar -Id mariadb' }
        Write-Host ''
        $r = Start-Banco -Catalogo $catalogo -Id $Id
        if (-not $r.ok) { Write-Host ('  Falhou: {0}' -f $r.erro) }
        Write-Host ''
    }

    'parar' {
        if ([string]::IsNullOrWhiteSpace($Id)) { throw 'Informe qual banco. Exemplo: .\devapp.ps1 -Acao parar -Id mariadb' }
        Write-Host ''
        $r = Stop-Banco -Catalogo $catalogo -Id $Id
        if (-not $r.ok) { Write-Host ('  Falhou: {0}' -f $r.erro) }
        Write-Host ''
    }

    'instalar' {
        if ([string]::IsNullOrWhiteSpace($Id)) {
            throw "Informe qual ferramenta instalar. Exemplo: .\devapp.ps1 -Acao instalar -Id putty"
        }
        Write-Host ''
        $r = Install-Cadeia -Catalogo $catalogo -Id $Id
        Write-Host ''
        if ($r.ok) { Write-Host ("  {0} instalado." -f $r.nome) }
        else       { Write-Host ("  Falhou: {0}" -f $r.erro) }
        Write-Host ''
    }
}
