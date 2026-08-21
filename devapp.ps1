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

.PARAMETER Id
    Filtra por uma ferramenta especifica (ex: -Id mariadb).

.EXAMPLE
    .\devapp.ps1
    .\devapp.ps1 -Acao env
    .\devapp.ps1 -Acao status -Id mysql
    .\devapp.ps1 -Acao json > status.json
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'env', 'path', 'json', 'doutor')]
    [string]$Acao = 'status',

    [string]$Id
)

$ErrorActionPreference = 'Stop'

# Valores do bloco "ambiente" que sao configuracao, nao caminho de pasta.
$ValoresNaoCaminho = @('PGDATABASE', 'PGUSER', 'PGPORT')


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

    foreach ($f in $Catalogo.ferramentas) {
        if (-not [string]::IsNullOrWhiteSpace($Filtro)) {
            if ($f.id -ne $Filtro) { continue }
        }

        $implementada = $true
        if ($null -ne $f.implementado) { $implementada = [bool]$f.implementado }

        $resultado.Add([pscustomobject]@{
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
            PerfilUsuario = $f.perfilUsuario
        })
    }

    return $resultado
}


function Show-Status {
    param($Itens)

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
    Write-Host ("1. Deteccao inferida ({0}) - o start.bat nao tinha IF EXIST; conferir:" -f $inferidas.Count)
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

    $sujam = @($Itens | Where-Object { $null -ne $_.PerfilUsuario })
    Write-Host ("3. Escrevem no seu perfil ao serem usadas ({0}):" -f $sujam.Count)
    foreach ($x in $sujam) {
        Write-Host ("     {0,-22} {1}" -f $x.Nome, ($x.PerfilUsuario -join ', '))
    }
    Write-Host ""

    $semRotina = @($Itens | Where-Object { -not $_.Implementada })
    if ($semRotina.Count -gt 0) {
        Write-Host ("4. Estao no catalogo mas nunca tiveram rotina ({0}):" -f $semRotina.Count)
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
    Write-Host "5. Portas de servidor:"
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
# Execucao
# ------------------------------------------------------------------

$catalogo = Import-Catalogo

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
}
