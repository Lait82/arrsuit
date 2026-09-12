"""Jellyfin: API key, borrado de segmentos y avisos de biblioteca.

LA API KEY NO SE PUEDE DERIVAR DE UN ARCHIVO, como si pasa con los *arr (que la
generan solas en su config.xml). Jellyfin las crea a pedido y las guarda
hasheadas. Y para crear una hace falta estar autenticado: POST /Auth/Keys pide
elevacion. O sea que el orquestador tiene que loguearse primero.

De ahi el flujo, que imita al de TAILSCALE_IP: el .env aporta lo que un humano
sabe (usuario y contraseña), el script deriva la API key y la ESCRIBE en el .env
para las corridas siguientes.

    JELLYFIN_USER + JELLYFIN_PASSWORD  ->  los ponés vos
    JELLYFIN_API_KEY                   ->  la escribe este modulo

Detalle de la API que obliga a hacer dos llamadas: POST /Auth/Keys responde 204
sin cuerpo, no devuelve la key que acaba de crear. Hay que pedir GET /Auth/Keys
despues y buscarla por nombre de app.

Lo otro que configura es el borrado de segmentos HLS: Jellyfin escribe los .ts
del transcode en su cache y por defecto los deja hasta terminar. Si el cliente
corta a la mitad quedan huerfanos acumulandose.
"""

import time
from pathlib import Path

from ..tools import api, config, ui

# Nombre con el que la key aparece en Dashboard -> API Keys. Tambien es como la
# reconocemos para no crear una nueva en cada corrida.
APP_NAME = "arrsuit-orchestrator"

# Claves de EncodingOptions (encoding.xml). Se chequea que existan antes de
# escribirlas: si Jellyfin es viejo y no las tiene, un POST con claves
# desconocidas se guarda igual y no hace nada. Mejor avisar.
KEY_DELETE_SEGMENTS = "EnableSegmentDeletion"
KEY_KEEP_SECONDS = "SegmentKeepSeconds"

ENV_API_KEY = "JELLYFIN_API_KEY"

# El plugin de Moonfin se llama 'Moonbase' en el catalogo: Moonfin es el
# cliente, Moonbase es el companion del servidor.
MOONBASE_PLUGIN = "Moonbase"


