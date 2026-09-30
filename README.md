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

# listar os snapshots existentes (local e nuvem, sem mexer no backup.env na mao)
sudo /usr/local/bin/backup-agent.sh list
```

Passo a passo completo: [`docs/deployment.md`](docs/deployment.md).
Configurar metricas no Zabbix: [`docs/zabbix-monitoring.md`](docs/zabbix-monitoring.md).
Procedimentos de recuperacao: [`docs/disaster-recovery.md`](docs/disaster-recovery.md).

## Atualizar o agente nos servidores

Alterar os arquivos neste repositorio (ex.: `os/linux/backup-agent.sh`)
**nao atualiza sozinho** o que ja esta instalado nos servidores — o jeito
de aplicar a atualizacao depende de como cada servidor foi instalado.

### Instalacao manual (`install.sh`)

No servidor, de dentro do clone do repositorio:

```bash
cd backup-agent   # pasta onde o repo foi clonado no servidor
sudo os/linux/update.sh
```

O `update.sh`:
1. Recusa rodar se houver alteracoes locais nao commitadas no clone (pra
   nao perder nada sem querer).
2. `git fetch` + `git merge --ff-only` de `origin/main` — falha com
   mensagem clara se o clone local divergiu do remoto, em vez de tentar
   adivinhar um merge.
3. Reaplica `backup-agent.sh` e `generate-psk.sh` em `/usr/local/bin`
   (sem mexer em `backup.env`/`excludes.txt` ja configurados).
4. Avisa se `devops/zabbix/template_backup_agent.xml` mudou (lembrete pra
   reimportar no Zabbix Server — ver
   [`docs/zabbix-monitoring.md`](docs/zabbix-monitoring.md)).
5. Mostra a versao final com `backup-agent.sh --version`, pra confirmar
   visualmente que a atualizacao realmente pegou.

### Deploy via Ansible

E automatico — a role ja reaplica o script toda vez que o playbook roda:

```bash
cd devops/ansible
git pull origin main
export BW_SESSION=$(bw unlock --raw)
ansible-playbook -i inventory/<cliente>/hosts.yml playbook.yml
```

Esse e o caminho que escala para varios servidores/clientes sem precisar
entrar em cada host manualmente — ver
[`devops/ansible/inventory/README.md`](devops/ansible/inventory/README.md).

## Versionamento

O projeto usa [semantic-release](https://semantic-release.gitbook.io/):
toda mudanca mesclada em `main` com uma mensagem de commit no padrao
[Conventional Commits](https://www.conventionalcommits.org/) (`fix:`,
`feat:`, etc.) gera automaticamente uma nova versao, atualiza o
`CHANGELOG.md`, cria uma tag e uma GitHub Release. A versao tambem fica
gravada no proprio script:

```bash
backup-agent.sh --version
```

Convencao de commits e o que cada tipo faz na versao: ver
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Roadmap

- [x] Fase 1: backup dual-stage, retencao, telemetria Zabbix (PSK estatica).
- [ ] Fase 2: emissao/renovacao dinamica de certificados via HashiCorp Vault PKI.
- [ ] Fase 3: agente Windows (PowerShell).
- [ ] Fase 4: agente macOS.
