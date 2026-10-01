#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT - BOOTSTRAP / INSTALACAO (Linux)
# Fase 1: sem HashiCorp Vault. TLS do canal Zabbix via PSK estatica.
#
# Distros suportadas:
#   - Debian/Ubuntu (apt)
#   - RHEL/CentOS/Rocky Linux/AlmaLinux (dnf/yum) - habilita EPEL (restic) e
#     o repositorio oficial do Zabbix (zabbix-sender) automaticamente.
#   - Amazon Linux 2/2023 (dnf/yum) - sem EPEL: a AWS nao mantem build do
#     EPEL binario-compativel com o AL2023, e o EPEL7 usado no AL2 esta sem
#     atualizacoes de seguranca desde 06/2024. O restic e instalado via
#     binario oficial do GitHub; o zabbix-sender via repositorio oficial do
#     Zabbix (ha uma pasta amazonlinux/ dedicada em repo.zabbix.com).
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

# Versao do repositorio oficial do Zabbix a habilitar no Debian/Ubuntu e no
# RHEL-family. Mantida em 6.0 para bater com o schema de
# devops/zabbix/template_backup_agent.xml (<version>6.0</version>) - ajuste
# via variavel de ambiente se o Zabbix Server real do cliente for outra
# major version.
ZABBIX_REPO_VERSION="${ZABBIX_REPO_VERSION:-6.0}"

# O Amazon Linux usa uma versao separada: a Zabbix nao publica um pacote de
# conveniencia 'zabbix-release' para Amazon Linux na serie 6.0 (so a arvore
# de pacotes crua, sem instalador), entao usamos a 7.0 so para habilitar o
# repositorio ali. O protocolo trapper do zabbix_sender e compativel com um
# Zabbix Server mais antigo, entao isso e seguro mesmo com servidor em 6.0.
ZABBIX_REPO_VERSION_AMZN="${ZABBIX_REPO_VERSION_AMZN:-7.0}"

# Versao do restic instalada via binario oficial no Amazon Linux (sem EPEL
# binario-compativel - ver prepare_repos() abaixo).
RESTIC_VERSION="${RESTIC_VERSION:-0.17.3}"

DISTRO_FAMILY=""
OS_MAJOR=""
PKG_MGR=""
ARCH=""

detect_os() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    else
        echo "[ERROR] /etc/os-release nao encontrado; distro nao suportada." >&2
        exit 1
    fi

    ARCH="$(uname -m)"

    case "${ID:-}" in
        debian|ubuntu)
            DISTRO_FAMILY="debian"
            ;;
        amzn)
            DISTRO_FAMILY="amzn"
            OS_MAJOR="${VERSION_ID%%.*}"
            ;;
        rhel|centos|rocky|almalinux)
            DISTRO_FAMILY="rhel"
            OS_MAJOR="${VERSION_ID%%.*}"
            ;;
        *)
            case "${ID_LIKE:-}" in
                *rhel*|*fedora*)
                    DISTRO_FAMILY="rhel"
                    OS_MAJOR="${VERSION_ID%%.*}"
                    ;;
                *debian*)
                    DISTRO_FAMILY="debian"
                    ;;
                *)
                    echo "[ERROR] Distro '${ID:-desconhecida}' nao suportada (suportado: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma, Amazon Linux 2/2023)." >&2
                    exit 1
                    ;;
            esac
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    else
        echo "[ERROR] Nenhum gerenciador de pacotes suportado encontrado (apt-get/dnf/yum)." >&2
        exit 1
    fi
}

prepare_repos() {
    case "$DISTRO_FAMILY" in
        debian)
            if ! dpkg -s zabbix-release >/dev/null 2>&1; then
                echo "[INFO] Habilitando repositorio oficial do Zabbix (necessario para 'zabbix-sender')..."
                command -v curl >/dev/null 2>&1 || apt-get install -y curl ca-certificates
                local tmpdeb
                tmpdeb="$(mktemp --suffix=.deb)"
                curl -fsSL -o "$tmpdeb" "https://repo.zabbix.com/zabbix/${ZABBIX_REPO_VERSION}/${ID}/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_REPO_VERSION}+${ID}${VERSION_ID}_all.deb"
                dpkg -i "$tmpdeb"
                rm -f "$tmpdeb"
                apt-get update -y
            fi
            ;;
        rhel)
            if ! rpm -q epel-release >/dev/null 2>&1; then
                echo "[INFO] Habilitando EPEL (necessario para 'restic')..."
                "${PKG_INSTALL[@]}" "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm"
            fi
            if ! rpm -q zabbix-release >/dev/null 2>&1; then
                echo "[INFO] Habilitando repositorio oficial do Zabbix (necessario para 'zabbix-sender')..."
                "${PKG_INSTALL[@]}" "https://repo.zabbix.com/zabbix/${ZABBIX_REPO_VERSION}/rhel/${OS_MAJOR}/${ARCH}/zabbix-release-latest-${ZABBIX_REPO_VERSION}.el${OS_MAJOR}.noarch.rpm"
            fi
            ;;
        amzn)
            if ! rpm -q zabbix-release >/dev/null 2>&1; then
                echo "[INFO] Habilitando repositorio oficial do Zabbix (Amazon Linux ${OS_MAJOR})..."
                "${PKG_INSTALL[@]}" "https://repo.zabbix.com/zabbix/${ZABBIX_REPO_VERSION_AMZN}/amazonlinux/${OS_MAJOR}/${ARCH}/zabbix-release-latest-${ZABBIX_REPO_VERSION_AMZN}.amzn${OS_MAJOR}.noarch.rpm"
            fi
            # Sem EPEL no Amazon Linux (ver cabecalho do script); o restic e
            # instalado via binario oficial em install_restic_binary().
            ;;
    esac
}

