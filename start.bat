@echo off
setlocal
title DEVAPP

:: ------------------------------------------------------------------
:: Lancador do DEVAPP: abre a interface no navegador.
::
:: Escrito em ASCII puro e sem chcp de proposito. O start.bat original
:: mistura UTF-8 com acentos e chcp 65001, e isso deixa o interpretador
:: de lote instavel: uma edicao em qualquer ponto do arquivo pode fazer
:: o cmd executar o meio de outra linha. Este arquivo fica pequeno e
:: sem acento nenhum justamente para nunca cair nisso.
:: ------------------------------------------------------------------

cd /d "%~dp0"

if not exist "%~dp0devapp.ps1" (
    echo.
    echo   ERRO: nao encontrei o devapp.ps1 nesta pasta.
    echo   Extraia o pacote inteiro do DEVAPP antes de abrir.
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0catalogo.json" (
    echo.
    echo   ERRO: nao encontrei o catalogo.json nesta pasta.
    echo   Extraia o pacote inteiro do DEVAPP antes de abrir.
    echo.
    pause
    exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
    echo.
    echo   ERRO: o Windows PowerShell nao foi encontrado no PATH.
    echo   O DEVAPP precisa dele para funcionar.
    echo.
    pause
    exit /b 1
)

echo.
echo   ------------------------------------------------
echo    DEVAPP - ambiente de desenvolvimento portatil
echo   ------------------------------------------------
echo.
echo   Abrindo a interface no seu navegador...
echo.
echo   Esta janela e o servidor: deixe ela aberta enquanto
echo   estiver usando. Para sair, use o botao "Encerrar
echo   servidor" na pagina, ou feche esta janela.
echo.

:: -ExecutionPolicy Bypass e obrigatorio, nao e atalho: quando o DEVAPP
:: e baixado do GitHub, o Windows marca o .ps1 como vindo da internet e
:: a politica RemoteSigned recusa executa-lo. Sem esta linha, o projeto
:: funcionaria so na maquina de quem escreveu o arquivo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0devapp.ps1" -Acao servir

if errorlevel 1 (
    echo.
    echo   O DEVAPP terminou com erro. A mensagem esta acima.
    echo.
    pause
) else (
    echo.
    echo   DEVAPP encerrado.
    timeout /t 3 /nobreak >nul 2>&1
)

endlocal
