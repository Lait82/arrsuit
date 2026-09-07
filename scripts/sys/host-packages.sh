#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/host-packages.sh <paquete>...
#
#  Instala los paquetes del host que el stack necesita fuera de Docker.
#
#  Hoy es solo ufw: nginx, fail2ban y geoipupdate se mudaron al compose.
#
#  IDEMPOTENCIA: chequea uno por uno con dpkg y, si no falta ninguno, ni
#  siquiera corre 'apt-get update'. Importa porque esto ahora corre en CADA
#  pasada del orquestador, no una sola vez: un 'apt update' de 20 segundos al
#  principio de cada corrida se nota.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

(( $# > 0 )) || die "No me pasaste ningun paquete."

missing=()
for pkg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if (( ${#missing[@]} == 0 )); then
    info "Paquetes del host ya instalados: $*"
    exit 0
fi

info "Faltan: ${missing[*]}"
export DEBIAN_FRONTEND=noninteractive
info "Actualizando indice de paquetes..."
apt-get update -qq || die "Fallo 'apt-get update'"
info "Instalando ${missing[*]}..."
apt-get install -y -qq "${missing[@]}" || die "Fallo la instalacion de ${missing[*]}"
info "Listo."
