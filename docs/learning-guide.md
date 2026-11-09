# Guía para Kevin

Este proyecto muestra cómo entregar una API pequeña con controles de seguridad que puedes explicar y verificar. El objetivo es entender cada decisión antes de agregar más herramientas.

## Qué hace cada archivo

| Archivo | Qué debes poder explicar |
| --- | --- |
| `app/main.py` | Define los endpoints de FastAPI. `/health` comprueba que responde; `/ready` indica que puede atender tráfico. Actualmente no depende de una base de datos. |
| `tests/test_api.py` | Comprueba el contrato de la API: respuestas, códigos HTTP y documentación. |
| `security/repo_guard.py` | Busca patrones de posibles credenciales y debug activado. Informa la ubicación sin imprimir el valor encontrado. |
| `tests/test_repo_guard.py` | Comprueba hallazgos, exclusiones, errores y los códigos de salida del scanner. |
| `requirements.txt` / `requirements-dev.txt` | Separan las dependencias de ejecución de las herramientas de desarrollo y validación. |
| `Dockerfile` | Construye la imagen y ejecuta la API como un usuario sin privilegios: UID 10001. |
| `compose.yaml` | Ejecuta esa imagen con filesystem de solo lectura y restricciones adicionales; publica el puerto 8001 únicamente en tu equipo. |
| `.github/workflows/ci.yml` | Ejecuta las verificaciones en GitHub para que otra persona pueda revisar los resultados. |
| `deploy/kubernetes/` | Describe el despliegue como código: pods, Service, probes, límites y NetworkPolicy. Todavía requiere validar un rollout real. |
| `Makefile` | Agrupa comandos repetibles para trabajar de la misma manera localmente y en CI. |

## Primera comprobación

En la carpeta del repositorio, con Python 3.13 instalado:

```bash
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
make check
```

`make check` ejecuta los tests, RepoGuard, Bandit y pip-audit. Un fallo detiene la verificación para que revises la causa. Los tests evalúan comportamiento; Bandit busca problemas de código; pip-audit consulta vulnerabilidades conocidas de dependencias. RepoGuard tiene una tarea más limitada: reconocer algunos patrones en archivos de texto.

Para ver una respuesta real:

```bash
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

En otra terminal:

```bash
curl --fail http://127.0.0.1:8000/health
curl --fail http://127.0.0.1:8000/ready
```

Abre `http://127.0.0.1:8000/docs` para probar los endpoints. Detén el servidor con Ctrl+C. Si el puerto ya está ocupado, comprueba primero si tu API anterior sigue funcionando.

## Demostrar que RepoGuard también falla correctamente

Un scanner que siempre muestra éxito no sirve como control. Este ejemplo crea un archivo temporal con una bandera de debug activada, lo analiza y lo borra. Se construye el texto por partes para que la guía misma no genere un hallazgo.

```bash
demo_dir="$(mktemp -d)"
printf '%s%s=%s%s\n' 'DE' 'BUG' 'Tr' 'ue' > "$demo_dir/.env"
python security/repo_guard.py "$demo_dir"
demo_status=$?
rm "$demo_dir/.env"
rmdir "$demo_dir"
test "$demo_status" -eq 1
```

Debes ver un hallazgo con archivo, línea y tipo de problema. El scanner devuelve `1` al encontrar problemas; la última comprobación devuelve éxito si ese fallo esperado ocurrió. No uses credenciales reales para esta prueba.

| Código de salida | Significado |
| --- | --- |
| `0` | No encontró patrones dentro de los archivos que revisó |
| `1` | Encontró uno o más problemas |
| `2` | No pudo revisar correctamente la ruta o un archivo seleccionado |

RepoGuard omite entornos virtuales, cachés, `.git`, `node_modules` y enlaces simbólicos. Revisa el árbol de archivos actual; no revisa el historial de Git ni demuestra que un repositorio esté libre de secretos. Si una credencial real se publica, hay que revocarla o rotarla aunque luego se borre del código.

## Revisar el contenedor

Abre Docker Desktop y comprueba que el motor responda:

```bash
docker info
docker compose up --build -d
docker compose exec -T api id
curl --fail http://127.0.0.1:8001/health
docker compose ps
docker compose down
```

El comando `id` debe mostrar UID 10001. Docker utiliza el puerto 8001 en tu Mac y 8000 dentro del contenedor. El filesystem de solo lectura y las capabilities eliminadas reducen lo que un proceso comprometido puede hacer; no sustituyen las actualizaciones ni una buena configuración del host.

## Fase 2: empaquetar con Zarf

```bash
make zarf-validate   # construye el paquete, lo despliega en un cluster nuevo y lo prueba
make zarf-down       # borra el cluster zarf-lab
```

Qué pasa por dentro:

1. `zarf package create` lee [`zarf.yaml`](../deploy/zarf/zarf.yaml) y mete en un solo archivo `.tar.zst` las imágenes, los manifests y un SBOM por imagen.
2. `zarf init` instala en el cluster un **registry interno** y un **agente** (un mutating webhook).
3. `zarf package deploy` sube las imágenes del paquete a ese registry. El agente reescribe cada pod para que use `127.0.0.1:31999/...` en vez de Docker Hub.
4. El script falla si alguna imagen no viene del registry de Zarf y después corre las mismas pruebas de k3d.

Qué debes saber de memoria:

- **Zarf** empaqueta software y todas sus dependencias para entregarlo en redes desconectadas (air-gapped), como las del DoD. Es un proyecto open source creado por Defense Unicorns.
- **Paquete Zarf**: un archivo versionado con imágenes, manifests/charts y SBOMs. Se crea con internet y se despliega sin internet.
- **Init package**: prepara el cluster una sola vez con el registry interno y el agente que reescribe las imágenes.
- **Componentes**: partes del paquete. `required: true` siempre se instala; los opcionales se eligen con `--components`. Por eso el cliente de pruebas es opcional.
- **SBOM** (Software Bill of Materials): la lista de todo el software dentro de una imagen. Sirve para responder rápido a un CVE nuevo.
- **Límite honesto**: el paquete no está firmado y no lo he probado en una red realmente desconectada. La firma es la Fase 4.

## Qué puedes decir en una entrevista

“Tomé una API FastAPI pequeña y añadí tests, restricciones de contenedor y verificaciones automáticas de seguridad. La validé en k3d: el script prueba el usuario no root, las capabilities, el filesystem de solo lectura y que la NetworkPolicy permite y bloquea el tráfico correcto. Después la empaqueté con Zarf y la desplegué en un cluster nuevo; el script falla si alguna imagen no viene del registry interno de Zarf. Mi siguiente paso es integrarla con UDS Core y firmar el paquete.”

CI significa **Continuous Integration**: comprobar cada cambio automáticamente. Este proyecto muestra esa parte y los fundamentos para **Continuous Delivery**; todavía no tiene despliegue automático. Kubernetes YAML es configuración declarativa de infraestructura, pero no significa que ya hayas provisionado AWS o trabajado con Terraform.

Sigue el [README principal](../README.md), la [guía Kubernetes](../deploy/kubernetes/README.md) y la [guía Zarf](../deploy/zarf/README.md) para avanzar. Cada milestone debe terminar con evidencia observable antes de describirlo como completado.
