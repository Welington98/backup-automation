#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT - GERACAO DE PSK ESTATICA PARA O CANAL ZABBIX
# Fase 1 (sem HashiCorp Vault): chave gerada localmente e cadastrada
# manualmente (ou via Ansible) no host correspondente no Zabbix Server.
# ==============================================================================

set -euo pipefail

ENV_FILE="/etc/backup-agent/backup.env"

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Execute como root." >&2
    exit 1
fi

if [ -f "$ENV_FILE" ]; then
    # Caminho so existe no host de destino, nao no repo.
    set -o allexport
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +o allexport
else
    echo "[CRITICAL] Arquivo $ENV_FILE nao encontrado!" >&2
    exit 1
fi

if [ "${ENABLE_ZABBIX_TLS:-false}" != "true" ]; then
    echo "[INFO] ENABLE_ZABBIX_TLS != true. Nada a fazer."
    exit 0
fi

PSK_FILE="${ZABBIX_TLS_PSK_FILE:-/etc/backup-agent/certs/zabbix.psk}"
PSK_IDENTITY="${ZABBIX_TLS_PSK_IDENTITY:-backup-agent:${ZABBIX_HOSTNAME:-unknown}}"

mkdir -p "$(dirname "$PSK_FILE")"
chmod 700 "$(dirname "$PSK_FILE")"

if [ -f "$PSK_FILE" ]; then
    echo "[INFO] PSK ja existe em $PSK_FILE. Nada a fazer (apague o arquivo para gerar uma nova)."
    exit 0
fi

openssl rand -hex 32 > "$PSK_FILE"
chmod 600 "$PSK_FILE"

echo "[SUCCESS] PSK gerada em $PSK_FILE"
echo
echo "Cadastre este host no Zabbix Server em:"
echo "  Data collection > Hosts > <host> > Encryption"
echo "    Connections to host:   PSK"
echo "    Connections from host: PSK"
echo "    PSK identity: $PSK_IDENTITY"
echo "    PSK value:    $(cat "$PSK_FILE")"
