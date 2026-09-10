#!/usr/bin/env bash
# =========================================================
# NODO DE SALIDA RESIDENCIAL — Contraparte de Vpsservice-Bash-Free
# ---------------------------------------------------------
# Este script se instala en el dispositivo que presta su IP
# residencial (el "nodo"). El VPS ya trae el otro extremo en
# modules/installers/wg_home.sh: alli se levanta el servidor
# WireGuard 10.77.77.1 y el policy routing por UID. Aqui vive
# el peer 10.77.77.2 que hace de puerta hacia Internet.
#
#   VPS (10.77.77.1)  ──wg-home──▶  NODO (10.77.77.2)  ──▶  ISP casa
#
# Dos modos de operacion, elegidos segun lo que el aparato permita:
#
#   A · WIREGUARD  (requiere root)
#       Interfaz wg-home real + ip_forward + MASQUERADE.
#       Transporta TCP, UDP e ICMP. Es el modo espejo exacto
#       de lo que el VPS espera en wg_home.sh.
#
#   B · SOCKS INVERSO (sin root)
#       ssh -R <puerto> hacia el VPS. OpenSSH >= 7.6 publica un
#       SOCKS5 en el VPS cuya salida es este dispositivo. Sirve
#       cuando el aparato no puede crear un TUN (Termux sin root).
#       Solo TCP: SSH no transporta datagramas UDP.
# =========================================================

# =========================================================
# LENGUAJE VISUAL — copia reducida de modules/ui.sh del panel
# Se vendoriza en vez de hacer source para que el script sea un
# unico archivo: en un telefono se instala con un solo curl.
# =========================================================

if ! locale charmap 2>/dev/null | grep -qi "utf-\?8"; then
    if locale -a 2>/dev/null | grep -qix "C.UTF-8"; then
        export LC_ALL=C.UTF-8 LANG=C.UTF-8
    elif locale -a 2>/dev/null | grep -qix "en_US.utf8"; then
        export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    fi
fi

CR="\033[0m"; BD="\033[1m"; DM="\033[2;37m"
RD="\033[1;31m"; GR="\033[1;32m"; YL="\033[1;33m"
BL="\033[1;34m"; MG="\033[1;35m"; CY="\033[1;36m"; WH="\033[1;37m"

UI_W=64
UI_PAD="  "

ui_line() {
    local color="${1:-$YL}" ch="${2:-━}" out="" i=0
    while [ $i -lt $UI_W ]; do out="${out}${ch}"; i=$((i+1)); done
    echo -e "${color}${out}${CR}"
}
ui_rule()  { ui_line "$DM" "─"; }
ui_solid() { ui_line "$YL" "━"; }
ui_blank() { echo ""; }

