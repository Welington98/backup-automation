# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
versionamento seguindo [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Added
- `docs/zabbix-monitoring.md`: guia completo de configuracao do
  monitoramento Zabbix — importar template, criar host (sem interface,
  itens sao Trapper), cadastrar encryption PSK, variaveis do `backup.env`,
  teste manual com `zabbix_sender`, tabela de todos os itens enviados pelo
  `backup-agent.sh` e troubleshooting comum.

### Fixed
- `os/linux/backup-agent.sh`: adicionado lock proprio (`flock` em
  `/var/lock/backup-agent.lock`) para impedir duas execucoes simultaneas
  do script no mesmo host — antes, rodar o script em paralelo (ex.: teste
  manual em cima do cron) podia colidir com o lock exclusivo do proprio
  Restic no meio de um `forget --prune`.
- `os/linux/backup-agent.sh`: falha no `forget/prune` (Estagio 3, local ou
  nuvem) agora e detectada, logada como `[ERROR]` e reportada ao Zabbix —
  antes, uma falha nessa etapa passava despercebida e o log terminava com
  `=== EXECUCAO FINALIZADA ===` como se tudo tivesse dado certo.
- `devops/zabbix/template_backup_agent.xml`: novos itens Trapper
  `restic.retention.local.status` e `restic.retention.cloud.status` (com
  triggers HIGH), para os dois fixes acima aparecerem no Zabbix. Reimportar
  o template nos hosts ja cadastrados.

### Changed
- `docs/deployment.md` secao 2 (instalacao manual) detalhada em
  subsecoes (2.1-2.5): preparo do disco do `REPO_LOCAL` (aviso sobre
  mount NFS/iSCSI caindo silenciosamente), tabela dos campos minimos do
  `backup.env`, aviso de que `RESTIC_PASSWORD` e obrigatorio e
  irrecuperavel se perdido, e nota sobre dimensionamento de espaco.
- `docs/disaster-recovery.md`: novo "Cenario 5" sobre locks do Restic,
  diferenciando execucao concorrente (agora prevenida pelo `flock`) de
  lock travado (`stale`) apos um processo morrer sem liberar.

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
