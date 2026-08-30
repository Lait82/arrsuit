#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/servarr-auth.sh <container> <config.xml>
#
#  Pone AuthenticationMethod=External en un *arr: el servicio no pide login y
#  delega la autenticacion en la capa de acceso (Tailscale). La API key sigue
#  funcionando.
#
#  POR QUE External Y NO DisabledForLocalAddresses:
#  los *arr consideran "local" solo loopback y los rangos RFC1918. Tailscale usa
#  100.64.0.0/10 (CGNAT), que NO entra en esa lista -> con
#  DisabledForLocalAddresses te pide login igual. Nadie llega al servicio sin
#  estar en el tailnet, asi que la auth ya la hizo Tailscale.
#
#  Patron stop/edit/start: el servicio reescribe su XML al apagarse, asi que
#  hay que editarlo con el contenedor detenido o se pierde el cambio.
#
#  Queda en bash y no en Python porque es exactamente la clase de tarea que
#  bash hace bien: parar un contenedor, editar un archivo, arrancarlo.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

CONTAINER="${1:?falta container}"
XML="${2:?falta config.xml}"
DC="$(detect_compose)"

[[ -f "$XML" ]] || die "No encuentro $XML"

if grep -qF '<AuthenticationMethod>External</AuthenticationMethod>' "$XML"; then
    info "Auth de $CONTAINER ya esta en External. No se toca."
    exit 0
fi

info "Parando $CONTAINER para editar su config..."
$DC stop "$CONTAINER" >/dev/null
cp -a "$XML" "${XML}.bak.$(date +%s)"

# Bug conocido (#9353): editar mal deja <AuthenticationMethod> duplicados.
# Estrategia robusta: borrar TODAS las lineas de AuthenticationMethod y
# AuthenticationRequired, y reescribir una sola de cada una.
grep -vE '<Authentication(Method|Required)>' "$XML" > "${XML}.tmp" && mv "${XML}.tmp" "$XML"

export _SA_M='  <AuthenticationMethod>External</AuthenticationMethod>'
export _SA_R='  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>'
awk '
    { print }
    /<Config>/ && !done { print ENVIRON["_SA_M"]; print ENVIRON["_SA_R"]; done=1 }
' "$XML" > "${XML}.tmp" && mv "${XML}.tmp" "$XML"
unset _SA_M _SA_R

info "Arrancando $CONTAINER..."
$DC start "$CONTAINER" >/dev/null
sleep 5
info "Auth de $CONTAINER en External (sin login; Tailscale es la capa de acceso)."
