# 📦 Repositorio Central Inled (apt.inled.es)

Repositorio oficial multi-distribución (APT / Pacman / DNF) para las aplicaciones de Inled y el ecosistema **Pulsar OS**.

---

## 🌿 Canales de Distribución: `stable` y `unstable`

El repositorio está estructurado en dos canales principales:

| Canal | Descripción | APT (Debian/Ubuntu) | Pacman (Arch Linux) | DNF (Fedora/RHEL) |
|---|---|---|---|---|
| **`stable`** | Versiones probadas y listas para producción | `deb https://apt.inled.es stable main` | `Server = https://apt.inled.es/arch/stable/$arch` | `baseurl=https://apt.inled.es/rpm/` |
| **`unstable`** | Versiones en desarrollo continuo y pruebas | `deb https://apt.inled.es unstable main` | `Server = https://apt.inled.es/arch/unstable/$arch` | `baseurl=https://apt.inled.es/rpm/unstable/` |

---

## 🚀 Flujo de Trabajo (Workflow)

```mermaid
flowchart LR
    A[Desarrollo en PKG] -->|Deploy a 'unstable'| B[apt.inled.es/unstable]
    B -->|Compilar ISO de prueba con --branch unstable| C[ISO Unstable]
    C -->|Pruebas satisfactorias| D[Promocionar a 'stable']
    D -->|Deploy a 'stable'| E[apt.inled.es/stable]
    E -->|Compilar ISO final con --branch stable| F[ISO Stable Oficial]
```

1. **Despliegue a Unstable:**
   - Al compilar y desplegar un paquete desde el repositorio `PKG`, se selecciona la rama `unstable`.
   - Se publica automáticamente en `apt.inled.es` bajo la rama `unstable`.

2. **Pruebas con ISO Unstable:**
   - En el repositorio `ISO`, se puede compilar una ISO seleccionando la rama `unstable`.
   - El archivo generado llevará `unstable` en su nombre (ej: `pulsaros-unstable-debian-refind-0.3.iso`).
   - La ISO vendrá configurada para consumir los paquetes desde el canal `unstable`.

3. **Promoción a Stable:**
   - Una vez comprobado que los paquetes funcionan correctamente, se promocionan a `stable`:
     - Desde GitHub Actions en `PKG`: ejecutando el workflow **🌟 Promote Package to Stable**.
     - Desde CLI en `PKG`: `./promote-package.sh <nombre_paquete>`.
     - Desde GitHub Actions en `apt.inled.es`: ejecutando el workflow **Promote Package (Unstable -> Stable)**.
   - Los paquetes se publican en el canal `stable`.

4. **Compilación de ISO Stable:**
   - En el repositorio `ISO`, se ejecuta el build con `--branch stable` para generar las imágenes oficiales finales (ej: `pulsaros-stable-debian-refind-0.3.iso`).

---

## 🛠️ Scripts y Herramientas

- `./update-repo.sh`: Sincroniza y publica todos los repositorios APT (stable, unstable), Arch (stable, unstable) y RPM.
- `./update-pacman-repo.sh`: Gestiona las bases de datos de Pacman firmadas con GPG para x86_64 y aarch64.
- `./update-rpm-repo.sh`: Genera y firma los metadatos de DNF/YUM.
- `./promote-package.py <nombre>`: Promociona paquetes existentes de `unstable` a `stable`.
- `./generate-web-index.py`: Genera el catálogo web y `packages.json` con pestañas y filtros por rama.
