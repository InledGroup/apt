#!/bin/bash
set -e

# Configuración
GPG_KEY_ID="repo@inled.es"
RPM_DIR="public/rpm"

echo "=== Configurando repositorio RPM (DNF/YUM) ==="

# Asegurar directorios
mkdir -p "$RPM_DIR"

# Añadir paquetes RPM desde la carpeta 'incoming'
if [ -d "incoming" ] && [ "$(ls -A incoming/*.rpm 2>/dev/null)" ]; then
    echo "Añadiendo nuevos paquetes RPM..."
    cp incoming/*.rpm "$RPM_DIR/"
    rm -rf incoming/*.rpm
fi

# Verificar si hay paquetes para procesar
if [ ! "$(ls -A "$RPM_DIR"/*.rpm 2>/dev/null)" ]; then
    echo "No hay paquetes RPM en $RPM_DIR. Saltando generación de metadatos."
    exit 0
fi

# Generar metadatos del repositorio
echo "Generando metadatos con createrepo_c..."
createrepo_c --update "$RPM_DIR"

# Firmar los metadatos (repomd.xml)
echo "Firmando repomd.xml..."
REPOMD_FILE="$RPM_DIR/repodata/repomd.xml"
if [ -f "$REPOMD_FILE" ]; then
    rm -f "$REPOMD_FILE.asc"
    gpg --batch --yes --armor --detach-sign --default-key "$GPG_KEY_ID" "$REPOMD_FILE"
    echo "Metadatos firmados correctamente."
else
    echo "ERROR: No se encontró $REPOMD_FILE"
    exit 1
fi

echo "Repositorio RPM actualizado con éxito en '$RPM_DIR/'"
