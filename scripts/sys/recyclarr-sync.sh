#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/recyclarr-sync.sh <container>
#
#  Corre 'recyclarr sync' adentro del contenedor: baja las TRaSH Guides y las
#  aplica a Radarr y Sonarr.
#
#  Por que 'docker exec' y no 'compose run --rm': el contenedor ya esta arriba
#  (lo levanto el paso del compose) y tiene el volumen de /config montado, que
#  es donde vive el cache del guide. Con 'run --rm' cada corrida se volveria a
#  clonar los repos del guide desde cero.
#
#  La primera corrida tarda: clona trash-guides y config-templates. Las
#  siguientes solo hacen fetch.
#
#  NO es idempotente en el sentido de "no hace nada si ya corrio": recyclarr es
#  declarativo, aplica el guide cada vez. Eso es deseado, porque el guide cambia
#  y esta es la forma de traer esos cambios.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

CONTAINER="${1:?falta el container}"

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]]; then
    die "El contenedor '$CONTAINER' no esta corriendo. ¿Fallo el paso del compose?"
fi

info "Sincronizando las TRaSH Guides (puede tardar un momento)..."
if ! docker exec "$CONTAINER" recyclarr sync --log info; then
    die "Fallo 'recyclarr sync'. Revisá el detalle arriba y en /srv/config/recyclarr/logs/"
fi
info "Guides aplicadas a Radarr y Sonarr."
