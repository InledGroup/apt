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
    # Usamos -force-replace para permitir re-subir la misma versión si es necesario
    aptly -config=aptly.conf repo add -force-replace "$REPO_NAME" incoming/
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
    # Forzamos overwrite para asegurar que los metadatos se regeneran siempre
    aptly publish update -force-overwrite -config=aptly.conf "$DISTRIBUTION" filesystem:public:
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
    
    # Obtener lista de paquetes de forma fiable
    rm -f packages_html_temp.txt
    
    # Extraemos los paquetes directamente de la descripción del repo
    # Formato esperado: [nombre_versión_arquitectura]
    aptly -config=aptly.conf repo show -with-packages "$REPO_NAME" | grep "  \[" | sed 's/  \[//; s/\]//' | sort -V | while read -r line; do
        if [ -z "$line" ]; then continue; fi
        
        PKG_NAME=$(echo "$line" | cut -d'_' -f1)
        PKG_VER=$(echo "$line" | cut -d'_' -f2)
        PKG_ARCH=$(echo "$line" | cut -d'_' -f3)
        
        echo "Procesando para web: $PKG_NAME ($PKG_VER)"
        
        DESC="Paquete para $PKG_NAME"
        if [ "$PKG_NAME" == "appinstall" ]; then DESC="Gestor de aplicaciones multiplataforma"; fi
        if [ "$PKG_NAME" == "seafari" ]; then DESC="Navegador web optimizado"; fi
        
        DEB_FILE="${PKG_NAME}_${PKG_VER}_${PKG_ARCH}.deb"
        DOWNLOAD_URL="${RELEASE_URL}/${DEB_FILE}"
        
        # Construir el HTML de la card
        ITEM_HTML="<li class=\"package-item\">"
        ITEM_HTML+="<div class=\"package-header\">"
        ITEM_HTML+="<span class=\"package-name\">$PKG_NAME</span>"
        ITEM_HTML+="<span class=\"package-version\">v$PKG_VER</span>"
        ITEM_HTML+="</div>"
        ITEM_HTML+="<p class=\"package-desc\">$DESC</p>"
        ITEM_HTML+="<div class=\"package-footer\">"
        ITEM_HTML+="<a href=\"$DOWNLOAD_URL\" class=\"btn btn-sm\">⬇️ Descargar .deb</a>"
        ITEM_HTML+="</div>"
        ITEM_HTML+="</li>"
        
        echo "$ITEM_HTML" >> packages_html_temp.txt
    done

    if [ -s "packages_html_temp.txt" ]; then
        # Usar un archivo temporal para la sustitución para evitar problemas con sed
        sed -e '/<!-- PACKAGES_LIST_PLACEHOLDER -->/r packages_html_temp.txt' -e '/<!-- PACKAGES_LIST_PLACEHOLDER -->/d' index.html.template > public/index.html
        rm packages_html_temp.txt
    else
        echo "Aviso: No se encontraron paquetes para listar en la web."
        EMPTY_MSG="<p style=\"grid-column: 1/-1; text-align: center; color: var(--text-muted);\">No hay paquetes disponibles en este momento.</p>"
        sed "s|<!-- PACKAGES_LIST_PLACEHOLDER -->|$EMPTY_MSG|g" index.html.template > public/index.html
    fi
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
