# DEVAPP

Ambiente de desenvolvimento portátil para Windows. Baixa, instala e executa
ferramentas de programação e bancos de dados **dentro da própria pasta**, sem
instalar nada no sistema e sem exigir privilégio de administrador.

Copiar a pasta para outro computador leva o ambiente inteiro junto.

---

## 1. Como usar

Extraia o pacote em qualquer lugar (por exemplo `C:\DEVAPP`) e dê **duplo clique
em `start.bat`**.

Ele abre a interface do DEVAPP no seu navegador. A janela preta que aparece é o
servidor: deixe aberta enquanto estiver usando. Para encerrar, use o botão
**Encerrar servidor** na página ou feche a janela.

> A interface roda em `127.0.0.1`, acessível somente pela sua máquina. Cada
> execução gera uma chave própria, então nenhuma página aberta no navegador
> consegue conversar com ele por trás dos panos.

---

## 2. O que a interface faz

**Ver o que está instalado.** Cada ferramenta vira um cartão com nome, versão e
um selo dizendo se está presente. A busca filtra por nome ou categoria, e há um
filtro para mostrar só o que falta.

**Instalar.** O botão baixa, extrai e posiciona a ferramenta, com barra de
progresso mostrando os megabytes. A instalação só é dada como concluída depois
que o arquivo de verificação aparece no disco.

Dependências são resolvidas sozinhas: mandar instalar o Maven instala o JDK
antes, porque Maven não roda sem ele. O cartão avisa disso antes do clique.

**Executar.** Abre a ferramenta já dentro do ambiente do DEVAPP — as variáveis
e os caminhos são herdados automaticamente.

**Subir e parar bancos de dados.** MySQL, MariaDB, PostgreSQL, MongoDB e Neo4j
têm botões próprios. A base é preparada sozinha na primeira vez. A parada usa o
comando próprio de cada banco (`mysqladmin shutdown`, `pg_ctl stop`), porque
derrubar um banco no tapa pode corromper os dados; o encerramento à força só
entra se o comando não responder, e a interface diz qual dos dois aconteceu.

**Extensões do VS Code por categoria.** Seis categorias — Java/Spring, Frontend,
Python, .NET, Flutter e Utilitários. A interface sabe quais já estão instaladas
e oferece instalar só as que faltam.

**Abrir um terminal com o ambiente.** Um prompt onde `java`, `node`, `python`,
`git` e as demais já respondem, sem precisar instalar nada no sistema.

**Tema claro e escuro**, lembrado no navegador.

---

## 3. Linha de comando

A interface é uma casca sobre o `devapp.ps1`, que também funciona sozinho:

```powershell
.\devapp.ps1                      # o que está instalado
.\devapp.ps1 -Acao env            # variáveis de ambiente resolvidas
.\devapp.ps1 -Acao path           # pastas que entram no PATH
.\devapp.ps1 -Acao doutor         # pendências e riscos do catálogo
.\devapp.ps1 -Acao json           # tudo em JSON

.\devapp.ps1 -Acao instalar  -Id maven
.\devapp.ps1 -Acao iniciar   -Id mariadb
.\devapp.ps1 -Acao parar     -Id mariadb
.\devapp.ps1 -Acao bancos              # quais bancos estão no ar
.\devapp.ps1 -Acao extensoes           # categorias do VS Code
.\devapp.ps1 -Acao extensoes -Id java  # instala uma categoria
.\devapp.ps1 -Acao servir              # sobe a interface
```

No Git Bash, use `powershell -ExecutionPolicy Bypass -File devapp.ps1 -Acao ...`.

O `-Acao doutor` é útil para revisar o catálogo: ele cruza os dados e aponta
detecções que foram deduzidas, ferramentas que não são portáteis, o que escreve
no seu perfil e conflitos de porta entre servidores.

---

## 4. Acrescentar uma ferramenta

Toda ferramenta é um bloco no [`catalogo.json`](catalogo.json). Não há código a
escrever:

```json
{
  "id": "minha-ferramenta",
  "nome": "Minha Ferramenta",
  "versao": "1.0",
  "categoria": "Utilitarios",
  "download": { "url": "https://...", "arquivo": "pacote.zip" },
  "instalacao": { "tipo": "zip", "destino": "minhaferramenta" },
  "detectar": "minhaferramenta/app.exe",
  "executar": "minhaferramenta/app.exe",
  "env": { "MINHA_HOME": "minhaferramenta" },
  "path": ["minhaferramenta"],
  "portatil": true
}
```

