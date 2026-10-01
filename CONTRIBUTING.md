# Contribuindo

## CI (.github/workflows/ci.yml)

Toda `pull_request` para `main` e todo push em branch diferente de `main`
rodam 4 checks automaticamente:

| Job | O que valida |
|---|---|
| `lint-shell` | `bash -n` (sintaxe) + `shellcheck` (severidade warning) em todo `*.sh` de `os/` e `devops/` |
| `lint-yaml` | `yamllint` (config em `.yamllint.yml`) nos YAML do repo (Ansible, workflows) |
| `validate-zabbix-template` | `scripts/validate-zabbix-template.py` - XML bem formado e todo `<uuid>` e um UUIDv4 valido e unico. Existe porque um UUID invalido ja chegou a um PR e so foi descoberto na hora de importar o template no Zabbix Server ("Invalid parameter '/N/uuid': UUIDv4 is expected.") |
| `functional-test` | `os/linux/test/functional-test.sh` - roda o pipeline completo, `check` (rapido e `--read-data`), `list`, `files`, `restore`, `--version`/`--help` e os casos de erro (comando/opcao invalida) contra um repositorio Restic descartavel, e falha se qualquer saida/exit code esperado nao bater |

Rode localmente antes de abrir o PR (reduz o ciclo de espera do CI):

```bash
# lint
shellcheck -x --severity=warning os/linux/*.sh os/linux/test/*.sh
yamllint -c .yamllint.yml .
python3 scripts/validate-zabbix-template.py

# teste funcional (precisa de sudo, restic e jq instalados)
sudo os/linux/test/functional-test.sh
```

`.github/workflows/release.yml` e separado e so roda em push direto a
`main` (gera version/changelog/release - ver secao abaixo).

## Versionamento (semantic-release)

Este repositorio usa [semantic-release](https://semantic-release.gitbook.io/)
para gerar versoes, `CHANGELOG.md` e GitHub Releases **automaticamente** a
partir das mensagens de commit, toda vez que algo e mesclado em `main`
(`.github/workflows/release.yml`).

Para isso funcionar, **todo commit em `main` precisa seguir o padrao
[Conventional Commits](https://www.conventionalcommits.org/)**:

```
<tipo>(<escopo opcional>): <descricao curta em ingles, imperativo>

<corpo opcional, pode ser em portugues, explicando o "porque">
```

### Tipos que importam para a versao

| Tipo | Efeito na versao | Exemplo |
|---|---|---|
| `fix:` | PATCH (`1.0.0` -> `1.0.1`) | `fix: send RESTIC_FROM_PASSWORD on cloud copy` |
| `feat:` | MINOR (`1.0.0` -> `1.1.0`) | `feat: split local/cloud size metrics` |
| `fix!:`, `feat!:`, ou corpo com `BREAKING CHANGE:` | MAJOR (`1.0.0` -> `2.0.0`) | `feat!: drop support for Ansible <2.14` |

### Tipos que nao disparam release (mas sao bem-vindos)

`docs:`, `chore:`, `refactor:`, `test:`, `style:`, `ci:`, `build:` — entram
no historico do git normalmente, mas o `commit-analyzer` os ignora para
efeito de versionamento. Use o tipo que descreve melhor a mudanca.

### Exemplos reais deste projeto

```
fix: send RESTIC_FROM_PASSWORD on restic copy to cloud repo

restic copy --from-repo needs the source repository's own password.
Without it, restic tries to prompt interactively and fails under
cron/non-interactive execution with "unable to read password".
```

```
feat: add value map for status items in Zabbix template

Latest data and graphs now show "OK"/"Falha" instead of raw 0/1 for
restic.backup.status and the two retention status items.
```

### O que acontece automaticamente a cada merge em `main`

1. `commit-analyzer` le todos os commits desde o ultimo release e decide
   se sai patch, minor, major ou nada (se so houver `docs:`/`chore:`/etc).
2. `release-notes-generator` monta as notas da release a partir dos
   commits.
3. `CHANGELOG.md` e atualizado (plugin `@semantic-release/changelog`).
4. A versao e gravada em `package.json` e em `BACKUP_AGENT_VERSION` no
   topo de `os/linux/backup-agent.sh` (plugin `@semantic-release/exec`,
   configurado em `.releaserc.json`) — confira com
   `os/linux/backup-agent.sh --version`.
5. Um commit `chore(release): X.Y.Z [skip ci]` e uma tag `vX.Y.Z` sao
   criados e enviados para `main` (plugin `@semantic-release/git`).
6. Uma GitHub Release e publicada com as notas geradas (plugin
   `@semantic-release/github`).

Nao ha publicacao em nenhum registry (`npm`, etc.) — o `package.json`
existe so para o `semantic-release` rodar e para manter a versao visivel
em um lugar padrao; o projeto continua sendo scripts/Ansible/Zabbix, nao
um pacote Node.js.

### Observacao importante

Commits anteriores a essa configuracao **nao** seguem esse padrao e nao
contam para o versionamento — o primeiro release so acontece a partir do
primeiro commit `fix:`/`feat:`/etc. que for mesclado em `main` depois
desta mudanca.
