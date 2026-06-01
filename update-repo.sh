#!/bin/bash
set -e

# Configuración
REPO_NAME="inled-repo"
DISTRIBUTION="stable"
COMPONENT="main"
GPG_KEY_ID="repo@inled.es"

# Asegurar directorios
mkdir -p .aptly public

# Inicializar repositorio si no existe
if ! aptly -config=aptly.conf repo show "$REPO_NAME" > /dev/null 2>&1; then
    echo "Creando repositorio $REPO_NAME..."
    aptly -config=aptly.conf repo create -comment="Inled APT Repository" -distribution="$DISTRIBUTION" -component="$COMPONENT" "$REPO_NAME"
fi

# Añadir paquetes desde la carpeta 'incoming'
if [ -d "incoming" ] && [ "$(ls -A incoming/*.deb 2>/dev/null)" ]; then
    echo "Añadiendo nuevos paquetes..."
    aptly -config=aptly.conf repo add "$REPO_NAME" incoming/
    rm -rf incoming/*.deb
fi

# Publicar el repositorio (o actualizar la publicación)
if ! aptly -config=aptly.conf publish list | grep -q "$DISTRIBUTION"; then
    echo "Publicando por primera vez..."
    aptly publish repo -config=aptly.conf -distribution="$DISTRIBUTION" "$REPO_NAME" filesystem:public:
else
    echo "Actualizando publicación..."
    aptly publish update -config=aptly.conf "$DISTRIBUTION" filesystem:public:
fi

# Si se proporciona una URL de Release, parchear los archivos Packages
if [ -n "$RELEASE_URL" ]; then
    echo "Parcheando archivos Packages para apuntar a $RELEASE_URL..."
    python3 patch-packages.py public "$RELEASE_URL"
    
    # Regenerar firmas de Release (InRelease y Release.gpg)
    # Buscamos todos los archivos Release en public/dists
    find public/dists -name "Release" | while read release_file; do
        dir=$(dirname "$release_file")
        echo "Re-firmando $release_file..."
        # Eliminar firmas antiguas
        rm -f "$dir/InRelease" "$dir/Release.gpg"
        # Crear Release.gpg (firma separada)
        gpg --batch --yes --armor --detach-sign --default-key "$GPG_KEY_ID" -o "$dir/Release.gpg" "$release_file"
        # Crear InRelease (firma embebida)
        gpg --batch --yes --armor --clearsign --default-key "$GPG_KEY_ID" -o "$dir/InRelease" "$release_file"
    done

    # Eliminar la carpeta pool de public para no subir los .deb a Pages
    echo "Eliminando archivos .deb de la carpeta public (se servirán desde GitHub Releases)..."
    rm -rf public/pool
fi

# Exportar la llave pública
gpg --armor --export "$GPG_KEY_ID" > public/archive.key

# Copiar el index.html si existe la plantilla
if [ -f "index.html.template" ]; then
    cp index.html.template public/index.html
fi

# Generar listado de directorios para que sea navegable como un repo Debian
echo "Generando índices de directorios..."
python3 generate-indexes.py public

echo "Repositorio actualizado con éxito en la carpeta 'public/'"
