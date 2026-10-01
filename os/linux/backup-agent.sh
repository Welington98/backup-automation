#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT (Linux) - Fase 1 (sem HashiCorp Vault)
# Arquitetura: Dual-Stage (Local -> Nuvem) + Telemetria Zabbix (TLS via PSK)
# ==============================================================================

# Atualizado automaticamente pelo semantic-release a cada release (nao
# editar a mao - ver .releaserc.json, plugin @semantic-release/exec).
BACKUP_AGENT_VERSION="1.6.0"

CONFIG_DIR="/etc/backup-agent"
BIN_DIR="/usr/local/bin"

# Valores do template (os/linux/backup.env.template) - usados tanto pelo
# wizard 'setup' (pra saber se o backup.env ja foi configurado) quanto pela
# guarda de seguranca mais abaixo (pra recusar rodar com placeholder).
PLACEHOLDER_RESTIC_PASSWORD="TROCAR_SENHA_MESTRE_CRIPTOGRAFIA"
PLACEHOLDER_AWS_ACCESS_KEY_ID="SUA_ACCESS_KEY"
PLACEHOLDER_AWS_SECRET_ACCESS_KEY="SUA_SECRET_KEY"

print_help() {
    cat <<EOF
backup-agent $BACKUP_AGENT_VERSION - backup dual-stage (Restic local -> nuvem) com telemetria Zabbix

Uso:
  backup-agent.sh                    Executa o pipeline completo de backup
  backup-agent.sh setup              Assistente interativo de configuracao inicial
  backup-agent.sh list               Lista os snapshots existentes (local e nuvem)
  backup-agent.sh files [opcoes]     Lista os arquivos dentro de um snapshot
  backup-agent.sh restore [opcoes]   Restaura um snapshot (ou parte dele) para um diretorio
  backup-agent.sh check [opcoes]     Verifica a integridade dos repositorios (restic check)
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

Opcoes de 'check':
  --read-data          Verifica tambem o conteudo dos pack files (lento, le o repositorio
                        inteiro). Sem essa opcao, so a estrutura/metadados sao verificados.

Exemplos:
  backup-agent.sh setup
  backup-agent.sh files
  backup-agent.sh files --cloud --snapshot a1b2c3d4
  backup-agent.sh restore --target /tmp/restauracao
  backup-agent.sh restore --target /tmp/restauracao --include /etc/backup-agent
  backup-agent.sh check
  backup-agent.sh check --read-data

Pipeline completo (sem argumentos):
  1. Backup local                (restic backup)
  2. Sincronizacao com a nuvem    (restic copy), se ENABLE_CLOUD_SYNC=true
  3. Retencao / expurgo           (restic forget --prune), local e nuvem
  4. Metricas para o Zabbix       (tamanho e snapshots, local e nuvem)

'check' e uma verificacao de integridade (restic check) separada do pipeline
diario - roda sob demanda ou por um cron proprio (ver docs/deployment.md e
docs/zabbix-monitoring.md), pois --read-data le o repositorio inteiro e pode
ser lento/custoso (egress na nuvem).

'setup' e o caminho recomendado pra primeira configuracao (apos o
install.sh): pergunta os campos de backup.env de forma interativa (senha
oculta, sem aparecer na tela/historico), inicializa os repositorios Restic,
gera a PSK do Zabbix e, se ZABBIX_API_URL/ZABBIX_API_TOKEN forem informados,
ja cadastra o host no Zabbix Server via API.

Configuracao: /etc/backup-agent/backup.env
Log:          \${LOG_PATH:-/var/log/backup-agent.log}

Documentacao: docs/deployment.md, docs/zabbix-monitoring.md e
docs/disaster-recovery.md no repositorio backup-automation.
EOF
}