Campos principais:

| Campo | Para que serve |
|---|---|
| `detectar` | arquivo cuja presença prova que está instalada |
| `executar` | comando do botão Executar; `{VAR}` vira o caminho absoluto |
| `instalacao.tipo` | `zip`, `exe-direto`, `7z-sfx`, `msi-admin` ou `instalador` |
| `instalacao.pastaExtraida` | quando o zip traz uma pasta com nome de versão |
| `instalacao.extrairEm` | quando o zip **não** traz pasta própria |
| `instalacao.posInstalacao` | passos extras: `criarPasta`, `copiar`, `renomear`, `escrever`, `baixar`, `rodar` |
| `requer` | outras ferramentas instaladas antes desta |
| `servidor` | porta, usuário e senha — marca a ferramenta como banco |
| `downloadExtra` | pacotes adicionais, cada um com seu destino |

---

## 5. Portabilidade

Tudo fica dentro da pasta do DEVAPP. Os caches das ferramentas, que normalmente
se espalham pelo seu perfil de usuário, são redirecionados para `cache/`.

Verificado por medição:

| Ferramenta | Normalmente escreve em | Medição |
|---|---|---|
| Gradle | `~/.gradle` | build real: zero arquivos no perfil |
| Maven | `~/.m2` | dependência baixada: zero no perfil, 614 arquivos no DEVAPP |
| npm | `%APPDATA%\npm` | pacote global: foi para `cache/npm` |
| pip | `%LOCALAPPDATA%\pip` | cache em `cache/pip` |
| DBeaver | `%APPDATA%\DBeaverData` | workspace em `cache/dbeaver` |

Redirecionados mas ainda não medidos: Flutter (`PUB_CACHE`), .NET
(`NUGET_PACKAGES`), Android SDK (`ANDROID_USER_HOME`) e NetBeans (`--userdir`).

**O que não é portátil**, e a interface avisa antes de instalar:

- **Python (completo)** — o instalador oficial grava no registro e cria entrada
  em Adicionar/Remover Programas. Existe a alternativa **Python (portátil)**,
  que é um zip e não deixa rastro, mas não traz `tkinter`, `venv` nem IDLE.
- **Postman** e **Insomnia** — o arquivo baixado é o instalador, que se instala
  sozinho no perfil do usuário.
- **Android Studio** — guarda configuração em `%APPDATA%\Google`; é o único que
  não respeita variável de ambiente.

---

## 6. O menu clássico

O menu em texto original continua disponível em **`start-classico.bat`**, com as
mesmas opções de sempre. Ele não recebe mais melhorias, mas está lá caso algo na
interface não atenda.

Dois defeitos conhecidos dele, que a interface não tem:

- a opção **14 (Executar → VSCODE)** não abre o VS Code: chamar `code.exe`
  diretamente com pastas customizadas não abre janela nenhuma nas versões atuais;
- a opção **15 (Notepad++)** não instala mais: o servidor de download original
  saiu do ar.

---

## 7. Estrutura

```
DEVAPP\
   start.bat            <- comece por aqui
   start-classico.bat   <- menu antigo, em texto
   devapp.ps1           <- motor: instala, executa, sobe bancos
   catalogo.json        <- as ferramentas, como dados
   ui\index.html        <- a interface
   settings.json        <- configuração inicial do VS Code
   scripts\             <- conversão de Markdown para PDF
   wget\  sevenzip\     <- utilitários embutidos
   cache\               <- caches que ficariam no seu perfil
   jdk\ node\ vscode\   <- as ferramentas instaladas
   ...
```

---

## 8. Problemas comuns

| Problema | O que fazer |
|---|---|
| "Comando não encontrado" no terminal | Use o botão **Terminal** da interface: ele carrega o ambiente |
| A página não abre sozinha | Copie o endereço mostrado na janela preta e cole no navegador |
| `Ctrl+C` não encerra o servidor no Git Bash | Use o botão **Encerrar servidor** na página; é limitação do Git Bash |
| Um banco não sobe | Confira se outro está usando a mesma porta — MySQL e MariaDB dividem a 3360 |
| Download falha | O DEVAPP tenta de novo com DNS público automaticamente; se insistir, verifique a rede |
| Extensões do VS Code não instalam | Instale o VS Code pela interface primeiro |

---

**DEVAPP** — Prof. Rômulo (rfdouro@gmail.com)