install_restic_binary() {
    if command -v restic >/dev/null 2>&1; then
        echo "[INFO] 'restic' ja esta instalado, pulando download do binario oficial."
        return 0
    fi

    local arch_suffix
    case "$ARCH" in
        x86_64)  arch_suffix="amd64" ;;
        aarch64) arch_suffix="arm64" ;;
        *)
            echo "[ERROR] Arquitetura '$ARCH' sem binario oficial do restic." >&2
            exit 1
            ;;
    esac

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    local fname="restic_${RESTIC_VERSION}_linux_${arch_suffix}.bz2"
    local base_url="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}"

    echo "[INFO] Baixando restic ${RESTIC_VERSION} (binario oficial, sem EPEL no Amazon Linux)..."
    curl -fsSL -o "$tmpdir/$fname" "$base_url/$fname"
    curl -fsSL -o "$tmpdir/SHA256SUMS" "$base_url/SHA256SUMS"
    ( cd "$tmpdir" && grep "linux_${arch_suffix}.bz2\$" SHA256SUMS | sha256sum -c - )

    bzip2 -d "$tmpdir/$fname"
    install -m 755 "$tmpdir/restic_${RESTIC_VERSION}_linux_${arch_suffix}" "$INSTALL_BIN/restic"
}

enable_cron_service() {
    local svc="$1"
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        echo "[WARN] systemd nao esta ativo como PID 1 (ambiente container?); habilite o servico '$svc' manualmente." >&2
        return 0
    fi
    systemctl enable --now "$svc" || echo "[WARN] Falha ao habilitar/iniciar o servico '$svc' via systemctl." >&2
}

detect_os
echo "[INFO] Distro detectada: ID=${ID:-?} familia=$DISTRO_FAMILY gerenciador=$PKG_MGR arquitetura=$ARCH"

case "$DISTRO_FAMILY" in
    debian)
        apt-get update -y
        PKG_INSTALL=(apt-get install -y)
        PACKAGES=(restic zabbix-sender curl jq cron openssl)
        ;;
    rhel)
        # --allowerasing (so dnf): imagens minimas RHEL8+/Rocky/Alma trazem
        # 'curl-minimal' pre-instalado, que conflita com o pacote 'curl'
        # completo - sem essa flag o dnf aborta em vez de substituir.
        if [ "$PKG_MGR" = "dnf" ]; then
            PKG_INSTALL=(dnf install -y --allowerasing)
        else
            PKG_INSTALL=(yum install -y)
        fi
        PACKAGES=(restic zabbix-sender curl jq cronie openssl)
        ;;
    amzn)
        if [ "$PKG_MGR" = "dnf" ]; then
            PKG_INSTALL=(dnf install -y --allowerasing)
        else
            PKG_INSTALL=(yum install -y)
        fi
        # util-linux-core: fornece o 'flock' usado pelo backup-agent.sh -
        # nao vem pre-instalado em imagens minimas de Amazon Linux (ao
        # contrario de RHEL/Rocky/Alma/Debian/Ubuntu, onde ja faz parte da
        # base).
        PACKAGES=(zabbix-sender curl jq cronie openssl bzip2 util-linux-core)
        ;;
esac

prepare_repos

echo "[INFO] Instalando dependencias: ${PACKAGES[*]}"
"${PKG_INSTALL[@]}" "${PACKAGES[@]}"

if [ "$DISTRO_FAMILY" = "amzn" ]; then
    install_restic_binary
fi

if [ -t 0 ]; then
    read -rp "Habilitar suporte a Rclone (Google Drive/OneDrive)? [y/N] " ENABLE_RCLONE
else
    ENABLE_RCLONE="N"
    echo "[INFO] Entrada nao interativa detectada; pulando pergunta sobre rclone (instale manualmente depois, se necessario)."
fi
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
install -m 750 "$SCRIPT_DIR/zabbix-register.sh" "$INSTALL_BIN/backup-agent-zabbix-register.sh"

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

# backup-agent - Verificacao de integridade (restic check, so metadados)
# semanal, domingo as 04:30 - fora do horario do pipeline diario para nao
# disputar o lock (flock) com ele.
30 4 * * 0 root /usr/local/bin/backup-agent.sh check > /dev/null 2>&1
EOF
chmod 644 "$CRON_FILE"

case "$DISTRO_FAMILY" in
    debian) enable_cron_service cron ;;
    rhel|amzn) enable_cron_service crond ;;
esac

echo "[SUCCESS] Instalacao concluida."
echo
echo "Proximo passo (recomendado):"
echo "  sudo $INSTALL_BIN/backup-agent.sh setup"
echo
echo "O assistente interativo acima pergunta a configuracao (senha oculta,"
echo "sem aparecer na tela/historico), inicializa os repositorios Restic,"
echo "gera a PSK do Zabbix e, se voce informar ZABBIX_API_URL/token, ja"
echo "cadastra o host no Zabbix Server via API."
echo
echo "Alternativa manual (sem o assistente):"
echo "  1. Edite $CONFIG_DIR/backup.env"
echo "  2. Inicialize o repositorio restic local:  restic -r <REPO_LOCAL> init"
echo "  3. (Opcional) Inicialize o repositorio na nuvem: restic -r <REPO_CLOUD> init"
echo "  4. Se ENABLE_ZABBIX_TLS=true, rode: $INSTALL_BIN/backup-agent-generate-psk.sh"
echo "  5. Cadastre a PSK gerada no host correspondente no Zabbix Server"
