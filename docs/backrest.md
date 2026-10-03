# Backrest centralizado (console Web de restauracao)

O [Backrest](https://github.com/garethgeorge/backrest) e uma interface Web
para o Restic. No `backup-agent` ele e usado **apenas de forma centralizada**,
em um servidor de gestao: o cliente continua rodando so `backup-agent.sh` +
Restic (sem servico Web nem RAM extra), e a equipe de suporte ganha uma
console unica para navegar snapshots e restaurar arquivos.

```
[Cliente A] --backup--+
[Cliente B] --backup--+--> [ Bucket S3 / Wasabi / MinIO (REPO_CLOUD) ]
[Cliente C] --backup--+              ^
                                     | le snapshots / restaura
                           [ Backrest centralizado ] <-- equipe de suporte
```

| Camada | Ferramenta | Funcao |
|---|---|---|
| Ponta (cliente) | `backup-agent.sh` + Restic | Backup local + `restic copy` para o S3 |
| Telemetria | `zabbix_sender` + Zabbix | Alertas se o backup falhar ou nao rodar |
| Visualizacao | Grafana | Dashboard consolidado ([grafana-dashboards.md](grafana-dashboards.md)) |
| Gestao/restauracao | **Backrest** | Console Web para navegar e restaurar |

## 1. Deploy

```bash
cd devops/backrest
cp .env.example .env
docker compose up -d
```

Acesse `http://localhost:9898`. No primeiro acesso, **crie o usuario admin**
(Settings) antes de expor o servico: sem isso a UI fica aberta.

Producao: coloque um reverse proxy (NGINX/Caddy/Traefik) com TLS na frente
(ex.: `https://backrest.suaempresa.com`) e mantenha `BACKREST_BIND=127.0.0.1`.

## 2. Cadastrar o repositorio de um cliente

Em **Add Repo**, use os mesmos valores do `backup.env` do cliente:

| Campo Backrest | Valor |
|---|---|
| Repo Name | `cliente-a-srv-ad02` |
| Repository URI | o `REPO_CLOUD` (ex.: `s3:s3.amazonaws.com/bucket/CLIENTE-CODE/HOSTNAME`) |
| Password | o `RESTIC_PASSWORD` do cliente (guarde no cofre de senhas) |
| Env Vars | `AWS_ACCESS_KEY_ID=...` e `AWS_SECRET_ACCESS_KEY=...` (e `AWS_DEFAULT_REGION` se preciso) |

Use credenciais S3 **somente-leitura** quando a equipe so for restaurar.
Para Wasabi/B2/MinIO use o endpoint no URI (`s3:https://s3.wasabisys.com/...`).

## 3. O que a equipe faz na UI

- Escolher um snapshot por data/hora (os criados pelo `backup-agent.sh`).
- Navegar a arvore de diretorios e restaurar arquivos/pastas selecionados
  (download ou restore para a pasta `/userdata` do container).
- Rodar `check` para auditoria de integridade.

## 4. Regras importantes

- **Nao crie planos de backup no Backrest para esses repositorios.** Quem
  grava e quem aplica a retencao e o `backup-agent.sh`; o Backrest e so
  leitura/restauracao.
- **Desative prune/check agendados** nesses repos no Backrest. `forget --prune`
  e `check` concorrentes com o agente disputam o lock do repositorio e podem
  falhar o backup. Rode `check` manualmente, fora da janela de backup.
- A senha do Restic e as chaves S3 ficam no `config.json` do Backrest
  (`devops/backrest/config/`, ja ignorado pelo git). Proteja o volume e
  faca backup dele; sem a senha o repositorio e irrecuperavel
  (ver [disaster-recovery.md](disaster-recovery.md)).
- Restore pela UI do Backrest complementa, nao substitui,
  `backup-agent.sh restore` (que continua valido no proprio cliente).