# Wizard interativo de primeira configuracao - roda ANTES do source do
# ENV_FILE (logo abaixo) de proposito: na primeira execucao, apos o
# install.sh, o backup.env so tem os placeholders do template, e e
# exatamente isso que o setup substitui.
cmd_setup() {
    if [ "$EUID" -ne 0 ]; then
        echo "[ERROR] Execute como root." >&2
        return 1
    fi

    local env_file="$CONFIG_DIR/backup.env"
    if [ ! -f "$env_file" ]; then
        echo "[ERROR] $env_file nao encontrado. Rode primeiro: sudo os/linux/install.sh" >&2
        return 1
    fi

    local current_password=""
    set -o allexport
    # shellcheck disable=SC1090
    source "$env_file"
    set +o allexport
    current_password="${RESTIC_PASSWORD:-}"

    if [ -n "$current_password" ] && [ "$current_password" != "$PLACEHOLDER_RESTIC_PASSWORD" ]; then
        echo "[WARN] $env_file ja parece configurado (RESTIC_PASSWORD nao e mais o placeholder)."
        local overwrite
        read -rp "Sobrescrever a configuracao atual? [y/N] " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "[INFO] Cancelado. Nenhuma alteracao feita."
            return 0
        fi
    fi

    echo "=== backup-agent setup - configuracao inicial ==="
    echo

    local backup_paths repo_local keep_local_daily
    read -rp "Diretorios a salvar (separados por virgula) [/var/univention-backup,/home,/etc]: " backup_paths
    backup_paths="${backup_paths:-/var/univention-backup,/home,/etc}"

    read -rp "Repositorio Restic local [/mnt/backup-local/restic-repo]: " repo_local
    repo_local="${repo_local:-/mnt/backup-local/restic-repo}"

    read -rp "Dias de retencao local (KEEP_LOCAL_DAILY) [7]: " keep_local_daily
    keep_local_daily="${keep_local_daily:-7}"

    mkdir -p "$repo_local"
    chmod 700 "$repo_local"

    local gen_password restic_password
    read -rp "Gerar RESTIC_PASSWORD automaticamente (openssl rand)? [Y/n] " gen_password
    if [[ "$gen_password" =~ ^[Nn]$ ]]; then
        local restic_password_confirm
        while true; do
            read -rsp "RESTIC_PASSWORD: " restic_password; echo
            read -rsp "Confirme RESTIC_PASSWORD: " restic_password_confirm; echo
            if [ -n "$restic_password" ] && [ "$restic_password" = "$restic_password_confirm" ]; then
                break
            fi
            echo "[ERROR] Senhas nao batem ou estao vazias, tente de novo." >&2
        done
    else
        restic_password="$(openssl rand -base64 32)"
    fi

    echo
    echo "[IMPORTANTE] RESTIC_PASSWORD (guarde AGORA em um gestor de senhas"
    echo "fora deste servidor - nao ha 'esqueci a senha', perder esta senha"
    echo "torna os backups permanentemente irrecuperaveis):"
    echo
    echo "    $restic_password"
    echo
    local _confirm_saved
    read -rp "Pressione Enter apos salvar a senha em lugar seguro para continuar... " _confirm_saved

    local enable_cloud="false" repo_cloud="" aws_access_key="" aws_secret_key=""
    local keep_cloud_daily=7 keep_cloud_weekly=4 keep_cloud_monthly=12
    local cloud_reply
    read -rp "Habilitar sincronizacao em nuvem (ENABLE_CLOUD_SYNC)? [y/N] " cloud_reply
    if [[ "$cloud_reply" =~ ^[Yy]$ ]]; then
        enable_cloud="true"
        read -rp "REPO_CLOUD (ex.: s3:s3.amazonaws.com/bucket/caminho): " repo_cloud
        read -rp "AWS_ACCESS_KEY_ID: " aws_access_key
        read -rsp "AWS_SECRET_ACCESS_KEY: " aws_secret_key; echo
        read -rp "Dias de retencao em nuvem (KEEP_CLOUD_DAILY) [7]: " keep_cloud_daily
        keep_cloud_daily="${keep_cloud_daily:-7}"
        read -rp "Semanas de retencao em nuvem (KEEP_CLOUD_WEEKLY) [4]: " keep_cloud_weekly
        keep_cloud_weekly="${keep_cloud_weekly:-4}"
        read -rp "Meses de retencao em nuvem (KEEP_CLOUD_MONTHLY) [12]: " keep_cloud_monthly
        keep_cloud_monthly="${keep_cloud_monthly:-12}"
    fi

    local default_hostname
    default_hostname="$(hostname -f 2>/dev/null || hostname)"
    local enable_zabbix="false" zabbix_server="" zabbix_port=10051
    local zabbix_hostname="$default_hostname" client_name=""
    local enable_zabbix_tls="false" zabbix_api_url="" zabbix_api_token=""
    local zabbix_reply
    read -rp "Habilitar monitoramento Zabbix (ENABLE_ZABBIX)? [Y/n] " zabbix_reply
    zabbix_reply="${zabbix_reply:-Y}"
    if [[ "$zabbix_reply" =~ ^[Yy]$ ]]; then
        enable_zabbix="true"
        read -rp "ZABBIX_SERVER (FQDN/IP): " zabbix_server
        read -rp "ZABBIX_PORT [10051]: " zabbix_port
        zabbix_port="${zabbix_port:-10051}"
        local zh_reply
        read -rp "ZABBIX_HOSTNAME [$default_hostname]: " zh_reply
        zabbix_hostname="${zh_reply:-$default_hostname}"
        read -rp "Nome do cliente/host group (CLIENT_NAME): " client_name

        local tls_reply
        read -rp "Habilitar TLS via PSK (ENABLE_ZABBIX_TLS)? [Y/n] " tls_reply
        tls_reply="${tls_reply:-Y}"
        if [[ "$tls_reply" =~ ^[Yy]$ ]]; then
            enable_zabbix_tls="true"
            read -rp "Cadastrar o host automaticamente via API do Zabbix? URL da API (Enter para pular, ex.: https://zabbix.suaempresa.com/api_jsonrpc.php): " zabbix_api_url
            if [ -n "$zabbix_api_url" ]; then
                read -rsp "Zabbix API token: " zabbix_api_token; echo
            fi
        fi
    fi

    echo "[INFO] Gravando $env_file..."
    cat > "$env_file" <<ENVEOF
# ==============================================================================
# BACKUP AGENT - ENVIRONMENT CONFIGURATION (gerado por backup-agent.sh setup)
# ==============================================================================

RESTIC_PASSWORD="$restic_password"

BACKUP_TARGET_PATHS="$backup_paths"
BACKUP_TAG="${client_name:+${client_name}-}daily"
EXCLUDE_FILE="$CONFIG_DIR/excludes.txt"

REPO_LOCAL="$repo_local"
KEEP_LOCAL_DAILY=$keep_local_daily

ENABLE_CLOUD_SYNC="$enable_cloud"
REPO_CLOUD="$repo_cloud"
AWS_ACCESS_KEY_ID="$aws_access_key"
AWS_SECRET_ACCESS_KEY="$aws_secret_key"

KEEP_CLOUD_DAILY=$keep_cloud_daily
KEEP_CLOUD_WEEKLY=$keep_cloud_weekly
KEEP_CLOUD_MONTHLY=$keep_cloud_monthly

CLIENT_NAME="$client_name"

ENABLE_ZABBIX="$enable_zabbix"
ZABBIX_SERVER="$zabbix_server"
ZABBIX_PORT=$zabbix_port
ZABBIX_HOSTNAME="$zabbix_hostname"

ENABLE_ZABBIX_TLS="$enable_zabbix_tls"
ZABBIX_TLS_PSK_IDENTITY="backup-agent:$zabbix_hostname"
ZABBIX_TLS_PSK_FILE="$CONFIG_DIR/certs/zabbix.psk"

ZABBIX_API_URL="$zabbix_api_url"
ZABBIX_API_TOKEN="$zabbix_api_token"
ENVEOF
    chmod 600 "$env_file"

    echo "[INFO] Inicializando repositorio Restic local ($repo_local)..."
    if RESTIC_PASSWORD="$restic_password" restic -r "$repo_local" cat config >/dev/null 2>&1; then
        echo "[INFO] Repositorio local ja inicializado, pulando."
    else
        RESTIC_PASSWORD="$restic_password" restic -r "$repo_local" init
    fi

    if [ "$enable_cloud" = "true" ] && [ -n "$repo_cloud" ]; then
        echo "[INFO] Inicializando repositorio Restic em nuvem ($repo_cloud)..."
        if AWS_ACCESS_KEY_ID="$aws_access_key" AWS_SECRET_ACCESS_KEY="$aws_secret_key" \
           RESTIC_PASSWORD="$restic_password" restic -r "$repo_cloud" cat config >/dev/null 2>&1; then
            echo "[INFO] Repositorio em nuvem ja inicializado, pulando."
        else
            AWS_ACCESS_KEY_ID="$aws_access_key" AWS_SECRET_ACCESS_KEY="$aws_secret_key" \
                RESTIC_PASSWORD="$restic_password" restic -r "$repo_cloud" init
        fi
    fi

    if [ "$enable_zabbix_tls" = "true" ]; then
        echo "[INFO] Gerando PSK do Zabbix..."
        "$BIN_DIR/backup-agent-generate-psk.sh"
    fi

    if [ "$enable_zabbix" = "true" ]; then
        if [ -n "$zabbix_api_url" ] && [ -n "$zabbix_api_token" ]; then
            echo "[INFO] Cadastrando host no Zabbix Server via API..."
            "$BIN_DIR/backup-agent-zabbix-register.sh"
        else
            echo
            echo "[INFO] Cadastro automatico nao configurado. Cadastre manualmente:"
            echo "  1. Data collection > Templates > Import -> devops/zabbix/template_backup_agent.xml"
            echo "  2. Data collection > Hosts > Create host:"
            echo "       Host name:  $zabbix_hostname"
            echo "       Host group: $client_name"
            echo "       Template:   Backup Agent"
            if [ "$enable_zabbix_tls" = "true" ]; then
                echo "  3. Aba Encryption > PSK: use a identity/value impressos acima"
            fi
            echo "  Detalhes: docs/zabbix-monitoring.md"
        fi
    fi

    echo
    echo "[SUCCESS] Configuracao inicial concluida."
    echo "Proximo passo: sudo backup-agent.sh   (roda o pipeline completo pela primeira vez)"
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
    setup)
        cmd_setup
        exit $?
        ;;
