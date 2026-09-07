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
CONFIG_HOST_PATH = "/srv/config/recyclarr/recyclarr.yml"


class Recyclarr:
    def __init__(self, cfg: config.Config, repo_root: Path):
        self.cfg = cfg
        self.template = repo_root / "configs" / "recyclarr" / "recyclarr.yml.tmpl"

    def _service_conf(self, service: str) -> tuple[str, str, str]:
        """Devuelve (trash_id del perfil, nombre del perfil, bloque YAML de CF groups)."""
        profile = self.cfg.get("recyclarr", service, "qualityProfile")
        groups = self.cfg.get(
            "recyclarr", service, "customFormatGroups", default=[], required=False
        )

        # Sin grupos, 'add:' quedaria vacio y el YAML seria invalido. Se emite
        # una lista vacia explicita para que siga parseando.
        if groups:
            block = "\n".join(
                f"        - trash_id: {g['trashId']}   # {g['name']}" for g in groups
            )
        else:
            block = "        []"

        return profile["trashId"], profile["name"], block

    def render(self, radarr, sonarr) -> str:
        radarr_id, radarr_name, radarr_groups = self._service_conf("radarr")
        sonarr_id, sonarr_name, sonarr_groups = self._service_conf("sonarr")

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
            "{{SONARR_URL}}": sonarr.internal_url,
            "{{SONARR_API_KEY}}": sonarr.api_key,
            "{{SONARR_PROFILE_ID}}": sonarr_id,
            "{{SONARR_PROFILE_NAME}}": sonarr_name,
            "{{SONARR_CF_GROUPS}}": sonarr_groups,
        }

        text = self.template.read_text()
        for placeholder, value in values.items():
            text = text.replace(placeholder, value)

        left = [p for p in values if p in text]
        if left:
            ui.die(f"Quedaron placeholders sin reemplazar en el YAML: {left}")
        return text

    def install_config(self, sys_scripts: Path, tmpdir: Path, radarr, sonarr) -> None:
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
