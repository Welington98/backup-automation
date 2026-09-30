# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
versionamento seguindo [SemVer](https://semver.org/lang/pt-BR/).

## [0.1.0] - 2026-09-30

### Added
- Estrutura inicial do repositorio (`os/`, `devops/`, `docs/`).
- `os/linux/backup-agent.sh`: backup local (Restic), sincronizacao em nuvem
  (`restic copy`), retencao local/nuvem, telemetria Zabbix Trapper.
- `os/linux/install.sh`: bootstrap de instalacao (pacotes, diretorios, cron).
- `os/linux/generate-psk.sh`: geracao de PSK estatica para o canal Zabbix.
- `os/linux/backup.env.template` e `excludes.txt`.
- Role Ansible `devops/ansible/roles/backup_agent` para deploy em massa,
  com `playbook.yml` e `ansible.cfg` prontos para uso.
- Inventario Ansible **multi-cliente** (`devops/ansible/inventory/`): cada
  cliente isolado em sua propria pasta (`hosts.yml`, `group_vars/`,
  `host_vars/`), com exemplo completo em `cliente_exemplo/` (autenticacao
  por senha e por chave SSH). Guia de uso em `inventory/README.md` e passo
  a passo para novo cliente em `inventory/TEMPLATE-NOVO-CLIENTE.md`.
- Guarda (`assert`) na role contra deploy com segredos ainda no valor
  padrao `CHANGE_ME`.

### Changed
- Segredos do inventario Ansible passaram de `ansible-vault` (um arquivo
  `<cliente>-vault.yml` criptografado por cliente) para **Vaultwarden**
  (self-hosted, compativel com Bitwarden), via
  `lookup('community.general.bitwarden', ...)` em `group_vars/<cliente>.yml`.
  Convencao: um item Secure Note por cliente (`backup-agent - <cliente>`)
  com um campo customizado por segredo. Requer `bw` CLI configurado no
  control node (`devops/ansible/requirements.yml` traz a collection
  `community.general`). Vaultwarden **nao** suporta a API do Bitwarden
  Secrets Manager (machine accounts) — a integracao usa o cofre de senhas
  normal.
- Template Zabbix Trapper `devops/zabbix/template_backup_agent.xml`.
- Documentacao: `docs/architecture.md`, `docs/deployment.md`,
  `docs/disaster-recovery.md`.

### Nao incluido nesta fase
- Integracao com HashiCorp Vault PKI (emissao/renovacao dinamica de
  certificados). O canal Zabbix usa PSK estatica sem rotacao automatica.
- Agentes Windows e macOS.