esac

set -o pipefail

ENV_FILE="$CONFIG_DIR/backup.env"
if [ -f "$ENV_FILE" ]; then
    # Caminho so existe no host de destino, nao no repo.
    set -o allexport
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +o allexport
else
    echo "CRITICAL: Arquivo de configuracao $ENV_FILE nao encontrado!"
    exit 1
fi

# Recusa rodar com os placeholders do template (os/linux/backup.env.template)
# - sem isso, um backup.env nunca editado roda "com sucesso" criptografando
# com uma senha publica/conhecida, ou falha tarde (tentando autenticar na
# nuvem com uma chave que nao existe). Espelha o assert equivalente do lado
# Ansible (devops/ansible/roles/backup_agent/tasks/main.yml).
if [ "${RESTIC_PASSWORD:-}" = "$PLACEHOLDER_RESTIC_PASSWORD" ]; then
    echo "CRITICAL: RESTIC_PASSWORD ainda esta com o valor padrao do template. Rode: backup-agent.sh setup"
    exit 1
fi

if [ "${ENABLE_CLOUD_SYNC:-false}" = "true" ] && { [ "${AWS_ACCESS_KEY_ID:-}" = "$PLACEHOLDER_AWS_ACCESS_KEY_ID" ] || [ "${AWS_SECRET_ACCESS_KEY:-}" = "$PLACEHOLDER_AWS_SECRET_ACCESS_KEY" ]; }; then
    echo "CRITICAL: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY ainda estao com o valor padrao do template. Rode: backup-agent.sh setup"
    exit 1
