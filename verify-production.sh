#!/usr/bin/env bash
# ==============================================================================
# Verifica que el despliegue a Cloudflare Pages ha llegado a PRODUCCIÓN.
#
# Por qué existe: `wrangler pages deploy --branch <rama>` crea un deployment
# *preview* salvo que <rama> sea la rama de producción del proyecto. Cuando el
# despliegue se queda en preview, https://apt.inled.es sigue sirviendo el
# deployment antiguo: el pool de paquetes sí está fresco (los .deb se sirven con
# un 302 al release de GitHub) pero el índice (Packages/Packages.gz) queda
# congelado, de modo que apt/pacman resuelven siempre la versión antigua.
# Entre 2026-09-13 y 2026-09-27 pasó esto y las ISO construidas en CI
# instalaban un pulsaros-recovery con la entrada rEFInd del recovery rota.
#
# Uso:
#   ./verify-production.sh                 # comprueba current_assets.txt
#   ./verify-production.sh f1.deb f2.deb   # comprueba esos paquetes
#
# Variables de entorno:
#   PROD_URL    (por defecto https://inled-apt.pages.dev)
#   RETRIES     (por defecto 3)  rondas de comprobación
#   SLEEP_SECS  (por defecto 5)  pausa entre rondas
#   MAX_SECONDS (por defecto 120) tope de tiempo total de la comprobación
# ==============================================================================
set -uo pipefail

PROD_URL="${PROD_URL:-https://inled-apt.pages.dev}"
DISTS=(unstable stable forky rolling)
RETRIES="${RETRIES:-3}"
SLEEP_SECS="${SLEEP_SECS:-5}"
MAX_SECONDS="${MAX_SECONDS:-120}"
START_TS=$(date +%s)
TMPDIR_V=$(mktemp -d)
trap 'rm -rf "$TMPDIR_V"' EXIT

# --- Paquetes a comprobar ---------------------------------------------------
FILES=("$@")
if [ "${#FILES[@]}" -eq 0 ] && [ -f current_assets.txt ]; then
    while IFS= read -r line; do
        case "$line" in
            *.deb) FILES+=("$line") ;;
        esac
    done < current_assets.txt
fi

NAMES=()
VERS=()
BASEFILES=()
for f in "${FILES[@]}"; do
    base=$(basename "$f")
    [[ "$base" == *.deb ]] || continue
    name=${base%%_*}
    ver=$(echo "$base" | cut -d_ -f2)
    [ -n "$ver" ] || continue
    NAMES+=("$name")
    VERS+=("$ver")
    BASEFILES+=("$base")
done

if [ "${#NAMES[@]}" -eq 0 ]; then
    # Sin paquetes que comprobar: basta con que el índice de producción exista.
    if curl -fsSL --max-time 60 \
        "$PROD_URL/dists/unstable/main/binary-amd64/Packages.gz" 2>/dev/null | gzip -dc >/dev/null 2>&1; then
        echo "✅ El índice de producción ($PROD_URL) responde"
        exit 0
    fi
    echo "❌ El índice de producción ($PROD_URL) no responde"
    exit 1
fi

# --- Descarga los índices UNA vez por ronda ---------------------------------
fetch_indexes() {
    local dist path out
    rm -f "$TMPDIR_V"/idx.*
    for dist in "${DISTS[@]}"; do
        out="$TMPDIR_V/idx.$dist"
        for path in "dists/$dist/main/binary-amd64/Packages.gz" \
                    "dists/$dist/main/binary-amd64/Packages"; do
            if curl -fsSL --max-time 60 "$PROD_URL/$path" -o "$TMPDIR_V/raw" 2>/dev/null; then
                if [[ "$path" == *.gz ]]; then
                    gzip -dc "$TMPDIR_V/raw" > "$out" 2>/dev/null || : > "$out"
                else
                    cp "$TMPDIR_V/raw" "$out"
                fi
                [ -s "$out" ] && break
            fi
        done
    done
    rm -f "$TMPDIR_V/raw"
}

# nombre + versión presentes en el mismo registro de algún índice
in_indexes() {  # $1 = nombre  $2 = versión
    local name="$1" ver="$2" f
    for f in "$TMPDIR_V"/idx.*; do
        [ -s "$f" ] || continue
        if grep -A8 -x "Package: $name" "$f" | grep -qx "Version: $ver"; then
            return 0
        fi
    done
    return 1
}

declare -a PENDING=()
for i in "${!NAMES[@]}"; do PENDING+=("$i"); done

found=0
total=${#NAMES[@]}

for (( round = 1; round <= RETRIES; round++ )); do
    fetch_indexes
    still=()
    for i in "${PENDING[@]}"; do
        if in_indexes "${NAMES[$i]}" "${VERS[$i]}"; then
            echo "  ✅ ${NAMES[$i]} ${VERS[$i]}"
            found=$(( found + 1 ))
        else
            still+=("$i")
        fi
    done
    PENDING=("${still[@]+"${still[@]}"}")
    [ "${#PENDING[@]}" -eq 0 ] && break
    # Tope de tiempo: la verificación nunca debe alargar el workflow.
    if [ "$round" -lt "$RETRIES" ] && [ $(( $(date +%s) - START_TS )) -lt "$MAX_SECONDS" ]; then
        echo "  ⏳ ${#PENDING[@]} sin verificar todavía (ronda $round/$RETRIES), reintento en ${SLEEP_SECS}s"
        sleep "$SLEEP_SECS"
    else
        break
    fi
done

echo
echo "📊 $found/$total paquetes visibles en el índice de producción"

# El dominio con reglas de caché propias puede tardar en refrescar: informativo.
# Se buscan las distribuciones una a una porque un paquete puede vivir solo en
# una de ellas (p. ej. las variantes +deb14 / +rolling).
sample=${BASEFILES[0]}
sample_name=${sample%%_*}
sample_ver=$(echo "$sample" | cut -d_ -f2)
served=0
for dist in "${DISTS[@]}"; do
    if curl -fsSL --max-time 30 "https://apt.inled.es/dists/$dist/main/binary-amd64/Packages.gz" 2>/dev/null \
        | gzip -dc 2>/dev/null \
        | grep -A8 -x "Package: $sample_name" | grep -qx "Version: $sample_ver"; then
        echo "ℹ️  apt.inled.es sirve $sample_name $sample_ver (dists/$dist)"
        served=1
        break
    fi
done
[ "$served" -eq 1 ] || echo "ℹ️  apt.inled.es aún no sirve $sample (puede tardar por su propia caché)"

if [ "${#PENDING[@]}" -eq 0 ]; then
    echo "✅ El despliegue llegó a producción"
    exit 0
fi

missing=()
for i in "${PENDING[@]}"; do missing+=("${BASEFILES[$i]}"); done

if [ "$found" -eq 0 ]; then
    echo "::error::El despliegue NO ha llegado a producción. El índice sigue announcing la versión antigua: ${missing[*]}"
    echo "::error::Normalmente significa que 'wrangler pages deploy' se ejecutó con un --branch que no es la rama de producción."
    exit 1
fi

echo "::warning::No verificados en producción (puede que el nombre de fichero y la versión difieran): ${missing[*]}"
echo "✅ El despliegue llegó a producción"
