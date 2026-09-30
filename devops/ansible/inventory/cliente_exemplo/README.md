# Cliente: Cliente Exemplo Ltda

Inventario isolado deste cliente para o `backup-agent`.

- **Hosts:** 2
  - `cliente-exemplo-srv-01` (192.168.10.10) — autenticacao por **senha SSH**
  - `cliente-exemplo-srv-02` (192.168.10.11) — autenticacao por **chave SSH**
- **Cloud:** S3 (`s3.amazonaws.com/seu-bucket-backups/cliente-exemplo/...`)
- **Zabbix:** TLS via PSK estatica (Fase 1, sem HashiCorp Vault)
- **Segredos:** Vaultwarden (item `backup-agent - cliente-exemplo`)
- **Status:** Exemplo/template — nao aponta para infraestrutura real

## Preparar segredos (Vaultwarden)

Crie no Vaultwarden da empresa um item do tipo **Secure Note** chamado
`backup-agent - cliente-exemplo`, com estes campos customizados (tipo
"Hidden" para os valores sensiveis):

| Campo customizado      | Valor                                          |
|-------------------------|-------------------------------------------------|
| `restic_password`       | Senha mestre do Restic deste cliente            |
| `aws_access_key`        | Access Key do bucket S3/Wasabi/B2/MinIO         |
| `aws_secret_key`        | Secret Key do bucket                            |
| `srv_01_ssh_password`   | Senha SSH do host `cliente-exemplo-srv-01`      |

`cliente-exemplo-srv-02` usa chave SSH (`ansible_ssh_private_key_file`),
entao nao precisa de campo no Vaultwarden.

No control node (maquina que roda o `ansible-playbook`), uma vez:

```bash
ansible-galaxy collection install -r ../../requirements.yml
bw config server https://vault.suaempresa.com
bw login
```

E a cada sessao de deploy:

```bash
export BW_SESSION=$(bw unlock --raw)
```

## Validar

```bash
cd devops/ansible
export BW_SESSION=$(bw unlock --raw)
ansible-inventory -i inventory/cliente_exemplo/hosts.yml --list
ansible backup_clients -i inventory/cliente_exemplo/hosts.yml -m ping
```

Se aparecer erro do tipo `Not logged in` ou `Vault is locked`, refaça o
`bw login`/`bw unlock` acima antes de tentar de novo.

## Deploy

```bash
cd devops/ansible
export BW_SESSION=$(bw unlock --raw)
ansible-playbook -i inventory/cliente_exemplo/hosts.yml playbook.yml
```

## Sobrescrever configuracao para um host especifico

`backup_agent_env` e um dict unico definido em `group_vars/cliente_exemplo.yml`.
Variaveis de dict **nao fazem merge automatico** entre niveis de precedencia
no Ansible (a menos que `hash_behaviour=merge` esteja ligado no `ansible.cfg`,
o que nao e recomendado por afetar todos os dicts do projeto). Para um host
precisar de um valor diferente (ex.: `BACKUP_TARGET_PATHS` maior em
`cliente-exemplo-srv-02`), copie o dict inteiro para
`host_vars/cliente-exemplo-srv-02.yml` e ajuste so o campo necessario - nao
apenas o campo isolado.
