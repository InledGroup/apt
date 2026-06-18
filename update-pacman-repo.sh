#!/bin/bash
set -e

# Configuración
GPG_KEY_ID="repo@inled.es"
ARCH_DIR="public/arch"
REPO_NAME="inled"

echo "=== Configurando repositorio Arch Linux (Pacman) ==="

# Asegurar directorios
mkdir -p "$ARCH_DIR"

# Añadir paquetes Arch desde la carpeta 'incoming'
# Arch packages: .pkg.tar.zst, .pkg.tar.xz, .pkg.tar.gz
if [ -d "incoming" ] && [ "$(ls -A incoming/*.pkg.tar.* 2>/dev/null)" ]; then
    echo "Añadiendo nuevos paquetes Arch..."
    cp incoming/*.pkg.tar.* "$ARCH_DIR/"
    rm -rf incoming/*.pkg.tar.*
fi

# Verificar si hay paquetes para procesar
if [ ! "$(ls -A "$ARCH_DIR"/*.pkg.tar.* 2>/dev/null)" ]; then
    echo "No hay paquetes Arch en $ARCH_DIR. Saltando generación de base de datos."
    exit 0
fi

# Generar/Actualizar la base de datos del repositorio
echo "Actualizando base de datos con repo-add..."
# repo-add [opciones] <ruta-a-la-db> <ruta-al-paquete>

# Archivos de base de datos
# Usamos .db.tar.gz porque repo-add lo requiere estrictamente.
# Luego convertiremos los enlaces simbólicos en archivos reales para Cloudflare Pages.
DB_FILE="$ARCH_DIR/$REPO_NAME.db.tar.gz"
FILES_FILE="$ARCH_DIR/$REPO_NAME.files.tar.gz"

# Recopilar todos los paquetes válidos para procesarlos de una vez
PKGS_TO_ADD=()

for pkg in "$ARCH_DIR"/*.pkg.tar.*; do
    # No procesar firmas como paquetes
    if [[ "$pkg" == *.sig ]]; then continue; fi
    
    echo "Procesando paquete: $pkg"
    
    # Firmar el paquete si no está firmado
    if [ ! -f "$pkg.sig" ]; then
        echo "Firmando paquete $pkg..."
        gpg --batch --yes --detach-sign --default-key "$GPG_KEY_ID" "$pkg"
    fi
    
    PKGS_TO_ADD+=("$pkg")
done

if [ ${#PKGS_TO_ADD[@]} -eq 0 ]; then
    echo "No hay nuevos paquetes válidos para añadir."
    exit 0
fi

# Añadir a la base de datos (procesar todos a la vez es más eficiente)
# -n (new) solo añade paquetes que no están, -f (force) sobreescribe
echo "Ejecutando repo-add para ${#PKGS_TO_ADD[@]} paquetes..."
repo-add --sign --key "$GPG_KEY_ID" "$DB_FILE" "${PKGS_TO_ADD[@]}"

# Solución para Cloudflare Pages: reemplazar enlaces simbólicos por archivos reales
# repo-add crea enlaces simbólicos (ej: inled.db -> inled.db.tar.gz)
# Cloudflare los sirve como texto, lo que rompe pacman.
echo "Corrigiendo enlaces simbólicos para Cloudflare Pages..."
for file in "$ARCH_DIR/$REPO_NAME.db" "$ARCH_DIR/$REPO_NAME.files" "$ARCH_DIR/$REPO_NAME.db.sig" "$ARCH_DIR/$REPO_NAME.files.sig"; do
    if [ -L "$file" ]; then
        target=$(readlink -f "$file")
        echo "Convirtiendo enlace simbólico en archivo real: $file -> $target"
        rm "$file"
        cp "$target" "$file"
    fi
done

echo "Repositorio Arch Linux actualizado con éxito en '$ARCH_DIR/'"
