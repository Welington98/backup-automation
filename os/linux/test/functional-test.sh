#!/usr/bin/env bash
# ==============================================================================
# Teste funcional de fumaca do backup-agent.sh
# ==============================================================================
# Executa o pipeline completo, 'check' (rapido e --read-data) e os comandos
# de exploracao/restauracao (list/files/restore) contra um repositorio
# Restic descartavel, e confere o resultado esperado de cada um. Usado pelo
# CI (.github/workflows/ci.yml); tambem pode ser rodado localmente em
# qualquer host Linux com sudo, restic e jq instalados:
#
#   sudo os/linux/test/functional-test.sh
#
# Precisa de sudo porque backup-agent.sh le sempre de
# /etc/backup-agent/backup.env (caminho fixo, nao parametrizavel).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/os/linux/backup-agent.sh"

WORKDIR="$(mktemp -d)"
OUT="$WORKDIR/out.log"
trap 'rm -rf "$WORKDIR"; rm -f /etc/backup-agent/backup.env' EXIT

mkdir -p "$WORKDIR/src" "$WORKDIR/restore"
echo "conteudo de teste" > "$WORKDIR/src/arquivo.txt"
touch "$WORKDIR/excludes.txt"

mkdir -p /etc/backup-agent
cat > /etc/backup-agent/backup.env <<EOF
RESTIC_PASSWORD="senha-teste-ci"
BACKUP_TARGET_PATHS="$WORKDIR/src"
BACKUP_TAG="ci-test"
EXCLUDE_FILE="$WORKDIR/excludes.txt"
REPO_LOCAL="$WORKDIR/repo-local"
KEEP_LOCAL_DAILY=7
ENABLE_CLOUD_SYNC="false"
ENABLE_ZABBIX="false"
LOG_PATH="$WORKDIR/backup-agent.log"
LOCK_PATH="$WORKDIR/backup-agent.lock"
EOF

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

log_has() { grep -qF "$1" "$WORKDIR/backup-agent.log" 2>/dev/null; }

RESTIC_PASSWORD="senha-teste-ci" restic -r "$WORKDIR/repo-local" init > "$OUT" 2>&1
if [ $? -ne 0 ]; then
    echo "[SETUP] Falha ao inicializar o repositorio Restic de teste:"
    cat "$OUT"
    exit 1
fi

echo "=== 1. Pipeline completo (sem argumentos) ==="
"$SCRIPT" > "$OUT" 2>&1
rc=$?
[ $rc -eq 0 ] && pass "pipeline completo termina com exit 0" || { fail "pipeline completo termina com exit $rc"; cat "$OUT"; }
log_has "[SUCCESS] Backup e sincronizacao concluidos." && pass "log registra sucesso do backup" || fail "log nao registra sucesso do backup"

SNAP_COUNT=$(RESTIC_PASSWORD="senha-teste-ci" restic -r "$WORKDIR/repo-local" snapshots --json 2>/dev/null | jq 'length')
[ "$SNAP_COUNT" = "1" ] && pass "1 snapshot criado no repositorio local" || fail "esperado 1 snapshot no repositorio local, encontrado '$SNAP_COUNT'"

echo "=== 2. check (verificacao rapida) ==="
"$SCRIPT" check > "$OUT" 2>&1
rc=$?
[ $rc -eq 0 ] && pass "'check' termina com exit 0" || { fail "'check' termina com exit $rc"; cat "$OUT"; }
log_has "[SUCCESS] Verificacao de integridade concluida sem erros." && pass "log registra sucesso do check" || fail "log nao registra sucesso do check"

echo "=== 3. check --read-data (verificacao completa) ==="
"$SCRIPT" check --read-data > "$OUT" 2>&1
rc=$?
[ $rc -eq 0 ] && pass "'check --read-data' termina com exit 0" || { fail "'check --read-data' termina com exit $rc"; cat "$OUT"; }

echo "=== 4. check com opcao invalida deve falhar ==="
"$SCRIPT" check --opcao-que-nao-existe > "$OUT" 2>&1
rc=$?
[ $rc -ne 0 ] && pass "'check --opcao-que-nao-existe' retorna erro" || fail "'check --opcao-que-nao-existe' deveria ter falhado"

echo "=== 5. comando desconhecido deve falhar ==="
"$SCRIPT" comando-que-nao-existe > "$OUT" 2>&1
rc=$?
[ $rc -ne 0 ] && pass "comando desconhecido retorna erro" || fail "comando desconhecido deveria ter falhado"

echo "=== 6. list ==="
"$SCRIPT" list > "$OUT" 2>&1
rc=$?
if [ $rc -eq 0 ] && grep -q "Repositorio Local" "$OUT"; then
    pass "'list' mostra o repositorio local"
else
    fail "'list' falhou ou nao mostrou o repositorio local"
fi

echo "=== 7. files ==="
"$SCRIPT" files > "$OUT" 2>&1
rc=$?
if [ $rc -eq 0 ] && grep -q "arquivo.txt" "$OUT"; then
    pass "'files' lista o arquivo de teste"
else
    fail "'files' falhou ou nao listou o arquivo de teste"
fi

echo "=== 8. restore ==="
"$SCRIPT" restore --target "$WORKDIR/restore" > "$OUT" 2>&1
rc=$?
RESTORED_FILE="$WORKDIR/restore$WORKDIR/src/arquivo.txt"
if [ $rc -eq 0 ] && [ -f "$RESTORED_FILE" ] && grep -q "conteudo de teste" "$RESTORED_FILE"; then
    pass "'restore' recupera o arquivo original com o conteudo esperado"
else
    fail "'restore' nao recuperou o arquivo esperado em $RESTORED_FILE"
fi

echo "=== 9. --version / --help ==="
"$SCRIPT" --version > "$OUT" 2>&1
[ $? -eq 0 ] && grep -qi "backup-agent" "$OUT" && pass "'--version' funciona" || fail "'--version' falhou"
"$SCRIPT" --help > "$OUT" 2>&1
[ $? -eq 0 ] && grep -q "^Uso:" "$OUT" && pass "'--help' funciona" || fail "'--help' falhou"

echo
echo "Resultado: $PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