ui_header() {
    local ver="${1:-}" name="N O D O   D E   S A L I D A"
    ui_solid
    printf "%b   %b►►►%b  %b%s%b  %b◄◄◄%b" "$CR" "$MG" "$CR" "$WH$BD" "$name" "$CR" "$MG" "$CR"
    if [ -n "$ver" ]; then
        local plain_len=$(( 3 + 3 + 2 + ${#name} + 2 + 3 ))
        local tag="[ $ver ]"
        local pad=$(( UI_W - plain_len - ${#tag} ))
        [ $pad -lt 1 ] && pad=1
        printf "%*s%b%s%b" "$pad" "" "$CY" "$tag" "$CR"
    fi
    echo ""
    ui_solid
}

ui_section() {
    local title="$1" sub="${2:-}"
    local pad=$(( (UI_W - ${#title}) / 2 ))
    [ $pad -lt 0 ] && pad=0
    printf "%*s%b%s%b\n" "$pad" "" "$WH$BD" "$title" "$CR"
    [ -n "$sub" ] && { pad=$(( (UI_W - ${#sub}) / 2 )); [ $pad -lt 0 ] && pad=0
                       printf "%*s%b%s%b\n" "$pad" "" "$DM" "$sub" "$CR"; }
    ui_solid
}

ui_cell() {
    local label="$1" value="${2:-N/A}" width="${3:-20}" vc="${4:-$WH}"
    local plain="${label}: ${value}"
    local pad=$(( width - ${#plain} ))
    [ $pad -lt 0 ] && pad=0
    printf "%b%s:%b %b%s%b%*s" "$DM" "$label" "$CR" "$vc" "$value" "$CR" "$pad" ""
}

ui_row2() {
    local w=$(( (UI_W - 2) / 2 ))
    echo -e "${UI_PAD}$(ui_cell "$1" "$2" $w)${DM}▸${CR} $(ui_cell "$3" "$4" $w)"
}

ui_tag_str() { [ "$1" = "on" ] && echo -e "${GR}[ ON  ]${CR}" || echo -e "${RD}[ OFF ]${CR}"; }

ui_opt() {
    local num="$1" title="$2" detail="${3:-}" tag="${4:-}"
    local title_w=24 detail_w=19
    local pad=$(( title_w - ${#title} - ${#num} + 1 ))
    [ $pad -lt 1 ] && pad=1
    printf "${UI_PAD}${CY}[%s]${CR} ${DM}▸${CR} ${WH}%s${CR}%*s" "$num" "$title" "$pad" ""
    local dpad
    if [ -n "$detail" ]; then
        printf "${DM}│ %s${CR}" "$detail"
        dpad=$(( detail_w - ${#detail} - 2 ))
    else
        dpad=$(( detail_w ))
    fi
    [ $dpad -lt 1 ] && dpad=1
    printf "%*s" "$dpad" ""
    [ -n "$tag" ] && printf "%b" "$tag"
    echo ""
}

ui_opt_danger() {
    local num="$1" title="$2" detail="${3:-}"
    local pad=$(( 24 - ${#title} - ${#num} + 1 ))
    [ $pad -lt 1 ] && pad=1
    printf "${UI_PAD}${CY}[%s]${CR} ${DM}▸${CR} ${RD}%s${CR}%*s" "$num" "$title" "$pad" ""
    [ -n "$detail" ] && printf "${RD}│ %s${CR}" "$detail"
    echo ""
}

ui_ok()   { echo -e "${UI_PAD}${GR}[+]${CR} $1"; }
ui_info() { echo -e "${UI_PAD}${YL}[*]${CR} $1"; }
ui_err()  { echo -e "${UI_PAD}${RD}[-]${CR} $1"; }
ui_warn() { echo -e "${UI_PAD}${YL}[!]${CR} $1"; }

ui_prompt() { read -r -p "$(echo -e "${UI_PAD}${DM}$1 ${CY}»${CR} ")" REPLY_UI; }
ui_pause()  { echo ""; read -r -p "$(echo -e "${UI_PAD}${DM}Presiona Enter para continuar...${CR}")"; }

# ui_ask <texto> <valor_por_defecto>  -> deja la respuesta en $REPLY_UI
ui_ask() {
    local q="$1" def="${2:-}"
    if [ -n "$def" ]; then
        read -r -p "$(echo -e "${UI_PAD}${DM}${q} ${DM}[${WH}${def}${DM}] ${CY}»${CR} ")" REPLY_UI
        REPLY_UI="${REPLY_UI:-$def}"
    else
        read -r -p "$(echo -e "${UI_PAD}${DM}${q} ${CY}»${CR} ")" REPLY_UI
    fi
}

# ui_confirm <texto> [s|n por defecto] -> 0 si acepta
ui_confirm() {
    local q="$1" def="${2:-s}" r
    read -r -p "$(echo -e "${UI_PAD}${DM}${q} (s/n) [${WH}${def}${DM}] ${CY}»${CR} ")" r
    r="${r:-$def}"
    [[ "$r" == "s" || "$r" == "S" ]]
}

NODE_VERSION="v1.0"

# =========================================================
# CONSTANTES DEL PROTOCOLO
# Estos valores son un contrato con wg_home.sh del VPS. Si se
# cambian aqui hay que cambiarlos alli: el VPS enruta a la IP
# fija 10.77.77.2 y escucha en 51820/UDP.
# =========================================================
NODE_IFACE="wg-home"
NODE_SUBNET="10.77.77.0/24"
NODE_VPS_WGIP="10.77.77.1"
NODE_SELF_WGIP="10.77.77.2"
NODE_DEFAULT_PORT="51820"
NODE_KEEPALIVE="25"

# Marca con la que se etiquetan las reglas propias, para poder
# retirarlas sin tocar el firewall que ya tuviera el aparato.
NODE_TAG="WGHOME_NODE"

# Prioridades de ip rule. Android usa el rango 10000-19999 para
# su propio policy routing, asi que nos colamos justo debajo de
# donde manda el trafico al agujero negro pero encima de main.
NODE_RULE_PRIO_BACK="14000"   # respuestas hacia la subred VPN
NODE_RULE_PRIO_FWD="15000"    # trafico que entra por wg-home

# =========================================================
# RUTAS — cambian segun el aparato, se fijan en _node_detect
# =========================================================
NODE_HOME=""          # directorio de configuracion
NODE_CONF=""          # node.conf (clave=valor)
NODE_PRIV=""          # clave privada WireGuard de este nodo
NODE_PUB=""           # clave publica WireGuard de este nodo
NODE_WGCONF=""        # wg-home.conf generado
NODE_LOG=""           # registro de eventos
NODE_PIDFILE=""       # pid del guardian (modo SOCKS / watchdog)
NODE_SELF="$( cd "$( dirname "${BASH_SOURCE[0]}" )" 2>/dev/null && pwd )/$( basename "${BASH_SOURCE[0]}" )"

# =========================================================
# ESTADO DETECTADO
# =========================================================
DEV_KIND=""       # vm | pc | termux | wsl | container | linux
DEV_LABEL=""      # texto legible para el panel
DEV_OS=""         # distribucion o version de Android
DEV_INIT=""       # systemd | termux-boot | magisk | cron | none
DEV_ROOT="no"     # yes | no
NODE_SU_CMD=""    # "" si ya somos root; "su -c" / "tsu -c" si hay que escalar
DEV_CAN_WG="no"   # el aparato puede levantar una interfaz wireguard
DEV_WG_KIND=""    # kernel | userspace

# =========================================================
# REGISTRO
# =========================================================
_node_log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
    [ -z "$NODE_LOG" ] && return 0
    mkdir -p "$(dirname "$NODE_LOG")" 2>/dev/null
    echo "[$ts] $*" >> "$NODE_LOG" 2>/dev/null
    # El log no crece sin control: en un telefono el almacenamiento
    # es escaso y el guardian escribe una linea por reintento.
    local lines
    lines=$(wc -l < "$NODE_LOG" 2>/dev/null || echo 0)
    if [ "${lines:-0}" -gt 2000 ]; then
        tail -n 800 "$NODE_LOG" > "${NODE_LOG}.tmp" 2>/dev/null && mv "${NODE_LOG}.tmp" "$NODE_LOG" 2>/dev/null
    fi
}

# =========================================================
# CAPA DE PRIVILEGIOS
# ---------------------------------------------------------
# En un PC somos root directamente. En Termux con Magisk hay
# que cruzar a 'su' en cada comando de red, y ese 'su' arranca
# con el PATH de Android: sin reexportar el PATH de Termux, ni
# 'wg' ni 'iptables' de los paquetes instalados serian visibles.
# =========================================================
_root_run() {
    if [ "$(id -u)" -eq 0 ]; then
        bash -c "$*"
    elif [ -n "$NODE_SU_CMD" ]; then
        $NODE_SU_CMD "export PATH='$PATH'; $*"
    else
        return 1
    fi
}

# Igual que _root_run pero silenciando toda la salida.
_root_try() { _root_run "$*" &>/dev/null; }

# =========================================================
# DETECCION DEL DISPOSITIVO
# =========================================================

_node_detect_android() {
    [ -n "${TERMUX_VERSION:-}" ] && return 0
    [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && return 0
    [ -d /data/data/com.termux/files/usr ] && return 0
    [ "$(uname -o 2>/dev/null)" = "Android" ] && return 0
    return 1
}

_node_detect_root() {
    if [ "$(id -u)" -eq 0 ]; then
        DEV_ROOT="yes"; NODE_SU_CMD=""
        return 0
    fi
    # La escalada automatica solo se intenta en Android. En un Linux
    # normal 'su' pide contrasena por terminal y dejaria el arranque
    # colgado en un prompt que el usuario no espera; alli la via
    # correcta es que el propio script se invoque con sudo.
    if ! _node_detect_android; then
        DEV_ROOT="no"; NODE_SU_CMD=""
        return 1
    fi

    local probe out
    for probe in tsu su; do
        command -v "$probe" &>/dev/null || continue
        # timeout evita quedarse esperando a que el usuario acepte el
        # dialogo de Magisk, que quiza ni siquiera esta viendo.
        out=$(timeout 15 "$probe" -c 'id -u' 2>/dev/null | tr -dc '0-9')
        if [ "$out" = "0" ]; then
            DEV_ROOT="yes"; NODE_SU_CMD="$probe -c"
            return 0
        fi
    done
    DEV_ROOT="no"; NODE_SU_CMD=""
    return 1
}

_node_detect_virt() {
    local v=""
    if command -v systemd-detect-virt &>/dev/null; then
        v=$(systemd-detect-virt 2>/dev/null)
        [ "$v" = "none" ] && v=""
    fi
    if [ -z "$v" ] && [ -r /sys/class/dmi/id/product_name ]; then
        v=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
        case "$v" in
            *VirtualBox*) v="virtualbox" ;;
            *VMware*)     v="vmware" ;;
            *KVM*|*QEMU*) v="kvm" ;;
            *)            v="" ;;
        esac
    fi
    echo "$v"
}

_node_detect_init() {
    if _node_detect_android; then
        # Termux:Boot es la unica via de arranque que no pide root.
        # Con root, Magisk service.d es mas fiable porque corre antes
        # de que se desbloquee la pantalla.
        if [ "$DEV_ROOT" = "yes" ] && _root_try "test -d /data/adb"; then
            echo "magisk"
        else
            echo "termux-boot"
        fi
        return
    fi
    if [ -d /run/systemd/system ] || command -v systemctl &>/dev/null; then
        echo "systemd"; return
    fi
    if command -v crontab &>/dev/null; then
        echo "cron"; return
    fi
    echo "none"
}

_node_detect() {
    # --- Familia del aparato ---
    if _node_detect_android; then
        DEV_KIND="termux"
        DEV_OS="Android $(getprop ro.build.version.release 2>/dev/null || echo '?')"
        local model
        model=$(getprop ro.product.model 2>/dev/null)
        DEV_LABEL="Termux${model:+ · $model}"
        NODE_HOME="${PREFIX:-/data/data/com.termux/files/usr}/etc/wghome-node"
    else
        if [ -r /proc/version ] && grep -qi "microsoft" /proc/version 2>/dev/null; then
            DEV_KIND="wsl"; DEV_LABEL="WSL (Windows)"
        elif [ -f /.dockerenv ] || grep -qaE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null; then
            DEV_KIND="container"; DEV_LABEL="Contenedor"
        else
            local virt
            virt=$(_node_detect_virt)
            if [ -n "$virt" ]; then
                DEV_KIND="vm"; DEV_LABEL="Maquina virtual ($virt)"
            else
                DEV_KIND="pc"; DEV_LABEL="Equipo fisico"
            fi
        fi
        if [ -r /etc/os-release ]; then
            DEV_OS=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${ID:-Linux}}" )
        else
            DEV_OS="Linux $(uname -r 2>/dev/null)"
        fi
        NODE_HOME="/etc/wghome-node"
    fi

    # --- Privilegios ---
    _node_detect_root

    # Sin root en un Linux normal no podemos escribir en /etc: el
    # nodo se guarda en el HOME del usuario y solo servira modo SOCKS.
    if [ "$DEV_KIND" != "termux" ] && [ "$DEV_ROOT" = "no" ]; then
        NODE_HOME="${HOME}/.wghome-node"
    fi

    NODE_CONF="${NODE_HOME}/node.conf"
    NODE_PRIV="${NODE_HOME}/node_private.key"
    NODE_PUB="${NODE_HOME}/node_public.key"
    NODE_WGCONF="${NODE_HOME}/wg-home.conf"
    NODE_LOG="${NODE_HOME}/node.log"
    NODE_PIDFILE="${NODE_HOME}/guardian.pid"

    # --- Arranque ---
    DEV_INIT=$(_node_detect_init)

    # --- Capacidad WireGuard ---
    _node_probe_wireguard
}

# Determina si este aparato puede sostener una interfaz WireGuard.
# No basta con que exista el binario 'wg': hace falta poder crear
# el device, y eso depende del kernel (module wireguard) o de que
# haya un /dev/net/tun utilizable para la version en espacio de usuario.
_node_probe_wireguard() {
    DEV_CAN_WG="no"; DEV_WG_KIND=""

    if [ "$DEV_ROOT" != "yes" ]; then
        # Sin root no hay TUN ni netlink: modo A queda descartado
        # por el sistema operativo, no por falta de paquetes.
        return 1
    fi

    command -v wg &>/dev/null || return 1

    # ¿El kernel trae WireGuard? Se comprueba creando y destruyendo
    # una interfaz de usar y tirar, que es la unica prueba que no
    # miente (el modulo puede estar compilado dentro del kernel y
    # no aparecer en lsmod).
    if _root_try "ip link add dev wgprobe0 type wireguard && ip link del dev wgprobe0"; then
        DEV_CAN_WG="yes"; DEV_WG_KIND="kernel"
        return 0
    fi
    _root_try "ip link del dev wgprobe0"

    # Sin modulo, wireguard-go hace el trabajo en espacio de usuario
    # a cambio de mas CPU y bateria. Necesita /dev/net/tun.
    if command -v wireguard-go &>/dev/null; then
        if _root_try "test -c /dev/net/tun" || _root_try "mkdir -p /dev/net && mknod /dev/net/tun c 10 200 && chmod 666 /dev/net/tun"; then
            DEV_CAN_WG="yes"; DEV_WG_KIND="userspace"
            return 0
        fi
    fi
    return 1
}

# Interfaz por la que este aparato sale a Internet ahora mismo.
# En un telefono cambia sola al pasar de wifi a datos, por eso se
# recalcula en cada activacion en vez de guardarse en el conf.
_node_uplink_iface() {
    local dev
    dev=$(_root_run "ip route get 1.1.1.1 2>/dev/null" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -z "$dev" ] && dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -z "$dev" ] && dev=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    echo "$dev"
}

# Tabla de rutas donde vive la default de esa interfaz.
# En Linux es 'main'. Android reparte cada red en su propia tabla
# (1021 para rmnet, 1002 para wlan...) y main suele estar vacia,
# asi que el trafico reenviado se perderia sin esta busqueda.
_node_uplink_table() {
    local dev="$1" t
    [ -z "$dev" ] && { echo "main"; return; }
    if _root_run "ip route show table main 2>/dev/null" 2>/dev/null | grep -q "^default.*dev ${dev}"; then
        echo "main"; return
    fi
    for t in $(_root_run "ip rule show 2>/dev/null" 2>/dev/null | sed -n 's/.*lookup \([A-Za-z0-9_]*\).*/\1/p' | sort -u); do
        [ "$t" = "local" ] && continue
        if _root_run "ip route show table $t 2>/dev/null" 2>/dev/null | grep -q "^default.*dev ${dev}"; then
            echo "$t"; return
        fi
    done
    echo "main"
}

# =========================================================
# CONFIGURACION PERSISTENTE
# ---------------------------------------------------------
# node.conf es un clave=valor plano. Se lee con un parser propio
# en vez de 'source' para que un fichero manipulado no pueda
# ejecutar codigo cuando el script corre como root al arrancar.
# =========================================================
CFG_MODE=""        # wireguard | socks
CFG_VPS_HOST=""    # IP o dominio del VPS
CFG_VPS_PORT=""    # 51820 en modo A, puerto SSH en modo B
CFG_VPS_PUBKEY=""  # clave publica WireGuard del VPS
CFG_SSH_USER=""    # usuario SSH del VPS (modo B)
CFG_SOCKS_PORT=""  # puerto SOCKS que se publica en el VPS (modo B)
CFG_AUTOSTART=""   # on | off
CFG_DEVICE=""      # etiqueta con la que se instalo
CFG_WG_CONF=""     # ruta del .conf de WireGuard realmente en uso
CFG_WG_MANAGER=""  # wg-quick | manual — quien manda sobre la interfaz
CFG_ADOPTED=""     # si | no — venia de una instalacion previa a mano

_node_cfg_get() {
    local key="$1"
    [ -f "$NODE_CONF" ] || return 1
    sed -n "s/^${key}=//p" "$NODE_CONF" 2>/dev/null | head -1
}

node_cfg_load() {
    [ -f "$NODE_CONF" ] || return 1
    CFG_MODE=$(_node_cfg_get MODE)
    CFG_VPS_HOST=$(_node_cfg_get VPS_HOST)
    CFG_VPS_PORT=$(_node_cfg_get VPS_PORT)
    CFG_VPS_PUBKEY=$(_node_cfg_get VPS_PUBKEY)
    CFG_SSH_USER=$(_node_cfg_get SSH_USER)
    CFG_SOCKS_PORT=$(_node_cfg_get SOCKS_PORT)
    CFG_AUTOSTART=$(_node_cfg_get AUTOSTART)
    CFG_DEVICE=$(_node_cfg_get DEVICE)
    CFG_WG_CONF=$(_node_cfg_get WG_CONF)
    CFG_WG_MANAGER=$(_node_cfg_get WG_MANAGER)
    CFG_ADOPTED=$(_node_cfg_get ADOPTED)

    # Un nodo adoptado usa el .conf que ya tenia, no el nuestro.
    [ -n "$CFG_WG_CONF" ] && NODE_WGCONF="$CFG_WG_CONF"
    [ -z "$CFG_WG_MANAGER" ] && CFG_WG_MANAGER="manual"

    # Rutas de clave fijadas al adoptar: mandan sobre las de por
    # defecto, porque son las que el VPS tiene registradas.
    local pk
    pk=$(_node_cfg_get PRIV_KEY); [ -n "$pk" ] && NODE_PRIV="$pk"
    pk=$(_node_cfg_get PUB_KEY);  [ -n "$pk" ] && NODE_PUB="$pk"

    # Lo mismo con las claves: si el conf adoptado vive en otro
    # sitio, las claves del metodo manual estan junto a el.
    if [ -n "$CFG_WG_CONF" ] && [ ! -f "$NODE_PRIV" ]; then
        local d k
        d=$(dirname "$CFG_WG_CONF")
        for k in home_private.key wghome_private.key node_private.key privatekey; do
            [ -f "$d/$k" ] && { NODE_PRIV="$d/$k"; break; }
        done
        for k in home_public.key wghome_public.key node_public.key publickey; do
            [ -f "$d/$k" ] && { NODE_PUB="$d/$k"; break; }
        done
    fi

    [ -n "$CFG_MODE" ]
}

node_cfg_save() {
    mkdir -p "$NODE_HOME" 2>/dev/null
    chmod 700 "$NODE_HOME" 2>/dev/null
    cat > "$NODE_CONF" <<EOF
# Nodo de salida residencial — generado por node.sh
# Editar a mano solo si sabes lo que haces.
MODE=${CFG_MODE}
DEVICE=${CFG_DEVICE}
VPS_HOST=${CFG_VPS_HOST}
VPS_PORT=${CFG_VPS_PORT}
VPS_PUBKEY=${CFG_VPS_PUBKEY}
SSH_USER=${CFG_SSH_USER}
SOCKS_PORT=${CFG_SOCKS_PORT}
AUTOSTART=${CFG_AUTOSTART}
WG_CONF=${CFG_WG_CONF}
WG_MANAGER=${CFG_WG_MANAGER}
ADOPTED=${CFG_ADOPTED}
PRIV_KEY=${NODE_PRIV}
PUB_KEY=${NODE_PUB}
EOF
    chmod 600 "$NODE_CONF" 2>/dev/null
}

node_is_configured() { [ -f "$NODE_CONF" ] && [ -n "$(_node_cfg_get MODE)" ]; }

# =========================================================
# DETECCION DE NODOS YA CONFIGURADOS
# ---------------------------------------------------------
# Antes de este script la contraparte se montaba a mano: claves
# en /etc/wireguard/home_private.key, conf en wg-home.conf y el
# servicio wg-quick@wg-home. Un equipo asi YA ES UN NODO, y
# tratarlo como virgen seria destructivo: regenerar las claves
# invalidaria el peer que el VPS ya tiene registrado.
#
# Por eso no se busca "nuestro" fichero de configuracion, sino
# la huella del protocolo: una interfaz WireGuard cuya direccion
# es 10.77.77.2. Eso es lo que define a un nodo, se haya creado
# como se haya creado.
# =========================================================

EX_WGCONF=""      # conf de WireGuard encontrado
EX_PRIV=""        # fichero de clave privada en uso
EX_PUB=""         # fichero de clave publica
EX_PEER_PUB=""    # clave publica del VPS leida del conf
EX_ENDPOINT=""    # host:puerto del VPS
EX_ADDRESS=""     # direccion de la interfaz
EX_UNIT=""        # wg-quick@wg-home: enabled / active / ""
EX_IFACE=""       # up si la interfaz existe ahora mismo
EX_NAT=""         # iptables / nft / ""

# Lee un campo de un .conf de WireGuard. Nunca se usa para
# mostrar la clave privada: solo para saber si existe.
_wg_conf_get() {
    local file="$1" key="$2"
    [ -r "$file" ] || { _root_run "cat '$file' 2>/dev/null" 2>/dev/null | sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" | head -1; return; }
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" 2>/dev/null | head -1
}

# ¿Este .conf describe a un nodo de salida de nuestro protocolo?
# La prueba es la direccion 10.77.77.2, no el nombre del fichero.
_wg_conf_is_node() {
    local file="$1" addr
    addr=$(_wg_conf_get "$file" "Address")
    [ -n "$addr" ] && [[ "$addr" == ${NODE_SELF_WGIP}/* || "$addr" == "$NODE_SELF_WGIP" ]]
}

_node_scan_existing() {
    EX_WGCONF=""; EX_PRIV=""; EX_PUB=""; EX_PEER_PUB=""
    EX_ENDPOINT=""; EX_ADDRESS=""; EX_UNIT=""; EX_IFACE=""; EX_NAT=""

    local -a dirs=("/etc/wireguard" "$NODE_HOME")
    [ -n "${PREFIX:-}" ] && dirs+=("${PREFIX}/etc/wireguard")

    # --- 1. Ficheros de configuracion ---
    # Se mira primero el nombre canonico y despues cualquier otro
    # conf del directorio: el usuario pudo llamarlo wg0.conf.
    local d f
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for f in "$d/${NODE_IFACE}.conf" "$d"/*.conf; do
            [ -f "$f" ] || continue
            if _wg_conf_is_node "$f"; then
                EX_WGCONF="$f"
                break 2
            fi
        done
    done

    if [ -n "$EX_WGCONF" ]; then
        EX_ADDRESS=$(_wg_conf_get "$EX_WGCONF" "Address")
        EX_PEER_PUB=$(_wg_conf_get "$EX_WGCONF" "PublicKey")
        EX_ENDPOINT=$(_wg_conf_get "$EX_WGCONF" "Endpoint")
    fi

    # --- 2. Claves sueltas del metodo manual ---
    local k
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for k in home_private.key wghome_private.key node_private.key privatekey; do
            [ -f "$d/$k" ] && { EX_PRIV="$d/$k"; break; }
        done
        for k in home_public.key wghome_public.key node_public.key publickey; do
            [ -f "$d/$k" ] && { EX_PUB="$d/$k"; break; }
        done
        [ -n "$EX_PRIV" ] && break
    done

    # --- 3. Servicio systemd del metodo manual ---
    if command -v systemctl &>/dev/null; then
        if systemctl is-enabled "wg-quick@${NODE_IFACE}" &>/dev/null; then
            EX_UNIT="enabled"
            systemctl is-active --quiet "wg-quick@${NODE_IFACE}" 2>/dev/null && EX_UNIT="enabled+active"
        elif systemctl is-active --quiet "wg-quick@${NODE_IFACE}" 2>/dev/null; then
            EX_UNIT="active"
        fi
    fi

    # --- 4. Interfaz viva ---
    # Es la evidencia mas fuerte: si existe, este equipo esta
    # haciendo de nodo ahora mismo aunque falten los ficheros.
    if _root_run "ip link show ${NODE_IFACE} 2>/dev/null" &>/dev/null; then
        EX_IFACE="up"
        [ -z "$EX_PEER_PUB" ] && EX_PEER_PUB=$(_root_run "wg show ${NODE_IFACE} peers 2>/dev/null" 2>/dev/null | head -1)
        [ -z "$EX_ENDPOINT" ] && EX_ENDPOINT=$(_root_run "wg show ${NODE_IFACE} endpoints 2>/dev/null" 2>/dev/null | awk '{print $2}' | head -1)
    fi

    # --- 5. NAT ya montado ---
    if _root_run "nft list ruleset 2>/dev/null" 2>/dev/null | grep -q "masquerade"; then
        EX_NAT="nft"
    elif _root_run "iptables -t nat -S POSTROUTING 2>/dev/null" 2>/dev/null | grep -q "MASQUERADE"; then
        EX_NAT="iptables"
    fi

    # Una interfaz wg-home viva NO basta por si sola: nuestro propio
    # script pudo dejarla creada y sin peer en un intento fallido, y
    # adoptarla generaba una config que apuntaba a claves
    # inexistentes. Solo cuenta si ademas tiene peer.
    [ -n "$EX_WGCONF" ] || [ -n "$EX_UNIT" ] || \
        { [ -n "$EX_IFACE" ] && [ -n "$EX_PEER_PUB" ]; }
}

# Convierte los hallazgos en un node.conf. No copia ni regenera
# claves: apunta a las que ya existen, que son las que el VPS
# tiene registradas.
node_adopt_existing() {
    CFG_MODE="wireguard"
    CFG_DEVICE="${DEV_LABEL} · ${DEV_OS}"
    CFG_ADOPTED="si"

    # El conf adoptado manda; si no habia, se usara el nuestro.
    if [ -n "$EX_WGCONF" ]; then
        CFG_WG_CONF="$EX_WGCONF"
        NODE_WGCONF="$EX_WGCONF"
    fi

    # wg-quick ya gestiona la interfaz: no se le disputa el mando,
    # se usa el mismo servicio para subirla y bajarla.
    if [ -n "$EX_UNIT" ]; then
        CFG_WG_MANAGER="wg-quick"
    else
        CFG_WG_MANAGER="manual"
    fi

    CFG_VPS_PUBKEY="$EX_PEER_PUB"
    if [ -n "$EX_ENDPOINT" ]; then
        CFG_VPS_HOST="${EX_ENDPOINT%:*}"
        CFG_VPS_PORT="${EX_ENDPOINT##*:}"
    fi
    [ -z "$CFG_VPS_PORT" ] && CFG_VPS_PORT="$NODE_DEFAULT_PORT"

    # Las claves del metodo manual se dejan donde estan.
    [ -n "$EX_PRIV" ] && NODE_PRIV="$EX_PRIV"
    [ -n "$EX_PUB" ]  && NODE_PUB="$EX_PUB"

    [ -n "$EX_UNIT" ] && CFG_AUTOSTART="on" || CFG_AUTOSTART="off"

    # Un montaje manual guarda la clave dentro del propio .conf y
    # rara vez deja un fichero suelto. Se extrae ahora, no cuando
    # haga falta: asi el nodo adoptado queda completo de entrada y
    # no falla mas tarde con un error de fichero inexistente.
    if wg_ensure_public_key; then
        _node_log "Claves del nodo adoptado listas (${NODE_PRIV})"
    else
        _node_log "AVISO: nodo adoptado sin clave privada utilizable"
    fi

    node_cfg_save
    _node_log "Configuracion previa adoptada: conf=${EX_WGCONF:-ninguno} unidad=${EX_UNIT:-ninguna} gestor=${CFG_WG_MANAGER}"
}

# Pantalla de adopcion. Enseña lo encontrado antes de tocar nada:
# el usuario debe poder decir que no y conservar su montaje.
node_screen_adopt() {
    clear; node_title
    ui_section "NODO YA CONFIGURADO" "se encontro una instalacion previa"
    ui_blank
    ui_info "Este dispositivo ya esta actuando como nodo de salida."
    ui_blank

    [ -n "$EX_WGCONF" ]  && echo -e "${UI_PAD}$(ui_cell "Configuracion" "$EX_WGCONF" 60 "$WH")"
    [ -n "$EX_ADDRESS" ] && echo -e "${UI_PAD}$(ui_cell "Direccion" "$EX_ADDRESS" 60 "$CY")"
    [ -n "$EX_PRIV" ]    && echo -e "${UI_PAD}$(ui_cell "Clave privada" "$EX_PRIV" 60 "$DM")"
    [ -n "$EX_ENDPOINT" ]&& echo -e "${UI_PAD}$(ui_cell "VPS" "$EX_ENDPOINT" 60 "$WH")"
    [ -n "$EX_UNIT" ]    && echo -e "${UI_PAD}$(ui_cell "wg-quick@${NODE_IFACE}" "$EX_UNIT" 60 "$GR")"
    [ -n "$EX_IFACE" ]   && echo -e "${UI_PAD}$(ui_cell "Interfaz ${NODE_IFACE}" "activa ahora mismo" 60 "$GR")"
    [ -n "$EX_NAT" ]     && echo -e "${UI_PAD}$(ui_cell "NAT existente" "$EX_NAT" 60 "$CY")"

    ui_blank
    ui_rule
    ui_blank
    echo -e "${UI_PAD}${DM}Al adoptarla, el panel toma el mando de lo que ya${CR}"
    echo -e "${UI_PAD}${DM}existe: reutiliza tus claves —las que el VPS tiene${CR}"
    echo -e "${UI_PAD}${DM}registradas— y no reescribe tu configuracion.${CR}"
    ui_blank
    ui_warn "Reconfigurar desde cero generaria claves nuevas y el"
    echo -e "${UI_PAD}${DM}   VPS dejaria de reconocer a este nodo.${CR}"
    ui_solid
    ui_blank

    if ui_confirm "¿Adoptar la configuracion existente?" "s"; then
        node_adopt_existing
        ui_blank
        ui_ok "Configuracion adoptada. Tus claves siguen intactas."
        [ "$CFG_WG_MANAGER" = "wg-quick" ] && \
            ui_info "El tunel se seguira gestionando con wg-quick@${NODE_IFACE}."
        ui_pause
        return 0
    fi
    return 1
}

# =========================================================
# DEPENDENCIAS
# =========================================================
_node_pkg_install() {
    local pkgs="$*"
    ui_info "Instalando: ${pkgs}"
    if _node_detect_android; then
        pkg install -y $pkgs &>/dev/null || apt install -y $pkgs &>/dev/null
    elif command -v apt-get &>/dev/null; then
        _root_try "apt-get update -yq"
        _root_try "apt-get install -yq $pkgs"
    elif command -v pacman &>/dev/null; then
        _root_try "pacman -Sy --noconfirm $pkgs"
    elif command -v dnf &>/dev/null; then
        _root_try "dnf install -y $pkgs"
    elif command -v apk &>/dev/null; then
        _root_try "apk add $pkgs"
    else
        return 1
    fi
}

_node_ensure_wg_tools() {
    command -v wg &>/dev/null && return 0
    if _node_detect_android; then
        # wireguard-tools vive en el repositorio root de Termux.
        pkg install -y root-repo &>/dev/null
        _node_pkg_install "wireguard-tools iproute2"
    else
        _node_pkg_install "wireguard-tools"
    fi
    command -v wg &>/dev/null
}

_node_ensure_ssh() {
    command -v ssh &>/dev/null && return 0
    if _node_detect_android; then
        _node_pkg_install "openssh"
    else
        _node_pkg_install "openssh-client"
    fi
    command -v ssh &>/dev/null
}

# =========================================================
# MODO A · WIREGUARD
# ---------------------------------------------------------
# El nodo es el peer 10.77.77.2. AllowedIPs vale 10.77.77.1/32
# a proposito: solo se tuneliza la conversacion con el VPS. Si
# se pusiera 0.0.0.0/0 el propio aparato mandaria su navegacion
# al VPS y se formaria un bucle — justo lo contrario de lo que
# queremos, que es prestar la salida, no consumirla.
# =========================================================

wg_generate_keys() {
    mkdir -p "$NODE_HOME" 2>/dev/null
    chmod 700 "$NODE_HOME" 2>/dev/null

    if ! command -v wg &>/dev/null; then
        ui_err "El comando 'wg' no esta disponible: no se pueden generar claves."
        _node_log "wg genkey imposible: falta wireguard-tools"
        return 1
    fi

    # La comprobacion es -s, no -f. Si un intento anterior fallo con
    # 'wg' aun sin instalar, quedo un fichero de cero bytes; con -f
    # se daba por bueno para siempre y el nodo no arrancaba nunca.
    if [ ! -s "$NODE_PRIV" ]; then
        (umask 077; wg genkey > "$NODE_PRIV" 2>/dev/null)
        if [ ! -s "$NODE_PRIV" ]; then
            rm -f "$NODE_PRIV" 2>/dev/null
            ui_err "No se pudo generar la clave privada."
            _node_log "wg genkey produjo un fichero vacio"
            return 1
        fi
        chmod 600 "$NODE_PRIV"
        _node_log "Par de claves WireGuard generado"
    fi

    # La publica se deriva siempre que falte o este vacia; hacerlo
    # no invalida el registro que el VPS ya tenga.
    if [ ! -s "$NODE_PUB" ]; then
        wg pubkey < "$NODE_PRIV" > "$NODE_PUB" 2>/dev/null
        chmod 644 "$NODE_PUB" 2>/dev/null
    fi
    [ -s "$NODE_PUB" ]
}

# Devuelve las rutas de trabajo a las nuestras. Reconfigurar desde
# cero no puede heredar los punteros de una adopcion anterior: si
# lo hiciera, escribiriamos claves nuevas en un sitio y buscariamos
# la config en otro.
_node_reset_paths() {
    NODE_WGCONF="${NODE_HOME}/wg-home.conf"
    NODE_PRIV="${NODE_HOME}/node_private.key"
    NODE_PUB="${NODE_HOME}/node_public.key"
}

# ¿La configuracion actual sirve para levantar el tunel? Un nodo
# puede quedar a medias (adoptado de algo que no era un nodo, o con
# claves que nunca llegaron a generarse) y conviene decirlo antes de
# que el usuario lo descubra al conectar.
node_config_is_sane() {
    [ "$CFG_MODE" != "wireguard" ] && return 0
    [ -n "$CFG_VPS_PUBKEY" ] && [ -n "$CFG_VPS_HOST" ] || return 1
    [ -s "$NODE_PRIV" ] && return 0
    [ -n "$NODE_WGCONF" ] && [ -n "$(_wg_conf_get "$NODE_WGCONF" "PrivateKey")" ] && return 0
    return 1
}

wg_render_conf() {
    local priv
    priv=$(cat "$NODE_PRIV" 2>/dev/null)
    cat <<EOF
# =========================================================
# Nodo de salida residencial — peer de wg_home.sh
# Interfaz : ${NODE_IFACE}
# Este equipo : ${NODE_SELF_WGIP}   VPS : ${NODE_VPS_WGIP}
# =========================================================
[Interface]
PrivateKey = ${priv}
Address    = ${NODE_SELF_WGIP}/24

[Peer]
PublicKey           = ${CFG_VPS_PUBKEY}
Endpoint            = ${CFG_VPS_HOST}:${CFG_VPS_PORT}
AllowedIPs          = ${NODE_VPS_WGIP}/32
PersistentKeepalive = ${NODE_KEEPALIVE}
EOF
}

wg_write_conf() {
    # Un conf adoptado es del usuario, no nuestro: reescribirlo
    # borraria ajustes suyos (DNS, PostUp, MTU, rutas propias).
    # Los cambios de endpoint se aplican con 'wg set', que toca
    # solo el campo pedido.
    # La guarda exige que el conf adoptado tenga clave dentro. Un
    # fichero ausente o vacio no es "configuracion del usuario que
    # hay que respetar": protegerlo dejaba al nodo sin salida.
    if [ "$CFG_ADOPTED" = "si" ] && [ -n "$(_wg_conf_get "$NODE_WGCONF" "PrivateKey")" ]; then
        _node_log "Conf adoptado ${NODE_WGCONF}: no se reescribe"
        if [ -n "$CFG_VPS_PUBKEY" ] && [ -n "$CFG_VPS_HOST" ]; then
            _root_try "wg set ${NODE_IFACE} peer ${CFG_VPS_PUBKEY} endpoint ${CFG_VPS_HOST}:${CFG_VPS_PORT}"
        fi
        return 0
    fi
    wg_render_conf > "$NODE_WGCONF"
    chmod 600 "$NODE_WGCONF"
}

wg_is_up() { _root_run "ip link show ${NODE_IFACE} 2>/dev/null" &>/dev/null; }

# Que la interfaz exista NO significa que este configurada. Si un
# 'wg setconf' fallo, queda una interfaz viva y sin peer: sube el
# tunel en el menu, no da error, y nunca hay handshake. Este es
# justo el estado que hace parecer que "el VPS no responde".
wg_peer_configured() {
    [ -n "$(_root_run "wg show ${NODE_IFACE} peers 2>/dev/null" 2>/dev/null)" ]
}

# El endpoint del VPS resuelto y fijado en la interfaz.
wg_endpoint_known() {
    local ep
    ep=$(_root_run "wg show ${NODE_IFACE} endpoints 2>/dev/null" 2>/dev/null | awk '{print $2}' | head -1)
    [ -n "$ep" ] && [ "$ep" != "(none)" ]
}

# Bytes cifrados enviados y recibidos. La relacion entre ambos es
# el diagnostico mas util que existe aqui:
#   tx > 0 y rx = 0  -> nuestros handshakes salen y nada vuelve:
#                       puerto UDP bloqueado o clave equivocada.
#   tx = 0           -> ni siquiera intentamos: falta el peer.
wg_transfer() {
    _root_run "wg show ${NODE_IFACE} transfer 2>/dev/null" 2>/dev/null | head -1 | awk '{print $2" "$3}'
}

wg_handshake_age() {
    local ts now
    ts=$(_root_run "wg show ${NODE_IFACE} latest-handshakes 2>/dev/null" 2>/dev/null | awk '{print $2}' | head -1)
    [ -z "$ts" ] || [ "$ts" = "0" ] && { echo "-1"; return; }
    now=$(date +%s)
    echo $(( now - ts ))
}

wg_has_handshake() {
    local age
    age=$(wg_handshake_age)
    [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt 180 ]
}

# Vuelca la configuracion sobre la interfaz. Los errores se guardan
# en el log en vez de tirarse a /dev/null: cuando esto falla en
# silencio, el sintoma que ve el usuario es "el VPS no responde al
# ping", que manda a buscar el problema en el sitio equivocado.
# Deja un .conf que 'wg setconf' acepte: solo las claves que
# entiende el kernel. 'wg-quick strip' hace esto, pero depender de
# el cuesta dos problemas en Android: no siempre esta instalado, y
# su salida habria que pasarla por sustitucion de proceso <(...),
# que el 'sh' de Android con el que corre 'su -c' no soporta.
_wg_strip_conf() {
    local src="$1" dst="$2"
    # En Termux el conf es del propio usuario y se lee directo; en
    # /etc/wireguard es 600 de root y hay que pasar por su. Probar
    # primero la via directa evita un salto a 'su' innecesario y,
    # sobre todo, funciona cuando no hay root en absoluto.
    ( umask 077
      if [ -r "$src" ]; then
          cat "$src"
      else
          _root_run "cat '${src}' 2>/dev/null" 2>/dev/null
      fi \
        | grep -viE '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' \
        > "$dst" ) 2>/dev/null
    [ -s "$dst" ]
}

# 'wg set private-key' exige la RUTA de un fichero, no la clave.
# Una config normal —y toda config adoptada— lleva la clave dentro
# del propio .conf, asi que no hay tal fichero: de ahi el
# "fopen: No such file or directory" que devolvia WireGuard.
wg_ensure_private_key() {
    [ -s "$NODE_PRIV" ] && return 0
    local k=""
    [ -n "$NODE_WGCONF" ] && k=$(_wg_conf_get "$NODE_WGCONF" "PrivateKey")
    [ -z "$k" ] && return 1
    mkdir -p "$NODE_HOME" 2>/dev/null
    NODE_PRIV="${NODE_HOME}/node_private.key"
    ( umask 077; printf '%s\n' "$k" > "$NODE_PRIV" )
    chmod 600 "$NODE_PRIV" 2>/dev/null
    _node_log "Clave privada extraida del conf a ${NODE_PRIV}"
    return 0
}

# La publica se deriva de la privada; no hace falta guardarla en el
# conf ni pedirsela al usuario.
wg_ensure_public_key() {
    [ -s "$NODE_PUB" ] && return 0
    wg_ensure_private_key || return 1
    NODE_PUB="${NODE_HOME}/node_public.key"
    wg pubkey < "$NODE_PRIV" > "$NODE_PUB" 2>/dev/null
    chmod 644 "$NODE_PUB" 2>/dev/null
    [ -s "$NODE_PUB" ]
}

wg_apply_peer() {
    local quiet="${1:-}" err="" tmp

    # --- Via 1: volcar el conf entero, ya depurado ---
    if [ -n "$NODE_WGCONF" ]; then
        tmp="${NODE_HOME}/.setconf.$$"
        if _wg_strip_conf "$NODE_WGCONF" "$tmp"; then
            err=$(_root_run "wg setconf ${NODE_IFACE} '${tmp}'" 2>&1)
            rm -f "$tmp" 2>/dev/null
            wg_peer_configured && return 0
            [ -n "$err" ] && _node_log "wg setconf fallo: ${err}"
        else
            rm -f "$tmp" 2>/dev/null
            _node_log "No se pudo leer ${NODE_WGCONF} para setconf"
        fi
    fi

    # --- Via 2: campo a campo ---
    # Necesita la clave privada en un fichero propio y saber cual es
    # el VPS. Si falta cualquiera de las dos, decirlo es mas util que
    # dejar que WireGuard responda con un error de bajo nivel.
    if ! wg_ensure_private_key; then
        _node_log "Sin clave privada utilizable (ni fichero ni dentro del conf)"
        [ -z "$quiet" ] && {
            ui_err "No hay clave privada para este nodo."
            echo -e "${UI_PAD}${DM}   Ni ${NODE_PRIV}${CR}"
            echo -e "${UI_PAD}${DM}   ni una linea PrivateKey dentro de ${NODE_WGCONF:-<sin conf>}.${CR}"
            echo -e "${UI_PAD}${DM}   Reconfigura con la opcion 1 para generar un par nuevo${CR}"
            echo -e "${UI_PAD}${DM}   (tendras que registrarlo de nuevo en el VPS).${CR}"
        }
        return 1
    fi

    if [ -z "$CFG_VPS_PUBKEY" ] || [ -z "$CFG_VPS_HOST" ]; then
        _node_log "Faltan datos del VPS: pubkey='${CFG_VPS_PUBKEY}' host='${CFG_VPS_HOST}'"
        [ -z "$quiet" ] && {
            ui_err "Faltan datos del VPS."
            echo -e "${UI_PAD}${DM}   Clave publica: ${CFG_VPS_PUBKEY:-<vacia>}${CR}"
            echo -e "${UI_PAD}${DM}   Host: ${CFG_VPS_HOST:-<vacio>}${CR}"
            echo -e "${UI_PAD}${DM}   Complétalos con la opcion 6 del menu.${CR}"
        }
        return 1
    fi

    err=$(_root_run "wg set ${NODE_IFACE} private-key '${NODE_PRIV}' peer '${CFG_VPS_PUBKEY}' endpoint '${CFG_VPS_HOST}:${CFG_VPS_PORT}' allowed-ips ${NODE_VPS_WGIP}/32 persistent-keepalive ${NODE_KEEPALIVE}" 2>&1)
    wg_peer_configured && return 0

    _node_log "wg set fallo: ${err}"
    [ -z "$quiet" ] && {
        ui_err "WireGuard rechazo la configuracion:"
        echo -e "${UI_PAD}${DM}   ${err:-sin detalle}${CR}"
    }
    return 1
}

# Levanta la interfaz sin wg-quick. wg-quick da por hecho un
# Linux de escritorio (resolvconf, sysctl, rutas en main) y en
# Android se rompe; montarla a mano es identico y portable.
wg_tunnel_up() {
    local quiet="${1:-}"
    [ -f "$NODE_WGCONF" ] || { [ -z "$quiet" ] && ui_err "Falta ${NODE_WGCONF}. Reconfigura (opcion 1)."; return 1; }

    if wg_is_up; then
        if wg_peer_configured; then
            [ -z "$quiet" ] && ui_warn "El tunel ya estaba activo."
            return 0
        fi
        # Interfaz huerfana: existe pero sin peer. Se reconfigura en
        # lugar de devolver un exito falso.
        [ -z "$quiet" ] && ui_warn "La interfaz existia sin peer configurado. Reparando..."
        _node_log "Interfaz ${NODE_IFACE} sin peer — reconfigurando"
        wg_apply_peer "$quiet"
        _root_try "ip link set up dev ${NODE_IFACE}"
        sleep 1
        wg_peer_configured && { [ -z "$quiet" ] && ui_ok "Peer restaurado."; return 0; }
        [ -z "$quiet" ] && ui_err "No se pudo configurar el peer."
        return 1
    fi

    # Si el montaje previo ya lo gestiona wg-quick, se usa su
    # servicio en lugar de crear la interfaz por nuestra cuenta:
    # dos gestores sobre la misma interfaz se pisan entre si.
    if [ "$CFG_WG_MANAGER" = "wg-quick" ]; then
        [ -z "$quiet" ] && ui_info "Levantando via wg-quick@${NODE_IFACE}..."
        _root_try "systemctl start wg-quick@${NODE_IFACE}" || \
            _root_try "wg-quick up ${NODE_IFACE}"
        sleep 1
        if wg_is_up; then
            _node_log "Tunel ${NODE_IFACE} levantado por wg-quick"
            [ -z "$quiet" ] && ui_ok "Tunel ${NODE_IFACE} activo."
            return 0
        fi
        [ -z "$quiet" ] && ui_err "wg-quick no pudo levantar la interfaz."
        return 1
    fi

    [ -z "$quiet" ] && ui_info "Creando interfaz ${NODE_IFACE}..."

    if [ "$DEV_WG_KIND" = "userspace" ]; then
        _root_try "test -c /dev/net/tun || { mkdir -p /dev/net && mknod /dev/net/tun c 10 200 && chmod 666 /dev/net/tun; }"
        _root_try "WG_PROCESS_FOREGROUND=0 wireguard-go ${NODE_IFACE}"
        sleep 1
    else
        _root_try "ip link add dev ${NODE_IFACE} type wireguard" || {
            [ -z "$quiet" ] && ui_err "No se pudo crear la interfaz. ¿Kernel sin WireGuard?"
            return 1
        }
    fi

    wg_apply_peer "$quiet"

    _root_try "ip address add ${NODE_SELF_WGIP}/24 dev ${NODE_IFACE}"
    _root_try "ip link set up dev ${NODE_IFACE}"

    sleep 1
    if wg_is_up && wg_peer_configured; then
        _node_log "Tunel ${NODE_IFACE} levantado hacia ${CFG_VPS_HOST}:${CFG_VPS_PORT}"
        [ -z "$quiet" ] && {
            ui_ok "Tunel ${NODE_IFACE} activo."
            # El handshake no es instantaneo, pero si a los pocos
            # segundos no llega, avisamos aqui y no dentro de media
            # hora cuando el usuario pruebe el ping desde el VPS.
            ui_info "Esperando handshake con el VPS..."
            local w=0
            while [ $w -lt 12 ]; do
                wg_has_handshake && { ui_ok "Handshake recibido: el VPS ya sabe donde estas."; return 0; }
                sleep 1; w=$((w+1))
            done
            ui_warn "Sin handshake tras ${w}s."
            echo -e "${UI_PAD}${DM}   Hasta que lo haya, el VPS NO puede hacerte ping:${CR}"
            echo -e "${UI_PAD}${DM}   no conoce tu direccion hasta que tu le hablas.${CR}"
            echo -e "${UI_PAD}${DM}   Usa la opcion 7 para ver donde se corta.${CR}"
        }
        return 0
    fi
    [ -z "$quiet" ] && ui_err "La interfaz no llego a levantarse con peer."
    return 1
}

wg_tunnel_down() {
    local quiet="${1:-}"
    nat_off quiet

    if [ "$CFG_WG_MANAGER" = "wg-quick" ]; then
        _root_try "systemctl stop wg-quick@${NODE_IFACE}" || \
            _root_try "wg-quick down ${NODE_IFACE}"
        _node_log "Tunel ${NODE_IFACE} detenido por wg-quick"
        [ -z "$quiet" ] && ui_ok "Tunel detenido."
        return 0
    fi

    if [ "$DEV_WG_KIND" = "userspace" ]; then
        _root_try "pkill -f 'wireguard-go ${NODE_IFACE}'"
        _root_try "rm -f /var/run/wireguard/${NODE_IFACE}.sock"
    fi
    _root_try "ip link del dev ${NODE_IFACE}"
    _node_log "Tunel ${NODE_IFACE} detenido"
    [ -z "$quiet" ] && ui_ok "Tunel detenido."
}

# =========================================================
# NAT — convertir el nodo en puerta hacia Internet
# ---------------------------------------------------------
# Sin esto el tunel sube pero el VPS no navega: los paquetes
# llegan a 10.77.77.2 y mueren ahi por falta de reenvio y de
# traduccion de origen.
# =========================================================
# ¿Hay un masquerade puesto por otro (nftables del metodo manual,
# firewalld, el propio usuario) que ya cubra nuestra subred?
# Si lo hay no debemos añadir el nuestro: duplicar NAT no mejora
# nada y ensucia un firewall que ya funcionaba.
_nat_foreign_present() {
    local up="$1"
    _root_run "nft list ruleset 2>/dev/null" 2>/dev/null \
        | grep -i "masquerade" | grep -qE "${NODE_SUBNET%/*}|oifname \"?${up}" && return 0
    _root_run "iptables -t nat -S POSTROUTING 2>/dev/null" 2>/dev/null \
        | grep -v "$NODE_TAG" | grep -i "MASQUERADE" | grep -qE "${NODE_SUBNET%/*}|-o ${up}" && return 0
    return 1
}

nat_is_active() {
    local up
    up=$(_node_uplink_iface)
    [ -z "$up" ] && return 1
    _root_run "iptables -t nat -C POSTROUTING -o ${up} -m comment --comment ${NODE_TAG} -j MASQUERADE 2>/dev/null" &>/dev/null && return 0
    _nat_foreign_present "$up"
}

nat_on() {
    local quiet="${1:-}" up tbl
    up=$(_node_uplink_iface)
    if [ -z "$up" ]; then
        [ -z "$quiet" ] && ui_err "Sin salida a Internet: no hay ruta por defecto."
        return 1
    fi
    tbl=$(_node_uplink_table "$up")

    [ -z "$quiet" ] && ui_info "Salida por ${up} (tabla ${tbl})."

    _root_try "sysctl -w net.ipv4.ip_forward=1"

    if _nat_foreign_present "$up"; then
        _node_log "NAT ya provisto por reglas ajenas en ${up}: no se duplica"
        [ -z "$quiet" ] && {
            ui_ok "Ya existe NAT para esta salida (nftables o reglas propias)."
            echo -e "${UI_PAD}${DM}   No se añaden reglas duplicadas.${CR}"
        }
        return 0
    fi

    # Reenvio en ambos sentidos, etiquetado para poder retirarlo.
    _root_run "iptables -C FORWARD -i ${NODE_IFACE} -o ${up} -m comment --comment ${NODE_TAG} -j ACCEPT 2>/dev/null" &>/dev/null || \
        _root_try "iptables -I FORWARD 1 -i ${NODE_IFACE} -o ${up} -m comment --comment ${NODE_TAG} -j ACCEPT"
    _root_run "iptables -C FORWARD -i ${up} -o ${NODE_IFACE} -m state --state RELATED,ESTABLISHED -m comment --comment ${NODE_TAG} -j ACCEPT 2>/dev/null" &>/dev/null || \
        _root_try "iptables -I FORWARD 1 -i ${up} -o ${NODE_IFACE} -m state --state RELATED,ESTABLISHED -m comment --comment ${NODE_TAG} -j ACCEPT"

    # Traduccion de origen: el trafico del VPS sale con la IP de casa.
    _root_run "iptables -t nat -C POSTROUTING -o ${up} -m comment --comment ${NODE_TAG} -j MASQUERADE 2>/dev/null" &>/dev/null || \
        _root_try "iptables -t nat -A POSTROUTING -o ${up} -m comment --comment ${NODE_TAG} -j MASQUERADE"

    # El MTU del tunel se recorta a 1420 y muchos sitios quedan a
    # medias por MSS mal negociado; esto lo arregla en el momento.
    _root_run "iptables -t mangle -C FORWARD -o ${up} -p tcp --tcp-flags SYN,RST SYN -m comment --comment ${NODE_TAG} -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null" &>/dev/null || \
        _root_try "iptables -t mangle -A FORWARD -o ${up} -p tcp --tcp-flags SYN,RST SYN -m comment --comment ${NODE_TAG} -j TCPMSS --clamp-mss-to-pmtu"

    # Policy routing solo donde hace falta. En Android la default
    # no esta en main, asi que el paquete reenviado no encontraria
    # salida y la respuesta no sabria volver al tunel.
    if [ "$tbl" != "main" ]; then
        _root_run "ip rule show 2>/dev/null" 2>/dev/null | grep -q "iif ${NODE_IFACE} lookup ${tbl}" || \
            _root_try "ip rule add iif ${NODE_IFACE} lookup ${tbl} priority ${NODE_RULE_PRIO_FWD}"
        _root_run "ip rule show 2>/dev/null" 2>/dev/null | grep -q "to ${NODE_SUBNET} lookup main" || \
            _root_try "ip rule add to ${NODE_SUBNET} lookup main priority ${NODE_RULE_PRIO_BACK}"
    fi

    _node_log "NAT activado hacia ${up} (tabla ${tbl})"
    [ -z "$quiet" ] && ui_ok "Salida a Internet compartida con el VPS."
    return 0
}

nat_off() {
    local quiet="${1:-}"
    # Se recorren todas las interfaces que hayan podido usarse:
    # el telefono pudo activar NAT en wifi y apagarlo en datos.
    local ifaces
    ifaces=$(_root_run "iptables-save -t nat 2>/dev/null" 2>/dev/null | grep "$NODE_TAG" | grep -oE '\-o [A-Za-z0-9_.-]+' | awk '{print $2}' | sort -u)
    [ -z "$ifaces" ] && ifaces=$(_node_uplink_iface)

    local up
    for up in $ifaces; do
        [ -z "$up" ] && continue
        while _root_run "iptables -t nat -D POSTROUTING -o ${up} -m comment --comment ${NODE_TAG} -j MASQUERADE 2>/dev/null" &>/dev/null; do :; done
        while _root_run "iptables -D FORWARD -i ${NODE_IFACE} -o ${up} -m comment --comment ${NODE_TAG} -j ACCEPT 2>/dev/null" &>/dev/null; do :; done
        while _root_run "iptables -D FORWARD -i ${up} -o ${NODE_IFACE} -m state --state RELATED,ESTABLISHED -m comment --comment ${NODE_TAG} -j ACCEPT 2>/dev/null" &>/dev/null; do :; done
        while _root_run "iptables -t mangle -D FORWARD -o ${up} -p tcp --tcp-flags SYN,RST SYN -m comment --comment ${NODE_TAG} -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null" &>/dev/null; do :; done
    done

    while _root_run "ip rule show 2>/dev/null" 2>/dev/null | grep -q "iif ${NODE_IFACE}"; do
        _root_try "ip rule del iif ${NODE_IFACE}" || break
    done
    while _root_run "ip rule show 2>/dev/null" 2>/dev/null | grep -q "to ${NODE_SUBNET} lookup main"; do
        _root_try "ip rule del to ${NODE_SUBNET} lookup main" || break
    done

    _node_log "NAT desactivado"
    [ -z "$quiet" ] && ui_ok "Reglas de salida retiradas."
}

# =========================================================
# MODO B · SOCKS INVERSO POR SSH
# ---------------------------------------------------------
# Por que existe este modo: sin root Android no deja crear un
# TUN ni tocar iptables, asi que un peer WireGuard que reenvie
# trafico es imposible — no es cuestion de paquetes, es el
# sistema el que lo prohibe. La app oficial de WireGuard usa
# VpnService, que solo captura el trafico del propio movil y
# no puede reenviar el que llega desde fuera.
#
# La vuelta: OpenSSH >= 7.6 acepta '-R <puerto>' sin destino,
# y entonces publica un SOCKS5 en el VPS cuyo extremo de salida
# es este aparato. El movil abre la conexion hacia fuera (no
# necesita puertos abiertos ni IP fija) y el VPS obtiene una
# salida residencial en 127.0.0.1:<puerto>.
#
# Limite real y conocido: SSH transporta TCP. UDP e ICMP no
# viajan por aqui. En el VPS hace falta redsocks para empujar
# el trafico marcado hacia ese SOCKS.
# =========================================================

NODE_SSH_KEY=""   # se fija en socks_paths

socks_paths() {
    NODE_SSH_KEY="${NODE_HOME}/ssh_node_key"
}

socks_generate_key() {
    socks_paths
    mkdir -p "$NODE_HOME" 2>/dev/null
    chmod 700 "$NODE_HOME" 2>/dev/null
    if [ ! -f "$NODE_SSH_KEY" ]; then
        ssh-keygen -t ed25519 -N "" -C "wghome-node@${CFG_DEVICE:-nodo}" -f "$NODE_SSH_KEY" &>/dev/null || return 1
        chmod 600 "$NODE_SSH_KEY"
        _node_log "Clave SSH del nodo generada"
    fi
    return 0
}

# Comprobacion previa: sin remote dynamic forwarding el modo B
# no funciona, y fallar aqui con un mensaje claro ahorra media
# hora de depuracion a ciegas contra un tunel que nunca levanta.
socks_check_ssh_version() {
    local v
    v=$(ssh -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | head -1 | cut -d_ -f2)
    [ -z "$v" ] && return 0
    local maj min
    maj=${v%%.*}; min=${v##*.}
    if [ "${maj:-0}" -gt 7 ] 2>/dev/null; then return 0; fi
    if [ "${maj:-0}" -eq 7 ] && [ "${min:-0}" -ge 6 ] 2>/dev/null; then return 0; fi
    return 1
}

socks_ssh_cmd() {
    socks_paths
    # -v no es ruido gratuito: es la unica forma de saber que el
    # reenvio remoto quedo realmente publicado. Sin ese dato solo
    # sabriamos que el proceso vive, que no es lo mismo.
    echo "ssh -v -N -T -i ${NODE_SSH_KEY} -p ${CFG_VPS_PORT} \
-o ExitOnForwardFailure=yes \
-o ConnectTimeout=15 \
-o ServerAliveInterval=25 \
-o ServerAliveCountMax=3 \
-o StrictHostKeyChecking=accept-new \
-o UserKnownHostsFile=${NODE_HOME}/known_hosts \
-o TCPKeepAlive=yes \
-R 127.0.0.1:${CFG_SOCKS_PORT} \
${CFG_SSH_USER}@${CFG_VPS_HOST}"
}

socks_is_up() {
    pgrep -f -- "-R 127.0.0.1:${CFG_SOCKS_PORT} ${CFG_SSH_USER}@${CFG_VPS_HOST}" &>/dev/null
}

socks_tunnel_up() {
    local quiet="${1:-}"
    socks_paths
    if socks_is_up; then
        [ -z "$quiet" ] && ui_warn "El tunel SOCKS ya estaba activo."
        return 0
    fi
    [ -f "$NODE_SSH_KEY" ] || { [ -z "$quiet" ] && ui_err "Falta la clave SSH. Reconfigura (opcion 1)."; return 1; }

    # En Android el sistema duerme la CPU y mata el proceso a los
    # pocos minutos de apagar la pantalla; el wake lock lo evita.
    command -v termux-wake-lock &>/dev/null && termux-wake-lock &>/dev/null

    # El log se vacia en cada intento: lo que interesa es si ESTE
    # arranque publico el reenvio, no lo que paso hace dos horas.
    : > "${NODE_HOME}/ssh.log"
    nohup $(socks_ssh_cmd) >>"${NODE_HOME}/ssh.log" 2>&1 &
    local pid=$!

    # Que el proceso siga vivo no significa que haya conectado:
    # puede estar aun en el saludo TCP contra un host inalcanzable.
    # Se espera a la confirmacion explicita del reenvio remoto.
    local waited=0
    while [ "$waited" -lt 25 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            [ -z "$quiet" ] && {
                ui_err "SSH termino antes de establecer el tunel:"
                grep -iE 'denied|refused|timed out|unreachable|failed|error' "${NODE_HOME}/ssh.log" 2>/dev/null | tail -n 3 | sed 's/^/      /'
            }
            _node_log "Tunel SOCKS fallido: ssh termino durante el arranque"
            return 1
        fi
        if grep -q "remote forward success" "${NODE_HOME}/ssh.log" 2>/dev/null; then
            _node_log "Tunel SOCKS establecido (SOCKS5 en 127.0.0.1:${CFG_SOCKS_PORT} del VPS)"
            [ -z "$quiet" ] && ui_ok "Tunel SOCKS activo — SOCKS5 en 127.0.0.1:${CFG_SOCKS_PORT} del VPS."
            return 0
        fi
        sleep 1
        waited=$((waited+1))
    done

    # Ni murio ni confirmo: se corta en vez de dejar un proceso
    # zombi que el menu mostraria como ON sin estarlo.
    kill "$pid" 2>/dev/null
    _node_log "Tunel SOCKS sin confirmar tras ${waited}s — intento abortado"
    [ -z "$quiet" ] && {
        ui_err "El VPS no confirmo el reenvio en ${waited}s."
        tail -n 3 "${NODE_HOME}/ssh.log" 2>/dev/null | sed 's/^/      /'
    }
    return 1
}

socks_tunnel_down() {
    local quiet="${1:-}"
    pkill -f -- "-R 127.0.0.1:${CFG_SOCKS_PORT} ${CFG_SSH_USER}@${CFG_VPS_HOST}" &>/dev/null
    command -v termux-wake-unlock &>/dev/null && termux-wake-unlock &>/dev/null
    _node_log "Tunel SOCKS detenido"
    [ -z "$quiet" ] && ui_ok "Tunel SOCKS detenido."
}

# Receta para el otro extremo. El VPS ya sabe marcar el trafico
# de los usuarios con fwmark 0x77 (wg_home.sh); lo que le falta
# en modo B es a donde mandar esa marca, porque no hay 10.77.77.2.
socks_vps_recipe() {
    cat <<EOF
# =========================================================
# LADO VPS — modo SOCKS (sin root en el nodo)
# Ejecutar en el VPS como root, una sola vez.
# =========================================================

# 1) Autorizar la clave del nodo
#    Se resuelve el home real del usuario: root vive en /root,
#    no en /home/root, y dar por hecho lo segundo rompe el paso.
U="${CFG_SSH_USER}"
H=\$(getent passwd "\$U" | cut -d: -f6)
mkdir -p "\$H/.ssh" && chmod 700 "\$H/.ssh"
echo '$(cat "${NODE_SSH_KEY}.pub" 2>/dev/null)' >> "\$H/.ssh/authorized_keys"
chmod 600 "\$H/.ssh/authorized_keys"
chown -R "\$U":"\$U" "\$H/.ssh"

# 2) sshd debe permitir el reenvio (suele venir activo)
grep -q '^AllowTcpForwarding yes' /etc/ssh/sshd_config || echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd

# 3) redsocks traduce "trafico marcado" -> "conexion SOCKS5"
apt-get install -y redsocks
cat > /etc/redsocks.conf <<'RS'
base { log_debug = off; log_info = on; daemon = on; redirector = iptables; }
redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = ${CFG_SOCKS_PORT};
    type = socks5;
}
RS
systemctl restart redsocks && systemctl enable redsocks

# 4) Desviar hacia redsocks lo que el panel marca con 0x77
#    (misma marca que usa wg_home.sh para el policy routing)
iptables -t nat -N HOMEVPN_SOCKS 2>/dev/null
iptables -t nat -F HOMEVPN_SOCKS
iptables -t nat -A HOMEVPN_SOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A HOMEVPN_SOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A HOMEVPN_SOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A HOMEVPN_SOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A HOMEVPN_SOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A HOMEVPN_SOCKS -p tcp -j REDIRECT --to-ports 12345
iptables -t nat -A OUTPUT -p tcp -m mark --mark 0x77 -j HOMEVPN_SOCKS

# 5) Persistir las reglas: sin esto se pierden al reiniciar
apt-get install -y iptables-persistent netfilter-persistent 2>/dev/null
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4

# =========================================================
# LIMITES DE ESTE MODO — leelos antes de dar por hecho nada
# =========================================================
# · Solo viaja TCP. SSH no transporta datagramas, asi que el
#   DNS por UDP seguira saliendo con la IP del VPS. Si quieres
#   que el DNS tambien salga por la residencial, fuerza a los
#   clientes a resolver por TCP o usa un resolver DoT/DoH.
# · No hay ICMP: un ping desde el VPS no viajara por el nodo.
# · El rendimiento depende de la subida del movil, y SSH añade
#   su propio cifrado sobre el de TLS: espera menos caudal que
#   en modo WireGuard.
EOF
}

# =========================================================
# CAPA UNIFICADA — el menu no necesita saber en que modo esta
# =========================================================
node_link_is_up() {
    case "$CFG_MODE" in
        wireguard) wg_is_up && wg_peer_configured ;;
        socks)     socks_is_up ;;
        *)         return 1 ;;
    esac
}

node_link_up() {
    local quiet="${1:-}"
    case "$CFG_MODE" in
        wireguard)
            wg_tunnel_up "$quiet" || return 1
            nat_on "$quiet"
            ;;
        socks)
            socks_tunnel_up "$quiet" || return 1
            ;;
        *) return 1 ;;
    esac
}

node_link_down() {
    local quiet="${1:-}"
    case "$CFG_MODE" in
        wireguard) wg_tunnel_down "$quiet" ;;
        socks)     socks_tunnel_down "$quiet" ;;
    esac
}

# Salud real del enlace, no solo "el proceso existe".
node_link_healthy() {
    case "$CFG_MODE" in
        wireguard) wg_is_up && wg_has_handshake ;;
        socks)     socks_is_up ;;
        *) return 1 ;;
    esac
}

# =========================================================
# GUARDIAN
# ---------------------------------------------------------
# Un movil cambia de wifi a datos, pierde cobertura en el
# ascensor y el sistema le mata procesos. Levantar el tunel una
# vez al arrancar no basta: hace falta alguien que lo vuelva a
# levantar cada vez que se cae, y que renueve el NAT cuando la
# interfaz de salida cambia de nombre.
# =========================================================
NODE_GUARD_INTERVAL="30"

node_guardian_loop() {
    _node_log "Guardian iniciado (modo ${CFG_MODE}, pid $$)"
    echo $$ > "$NODE_PIDFILE" 2>/dev/null

    local last_uplink=""
    while true; do
        if ! node_link_is_up; then
            _node_log "Enlace caido — reintentando"
            node_link_up quiet
        elif [ "$CFG_MODE" = "wireguard" ]; then
            local age
            age=$(wg_handshake_age)
            # -1 = nunca hubo saludo. Damos margen a que el VPS
            # registre la clave antes de empezar a reciclar.
            if [ "$age" -gt 240 ] 2>/dev/null; then
                _node_log "Sin handshake desde hace ${age}s — reiniciando tunel"
                wg_tunnel_down quiet
                sleep 2
                node_link_up quiet
            fi

            # Si el aparato cambio de wifi a datos, el MASQUERADE
            # apuntaba a una interfaz que ya no sale a ningun lado.
            local up
            up=$(_node_uplink_iface)
            if [ -n "$up" ] && [ "$up" != "$last_uplink" ]; then
                [ -n "$last_uplink" ] && _node_log "Salida cambiada: ${last_uplink} -> ${up}"
                nat_off quiet
                nat_on quiet
                last_uplink="$up"
            fi
        fi
        sleep "$NODE_GUARD_INTERVAL"
    done
}

node_guardian_is_running() {
    [ -f "$NODE_PIDFILE" ] || return 1
    local pid
    pid=$(cat "$NODE_PIDFILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # El sistema recicla PIDs: que exista un proceso con ese numero no
    # significa que sea el nuestro. Se confirma con la linea de comandos.
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q -- "--guardian" || return 1
    fi
    return 0
}

node_guardian_start() {
    node_guardian_is_running && return 0
    command -v termux-wake-lock &>/dev/null && termux-wake-lock &>/dev/null
    nohup bash "$NODE_SELF" --guardian >>"${NODE_HOME}/guardian.log" 2>&1 &
    sleep 1
    node_guardian_is_running
}

node_guardian_stop() {
    if [ -f "$NODE_PIDFILE" ]; then
        local pid
        pid=$(cat "$NODE_PIDFILE" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$NODE_PIDFILE"
    fi
    pkill -f "$(basename "$NODE_SELF") --guardian" &>/dev/null
}

# =========================================================
# ARRANQUE AUTOMATICO
# ---------------------------------------------------------
# Cada familia de aparato tiene su propio mecanismo y ninguno
# sirve para el resto: systemd en el PC y la VM, Termux:Boot en
# el movil sin root, service.d de Magisk con root, cron @reboot
# como red de seguridad en sistemas sin systemd.
# =========================================================
NODE_SYSTEMD_UNIT="/etc/systemd/system/wghome-node.service"
NODE_BOOT_DIR="${HOME}/.termux/boot"
NODE_BOOT_FILE="${NODE_BOOT_DIR}/10-wghome-node.sh"
NODE_MAGISK_FILE="/data/adb/service.d/wghome-node.sh"

autostart_is_on() {
    case "$DEV_INIT" in
        systemd)     _root_run "systemctl is-enabled wghome-node.service 2>/dev/null" 2>/dev/null | grep -q enabled ;;
        termux-boot) [ -f "$NODE_BOOT_FILE" ] ;;
        magisk)      _root_run "test -f ${NODE_MAGISK_FILE}" &>/dev/null || [ -f "$NODE_BOOT_FILE" ] ;;
        cron)        crontab -l 2>/dev/null | grep -q "wghome-node" ;;
        *)           return 1 ;;
    esac
}

autostart_enable() {
    mkdir -p "$NODE_HOME" 2>/dev/null
    case "$DEV_INIT" in
        systemd)
            local unit
            unit=$(cat <<EOF
[Unit]
Description=Nodo de salida residencial (wg-home)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${NODE_SELF} --guardian
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
)
            _root_run "cat > ${NODE_SYSTEMD_UNIT} <<'UNIT'
${unit}
UNIT"
            _root_try "systemctl daemon-reload"
            _root_try "systemctl enable wghome-node.service"
            _root_try "systemctl start wghome-node.service"
            ;;
        termux-boot|magisk)
            # Termux:Boot ejecuta lo que encuentre en ~/.termux/boot
            # al terminar de arrancar el telefono. La app hay que
            # instalarla aparte desde F-Droid; sin ella la carpeta
            # existe pero nadie la lee.
            mkdir -p "$NODE_BOOT_DIR" 2>/dev/null
            cat > "$NODE_BOOT_FILE" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# Arranque del nodo de salida residencial
termux-wake-lock 2>/dev/null
exec bash ${NODE_SELF} --guardian
EOF
            chmod +x "$NODE_BOOT_FILE"

            if [ "$DEV_INIT" = "magisk" ]; then
                # service.d corre en el arranque real, sin depender
                # de que el usuario abra Termux ni desbloquee.
                _root_run "mkdir -p /data/adb/service.d && cat > ${NODE_MAGISK_FILE} <<'MG'
#!/system/bin/sh
# Nodo de salida residencial — espera a que la red este lista
sleep 45
export PATH=${PREFIX:-/data/data/com.termux/files/usr}/bin:\$PATH
${PREFIX:-/data/data/com.termux/files/usr}/bin/bash ${NODE_SELF} --guardian &
MG
chmod 755 ${NODE_MAGISK_FILE}"
            fi
            ;;
        cron)
            (crontab -l 2>/dev/null | grep -v "wghome-node"; echo "@reboot bash ${NODE_SELF} --guardian # wghome-node") | crontab -
            ;;
        *)
            return 1
            ;;
    esac
    CFG_AUTOSTART="on"; node_cfg_save
    _node_log "Arranque automatico activado (${DEV_INIT})"
    return 0
}

autostart_disable() {
    case "$DEV_INIT" in
        systemd)
            _root_try "systemctl disable --now wghome-node.service"
            _root_try "rm -f ${NODE_SYSTEMD_UNIT}"
            _root_try "systemctl daemon-reload"
            ;;
        termux-boot|magisk)
            rm -f "$NODE_BOOT_FILE" 2>/dev/null
            _root_try "rm -f ${NODE_MAGISK_FILE}"
            ;;
        cron)
            crontab -l 2>/dev/null | grep -v "wghome-node" | crontab -
            ;;
    esac
    CFG_AUTOSTART="off"; node_cfg_save
    _node_log "Arranque automatico desactivado"
}

# =========================================================
# PANTALLAS
# =========================================================
node_title() {
    echo ""
    ui_header "NODO · ${NODE_VERSION}"
}

# Recomendacion de modo segun lo que el aparato permite de verdad.
node_recommended_mode() {
    [ "$DEV_CAN_WG" = "yes" ] && echo "wireguard" || echo "socks"
}

node_screen_device() {
    clear; node_title
    ui_section "DISPOSITIVO DETECTADO" "que puede y que no puede hacer este aparato"
    ui_blank
    ui_row2 "Tipo" "${DEV_LABEL}" "Sistema" "${DEV_OS}"
    ui_row2 "Root" "$([ "$DEV_ROOT" = yes ] && echo 'si' || echo 'no')" "Arranque" "${DEV_INIT}"
    if node_is_configured; then
        local origen="asistente"
        [ "$CFG_ADOPTED" = "si" ] && origen="adoptada de un montaje previo"
        ui_row2 "Ya es nodo" "si" "Config" "${origen}"
        [ "$CFG_MODE" = "wireguard" ] && \
            ui_row2 "Conf en uso" "$(basename "${NODE_WGCONF}")" "Gestor" "${CFG_WG_MANAGER:-manual}"
    else
        ui_row2 "Ya es nodo" "no" "Config" "sin configurar"
    fi
    ui_rule
    ui_blank

    if [ "$DEV_CAN_WG" = "yes" ]; then
        ui_ok "Modo WIREGUARD disponible (${DEV_WG_KIND})."
        echo -e "${UI_PAD}${DM}   Salida completa: TCP, UDP e ICMP.${CR}"
    else
        ui_warn "Modo WIREGUARD no disponible ahora mismo."
        if [ "$DEV_ROOT" = "yes" ]; then
            echo -e "${UI_PAD}${DM}   Hay root, pero el kernel no trae WireGuard y no${CR}"
            echo -e "${UI_PAD}${DM}   se encontro wireguard-go para suplirlo.${CR}"
        elif [ "$DEV_KIND" = "termux" ]; then
            echo -e "${UI_PAD}${DM}   Android sin root no deja crear una interfaz TUN ni${CR}"
            echo -e "${UI_PAD}${DM}   tocar iptables. Es un limite del sistema, no de los${CR}"
            echo -e "${UI_PAD}${DM}   paquetes: ni la app oficial de WireGuard puede hacerlo,${CR}"
            echo -e "${UI_PAD}${DM}   porque VpnService solo captura el trafico propio.${CR}"
        else
            echo -e "${UI_PAD}${DM}   Este script no se esta ejecutando como root. En Linux${CR}"
            echo -e "${UI_PAD}${DM}   basta con relanzarlo:  ${WH}sudo bash node.sh${CR}"
        fi
        ui_blank
        ui_ok "Modo SOCKS INVERSO disponible (sin root)."
        echo -e "${UI_PAD}${DM}   Salida solo TCP. Necesita redsocks en el VPS.${CR}"
    fi
    ui_solid
}

# =========================================================
# ASISTENTE DE INSTALACION
# =========================================================
node_install() {
    clear; node_title
    ui_section "CONFIGURAR ESTE NODO" "asistente"
    ui_blank

    if node_is_configured; then
        ui_warn "Ya existe una configuracion previa (modo ${CFG_MODE})."
        if [ "$CFG_ADOPTED" = "si" ]; then
            ui_blank
            ui_warn "Esta configuracion se adopto de un montaje anterior."
            echo -e "${UI_PAD}${DM}   Sus claves son las que el VPS tiene registradas.${CR}"
            echo -e "${UI_PAD}${DM}   Si solo quieres cambiar el host o la clave del VPS,${CR}"
            echo -e "${UI_PAD}${DM}   usa la opcion 6 del menu en lugar de reconfigurar.${CR}"
        fi
        ui_blank
        ui_confirm "¿Sobrescribirla?" "n" || { ui_ok "Sin cambios."; sleep 1; return; }
    fi

    node_screen_device
    ui_blank

    # --- Modo ---
    local rec
    rec=$(node_recommended_mode)
    if [ "$DEV_CAN_WG" = "yes" ]; then
        echo -e "${UI_PAD}${WH}Modo de operacion${CR}"
        ui_opt "1" "WIREGUARD" "recomendado"
        ui_opt "2" "SOCKS INVERSO" "solo TCP"
        ui_blank
        ui_ask "Elige modo [1-2]" "1"
        [ "$REPLY_UI" = "2" ] && CFG_MODE="socks" || CFG_MODE="wireguard"
    else
        CFG_MODE="socks"
        ui_info "Se usara modo SOCKS INVERSO (unico viable aqui)."
    fi

    CFG_DEVICE="${DEV_LABEL} · ${DEV_OS}"
    ui_blank

    if [ "$CFG_MODE" = "wireguard" ]; then
        node_install_wireguard || return 1
    else
        node_install_socks || return 1
    fi

    # --- Arranque automatico ---
    ui_blank
    if ui_confirm "¿Levantar el nodo solo al encender el dispositivo?" "s"; then
        if autostart_enable; then
            ui_ok "Arranque automatico activado via ${DEV_INIT}."
            [ "$DEV_INIT" = "termux-boot" ] && {
                ui_warn "Necesitas la app Termux:Boot instalada desde F-Droid"
                echo -e "${UI_PAD}${DM}   y abierta una vez para que Android la autorice.${CR}"
            }
        else
            ui_err "No se pudo configurar el arranque en este sistema."
        fi
    else
        CFG_AUTOSTART="off"; node_cfg_save
    fi

    # --- Levantar ahora ---
    ui_blank
    if ui_confirm "¿Conectar ahora con el VPS?" "s"; then
        node_link_up
        node_guardian_start && ui_ok "Guardian de conexion en marcha."
    fi

    ui_pause
}

node_install_wireguard() {
    ui_info "Preparando modo WireGuard..."
    _node_ensure_wg_tools || { ui_err "No se pudo instalar wireguard-tools."; ui_pause; return 1; }

    # Reconfigurar es empezar de cero: se sueltan los punteros de
    # cualquier adopcion previa y se vuelve a nuestras rutas.
    CFG_ADOPTED="no"; CFG_WG_CONF=""; CFG_WG_MANAGER="manual"
    _node_reset_paths

    CFG_VPS_PORT="$NODE_DEFAULT_PORT"
    ui_blank
    echo -e "${UI_PAD}${DM}Datos del VPS. Los encuentras en el panel:${CR}"
    echo -e "${UI_PAD}${DM}GATEWAY RESIDENCIAL ▸ [5] CLAVE PUBLICA DEL VPS${CR}"
    ui_blank

    ui_ask "IP publica o dominio del VPS" "$CFG_VPS_HOST"
    CFG_VPS_HOST="$REPLY_UI"
    [ -z "$CFG_VPS_HOST" ] && { ui_err "Sin host no hay nodo."; ui_pause; return 1; }

    ui_ask "Puerto WireGuard del VPS" "$NODE_DEFAULT_PORT"
    CFG_VPS_PORT="$REPLY_UI"

    ui_ask "Clave publica del VPS" "$CFG_VPS_PUBKEY"
    CFG_VPS_PUBKEY="$REPLY_UI"
    if ! echo "$CFG_VPS_PUBKEY" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
        ui_warn "Esa clave no tiene el formato base64 de 44 caracteres."
        ui_confirm "¿Continuar igualmente?" "n" || { ui_pause; return 1; }
    fi

    if ! wg_generate_keys; then
        ui_pause; return 1
    fi
    node_cfg_save
    wg_write_conf
    _node_log "Nodo configurado en modo WireGuard contra ${CFG_VPS_HOST}"

    ui_blank
    ui_ok "Configuracion escrita en ${NODE_WGCONF}"
    node_show_pubkey_inline
    return 0
}

node_install_socks() {
    ui_info "Preparando modo SOCKS inverso..."
    _node_ensure_ssh || { ui_err "No se pudo instalar el cliente SSH."; ui_pause; return 1; }

    if ! socks_check_ssh_version; then
        ui_err "Tu OpenSSH es anterior a 7.6 y no soporta SOCKS remoto."
        echo -e "${UI_PAD}${DM}   Actualiza el paquete openssh antes de seguir.${CR}"
        ui_pause; return 1
    fi

    ui_blank
    ui_ask "IP publica o dominio del VPS" "$CFG_VPS_HOST"
    CFG_VPS_HOST="$REPLY_UI"
    [ -z "$CFG_VPS_HOST" ] && { ui_err "Sin host no hay nodo."; ui_pause; return 1; }

    ui_ask "Puerto SSH del VPS" "${CFG_VPS_PORT:-22}"
    CFG_VPS_PORT="$REPLY_UI"

    ui_ask "Usuario SSH del VPS" "${CFG_SSH_USER:-root}"
    CFG_SSH_USER="$REPLY_UI"

    ui_ask "Puerto SOCKS a publicar en el VPS" "${CFG_SOCKS_PORT:-1080}"
    CFG_SOCKS_PORT="$REPLY_UI"

    socks_generate_key || { ui_err "No se pudo generar la clave SSH."; ui_pause; return 1; }
    node_cfg_save
    _node_log "Nodo configurado en modo SOCKS contra ${CFG_SSH_USER}@${CFG_VPS_HOST}"

    # La receta se deja en disco: es larga y hay que copiarla al VPS.
    socks_vps_recipe > "${NODE_HOME}/vps-setup.txt"
    chmod 600 "${NODE_HOME}/vps-setup.txt"

    ui_blank
    ui_ok "Clave SSH del nodo generada."
    ui_blank
    echo -e "${UI_PAD}${YL}Copia esta linea en el VPS (~/.ssh/authorized_keys):${CR}"
    ui_blank
    echo -e "${UI_PAD}${WH}$(cat "${NODE_SSH_KEY}.pub" 2>/dev/null)${CR}"
    ui_blank
    ui_info "Receta completa del VPS guardada en:"
    echo -e "${UI_PAD}${DM}   ${NODE_HOME}/vps-setup.txt${CR}"
    echo -e "${UI_PAD}${DM}   (opcion 5 del menu la vuelve a mostrar)${CR}"
    return 0
}

node_show_pubkey_inline() {
    ui_blank
    echo -e "${UI_PAD}${YL}Registra esta clave en el VPS:${CR}"
    echo -e "${UI_PAD}${DM}GATEWAY RESIDENCIAL ▸ [6] REGISTRAR CLAVE DEL PC${CR}"
    ui_blank
    echo -e "${UI_PAD}${WH}$(cat "$NODE_PUB" 2>/dev/null)${CR}"
    ui_blank
}

node_screen_pubkey() {
    clear; node_title
    ui_section "CLAVE PUBLICA DE ESTE NODO" "para registrarla en el VPS"
    ui_blank

    if [ "$CFG_MODE" = "socks" ]; then
        socks_paths
        if [ -f "${NODE_SSH_KEY}.pub" ]; then
            echo -e "${UI_PAD}${DM}Clave SSH — va en ~/.ssh/authorized_keys del VPS:${CR}"
            ui_blank
            echo -e "${UI_PAD}${WH}$(cat "${NODE_SSH_KEY}.pub")${CR}"
            ui_blank
            ui_rule
            ui_info "Receta completa para el VPS:"
            echo -e "${UI_PAD}${DM}   ${NODE_HOME}/vps-setup.txt${CR}"
            ui_blank
            if ui_confirm "¿Mostrarla en pantalla?" "n"; then
                echo ""
                cat "${NODE_HOME}/vps-setup.txt" 2>/dev/null | sed 's/^/  /'
            fi
        else
            ui_err "No hay clave SSH. Reconfigura con la opcion 1."
        fi
    else
        wg_ensure_public_key >/dev/null 2>&1
        if [ -f "$NODE_PUB" ]; then
            ui_row2 "Este nodo" "$NODE_SELF_WGIP" "VPS" "$NODE_VPS_WGIP"
            ui_blank
            echo -e "${UI_PAD}${DM}Panel del VPS ▸ GATEWAY RESIDENCIAL ▸ [6]${CR}"
            ui_blank
            echo -e "${UI_PAD}${WH}$(cat "$NODE_PUB")${CR}"
            ui_blank
            ui_warn "La clave privada nunca sale de este dispositivo."
        else
            ui_err "No hay claves. Reconfigura con la opcion 1."
        fi
    fi
    ui_solid
    ui_pause
}

# =========================================================
# DIAGNOSTICO
# ---------------------------------------------------------
# Cinco comprobaciones en el mismo orden en que fallan las
# cosas: paquetes, enlace, saludo, alcance y salida real.
# =========================================================
node_diagnose() {
    clear; node_title
    ui_section "DIAGNOSTICO" "cinco comprobaciones en cadena"
    ui_blank

    local ok=0 fail=0
    _chk_ok()   { ui_ok   "$1"; ok=$((ok+1)); }
    _chk_fail() { ui_err  "$1"; fail=$((fail+1)); }

    # 1 — Herramientas
    if [ "$CFG_MODE" = "wireguard" ]; then
        command -v wg &>/dev/null && _chk_ok "1/5 wireguard-tools presente." \
                                  || _chk_fail "1/5 falta el comando 'wg'."
    else
        command -v ssh &>/dev/null && _chk_ok "1/5 cliente SSH presente." \
                                   || _chk_fail "1/5 falta el comando 'ssh'."
    fi

    # 2 — Enlace levantado
    if [ "$CFG_MODE" = "wireguard" ]; then
        if wg_is_up && wg_peer_configured; then
            _chk_ok "2/5 interfaz ${NODE_IFACE} activa y con peer."
        elif wg_is_up; then
            _chk_fail "2/5 la interfaz existe pero NO tiene peer configurado."
            echo -e "${UI_PAD}${DM}     Sube el tunel de nuevo (opcion 2): se repara solo.${CR}"
        else
            _chk_fail "2/5 la interfaz ${NODE_IFACE} no existe."
        fi
    elif node_link_is_up; then
        _chk_ok "2/5 enlace activo."
    else
        _chk_fail "2/5 el enlace esta caido."
    fi

    # 3 — Conversacion con el VPS
    if [ "$CFG_MODE" = "wireguard" ]; then
        local age
        age=$(wg_handshake_age)
        if [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt 180 ]; then
            _chk_ok "3/5 handshake hace ${age}s."
        elif [ "$age" -ge 0 ] 2>/dev/null; then
            _chk_fail "3/5 ultimo handshake hace ${age}s (obsoleto)."
        else
            _chk_fail "3/5 nunca hubo handshake."
            # Aqui esta la explicacion del sintoma clasico. El VPS no
            # lleva Endpoint en su bloque [Peer] — no puede llevarlo,
            # porque este equipo esta tras CGNAT y no tiene IP fija.
            # Solo aprende donde estamos cuando NOSOTROS le hablamos.
            echo -e "${UI_PAD}${DM}     Mientras no haya handshake, el VPS no sabe donde${CR}"
            echo -e "${UI_PAD}${DM}     estas y su 'ping 10.77.77.2' NO puede funcionar.${CR}"
            local tr rx tx
            tr=$(wg_transfer); rx=$(echo "$tr" | awk '{print $1}'); tx=$(echo "$tr" | awk '{print $2}')
            if [ -n "$tx" ] && [ "$tx" != "0" ] && [ "${rx:-0}" = "0" ]; then
                echo -e "${UI_PAD}${RD}     Salen datos (${tx}) y no vuelve nada (${rx}).${CR}"
                echo -e "${UI_PAD}${DM}     Eso apunta a UDP ${CFG_VPS_PORT} bloqueado en el VPS${CR}"
                echo -e "${UI_PAD}${DM}     (UFW o cortafuegos de DigitalOcean) o a que la${CR}"
                echo -e "${UI_PAD}${DM}     clave publica registrada alli no es la de este nodo.${CR}"
            elif [ "${tx:-0}" = "0" ]; then
                echo -e "${UI_PAD}${DM}     No sale ni un byte: revisa el peer y el endpoint.${CR}"
            fi
        fi
    else
        if socks_is_up; then
            _chk_ok "3/5 sesion SSH sostenida."
        else
            _chk_fail "3/5 la sesion SSH no esta viva."
        fi
    fi

    # 4 — Alcance del otro extremo
    if [ "$CFG_MODE" = "wireguard" ]; then
        if ! wg_endpoint_known; then
            _chk_fail "4/5 la interfaz no tiene endpoint del VPS resuelto."
            echo -e "${UI_PAD}${DM}     Revisa que ${CFG_VPS_HOST}:${CFG_VPS_PORT} sea correcto.${CR}"
        elif ping -c 2 -W 3 "$NODE_VPS_WGIP" &>/dev/null; then
            _chk_ok "4/5 el VPS responde en ${NODE_VPS_WGIP}."
        else
            _chk_fail "4/5 sin respuesta de ${NODE_VPS_WGIP}."
        fi
    else
        if timeout 8 bash -c "</dev/tcp/${CFG_VPS_HOST}/${CFG_VPS_PORT}" &>/dev/null; then
            _chk_ok "4/5 puerto SSH ${CFG_VPS_PORT} alcanzable."
        else
            _chk_fail "4/5 no se alcanza ${CFG_VPS_HOST}:${CFG_VPS_PORT}."
        fi
    fi

    # 5 — Puerta hacia Internet
    if [ "$CFG_MODE" = "wireguard" ]; then
        local fwd
        fwd=$(_root_run "sysctl -n net.ipv4.ip_forward 2>/dev/null" 2>/dev/null | tr -dc '0-9')
        if [ "$fwd" = "1" ] && nat_is_active; then
            _chk_ok "5/5 reenvio y NAT activos hacia $(_node_uplink_iface)."
        elif [ "$fwd" != "1" ]; then
            _chk_fail "5/5 ip_forward apagado: el VPS no navegara."
        else
            _chk_fail "5/5 falta la regla MASQUERADE."
        fi
    else
        if [ -f "${NODE_HOME}/vps-setup.txt" ]; then
            _chk_ok "5/5 receta del VPS generada (verifica redsocks alli)."
        else
            _chk_fail "5/5 falta la receta del VPS."
        fi
    fi

    ui_blank
    ui_rule
    echo -e "${UI_PAD}$(ui_cell "Correctas" "$ok" 20 "$GR")${DM}▸${CR} $(ui_cell "Fallidas" "$fail" 20 "$RD")"

    if [ "$CFG_MODE" = "wireguard" ] && wg_is_up; then
        ui_blank
        echo -e "${UI_PAD}${YL}── Estado WireGuard ──${CR}"
        _root_run "wg show ${NODE_IFACE} 2>/dev/null" 2>/dev/null | sed 's/^/    /'
    fi

    ui_solid
    ui_pause
}

node_check_ip() {
    clear; node_title
    ui_section "IP DE SALIDA" "la que veran los destinos"
    ui_blank

    ui_info "Consultando IP publica de este dispositivo..."
    local ip=""
    if command -v curl &>/dev/null; then
        ip=$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null)
    elif command -v wget &>/dev/null; then
        ip=$(wget -qO- --timeout=8 https://api.ipify.org 2>/dev/null)
    else
        ui_warn "No hay curl ni wget para consultar la IP."
    fi
    ui_blank

    if [ -n "$ip" ]; then
        echo -e "${UI_PAD}$(ui_cell "IP residencial" "$ip" 30 "$GR")"
    else
        echo -e "${UI_PAD}$(ui_cell "IP residencial" "sin respuesta" 30 "$RD")"
    fi
    echo -e "${UI_PAD}$(ui_cell "Salida por" "$(_node_uplink_iface || echo 'sin red')" 30 "$CY")"
    ui_blank
    ui_rule
    echo -e "${UI_PAD}${DM}Esta debe ser la misma que muestra el panel del VPS${CR}"
    echo -e "${UI_PAD}${DM}en GATEWAY RESIDENCIAL ▸ [11] VER IP DE SALIDA${CR}"
    echo -e "${UI_PAD}${DM}cuando la salida residencial esta activada.${CR}"
    ui_solid
    ui_pause
}

node_show_log() {
    clear; node_title
    ui_section "REGISTRO" "ultimos 25 eventos"
    ui_blank
    if [ -f "$NODE_LOG" ]; then
        tail -n 25 "$NODE_LOG" | sed 's/^/  /'
    else
        ui_warn "Todavia no hay registro."
    fi
    ui_solid
    ui_pause
}

node_remove() {
    clear; node_title
    ui_section "ELIMINAR CONFIGURACION" "borrado definitivo"
    ui_blank
    ui_warn "Se retiran el tunel, las reglas, el arranque y las claves."
    ui_blank
    ui_confirm "¿Seguro?" "n" || { ui_ok "Cancelado."; sleep 1; return; }
    ui_confirm "Confirma otra vez: esto borra las claves" "n" || { ui_ok "Cancelado."; sleep 1; return; }

    node_guardian_stop
    node_link_down quiet
    autostart_disable
    rm -rf "$NODE_HOME" 2>/dev/null

    ui_blank
    ui_ok "Nodo eliminado de este dispositivo."
    ui_warn "Recuerda quitar el peer tambien en el panel del VPS."
    ui_pause
}

# =========================================================
# MENU PRINCIPAL
# =========================================================
node_menu() {
    while true; do
        clear; node_title
        ui_section "NODO DE SALIDA RESIDENCIAL" "contraparte del gateway del VPS"
        ui_blank

        local TAG_LINK TAG_AUTO TAG_GUARD modo_txt
        node_link_is_up      && TAG_LINK="$(ui_tag_str on)"  || TAG_LINK="$(ui_tag_str off)"
        autostart_is_on      && TAG_AUTO="$(ui_tag_str on)"  || TAG_AUTO="$(ui_tag_str off)"
        node_guardian_is_running && TAG_GUARD="$(ui_tag_str on)" || TAG_GUARD="$(ui_tag_str off)"

        [ "$CFG_MODE" = "wireguard" ] && modo_txt="WireGuard" || modo_txt="SOCKS inverso"

        [ "$CFG_ADOPTED" = "si" ] && modo_txt="${modo_txt} (adoptado)"
        ui_row2 "Dispositivo" "${DEV_LABEL}" "Modo" "${modo_txt}"
        local up_now
        up_now=$(_node_uplink_iface)
        ui_row2 "VPS" "${CFG_VPS_HOST:-sin definir}" "Salida" "${up_now:-sin red}"

        if [ "$CFG_MODE" = "wireguard" ]; then
            local age agetxt
            age=$(wg_handshake_age)
            if [ "$age" -ge 0 ] 2>/dev/null; then agetxt="hace ${age}s"; else agetxt="nunca"; fi
            ui_row2 "Handshake" "${agetxt}" "NAT" "$(nat_is_active && echo activo || echo inactivo)"
        fi
        ui_rule

        # Si la config no da para levantar el tunel, decirlo aqui y
        # no dentro de tres opciones: es lo primero que el usuario
        # necesita saber al abrir el panel.
        if ! node_config_is_sane; then
            ui_blank
            ui_err "Esta configuracion NO puede levantar el tunel."
            if [ ! -s "$NODE_PRIV" ] && [ -z "$(_wg_conf_get "$NODE_WGCONF" "PrivateKey")" ]; then
                echo -e "${UI_PAD}${DM}   Falta la clave privada de este nodo.${CR}"
            else
                echo -e "${UI_PAD}${DM}   Faltan la clave publica o el host del VPS.${CR}"
            fi
            echo -e "${UI_PAD}${WH}   Usa la opcion [1] para reconfigurar desde cero.${CR}"
            echo -e "${UI_PAD}${DM}   Generara claves nuevas: habra que registrarlas${CR}"
            echo -e "${UI_PAD}${DM}   en el panel del VPS con su opcion [6].${CR}"
        fi
        ui_blank

        echo -e "${UI_PAD}${YL}── ENLACE ──${CR}"
        ui_opt "1" "CONFIGURAR NODO"   "asistente"
        ui_opt "2" "CONEXION AL VPS"   "activar/apagar" "$TAG_LINK"
        ui_opt "3" "ARRANQUE AL ENCENDER" "persistencia" "$TAG_AUTO"
        ui_opt "4" "GUARDIAN"          "reconecta solo" "$TAG_GUARD"
        ui_blank
        echo -e "${UI_PAD}${YL}── VINCULACION ──${CR}"
        ui_opt "5" "CLAVE DE ESTE NODO" "para el VPS"
        ui_opt "6" "CAMBIAR DATOS DEL VPS" "host y clave"
        ui_blank
        echo -e "${UI_PAD}${YL}── DIAGNOSTICO ──${CR}"
        ui_opt "7" "DIAGNOSTICO"       "5 comprobaciones"
        ui_opt "8" "VER IP DE SALIDA"  "la de tu casa"
        ui_opt "9" "REGISTRO"          "ultimos eventos"
        ui_opt "10" "DATOS DEL EQUIPO" "que soporta"
        ui_blank
        ui_opt_danger "11" "ELIMINAR NODO" "borra todo"
        ui_opt "0" "SALIR"
        ui_solid
        ui_prompt "Elige una opcion [0-11]"

        case "$REPLY_UI" in
            1)  node_install ;;
            2)  if node_link_is_up; then
                    node_guardian_stop
                    node_link_down
                    sleep 1
                else
                    node_link_up
                    node_guardian_start
                    sleep 1
                fi ;;
            3)  if autostart_is_on; then autostart_disable; ui_ok "Arranque automatico apagado."
                else autostart_enable && ui_ok "Arranque automatico encendido." || ui_err "No disponible aqui."
                fi; sleep 1 ;;
            4)  if node_guardian_is_running; then node_guardian_stop; ui_ok "Guardian detenido."
                else node_guardian_start && ui_ok "Guardian en marcha." || ui_err "No arranco."
                fi; sleep 1 ;;
            5)  node_screen_pubkey ;;
            6)  clear; node_title
                ui_section "DATOS DEL VPS" "reconfigurar sin perder las claves"
                ui_blank
                if [ "$CFG_MODE" = "wireguard" ]; then
                    ui_ask "IP o dominio del VPS" "$CFG_VPS_HOST"; CFG_VPS_HOST="$REPLY_UI"
                    ui_ask "Puerto WireGuard" "$CFG_VPS_PORT";     CFG_VPS_PORT="$REPLY_UI"
                    ui_ask "Clave publica del VPS" "$CFG_VPS_PUBKEY"; CFG_VPS_PUBKEY="$REPLY_UI"
                    node_cfg_save; wg_write_conf
                    ui_blank; ui_ok "Datos actualizados."
                    if node_link_is_up && ui_confirm "¿Reiniciar el tunel para aplicarlos?" "s"; then
                        node_link_down quiet; node_link_up
                    fi
                else
                    ui_ask "IP o dominio del VPS" "$CFG_VPS_HOST"; CFG_VPS_HOST="$REPLY_UI"
                    ui_ask "Puerto SSH" "$CFG_VPS_PORT";           CFG_VPS_PORT="$REPLY_UI"
                    ui_ask "Usuario SSH" "$CFG_SSH_USER";          CFG_SSH_USER="$REPLY_UI"
                    ui_ask "Puerto SOCKS en el VPS" "$CFG_SOCKS_PORT"; CFG_SOCKS_PORT="$REPLY_UI"
                    node_cfg_save
                    socks_vps_recipe > "${NODE_HOME}/vps-setup.txt"
                    ui_blank; ui_ok "Datos actualizados."
                fi
                ui_pause ;;
            7)  node_diagnose ;;
            8)  node_check_ip ;;
            9)  node_show_log ;;
            10) node_screen_device; ui_pause ;;
            11) node_remove
                node_is_configured || return 0 ;;
            0)  clear; return 0 ;;
            *)  ui_err "Opcion no valida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# PUNTO DE ENTRADA
# ---------------------------------------------------------
# --guardian : bucle de reconexion, lo llaman systemd/Termux:Boot
# --up/--down: control directo desde scripts
# sin flags  : si ya hay configuracion la adopta y abre el menu;
#              si no la hay, lanza el asistente una sola vez.
# =========================================================
# En Linux, quedarse sin root degrada el nodo a modo SOCKS sin que
# el usuario se entere. Antes de que eso pase se le avisa y se le
# ofrece relanzar con sudo, que es lo que casi siempre queria.
_node_offer_sudo() {
    [ "$DEV_ROOT" = "yes" ] && return 0
    [ "$DEV_KIND" = "termux" ] && return 0
    command -v sudo &>/dev/null || return 0

    clear; node_title
    ui_section "SE RECOMIENDA ROOT" "para el modo WireGuard completo"
    ui_blank
    ui_warn "Estas ejecutando el script como usuario normal."
    echo -e "${UI_PAD}${DM}   Sin root este nodo solo podra usar SOCKS inverso (TCP).${CR}"
    echo -e "${UI_PAD}${DM}   Con root puede ser un peer WireGuard completo.${CR}"
    ui_blank
    if ui_confirm "¿Relanzar con sudo?" "s"; then
        exec sudo bash "$NODE_SELF" "$@"
    fi
}

node_main() {
    _node_detect

    # Las llamadas no interactivas no deben crear nada: --help y
    # --status se ejecutan a menudo desde scripts ajenos y dejarian
    # un directorio de configuracion vacio a su paso.
    case "${1:-}" in
        --guardian)
            node_cfg_load || { _node_log "Guardian abortado: sin configuracion"; exit 1; }
            node_guardian_loop
            exit 0 ;;
        --up)
            node_cfg_load || exit 1
            node_link_up quiet; exit $? ;;
        --down)
            node_cfg_load || exit 1
            node_link_down quiet; exit 0 ;;
        --status)
            node_cfg_load || { echo "sin configurar"; exit 1; }
            node_link_healthy && echo "activo (${CFG_MODE})" || echo "caido (${CFG_MODE})"
            exit 0 ;;
        --help|-h)
            echo "Uso: bash node.sh [--guardian|--up|--down|--status]"
            exit 0 ;;
    esac

    mkdir -p "$NODE_HOME" 2>/dev/null

    if node_cfg_load; then
        # Configuracion previa encontrada: se adopta y se entra
        # directo al menu, sin repetir el asistente.
        _node_log "Panel abierto — configuracion existente adoptada (${CFG_MODE})"
        node_menu
    else
        _node_offer_sudo "$@"

        # No hay node.conf, pero eso no significa que el equipo sea
        # virgen: pudo montarse a mano antes de que existiera este
        # script. Se busca la huella del protocolo antes de ofrecer
        # un asistente que generaria claves nuevas y romperia el
        # registro que el VPS ya tiene.
        if _node_scan_existing; then
            if node_screen_adopt; then
                node_cfg_load && node_menu
                return 0
            fi
        fi

        clear; node_title
        ui_section "PRIMER ARRANQUE" "este dispositivo aun no es un nodo"
        ui_blank
        ui_info "No se encontro configuracion previa."
        echo -e "${UI_PAD}${DM}   Buscada en: ${NODE_CONF}${CR}"
        echo -e "${UI_PAD}${DM}   Y tambien en /etc/wireguard (metodo manual).${CR}"
        ui_blank
        ui_pause
        node_install
        node_cfg_load && node_menu
    fi
}

node_main "$@"
