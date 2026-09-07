"""Puente hacia los scripts bash de scripts/sys/.

DIVISION DE RESPONSABILIDADES:
  bash   -> todo lo que toca el sistema: docker compose, mkdir/chown/chmod,
            docker exec, y la cirugia sobre archivos de config (.conf, .xml).
            Son herramientas que ya viven en el host y bash las invoca mejor.
  python -> orquestacion, HTTP, JSON, y decidir QUE hay que hacer.

Cada script de scripts/sys/ recibe todo por argumentos: no comparte globales
con nadie, se puede correr a mano para debuggear, y su contrato es explicito.
"""

import shutil
import subprocess
import sys
from pathlib import Path

from . import ui


def run_script(script: Path, *args: str, capture: bool = False) -> str:
    """Corre un script de scripts/sys/ y aborta si falla.

    Con capture=False la salida del script se copia a la consola Y al log a
    medida que sale, asi los info() de bash se mezclan naturalmente con los de
    Python sin que el log se pierda el detalle. Importa cuando algo falla
    lejos de la terminal: el rc suelto no alcanza para saber que paso.

    El precio es que los scripts dejan de ver un TTY, asi que docker compose
    imprime en modo plano (una linea por evento) en vez de las barras de
    progreso que se redibujan. Para el log es una mejora: las barras dejaban
    basura y ningun dato.
    """
    if not script.is_file():
        ui.die(f"Falta el script {script}")

    cmd = ["bash", str(script), *[str(a) for a in args]]
    ui.logfile(f"--- EXEC: {' '.join(cmd)}")

    if capture:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        ui.logfile(f"    RC: {proc.returncode}")
        ui.logfile(f"    STDOUT: {proc.stdout.strip()}")
        if proc.stderr.strip():
            ui.logfile(f"    STDERR: {proc.stderr.strip()}")
        if proc.returncode != 0:
            if proc.stderr.strip():
                print(proc.stderr.rstrip())
            ui.die(f"Fallo {script.name} (rc={proc.returncode})")
        return proc.stdout.strip()

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,   # un solo flujo: preserva el orden real
        text=True,
        bufsize=1,                  # linea a linea, para que no se vea trabado
        errors="replace",           # las barras de progreso traen bytes raros
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        ui.logfile(f"    | {line.rstrip()}")
    rc = proc.wait()

    ui.logfile(f"    RC: {rc}")
    if rc != 0:
        ui.die(f"Fallo {script.name} (rc={rc})")
    return ""


def run(*cmd: str, check: bool = True) -> str:
    """Comando suelto, con la salida capturada."""
    ui.logfile(f"--- EXEC: {' '.join(cmd)}")
    proc = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    ui.logfile(f"    RC: {proc.returncode}")
    if proc.returncode != 0 and check:
        ui.die(f"Fallo: {' '.join(cmd)}\n{proc.stderr.strip()}")
    return proc.stdout.strip()


def have(program: str) -> bool:
    return shutil.which(program) is not None
