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

# Listar paquetes en el repositorio para depuración
echo "Estado actual del repositorio $REPO_NAME:"
aptly -config=aptly.conf repo show -with-packages "$REPO_NAME"

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
    echo "Generando index.html dinámico..."
    
    # Intentar obtener la lista de paquetes de aptly de forma más robusta
    # Buscamos en el repo local
    if aptly -config=aptly.conf repo show -with-packages "$REPO_NAME" > packages_info.txt; then
        PACKAGES_HTML=""
        # El formato suele ser: "  [nombre_versión_arquitectura]"
        # Usamos sed para limpiar y extraer solo el nombre
        grep "  \[" packages_info.txt | sed 's/  \[//; s/_.*//' | sort -u | while read -r pkg; do
            echo "Paquete detectado: $pkg"
            PACKAGES_HTML+='<li class="package-item"><span class="package-name">'$pkg'</span></li>'
        done > packages_html_temp.txt
        PACKAGES_HTML=$(cat packages_html_temp.txt)
        rm packages_info.txt packages_html_temp.txt
    fi

    # Si la lista está vacía, ponemos los por defecto
    if [ -z "$PACKAGES_HTML" ]; then
        echo "Aviso: No se detectaron paquetes automáticamente, usando lista por defecto."
        PACKAGES_HTML='<li class="package-item"><span class="package-name">appinstall</span><span class="package-desc">Gestor de aplicaciones</span></li>'
        PACKAGES_HTML+='<li class="package-item"><span class="package-name">seafari</span><span class="package-desc">Navegador optimizado</span></li>'
    fi

    # Usar una variable temporal para el sed para evitar problemas con caracteres especiales
    sed "s|<!-- PACKAGES_LIST_PLACEHOLDER -->|$PACKAGES_HTML|g" index.html.template > public/index.html
fi

# Asegurar carpeta de skills y copiar contenido si existe en la raíz
mkdir -p public/skills
if [ -d "skills" ]; then
    cp -r skills/* public/skills/
fi

# Generar listado de directorios para que sea navegable como un repo Debian
echo "Generando índices de directorios..."
python3 generate-indexes.py public

# Actualizar repositorio RPM si existe el script
if [ -f "./update-rpm-repo.sh" ]; then
    bash ./update-rpm-repo.sh
fi

# Crear archivo _headers para Cloudflare Pages
echo "Creando archivo _headers para Cloudflare Pages..."
cat <<EOF > public/_headers
/*
  Access-Control-Allow-Origin: *
  Cache-Control: public, max-age=0, must-revalidate
/dists/*
  Content-Type: text/plain; charset=utf-8
/pool/*
  Content-Type: application/vnd.debian.binary-package
/skills/*.md
  Content-Type: text/markdown; charset=utf-8
EOF

echo "Repositorio actualizado con éxito en la carpeta 'public/'"
