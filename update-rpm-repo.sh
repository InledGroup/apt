#!/bin/bash
set -e

# Configuration
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

# Add RPM packages from 'incoming'
shopt -s nullglob
incoming_rpms=(incoming/*.rpm)
shopt -u nullglob
if [ ${#incoming_rpms[@]} -gt 0 ]; then
    echo "Adding new RPM packages..."
    cp incoming/*.rpm "$RPM_DIR/"
    rm -f incoming/*.rpm
fi

# Check if there are packages to process
shopt -s nullglob
rpm_files=("$RPM_DIR"/*.rpm)
shopt -u nullglob
if [ ${#rpm_files[@]} -eq 0 ]; then
    echo "No RPM packages in $RPM_DIR. Skipping metadata generation."
    exit 0
fi

# Generate repository metadata
echo "Generating metadata with createrepo_c..."
createrepo_c --update "$RPM_DIR"

# Sign repomd.xml
echo "Signing repomd.xml..."
REPOMD_FILE="$RPM_DIR/repodata/repomd.xml"
if [ -f "$REPOMD_FILE" ]; then
    rm -f "$REPOMD_FILE.asc"
    gpg --batch --yes --armor --detach-sign --default-key "$GPG_FINGERPRINT" "$REPOMD_FILE"
    echo "Metadata signed successfully."
else
    echo "ERROR: $REPOMD_FILE not found"
    exit 1
fi

echo "RPM repository updated successfully in '$RPM_DIR/'"
