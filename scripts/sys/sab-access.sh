#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/sab-access.sh <container> <sabnzbd.ini> <host_interno> <inet_exposure>
#
#  Configura los dos filtros de acceso de SABnzbd editando el .ini.
#
#  No se puede por API: en sabnzbd/cfg.py las dos opciones estan declaradas
#  con protect=True, y config.py hace `if not self.__protect: self.set(...)`.
#  O sea que la API las ignora en silencio: responde 200 con el valor viejo.
#
#    host_whitelist -> valida el header Host. Radarr usa http://sabnzbd:8080,
#                      sin esto recibe "Hostname verification failed".
#    inet_exposure  -> nivel de acceso para los clientes que SABnzbd considera
#                      externos. El navegador entra por la IP de Tailscale
#                      (CGNAT, no RFC1918) -> "External internet access denied".
#                      0 sin acceso   1 solo agregar NZBs   2 API sin config
#                      3 API completa 4 API + web           5 web, login externo
#
#  No se toca local_ranges: reemplazaria el default RFC1918 en vez de
#  extenderlo, y Radarr/Sonarr dependen de ese default para entrar desde
#  172.20.0.1.
#
#  El puerto solo escucha en ${TAILSCALE_IP} y 127.0.0.1, asi que "externo"
#  aca es el tailnet.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

CONTAINER="${1:?falta container}"
INI="${2:?falta sabnzbd.ini}"
INTERNAL_HOST="${3:?falta host interno}"
INET_EXPOSURE="${4:?falta inet_exposure}"
DC="$(detect_compose)"

[[ -f "$INI" ]] || die "No encuentro $INI. ¿SABnzbd arranco al menos una vez?"

if grep -qE "^inet_exposure[[:space:]]*=[[:space:]]*${INET_EXPOSURE}\$" "$INI" \
   && grep -qE "^host_whitelist[[:space:]]*=.*\b${INTERNAL_HOST}\b" "$INI"; then
    info "SABnzbd ya tiene el acceso configurado. No se toca."
    exit 0
fi

# Escribe una clave dentro de [misc]: reemplaza si existe (descartando
# duplicados), agrega al final de la seccion si no.
# awk+ENVIRON y no sed: el valor trae comas y puntos que sed interpretaria.
ini_set() {
    local key="$1" value="$2"
    grep -qE '^\[misc\]' "$INI" || die "No encuentro la seccion [misc] en $INI"

    export _INI_KEY="$key" _INI_VAL="$value"
    awk '
        BEGIN { sec=""; done=0 }
        /^\[.*\]$/ {
            if (sec == "misc" && !done) {
                print ENVIRON["_INI_KEY"] " = " ENVIRON["_INI_VAL"]; done=1
            }
            sec = substr($0, 2, length($0)-2)
            print; next
        }
        {
            if (sec == "misc" && $0 ~ "^" ENVIRON["_INI_KEY"] "[ \t]*=") {
                if (!done) { print ENVIRON["_INI_KEY"] " = " ENVIRON["_INI_VAL"]; done=1 }
                next
            }
            print
        }
        END {
            if (sec == "misc" && !done) {
                print ENVIRON["_INI_KEY"] " = " ENVIRON["_INI_VAL"]
            }
        }
    ' "$INI" > "${INI}.tmp" && mv "${INI}.tmp" "$INI"
    unset _INI_KEY _INI_VAL
}

# stop/edit/start: SABnzbd reescribe el .ini al apagarse.
info "Parando SABnzbd para editar su config..."
$DC stop "$CONTAINER" >/dev/null
cp -a "$INI" "${INI}.bak.$(date +%s)"

# Preserva las entradas que ya hubiera y agrega el nombre interno.
current="$(grep -E '^host_whitelist[[:space:]]*=' "$INI" | head -n1 | cut -d= -f2- | tr -d ' ' || true)"
entries="$(echo "$current" | tr ',' '\n' | grep -v '^$' | grep -vx "$INTERNAL_HOST" || true)"
whitelist="$(printf '%s\n%s\n' "$entries" "$INTERNAL_HOST" | grep -v '^$' | paste -sd, -)"

info "host_whitelist = $whitelist"
ini_set host_whitelist "$whitelist"

info "inet_exposure = $INET_EXPOSURE"
ini_set inet_exposure "$INET_EXPOSURE"

info "Arrancando SABnzbd..."
$DC start "$CONTAINER" >/dev/null
sleep 5

# SABnzbd reescribe el .ini al arrancar: confirmamos que el cambio sobrevivio.
if ! grep -qE "^inet_exposure[[:space:]]*=[[:space:]]*${INET_EXPOSURE}\$" "$INI"; then
    warn "inet_exposure no quedo en ${INET_EXPOSURE}:"
    grep -E '^inet_exposure' "$INI" || echo "  (la clave no esta)"
    die "SABnzbd descarto el cambio al arrancar."
fi
info "Acceso configurado."
