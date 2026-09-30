# [1.2.0](https://github.com/Welington98/backup-automation/compare/v1.1.0...v1.2.0) (2026-09-30)


### Features

* add --help to backup-agent.sh and reject unknown commands ([db1716f](https://github.com/Welington98/backup-automation/commit/db1716f9618a136631938a6a178a71a82a1169af))
* add files and restore subcommands to backup-agent.sh ([22bb52e](https://github.com/Welington98/backup-automation/commit/22bb52e759a712fb31c1c5ac8d8d7ea7215b8f0c))
* add update.sh to safely pull and reapply changes on servers ([641cc83](https://github.com/Welington98/backup-automation/commit/641cc834bfbf42638d58c74569d8e3d867dbef01))

# [1.1.0](https://github.com/Welington98/backup-automation/compare/v1.0.0...v1.1.0) (2026-09-30)


### Features

* add list subcommand to backup-agent.sh ([caa8018](https://github.com/Welington98/backup-automation/commit/caa8018f683bf19d6a705ca66c91c368a12af9f6))

# 1.0.0 (2026-09-30)


### Features

* add semantic-release for automated versioning ([e6751ad](https://github.com/Welington98/backup-automation/commit/e6751ad6921deebac1822eeb2d2728d1e6ff85c0))

# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
versionamento seguindo [SemVer](https://semver.org/lang/pt-BR/).

> A partir daqui, este arquivo e atualizado automaticamente pelo
> [semantic-release](https://semantic-release.gitbook.io/) a cada release,
> com base nas mensagens de commit (Conventional Commits — ver
> [`CONTRIBUTING.md`](CONTRIBUTING.md)). As entradas abaixo de `[Unreleased]`
> foram escritas a mao durante o desenvolvimento inicial, antes dessa
> automacao existir.

## [Unreleased]

### Added
- `devops/zabbix/template_backup_agent.xml`: Value Map **"Backup Agent
  Status"** (`0` -> "Falha", `1` -> "OK") aplicado aos tres itens de status
  (`restic.backup.status`, `restic.retention.local.status`,
  `restic.retention.cloud.status`) — Latest data e graficos no Zabbix
  passam a mostrar texto em vez de `0`/`1` cru. Estrutura do XML (tag
  `<valuemaps>` a nivel de template, `<valuemap><name>` a nivel de item)
  confirmada criando o value map de verdade via API e exportando, contra
  um Zabbix Server 6.0 real, antes de escrever no arquivo a mao — import,
  vinculo aos 3 itens e reimport validados.
- `README.md`: secao "Atualizar o agente nos servidores" — como reaplicar
  mudancas deste repositorio nos servidores ja instalados, tanto para
  instalacao manual (`install.sh` + `git pull` + `install`) quanto via
  Ansible (automatico a cada `ansible-playbook`).
- Metricas de tamanho e contagem de snapshots agora sao reportadas
  **separadamente** para local e nuvem: `restic.repo.size` e
  `restic.repo.snapshots` viraram `restic.repo.size.local`/`.cloud` e
  `restic.repo.snapshots.local`/`.cloud` (`os/linux/backup-agent.sh`,
  `devops/zabbix/template_backup_agent.xml`). Antes, com
  `ENABLE_CLOUD_SYNC="true"`, so o tamanho da nuvem era reportado — o
  repositorio local nunca aparecia. Validado com import real (create +
  update) contra um Zabbix Server 6.0 em Docker.
- `docs/zabbix-monitoring.md`: guia completo de configuracao do
  monitoramento Zabbix — importar template, criar host (sem interface,
  itens sao Trapper), cadastrar encryption PSK, variaveis do `backup.env`,
  teste manual com `zabbix_sender`, tabela de todos os itens enviados pelo
  `backup-agent.sh` e troubleshooting comum.

### Fixed
- `os/linux/backup-agent.sh`: Estagio 2 (`restic copy` para a nuvem) falhava
  sempre em execucao nao-interativa (cron ou script manual sem terminal)
  com `unable to read password` / `unable to get terminal state: inappropriate
  ioctl for device`. O comando usava a flag depreciada `--repo2` sem nunca
  fornecer a senha do repositorio de origem — o Restic tentava pedi-la de
  forma interativa e nao havia terminal disponivel. Migrado para
  `-r "$REPO_CLOUD" copy --from-repo "$REPO_LOCAL"` (sintaxe atual, nao
  depreciada) com `RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"` (mesma senha
  mestre usada nos dois repositorios). `docs/architecture.md` atualizado
  para refletir `--from-repo`. Reproduzido e validado com o binario real
  do `restic` (nao so mock): sem o fix, falha exatamente como no servidor;
  com o fix, a copia do snapshot para o repositorio de destino funciona.
- `devops/zabbix/template_backup_agent.xml`: tag raiz corrigida de
  `<template_groups>` para `<groups>` — `template_groups` so existe a
  partir do Zabbix 6.2, mas o arquivo declara `<version>6.0</version>`,
  causando falha na importacao (`Invalid tag "/zabbix_export": unexpected
  tag "template_groups"`). Corrigido e **validado com um import real**
  contra um Zabbix Server 6.0 (Docker), incluindo reimportacao.
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