fi

LOG_FILE="${LOG_PATH:-/var/log/backup-agent.log}"
LOCK_FILE="${LOCK_PATH:-/var/lock/backup-agent.lock}"

# Impede duas execucoes simultaneas do pipeline e/ou do 'check' no mesmo
# host (ex.: cron do pipeline em cima do cron do check, ou duas chamadas
# manuais em paralelo) - evita que o Restic rejeite uma das duas no meio de
# um forget/prune ou check com "repository is already locked".
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Outra execucao do backup-agent.sh ja esta em andamento (lock $LOCK_FILE). Abortando." >> "$LOG_FILE"
        exit 1
    fi
}

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

    check)
        shift
        CHECK_ARGS=()

        while [ $# -gt 0 ]; do
            case "$1" in
                --read-data) CHECK_ARGS+=(--read-data); shift ;;
                *)
                    echo "[ERROR] Opcao desconhecida para 'check': $1" >&2
                    echo "Uso: backup-agent.sh check [--read-data]" >&2
                    exit 1
                    ;;
            esac
        done

        acquire_lock

        CHECK_START=$(date +%s)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] === INICIANDO VERIFICACAO DE INTEGRIDADE (restic check) ===" >> "$LOG_FILE"

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CHECK] Verificando repositorio local ($REPO_LOCAL)..." >> "$LOG_FILE"
        restic -r "$REPO_LOCAL" check "${CHECK_ARGS[@]}" >> "$LOG_FILE" 2>&1
        LOCAL_CHECK_STATUS=$?

        if [ $LOCAL_CHECK_STATUS -eq 0 ]; then
            send_zabbix "restic.check.local.status" 1
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] restic check encontrou problemas no repositorio local." >> "$LOG_FILE"
            send_zabbix "restic.check.local.status" 0
        fi

        OVERALL_CHECK_STATUS=$LOCAL_CHECK_STATUS

        if [ "$ENABLE_CLOUD_SYNC" = "true" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CHECK] Verificando repositorio em nuvem ($REPO_CLOUD)..." >> "$LOG_FILE"
            restic -r "$REPO_CLOUD" check "${CHECK_ARGS[@]}" >> "$LOG_FILE" 2>&1
            CLOUD_CHECK_STATUS=$?

            if [ $CLOUD_CHECK_STATUS -eq 0 ]; then
                send_zabbix "restic.check.cloud.status" 1
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] restic check encontrou problemas no repositorio em nuvem." >> "$LOG_FILE"
                send_zabbix "restic.check.cloud.status" 0
                OVERALL_CHECK_STATUS=$CLOUD_CHECK_STATUS
            fi
        fi

        CHECK_END=$(date +%s)
        send_zabbix "restic.check.duration" "$((CHECK_END - CHECK_START))"

        if [ $OVERALL_CHECK_STATUS -eq 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] Verificacao de integridade concluida sem erros." >> "$LOG_FILE"
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] === VERIFICACAO FINALIZADA ===" >> "$LOG_FILE"

        exit $OVERALL_CHECK_STATUS
        ;;

    "") ;; # sem comando -> roda o pipeline completo abaixo

    *)
        echo "[ERROR] Comando desconhecido: $1" >&2
        echo "" >&2
        print_help >&2
        exit 1
        ;;
esac

START_TIME=$(date +%s)

acquire_lock

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
