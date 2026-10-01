#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT - CADASTRO AUTOMATICO DO HOST NO ZABBIX SERVER (via API)
# Fase 1 (sem HashiCorp Vault): cria/atualiza host group, vincula o template
# "Backup Agent" e configura a encryption PSK via API do Zabbix, no lugar do
# cadastro manual descrito em docs/zabbix-monitoring.md. Opcional: se
# ZABBIX_API_URL/ZABBIX_API_TOKEN nao estiverem configurados em backup.env,
# este script nao faz nada e o cadastro manual continua valendo.
# ==============================================================================

set -euo pipefail

ENV_FILE="/etc/backup-agent/backup.env"
TEMPLATE_NAME="Backup Agent"

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

if [ "${ENABLE_ZABBIX:-false}" != "true" ]; then
    echo "[INFO] ENABLE_ZABBIX != true. Nada a fazer."
    exit 0
fi

if [ -z "${ZABBIX_API_URL:-}" ] || [ -z "${ZABBIX_API_TOKEN:-}" ]; then
    echo "[INFO] ZABBIX_API_URL/ZABBIX_API_TOKEN nao configurados em $ENV_FILE."
    echo "[INFO] Cadastro automatico desabilitado - cadastre o host manualmente"
    echo "       (ver docs/zabbix-monitoring.md, secao 3)."
    exit 0
fi

for bin in curl jq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "[ERROR] '$bin' nao encontrado (dependencia do install.sh)." >&2; exit 1; }
done

if [ -z "${ZABBIX_HOSTNAME:-}" ]; then
    echo "[ERROR] ZABBIX_HOSTNAME nao definido em $ENV_FILE." >&2
    exit 1
fi

if [ -z "${CLIENT_NAME:-}" ]; then
    echo "[ERROR] CLIENT_NAME nao definido em $ENV_FILE (nome do host group - precisa" >&2
    echo "        bater com o cliente, ver docs/grafana-dashboards.md)." >&2
    exit 1
fi

TLS_CONNECT=0
TLS_ACCEPT=1
PSK_IDENTITY=""
PSK_VALUE=""

if [ "${ENABLE_ZABBIX_TLS:-false}" = "true" ]; then
    PSK_FILE="${ZABBIX_TLS_PSK_FILE:-/etc/backup-agent/certs/zabbix.psk}"
    if [ ! -f "$PSK_FILE" ]; then
        echo "[ERROR] $PSK_FILE nao encontrado. Rode backup-agent-generate-psk.sh primeiro." >&2
        exit 1
    fi
    PSK_IDENTITY="${ZABBIX_TLS_PSK_IDENTITY:-backup-agent:${ZABBIX_HOSTNAME}}"
    PSK_VALUE="$(cat "$PSK_FILE")"
    # PSK (connections to/from host): bit 2 = PSK, ver Zabbix API host object.
    TLS_CONNECT=2
    TLS_ACCEPT=2
fi

# Chama a API JSON-RPC do Zabbix. $1 = method, $2 = params (JSON valido).
# Usa o campo "auth" no corpo da requisicao (compativel com Zabbix 6.0+;
# o header Authorization: Bearer so existe a partir do 6.4) e falha alto se
# a API responder com "error".
zbx_api() {
    local method="$1" params="$2" response
    response="$(curl -fsS -X POST "$ZABBIX_API_URL" \
        -H "Content-Type: application/json-rpc" \
        -d "$(jq -n --arg method "$method" --argjson params "$params" --arg auth "$ZABBIX_API_TOKEN" \
            '{jsonrpc: "2.0", method: $method, params: $params, auth: $auth, id: 1}')")"

    if [ "$(echo "$response" | jq -r 'has("error")')" = "true" ]; then
        echo "[ERROR] Zabbix API ($method) falhou: $(echo "$response" | jq -r '.error.data // .error.message')" >&2
        exit 1
    fi

    echo "$response" | jq -c '.result'
}

echo "[INFO] Procurando host group '$CLIENT_NAME'..."
GROUP_ID="$(zbx_api "hostgroup.get" "$(jq -n --arg name "$CLIENT_NAME" '{output: ["groupid"], filter: {name: [$name]}}')" | jq -r '.[0].groupid // empty')"

if [ -z "$GROUP_ID" ]; then
    echo "[INFO] Host group '$CLIENT_NAME' nao existe, criando..."
    GROUP_ID="$(zbx_api "hostgroup.create" "$(jq -n --arg name "$CLIENT_NAME" '{name: $name}')" | jq -r '.groupids[0]')"
fi

echo "[INFO] Procurando template '$TEMPLATE_NAME'..."
TEMPLATE_ID="$(zbx_api "template.get" "$(jq -n --arg host "$TEMPLATE_NAME" '{output: ["templateid"], filter: {host: [$host]}}')" | jq -r '.[0].templateid // empty')"

if [ -z "$TEMPLATE_ID" ]; then
    echo "[ERROR] Template '$TEMPLATE_NAME' nao encontrado no Zabbix Server." >&2
    echo "        Importe devops/zabbix/template_backup_agent.xml primeiro (Data collection > Templates > Import)." >&2
    exit 1
fi

echo "[INFO] Procurando host '$ZABBIX_HOSTNAME'..."
HOST_ID="$(zbx_api "host.get" "$(jq -n --arg host "$ZABBIX_HOSTNAME" '{output: ["hostid"], filter: {host: [$host]}}')" | jq -r '.[0].hostid // empty')"

HOST_PARAMS="$(jq -n \
    --arg host "$ZABBIX_HOSTNAME" \
    --argjson groupid "$GROUP_ID" \
    --argjson templateid "$TEMPLATE_ID" \
    --argjson tls_connect "$TLS_CONNECT" \
    --argjson tls_accept "$TLS_ACCEPT" \
    --arg psk_identity "$PSK_IDENTITY" \
    --arg psk "$PSK_VALUE" \
    '{
        host: $host,
        groups: [{groupid: ($groupid | tostring)}],
        templates: [{templateid: ($templateid | tostring)}],
        tls_connect: $tls_connect,
        tls_accept: $tls_accept
    } + (if $tls_connect == 2 then {tls_psk_identity: $psk_identity, tls_psk: $psk} else {} end)')"

if [ -z "$HOST_ID" ]; then
    echo "[INFO] Host '$ZABBIX_HOSTNAME' nao existe, criando..."
    zbx_api "host.create" "$HOST_PARAMS" > /dev/null
    echo "[SUCCESS] Host '$ZABBIX_HOSTNAME' criado (grupo '$CLIENT_NAME', template '$TEMPLATE_NAME')."
else
    echo "[INFO] Host '$ZABBIX_HOSTNAME' ja existe (hostid=$HOST_ID), atualizando..."
    UPDATE_PARAMS="$(echo "$HOST_PARAMS" | jq --argjson hostid "$HOST_ID" '. + {hostid: ($hostid | tostring)} | del(.host)')"
    zbx_api "host.update" "$UPDATE_PARAMS" > /dev/null
    echo "[SUCCESS] Host '$ZABBIX_HOSTNAME' atualizado (grupo '$CLIENT_NAME', template '$TEMPLATE_NAME')."
fi
