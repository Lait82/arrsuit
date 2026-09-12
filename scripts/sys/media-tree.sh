#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/media-tree.sh <media_host_dir> <puid> <pgid> <dir>...
#
#  Crea el arbol de carpetas en el host con el dueño correcto.
#
#  ESTO VA ANTES DE 'docker compose up'. Si el destino de un bind mount no
#  existe, Docker lo crea root:root 755 y despues los contenedores (que corren
#  como uid $PUID) no pueden escribir ahi. Creandolas nosotros primero, con el
#  dueño correcto, Docker nunca tiene que inventar nada.
#
#  Las imagenes de linuxserver arrancan como root y ajustan el dueño de su
#  propio /config al iniciar, asi que para ellas el dueño de la carpeta da
#  igual. /data NO lo tocan (y esta bien: no queres un chown recursivo de tu
#  biblioteca en cada arranque), por eso el media tree es cosa nuestra.
#
#  LAS QUE NO SON DE LINUXSERVER SI NECESITAN EL DUEÑO PUESTO DE ENTRADA, y
#  Seerr ademas no perdona: corre como uid 1000 sin poder elevarse, no chownea
#  nada, y si /app/config le llega de root muere en el arranque con EACCES al
#  crear su carpeta de logs. Con 'restart: unless-stopped' eso es un contenedor
#  reiniciandose para siempre. Por eso el dueño se ajusta aca, ANTES del
#  compose up, y no mas tarde: despues ya no hay contenedor vivo al que
#  arreglarle nada.
#
#  El chown de cada carpeta de la lista es DE LA CARPETA EN SI, no recursivo:
#  alcanza para que el servicio pueda escribir adentro y no toca lo que cada
#  app haya armado abajo (ni la biblioteca, que se maneja aparte mas abajo).
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

MEDIA_HOST_DIR="${1:?falta media_host_dir}"; shift
PUID="${1:?falta puid}"; shift
PGID="${1:?falta pgid}"; shift

for d in "$@"; do
    if [[ ! -d "$d" ]]; then
        info "Creando $d"
        mkdir -p "$d" || die "No pude crear $d"
    fi
    if [[ "$(stat -c '%u:%g' "$d")" != "${PUID}:${PGID}" ]]; then
        info "Ajustando dueño de $d -> ${PUID}:${PGID}"
        chown "${PUID}:${PGID}" "$d" || die "Fallo el chown de $d"
    fi
done

# Solo chowneamos si hace falta. 'find -not -uid' corta en el primer archivo
# con dueño incorrecto, asi evitamos un chown -R sobre una biblioteca grande
# cuando ya esta todo bien (que es el caso normal a partir de la 2da corrida).
if find "$MEDIA_HOST_DIR" \( -not -uid "$PUID" -o -not -gid "$PGID" \) \
    -print -quit 2>/dev/null | grep -q .; then
    info "Ajustando dueño de $MEDIA_HOST_DIR -> ${PUID}:${PGID} (puede tardar si hay muchos archivos)"
    chown -R "${PUID}:${PGID}" "$MEDIA_HOST_DIR" || die "Fallo el chown de $MEDIA_HOST_DIR"
else
    info "Dueño de $MEDIA_HOST_DIR ya es correcto (${PUID}:${PGID})"
fi

# setgid en los directorios: lo que se cree adentro hereda el grupo, asi ningun
# servicio del stack se queda afuera de lo que escribio otro.
chmod -R u+rwX,g+rwX "$MEDIA_HOST_DIR" || die "Fallo el chmod de $MEDIA_HOST_DIR"
find "$MEDIA_HOST_DIR" -type d -exec chmod g+s {} + 2>/dev/null || true
