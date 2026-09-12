"""Seerr: el front de requests (ex Jellyseerr).

EL PROYECTO SE LLAMA SEERR, NO JELLYSEERR: Overseerr y Jellyseerr se fusionaron
en Seerr (ghcr.io/seerr-team/seerr) y las dos imagenes viejas quedaron sin
mantenimiento. La API sigue siendo /api/v1/* y hereda casi todo de Overseerr,
asi que la doc vieja parece valida y no lo es: la spec publicada declara
JellyfinSettings con 'hostname/adminUser/adminPass' y el servidor real usa
'ip/port/useSsl/urlBase'. Todo lo de aca esta sacado del codigo de la version
que corre, no de la spec.

EL HUEVO Y LA GALLINA DE LA AUTENTICACION, que es lo que ordena todo el flujo:
Seerr genera una API key sola en el primer arranque y la deja en settings.json,
pero esa key NO alcanza para configurarlo de cero. El middleware que la valida
(server/middleware/auth.ts) la traduce al USUARIO 1, y en una instalacion nueva
ese usuario todavia no existe: la key resuelve a nadie y todos los endpoints de
settings contestan 403.

El unico endpoint abierto es POST /auth/jellyfin, y esta abierto justamente
para esto: si la base no tiene usuarios, crea al primero como admin. De paso
deja configurado el enlace con Jellyfin, porque para logearte necesita saber a
que servidor pegarle. O sea que una sola llamada resuelve las dos cosas:

    1. POST /auth/jellyfin  ->  crea el admin Y enlaza Jellyfin  (sin auth)
    2. de ahi en adelante   ->  X-Api-Key contra settings.json   (ya hay user 1)

Reusa JELLYFIN_USER / JELLYFIN_PASSWORD del .env: el admin de Seerr ES el admin
de Jellyfin, no hay credenciales propias que inventar. Seerr se crea su propia
API key del lado de Jellyfin (aparece como 'Seerr' en el Dashboard).
"""

import json
from pathlib import Path

from ..tools import api, config, ui

SETTINGS_JSON = Path("/srv/config/seerr/settings.json")

# MediaServerType del server (server/constants/server.ts). El JELLYFIN va en el
# body de /auth/jellyfin, y sin el valor correcto la creacion del admin falla
# con NoAdminUser aunque las credenciales esten bien.
MEDIA_SERVER_JELLYFIN = 2
MEDIA_SERVER_NOT_CONFIGURED = 4

# Radarr pide una "minimum availability" para las peliculas que se agregan.
# 'released' = recien cuando salio en digital; es lo que evita que Radarr se
# quede buscando meses una pelicula que todavia esta en el cine.
MIN_AVAILABILITY = "released"


