#!/usr/bin/env python3
# =========================================================================
#  configure-stack.py - Orquesta y configura el media stack de punta a punta
#
#  Pensado para alguien que apenas se maneja: un solo comando deja todo listo.
#
#  ARQUITECTURA:
#    Este archivo es el ORQUESTADOR. Define los pasos y decide QUE hay que
#    hacer; el COMO se reparte segun la herramienta que corresponde:
#
#      python (pylib/)      -> HTTP, JSON, y toda la logica de configuracion
#                              via API. Es donde bash sufria: no puede devolver
#                              estructuras y armar payloads con jq es fragil.
#      bash (scripts/sys/)  -> lo que toca el sistema: docker compose,
#                              mkdir/chown/chmod, docker exec, y la cirugia
#                              sobre archivos de config (.conf, .xml).
#
#    Los scripts de bash reciben todo por argumentos: no comparten globales,
#    se pueden correr a mano para debuggear y su contrato es explicito.
#
#  Idempotente: se puede correr varias veces sin romper ni duplicar nada.
#
#  Config editable -> configs/services_setup.conf
#  Secretos/IP     -> .env  (TAILSCALE_IP la escribe setup-host.sh)
#  LOG             -> ./configure-stack.log  (cada request/response)
#
#  LO QUE NO HACE (queda manual, son credenciales personales):
#    - Cargar indexers en Prowlarr: cada uno tiene campos propios.
#    - Cargar el proveedor de Usenet en SABnzbd (Config -> Servers). Sin eso
#      SABnzbd no baja nada: el indexer dice DONDE esta, el proveedor es DE
#      DONDE se baja, y son dos suscripciones distintas.
#
#  >>> Requiere: docker, python3. Corre con sudo (toca /srv/config y docker).
# =========================================================================

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))

from pylib import config, sab, servarr, sh, ui  # noqa: E402

SYS_SCRIPTS = REPO_ROOT / "scripts" / "sys"
TOTAL_STEPS = 8


def check_prereqs() -> None:
    if os.geteuid() != 0:
        ui.print_fatal("Corré con sudo (toca /srv/config y docker).")
        sys.exit(1)
    if not sh.have("docker"):
        ui.print_fatal("Falta docker.")
        sys.exit(1)


