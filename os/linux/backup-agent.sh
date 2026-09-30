#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT v1.0.0 (Linux) - Fase 1 (sem HashiCorp Vault)
# Arquitetura: Dual-Stage (Local -> Nuvem) + Telemetria Zabbix (TLS via PSK)
# ==============================================================================

set -o pipefail

ENV_FILE="/etc/backup-agent/backup.env"
if [ -f "$ENV_FILE" ]; then
    set -o allexport; source "$ENV_FILE"; set +o allexport
else
    echo "CRITICAL: Arquivo de configuracao $ENV_FILE nao encontrado!"
    exit 1
fi

LOG_FILE="${LOG_PATH:-/var/log/backup-agent.log}"
START_TIME=$(date +%s)

# Impede duas execucoes simultaneas (ex.: teste manual em cima do cron, ou
# duas chamadas manuais em paralelo) - evita que o Restic rejeite a segunda
# instancia no meio de um forget/prune com "repository is already locked".
LOCK_FILE="${LOCK_PATH:-/var/lock/backup-agent.lock}"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Outra execucao do backup-agent.sh ja esta em andamento (lock $LOCK_FILE). Abortando." >> "$LOG_FILE"
    exit 1
fi

# Funcao para telemetria Zabbix Trapper
send_zabbix() {
    local key="$1"
    local val="$2"

    if [ "$ENABLE_ZABBIX" = "true" ] && [ -n "$ZABBIX_SERVER" ]; then
        local tls_args=()

        if [ "$ENABLE_ZABBIX_TLS" = "true" ]; then
            tls_args=(--tls-connect psk
                      --tls-psk-identity "$ZABBIX_TLS_PSK_IDENTITY"
                      --tls-psk-file "$ZABBIX_TLS_PSK_FILE")
        fi

        zabbix_sender -z "$ZABBIX_SERVER" \
                      -p "${ZABBIX_PORT:-10051}" \
                      -s "$ZABBIX_HOSTNAME" \
                      -k "$key" \
                      -o "$val" \
                      "${tls_args[@]}" > /dev/null 2>&1
    fi
}

# Reporta tamanho e quantidade de snapshots de um repositorio (local ou
# nuvem, identificados pelo sufixo) via restic.repo.size.<sufixo> e
# restic.repo.snapshots.<sufixo>
report_repo_metrics() {
    local repo="$1"
    local suffix="$2"

    local stats_json total_size snapshot_count
    stats_json=$(restic -r "$repo" stats --json 2>/dev/null)
    total_size=$(echo "$stats_json" | jq -r '.total_size // empty')
    snapshot_count=$(restic -r "$repo" snapshots --json 2>/dev/null | jq -r 'length')

    [ -n "$total_size" ] && send_zabbix "restic.repo.size.${suffix}" "$total_size"
    [ -n "$snapshot_count" ] && send_zabbix "restic.repo.snapshots.${suffix}" "$snapshot_count"
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === INICIANDO AGENTE DE BACKUP ===" >> "$LOG_FILE"

# ------------------------------------------------------------------------------
# ETAPA 1: BACKUP LOCAL (SNAPSHOT)
# ------------------------------------------------------------------------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STAGE 1] Executando backup local..." >> "$LOG_FILE"

IFS=',' read -ra PATHS <<< "$BACKUP_TARGET_PATHS"

restic -r "$REPO_LOCAL" backup \
    "${PATHS[@]}" \
    --exclude-file="${EXCLUDE_FILE}" \
    --tag "${BACKUP_TAG:-daily-auto}" >> "$LOG_FILE" 2>&1

LOCAL_STATUS=$?

if [ $LOCAL_STATUS -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Falha no backup local." >> "$LOG_FILE"
    send_zabbix "restic.backup.status" 0
    exit 1
fi

# ------------------------------------------------------------------------------
# ETAPA 2: COPIAR SNAPSHOT LOCAL PARA NUVEM (S3/GDRIVE/B2)
# ------------------------------------------------------------------------------
if [ "$ENABLE_CLOUD_SYNC" = "true" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STAGE 2] Sincronizando com repositorio em nuvem..." >> "$LOG_FILE"

    restic -r "$REPO_LOCAL" copy --repo2 "$REPO_CLOUD" >> "$LOG_FILE" 2>&1
    CLOUD_STATUS=$?
else
    CLOUD_STATUS=0
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $CLOUD_STATUS -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] Backup e sincronizacao concluidos." >> "$LOG_FILE"
    send_zabbix "restic.backup.status" 1
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Falha na sincronizacao com a nuvem." >> "$LOG_FILE"
    send_zabbix "restic.backup.status" 0
fi

send_zabbix "restic.backup.duration" "$DURATION"

# ------------------------------------------------------------------------------
# ETAPA 3: RETENCAO / EXPURGO (PRUNE)
# ------------------------------------------------------------------------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STAGE 3] Aplicando politicas de retencao..." >> "$LOG_FILE"

# Retencao Local (Curto Prazo)
restic -r "$REPO_LOCAL" forget \
    --keep-daily "${KEEP_LOCAL_DAILY:-7}" \
    --prune >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Falha na retencao local (forget/prune)." >> "$LOG_FILE"
    send_zabbix "restic.retention.local.status" 0
else
    send_zabbix "restic.retention.local.status" 1
fi

# Retencao Nuvem (Longo Prazo)
if [ "$ENABLE_CLOUD_SYNC" = "true" ]; then
    restic -r "$REPO_CLOUD" forget \
        --keep-daily "${KEEP_CLOUD_DAILY:-7}" \
        --keep-weekly "${KEEP_CLOUD_WEEKLY:-4}" \
        --keep-monthly "${KEEP_CLOUD_MONTHLY:-12}" \
        --prune >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Falha na retencao em nuvem (forget/prune)." >> "$LOG_FILE"
        send_zabbix "restic.retention.cloud.status" 0
    else
        send_zabbix "restic.retention.cloud.status" 1
    fi
fi

# ------------------------------------------------------------------------------
# ETAPA 4: METRICAS E ESTATISTICAS
# ------------------------------------------------------------------------------
report_repo_metrics "$REPO_LOCAL" "local"

if [ "$ENABLE_CLOUD_SYNC" = "true" ]; then
    report_repo_metrics "$REPO_CLOUD" "cloud"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === EXECUCAO FINALIZADA ===" >> "$LOG_FILE"
