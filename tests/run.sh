#!/bin/bash
# =========================================================
# PRUEBAS DEL NODO
# ---------------------------------------------------------
#   bash tests/run.sh
#
# No hacen falta permisos ni red. Lo que NO cubren: nada que
# dependa de root, de iptables reales, de una interfaz
# WireGuard viva, de Android ni de un VPS. Que esto pase no
# significa que el nodo de salida a Internet.
# =========================================================
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

G="\033[1;32m"; R="\033[1;31m"; Y="\033[1;33m"; D="\033[2;37m"; C="\033[0m"
OK=0; FAIL=0; FAILED=()
ok()   { OK=$((OK+1)); printf "  ${G}✓${C} %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf "  ${R}✗${C} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${D}%s${C}\n" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "esperaba '$3', obtuve '$2'"; }
group(){ printf "\n${Y}── %s ──${C}\n" "$1"; }

group "Sintaxis"
for f in node.sh setup.sh tests/run.sh; do
    [ -f "$f" ] || continue
    if err=$(bash -n "$f" 2>&1); then ok "$f"; else bad "$f" "$err"; fi
done

group "Funciones invocadas pero no definidas"
DEF=$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' node.sh | tr -d '()' | sort -u)
USED=$(grep -hoP '(?<![\w/])(_node_[a-z0-9_]+|node_[a-z0-9_]+|wg_[a-z0-9_]+|_wg_[a-z0-9_]+|socks_[a-z0-9_]+|nat_[a-z0-9_]+|autostart_[a-z0-9_]+|ui_[a-z0-9_]+)(?![\w./])' node.sh | sort -u)
MISSING=""
while read -r fn; do
    [ -z "$fn" ] && continue
    grep -qx "$fn" <<<"$DEF" || MISSING="$MISSING $fn"
done <<<"$USED"
[ -z "$MISSING" ] && ok "todas las funciones internas existen" || bad "funciones sin definir" "$MISSING"

# Cargar node.sh sin que arranque el panel
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed 's/^node_main "\$@"$//' node.sh > "$TMP/lib.sh"
# shellcheck disable=SC1090
source "$TMP/lib.sh"
_node_log() { :; }

NODE_HOME="$TMP/home"; mkdir -p "$NODE_HOME"
NODE_CONF="$NODE_HOME/node.conf"; NODE_LOG="$NODE_HOME/node.log"
NODE_PRIV="$NODE_HOME/priv.key"; NODE_PUB="$NODE_HOME/pub.key"
NODE_WGCONF="$NODE_HOME/wg-home.conf"

group "Reconocer un dispositivo que ya es nodo"
# La huella es la direccion dentro del rango que reparte el VPS, no
# el nombre del fichero: buscar "wg-home.conf" daba falsos negativos.
mk() { printf '[Interface]\nAddress = %s\n' "$1" > "$TMP/c.conf"; }
for a in 10.77.77.2/24 10.77.77.3/24 10.77.78.2/24 10.77.92.9/32; do
    mk "$a"; _wg_conf_is_node "$TMP/c.conf" && ok "reconoce $a" || bad "no reconoce $a"
done
# La .1 es el VPS y la .255 el broadcast; 10.77.93 queda fuera del rango.
for a in 10.77.77.1/24 10.77.77.255/24 10.77.93.2/24 192.168.1.5/24; do
    mk "$a"; _wg_conf_is_node "$TMP/c.conf" && bad "acepta $a siendo invalida" || ok "rechaza $a"
done
# Un prefijo no basta: .20 no es .2
mk "10.77.77.20/24"; _wg_conf_is_node "$TMP/c.conf" && ok "acepta 10.77.77.20 (nodo valido)" || bad "rechaza 10.77.77.20"

group "La red se deduce de la direccion asignada"
for pair in "10.77.77.2 10.77.77.1 10.77.77.0/24" "10.77.78.2 10.77.78.1 10.77.78.0/24"; do
    set -- $pair
    NODE_SELF_WGIP="$1"; _node_derive_net
    is "$1 -> VPS $2"  "$NODE_VPS_WGIP" "$2"
    is "$1 -> red $3"  "$NODE_SUBNET"   "$3"
done

group "El endpoint no puede ser una direccion del tunel"
# Apuntar el endpoint a 10.77.77.1 es pedirle al tunel que se
# transporte a si mismo: no hay handshake y nada lo avisa.
_node_check_endpoint_host 10.77.77.1 >/dev/null 2>&1 && bad "acepta la IP del tunel" || ok "rechaza la IP del tunel"
_node_check_endpoint_host 203.0.113.9 >/dev/null 2>&1 && ok "acepta una IP publica" || bad "rechaza una IP publica"
_node_check_endpoint_host vps.ejemplo.com >/dev/null 2>&1 && ok "acepta un dominio" || bad "rechaza un dominio"

group "Configuracion persistente"
CFG_MODE=wireguard; CFG_DEVICE="prueba"; CFG_VPS_HOST=203.0.113.9
CFG_VPS_PORT=51821; CFG_VPS_PUBKEY="AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCd="
CFG_AUTOSTART=on; CFG_ADOPTED=no; NODE_SELF_WGIP=10.77.78.2
node_cfg_save
CFG_MODE=""; CFG_VPS_HOST=""; CFG_VPS_PORT=""; NODE_SELF_WGIP=10.77.77.2
node_cfg_load >/dev/null 2>&1
is "el modo se relee"          "$CFG_MODE"        "wireguard"
is "el host se relee"          "$CFG_VPS_HOST"    "203.0.113.9"
is "el puerto se relee"        "$CFG_VPS_PORT"    "51821"
is "la IP propia se relee"     "$NODE_SELF_WGIP"  "10.77.78.2"
is "y arrastra su red"         "$NODE_VPS_WGIP"   "10.77.78.1"
is "el fichero queda privado"  "$(stat -c '%a' "$NODE_CONF")" "600"

group "Claves"
command -v wg >/dev/null 2>&1 || { printf "  ${D}(omitido: falta el comando wg)${C}\n"; SKIP_WG=1; }
if [ -z "${SKIP_WG:-}" ]; then
    rm -f "$NODE_PRIV" "$NODE_PUB"
    wg_generate_keys >/dev/null 2>&1 && ok "genera un par" || bad "no genera par"
    is "la privada queda en 600" "$(stat -c '%a' "$NODE_PRIV")" "600"
    REAL=$(wg pubkey < "$NODE_PRIV")
    is "la publica corresponde a la privada" "$(cat "$NODE_PUB")" "$REAL"

    # Un 'wg genkey' que fallo antes de instalar wireguard-tools dejaba
    # un fichero vacio; comprobando solo -f se daba por bueno para siempre.
    : > "$NODE_PRIV"; rm -f "$NODE_PUB"
    wg_generate_keys >/dev/null 2>&1
    [ -s "$NODE_PRIV" ] && ok "regenera una clave vacia" || bad "da por buena una clave vacia"

    # Una config normal lleva la clave dentro del .conf y no hay .key
    # aparte: 'wg set private-key' pedia una ruta y fallaba con fopen.
    KEY=$(wg genkey)
    printf '[Interface]\nPrivateKey = %s\nAddress = 10.77.77.2/24\n' "$KEY" > "$NODE_WGCONF"
    rm -f "$NODE_PRIV" "$NODE_PUB"
    wg_ensure_private_key >/dev/null 2>&1
    is "extrae la clave de dentro del .conf" "$(cat "$NODE_PRIV")" "$KEY"

    # setconf no entiende 'Address': hay que depurar el fichero antes.
    _wg_strip_conf "$NODE_WGCONF" "$TMP/stripped.conf" >/dev/null 2>&1
    grep -q "Address" "$TMP/stripped.conf" && bad "deja Address en el conf depurado" || ok "quita Address del conf depurado"
    grep -q "PrivateKey" "$TMP/stripped.conf" && ok "conserva PrivateKey" || bad "pierde PrivateKey"

    # Importar sirve para recuperar la identidad que el VPS ya conoce.
    rm -f "$NODE_PRIV" "$NODE_PUB"
    echo "$KEY" | wg_import_key >/dev/null 2>&1
    is "importa una clave pegada" "$(cat "$NODE_PRIV")" "$KEY"
    rm -f "$NODE_PRIV" "$NODE_PUB"
    echo "esto-no-es-una-clave" | wg_import_key >/dev/null 2>&1
    [ -f "$NODE_PRIV" ] && bad "acepta basura como clave" || ok "rechaza basura y no deja restos"
fi

group "Integridad de la configuracion"
CFG_MODE=wireguard; CFG_VPS_PUBKEY="AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCd="
CFG_VPS_HOST=203.0.113.9; NODE_WGCONF="$TMP/vacio.conf"; : > "$NODE_WGCONF"
rm -f "$NODE_PRIV"
node_config_is_sane && bad "da por buena una config sin clave" || ok "detecta que falta la clave privada"
echo "clave" > "$NODE_PRIV"
CFG_VPS_HOST=""
node_config_is_sane && bad "da por buena una config sin host" || ok "detecta que faltan datos del VPS"
CFG_VPS_HOST=203.0.113.9
node_config_is_sane && ok "acepta una config completa" || bad "rechaza una config completa"

printf "\n${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C}\n"
if [ "$FAIL" -eq 0 ]; then printf " ${G}%d pruebas correctas${C}\n" "$OK"
else printf " ${G}%d correctas${C}  ${R}%d fallidas${C}\n" "$OK" "$FAIL"
     printf "${D}   %s${C}\n" "${FAILED[@]}"; fi
echo ""
echo -e "${D} No se prueba nada que dependa de root, de iptables reales,${C}"
echo -e "${D} de WireGuard vivo, de Android ni de un VPS.${C}"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