def main() -> int:
    check_prereqs()
    ui.init_log(REPO_ROOT / "configure-stack.log", TOTAL_STEPS)

    cfg = config.Config(REPO_ROOT)

    radarr = servarr.Radarr(cfg)
    sonarr = servarr.Sonarr(cfg)
    prowlarr = servarr.Prowlarr(cfg)
    sabnzbd = sab.Sabnzbd(cfg)

    radarr_category = cfg.get("radarr", "downloadClientCategory")
    sonarr_category = cfg.get("sonarr", "downloadClientCategory")
    radarr_root = config.require_container_path(
        cfg.get("radarr", "rootFolder"), "radarr.rootFolder"
    )
    sonarr_root = config.require_container_path(
        cfg.get("sonarr", "rootFolder"), "sonarr.rootFolder"
    )

    # -- 1 ----------------------------------------------------------------
    ui.step("Preparando el arbol de carpetas en el host")
    # Los root folders salen de la config, asi que se agregan a la lista en vez
    # de asumir cuales son: si los cambias en el conf, la carpeta se crea igual.
    dirs = [
        config.MEDIA_HOST_DIR,
        f"{config.MEDIA_HOST_DIR}/downloads",
        config.ctr_to_host_path(radarr_root),
        config.ctr_to_host_path(sonarr_root),
        config.ctr_to_host_path(sabnzbd.complete_dir),
        config.ctr_to_host_path(sabnzbd.incomplete_dir),
        config.CONFIG_HOST_DIR,
    ]
    sh.run_script(
        SYS_SCRIPTS / "media-tree.sh",
        config.MEDIA_HOST_DIR, config.PUID, config.PGID,
        *dict.fromkeys(dirs),   # dedup preservando el orden
    )

    # -- 2 ----------------------------------------------------------------
    ui.step("Levantando el stack")
    sh.run_script(SYS_SCRIPTS / "compose-up.sh", REPO_ROOT)

    # -- 3 ----------------------------------------------------------------
    ui.step(f"Configurando bypass de auth de qBittorrent (red {config.MEDIA_SUBNET})")
    sh.run_script(
        SYS_SCRIPTS / "qbit-bypass.sh",
        config.QBIT_CONTAINER, config.QBIT_CONF, config.MEDIA_SUBNET,
    )

    # -- 4 ----------------------------------------------------------------
    ui.step("Configurando Radarr (peliculas)")
    radarr.apply_external_auth(SYS_SCRIPTS)
    radarr.wait_ready()
    ui.detail(f"Categoria   : {radarr_category}")
    ui.detail(f"Root folder : {radarr_root}")
    radarr.upsert_download_client(
        config.TC_NAME, radarr.qbittorrent_payload(radarr_category)
    )
    sh.run_script(
        SYS_SCRIPTS / "ensure-dir.sh",
        config.ctr_to_host_path(radarr_root), config.PUID, config.PGID,
        radarr.container, radarr_root,
    )
    radarr.add_root_folder(radarr_root)

    # La carpeta de descargas tiene el mismo problema de dueño, pero se
    # manifiesta mas tarde y peor: el root folder se agrega bien y recien falla
    # al importar ("Couldn't import" en Activity -> Queue). Radarr necesita
    # escribir ahi para hacer el hardlink de downloads/ -> movies/.
    sh.run_script(
        SYS_SCRIPTS / "ensure-dir.sh",
        f"{config.MEDIA_HOST_DIR}/downloads", config.PUID, config.PGID,
        radarr.container, f"{config.MEDIA_CTR_DIR}/downloads",
    )

    # -- 5 ----------------------------------------------------------------
    ui.step("Configurando Sonarr (series)")
    sonarr.apply_external_auth(SYS_SCRIPTS)
    sonarr.wait_ready()
    ui.detail(f"Categoria   : {sonarr_category}")
    ui.detail(f"Root folder : {sonarr_root}")
    sonarr.upsert_download_client(
        config.TC_NAME, sonarr.qbittorrent_payload(sonarr_category)
    )
    sh.run_script(
        SYS_SCRIPTS / "ensure-dir.sh",
        config.ctr_to_host_path(sonarr_root), config.PUID, config.PGID,
        sonarr.container, sonarr_root,
    )
    sonarr.add_root_folder(sonarr_root)

    # -- 6 ----------------------------------------------------------------
    ui.step("Configurando SABnzbd (usenet)")
    # Va DESPUES de Radarr y Sonarr porque se conecta a los dos.
    sabnzbd.wait_ready()
    sabnzbd.ensure_host_whitelist()
    for ctr_path in (sabnzbd.complete_dir, sabnzbd.incomplete_dir):
        sh.run_script(
            SYS_SCRIPTS / "ensure-dir.sh",
            config.ctr_to_host_path(ctr_path), config.PUID, config.PGID,
            sab.SAB_CONTAINER, ctr_path,
        )
    sabnzbd.configure_dirs()
    sabnzbd.configure_categories([radarr_category, sonarr_category])
    radarr.upsert_download_client(
        sab.SAB_NAME, sabnzbd.client_payload(radarr.category_field, radarr_category)
    )
    sonarr.upsert_download_client(
        sab.SAB_NAME, sabnzbd.client_payload(sonarr.category_field, sonarr_category)
    )

    # -- 7 ----------------------------------------------------------------
    ui.step("Configurando Prowlarr (indexers)")
    # Va ULTIMO a proposito: se conecta hacia Radarr y Sonarr y necesita las
    # API keys de los dos, asi que ambos tienen que existir y responder antes.
    prowlarr.apply_external_auth(SYS_SCRIPTS)
    prowlarr.wait_ready()
    prowlarr.add_flaresolverr()
    prowlarr.connect_app(radarr)
    prowlarr.connect_app(sonarr)

    # -- 8 ----------------------------------------------------------------
    ui.step("Listo")
    ui.detail(f"Peliculas : {radarr_root}")
    ui.detail(f"Series    : {sonarr_root}")
    ui.detail("Descargas : torrent via qBittorrent + usenet via SABnzbd")
    print()
    ui.detail(f"Paneles (por Tailscale, http://{cfg.tailscale_ip}:PUERTO):")
    ui.detail("  7878 Radarr    8989 Sonarr    9696 Prowlarr")
    ui.detail(f"  8080 qBittorrent    {sabnzbd.port} SABnzbd    6767 Bazarr    5055 Jellyseerr")
    print()
    ui.warn("Faltan dos pasos manuales (son credenciales personales):")
    ui.warn("  1) Indexers en Prowlarr (Indexers -> Add Indexer). A los que")
    ui.warn(f"     esten detras de Cloudflare, poneles el tag '{prowlarr.FLARESOLVERR_TAG}'.")
    ui.warn("  2) Proveedor de Usenet en SABnzbd (Config -> Servers). SIN ESTO")
    ui.warn("     SABnzbd no baja nada, por mas que Radarr le mande trabajo.")
    ui.logfile("=== configure-stack finalizado OK ===")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ui.StackError as exc:
        ui.print_fatal(str(exc))
        ui.logfile(f"=== ABORTADO: {exc} ===")
        sys.exit(1)
    except KeyboardInterrupt:
        ui.print_fatal("Interrumpido.")
        sys.exit(130)
