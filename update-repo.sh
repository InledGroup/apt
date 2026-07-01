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
    # English: Add packages to the aptly repository database.
    # Español: Añadir paquetes a la base de datos del repositorio de aptly.
    aptly -config=aptly.conf repo add -force-replace "$REPO_NAME" incoming/
    
    # English: We do NOT remove the debs from incoming/ here because they need to be uploaded to GitHub Releases in a later step.
    # Español: NO eliminamos los debs de incoming/ aquí porque deben ser subidos a GitHub Releases en un paso posterior.
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
# English: Copy packages to incoming/ so they are uploaded to GitHub Releases, then create 302 redirects and remove physical files from public/ to stay under the 25 MiB Cloudflare Pages limit
# Español: Copiar paquetes a incoming/ para asegurar que se suben a GitHub Releases, luego crear redirecciones 302 y borrar archivos físicos de public/ para no superar el límite de 25 MiB de Cloudflare Pages

REDIRECTS_FILE="public/_redirects"
touch "$REDIRECTS_FILE"

# Process RPMs
# Procesar RPMs
if [ -d "public/rpm" ]; then
    mkdir -p incoming
    # Copy RPMs to incoming/ so GitHub Release upload step catches them
    # Copiar RPMs a incoming/ para que el paso de subida a GitHub Releases los capture
    cp public/rpm/*.rpm incoming/ 2>/dev/null || true
    
    for rpm_file in public/rpm/*.rpm; do
        if [ -f "$rpm_file" ]; then
            filename=$(basename "$rpm_file")
            echo "Creating 302 redirect for $filename..."
            if ! grep -q "/rpm/$filename" "$REDIRECTS_FILE"; then
                echo "/rpm/$filename $RELEASE_URL/$filename 302" >> "$REDIRECTS_FILE"
            fi
            rm "$rpm_file"
        fi
    done
fi

# Process Arch Linux packages (Pacman)
# Procesar paquetes de Arch Linux (Pacman)
if [ -d "public/arch" ]; then
    mkdir -p incoming
    # Copy pacman packages and their signatures to incoming/
    # Copiar paquetes de pacman y sus firmas a incoming/
    cp public/arch/*.pkg.tar.* incoming/ 2>/dev/null || true
    
    for pkg_file in public/arch/*.pkg.tar.*; do
        # Skip signature files in the main loop, as they are handled alongside their packages
        # Omitir los archivos de firma en el bucle principal, ya que se manejan junto con sus paquetes
        if [[ "$pkg_file" == *.sig ]]; then continue; fi
        
        if [ -f "$pkg_file" ]; then
            filename=$(basename "$pkg_file")
            echo "Creating 302 redirect for $filename..."
            
            # Redirect package
            if ! grep -q "/arch/$filename" "$REDIRECTS_FILE"; then
                echo "/arch/$filename $RELEASE_URL/$filename 302" >> "$REDIRECTS_FILE"
            fi
            rm "$pkg_file"
            
            # Redirect signature if exists
            if [ -f "$pkg_file.sig" ]; then
                sig_filename="$filename.sig"
                if ! grep -q "/arch/$sig_filename" "$REDIRECTS_FILE"; then
                    echo "/arch/$sig_filename $RELEASE_URL/$sig_filename 302" >> "$REDIRECTS_FILE"
                fi
                rm "$pkg_file.sig"
            fi
        fi
    done
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
