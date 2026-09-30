# backup-agent

Solucao corporativa white-label para automacao de backup, criptografia,
sincronizacao em nuvem e telemetria em ambientes Linux on-premises e cloud.

> **Status:** Fase 1 (sem HashiCorp Vault). O canal de telemetria Zabbix usa
> TLS via PSK estatica em vez de certificados X.509 dinamicos. Veja
> [`docs/architecture.md`](docs/architecture.md) para detalhes.

## Arquitetura (resumo)

1. **Backup local:** snapshot desduplicado e criptografado via [Restic](https://restic.net/).
2. **Sincronizacao em nuvem:** `restic copy` para S3 / Wasabi / Backblaze B2 / MinIO (ou Rclone para Google Drive/OneDrive).
3. **Telemetria:** status, duracao e estatisticas enviados via `zabbix_sender` (Zabbix Trapper), com TLS via PSK.

Detalhes completos em [`docs/architecture.md`](docs/architecture.md).

## Estrutura do repositorio

```
backup-agent/
├── os/linux/            # install.sh, backup-agent.sh, generate-psk.sh, templates
├── os/windows/          # reservado (fase futura)
├── os/macos/            # reservado (fase futura)
├── devops/ansible/      # role de deploy automatizado
├── devops/zabbix/       # template Zabbix Trapper
└── docs/                # arquitetura, deployment, monitoramento Zabbix, disaster recovery
```

## Quick start

```bash
sudo os/linux/install.sh
sudo vi /etc/backup-agent/backup.env
restic -r <REPO_LOCAL> init
sudo /usr/local/bin/backup-agent-generate-psk.sh
sudo /usr/local/bin/backup-agent.sh
```

Passo a passo completo: [`docs/deployment.md`](docs/deployment.md).
Configurar metricas no Zabbix: [`docs/zabbix-monitoring.md`](docs/zabbix-monitoring.md).
Procedimentos de recuperacao: [`docs/disaster-recovery.md`](docs/disaster-recovery.md).

## Roadmap

- [x] Fase 1: backup dual-stage, retencao, telemetria Zabbix (PSK estatica).
- [ ] Fase 2: emissao/renovacao dinamica de certificados via HashiCorp Vault PKI.
- [ ] Fase 3: agente Windows (PowerShell).
- [ ] Fase 4: agente macOS.
