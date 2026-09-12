"""Recyclarr: aplica las TRaSH Guides a Radarr y Sonarr.

No tiene API ni UI: se configura con un YAML y se dispara por CLI. Asi que
esto es render de plantilla + un 'recyclarr sync' adentro del contenedor.

QUE SINCRONIZA (las tres cosas que dan la calidad "correcta" segun TRaSH):
  quality_definition   -> tamanios min/max aceptables por calidad
  quality_profiles     -> el perfil entero, traido del guide por trash_id
  custom_format_groups -> custom formats y sus puntajes

POR QUE VA AL FINAL DEL ORQUESTADOR: necesita las API keys de Radarr y Sonarr,
o sea que los dos tienen que haber arrancado y estar configurados. Es la
pasada de afinado sobre un stack que ya funciona.

EFECTO SECUNDARIO QUE HAY QUE SABER: cambiar los quality profiles hace que
Radarr y Sonarr re-evaluen la biblioteca que ya tenes y encolen upgrades de lo
que quedo por debajo del cutoff nuevo. Por eso conviene correrlo temprano en la
vida del stack y no despues de bajar 2 TB.
"""

from pathlib import Path

from ..tools import config, sh, ui

CONTAINER = "recyclarr"

# El contenedor monta /srv/config/recyclarr como /config, y recyclarr busca su
# config en /config/recyclarr.yml (RECYCLARR_CONFIG_DIR=/config en la imagen).
CONFIG_HOST_DIR = "/srv/config/recyclarr"
CONFIG_CTR_DIR = "/config"
CONFIG_HOST_PATH = f"{CONFIG_HOST_DIR}/recyclarr.yml"


class Recyclarr:
    def __init__(self, cfg: config.Config, repo_root: Path):
        self.cfg = cfg
        self.template = repo_root / "configs" / "recyclarr" / "recyclarr.yml.tmpl"

    def _service_conf(self, service: str) -> tuple[str, str, str, str]:
        """Devuelve (trash_id del perfil, nombre, bloque de CF groups, bloque de CFs)."""
        profile = self.cfg.get("recyclarr", service, "qualityProfile")
        groups = self.cfg.get(
            "recyclarr", service, "customFormatGroups", default=[], required=False
        )
        formats = self.cfg.get(
            "recyclarr", service, "customFormats", default=[], required=False
        )

        # Sin grupos, 'add:' quedaria vacio y el YAML seria invalido. Se emite
        # una lista vacia explicita para que siga parseando.
        if groups:
            group_block = "\n".join(
                f"        - trash_id: {g['trashId']}   # {g['name']}" for g in groups
            )
        else:
            group_block = "        []"

        # El perfil se referencia por nombre y no por trash_id: un mismo trash_id
        # puede cubrir varias variantes de un perfil, y ahi Recyclarr rechaza la
        # referencia por ambigua.
        if formats:
            lines = []
            for fmt in formats:
                lines += [
                    "      - trash_ids:",
                    f"          - {fmt['trashId']}   # {fmt['name']}",
                    "        assign_scores_to:",
                    f"          - name: \"{profile['name']}\"",
                    f"            score: {fmt['score']}",
                ]
            format_block = "\n".join(lines)
        else:
            format_block = "      []"

        return profile["trashId"], profile["name"], group_block, format_block

    def render(self, radarr, sonarr) -> str:
        radarr_id, radarr_name, radarr_groups, radarr_formats = self._service_conf("radarr")
        sonarr_id, sonarr_name, sonarr_groups, sonarr_formats = self._service_conf("sonarr")

        ui.detail(f"Radarr : {radarr_name}")
        ui.detail(f"Sonarr : {sonarr_name}")

        # internal_url y no la URL de Tailscale: recyclarr esta en la red
        # 'media' y les pega por el DNS interno de Docker.
        values = {
            "{{RADARR_URL}}": radarr.internal_url,
            "{{RADARR_API_KEY}}": radarr.api_key,
            "{{RADARR_PROFILE_ID}}": radarr_id,
            "{{RADARR_PROFILE_NAME}}": radarr_name,
            "{{RADARR_CF_GROUPS}}": radarr_groups,
            "{{RADARR_CUSTOM_FORMATS}}": radarr_formats,
            "{{SONARR_URL}}": sonarr.internal_url,
            "{{SONARR_API_KEY}}": sonarr.api_key,
            "{{SONARR_PROFILE_ID}}": sonarr_id,
            "{{SONARR_PROFILE_NAME}}": sonarr_name,
            "{{SONARR_CF_GROUPS}}": sonarr_groups,
            "{{SONARR_CUSTOM_FORMATS}}": sonarr_formats,
        }

        text = self.template.read_text()
        for placeholder, value in values.items():
            text = text.replace(placeholder, value)

        left = [p for p in values if p in text]
        if left:
            ui.die(f"Quedaron placeholders sin reemplazar en el YAML: {left}")
        return text

    def install_config(self, sys_scripts: Path, tmpdir: Path, radarr, sonarr) -> None:
        # El dueño de /config va ANTES de escribir nada adentro. Esta imagen no
        # es de LinuxServer: corre como uid 1000 y no chownea /config al
        # arrancar, asi que hereda el root:root con el que Docker crea el
        # directorio del bind cuando todavia no existe en el host. Recyclarr se
        # guarda el estado en /config/state, y sin esto el sync muere con
        # 'Access to the path /config/state is denied'.
        sh.run_script(
            sys_scripts / "ensure-dir.sh",
            CONFIG_HOST_DIR, config.PUID, config.PGID,
            CONTAINER, CONFIG_CTR_DIR,
        )

        rendered = tmpdir / "recyclarr.yml"
        rendered.write_text(self.render(radarr, sonarr))
        sh.run_script(
            sys_scripts / "install-conf.sh",
            config.PUID, config.PGID,
            str(rendered), CONFIG_HOST_PATH,
        )

    def sync(self, sys_scripts: Path) -> None:
        """Aplica el guide ahora.

        El contenedor ya corre un sync solo con su cron (@daily, default de la
        imagen), pero eso significa esperar hasta 24hs para ver el efecto de un
        cambio. Esto lo aplica en el momento.
        """
        sh.run_script(sys_scripts / "recyclarr-sync.sh", CONTAINER)
