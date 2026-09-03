"""nginx + fail2ban: la capa que da a internet.

A diferencia de Radarr o SABnzbd, estos dos no tienen API: se configuran con
archivos. Lo unico que hay que DECIDIR es si el geo-bloqueo se activa, y eso
depende de si el .env trae credenciales de MaxMind. El resto es copiar los
archivos de configs/ a /srv/config, que es lo que los contenedores montan.

Los dos corren en el compose (antes iban instalados en el host via
setup-host.sh). Consecuencia importante que se ve en jail.d/jellyfin.local:
con nginx en un contenedor, el trafico de internet ya no pasa por la cadena
INPUT del firewall sino por el forward de Docker, asi que fail2ban tiene que
banear en DOCKER-USER.
"""

import filecmp
import re
import tempfile
from pathlib import Path

from ..tools import config, sh, ui

# Perfil del compose que levanta el contenedor geoipupdate. Sin credenciales
# esa imagen sale con error, asi que no se activa.
GEO_PROFILE = "geo"

# Placeholder que traia el env.example viejo: si quedo pegado tal cual, es lo
# mismo que no haber configurado nada.
_PLACEHOLDER = "TU_LICENSE_KEY"

_COUNTRY_RE = re.compile(r"^[A-Za-z]{2}$")


class Proxy:
    def __init__(self, cfg: config.Config, repo_root: Path):
        self.cfg = cfg
        self.repo_root = repo_root
        self.src = repo_root / "configs"

        self.account_id = cfg.env("MAXMIND_ACCOUNT_ID", required=False)
        self.license_key = cfg.env("MAXMIND_LICENSE_KEY", required=False)
        if self.license_key == _PLACEHOLDER:
            self.license_key = ""
        if self.license_key:
            ui.add_secret(self.license_key)

        self.countries = cfg.get(
            "nginx", "geoBlock", "countries", default=[], required=False
        )
        for code in self.countries:
            if not _COUNTRY_RE.match(str(code)):
                ui.die(
                    f"'{code}' no es un codigo ISO de pais de 2 letras "
                    f"(.nginx.geoBlock.countries en {cfg.conf_file})."
                )

    @property
    def geo_enabled(self) -> bool:
        return bool(self.account_id and self.license_key and self.countries)

    @property
    def compose_profiles(self) -> list[str]:
        return [GEO_PROFILE] if self.geo_enabled else []

    # -- configs ----------------------------------------------------------

    def install_configs(self, sys_scripts: Path) -> bool:
        """Copia las configs del repo a /srv/config. Devuelve si algo cambio.

        El 'cambio' se calcula aca y no en bash porque es lo que decide si hay
        que recargar los contenedores despues: sin eso, editar un .conf del
        repo no tendria ningun efecto hasta el proximo reinicio manual.
        """
        with tempfile.TemporaryDirectory(prefix="geoip-") as tmpdir:
            geoip_conf = self._render_geoip_conf(Path(tmpdir))

            pairs = [
                (self.src / "nginx" / "site-confs" / "default.conf",
                 f"{config.NGINX_SITE_CONFS_DIR}/default.conf"),
                (geoip_conf,
                 f"{config.NGINX_SITE_CONFS_DIR}/00-geoip.conf"),
                (self.src / "nginx" / "proxy_jellyfin.conf",
                 f"{config.NGINX_CONF_DIR}/proxy_jellyfin.conf"),
                (self.src / "fail2ban" / "filter.d" / "jellyfin.conf",
                 f"{config.F2B_FILTER_DIR}/jellyfin.conf"),
                (self.src / "fail2ban" / "jail.d" / "jellyfin.local",
                 f"{config.F2B_JAIL_DIR}/jellyfin.local"),
            ]

            changed = any(not _same(src, dst) for src, dst in pairs)

            flat: list[str] = []
            for src, dst in pairs:
                flat += [str(src), dst]
            sh.run_script(
                sys_scripts / "install-conf.sh", config.PUID, config.PGID, *flat
            )

        return changed

    def _render_geoip_conf(self, tmpdir: Path) -> Path:
        """Devuelve el 00-geoip.conf que corresponde, listo para copiar.

        Son dos archivos distintos y no un sed sobre uno solo: el server block
        usa $allowed_country siempre, y nginx no arranca con una variable que
        nadie define. Con el geo apagado igual hace falta un map que la fije
        en 'yes'.
        """
        if not self.geo_enabled:
            if not self.countries:
                # Lista vacia = "no pasa ningun pais", que dejaria el sitio
                # inaccesible hasta para vos. Se interpreta como apagado.
                ui.warn("Sin paises en .nginx.geoBlock.countries: "
                        "el stack levanta SIN geo-bloqueo.")
            else:
                ui.warn("Sin credenciales de MaxMind en el .env: "
                        "el stack levanta SIN geo-bloqueo.")
            return self.src / "nginx" / "geoip-off.conf"

        ui.info(f"Geo-bloqueo activo. Paises permitidos: {', '.join(self.countries)}")
        tmpl = (self.src / "nginx" / "geoip-on.conf.tmpl").read_text()
        lines = "\n".join(f"    {str(c).upper()} yes;" for c in self.countries)

        rendered = tmpdir / "00-geoip.conf"
        rendered.write_text(tmpl.replace("{{COUNTRIES}}", lines))
        return rendered

    # -- geoip ------------------------------------------------------------

    def sync_geoip_db(self, sys_scripts: Path) -> None:
        """Baja la base GeoLite2 antes de que nginx arranque.

        No es opcional cuando el geo esta activo: la directiva geoip2 abre el
        .mmdb al parsear la config, asi que sin la base nginx no levanta.
        """
        sh.run_script(sys_scripts / "geoip-sync.sh", self.repo_root)

    # -- recarga ----------------------------------------------------------

    def reload(self) -> None:
        """Aplica los cambios de config en los contenedores que ya corrian.

        Si no estan corriendo no hay nada que hacer: los levanta el compose
        con la config nueva ya puesta.
        """
        if _running(config.NGINX_CONTAINER):
            # nginx -t primero: valida y aborta con el error a la vista antes
            # de mandar el reload, que con la config rota no hace nada y solo
            # deja una linea suelta en el error.log.
            sh.run("docker", "exec", config.NGINX_CONTAINER, "nginx", "-t")
            sh.run("docker", "exec", config.NGINX_CONTAINER, "nginx", "-s", "reload")
            ui.info("nginx recargado.")

        if _running(config.F2B_CONTAINER):
            # fail2ban no tiene reload de jails nuevos que sea confiable.
            sh.run("docker", "restart", config.F2B_CONTAINER)
            ui.info("fail2ban reiniciado.")


def _same(src: Path, dst: str) -> bool:
    dst_path = Path(dst)
    return dst_path.is_file() and filecmp.cmp(src, dst_path, shallow=False)


def _running(container: str) -> bool:
    out = sh.run(
        "docker", "inspect", "-f", "{{.State.Running}}", container, check=False
    )
    return out.strip() == "true"
