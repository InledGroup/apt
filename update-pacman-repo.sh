#!/bin/bash
set -e

REPO_NAME="inled"

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
mkdir -p public/arch public/arch/x86_64 public/arch/aarch64 incoming

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

# Function to manage an architecture repository database
sync_arch_repo() {
    local target_dir="$1"
    local target_arch="$2" # "x86_64" or "aarch64"
    local db_file="$target_dir/$REPO_NAME.db.tar.gz"

    echo "--- Syncing Arch repo for $target_arch in '$target_dir' ---"
    mkdir -p "$target_dir"

    local indexed_filenames=()
    if [ -f "$db_file" ]; then
        while IFS= read -r fn; do
            [ -n "$fn" ] && indexed_filenames+=("$fn")
        done < <(tar -ztf "$db_file" 2>/dev/null | grep '/desc$' | while read -r desc_entry; do
            tar -zxOf "$db_file" "$desc_entry" | grep -A 1 '^%FILENAME%' | tail -n 1
        done)
    fi

    # Purge stale packages from db
    if [ -f "current_assets.txt" ] && [ -f "$db_file" ]; then
        for fn in "${indexed_filenames[@]}"; do
            if ! grep -Fxq "$fn" current_assets.txt && [ ! -f "incoming/$fn" ]; then
                local core="${fn%.pkg.tar.*}"
                local core2="${core%-*}"
                local core3="${core2%-*}"
                local pkg_name="${core3%-*}"
                echo "🗑️ Removing stale package $pkg_name ($fn) from $db_file..."
                repo-remove --sign --key "$GPG_FINGERPRINT" "$db_file" "$pkg_name" || true
            fi
        done
    fi

    # Identify missing packages for this target architecture
    local missing_pkgs=()
    if [ -f "current_assets.txt" ]; then
        while IFS= read -r asset; do
            [ -n "$asset" ] || continue
            if [[ "$asset" == *.pkg.tar.* ]] && [[ "$asset" != *.sig ]]; then
                if [[ "$asset" == *"-${target_arch}.pkg.tar."* ]] || [[ "$asset" == *"-any.pkg.tar."* ]]; then
                    local is_indexed=false
                    for ifn in "${indexed_filenames[@]}"; do
                        if [ "$ifn" = "$asset" ]; then
                            is_indexed=true
                            break
                        fi
                    done
                    if [ "$is_indexed" = false ]; then
                        missing_pkgs+=("$asset")
                    fi
                fi
            fi
        done < current_assets.txt
    fi

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "Found ${#missing_pkgs[@]} active Arch package(s) missing from $target_dir: ${missing_pkgs[*]}"
        local base_release_url="${RELEASE_URL:-https://github.com/InledGroup/apt/releases/download/packages}"
        for asset in "${missing_pkgs[@]}"; do
            if [ ! -f "incoming/$asset" ]; then
                echo "Downloading missing asset: $asset..."
                if wget -q "$base_release_url/$asset" -O "incoming/$asset"; then
                    echo "Signing downloaded package incoming/$asset..."
                    rm -f "incoming/$asset.sig"
                    gpg --batch --yes --detach-sign --default-key "$GPG_FINGERPRINT" "incoming/$asset"
                else
                    echo "⚠️ Failed to download $base_release_url/$asset"
                    rm -f "incoming/$asset"
                fi
            fi
        done
    fi

    # Add matching incoming packages to db
    shopt -s nullglob
    local all_incoming=(incoming/*.pkg.tar.*)
    shopt -u nullglob

    local pkgs_to_add=()
    for pkg in "${all_incoming[@]}"; do
        if [[ "$pkg" == *.sig ]]; then continue; fi
        if [[ "$pkg" == *"-${target_arch}.pkg.tar."* ]] || [[ "$pkg" == *"-any.pkg.tar."* ]]; then
            pkgs_to_add+=("$pkg")
        fi
    done

    if [ ${#pkgs_to_add[@]} -gt 0 ]; then
        echo "Running repo-add in $target_dir for ${#pkgs_to_add[@]} packages..."
        repo-add --sign --key "$GPG_FINGERPRINT" "$db_file" "${pkgs_to_add[@]}"
    fi

    # Dereference all symlinks in target_dir for Cloudflare Pages
    for link in "$target_dir"/*; do
        if [ -L "$link" ]; then
            local target=$(readlink -f "$link")
            rm "$link"
            cp "$target" "$link"
        fi
    done
}

# 2. Build and sync x86_64 repository at public/arch and public/arch/x86_64
sync_arch_repo "public/arch" "x86_64"

# Mirror public/arch files into public/arch/x86_64
echo "Mirroring public/arch database to public/arch/x86_64..."
cp -f public/arch/inled.* public/arch/x86_64/ 2>/dev/null || true

# 3. Build and sync aarch64 repository at public/arch/aarch64
sync_arch_repo "public/arch/aarch64" "aarch64"

echo "Arch Linux repositories updated successfully."
