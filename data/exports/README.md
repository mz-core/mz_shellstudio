# Export snapshots

`mz_shellstudio:server:prepareExport` grava aqui um JSON autocontido do projeto validado.

O FXServer não executa o compilador. Copie o snapshot para a máquina de build e execute:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/mz_shellstudio_exporter/export-project.ps1 -ProjectFile "mz_shellstudio/data/exports/<arquivo>.json"
```

O script gera uma pasta nova em `release-artifacts/mz_shellstudio/` e nunca altera `server.cfg` de produção.