class Seerr:
    name = "Seerr"
    container = "seerr"
    port = 5055

    def __init__(self, cfg: config.Config):
        self.cfg = cfg
        self._api_key: str | None = None

        self.admin_email = cfg.get(
            "seerr", "adminEmail", default="", required=False
        )
        self.min_availability = cfg.get(
            "seerr", "radarr", "minimumAvailability",
            default=MIN_AVAILABILITY, required=False,
        )
        self.season_folders = cfg.get(
            "seerr", "sonarr", "seasonFolders", default=True, required=False
        )

    @property
    def url(self) -> str:
        """Por el tailnet: el compose lo publica en ${TAILSCALE_IP}:5055."""
        return f"http://{self.cfg.tailscale_ip}:{self.port}"

    @property
    def internal_url(self) -> str:
        """La que usan los otros contenedores por la red 'media' (hoy, el
        proxy de Seerr de Moonbase desde Jellyfin)."""
        return f"http://{self.container}:{self.port}"

    @property
    def api_key(self) -> str:
        """La saca de settings.json, como SABnzbd del ini y los *arr del xml.

        Seerr la genera sola en el primer arranque; nunca hay que crearla.
        """
        if self._api_key is None:
            if not SETTINGS_JSON.is_file():
                ui.die(
                    f"No encuentro {SETTINGS_JSON}. "
                    f"¿El contenedor '{self.container}' arranco al menos una vez?"
                )
            try:
                data = json.loads(SETTINGS_JSON.read_text())
            except json.JSONDecodeError as exc:
                ui.die(f"{SETTINGS_JSON} no es JSON valido: {exc}")

            key = (data.get("main") or {}).get("apiKey", "")
            if not key:
                ui.die(f"No pude extraer main.apiKey de {SETTINGS_JSON}")
            self._api_key = key
            ui.add_secret(key)
        return self._api_key

    # -- HTTP -------------------------------------------------------------
    def call(self, method: str, path: str, data=None, auth: bool = True) -> api.Response:
        headers = {"X-Api-Key": self.api_key} if auth else {}
        return api.request(method, f"{self.url}/api/v1{path}", headers=headers, data=data)

    def wait_ready(self, attempts: int = 45, delay: int = 2) -> None:
        """Espera por /status, que no pide auth.

        Tiene que ser un endpoint publico: en la primera corrida todavia no hay
        usuario 1 y cualquier otro endpoint contestaria 403 aunque el servidor
        este perfecto.
        """
        ok = ui.wait_for(
            f"Esperando a que {self.name} responda",
            lambda: self.call("GET", "/status", auth=False).ok,
            attempts,
            delay,
        )
        if not ok:
            ui.die(
                f"{self.name} no respondio en {self.url} despues de "
                f"{attempts * delay}s. Mira 'docker logs {self.container}'."
            )

    @property
    def version(self) -> str:
        return (self.call("GET", "/status", auth=False).json() or {}).get("version", "?")

    @property
    def initialized(self) -> bool:
        """True cuando ya paso el asistente inicial."""
        resp = self.call("GET", "/settings/public", auth=False)
        if not resp.ok:
            ui.die(f"{self.name} no contesta /settings/public (HTTP {resp.status}).")
        # Default True: si no podemos leer el campo, no corremos el setup sobre
        # una instancia que no sabemos interpretar.
        return (resp.json() or {}).get("initialized", True)

    # -- Enlace con Jellyfin ----------------------------------------------
    @property
    def _jellyfin_settings(self) -> dict:
        """El enlace con Jellyfin, tal como lo tiene guardado Seerr.

        PIDE API KEY, asi que recien sirve una vez que existe el usuario admin.
        Para saber SI hay que crearlo esta media_server_linked, que mira el
        endpoint publico.

        SE LEE DE ACA Y NO DE /settings/jellyfin/library, que seria lo obvio
        para mirar las librerias: ese GET tiene efecto de escritura (ver
        enable_libraries).
        """
        resp = self.call("GET", "/settings/jellyfin")
        if not resp.ok:
            ui.die(f"No pude leer la config de Jellyfin de {self.name} "
                   f"(HTTP {resp.status}).")
        return resp.json() or {}

    @property
    def media_server_linked(self) -> bool:
        """Si ya se corrio el enlace con Jellyfin.

        SALE DEL ENDPOINT PUBLICO A PROPOSITO: este es el chequeo que decide si
        hay que crear al admin, o sea que corre justo cuando la API key todavia
        no sirve para nada (resuelve al usuario 1, que no existe). Preguntarlo
        por /settings/jellyfin, que seria lo natural, da 403 en la unica
        corrida donde la respuesta importa.

        Seerr deja mediaServerType en NOT_CONFIGURED hasta que el enlace se
        guarda, y lo hace en la misma request que crea al admin: si esto es
        True, el usuario 1 existe.
        """
        resp = self.call("GET", "/settings/public", auth=False)
        if not resp.ok:
            ui.die(f"{self.name} no contesta /settings/public (HTTP {resp.status}).")
        kind = (resp.json() or {}).get("mediaServerType", MEDIA_SERVER_NOT_CONFIGURED)
        return kind != MEDIA_SERVER_NOT_CONFIGURED

    def link_jellyfin(self, jellyfin) -> None:
        """Crea el usuario admin y enlaza Jellyfin. Idempotente.

        Es la unica llamada del flujo que va SIN API key, y la unica ventana
        para crear al usuario 1 (ver el docstring del modulo).
        """
        if self.media_server_linked:
            ui.info(f"{self.name} ya esta enlazado con Jellyfin "
                    f"({self._jellyfin_settings.get('ip') or '?'}).")
            return

        if not (jellyfin.user and jellyfin.password):
            ui.die(
                "Necesito JELLYFIN_USER y JELLYFIN_PASSWORD en el .env: el "
                f"admin de {self.name} se crea logueandose contra Jellyfin."
            )

        ui.info(f"Creando el admin de {self.name} como '{jellyfin.user}'...")
        ui.detail(f"Jellyfin: {jellyfin.internal_url}")

        # 'hostname' es el HOST PELADO, no una URL: el server arma
        # http://<hostname>:<port><urlBase> por su cuenta (utils/getHostname.ts).
        # Mandarle 'http://jellyfin' daria 'http://http://jellyfin:8096'.
        #
        # Y va el nombre del contenedor porque el que se conecta a Jellyfin es
        # Seerr, desde adentro de la red 'media'.
        resp = self.call("POST", "/auth/jellyfin", {
            "username": jellyfin.user,
            "password": jellyfin.password,
            "hostname": jellyfin.container,
            "port": jellyfin.port,
            "useSsl": False,
            "urlBase": "",
            "email": self.admin_email or jellyfin.user,
            "serverType": MEDIA_SERVER_JELLYFIN,
        }, auth=False)

        if not resp.ok:
            ui.warn(f"El enlace con Jellyfin fallo (HTTP {resp.status}):")
            print(resp.errors())
            if resp.status == 403:
                ui.warn(f"403 = el usuario '{jellyfin.user}' no es admin en Jellyfin.")
            ui.die(f"No pude crear el admin de {self.name}.")

        if not self.media_server_linked:
            ui.die(f"{self.name} acepto el login pero no guardo el enlace con Jellyfin.")
        ui.info("Admin creado y Jellyfin enlazado (API key 'Seerr' creada en Jellyfin).")

    # -- Librerias ---------------------------------------------------------
    def _libraries(self, enable: list[str], sync: bool = False) -> list:
        """Una pasada por /settings/jellyfin/library. SIEMPRE ESCRIBE.

        Es una trampa heredada de Overseerr: aunque sea un GET, este endpoint
        modifica. Y lo hace en dos tiempos, que es lo que importa entender:

          1. con ?sync=true relee las librerias de Jellyfin, CONSERVANDO el
             flag 'enabled' de las que ya conocia;
          2. despues, siempre, reemplaza el conjunto de prendidas por lo que
             venga en ?enable. Sin ese parametro el conjunto queda VACIO.

        O sea que el paso 2 pisa lo que conservo el paso 1: sincronizar y
        prender tienen que ir en la MISMA request. Un ?sync=true suelto (que es
        lo que uno escribiria para "solo mirar que hay") apaga todas las
        librerias.
        """
        query = "?sync=true" if sync else "?"
        if enable:
            query += ("&" if sync else "") + "enable=" + ",".join(enable)

        resp = self.call("GET", f"/settings/jellyfin/library{query}")
        if resp.ok:
            return resp.json() or []

        ui.warn(f"Fallo la lectura de librerias de Jellyfin (HTTP {resp.status}):")
        print(resp.errors())
        if resp.status == 404:
            ui.warn("404 = Jellyfin todavia no tiene ninguna libreria creada.")
            ui.warn("Las crea el paso 11 desde .jellyfin.libraries del conf: si "
                    "llegaste aca sin ellas, mira si ese paso las salteo.")
            return []
        ui.die("No pude leer las librerias de Jellyfin.")

    def enable_libraries(self) -> None:
        """Sincroniza las librerias de Jellyfin y las prende. Idempotente.

        Sin ninguna libreria prendida, Seerr no sabe que hay bajado y te ofrece
        pedir cosas que ya estan en la biblioteca.
        """
        # El estado se lee de /settings/jellyfin y no del endpoint de librerias
        # justamente porque ese escribe: preguntarle que hay prendido lo apaga.
        current = self._jellyfin_settings.get("libraries") or []
        keep = [lib["id"] for lib in current if lib.get("enabled")]

        # El sync va con las que ya estaban prendidas: si se mandara solo, las
        # apagaria a todas antes de devolver la lista.
        libraries = self._libraries(enable=keep, sync=True)
        if not libraries:
            ui.warn("Jellyfin no devolvio ninguna libreria: no hay nada que prender.")
            ui.warn("Las crea el paso 11 desde .jellyfin.libraries del conf.")
            return

        # Si ya habia alguna prendida, la eleccion es del usuario y no se pisa.
        if keep:
            ui.info(f"Ya hay {len(keep)} libreria(s) prendida(s). No se tocan:")
            for lib in libraries:
                if lib.get("enabled"):
                    ui.detail(f"  {lib.get('name')}")
            return

        # Primera configuracion: se prenden todas las que trajo el sync.
        libraries = self._libraries(enable=[lib["id"] for lib in libraries])
        ui.info(f"{len(libraries)} libreria(s) de Jellyfin prendidas:")
        for lib in libraries:
            ui.detail(f"  {lib.get('name')} ({lib.get('type', '?')})")

        # El scan completo corre en background: Seerr recorre la biblioteca y
        # marca como disponible lo que ya esta bajado. No se espera a que
        # termine, puede tardar segun el tamaño de la biblioteca.
        started = self.call("POST", "/settings/jellyfin/sync", {"start": True})
        if started.ok:
            ui.info("Scan inicial de la biblioteca lanzado (corre en background).")
        else:
            ui.warn(f"No pude lanzar el scan inicial (HTTP {started.status}). "
                    "Se puede correr a mano desde Settings -> Jobs.")

    # -- Radarr / Sonarr ---------------------------------------------------
    def connect_servarr(self, app, root_folder: str, profile_name: str) -> None:
        """Carga Radarr o Sonarr como destino de los pedidos. Idempotente.

        POR QUE UN /test ANTES DE GUARDAR, aparte de para validar: la respuesta
        del test es de donde salen el quality profile y el root folder. Seerr
        no los guarda por nombre sino por ID, y esos IDs son de la instancia de
        Radarr/Sonarr: no hay forma de saberlos sin preguntarle.
        """
        kind = app.name.lower()   # 'radarr' | 'sonarr'

        existing = self.call("GET", f"/settings/{kind}")
        if not existing.ok:
            ui.die(f"No pude listar los {app.name} de {self.name} "
                   f"(HTTP {existing.status}).")
        for item in existing.json() or []:
            if item.get("name") == app.name:
                ui.warn(f"'{app.name}' ya esta cargado en {self.name} "
                        f"(id {item.get('id')}). No se duplica.")
                return

        payload = {
            "name": app.name,
            # host y puerto INTERNOS: el que se conecta es el contenedor de
            # Seerr por la red 'media', no vos por Tailscale.
            "hostname": app.container,
            "port": app.port,
            "apiKey": app.api_key,
            "useSsl": False,
            "baseUrl": "",
            "is4k": False,
            "isDefault": True,
            "syncEnabled": True,
            # preventSearch False = al aprobar un pedido, Radarr/Sonarr salen a
            # buscarlo de una. Es el punto de tener esto automatizado.
            "preventSearch": False,
            "tags": [],
            "tagRequests": False,
            # Link "abrir en Radarr" del panel de admin. Va la URL de Tailscale
            # porque este la abris vos en el navegador, no el contenedor.
            "externalUrl": app.url,
        }

        ui.info(f"Probando {self.name} -> {app.name} (endpoint /test)...")
        test = self.call("POST", f"/settings/{kind}/test", payload)
        if not test.ok:
            ui.warn(f"El test fallo (HTTP {test.status}):")
            print(test.errors())
            ui.die(f"Abortando: no cargo un {app.name} que no conecta.")
        probe = test.json() or {}

        payload["activeProfileId"], payload["activeProfileName"] = self._pick_profile(
            probe.get("profiles") or [], profile_name, app.name
        )
        payload["activeDirectory"] = self._pick_root_folder(
            probe.get("rootFolders") or [], root_folder, app.name
        )

        if kind == "radarr":
            payload["minimumAvailability"] = self.min_availability
        else:
            payload["enableSeasonFolders"] = self.season_folders
            # Solo existe en Sonarr v3: en v4 los language profiles se sacaron
            # y el test devuelve null. Mandarlo igual guarda un id invalido.
            lang = probe.get("languageProfiles")
            if lang:
                payload["activeLanguageProfileId"] = lang[0]["id"]

        ui.detail(f"Quality profile: {payload['activeProfileName']}")
        ui.detail(f"Root folder    : {payload['activeDirectory']}")

        saved = self.call("POST", f"/settings/{kind}", payload)
        if not saved.ok:
            ui.warn(f"Fallo al cargar {app.name} (HTTP {saved.status}):")
            print(saved.errors())
            ui.die(f"No se pudo cargar {app.name} en {self.name}.")
        ui.info(f"'{app.name}' cargado en {self.name} "
                f"(id {(saved.json() or {}).get('id', '?')})")

    @staticmethod
    def _pick_profile(profiles: list, wanted: str, app_name: str) -> tuple[int, str]:
        """Elige el quality profile por nombre, con el primero como fallback.

        El nombre que se busca es el que aplica Recyclarr (sale del mismo
        services_setup.conf): sin esto, Seerr pediria con un perfil y Recyclarr
        afinaria otro.
        """
        if not profiles:
            ui.die(f"{app_name} no devolvio ningun quality profile.")

        for profile in profiles:
            if profile.get("name") == wanted:
                return profile["id"], profile["name"]

        fallback = profiles[0]
        ui.warn(
            f"{app_name} no tiene el quality profile '{wanted}'; uso "
            f"'{fallback['name']}'. (¿Corrio bien el paso de Recyclarr?)"
        )
        return fallback["id"], fallback["name"]

    @staticmethod
    def _pick_root_folder(folders: list, wanted: str, app_name: str) -> str:
        if not folders:
            ui.die(f"{app_name} no devolvio ningun root folder.")

        for folder in folders:
            if folder.get("path") == wanted:
                return wanted

        fallback = folders[0]["path"]
        ui.warn(
            f"{app_name} no tiene el root folder '{wanted}'; uso '{fallback}'."
        )
        return fallback

    # -- Cierre ------------------------------------------------------------
    def finish_setup(self) -> None:
        """Marca el asistente como completo.

        Hasta que no se llama, la web redirige todo a /setup por mas que la
        config este entera.
        """
        resp = self.call("POST", "/settings/initialize")
        if not resp.ok:
            ui.warn(f"Fallo al cerrar el asistente (HTTP {resp.status}):")
            print(resp.errors())
            ui.die(f"No pude marcar {self.name} como inicializado.")
        ui.info(f"{self.name} marcado como inicializado.")
