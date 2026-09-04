#!/bin/bash
set -e

ARCH_DIR="public/arch"
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
mkdir -p "$ARCH_DIR"
DB_FILE="$ARCH_DIR/$REPO_NAME.db.tar.gz"

# Check if there are new Arch packages in incoming
shopt -s nullglob
incoming_pkgs=(incoming/*.pkg.tar.*)
shopt -u nullglob

PKGS_TO_ADD=()
for pkg in "${incoming_pkgs[@]}"; do
    if [[ "$pkg" == *.sig ]]; then continue; fi
    echo "Processing incoming Arch package: $pkg"
    echo "Signing package $pkg..."
    rm -f "$pkg.sig"
    gpg --batch --yes --detach-sign --default-key "$GPG_FINGERPRINT" "$pkg"
    PKGS_TO_ADD+=("$pkg")
done

if [ ${#PKGS_TO_ADD[@]} -gt 0 ]; then
    echo "Running repo-add for ${#PKGS_TO_ADD[@]} packages..."
    repo-add --sign --key "$GPG_FINGERPRINT" "$DB_FILE" "${PKGS_TO_ADD[@]}"
fi

# Fix symlinks for Cloudflare Pages
echo "Fixing symlinks for Cloudflare Pages..."
for link in "$ARCH_DIR/$REPO_NAME.db" "$ARCH_DIR/$REPO_NAME.files"; do
    if [ -L "$link" ]; then
        target=$(readlink -f "$link")
        echo "Converting symlink to real file: $link -> $target"
        rm "$link"
        cp "$target" "$link"
    fi
done

# Ensure .db.sig and .files.sig exist
for sig_src in "$ARCH_DIR/$REPO_NAME.db.tar.gz.sig" "$ARCH_DIR/$REPO_NAME.files.tar.gz.sig"; do
    if [ -f "$sig_src" ]; then
        sig_dst="${sig_src%.tar.gz.sig}.sig"
        if [ ! -f "$sig_dst" ] || [ "$sig_src" -nt "$sig_dst" ]; then
            echo "Creating $sig_dst for pacman compatibility..."
            cp -f "$sig_src" "$sig_dst"
        fi
    fi
done

echo "Arch Linux repository updated successfully in '$ARCH_DIR/'"
