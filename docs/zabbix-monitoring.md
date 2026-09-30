# Monitoramento Zabbix - backup-agent

Guia completo para o backup-agent enviar metricas para o Zabbix Server via
`zabbix_sender` (modelo Trapper). Cobre os dois lados: o que configurar no
**Zabbix Server** e o que configurar no **servidor cliente** (backup-agent).

## 1. Visao geral

- O `backup-agent.sh` envia os dados **ativamente** (push) via
  `zabbix_sender` apos cada execucao — nao precisa de Zabbix Agent rodando
  no cliente, nem de polling do servidor.
- Todos os itens sao do tipo **Trapper**, entao o host no Zabbix **nao
  precisa de uma interface Agent/SNMP/JMX/IPMI configurada**.
- O canal e criptografado com **TLS via PSK estatica** (Fase 1, sem
  HashiCorp Vault) — ver [`docs/architecture.md`](architecture.md) para o
  raciocinio por tras dessa escolha.

## 2. Pre-requisitos

- Pacote `zabbix-sender` instalado no cliente (ja incluso no
  `os/linux/install.sh`).
- TCP `10051` liberado de saida do cliente para o Zabbix Server (ver
  [`docs/deployment.md`](deployment.md) secao 1).
- Acesso ao Zabbix Server para importar template e cadastrar host
  (**Data collection**, perfil com permissao de escrita).

## 3. Configurar no Zabbix Server

### 3.1 Importar o template

**Data collection > Templates > Import** e selecione
`devops/zabbix/template_backup_agent.xml`.

> Sempre que esse arquivo for atualizado no repositorio (itens/triggers
> novos), reimporte — o Zabbix nao atualiza hosts ja cadastrados sozinho.

### 3.2 Criar o host

**Data collection > Hosts > Create host**:

- **Host name:** precisa ser **identico** ao `ZABBIX_HOSTNAME` configurado
  no `backup.env` do cliente (sensivel a maiusculas/minusculas).
- **Templates:** vincule o template **Backup Agent** importado no passo 3.1.
- **Host groups:** qualquer grupo (ex.: crie um "Backup Agent" se nao tiver
  um preferido).
- **Interfaces:** nao e necessario adicionar nenhuma — todos os itens do
  template sao Trapper.

### 3.3 Configurar encryption (PSK)

Na aba **Encryption** do host criado:

- **Connections to host:** `PSK`
- **Connections from host:** `PSK`
- **PSK identity** e **PSK value:** gerados no cliente (secao 4.2 abaixo) —
  cole exatamente o que o script imprimir.

## 4. Configurar no servidor cliente

### 4.1 Variaveis no `backup.env`

```env
ENABLE_ZABBIX="true"
ZABBIX_SERVER="zabbix.suaempresa.com"
ZABBIX_PORT="10051"
ZABBIX_HOSTNAME="HOSTNAME_EXATO_NO_ZABBIX"

ENABLE_ZABBIX_TLS="true"
ZABBIX_TLS_PSK_IDENTITY="backup-agent:HOSTNAME_EXATO_NO_ZABBIX"
ZABBIX_TLS_PSK_FILE="/etc/backup-agent/certs/zabbix.psk"
```

| Campo | O que colocar |
|---|---|
| `ENABLE_ZABBIX` | `"true"` para enviar metricas, `"false"` para desligar o monitoramento |
| `ZABBIX_SERVER` | FQDN ou IP do Zabbix Server |
| `ZABBIX_PORT` | Porta do Trapper (padrao `10051`) |
| `ZABBIX_HOSTNAME` | Precisa bater **exatamente** com o "Host name" cadastrado no passo 3.2 |
| `ENABLE_ZABBIX_TLS` | `"true"` para usar PSK (recomendado); `"false"` envia em texto puro |
| `ZABBIX_TLS_PSK_IDENTITY` | Identificador livre, usado tambem no cadastro do host (passo 3.3) |
| `ZABBIX_TLS_PSK_FILE` | Caminho do arquivo com a PSK gerada (ver 4.2) |

### 4.2 Gerar a PSK

```bash
sudo /usr/local/bin/backup-agent-generate-psk.sh
```

O script cria `ZABBIX_TLS_PSK_FILE` (modo `600`) e imprime a **PSK identity**
e a **PSK value** a copiar para a aba Encryption do host (passo 3.3). Se o
arquivo ja existir, o script nao faz nada — apague-o primeiro para gerar
uma PSK nova (e recadastre no Zabbix Server, a antiga fica invalida).

