#!/bin/bash
# =========================================================
# Nodo de salida residencial — instalador
# ---------------------------------------------------------
# En un PC o una maquina virtual:
#   curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Node-Gateway/main/setup.sh -o /tmp/nodo.sh && sudo bash /tmp/nodo.sh
#
# En Termux (con o sin root):
#   pkg install -y curl git && curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Node-Gateway/main/setup.sh -o nodo.sh && bash nodo.sh
#
# A diferencia del setup del VPS, este no exige root: sin root
# el nodo funciona igual en modo SOCKS inverso, que es la unica
# via que Android deja abierta sin Magisk.
# =========================================================

set -u

C0="\033[0m"; CY="\033[1;36m"; GR="\033[1;32m"; RD="\033[1;31m"; YL="\033[1;33m"; DM="\033[2;37m"

say()  { echo -e "${YL}[*]${C0} $1"; }
ok()   { echo -e "${GR}[+]${C0} $1"; }
bad()  { echo -e "${RD}[-]${C0} $1"; }

REPO_URL="${NODE_REPO_URL:-https://github.com/Juandocoro/Vpsservice-Node-Gateway.git}"

clear
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
echo -e "   ${CY}NODO DE SALIDA RESIDENCIAL${C0} ${DM}· instalador${C0}"
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
echo ""

# =========================================================
# Donde se instala — depende del aparato
# =========================================================
IS_TERMUX="no"
if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files/usr ] || [ "$(uname -o 2>/dev/null)" = "Android" ]; then
    IS_TERMUX="yes"
    TARGET_DIR="${HOME}/wghome-node"
elif [ "$(id -u)" -eq 0 ]; then
    TARGET_DIR="/opt/wghome-node"
else
    TARGET_DIR="${HOME}/.local/share/wghome-node"
fi

say "Dispositivo: $([ "$IS_TERMUX" = yes ] && echo 'Termux / Android' || echo 'Linux')"
say "Destino: ${TARGET_DIR}"
echo ""

# =========================================================
# Dependencias minimas para llegar al menu
# =========================================================
say "Comprobando dependencias..."
NEED=""
command -v git  &>/dev/null || NEED="$NEED git"
command -v curl &>/dev/null || NEED="$NEED curl"

if [ -n "$NEED" ]; then
    say "Instalando:$NEED"
    if [ "$IS_TERMUX" = "yes" ]; then
        pkg install -y $NEED &>/dev/null
    elif command -v apt-get &>/dev/null; then
        apt-get update -yq &>/dev/null; apt-get install -yq $NEED &>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm $NEED &>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y $NEED &>/dev/null
    elif command -v apk &>/dev/null; then
        apk add $NEED &>/dev/null
    fi
fi

if ! command -v git &>/dev/null; then
    bad "No se pudo instalar git. Abortando."
    exit 1
fi

# =========================================================
# Traer el codigo
# =========================================================
if [ -d "$TARGET_DIR/.git" ]; then
    say "Actualizando instalacion existente..."
    git -C "$TARGET_DIR" pull --ff-only &>/dev/null || {
        say "El pull fallo; se vuelve a clonar."
        rm -rf "$TARGET_DIR"
    }
fi

if [ ! -d "$TARGET_DIR/.git" ]; then
    say "Descargando..."
    rm -rf "$TARGET_DIR"
    mkdir -p "$(dirname "$TARGET_DIR")"
    if ! git clone --depth 1 "$REPO_URL" "$TARGET_DIR" &>/dev/null; then
        bad "No se pudo clonar ${REPO_URL}"
        echo -e "${DM}    Si el repo aun no existe, copia node.sh a mano en ${TARGET_DIR}${C0}"
        exit 1
    fi
fi

chmod +x "$TARGET_DIR"/*.sh 2>/dev/null
ok "Codigo instalado."

# =========================================================
# Comando global 'nodo'
# La configuracion del nodo NO se guarda aqui: vive en
# /etc/wghome-node o $PREFIX/etc/wghome-node, asi que una
# reinstalacion no borra las claves ya registradas en el VPS.
# =========================================================
say "Registrando comando 'nodo'..."
if [ "$IS_TERMUX" = "yes" ]; then
    BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    cat > "${BIN_DIR}/nodo" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec bash ${TARGET_DIR}/node.sh "\$@"
EOF
    chmod +x "${BIN_DIR}/nodo"
elif [ "$(id -u)" -eq 0 ]; then
    cat > /usr/local/bin/nodo <<EOF
#!/bin/bash
exec bash ${TARGET_DIR}/node.sh "\$@"
EOF
    chmod +x /usr/local/bin/nodo
else
    mkdir -p "${HOME}/.local/bin"
    cat > "${HOME}/.local/bin/nodo" <<EOF
#!/bin/bash
exec sudo bash ${TARGET_DIR}/node.sh "\$@"
EOF
    chmod +x "${HOME}/.local/bin/nodo"
    case ":$PATH:" in
        *":${HOME}/.local/bin:"*) ;;
        *) echo -e "${DM}    Añade ~/.local/bin al PATH para usar 'nodo'.${C0}" ;;
    esac
fi
ok "Comando global: ${CY}nodo${C0}"

echo ""
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
ok "Instalacion completada."
echo -e "${DM}    Ejecuta 'nodo' para abrir el panel.${C0}"
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
echo ""
read -r -p "$(echo -e "${DM}")Presiona Enter para abrir el panel...$(echo -e "${C0}")"
exec bash "$TARGET_DIR/node.sh"
