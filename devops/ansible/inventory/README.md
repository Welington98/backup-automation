# Inventario Ansible - Estrutura Multi-Cliente

Inventario do `backup-agent` com isolamento completo por cliente: cada
cliente tem sua propria pasta, com hosts, variaveis e segredos separados dos
demais.

## Estrutura de diretorios

```
devops/ansible/inventory/
├── README.md                       ← este arquivo
├── TEMPLATE-NOVO-CLIENTE.md        ← guia passo a passo para adicionar um cliente
│
├── cliente_exemplo/                ← um cliente (template/exemplo)
│   ├── hosts.yml                   Inventario: hosts + grupo do cliente
│   ├── README.md                   Resumo e comandos do cliente
│   ├── group_vars/
│   │   └── cliente_exemplo.yml     Config do backup-agent + lookups no Vaultwarden
│   └── host_vars/                  Overrides por host (opcional, ver README do cliente)
│
└── [outro-cliente]/                ← proximo cliente, mesma estrutura
    ├── hosts.yml
    ├── README.md
    ├── group_vars/
    └── host_vars/
```

## Por que nao existe um `hosts.yml` global listando todos os clientes?

De proposito. Um inventario global unico exigiria duplicar `group_vars` em
dois lugares (dentro da pasta do cliente e no nivel raiz) para funcionar
corretamente — o Ansible so carrega `group_vars/`/`host_vars/` que estao ao
lado do arquivo de inventario que voce de fato passar em `-i`. Manter cada
cliente 100% autocontido evita essa duplicacao e, mais importante, evita
rodar um playbook contra todos os clientes de uma vez por engano.

**Cada cliente e sempre executado isoladamente:**

```bash
ansible-playbook -i inventory/<cliente>/hosts.yml playbook.yml
```

## Grupos usados em todo cliente

- `backup_clients` — todos os hosts do cliente que rodam o `backup-agent`
  (e o grupo que o `playbook.yml` usa como `hosts:`).
- `<cliente>` — grupo com o nome do cliente, agregando `backup_clients` e
  carregando `group_vars/<cliente>.yml` (o nome do arquivo precisa bater com
  o nome do grupo para o Ansible carregar automaticamente).

## Segredos (Vaultwarden)

Os segredos (senha mestre do Restic, chaves AWS, senhas SSH) nao ficam no
repositorio, nem em texto puro nem criptografados — eles vem do
**Vaultwarden** da empresa via lookup do Ansible
(`community.general.bitwarden`).

Convencao: um item **Secure Note** por cliente, nomeado
`backup-agent - <cliente>`, com um campo customizado por segredo (ex.:
`restic_password`, `aws_access_key`, `aws_secret_key`,
`srv_01_ssh_password` e, opcionalmente, `zabbix_api_url`/`zabbix_api_token`
— so se for usar o cadastro automatico do host no Zabbix via API, ver
`docs/zabbix-monitoring.md` secao 3). Cada `group_vars/<cliente>.yml`
referencia esse item via `lookup()` — veja
`cliente_exemplo/group_vars/cliente_exemplo.yml` e o README do cliente
para a lista exata de campos esperados.

Na maquina que roda o Ansible (control node), uma vez:

```bash
ansible-galaxy collection install -r ../requirements.yml
bw config server https://vault.suaempresa.com
bw login
```

E a cada sessao de deploy (o Bitwarden/Vaultwarden bloqueia o vault entre
sessoes por design — nao ha como automatizar isso sem guardar a master
password em algum lugar, o que so move o problema):

```bash
export BW_SESSION=$(bw unlock --raw)
```

Sem isso, os comandos abaixo falham com um erro do `bw` (`Not logged in.`
ou `Vault is locked.`) — refaca o `bw login`/`bw unlock` e tente de novo.

> **Fora de escopo:** o Vaultwarden nao implementa a API do Bitwarden
> *Secrets Manager* (produto separado, com "machine accounts" e sem
> necessidade de desbloqueio manual). Por isso a integracao usa o cofre de
> senhas normal (`community.general.bitwarden`), nao
> `bitwarden_secrets_manager`.

## Autenticacao SSH suportada

Os dois metodos convivem no mesmo inventario, host a host (veja
`cliente_exemplo/hosts.yml`):

- **Senha:** `ansible_password: "{{ vault_<algo>_ssh_password }}"` — requer
  o pacote `sshpass` instalado na maquina que roda o Ansible.
- **Chave SSH (recomendado):** `ansible_ssh_private_key_file: "~/.ssh/..."`.
  A chave privada nunca e versionada neste repositorio.

## Prioridade de variaveis (maior → menor)

```
1. host_vars/<host>.yml                  (dentro da pasta do cliente)
2. group_vars/<cliente>.yml              (configuracao do cliente + lookups Vaultwarden)
3. roles/backup_agent/defaults/main.yml  (fallback do projeto)
```

`backup_agent_env` e um unico dict — em Ansible, dicts nao fazem merge
automatico entre niveis de precedencia. Isso significa que
`group_vars/<cliente>.yml` deve redefinir o dict **inteiro** (nao so os
campos que mudam em relacao ao padrao), e um override em `host_vars/`
tambem precisa copiar o dict inteiro, ajustando so o campo necessario.

## Comandos uteis

Sempre com `BW_SESSION` exportado (ver secao Segredos acima):

```bash
# Validar sintaxe
ansible-inventory -i inventory/<cliente>/hosts.yml --list

# Testar conectividade
ansible backup_clients -i inventory/<cliente>/hosts.yml -m ping

# Deploy
ansible-playbook -i inventory/<cliente>/hosts.yml playbook.yml

# Dry-run
ansible-playbook -i inventory/<cliente>/hosts.yml playbook.yml --check --diff

# Um host especifico
ansible-playbook -i inventory/<cliente>/hosts.yml playbook.yml --limit cliente-exemplo-srv-01
```

## Adicionar um novo cliente

Caminho recomendado - [`new-client.sh`](new-client.sh) automatiza a copia,
o rename e a substituicao do nome do cliente:

```bash
cd devops/ansible/inventory
./new-client.sh meu-novo-cliente "Meu Novo Cliente Ltda"
# edite hosts.yml, group_vars/meu-novo-cliente.yml e README.md
# crie o item "backup-agent - meu-novo-cliente" no Vaultwarden (ver secao Segredos)
```

Passo a passo completo (inclusive o que o script nao automatiza): ver
[`TEMPLATE-NOVO-CLIENTE.md`](TEMPLATE-NOVO-CLIENTE.md). Alternativa manual,
sem o script:

```bash
cd devops/ansible/inventory
cp -r cliente_exemplo meu-novo-cliente
cd meu-novo-cliente
mv group_vars/cliente_exemplo.yml group_vars/meu-novo-cliente.yml
```
