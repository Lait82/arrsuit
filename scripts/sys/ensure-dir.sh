#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/ensure-dir.sh <host_path> <puid> <pgid> <container> <ctr_path>
#
#  Crea una carpeta en el host con el dueño correcto y despues VERIFICA que el
#  contenedor pueda escribir en ella.
#
#  La verificacion se hace DESDE ADENTRO del contenedor porque es el unico
#  lugar donde la respuesta cuenta. Un chequeo en el host no puede ver:
#    - un bind montado :ro
#    - un mount que fallo y dejo /data vacio
#    - SELinux sin labels :z
#    - userns-remap, donde el uid $PUID del contenedor NO es el $PUID del host
#      y ningun chown en el host sirve
#
#  OJO con el -u $PUID: 'docker exec' sin eso corre como root, y root escribe
#  siempre -> el test daria un falso OK.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

HOST_PATH="${1:?falta host_path}"
PUID="${2:?falta puid}"
PGID="${3:?falta pgid}"
CONTAINER="${4:?falta container}"
CTR_PATH="${5:?falta ctr_path}"

if [[ ! -d "$HOST_PATH" ]]; then
    info "Creando $HOST_PATH en el host..."
    mkdir -p "$HOST_PATH" || die "No pude crear $HOST_PATH"
fi
chown "${PUID}:${PGID}" "$HOST_PATH" || die "Fallo el chown de $HOST_PATH"

if docker exec -u "$PUID" "$CONTAINER" test -w "$CTR_PATH" 2>/dev/null; then
    info "Permisos OK: $CONTAINER puede escribir en $CTR_PATH"
    exit 0
fi

warn "$CONTAINER (uid $PUID / 'abc') no puede escribir en $CTR_PATH"
warn "El host tiene $HOST_PATH como ${PUID}:${PGID}, asi que no es el dueño."
warn "Revisá, en este orden:"
warn "  1) que el bind este montado y no sea read-only:"
warn "       docker exec $CONTAINER mount | grep /data"
warn "  2) que dockerd no tenga userns-remap (remapea los uid del contenedor):"
warn "       docker info | grep -i userns"
warn "  3) SELinux: si esta activo, el compose necesita ':z' en el volumen."
die "Abortando: no configuro una carpeta donde $CONTAINER no puede escribir."
