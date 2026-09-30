# Deployment - backup-agent (Fase 1)

## 1. Requisitos

### Servidor cliente (Linux)
- SO: Univention Corporate Server (UCS), Debian 10+, Ubuntu 18.04+,
  RHEL/CentOS 8+, Rocky Linux.
- Pacotes: `restic`, `zabbix-sender`, `curl`, `jq`, `openssl`, `cron`
  (opcional: `rclone` para Google Drive/OneDrive).
- Armazenamento: disco secundario ou ponto de montagem NFS/iSCSI para o
  repositorio local.

### Rede / Firewall (saida)
- TCP `10051` liberado para o Zabbix Server central.
- TCP `443` liberado para o endpoint do bucket S3/nuvem (e para o Zabbix
  Server se ele expuser API/agent por HTTPS).

### Zabbix Server
- Template `devops/zabbix/template_backup_agent.xml` importado.
- Host cadastrado com **Encryption: PSK** (Connections to/from host = PSK),
  usando a identity e o valor gerados por `generate-psk.sh` no cliente.

## 2. Instalacao manual (um host)

```bash
git clone <repo> backup-agent && cd backup-agent
sudo os/linux/install.sh
```

O `install.sh`:
1. Instala as dependencias via `apt`/`dnf`/`yum`.
2. Cria `/etc/backup-agent/` (config) e `/var/log/backup-agent.log`.
3. Copia os scripts para `/usr/local/bin/`.
4. Cria `/etc/backup-agent/backup.env` a partir do template (se nao existir).
5. Agenda a execucao diaria em `/etc/cron.d/backup-agent` (03:30).

Depois de instalar:

```bash
# 1. Edite as credenciais e paths
sudo vi /etc/backup-agent/backup.env

# 2. Inicialize os repositorios restic (uma vez)
restic -r /mnt/backup-local/restic-repo init
restic -r s3:s3.amazonaws.com/seu-bucket/CLIENTE/HOSTNAME init

# 3. Gere a PSK do canal Zabbix
sudo /usr/local/bin/backup-agent-generate-psk.sh
# -> copie a "PSK identity" e o "PSK value" impressos

# 4. Cadastre a PSK no Zabbix Server
# Data collection > Hosts > <host> > Encryption > PSK

# 5. Teste manualmente
sudo /usr/local/bin/backup-agent.sh
tail -f /var/log/backup-agent.log
```

## 3. Deploy em massa (Ansible) - inventario multi-cliente

Arquivos prontos em `devops/ansible/`:

```
devops/ansible/
├── ansible.cfg                     # roles_path; sem inventario padrao (ver abaixo)
├── requirements.yml                # collection community.general (lookup do Vaultwarden)
├── playbook.yml                    # playbook principal (hosts: backup_clients)
├── inventory/
│   ├── README.md                   # como funciona o inventario multi-cliente
│   ├── TEMPLATE-NOVO-CLIENTE.md    # passo a passo para adicionar um cliente
│   └── cliente_exemplo/            # um cliente = uma pasta autocontida
│       ├── hosts.yml               # hosts + auth (exemplos de senha e chave SSH)
│       ├── README.md
│       └── group_vars/
│           └── cliente_exemplo.yml # config do cliente + lookups no Vaultwarden
└── roles/backup_agent/             # role (defaults, tasks, templates)
```

