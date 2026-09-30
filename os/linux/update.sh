#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT - ATUALIZACAO (Linux)
# Atualiza o clone local do repositorio (git pull --ff-only) e reaplica os
# scripts em /usr/local/bin. NAO mexe em backup.env nem excludes.txt - a
# configuracao ja feita no servidor fica intacta.
#
# Uso (rodar de dentro do clone do repositorio no servidor):
#   cd backup-automation && sudo os/linux/update.sh
# ==============================================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Execute como root (sudo)." >&2
    exit 1
fi

BRANCH="${BACKUP_AGENT_UPDATE_BRANCH:-main}"
INSTALL_BIN="/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "[ERROR] $REPO_DIR nao parece ser um clone git do backup-agent (.git nao encontrado)." >&2
    echo "        Rode este script de dentro do clone do repositorio no servidor." >&2
    exit 1
fi

cd "$REPO_DIR"

if [ -n "$(git status --porcelain)" ]; then
    echo "[ERROR] Ha alteracoes locais nao commitadas em $REPO_DIR:" >&2
    git status --short >&2
    echo "[ERROR] Resolva isso (commit, descarte ou stash) antes de atualizar, para nao perder nada." >&2
    exit 1
fi

BEFORE_COMMIT="$(git rev-parse HEAD)"

echo "[INFO] Buscando atualizacoes de origin/$BRANCH..."
git fetch origin "$BRANCH"

if ! git merge --ff-only "origin/$BRANCH"; then
    echo "[ERROR] Nao foi possivel avancar para origin/$BRANCH em fast-forward." >&2
    echo "        O clone local divergiu do remoto (commits locais no branch atual?)." >&2
    echo "        Resolva manualmente (ex: git log --oneline HEAD..origin/$BRANCH) antes de tentar de novo." >&2
    exit 1
fi

AFTER_COMMIT="$(git rev-parse HEAD)"

if [ "$BEFORE_COMMIT" = "$AFTER_COMMIT" ]; then
    echo "[INFO] Ja estava atualizado (nada novo em origin/$BRANCH)."
else
    echo "[INFO] Atualizado de ${BEFORE_COMMIT:0:7} para ${AFTER_COMMIT:0:7}:"
    git log --oneline "$BEFORE_COMMIT..$AFTER_COMMIT"

    if git diff --name-only "$BEFORE_COMMIT" "$AFTER_COMMIT" | grep -q "^devops/zabbix/template_backup_agent\.xml$"; then
        echo "[WARN] devops/zabbix/template_backup_agent.xml mudou - reimporte o template no Zabbix Server (ver docs/zabbix-monitoring.md)."
    fi
fi

echo "[INFO] Reaplicando scripts em $INSTALL_BIN..."
install -m 750 "$REPO_DIR/os/linux/backup-agent.sh" "$INSTALL_BIN/backup-agent.sh"
install -m 750 "$REPO_DIR/os/linux/generate-psk.sh" "$INSTALL_BIN/backup-agent-generate-psk.sh"

echo "[SUCCESS] Atualizacao concluida."
"$INSTALL_BIN/backup-agent.sh" --version