## 5. Testar antes de esperar o cron

Envie um valor manualmente com o mesmo `zabbix_sender` que o script usa:

```bash
set -a; source /etc/backup-agent/backup.env; set +a

zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -s "$ZABBIX_HOSTNAME" \
    -k restic.backup.status -o 1 \
    --tls-connect psk \
    --tls-psk-identity "$ZABBIX_TLS_PSK_IDENTITY" \
    --tls-psk-file "$ZABBIX_TLS_PSK_FILE"
```

Saida esperada: `... processed: 1; failed: 0; total: 1; seconds spent: ...`.
Depois confirme no Zabbix: **Monitoring > Latest data**, filtre pelo host e
confira se `restic.backup.status` recebeu o valor `1`.

Ou rode o agente completo e acompanhe o log (ver
[`docs/deployment.md`](deployment.md) secao 2.5).

## 6. Itens enviados pelo backup-agent.sh

| Key | Quando e enviado | Tipo | Significado |
|---|---|---|---|
| `restic.backup.status` | Sempre (Etapas 1-2) | `0`/`1` | `1` = backup local + sincronizacao concluidos; `0` = falha em qualquer um dos dois |
| `restic.backup.duration` | Sempre | segundos | Duracao total da execucao |
| `restic.retention.local.status` | Sempre (Etapa 3) | `0`/`1` | Resultado do `forget --prune` no repositorio local |
| `restic.retention.cloud.status` | Apenas se `ENABLE_CLOUD_SYNC="true"` | `0`/`1` | Resultado do `forget --prune` no repositorio em nuvem |
| `restic.repo.size.local` | Sempre, se `restic stats` tiver sucesso (Etapa 4) | bytes | Tamanho total do repositorio **local** (`REPO_LOCAL`) |
| `restic.repo.snapshots.local` | Sempre, se `restic snapshots` tiver sucesso (Etapa 4) | contagem | Quantidade de snapshots no repositorio **local** |
| `restic.repo.size.cloud` | Apenas se `ENABLE_CLOUD_SYNC="true"` e `restic stats` tiver sucesso | bytes | Tamanho total do repositorio **em nuvem** (`REPO_CLOUD`) |
| `restic.repo.snapshots.cloud` | Apenas se `ENABLE_CLOUD_SYNC="true"` e `restic snapshots` tiver sucesso | contagem | Quantidade de snapshots no repositorio **em nuvem** |

Os tres itens `*.status` (`restic.backup.status`,
`restic.retention.local.status`, `restic.retention.cloud.status`) usam o
Value Map **"Backup Agent Status"**, ja incluso no template — em vez de `0`
e `1`, **Monitoring > Latest data** e os graficos mostram "Falha"/"OK"
diretamente, sem precisar decorar o significado do numero.

Triggers ja inclusos no template: falha em qualquer `*.status` (HIGH) e
ausencia de dados por 26h em `restic.backup.status` (AVERAGE) — ver
`devops/zabbix/template_backup_agent.xml` para os detalhes.

## 7. Troubleshooting

| Sintoma | Causa provavel |
|---|---|
| `zabbix_sender` retorna `failed: 1` | Host no Zabbix com nome diferente de `ZABBIX_HOSTNAME`, ou item/template nao importado/vinculado |
| Erro de TLS/handshake | `ZABBIX_TLS_PSK_IDENTITY` ou o conteudo de `ZABBIX_TLS_PSK_FILE` nao batem com o cadastrado na aba Encryption do host |
| Timeout / connection refused | TCP `10051` bloqueado no firewall de saida, ou `ZABBIX_SERVER`/`ZABBIX_PORT` errados |
| Enviou mas nao aparece em Latest data | Item nao existe no template (reimporte o XML) ou o template nao esta vinculado a esse host |

Para isolar problema de conectividade vs. TLS, teste primeiro com
`ENABLE_ZABBIX_TLS="false"` (e a aba Encryption do host em "No encryption")
— se funcionar sem TLS, o problema esta na PSK; se nem sem TLS funcionar, e
rede/firewall/nome de host.

## 8. Referencias

- `devops/zabbix/template_backup_agent.xml` — definicao dos itens/triggers.
- `os/linux/generate-psk.sh` — geracao da PSK.
- `os/linux/backup-agent.sh` (funcao `send_zabbix`) — como cada item e enviado.
- [`docs/architecture.md`](architecture.md) — seguranca do canal (PSK vs. Vault PKI futuro).
