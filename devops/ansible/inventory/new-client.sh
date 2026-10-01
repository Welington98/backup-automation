#!/usr/bin/env bash
# ==============================================================================
# BACKUP AGENT - SCAFFOLD DE NOVO CLIENTE (inventario Ansible multi-cliente)
#
# Automatiza os passos mecanicos de TEMPLATE-NOVO-CLIENTE.md: copiar
# cliente_exemplo/, renomear os arquivos e substituir o nome do cliente em
# todo o conteudo copiado (um unico slug, igual ao que o TEMPLATE-NOVO-
# -CLIENTE.md ja usa pra pasta/grupo/client_name/hosts/item do Vaultwarden -
# o nome "cliente_exemplo", com underscore, e so o nome escolhido pra esse
# exemplo em si, nao uma exigencia do Ansible). Os passos que exigem
# credenciais externas (Vaultwarden, bucket cloud, IPs/hosts reais)
# continuam manuais de proposito - ver o checklist impresso no final.
# ==============================================================================

set -euo pipefail

usage() {
    echo "Uso: $0 <nome-do-cliente> [\"Nome de exibicao do cliente\"]" >&2
    echo "Exemplo: $0 meu-cliente \"Meu Cliente Ltda\"" >&2
    exit 1
}

[ $# -ge 1 ] || usage

SLUG="$1"
DISPLAY_NAME="${2:-$SLUG}"

# kebab-case: letras minusculas, numeros e hifens - mesmo formato usado em
# client_name/hosts/item do Vaultwarden nos exemplos do projeto.
if [[ ! "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "[ERROR] Nome do cliente deve ser kebab-case (letras minusculas, numeros e hifens), ex.: meu-cliente" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/cliente_exemplo"
DEST_DIR="$SCRIPT_DIR/$SLUG"

if [ ! -d "$SRC_DIR" ]; then
    echo "[ERROR] $SRC_DIR nao encontrado (rode este script de dentro de devops/ansible/inventory/)." >&2
    exit 1
fi

if [ -e "$DEST_DIR" ]; then
    echo "[ERROR] $DEST_DIR ja existe." >&2
    exit 1
fi

command -v perl >/dev/null 2>&1 || { echo "[ERROR] 'perl' nao encontrado (necessario pra renomear o conteudo copiado)." >&2; exit 1; }

echo "[INFO] Copiando $SRC_DIR -> $DEST_DIR..."
cp -r "$SRC_DIR" "$DEST_DIR"

mv "$DEST_DIR/group_vars/cliente_exemplo.yml" "$DEST_DIR/group_vars/$SLUG.yml"

echo "[INFO] Substituindo nomes (cliente_exemplo / cliente-exemplo -> $SLUG)..."
while IFS= read -r -d '' f; do
    SLUG="$SLUG" DISPLAY_NAME="$DISPLAY_NAME" \
        perl -pi -e '
            s/cliente_exemplo/$ENV{SLUG}/g;
            s/cliente-exemplo/$ENV{SLUG}/g;
            s/Cliente Exemplo Ltda/$ENV{DISPLAY_NAME}/g;
        ' "$f"
done < <(find "$DEST_DIR" -type f -print0)

echo "[SUCCESS] Pasta $DEST_DIR criada."
echo
echo "Passos que AINDA precisam ser feitos a mao (exigem credenciais"
echo "externas ou dados reais do cliente, nao dao pra automatizar):"
echo
echo "  [ ] Editar $DEST_DIR/hosts.yml com os IPs/hosts reais e o metodo"
echo "      de autenticacao SSH de cada um (senha ou chave)"
echo "  [ ] Editar $DEST_DIR/group_vars/$SLUG.yml com os paths de backup,"
echo "      bucket S3/Wasabi/B2/MinIO e servidor Zabbix reais"
echo "  [ ] Criar o item 'backup-agent - $SLUG' no Vaultwarden com os"
echo "      campos customizados esperados (restic_password,"
echo "      aws_access_key, aws_secret_key, <host>_ssh_password por host"
echo "      com autenticacao por senha)"
echo "  [ ] Atualizar $DEST_DIR/README.md com os dados reais deste cliente"
echo "  [ ] Confirmar que o bucket S3/Wasabi/B2/MinIO do cliente ja existe"
echo
echo "Depois disso, valide e faca o deploy (a partir de devops/ansible/):"
echo
echo "  export BW_SESSION=\$(bw unlock --raw)"
echo "  ansible-inventory -i inventory/$SLUG/hosts.yml --list"
echo "  ansible-playbook -i inventory/$SLUG/hosts.yml playbook.yml --check --diff"
echo
echo "Checklist completo: TEMPLATE-NOVO-CLIENTE.md"
