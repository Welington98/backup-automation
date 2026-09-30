#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT - BOOTSTRAP / INSTALACAO (Linux)
# Fase 1: sem HashiCorp Vault. TLS do canal Zabbix via PSK estatica.
# ==============================================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Execute como root (sudo)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN="/usr/local/bin"
CONFIG_DIR="/etc/backup-agent"
LOG_FILE="/var/log/backup-agent.log"

echo "[INFO] Detectando gerenciador de pacotes..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    PKG_INSTALL=(apt-get install -y)
    PACKAGES=(restic zabbix-sender curl jq cron openssl)
elif command -v dnf >/dev/null 2>&1; then
    PKG_INSTALL=(dnf install -y)
    PACKAGES=(restic zabbix-sender curl jq cronie openssl)
elif command -v yum >/dev/null 2>&1; then
    PKG_INSTALL=(yum install -y)
    PACKAGES=(restic zabbix-sender curl jq cronie openssl)
else
    echo "[ERROR] Gerenciador de pacotes nao suportado. Instale manualmente: restic, zabbix-sender, curl, jq, openssl." >&2
    exit 1
fi

echo "[INFO] Instalando dependencias: ${PACKAGES[*]}"
"${PKG_INSTALL[@]}" "${PACKAGES[@]}"

read -rp "Habilitar suporte a Rclone (Google Drive/OneDrive)? [y/N] " ENABLE_RCLONE
if [[ "$ENABLE_RCLONE" =~ ^[Yy]$ ]]; then
    "${PKG_INSTALL[@]}" rclone
fi

echo "[INFO] Criando diretorios..."
mkdir -p "$CONFIG_DIR/certs"
chmod 700 "$CONFIG_DIR/certs"
touch "$LOG_FILE"

echo "[INFO] Instalando scripts em $INSTALL_BIN..."
install -m 750 "$SCRIPT_DIR/backup-agent.sh" "$INSTALL_BIN/backup-agent.sh"
install -m 750 "$SCRIPT_DIR/generate-psk.sh" "$INSTALL_BIN/backup-agent-generate-psk.sh"

if [ ! -f "$CONFIG_DIR/backup.env" ]; then
    install -m 600 "$SCRIPT_DIR/backup.env.template" "$CONFIG_DIR/backup.env"
    echo "[WARN] Edite $CONFIG_DIR/backup.env antes de habilitar o cron."
else
    echo "[INFO] $CONFIG_DIR/backup.env ja existe, mantendo o arquivo atual."
fi

if [ ! -f "$CONFIG_DIR/excludes.txt" ]; then
    install -m 644 "$SCRIPT_DIR/excludes.txt" "$CONFIG_DIR/excludes.txt"
fi

CRON_FILE="/etc/cron.d/backup-agent"
cat > "$CRON_FILE" <<'EOF'
# backup-agent - Execucao diaria as 03:30
30 3 * * * root /usr/local/bin/backup-agent.sh > /dev/null 2>&1
EOF
chmod 644 "$CRON_FILE"

echo "[SUCCESS] Instalacao concluida."
echo
echo "Proximos passos:"
echo "  1. Edite $CONFIG_DIR/backup.env"
echo "  2. Inicialize o repositorio restic local:  restic -r <REPO_LOCAL> init"
echo "  3. (Opcional) Inicialize o repositorio na nuvem: restic -r <REPO_CLOUD> init"
echo "  4. Se ENABLE_ZABBIX_TLS=true, rode: $INSTALL_BIN/backup-agent-generate-psk.sh"
echo "  5. Cadastre a PSK gerada no host correspondente no Zabbix Server"
