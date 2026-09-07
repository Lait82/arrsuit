#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/ufw-rules.sh <ssh_port>
#
#  Deja el firewall del host en el estado que el stack necesita:
#  todo cerrado salvo SSH, Tailscale y el puerto 80 (nginx).
#
#  POR QUE EL CHEQUEO DE IDEMPOTENCIA NO ES COSMETICO:
#  aplicar las reglas implica 'ufw --force reset', que borra el firewall y lo
#  reconstruye. En la primera corrida da igual, pero esto ahora corre en cada
#  pasada del orquestador, con el stack ARRIBA: un reset con Docker corriendo
#  le pasa el trapo a las cadenas de iptables y hay que esperar a que Docker
#  las rearme. Asi que si el firewall ya esta como queremos, no se toca nada.
#
#  Y OJO CON EL ORDEN al aplicar: SSH y Tailscale se abren ANTES del enable,
#  o te quedas afuera del server.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

SSH_PORT="${1:?falta ssh_port}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "El puerto SSH tiene que ser un numero (recibi '$SSH_PORT')"

command -v ufw >/dev/null 2>&1 || die "Falta ufw. ¿Corrio host-packages.sh?"

# --- ¿hace falta tocar algo? --------------------------------------------
needs_apply=0
status="$(ufw status verbose 2>/dev/null || true)"

if ! grep -q '^Status: active' <<<"$status"; then
    info "UFW esta inactivo."
    needs_apply=1
elif ! grep -q 'Default: deny (incoming)' <<<"$status"; then
    info "UFW no esta denegando el trafico entrante por defecto."
    needs_apply=1
else
    # 'ufw status' imprime una linea por regla; alcanza con que aparezca cada
    # una de las que nos importan. Sobrar reglas no nos molesta: si agregaste
    # algo a mano, no se lo pisamos.
    declare -A wanted=(
        ["on tailscale0.*ALLOW IN"]="acceso por la interfaz de Tailscale"
        ["^${SSH_PORT}/tcp .*ALLOW"]="SSH en el puerto ${SSH_PORT}"
        ["^41641/udp .*ALLOW"]="Tailscale (41641/udp)"
        ["^80/tcp .*ALLOW"]="nginx (80/tcp)"
    )
    for pattern in "${!wanted[@]}"; do
        if ! grep -qE "$pattern" <<<"$status"; then
            info "Falta la regla: ${wanted[$pattern]}"
            needs_apply=1
        fi
    done
fi

if (( needs_apply == 0 )); then
    info "El firewall ya esta configurado. No se toca."
    exit 0
fi

# --- aplicar -------------------------------------------------------------
# Guarda: sin la interfaz de Tailscale, abrir "in on tailscale0" no sirve y
# quedarias dependiendo solo del puerto SSH. Se aborta ANTES del reset.
if ! ip link show tailscale0 >/dev/null 2>&1; then
    die "No existe la interfaz tailscale0. Abortando ANTES de tocar el firewall para no lockearte."
fi

warn "Reconfigurando el firewall (reset + reglas). Si el stack esta arriba, Docker rearma sus cadenas solo."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'Tailscale interface'
ufw allow "$SSH_PORT"/tcp   comment 'SSH'
ufw allow 41641/udp         comment 'Tailscale'
ufw allow 80/tcp            comment 'Jellyfin via nginx'
ufw --force enable
info "Firewall aplicado: SSH ($SSH_PORT), Tailscale y 80/tcp."
