#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/geoip-sync.sh <repo_root>
#
#  Baja la base GeoLite2 al volumen 'geoip' de una, sin esperar al ciclo
#  semanal del contenedor geoipupdate.
#
#  Hace falta porque nginx NO arranca si el .mmdb no esta: la directiva
#  geoip2 abre el archivo al parsear la config y aborta si no lo encuentra.
#  Si dependieramos solo del servicio de fondo, la primera vez nginx entraria
#  en loop de reinicios hasta que la descarga termine.
#
#  GEOIPUPDATE_FREQUENCY=0 -> corre una vez y sale (el modo daemon es != 0).
#  'run --rm' y no 'up': queremos esperar a que termine y saber si fallo.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

REPO_ROOT="${1:?falta el repo_root}"
cd "$REPO_ROOT" || die "No pude entrar a $REPO_ROOT"

DC="$(detect_compose)"

info "Bajando la base GeoLite2-Country (MaxMind)..."
if ! $DC --profile geo run --rm -e GEOIPUPDATE_FREQUENCY=0 geoipupdate; then
    die "geoipupdate fallo. Revisá MAXMIND_ACCOUNT_ID / MAXMIND_LICENSE_KEY en el .env."
fi
info "Base GeoLite2 lista en el volumen 'geoip'."