class Jellyfin:
    # Mismos nombres que en Servarr: quien consume esto (la notificacion de
    # Radarr/Sonarr) no tiene que saber de que clase viene.
    name = "Jellyfin"
    container = "jellyfin"
    port = 8096

    def __init__(self, cfg: config.Config):
        self.cfg = cfg
        self.api_key = cfg.env(ENV_API_KEY, required=False)
        self.user = cfg.env("JELLYFIN_USER", required=False)
        self.password = cfg.env("JELLYFIN_PASSWORD", required=False)

        for secret in (self.api_key, self.password):
            if secret:
                ui.add_secret(secret)

        # Solo se usan la primera vez, cuando corre el asistente. Despues el
        # dueño de estos valores es Jellyfin: cambiarlos aca no los reescribe.
        self.server_name = cfg.get(
            "jellyfin", "setup", "serverName", default="JellyfinServer", required=False
        )
        self.ui_culture = cfg.get(
            "jellyfin", "setup", "uiCulture", default="en-US", required=False
        )
        self.metadata_country = cfg.get(
            "jellyfin", "setup", "metadataCountryCode", default="US", required=False
        )
        self.metadata_language = cfg.get(
            "jellyfin", "setup", "preferredMetadataLanguage", default="en",
            required=False,
        )

        self.delete_segments = cfg.get(
            "jellyfin", "transcoding", "deleteSegments", default=True, required=False
        )
        self.keep_seconds = cfg.get(
            "jellyfin", "transcoding", "keepSegmentsSeconds",
            default=3600, required=False,
        )

        self.libraries = cfg.get(
            "jellyfin", "libraries", default=[], required=False
        )
        self.plugins = cfg.get("jellyfin", "plugins", default=[], required=False)

    @property
    def configured(self) -> bool:
        """Hay con que trabajar: o ya tenemos key, o podemos crearla."""
        return bool(self.api_key or (self.user and self.password))

    @property
    def url(self) -> str:
        """Por el tailnet: es como el host alcanza a Jellyfin (el compose lo
        publica en ${TAILSCALE_IP}:8096, no en 0.0.0.0)."""
        return f"http://{self.cfg.tailscale_ip}:{self.port}"

    @property
    def internal_url(self) -> str:
        """La que usan Radarr y Sonarr, que le pegan por la red 'media'."""
        return f"http://{self.container}:{self.port}"

    # -- HTTP -------------------------------------------------------------
    def call(self, method: str, path: str, data=None, token: str = "") -> api.Response:
        """'token' permite usar el AccessToken de sesion mientras todavia no
        hay API key; el resto del tiempo va la key.

        EL TOKEN VA EN 'Authorization' Y NO EN 'X-Emby-Token': ese header era
        un alias heredado de Emby y Jellyfin 12 lo saco. Con el, un servidor 12
        contesta 401 a TODO aunque el token sea valido. El esquema
        'MediaBrowser Token="..."' es el nativo y lo entienden las dos: 10.x lo
        acepta desde siempre porque es el que usan sus propios clientes.
        """
        auth = token or self.api_key
        return api.request(
            method,
            f"{self.url}{path}",
            headers={"Authorization": f'MediaBrowser Token="{auth}"'},
            data=data,
            secret=auth or None,
        )

    def wait_ready(self, attempts: int = 90, delay: int = 2) -> None:
        """Espera por un endpoint PUBLICO.

        /System/Info/Public no pide auth: sirve para saber si el servidor esta
        arriba incluso antes de tener API key, que es justo el caso de la
        primera corrida.

        La espera es MAS LARGA que la del resto de las apps (3 min contra 1):
        mientras arranca, Jellyfin contesta 503 'Server is loading' en vez de
        no contestar, y ese arranque incluye crear y migrar su base SQLite y
        cargar los plugins. Con el minuto que le alcanza a los *arr, la primera
        corrida aborta un paso antes del final con el servidor sano.

        NO ALCANZA CON QUE CONTESTE 200: mientras carga, Jellyfin 12 devuelve
        por este mismo endpoint un JSON RECORTADO Y EN camelCase, sin el
        StartupWizardCompleted que mira wizard_pending. Ese campo ausente cae
        al default (asistente completo), asi que la corrida se saltea el
        asistente y muere mas adelante en el login, echandole la culpa a las
        credenciales del .env. Por eso se espera al campo y no al codigo HTTP.
        """
        def ready() -> bool:
            resp = api.request("GET", f"{self.url}/System/Info/Public")
            return resp.ok and "StartupWizardCompleted" in (resp.json() or {})

        ok = ui.wait_for(
            "Esperando a que Jellyfin responda",
            ready,
            attempts,
            delay,
        )
        if not ok:
            ui.die(
                f"Jellyfin no respondio en {self.url} despues de "
                f"{attempts * delay}s. Mira 'docker logs jellyfin'."
            )

    # -- Asistente inicial ------------------------------------------------
    def _startup(self, method: str, path: str, data=None) -> api.Response:
        """Llamada a /Startup/*: va SIN token.

        Mientras el asistente no termino, esos endpoints corren con la policy
        FirstTimeSetupOrElevated, que los deja pasar sin autenticar. Es la unica
        ventana para crear el primer usuario, porque todavia no hay con que
        loguearse. Apenas se llama a /Startup/Complete, pasan a pedir admin.
        """
        return api.request(method, f"{self.url}{path}", data=data)

    @property
    def wizard_pending(self) -> bool:
        resp = api.request("GET", f"{self.url}/System/Info/Public")
        if not resp.ok:
            ui.die(f"Jellyfin no contesta /System/Info/Public (HTTP {resp.status}).")
        # El default es True para no intentar el wizard sobre un servidor que no
        # sabemos leer: si el campo no viene, se asume configurado.
        return not (resp.json() or {}).get("StartupWizardCompleted", True)

    def complete_wizard(self) -> None:
        """Corre el asistente inicial por API. Idempotente."""
        if not self.wizard_pending:
            ui.info("El asistente inicial ya estaba completo.")
            return

        if not (self.user and self.password):
            ui.die(
                "El asistente inicial de Jellyfin esta pendiente y necesito "
                "JELLYFIN_USER y JELLYFIN_PASSWORD en el .env para crear el "
                "usuario admin."
            )

        ui.info(f"Corriendo el asistente inicial (admin '{self.user}')...")
        ui.detail(f"Servidor : {self.server_name}")
        ui.detail(f"Idioma   : {self.ui_culture} / metadatos {self.metadata_language}"
                  f" ({self.metadata_country})")

        steps = (
            ("POST", "/Startup/Configuration", {
                "ServerName": self.server_name,
                "UICulture": self.ui_culture,
                "MetadataCountryCode": self.metadata_country,
                "PreferredMetadataLanguage": self.metadata_language,
            }),
            # ESTE GET NO ES OPCIONAL, aunque no usemos la respuesta: es el que
            # crea el usuario por defecto ('abc'). El POST de abajo RENOMBRA a
            # ese usuario, no crea uno, asi que sin nadie a quien renombrar
            # contesta 404. El wizard web hace la misma secuencia.
            ("GET", "/Startup/User", None),
            ("POST", "/Startup/User", {"Name": self.user, "Password": self.password}),
            # Remote access ON: a Jellyfin se entra desde internet por nginx.
            # El mapeo de puertos es UPnP contra el router, que en un VPS no
            # existe: pedirlo solo agrega un error en el log de arranque.
            ("POST", "/Startup/RemoteAccess", {
                "EnableRemoteAccess": True,
                "EnableAutomaticPortMapping": False,
            }),
            ("POST", "/Startup/Complete", None),
        )
        for method, path, payload in steps:
            resp = self._startup(method, path, payload)
            if not resp.ok:
                ui.die(f"Fallo el asistente en {method} {path} (HTTP {resp.status}).")

        if self.wizard_pending:
            ui.die("Corri el asistente pero Jellyfin lo sigue marcando pendiente.")
        ui.info("Asistente completado.")

    # -- API key ----------------------------------------------------------
    def ensure_api_key(self) -> None:
        """Deja self.api_key usable, creandola si hace falta. Idempotente."""
        if self.api_key and self._key_works(self.api_key):
            ui.info("La API key del .env funciona.")
            return

        if self.api_key:
            ui.warn("La API key del .env ya no sirve; genero una nueva.")
        if not (self.user and self.password):
            ui.die(
                "Necesito JELLYFIN_USER y JELLYFIN_PASSWORD en el .env: crear "
                "una API key requiere estar autenticado."
            )

        token = self._authenticate()

        # Idempotencia: si ya existe una key con nuestro nombre de app se reusa.
        # Sin esto cada corrida dejaria una key nueva colgada en el Dashboard.
        key = self._find_key(token)
        if key:
            ui.info(f"Reuso la API key existente '{APP_NAME}'.")
        else:
            ui.info(f"Creando la API key '{APP_NAME}'...")
            created = self.call("POST", f"/Auth/Keys?app={APP_NAME}", token=token)
            if not created.ok:
                ui.die(f"No pude crear la API key (HTTP {created.status}).")
            # Responde 204 sin cuerpo: hay que ir a buscarla.
            key = self._find_key(token)
            if not key:
                ui.die("Cree la API key pero no aparece al listarlas.")

        self.api_key = key
        ui.add_secret(key)
        self._persist_api_key(key)

    def _key_works(self, key: str) -> bool:
        return self.call("GET", "/System/Info", token=key).ok

    def _authenticate(self) -> str:
        """Login usuario/contraseña -> AccessToken de sesion."""
        ui.info(f"Autenticando como '{self.user}'...")
        resp = api.request(
            "POST",
            f"{self.url}/Users/AuthenticateByName",
            headers={
                # Jellyfin RECHAZA el login sin este header: necesita saber que
                # cliente se conecta para registrar la sesion.
                "Authorization": (
                    f'MediaBrowser Client="{APP_NAME}", Device="configure-stack", '
                    f'DeviceId="{APP_NAME}", Version="1.0.0"'
                )
            },
            data={"Username": self.user, "Pw": self.password},
            secret=self.password,
        )
        if not resp.ok:
            ui.warn(f"El login fallo (HTTP {resp.status}).")
            ui.die("Revisá JELLYFIN_USER y JELLYFIN_PASSWORD en el .env.")

        token = (resp.json() or {}).get("AccessToken", "")
        if not token:
            ui.die("Jellyfin acepto el login pero no devolvio AccessToken.")
        ui.add_secret(token)
        return token

    def _find_key(self, token: str) -> str:
        """Busca una key ya creada con nuestro nombre de app."""
        resp = self.call("GET", "/Auth/Keys", token=token)
        if not resp.ok:
            ui.die(f"No pude listar las API keys (HTTP {resp.status}).")
        for item in (resp.json() or {}).get("Items", []):
            if item.get("AppName") == APP_NAME:
                return item.get("AccessToken", "")
        return ""

    def _persist_api_key(self, key: str) -> None:
        """Escribe la key en el .env y recarga la config.

        VA EN PYTHON Y NO EN UN SCRIPT DE BASH, a diferencia del resto de lo que
        toca archivos en este repo: el valor es un secreto, y pasarlo como
        argumento a un script lo deja visible en 'ps aux' para cualquier usuario
        del host mientras dure la llamada.
        """
        env_file: Path = self.cfg.env_file
        lines = env_file.read_text().splitlines()

        for i, line in enumerate(lines):
            if line.strip().startswith(f"{ENV_API_KEY}="):
                lines[i] = f"{ENV_API_KEY}={key}"
                break
        else:
            lines += ["", "# La escribe el orquestador (pylib/apps/jellyfin.py)",
                      f"{ENV_API_KEY}={key}"]

        env_file.write_text("\n".join(lines) + "\n")

        # El .env ahora tiene una contraseña de admin y una API key. Venia con
        # permisos 644, o sea legible por cualquier usuario del host.
        env_file.chmod(0o600)

        self.cfg.reload_env()
        ui.info(f"API key guardada en {env_file.name} (permisos 600).")

    # -- Transcoding ------------------------------------------------------
    def configure_transcoding(self) -> None:
        """Prende el borrado de segmentos HLS ya consumidos.

        Se lee la config entera y se reescribe entera: el endpoint reemplaza el
        objeto completo, asi que mandar solo las dos claves borraria todo el
        resto de los ajustes de encoding.
        """
        resp = self.call("GET", "/System/Configuration/encoding")
        if not resp.ok:
            ui.die(f"No pude leer la config de encoding (HTTP {resp.status}).")

        encoding = resp.json() or {}
        missing = [k for k in (KEY_DELETE_SEGMENTS, KEY_KEEP_SECONDS) if k not in encoding]
        if missing:
            ui.warn(
                f"Esta version de Jellyfin no tiene {', '.join(missing)}. "
                "El borrado de segmentos se saltea (se agrego en 10.10)."
            )
            return

        if (encoding[KEY_DELETE_SEGMENTS] == self.delete_segments
                and encoding[KEY_KEEP_SECONDS] == self.keep_seconds):
            ui.info("El borrado de segmentos ya esta como queremos. No se toca.")
            return

        encoding[KEY_DELETE_SEGMENTS] = self.delete_segments
        encoding[KEY_KEEP_SECONDS] = self.keep_seconds

        saved = self.call("POST", "/System/Configuration/encoding", encoding)
        if not saved.ok:
            ui.warn(f"Fallo al guardar la config de encoding (HTTP {saved.status}):")
            print(saved.errors())
            ui.die("No se pudo configurar el borrado de segmentos.")

        estado = "activado" if self.delete_segments else "desactivado"
        ui.info(f"Borrado de segmentos {estado}, retencion {self.keep_seconds}s.")

    # -- Bibliotecas ------------------------------------------------------
    def create_libraries(self) -> None:
        """Crea las bibliotecas del conf. Idempotente (por nombre).

        EL ASISTENTE INICIAL NO CREA NINGUNA: termina con el servidor vacio, y
        sin bibliotecas Jellyfin no muestra nada por mas que /data tenga todo.
        Tampoco las descubre solo, aunque Radarr y Sonarr esten importando ahi.

        Las rutas son las que ve JELLYFIN (/data/...), que es el mismo bind que
        usan Radarr y Sonarr: por eso en el conf se escriben igual que los
        rootFolder de ellos.
        """
        if not self.libraries:
            ui.warn("No hay .jellyfin.libraries en el conf: no se crea ninguna.")
            return

        existing = self.call("GET", "/Library/VirtualFolders")
        if not existing.ok:
            ui.die(f"No pude listar las bibliotecas (HTTP {existing.status}).")
        by_name = {item.get("Name") for item in (existing.json() or [])}

        created = 0
        for lib in self.libraries:
            name, kind, path = lib["name"], lib["type"], lib["path"]
            if name in by_name:
                ui.warn(f"La biblioteca '{name}' ya existe. No se duplica.")
                continue

            ui.info(f"Creando la biblioteca '{name}' ({kind}) en {path}...")
            # Solo se mandan PathInfos y el idioma: todo lo que no venga en
            # LibraryOptions lo completa Jellyfin con sus defaults, que es lo
            # que queremos (el monitor en tiempo real, por ejemplo).
            resp = self.call(
                "POST",
                f"/Library/VirtualFolders?name={api.quote(name)}"
                f"&collectionType={kind}&refreshLibrary=true",
                {
                    "LibraryOptions": {
                        "PathInfos": [{"Path": path}],
                        "PreferredMetadataLanguage": self.metadata_language,
                        "MetadataCountryCode": self.metadata_country,
                    }
                },
            )
            if not resp.ok:
                ui.warn(f"Fallo al crear '{name}' (HTTP {resp.status}):")
                print(resp.errors())
                ui.die(f"No se pudo crear la biblioteca '{name}'.")
            created += 1

        if created:
            ui.info(f"{created} biblioteca(s) creada(s). El escaneo corre en background.")

    # -- Plugins ----------------------------------------------------------
    def install_plugins(self) -> bool:
        """Instala los plugins del conf. Devuelve si hace falta reiniciar.

        Cada plugin trae su repositorio: Jellyfin solo instala desde un
        manifest que tenga cargado, asi que primero se agrega el repo y despues
        se pide el paquete por nombre.
        """
        if not self.plugins:
            return False

        installed = self.call("GET", "/Plugins")
        if not installed.ok:
            ui.die(f"No pude listar los plugins (HTTP {installed.status}).")
        have = {item.get("Name") for item in (installed.json() or [])}

        # Tambien cuenta lo que ya esta en disco: un plugin que quedo bajado
        # pero todavia no cargo (porque el reinicio no llego a pasar) no figura
        # en /Plugins, y sin esto la corrida siguiente lo volveria a bajar.
        have |= {
            d.name.rsplit("_", 1)[0]
            for d in self.plugins_dir.glob("*_*")
            if d.joinpath("meta.json").is_file()
        }

        pending = [p for p in self.plugins if p["name"] not in have]
        for plugin in self.plugins:
            if plugin["name"] in have:
                ui.warn(f"El plugin '{plugin['name']}' ya esta instalado. No se toca.")
        if not pending:
            return False

        for plugin in pending:
            self._add_repository(plugin["repositoryName"], plugin["repository"])

        restart_needed = False
        for plugin in pending:
            name = plugin["name"]
            ui.info(f"Instalando el plugin '{name}'...")
            resp = self.call("POST", f"/Packages/Installed/{api.quote(name)}")
            if not resp.ok:
                ui.warn(f"Fallo la instalacion de '{name}' (HTTP {resp.status}):")
                print(resp.errors())
                if resp.status == 404:
                    ui.warn(f"404 = Jellyfin no encuentra '{name}' en el catalogo. "
                            "Revisá el nombre y la URL del repo en el conf.")
                ui.die(f"No se pudo instalar el plugin '{name}'.")
            restart_needed = True

        # La descarga y el descomprimido son asincronicos: el POST contesta 204
        # apenas encola el trabajo. Sin esta espera, el reinicio de abajo puede
        # agarrar la instalacion a mitad de camino.
        for plugin in pending:
            self._wait_plugin(plugin["name"])

        return restart_needed

    def _add_repository(self, name: str, url: str) -> None:
        """Agrega un repositorio de plugins. Idempotente (por URL).

        OJO: el POST REEMPLAZA la lista entera, no agrega. Mandar solo el repo
        nuevo deja a Jellyfin sin el catalogo oficial, que es de donde sale
        todo lo demas. Por eso se lee la lista actual y se manda completa.
        """
        current = self.call("GET", "/Repositories")
        if not current.ok:
            ui.die(f"No pude listar los repositorios (HTTP {current.status}).")

        repos = current.json() or []
        if any(repo.get("Url") == url for repo in repos):
            return

        ui.info(f"Agregando el repositorio de plugins '{name}'...")
        repos.append({"Name": name, "Url": url, "Enabled": True})
        saved = self.call("POST", "/Repositories", repos)
        if not saved.ok:
            ui.warn(f"Fallo al agregar el repositorio (HTTP {saved.status}):")
            print(saved.errors())
            ui.die(f"No se pudo agregar el repositorio '{name}'.")

    @property
    def plugins_dir(self) -> Path:
        """Donde Jellyfin desempaqueta los plugins, visto desde el HOST.

        El compose monta /srv/config/jellyfin como /config, y adentro los
        plugins cuelgan de /config/data/plugins/<Nombre>_<Version>/.
        """
        return Path(f"{config.CONFIG_HOST_DIR}/{self.container}/data/plugins")

    def _wait_plugin(self, name: str, attempts: int = 30, delay: int = 2) -> None:
        """Espera a que la instalacion termine de bajar y desempaquetar.

        SE MIRA EL DISCO Y NO /Plugins, que seria lo natural: un plugin recien
        instalado aparece ahi SOLO SI el servidor pudo cargarlo en caliente. Si
        no (le pasa a Moonbase, cuyo targetAbi es de una version anterior),
        queda instalado y perfectamente funcional pero invisible en esa lista
        hasta despues del reinicio, y esperarlo ahi daba un timeout sobre algo
        que ya habia salido bien.

        El marcador es el meta.json que Jellyfin escribe al FINAL: el directorio
        solo aparece antes, mientras todavia se esta desempaquetando, y
        reiniciar en ese momento parte la instalacion al medio.
        """
        def unpacked() -> bool:
            return any(
                d.joinpath("meta.json").is_file()
                for d in self.plugins_dir.glob(f"{name}_*")
            )

        if not ui.wait_for(f"Esperando a que baje el plugin '{name}'", unpacked,
                           attempts, delay):
            ui.die(
                f"El plugin '{name}' no aparecio en {self.plugins_dir} despues "
                f"de {attempts * delay}s. Mira 'docker logs {self.container}'."
            )

    def restart(self) -> None:
        """Reinicia Jellyfin y espera a que vuelva.

        Los plugins recien instalados quedan en estado 'Restart' y no cargan
        hasta que pasa esto.

        Reinicia el PROCESO, no el contenedor: en la imagen de LinuxServer lo
        levanta s6 de nuevo en el lugar, asi que el contenedor sigue arriba y
        no hace falta meterse con docker.
        """
        ui.info("Reiniciando Jellyfin para que carguen los plugins...")
        resp = self.call("POST", "/System/Restart")
        if not resp.ok:
            ui.warn(f"Fallo el reinicio (HTTP {resp.status}). Reinicialo a mano:")
            ui.warn(f"  docker restart {self.container}")
            return

        # El servidor tarda un instante en soltar el puerto: sin esta pausa, el
        # primer chequeo lo encuentra todavia vivo y da por hecho que ya volvio.
        time.sleep(5)
        self.wait_ready()

    # -- Moonbase (el plugin de Moonfin) ----------------------------------
    def _plugin_id(self, name: str) -> str:
        """Id del plugin instalado, o '' si no esta. Se pregunta en vez de
        hardcodear el GUID: si el plugin no esta, no hay nada que configurar."""
        resp = self.call("GET", "/Plugins")
        if not resp.ok:
            ui.die(f"No pude listar los plugins (HTTP {resp.status}).")
        for item in resp.json() or []:
            if item.get("Name") == name:
                return item.get("Id", "")
        return ""

    def configure_moonbase_seerr(self, seerr) -> None:
        """Prende el proxy de Seerr de Moonbase. Idempotente.

        ES LO QUE PERMITE PEDIR CONTENIDO SIN EXPONER SEERR: Moonbase proxea
        Seerr por adentro de Jellyfin (con single sign-on), y a Jellyfin ya se
        entra desde internet via nginx. Sin esto habria que abrirle un puerto
        propio a Seerr.

        Las dos URLs son INTERNAS de la red 'media' porque las dos son
        conversaciones entre contenedores: Jellyfin le pega a Seerr, y Seerr le
        pega de vuelta al webhook de Jellyfin. Ninguna la abre un navegador.
        """
        # Sacarlo del conf es una decision, no un error: si no lo pediste, no
        # hay nada que avisar.
        if not any(p["name"] == MOONBASE_PLUGIN for p in self.plugins):
            return

        plugin_id = self._plugin_id(MOONBASE_PLUGIN)
        if not plugin_id:
            ui.warn(f"'{MOONBASE_PLUGIN}' esta en el conf pero no aparece "
                    "instalado: no hay integracion de Seerr que prender.")
            return

        path = f"/Plugins/{plugin_id}/Configuration"
        resp = self.call("GET", path)
        if not resp.ok:
            ui.die(f"No pude leer la config de {MOONBASE_PLUGIN} "
                   f"(HTTP {resp.status}).")
        current = resp.json() or {}

        wanted = {
            "SeerrEnabled": True,
            "SeerrUrl": seerr.internal_url,
            # Solo se usa para armar la URL del webhook que Seerr llama de
            # vuelta. Si se deja vacio, Moonbase la adivina: prueba la URL
            # publicada de Jellyfin, despues una IP de LAN y al final
            # loopback, que desde el contenedor de Seerr no resuelve a nada.
            "PublicServerUrl": self.internal_url,
        }

        if all(current.get(key) == value for key, value in wanted.items()):
            ui.info(f"La integracion de Seerr en {MOONBASE_PLUGIN} ya esta "
                    "como queremos. No se toca.")
            return

        # Se manda la config ENTERA y no solo las claves nuestras: el endpoint
        # deserializa el body en el objeto de configuracion, asi que todo lo
        # que no venga vuelve a su default y se perderia el resto de los
        # ajustes del plugin (incluido el secreto del webhook, que Moonbase
        # genera solo la primera vez).
        current.update(wanted)
        saved = self.call("POST", path, current)
        if not saved.ok:
            ui.warn(f"Fallo al guardar la config de {MOONBASE_PLUGIN} "
                    f"(HTTP {saved.status}):")
            print(saved.errors())
            ui.die(f"No pude prender la integracion de Seerr en {MOONBASE_PLUGIN}.")

        ui.info(f"Integracion de Seerr prendida en {MOONBASE_PLUGIN}.")
        ui.detail(f"Seerr    : {seerr.internal_url}")
        ui.detail(f"Webhook  : {self.internal_url}")
        ui.warn("El webhook de Seerr lo registra Moonbase recien cuando entras "
                "a Seerr desde Moonfin: necesita una sesion de admin.")

    def report_plugins(self) -> None:
        """Muestra en que estado quedo cada plugin.

        VALE LA PENA MIRARLO: Jellyfin instala un plugin aunque su targetAbi
        sea de una version anterior a la del servidor, y el problema recien
        aparece al cargarlo. 'Active' es el unico estado que significa que
        anduvo; 'Malfunctioned' o 'NotSupported' es que quedo instalado y
        muerto.
        """
        resp = self.call("GET", "/Plugins")
        if not resp.ok:
            ui.warn(f"No pude listar los plugins (HTTP {resp.status}).")
            return

        wanted = {p["name"] for p in self.plugins}
        for item in resp.json() or []:
            if item.get("Name") not in wanted:
                continue
            status = item.get("Status", "?")
            line = f"{item.get('Name')} {item.get('Version', '')} -> {status}"
            if status == "Active":
                ui.detail(f"  {line}")
            else:
                ui.warn(f"  {line}  (se esperaba 'Active')")
