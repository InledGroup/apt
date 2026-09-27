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
# instalaron un pulsaros-recovery con la entrada rEFInd del recovery rota.
#
# Uso:
#   ./verify-production.sh                 # comprueba current_assets.txt
#   ./verify-production.sh f1.deb f2.deb   # comprueba esos paquetes
#
# Variables de entorno:
#   PROD_URL    (por defecto https://inled-apt.pages.dev)
#   RETRIES     (por defecto 6)  intentos de comprobación
#   SLEEP_SECS  (por defecto 10) pausa entre intentos
# ==============================================================================
set -uo pipefail

PROD_URL="${PROD_URL:-https://inled-apt.pages.dev}"
DISTS=(unstable stable forky rolling)
RETRIES="${RETRIES:-6}"
SLEEP_SECS="${SLEEP_SECS:-10}"

FILES=("$@")
if [ "${#FILES[@]}" -eq 0 ] && [ -f current_assets.txt ]; then
    while IFS= read -r line; do
        case "$line" in
            *.deb) FILES+=("$line") ;;
        esac
    done < current_assets.txt
fi

index_for() {  # $1 = distribución -> imprime el índice por stdout
    local dist="$1" path body
    for path in "dists/$dist/main/binary-amd64/Packages.gz" \
                "dists/$dist/main/binary-amd64/Packages"; do
        body=$(curl -fsSL --max-time 60 "$PROD_URL/$path" 2>/dev/null || true)
        [ -n "$body" ] || continue
        if [[ "$path" == *.gz ]]; then
            printf '%s' "$body" | gzip -dc 2>/dev/null || true
        else
            printf '%s' "$body"
        fi
        return 0
    done
    return 1
}

# ¿Está este nombre_versión en el índice de producción de alguna distribución?
in_production() {  # $1 = nombre  $2 = versión
    local name="$1" ver="$2" attempt dist idx
    for (( attempt = 1; attempt <= RETRIES; attempt++ )); do
        for dist in "${DISTS[@]}"; do
            idx=$(index_for "$dist") || continue
            if printf '%s\n' "$idx" | grep -A8 -x "Package: $name" | grep -qx "Version: $ver"; then
                return 0
            fi
        done
        if [ "$attempt" -lt "$RETRIES" ]; then
            echo "     ⏳ aún no visible en producción (intento $attempt/$RETRIES), reintento en ${SLEEP_SECS}s"
            sleep "$SLEEP_SECS"
        fi
    done
    return 1
}

# --- Sin nada que comprobar: solo que el índice responda --------------------
if [ "${#FILES[@]}" -eq 0 ]; then
    if index_for unstable >/dev/null; then
        echo "✅ El índice de producción ($PROD_URL) responde"
        exit 0
    fi
    echo "❌ El índice de producción ($PROD_URL) no responde"
    exit 1
fi

total=0
found=0
missing=()

for f in "${FILES[@]}"; do
    base=$(basename "$f")
    [[ "$base" == *.deb ]] || continue
    name=${base%%_*}
    ver=$(echo "$base" | cut -d_ -f2)
    [ -n "$ver" ] || continue
    total=$(( total + 1 ))
    if in_production "$name" "$ver"; then
        echo "  ✅ $name $ver"
        found=$(( found + 1 ))
    else
        echo "  ❌ $name $ver no está en el índice de producción"
        missing+=("$base")
    fi
done

echo
echo "📊 $found/$total paquetes nuevos visibles en producción"

# El dominio con cache-control propio puede tardar en refrescar: informativo.
if [ "$total" -gt 0 ]; then
    last=${FILES[${#FILES[@]}-1]}
    lname=$(basename "$last")
    [[ "$lname" == *.deb ]] && curl -fsSL --max-time 30 \
        "https://apt.inled.es/dists/unstable/main/binary-amd64/Packages.gz" 2>/dev/null \
        | gzip -dc 2>/dev/null \
        | grep -A8 -x "Package: ${lname%%_*}" | grep -x "Version: $(echo "$lname" | cut -d_ -f2)" \
        | sed 's/^/ℹ️  apt.inled.es (puede tardar por caché): /' || true
fi

if [ "$total" -gt 0 ] && [ "$found" -eq 0 ]; then
    echo "::error::El despliegue NO ha llegado a producción. apt.inled.es sigue sirviendo el índice antiguo (${missing[*]})."
    echo "::error::Suele significar que 'wrangler pages deploy' se ejecutó con un --branch que no es la rama de producción."
    exit 1
fi

if [ "${#missing[@]}" -gt 0 ]; then
    echo "::warning::Estos paquetes no se han visto en producción (puede ser que el nombre de fichero y la versión difieran): ${missing[*]}"
fi

echo "✅ El despliegue llegó a producción"
