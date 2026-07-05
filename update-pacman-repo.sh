#!/bin/bash
set -e

# Configuration
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

# Add Arch packages from 'incoming'
shopt -s nullglob
incoming_pkgs=(incoming/*.pkg.tar.*)
shopt -u nullglob
if [ ${#incoming_pkgs[@]} -gt 0 ]; then
    echo "Adding new Arch packages..."
    cp incoming/*.pkg.tar.* "$ARCH_DIR/"
    rm -f incoming/*.pkg.tar.*
fi

# Check if there are packages to process
shopt -s nullglob
arch_pkgs=("$ARCH_DIR"/*.pkg.tar.*)
shopt -u nullglob
if [ ${#arch_pkgs[@]} -eq 0 ]; then
    echo "No Arch packages in $ARCH_DIR. Skipping database generation."
    exit 0
fi

# Generate/Update database
echo "Updating database with repo-add..."
DB_FILE="$ARCH_DIR/$REPO_NAME.db.tar.gz"

# Collect valid packages
PKGS_TO_ADD=()
for pkg in "$ARCH_DIR"/*.pkg.tar.*; do
    if [[ "$pkg" == *.sig ]]; then continue; fi
    echo "Processing package: $pkg"
    if [ ! -f "$pkg.sig" ]; then
        echo "Signing package $pkg..."
        gpg --batch --yes --detach-sign --default-key "$GPG_FINGERPRINT" "$pkg"
    fi
    PKGS_TO_ADD+=("$pkg")
done

if [ ${#PKGS_TO_ADD[@]} -eq 0 ]; then
    echo "No valid packages to add."
    exit 0
fi

echo "Running repo-add for ${#PKGS_TO_ADD[@]} packages..."
repo-add --sign --key "$GPG_FINGERPRINT" "$DB_FILE" "${PKGS_TO_ADD[@]}"

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
        if [ ! -f "$sig_dst" ]; then
            echo "Creating $sig_dst symlink for pacman compatibility..."
            cp "$sig_src" "$sig_dst"
        fi
    fi
done

echo "Arch Linux repository updated successfully in '$ARCH_DIR/'"
