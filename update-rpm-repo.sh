#!/bin/bash
set -e

RPM_DIR="public/rpm"

# GPG fingerprint is passed from update-repo.sh; fall back to extracting it
if [ -z "$GPG_FINGERPRINT" ]; then
    GPG_FINGERPRINT=$(gpg --list-keys --with-colons "repo@inled.es" 2>/dev/null | grep '^fpr:' | head -1 | cut -d: -f10)
fi

if [ -z "$GPG_FINGERPRINT" ]; then
    echo "ERROR: No GPG fingerprint available. Set GPG_FINGERPRINT or ensure key exists."
    exit 1
fi

echo "=== Configuring RPM repository (DNF/YUM) ==="
echo "Using GPG fingerprint: $GPG_FINGERPRINT"

# Ensure directories
mkdir -p "$RPM_DIR"

# Check if there are missing active RPM packages to download
if [ -f "current_assets.txt" ]; then
    base_release_url="${RELEASE_URL:-https://github.com/InledGroup/apt/releases/download/packages}"
    while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        if [[ "$asset" == *.rpm ]]; then
            if [ ! -f "$RPM_DIR/$asset" ] && [ ! -f "incoming/$asset" ]; then
                echo "📥 Downloading active RPM package: $asset..."
                if ! wget -q "$base_release_url/$asset" -O "incoming/$asset"; then
                    echo "⚠️ Failed to download $base_release_url/$asset"
                    rm -f "incoming/$asset"
                fi
            fi
        fi
    done < current_assets.txt
fi

# Check if there are new RPM packages in incoming
shopt -s nullglob
incoming_rpms=(incoming/*.rpm)
shopt -u nullglob

if [ ${#incoming_rpms[@]} -gt 0 ]; then
    echo "Processing ${#incoming_rpms[@]} new RPM packages..."
    cp incoming/*.rpm "$RPM_DIR/"
    createrepo_c --update "$RPM_DIR"
    rm -f "$RPM_DIR"/*.rpm
elif [ ! -f "$RPM_DIR/repodata/repomd.xml" ]; then
    echo "Initializing empty RPM repodata..."
    createrepo_c "$RPM_DIR"
fi

# Sign repomd.xml
REPOMD_FILE="$RPM_DIR/repodata/repomd.xml"
if [ -f "$REPOMD_FILE" ]; then
    echo "Signing repomd.xml..."
    rm -f "$REPOMD_FILE.asc"
    gpg --batch --yes --armor --detach-sign --default-key "$GPG_FINGERPRINT" "$REPOMD_FILE"
    echo "Metadata signed successfully."
fi

echo "RPM repository updated successfully in '$RPM_DIR/'"