Os segredos (senha mestre do Restic, chaves AWS, senhas SSH) nao ficam no
repositorio — vem do **Vaultwarden** da empresa via lookup do Ansible
(`community.general.bitwarden`), um item por cliente. Ver
["Segredos (Vaultwarden)"](../devops/ansible/inventory/README.md#segredos-vaultwarden)
no README do inventario.

Cada cliente e uma pasta isolada sob `inventory/`, sem inventario global —
todo comando informa explicitamente qual cliente com `-i
inventory/<cliente>/hosts.yml`. Detalhes completos, incluindo por que nao
ha um `hosts.yml` unico para todos os clientes, estao em
[`devops/ansible/inventory/README.md`](../devops/ansible/inventory/README.md).

### 3.1 Adicionar/configurar um cliente

Para o primeiro cliente real, copie `inventory/cliente_exemplo/` (ver
[`TEMPLATE-NOVO-CLIENTE.md`](../devops/ansible/inventory/TEMPLATE-NOVO-CLIENTE.md)
para o passo a passo completo):

```bash
cd devops/ansible/inventory
cp -r cliente_exemplo meu-cliente
cd meu-cliente
mv group_vars/cliente_exemplo.yml group_vars/meu-cliente.yml
```

1. Edite `hosts.yml` com os hosts reais do cliente. Cada host escolhe seu
   metodo de autenticacao SSH:
   - **Senha:** `ansible_password` (requer `sshpass` instalado na maquina
     que roda o Ansible).
   - **Chave SSH (recomendado):** `ansible_ssh_private_key_file`.
2. Edite `group_vars/meu-cliente.yml` com o `backup_agent_env` do cliente
   (paths, bucket S3, servidor Zabbix) e o `_bw_item` (nome do item no
   Vaultwarden — ver passo 3).
3. Crie no Vaultwarden da empresa um item **Secure Note** chamado
   `backup-agent - meu-cliente`, com um campo customizado por segredo:
   `restic_password`, `aws_access_key`, `aws_secret_key` e
   `<host>_ssh_password` (um por host com autenticacao por senha). Nada
   disso fica no repositorio — nem em texto puro, nem criptografado.
4. A role tem um `assert` que falha o playbook se `RESTIC_PASSWORD` ou as
   credenciais AWS (quando `ENABLE_CLOUD_SYNC=true`) ainda estiverem com o
   valor padrao `CHANGE_ME`, como rede de seguranca contra esquecer o passo 3
   (item nao criado, campo com nome errado etc).

### 3.2 Executar

Uma vez por maquina de controle:

```bash
cd devops/ansible
ansible-galaxy collection install -r requirements.yml
bw config server https://vault.suaempresa.com
bw login
```

A cada sessao de deploy (o Vaultwarden bloqueia o vault entre sessoes):

```bash
export BW_SESSION=$(bw unlock --raw)

ansible-playbook -i inventory/meu-cliente/hosts.yml playbook.yml

# se o sudo no host remoto pedir senha:
ansible-playbook -i inventory/meu-cliente/hosts.yml playbook.yml --ask-become-pass

# dry-run:
ansible-playbook -i inventory/meu-cliente/hosts.yml playbook.yml --check --diff

# um host especifico do cliente:
ansible-playbook -i inventory/meu-cliente/hosts.yml playbook.yml --limit meu-cliente-srv-01
```

> **Nota de seguranca:** a task que exibe a PSK gerada usa `debug`, que pode
> ficar registrada em logs do Ansible/CI. Em ambientes com logging
> centralizado, considere adicionar `no_log: true` a essa task
> (`devops/ansible/roles/backup_agent/tasks/main.yml`) e distribuir a PSK
> por um canal separado.

## 4. Cron

```cron
# Execucao diaria as 03:30
30 3 * * * root /usr/local/bin/backup-agent.sh > /dev/null 2>&1
```

Instalado automaticamente em `/etc/cron.d/backup-agent` pelo `install.sh`
(ou pela role Ansible). Nao ha job de renovacao de certificado nesta fase,
pois a PSK e estatica.

## 5. Checklist pos-deploy

- [ ] `restic snapshots -r $REPO_LOCAL` mostra o snapshot mais recente.
- [ ] `restic snapshots -r $REPO_CLOUD` mostra o snapshot replicado.
- [ ] Item `restic.backup.status` no Zabbix recebeu valor `1`.
- [ ] Trigger "No Data Received (26h)" nao esta disparada.
- [ ] `/var/log/backup-agent.log` sem erros na ultima execucao.
