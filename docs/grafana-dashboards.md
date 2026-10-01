# Dashboard Grafana - backup-agent

Guia para visualizar num unico dashboard Grafana as metricas que o
`backup-agent.sh` ja envia ao Zabbix (ver
[`docs/zabbix-monitoring.md`](zabbix-monitoring.md)). Nao ha nenhum agente
ou exporter novo — o Grafana so le do Zabbix via o plugin
`alexanderzobnin-zabbix-app`.

## 1. Visao geral

- Dashboard unico, com filtros **Cliente** (host group do Zabbix) e **Host**
  encadeados — reutilizavel conforme novos clientes entram no inventario
  Ansible (`devops/ansible/inventory/<cliente>/`).
- Cobre as 8 metricas ja documentadas em
  [`docs/zabbix-monitoring.md`](zabbix-monitoring.md#6-itens-enviados-pelo-backup-agentsh),
  mais um painel de resumo ("Hosts com falha nas ultimas 24h").
- Arquivos em `devops/grafana/`:
  - `provisioning/datasources/zabbix.yaml` — datasource Zabbix (API Token).
  - `provisioning/dashboards/backup-agent.yaml` — provider que carrega o
    dashboard automaticamente a partir de `dashboards/*.json`.
  - `dashboards/backup_agent_overview.json` — o dashboard em si.
  - `docker-compose.smoke.yml` — ambiente local para build/teste (nao e
    o Grafana de producao).

## 2. Pre-requisitos

- Um Grafana (OSS ou Cloud) com o plugin **Zabbix** instalado
  (`grafana-cli plugins install alexanderzobnin-zabbix-app` ou
  `GF_INSTALL_PLUGINS=alexanderzobnin-zabbix-app`).
- Acesso de leitura a API do Zabbix Server que ja recebe os dados do
  `backup-agent.sh` (mesmo `ZABBIX_SERVER` do `backup.env`).
- **Convencao obrigatoria:** cada cliente precisa ter um **host group no
  Zabbix com o nome identico ao `client_name`** definido em
  `devops/ansible/inventory/<cliente>/group_vars/<cliente>.yml` — e assim
  que o dashboard filtra por "Cliente". Isso ja esta documentado em
  [`docs/zabbix-monitoring.md`](zabbix-monitoring.md#32-criar-o-host).

## 3. Criar o usuario e o token de API no Zabbix

Crie um usuario **dedicado e somente-leitura** para o Grafana (nao use o
`Admin`):

1. **Users > User groups > Create user group**, nome "Grafana Readers",
   permissao de leitura nos host groups dos clientes que devem aparecer no
   dashboard (ou em todos, se o Grafana centralizar todos os clientes).
2. **Users > Users > Create user**, ex. `grafana-reader`, role **User
   role**, no grupo criado acima.
3. **Administration > API tokens > Create token**, vinculado a esse
   usuario, sem expiracao (ou com rotacao programada). Copie o token — so
   e mostrado uma vez.

## 4. Provisionar o datasource

`devops/grafana/provisioning/datasources/zabbix.yaml` ja define o
datasource com `authType: token`. Ajuste a `url` para o Zabbix Server real
e defina a variavel de ambiente `GRAFANA_ZABBIX_API_TOKEN` (o token do
passo 3) no ambiente do processo Grafana antes de subir:

```bash
export GRAFANA_ZABBIX_API_TOKEN="d668c11ae72d..."
```

Confirme com **Connections > Data sources > Zabbix > Save & Test** (ou
`GET /api/datasources/uid/<uid>/health`) — deve responder a versao da API
do Zabbix.

## 5. Provisionar o dashboard

`devops/grafana/provisioning/dashboards/backup-agent.yaml` aponta para a
pasta `dashboards/` e carrega `backup_agent_overview.json`
automaticamente, numa pasta "Backup Agent" no Grafana. Basta montar
`devops/grafana/provisioning/` e `devops/grafana/dashboards/` nos
diretorios de provisioning do seu Grafana (ou copiar os arquivos para la).

Sem provisioning de arquivo, tambem da pra importar manualmente
(**Dashboards > New > Import**, colar o conteudo do JSON) — mas perde a
atualizacao automatica quando o arquivo mudar no repositorio.

## 6. Paineis do dashboard

| Painel | Metrica Zabbix | Tipo |
|---|---|---|
| Hosts com falha nas ultimas 24h | `restic.backup.status` (via Problems/trigger do template) | Stat |
| Status do Backup | `restic.backup.status` | Stat (1 por host) |
| Duracao do Backup | `restic.backup.duration` | Timeseries |
| Tamanho do Repositorio Local | `restic.repo.size.local` | Timeseries |
| Tamanho do Repositorio Cloud | `restic.repo.size.cloud` | Timeseries |
| Snapshots Local | `restic.repo.snapshots.local` | Stat |
| Snapshots Cloud | `restic.repo.snapshots.cloud` | Stat |
| Status Retencao Local | `restic.retention.local.status` | Stat |
| Status Retencao Cloud | `restic.retention.cloud.status` | Stat |

Os paineis `*Cloud*` mostram "Sem cloud sync" quando o cliente nao tem
`ENABLE_CLOUD_SYNC=true` (o item correspondente nunca recebe dado nesse
caso — ver [`docs/zabbix-monitoring.md`](zabbix-monitoring.md#6-itens-enviados-pelo-backup-agentsh)).

O intervalo padrao do dashboard e **ultimos 2 dias** — deliberado: o
datasource Zabbix decide entre usar `history` (dado bruto) ou `trends`
(agregado por hora) com base no intervalo de tempo consultado
(`trendsFrom`/`trendsRange` no datasource), e como o `backup-agent.sh`
roda uma vez por dia, um intervalo maior que a janela de `trends` pode
cair num periodo sem trend calculado ainda, mostrando "No data" mesmo
com o backup tendo rodado. Para olhar semanas/meses, aumente o intervalo
manualmente — o Zabbix ja tera calculado os trends dessas datas mais
antigas.

## 7. Atualizando o dashboard

Diferente do template Zabbix (que e reimportado manualmente e
`os/linux/update.sh` avisa quando ele muda), o dashboard Grafana **nao**
passa pelo fluxo de update do agente — o Grafana roda centralizado, nao em
cada servidor cliente. Sempre que
`devops/grafana/dashboards/backup_agent_overview.json` mudar neste
repositorio:

- Se o Grafana usa provisioning por arquivo (recomendado): sincronize a
  pasta `devops/grafana/` para onde o Grafana le (`updateIntervalSeconds:
  30` no provider ja aplica a mudanca sozinho depois disso).
- Se foi importado manualmente: reimporte pela UI (**Dashboards >
  Import**) sobrescrevendo o existente.

## 8. Troubleshooting

| Sintoma | Causa provavel |
|---|---|
| Painel mostra "No data" em todos os paineis | Host nao esta no host group com nome = `client_name`, ou o usuario/token do Grafana nao tem permissao de leitura nesse grupo |
| Um painel especifico "No data", outros ok | Intervalo de tempo cai no limite history/trends (ver secao 6) — tente "Last 2 days" |
| Paineis `*Cloud*` sempre "Sem cloud sync" | Esperado se `ENABLE_CLOUD_SYNC=false` nesse cliente |
| Variavel "Host" fica vazia | Variavel "Cliente" ainda nao tem selecao, ou o host group esta vazio |
| `Save & Test` do datasource falha | Token expirado/revogado, ou `url` da API do Zabbix errada (ver `docs/zabbix-monitoring.md` para o endereco do `ZABBIX_SERVER`) |

## 9. Testar localmente antes de aplicar em producao

Ambiente reprodutivel via Docker Compose (`devops/grafana/docker-compose.smoke.yml`):
sobe Zabbix (server + web + banco) e Grafana com o plugin ja instalado.

```bash
docker compose -f devops/grafana/docker-compose.smoke.yml up -d
```

1. Importe `devops/zabbix/template_backup_agent.xml` no Zabbix
   (`http://localhost:18080`, **Data collection > Templates > Import**).
2. Crie um host group de teste (ex. `cliente-exemplo`) e 1-2 hosts fake
   vinculados ao template (sem interface — os items sao todos Trapper).
3. Envie dados de teste com o mesmo `zabbix_sender` usado pelo agente:
   ```bash
   zabbix_sender -z localhost -p 10051 -s <host-teste> -k restic.backup.status -o 1
   # repita para os outros 7 keys (ver docs/zabbix-monitoring.md secao 6)
   ```
4. Confirme em **Monitoring > Latest data** que os valores chegaram.
5. Crie um usuario/token de API (secao 3 acima) e exporte
   `GRAFANA_ZABBIX_API_TOKEN` antes de subir o container do Grafana.
6. Abra `http://localhost:13000` — o dashboard "Backup Agent - Visao
   Geral" ja deve aparecer (carregado via provisioning), selecione o
   cliente/host de teste e confirme que os 9 paineis mostram dado.

Para iterar no proprio JSON do dashboard, use o `gcx` (CLI da Grafana) com
um contexto separado apontando para esse Grafana local — **nunca** para
uma instancia de producao compartilhada:

```bash
gcx login backup-agent-local --server http://localhost:13000 --token <service-account-token>
gcx config current-context   # confirme que NAO é o contexto de producao
gcx dashboards snapshot backup-agent-overview --output-dir ./snapshots --since 2d \
  --var cliente=<cliente-teste> --var host=All --theme dark
```

Derrubar e limpar tudo:

```bash
docker compose -f devops/grafana/docker-compose.smoke.yml down -v
```

## 10. Referencias

- [`docs/zabbix-monitoring.md`](zabbix-monitoring.md) — origem das metricas e convencao de host group.
- `devops/grafana/README.md` — paleta de cores usada nos paineis e detalhes do ambiente local.
- `devops/zabbix/template_backup_agent.xml` — items/triggers/value map consumidos pelo dashboard.
