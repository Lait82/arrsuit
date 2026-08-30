#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/qbit-bypass.sh <container> <qbittorrent.conf> <subnet>
#
#  Permite que la red 'media' le pegue a la WebUI de qBittorrent sin login,
#  whitelisteando la subnet. Es lo que necesitan Radarr y Sonarr para
#  manejar torrents.
#
#  Patron stop/edit/start: qBittorrent reescribe su .conf al apagarse.
#
#  ESTE ARCHIVO ES EL MAS DELICADO DEL STACK: las claves llevan un backslash
#  literal ('WebUI\AuthSubnetWhitelist'). Ver el comentario de set_conf_key.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

CONTAINER="${1:?falta container}"
CONF="${2:?falta qbittorrent.conf}"
SUBNET="${3:?falta subnet}"
DC="$(detect_compose)"

[[ -f "$CONF" ]] || die "No existe $CONF. ¿Arranco qBittorrent al menos una vez?"

# ¿Ya esta aplicado? (grep -F: match literal, no interpreta el backslash)
if grep -qF 'WebUI\AuthSubnetWhitelistEnabled=true' "$CONF" \
   && grep -qF "WebUI\\AuthSubnetWhitelist=$SUBNET" "$CONF"; then
    info "El bypass ya esta aplicado ($SUBNET). No se toca qBittorrent."
    exit 0
fi

info "Parando qBittorrent para editar su config..."
$DC stop "$CONTAINER" >/dev/null
cp -a "$CONF" "${CONF}.bak.$(date +%s)"

# Limpieza previa: borrar CUALQUIER linea de estas claves, bien o mal escrita
# (con barra, sin barra por el bug del -v, con otra subnet, o duplicadas). Asi
# el archivo converge a lo correcto sin importar como quedo de corridas
# anteriores. Matcheamos 'AuthSubnetWhitelist', comun a la version correcta y
# a la rota (WebUIAuthSubnet sin barra).
if grep -qF 'AuthSubnetWhitelist' "$CONF"; then
    grep -vF 'AuthSubnetWhitelist' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
fi

grep -qF '[Preferences]' "$CONF" || echo '[Preferences]' >> "$CONF"

# awk usando ENVIRON y NO -v: pasar el valor por -v hace que awk interprete
# '\A' como escape y se coma la barra. Via ENVIRON[] el string es literal, asi
# 'WebUI\AuthSubnet...' se preserva con la barra.
set_conf_key() {
    local key="$1" val="$2"
    export _CK_KEY="$key" _CK_LINE="${key}=${val}"
    if grep -qF "${key}=" "$CONF"; then
        awk '
            index($0, ENVIRON["_CK_KEY"] "=") == 1 { print ENVIRON["_CK_LINE"]; next }
            { print }
        ' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
    else
        awk '
            { print }
            /^\[Preferences\]/ && !done { print ENVIRON["_CK_LINE"]; done=1 }
        ' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
    fi
    unset _CK_KEY _CK_LINE
}

set_conf_key 'WebUI\AuthSubnetWhitelistEnabled' 'true'
set_conf_key 'WebUI\AuthSubnetWhitelist' "$SUBNET"
# Si aparece un 403 desde otros contenedores, descomentar:
# set_conf_key 'WebUI\HostHeaderValidation' 'false'

info "Arrancando qBittorrent..."
$DC start "$CONTAINER" >/dev/null
sleep 5
info "Bypass aplicado para $SUBNET."
