#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT (Linux) - Fase 1 (sem HashiCorp Vault)
# Arquitetura: Dual-Stage (Local -> Nuvem) + Telemetria Zabbix (TLS via PSK)
# ==============================================================================

# Atualizado automaticamente pelo semantic-release a cada release (nao
# editar a mao - ver .releaserc.json, plugin @semantic-release/exec).
BACKUP_AGENT_VERSION="1.2.0"

print_help() {
    cat <<EOF
backup-agent $BACKUP_AGENT_VERSION - backup dual-stage (Restic local -> nuvem) com telemetria Zabbix

Uso:
  backup-agent.sh                    Executa o pipeline completo de backup
  backup-agent.sh list               Lista os snapshots existentes (local e nuvem)
  backup-agent.sh files [opcoes]     Lista os arquivos dentro de um snapshot
  backup-agent.sh restore [opcoes]   Restaura um snapshot (ou parte dele) para um diretorio
  backup-agent.sh --version          Mostra a versao instalada e sai
  backup-agent.sh --help             Mostra esta ajuda e sai

Opcoes de 'files':
  --cloud              Usa o repositorio em nuvem em vez do local (requer ENABLE_CLOUD_SYNC=true)
  --snapshot <id>      Snapshot a inspecionar (padrao: latest)

Opcoes de 'restore' (--target e obrigatorio):
  --target <dir>       Diretorio de destino da restauracao (obrigatorio)
  --cloud              Usa o repositorio em nuvem em vez do local (requer ENABLE_CLOUD_SYNC=true)
  --snapshot <id>      Snapshot a restaurar (padrao: latest)
  --include <padrao>   Restaura so os caminhos que casam com o padrao, em vez do snapshot inteiro

Exemplos:
  backup-agent.sh files
  backup-agent.sh files --cloud --snapshot a1b2c3d4
  backup-agent.sh restore --target /tmp/restauracao
  backup-agent.sh restore --target /tmp/restauracao --include /etc/backup-agent

Pipeline completo (sem argumentos):
  1. Backup local                (restic backup)
  2. Sincronizacao com a nuvem    (restic copy), se ENABLE_CLOUD_SYNC=true
  3. Retencao / expurgo           (restic forget --prune), local e nuvem
  4. Metricas para o Zabbix       (tamanho e snapshots, local e nuvem)

Configuracao: /etc/backup-agent/backup.env
Log:          \${LOG_PATH:-/var/log/backup-agent.log}

Documentacao: docs/deployment.md, docs/zabbix-monitoring.md e
docs/disaster-recovery.md no repositorio backup-automation.
EOF
}

case "${1:-}" in
    --version|-v)
        echo "backup-agent $BACKUP_AGENT_VERSION"
        exit 0
        ;;
    --help|-h)
        print_help
        exit 0
        ;;
esac

set -o pipefail

ENV_FILE="/etc/backup-agent/backup.env"
if [ -f "$ENV_FILE" ]; then
    set -o allexport; source "$ENV_FILE"; set +o allexport
else
    echo "CRITICAL: Arquivo de configuracao $ENV_FILE nao encontrado!"
    exit 1
fi

# Comandos de exploracao/restauracao (list, files, restore) sao so leitura
# no repositorio Restic (restore so escreve no --target escolhido, nunca no
# repositorio) - por isso nao usam o lock nem escrevem no log, e podem
# rodar a qualquer momento mesmo com um backup em andamento.
case "${1:-}" in
    list)
        echo "=== Snapshots - Repositorio Local ($REPO_LOCAL) ==="
        restic -r "$REPO_LOCAL" snapshots

        if [ "$ENABLE_CLOUD_SYNC" = "true" ]; then
            echo ""
            echo "=== Snapshots - Repositorio Nuvem ($REPO_CLOUD) ==="
            restic -r "$REPO_CLOUD" snapshots
        fi
        exit 0
        ;;

    files)
        shift
        TARGET_REPO="$REPO_LOCAL"
        SNAPSHOT="latest"

        while [ $# -gt 0 ]; do
            case "$1" in
                --cloud)
                    if [ "$ENABLE_CLOUD_SYNC" != "true" ]; then
                        echo "[ERROR] --cloud requer ENABLE_CLOUD_SYNC=\"true\" em $ENV_FILE." >&2
                        exit 1
                    fi
                    TARGET_REPO="$REPO_CLOUD"
                    shift
                    ;;
                --snapshot) SNAPSHOT="${2:?--snapshot precisa de um ID}"; shift 2 ;;
                *)
                    echo "[ERROR] Opcao desconhecida para 'files': $1" >&2
                    echo "Uso: backup-agent.sh files [--cloud] [--snapshot <id>]" >&2
                    exit 1
                    ;;
            esac
        done

        restic -r "$TARGET_REPO" ls "$SNAPSHOT"
        exit $?
        ;;

    restore)
        shift
        TARGET_REPO="$REPO_LOCAL"
        SNAPSHOT="latest"
        RESTORE_TARGET=""
        INCLUDE=""

        while [ $# -gt 0 ]; do
            case "$1" in
                --target) RESTORE_TARGET="${2:?--target precisa de um diretorio de destino}"; shift 2 ;;
                --cloud)
                    if [ "$ENABLE_CLOUD_SYNC" != "true" ]; then
                        echo "[ERROR] --cloud requer ENABLE_CLOUD_SYNC=\"true\" em $ENV_FILE." >&2
                        exit 1
                    fi
                    TARGET_REPO="$REPO_CLOUD"
                    shift
                    ;;
                --snapshot) SNAPSHOT="${2:?--snapshot precisa de um ID}"; shift 2 ;;
                --include) INCLUDE="${2:?--include precisa de um padrao}"; shift 2 ;;
                *)
                    echo "[ERROR] Opcao desconhecida para 'restore': $1" >&2
                    echo "Uso: backup-agent.sh restore --target <diretorio> [--cloud] [--snapshot <id>] [--include <padrao>]" >&2
                    exit 1
                    ;;
            esac
        done

        if [ -z "$RESTORE_TARGET" ]; then
            echo "[ERROR] restore precisa de --target <diretorio>" >&2
            echo "Uso: backup-agent.sh restore --target <diretorio> [--cloud] [--snapshot <id>] [--include <padrao>]" >&2
            exit 1
        fi

        RESTORE_ARGS=(-r "$TARGET_REPO" restore "$SNAPSHOT" --target "$RESTORE_TARGET")
        [ -n "$INCLUDE" ] && RESTORE_ARGS+=(--include "$INCLUDE")

        restic "${RESTORE_ARGS[@]}"
        exit $?
        ;;

    "") ;; # sem comando -> roda o pipeline completo abaixo

    *)
        echo "[ERROR] Comando desconhecido: $1" >&2
        echo "" >&2
        print_help >&2
        exit 1
        ;;
esac

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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === INICIANDO AGENTE DE BACKUP v$BACKUP_AGENT_VERSION ===" >> "$LOG_FILE"

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

    # RESTIC_FROM_PASSWORD e a senha do repositorio de origem (--from-repo).
    # Como local e nuvem usam a mesma RESTIC_PASSWORD (senha mestre unica,
    # ver backup.env.template), reaproveitamos o mesmo valor - sem isso o
    # restic tenta pedir a senha de forma interativa e falha em
    # background/cron com "unable to read password".
    RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" \
        restic -r "$REPO_CLOUD" copy --from-repo "$REPO_LOCAL" >> "$LOG_FILE" 2>&1
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
