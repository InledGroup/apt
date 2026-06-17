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

# Añadir paquetes desde la carpeta 'incoming' (incluye recuperados de Releases)
if [ -d "incoming" ] && [ "$(ls -A incoming/*.deb 2>/dev/null)" ]; then
    echo "Sincronizando paquetes con el repositorio APT..."
    # Usamos -force-replace para asegurar que la base de datos local coincide con los archivos físicos
    aptly -config=aptly.conf repo add -force-replace "$REPO_NAME" incoming/
    rm -rf incoming/*.deb
fi

# Publicar el repositorio (o actualizar la publicación)
if ! aptly -config=aptly.conf publish list | grep -q "$DISTRIBUTION"; then
    echo "Publicando por primera vez..."
    aptly publish repo -config=aptly.conf -distribution="$DISTRIBUTION" "$REPO_NAME" filesystem:public:
else
    echo "Actualizando publicación..."
    aptly publish update -force-overwrite -config=aptly.conf "$DISTRIBUTION" filesystem:public:
fi

# Si se proporciona una URL de Release, parchear los archivos Packages
if [ -n "$RELEASE_URL" ]; then
    echo "Parcheando archivos Packages para apuntar a $RELEASE_URL..."
    python3 patch-packages.py public "$RELEASE_URL"
    
    # Regenerar firmas de Release
    find public/dists -name "Release" | while read release_file; do
        dir=$(dirname "$release_file")
        rm -f "$dir/InRelease" "$dir/Release.gpg"
        gpg --batch --yes --armor --detach-sign --default-key "$GPG_KEY_ID" -o "$dir/Release.gpg" "$release_file"
        gpg --batch --yes --armor --clearsign --default-key "$GPG_KEY_ID" -o "$dir/InRelease" "$release_file"
    done

    # Eliminar pool local (se sirven desde GitHub)
    rm -rf public/pool
fi

# Exportar la llave pública
gpg --armor --export "$GPG_KEY_ID" > public/archive.key

# Asegurar carpeta de skills
mkdir -p public/skills
if [ -d "skills" ]; then
    cp -r skills/* public/skills/
fi

# Actualizar repositorios RPM y Arch
if [ -f "./update-rpm-repo.sh" ]; then bash ./update-rpm-repo.sh; fi
if [ -f "./update-pacman-repo.sh" ]; then bash ./update-pacman-repo.sh; fi

# Generar listado de directorios (índices navegables)
echo "Generando índices de directorios..."
python3 generate-indexes.py public

# Generar index.html y packages.json dinámicos
if [ -f "index.html.template" ]; then
    echo "Generando web y metadatos..."
    python3 generate-web-index.py "$RELEASE_URL"
fi

# Crear archivo _headers para Cloudflare Pages
cat <<EOF > public/_headers
/*
  Access-Control-Allow-Origin: *
  Cache-Control: public, max-age=0, must-revalidate
/dists/*
  Content-Type: text/plain; charset=utf-8
/pool/*
  Content-Type: application/vnd.debian.binary-package
/rpm/*
  Content-Type: application/x-rpm
/arch/*
  Content-Type: application/octet-stream
/skills/*.md
  Content-Type: text/markdown; charset=utf-8
EOF

echo "Repositorio actualizado con éxito."
