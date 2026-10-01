# Template: Criar Inventario para Novo Cliente

Guia passo a passo para adicionar um cliente ao `backup-agent`.

## Passo 1: Copiar a estrutura de exemplo

Caminho recomendado - `new-client.sh` automatiza a copia, o rename e a
substituicao do nome do cliente em todos os arquivos (ver
[`new-client.sh`](new-client.sh)):

```bash
cd devops/ansible/inventory
./new-client.sh meu-cliente "Meu Cliente Ltda"
```

O script cria a pasta `meu-cliente/` (mesmo nome em tudo - pasta, grupo do
Ansible, arquivo `group_vars`, `client_name`, hosts, item do Vaultwarden) e
imprime o checklist do que ainda falta (Passos 2-7 abaixo). Pule para o
Passo 2.

<details>
<summary>Alternativa manual (sem o script)</summary>

```bash
cd devops/ansible/inventory
cp -r cliente_exemplo meu-cliente
cd meu-cliente
mv group_vars/cliente_exemplo.yml group_vars/meu-cliente.yml
```

> O nome do arquivo em `group_vars/` precisa ser igual ao nome do grupo do
> cliente definido em `hosts.yml` (`meu-cliente`) para o Ansible carregar
> as variaveis automaticamente.

</details>

## Passo 2: Editar `hosts.yml`

Substitua os hosts de exemplo pelos servidores reais do cliente. Escolha o
metodo de autenticacao por host:

```yaml
all:
  children:
    backup_clients:
      hosts:
        meu-cliente-srv-01:
          ansible_host: "203.0.113.10"
          ansible_port: 22
          ansible_user: "root"
          # Metodo SENHA (requer sshpass no control node):
          ansible_password: "{{ vault_srv_01_ssh_password }}"

        meu-cliente-srv-02:
          ansible_host: "203.0.113.11"
          ansible_port: 22
          ansible_user: "deploy"
          # Metodo CHAVE SSH (recomendado):
          ansible_ssh_private_key_file: "~/.ssh/id_backup_agent_meu_cliente"

    meu-cliente:
      children:
        backup_clients:

  vars:
    ansible_become: true
    ansible_become_method: sudo
    ansible_ssh_common_args: "-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
```

Renomeie o grupo do cliente e as chaves de host para o nome real do
cliente em todo o arquivo (grupo `meu-cliente`, hosts
`meu-cliente-srv-NN`).

## Passo 3: Editar `group_vars/meu-cliente.yml`

Ajuste `client_name`, `client_display_name`, `_bw_item` (nome do item no
Vaultwarden, ver Passo 4) e todo o dict `backup_agent_env` (paths de
backup, bucket S3, servidor Zabbix etc). Veja os comentarios no arquivo
copiado de `cliente_exemplo` e a referencia completa de campos em
`os/linux/backup.env.template` na raiz do repositorio. Os campos
`vault_restic_password`, `vault_aws_access_key`, `vault_aws_secret_key` e
`vault_<host>_ssh_password` ja vem como `lookup('community.general.bitwarden', ...)`
— nao precisam de edicao alem de renomear `_bw_item` e ajustar quais
`vault_<host>_ssh_password` existem (um por host com autenticacao por
senha).

## Passo 4: Criar o item no Vaultwarden

Crie no Vaultwarden da empresa um item **Secure Note** chamado
`backup-agent - meu-cliente` (o mesmo valor usado em `_bw_item` no Passo
3), com um campo customizado (tipo "Hidden") para cada segredo:

- `restic_password` — senha mestre do Restic deste cliente (guarde uma
  copia fora do Vaultwarden tambem; sem ela os backups sao irrecuperaveis).
- `aws_access_key` / `aws_secret_key` — credenciais do bucket
  S3/Wasabi/B2/MinIO deste cliente.
- `<host>_ssh_password` (um por host que usa autenticacao por senha, ex.
  `srv_01_ssh_password`) — apenas para hosts que nao usam chave SSH.
- `zabbix_api_url` / `zabbix_api_token` (opcional) — so se for usar o
  cadastro automatico do host no Zabbix via API em vez do cadastro manual
  (descomente `vault_zabbix_api_url`/`vault_zabbix_api_token` no
  `group_vars/meu-cliente.yml`, ver docs/zabbix-monitoring.md secao 3).

Nao ha necessidade de `ansible-vault` nem de arquivo `.example` — o
segredo mora so no Vaultwarden, o `group_vars/meu-cliente.yml` so guarda a
referencia ao item.

## Passo 5: Atualizar `README.md`

Copie o `README.md` de `cliente_exemplo` e ajuste hosts, cloud e status.

## Passo 6: Validar

```bash
cd devops/ansible
ansible-galaxy collection install -r requirements.yml   # uma vez por maquina
export BW_SESSION=$(bw unlock --raw)                     # a cada sessao
ansible-inventory -i inventory/meu-cliente/hosts.yml --list
ansible backup_clients -i inventory/meu-cliente/hosts.yml -m ping
```

Se algum comando falhar com `Not logged in.` ou `Vault is locked.`, rode
`bw login` e depois `export BW_SESSION=$(bw unlock --raw)` de novo.

## Passo 7: Deploy

```bash
# Dry-run primeiro
ansible-playbook -i inventory/meu-cliente/hosts.yml playbook.yml --check --diff

# Deploy real
ansible-playbook -i inventory/meu-cliente/hosts.yml playbook.yml
```

## Checklist

- [ ] Pasta `inventory/meu-cliente/` criada a partir de `cliente_exemplo`
- [ ] `hosts.yml` com IPs, portas e metodo de autenticacao corretos por host
- [ ] `group_vars/meu-cliente.yml` com `backup_agent_env` completo e `_bw_item` correto
- [ ] Item `backup-agent - meu-cliente` criado no Vaultwarden com todos os campos
- [ ] `README.md` do cliente atualizado
- [ ] Bucket S3/Wasabi/B2/MinIO do cliente ja existe e as credenciais funcionam
- [ ] Repositorios Restic (local e nuvem) inicializados (`restic init`)
- [ ] Host cadastrado no Zabbix Server com Encryption PSK - automatico se
      `zabbix_api_token` foi configurado no Passo 4 (a role chama
      `backup-agent-zabbix-register.sh`), manual senao (PSK gerada por
      `backup-agent-generate-psk.sh` no primeiro deploy)
- [ ] Host group no Zabbix Server = `CLIENT_NAME`/`client_name` deste
      cliente (necessario para o dashboard Grafana consolidado, ver
      `docs/grafana-dashboards.md`)
- [ ] `ansible-inventory --list` e `ansible ... -m ping` validados
- [ ] Dry-run (`--check --diff`) revisado antes do deploy real
- [ ] Cron de verificacao de integridade (`backup-agent.sh check`, semanal)
      agendado pela role e `restic.check.local.status` chegando no Zabbix
      (ver `docs/zabbix-monitoring.md` secao 6.1)
