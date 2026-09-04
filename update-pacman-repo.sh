#!/bin/bash
set -e

ARCH_DIR="public/arch"
REPO_NAME="inled"
DB_FILE="$ARCH_DIR/$REPO_NAME.db.tar.gz"

# GPG fingerprint is passed from update-repo.sh; fall back to extracting it
if [ -z "$GPG_FINGERPRINT" ]; then
    GPG_FINGERPRINT=$(gpg --list-keys --with-colons "repo@inled.es" 2>/dev/null | grep '^fpr:' | head -1 | cut -d: -f10)
fi

if [ -z "$GPG_FINGERPRINT" ]; then
    echo "ERROR: No GPG fingerprint available. Set GPG_FINGERPRINT or ensure key exists."
    exit 1
fi

echo "=== Configuring Arch Linux repository (Pacman) ==="
echo "Using GPG fingerprint: $GPG_FINGERPRINT"

# Ensure directories
mkdir -p "$ARCH_DIR" incoming

# 1. Sign any new incoming Arch packages
shopt -s nullglob
incoming_pkgs=(incoming/*.pkg.tar.*)
shopt -u nullglob

for pkg in "${incoming_pkgs[@]}"; do
    if [[ "$pkg" == *.sig ]]; then continue; fi
    echo "Processing incoming Arch package: $pkg"
    echo "Signing package $pkg..."
    rm -f "$pkg.sig"
    gpg --batch --yes --detach-sign --default-key "$GPG_FINGERPRINT" "$pkg"
done

# 2. Synchronize inled.db with current_assets.txt
INDEXED_FILENAMES=()
if [ -f "$DB_FILE" ]; then
    while IFS= read -r fn; do
        [ -n "$fn" ] && INDEXED_FILENAMES+=("$fn")
    done < <(tar -ztf "$DB_FILE" 2>/dev/null | grep '/desc$' | while read -r desc_entry; do
        tar -zxOf "$DB_FILE" "$desc_entry" | grep -A 1 '^%FILENAME%' | tail -n 1
    done)
fi

# Purge stale packages from inled.db (indexed but not in current_assets.txt or incoming)
if [ -f "current_assets.txt" ] && [ -f "$DB_FILE" ]; then
    for fn in "${INDEXED_FILENAMES[@]}"; do
        if ! grep -Fxq "$fn" current_assets.txt && [ ! -f "incoming/$fn" ]; then
            core="${fn%.pkg.tar.*}"
            core2="${core%-*}"
            core3="${core2%-*}"
            pkg_name="${core3%-*}"
            echo "🗑️ Removing stale package $pkg_name ($fn) from $REPO_NAME.db..."
            repo-remove --sign --key "$GPG_FINGERPRINT" "$DB_FILE" "$pkg_name" || true
        fi
    done
fi

# Identify active Arch packages in current_assets.txt that are missing from inled.db
MISSING_PKGS=()
if [ -f "current_assets.txt" ]; then
    while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        if [[ "$asset" == *.pkg.tar.* ]] && [[ "$asset" != *.sig ]]; then
            is_indexed=false
            for ifn in "${INDEXED_FILENAMES[@]}"; do
                if [ "$ifn" = "$asset" ]; then
                    is_indexed=true
                    break
                fi
            done
            if [ "$is_indexed" = false ]; then
                MISSING_PKGS+=("$asset")
            fi
        fi
    done < current_assets.txt
fi

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Found ${#MISSING_PKGS[@]} active Arch package(s) missing from $REPO_NAME.db: ${MISSING_PKGS[*]}"
    BASE_RELEASE_URL="${RELEASE_URL:-https://github.com/InledGroup/apt/releases/download/packages}"
    for asset in "${MISSING_PKGS[@]}"; do
        if [ ! -f "incoming/$asset" ]; then
            echo "Downloading missing asset: $asset..."
            if wget -q "$BASE_RELEASE_URL/$asset" -O "incoming/$asset"; then
                echo "Signing downloaded package incoming/$asset..."
                rm -f "incoming/$asset.sig"
                gpg --batch --yes --detach-sign --default-key "$GPG_FINGERPRINT" "incoming/$asset"
            else
                echo "⚠️ Failed to download $BASE_RELEASE_URL/$asset"
                rm -f "incoming/$asset"
            fi
        fi
    done
fi

# 3. Add all packages in incoming to inled.db
shopt -s nullglob
all_pkgs_to_add=(incoming/*.pkg.tar.*)
shopt -u nullglob

PKGS_TO_ADD=()
for pkg in "${all_pkgs_to_add[@]}"; do
    if [[ "$pkg" == *.sig ]]; then continue; fi
    PKGS_TO_ADD+=("$pkg")
done

if [ ${#PKGS_TO_ADD[@]} -gt 0 ]; then
    echo "Running repo-add for ${#PKGS_TO_ADD[@]} packages..."
    repo-add --sign --key "$GPG_FINGERPRINT" "$DB_FILE" "${PKGS_TO_ADD[@]}"
fi

# 4. Fix symlinks for Cloudflare Pages (convert all symlinks to real files)
echo "Fixing symlinks for Cloudflare Pages..."
for link in "$ARCH_DIR"/*; do
    if [ -L "$link" ]; then
        target=$(readlink -f "$link")
        echo "Converting symlink to real file: $link -> $target"
        rm "$link"
        cp "$target" "$link"
    fi
done

echo "Arch Linux repository updated successfully in '$ARCH_DIR/'"
