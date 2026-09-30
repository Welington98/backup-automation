# Arquitetura - backup-agent (Fase 1)

## Visao Geral

O `backup-agent` automatiza backup local, replicacao em nuvem e telemetria
para ambientes Linux on-premises e cloud, usando Restic como engine de
backup desduplicado e criptografado, e Zabbix Trapper para monitoramento.

Esta e a **Fase 1** do projeto: implementa toda a arquitetura Dual-Stage
descrita no planejamento original, **exceto** a emissao dinamica de
certificados via HashiCorp Vault PKI. A integracao com Vault fica reservada
para uma fase futura; por ora, o canal Zabbix usa uma **PSK (Pre-Shared Key)
estatica**, gerada localmente por host.

## Arquitetura Dual-Stage

```
┌──────────────────────────────────────────────────────────────┐
│                  SERVIDOR CLIENTE (ON-PREMISES)               │
│                                                                │
│  ┌───────────────────────┐   1. Snapshot Local                │
│  │   backup-agent.sh      ├──────────────────────┐            │
│  └──────────┬────────────┘                        ▼           │
│             │ 2. restic copy                ┌──────────────┐  │
│             │ (local -> nuvem)               │ Disco/NAS    │  │
│             ▼                                └──────────────┘  │
│  ┌───────────────────────┐                                    │
│  │   zabbix_sender        │                                   │
│  │   (TLS via PSK)        │                                   │
│  └──────────┬────────────┘                                    │
└─────────────┼──────────────────────────────────────────────────┘
              │ 3. Telemetria TCP/10051 (TLS PSK)
              ▼
   ┌───────────────────────────┐        4. restic copy --repo2
   │   ZABBIX SERVER CENTRAL   │        ┌───────────────────────┐
   └───────────────────────────┘        │ S3 / Wasabi / B2/MinIO │
                                         └───────────────────────┘
```

## Estagios

1. **Estagio 1 (Backup Local):** `restic backup` cria um snapshot
   desduplicado e criptografado no repositorio local (`REPO_LOCAL`),
   normalmente em disco secundario ou ponto de montagem NFS/iSCSI.
2. **Estagio 2 (Sincronizacao em Nuvem):** `restic copy --repo2` replica os
   snapshots do repositorio local para o repositorio remoto (`REPO_CLOUD`),
   suportando qualquer backend compativel com Restic (S3, Wasabi, Backblaze
   B2, MinIO; Google Drive/OneDrive via Rclone).
3. **Retencao:** `restic forget --prune` aplica politicas de retencao
   independentes para local (curto prazo, `KEEP_LOCAL_DAILY`) e nuvem (longo
   prazo, `KEEP_CLOUD_DAILY/WEEKLY/MONTHLY`).
4. **Telemetria:** `zabbix_sender` envia status, duracao, tamanho do
   repositorio e contagem de snapshots como itens Trapper.

## Seguranca do canal Zabbix (Fase 1: PSK estatica)

Sem o Vault PKI, a criptografia do canal `zabbix_sender` -> Zabbix Server e
feita com `--tls-connect psk`:

- A PSK e gerada localmente por `generate-psk.sh` (`openssl rand -hex 32`,
  256 bits) e armazenada em `/etc/backup-agent/certs/zabbix.psk` (modo 600).
- O mesmo valor precisa ser cadastrado manualmente (ou via Ansible) no
  cadastro do host em **Zabbix Server > Data collection > Hosts > Encryption**.
- **Nao ha rotacao automatica.** A PSK e valida ate ser trocada manualmente.
  Quando o Vault PKI for introduzido em uma fase futura, este mecanismo pode
  ser substituido por certificados X.509 dinamicos com TTL curto e renovacao
  automatica via cron, sem alterar a logica de `backup-agent.sh` (apenas os
  `tls_args` passados ao `zabbix_sender`).

## Fora de escopo na Fase 1

- HashiCorp Vault PKI Engine (emissao/renovacao automatica de certificados).
- Rotacao automatica de credenciais (PSK, AWS keys).
- Suporte Windows/macOS (diretorios `os/windows` e `os/macos` reservados).
