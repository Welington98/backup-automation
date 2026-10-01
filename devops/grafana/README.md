# Grafana — dashboard consolidado do backup-agent

Este diretorio contem o provisioning e o dashboard Grafana que leem os
dados **ja enviados ao Zabbix** pelo `backup-agent.sh`
(`docs/zabbix-monitoring.md`). Nao existe nenhum exporter novo nem mudanca
no agente — o Grafana so consulta o Zabbix via o plugin
`alexanderzobnin-zabbix-app`.

```
devops/grafana/
├── docker-compose.smoke.yml         # Zabbix + Grafana LOCAIS, so para build/teste
├── provisioning/
│   ├── datasources/zabbix.yaml      # datasource Zabbix (API Token)
│   └── dashboards/backup-agent.yaml # provider que carrega dashboards/*.json automaticamente
└── dashboards/
    └── backup_agent_overview.json   # dashboard unico, filtro Cliente -> Host
```

Guia completo de uso (importar, provisionar em producao, troubleshooting):
[`docs/grafana-dashboards.md`](../../docs/grafana-dashboards.md).

## Referencia visual (paleta)

O pedido original era usar o kit da comunidade Figma "Saga UI Kit Dark
Theme" como referencia de estilo. Esse link e uma pagina de listagem da
comunidade (nao um arquivo `/design/...` com `node-id`), entao as
ferramentas de design-to-code nao conseguem ler os tokens dele
diretamente — seria necessario abrir/duplicar o arquivo no Figma e
compartilhar o link do frame especifico. Ate isso acontecer, os paineis
usam a **paleta dark validada** da skill de visualizacao de dados deste
ambiente (contraste e distincao de cor conferidos por script, nao no
olho), que ja cobre exatamente os papeis que um dashboard de operacao
precisa:

| Papel | Cor | Uso no dashboard |
|---|---|---|
| Status OK | `#0ca30c` | Threshold do valor `1` nos paineis de status (backup/retencao) |
| Status Falha | `#d03b3b` | Threshold do valor `0` nos mesmos paineis |
| Superficie do painel (dark) | `#1a1a19` | Fundo dos paineis (tema dark nativo do Grafana) |
| Texto primario (dark) | `#ffffff` | Valores/numeros grandes |
| Texto secundario (dark) | `#c3c2b7` | Legendas, labels de eixo |

As series por host (duracao, tamanho, snapshots) **nao** usam cor fixa por
host — o dashboard e o mesmo para qualquer cliente/host que entrar no
inventario depois, entao a cor de cada serie e atribuida automaticamente
pelo `palette-classic` nativo do Grafana (ja pensado para funcionar no
tema dark), em vez de um hex fixo por posicao que so faria sentido para
uma lista fixa de hosts.

Se depois conseguirem o link real do frame no Figma (`/design/<fileKey>?node-id=...`),
essa tabela pode ser atualizada com os hex exatos do kit — a estrutura dos
paineis (`dashboards/backup_agent_overview.json`) nao muda, so as cores.

## Ambiente local de build/teste

```bash
docker compose -f devops/grafana/docker-compose.smoke.yml up -d
```

- Zabbix Web: http://localhost:18080 (`Admin` / `zabbix`)
- Grafana: http://localhost:13000 (`admin` / `admin`)

Passo a passo completo de importar o template, criar hosts de teste,
enviar dados com `zabbix_sender` e provisionar o dashboard:
[`docs/grafana-dashboards.md`](../../docs/grafana-dashboards.md).

**Nunca aponte o `gcx` (CLI da Grafana) ou este compose para a instancia de
producao compartilhada da empresa** — confira sempre `gcx config
current-context` antes de rodar `gcx dashboards create/update/snapshot`.

Para derrubar e limpar tudo:

```bash
docker compose -f devops/grafana/docker-compose.smoke.yml down -v
```
