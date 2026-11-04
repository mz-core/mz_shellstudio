# MZ Shell Studio — Wave 2 + Grid Mode

Editor procedural in-game para criar projetos de shell GTA V Legacy. O resource guarda apenas o contrato JSON; a conversão em YDR/YTD/YTYP/YBN continua sendo offline pelo exportador C++ pinado.

## Instalação em staging

O resource não foi adicionado a nenhum `server.cfg` e permanece desativado por padrão. Em um FXServer Legacy isolado:

1. disponibilize `ox_lib`, `mz_core` e esta pasta como resources;
2. confirme que o usuário autorizado possui `group.mz_owner` ou altere `Config.Permission` para uma permissão canônica existente;
3. inicie `mz_shellstudio` somente nesse staging;
4. execute `/mz_shellstudio`.

Não use o resource contra produção antes da homologação in-game descrita no relatório da Wave 2.

## Controles

- clique esquerdo: selecionar ou confirmar ponto;
- **Piso grade / Teto grade / Apagar célula**: clique ou arraste para pintar células de 2 m;
- botão direito + arrastar: orbitar;
- `Shift` + botão direito + arrastar: mover o alvo da câmera;
- scroll: zoom;
- `Delete`: apagar a seleção (elementos manuais; estruturas da planta são editadas pelas ferramentas de grade);
- `Ctrl+Z` / `Ctrl+Shift+Z`: desfazer/refazer;
- `Ctrl+S`: salvar;
- `ESC`: cancelar o desenho atual; um segundo `ESC` fecha o editor.

Piso, teto e parede usam dois pontos. Porta e janela usam um clique próximo de uma parede. A Wave 2 aceita uma abertura retangular por parede.

## Grid Mode

As ferramentas **Piso grade** e **Teto grade** pintam células de 2 m. As paredes de contorno são geradas automaticamente e recalculadas quando células vizinhas são adicionadas ou removidas. Pisos, tetos e trechos contínuos de parede são unificados antes de entrar no contrato de elementos, para respeitar o limite atual.

A planta (`plan`) é a fonte de autoria; os elementos `generated` são compilados de forma determinística. O servidor recompila a planta no save e rejeita divergências. Portas e janelas existentes continuam funcionando; ao alterar a planta, aberturas sobre paredes geradas são remapeadas ou removidas com aviso.

## Materiais

O catálogo inicial usa texturas procedurais próprias: `checker`, `concrete`, `plaster`, `wood`, `tile`, `brick` e `metal`. Nenhuma textura de terceiros é redistribuída.

- Selecione um elemento manual e clique em uma amostra no inspetor para aplicar.
- Com a ferramenta **Materiais**, escolha uma amostra e clique no piso, parede ou teto. Em elementos gerados, a superfície de origem da planta é atualizada e recompilada.
- O material é preservado no merge, no save e na recompilação server-side.
- O exportador agrupa a geometria por material, gera uma textura procedural por material no YTD e associa shaders/UVs no YDR. `checker` continua compatível.

## Exportação

O botão **Preparar exportação** grava um snapshot JSON validado em `data/exports/` e mostra o comando local. O FXServer não executa o compilador.

Na máquina de build, a partir da raiz do repositório:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/mz_shellstudio_exporter/export-project.ps1 -ProjectFile "mz_shellstudio/data/exports/<snapshot>.json"
```

Ou, usando o store diretamente:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/mz_shellstudio_exporter/export-project.ps1 -ProjectId <id> -Store "mz_shellstudio/data/projects.json"
```

O pacote é criado em `release-artifacts/mz_shellstudio/<id>-<timestamp>/`, com `stream/`, `fxmanifest.lua`, `client.lua`, `README.md` e `build-report.json`. O script não sobrescreve pastas e não altera `server.cfg`.

## Persistência e segurança

`server/main.lua` é o único writer de `data/projects.json`. Toda operação revalida permissão pelo `mz_core`, resolve o `accountId` estável, limita taxa/tamanho e valida o schema compartilhado. A NUI não fornece paths nem grava arquivos diretamente.

## Exportação offline direta

O fluxo recomendado é `export-project.ps1` (acima). O comando direto abaixo continua disponível para automação:

Após salvar e copiar com segurança o store do staging para a máquina de build:

```powershell
$exe = "$env:TEMP\mzss-wave2-build\mzss_native_poc.exe"
& $exe project-store `
  D:\git-hub\repo_oficial\mz_shellstudio\data\projects.json `
  mzss_p_ID_DO_PROJETO `
  D:\saida\resource_mzss
```

Também é possível usar `project <project.json> <resource-dir>`. O pacote gerado contém manifest, cliente mínimo de spawn/cleanup, assets em `stream/`, relatório e YBN diagnóstico fora de `stream/`.

O comando do pacote exportado é `/mzss_spawn_wave2`. Execute-o apenas em staging e faça a homologação com personagem real.
