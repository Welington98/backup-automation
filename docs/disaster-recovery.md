# Disaster Recovery - backup-agent (Fase 1)

## Cenario 1: Perda do disco/NAS local (repositorio local intacto na nuvem)

1. Provisione um novo disco/NAS e monte no mesmo ponto usado por
   `REPO_LOCAL` (ou aponte `REPO_LOCAL` para o novo caminho).
2. Reinicialize o repositorio local, se necessario:
   ```bash
   restic -r "$REPO_LOCAL" init
   ```
3. Restaure diretamente a partir da nuvem (nao e necessario esperar o
   repositorio local ser reconstruido):
   ```bash
   backup-agent.sh list                                            # ou: restic -r "$REPO_CLOUD" snapshots
   backup-agent.sh restore --cloud --target /caminho/restauracao    # ou: restic -r "$REPO_CLOUD" restore <snapshot-id> --target ...
   ```
   `backup-agent.sh restore`/`files` cobrem o caso comum (ler
   `backup.env`, montar o `-r` certo); para algo mais especifico do
   Restic (`--verify`, `--exclude`, restaurar so um UID/permissao
   especifica etc.) use o `restic` direto como no comentario acima.
4. O proximo ciclo do `backup-agent.sh` volta a popular o repositorio local
   normalmente.

## Cenario 2: Perda total do servidor cliente (novo host)

1. Reinstale o SO base e execute `os/linux/install.sh` no novo host.
2. Restaure `/etc/backup-agent/backup.env` a partir do backup de
   configuracao (ou reconfigure manualmente, mantendo o mesmo
   `RESTIC_PASSWORD` para conseguir ler os snapshots existentes na nuvem).
3. Gere uma nova PSK (`backup-agent-generate-psk.sh`) e recadastre-a no
   Zabbix Server para o host (a PSK antiga fica invalida).
4. Restaure os dados a partir de `REPO_CLOUD` (ver Cenario 1, passo 3).
5. Valide a proxima execucao agendada e o recebimento de telemetria no
   Zabbix.

## Cenario 3: Perda da senha Restic (`RESTIC_PASSWORD`)

Sem a senha, **os dados nos repositorios (local e nuvem) sao
irrecuperaveis** — a criptografia do Restic e end-to-end e nao ha
mecanismo de recuperacao de senha.

Mitigacao: armazene `RESTIC_PASSWORD` em um cofre de segredos separado do
host (gestor de senhas da equipe, secret manager) e nunca apenas no
`backup.env` do proprio servidor. A introducao futura do HashiCorp Vault
podera centralizar tambem este segredo.

## Cenario 4: Corrupcao do repositorio Restic

```bash
restic -r "$REPO" check
restic -r "$REPO" check --read-data   # mais lento, verifica integridade dos dados
restic -r "$REPO" rebuild-index       # se o indice estiver corrompido
```

Se o repositorio local estiver corrompido mas a nuvem estiver integra,
trate como o Cenario 1 (descartar o repositorio local e recria-lo a partir
da proxima execucao) e restaure dados criticos a partir da nuvem enquanto
isso.

## Cenario 5: Repositorio bloqueado (lock do Restic)

O Restic usa um lock exclusivo no repositorio durante `backup`, `forget
--prune` e outras operacoes de escrita, para evitar que duas execucoes
corrompam o mesmo repositorio. Se voce ver algo como:

```
repo already locked, waiting up to 0s for the lock
unable to create lock in backend: repository is already locked exclusively
by PID 384558 on <host> by root (UID 0, GID 0)
lock was created at ... (Ns ago)
the `unlock` command can be used to remove stale locks
```

Ha duas causas possiveis:

1. **Execucao concorrente real** (outro processo do `backup-agent.sh` ou um
   comando `restic` manual esta rodando *agora* no mesmo repositorio). O
   `backup-agent.sh` ja tem seu proprio lock (`flock` em
   `/var/lock/backup-agent.lock`) que impede duas instancias *do script*
   rodarem ao mesmo tempo — mas isso nao impede um `restic` chamado
   manualmente por voce de colidir com uma execucao do script em
   andamento. Nesse caso, **espere a outra execucao terminar** (confira
   com `ps aux | grep restic`) — nao force um `unlock` com um processo
   ainda ativo, ou vai corromper o repositorio.
2. **Lock travado (stale)**: o processo que segurava o lock morreu (kill
   -9, falta de energia, OOM killer) sem liberar. Confirme que o PID do
   erro nao existe mais (`ps -p <PID>`) e, so entao, libere manualmente:
   ```bash
   restic -r "$REPO" unlock
   ```

## Teste periodico de restauracao

Recomenda-se validar trimestralmente que um snapshot recente pode ser
restaurado com sucesso, em um ambiente isolado:

```bash
restic -r "$REPO_CLOUD" restore latest --target /tmp/dr-test --verify
```

Registre a data e o resultado desse teste — ele e a unica forma real de
confirmar que a cadeia de backup esta funcional, alem do status verde no
Zabbix.
