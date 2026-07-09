#!/bin/bash
set -e

# Configuration
DISTRIBUTION="${DISTRIBUTION:-stable}"
REPO_NAME="inled-repo"
if [ "$DISTRIBUTION" != "stable" ]; then
    REPO_NAME="inled-repo-$DISTRIBUTION"
fi
COMPONENT="main"
GPG_KEY_ID="repo@inled.es"

# Extract the actual GPG fingerprint for this key
get_gpg_fingerprint() {
    gpg --list-keys --with-colons "$1" 2>/dev/null | grep '^fpr:' | head -1 | cut -d: -f10
}

GPG_FINGERPRINT=$(get_gpg_fingerprint "$GPG_KEY_ID")
if [ -z "$GPG_FINGERPRINT" ]; then
    echo "ERROR: GPG key '$GPG_KEY_ID' not found in keyring. Export or generate it first."
    exit 1
fi
echo "Using GPG key: $GPG_KEY_ID (fingerprint: $GPG_FINGERPRINT)"

# Ensure directories
mkdir -p .aptly public

# Initialize repository if needed
if ! aptly -config=aptly.conf repo show "$REPO_NAME" > /dev/null 2>&1; then
    echo "Creating repository $REPO_NAME..."
    aptly -config=aptly.conf repo create -comment="Inled APT Repository" -distribution="$DISTRIBUTION" -component="$COMPONENT" "$REPO_NAME"
fi

# Add packages from 'incoming'
shopt -s nullglob
deb_files=(incoming/*.deb)
shopt -u nullglob
if [ ${#deb_files[@]} -gt 0 ]; then
    echo "Syncing packages with APT repository..."
    aptly -config=aptly.conf repo add -force-replace "$REPO_NAME" incoming/
fi

# Publish or update
if ! aptly -config=aptly.conf publish list | grep -q "$DISTRIBUTION"; then
    echo "Publishing for first time..."
    aptly publish repo -config=aptly.conf -distribution="$DISTRIBUTION" "$REPO_NAME" filesystem:public:
else
    echo "Updating publication..."
    aptly publish update -force-overwrite -config=aptly.conf "$DISTRIBUTION" filesystem:public:
fi

# Patch Packages files to point to release URL, then regenerate Release signatures
if [ -n "$RELEASE_URL" ]; then
    echo "Patching Packages files to point to $RELEASE_URL..."
    python3 patch-packages.py public "$RELEASE_URL"
fi

# Always regenerate Release signatures
find public/dists -name "Release" | while read release_file; do
    dir=$(dirname "$release_file")
    rm -f "$dir/InRelease" "$dir/Release.gpg"
    gpg --batch --yes --armor --detach-sign --default-key "$GPG_FINGERPRINT" -o "$dir/Release.gpg" "$release_file"
    gpg --batch --yes --armor --clearsign --default-key "$GPG_FINGERPRINT" -o "$dir/InRelease" "$release_file"
done

# Remove local pool (served from GitHub Releases)
if [ -n "$RELEASE_URL" ]; then
    rm -rf public/pool
fi

# Export public key
if gpg --armor --export "$GPG_FINGERPRINT" > public/archive.key 2>/dev/null; then
    echo "Public key exported to public/archive.key"
else
    echo "ERROR: Failed to export GPG key"
    exit 1
fi

# Ensure skills directory
mkdir -p public/skills
if [ -d "skills" ]; then
    cp -r skills/* public/skills/
fi

# Update RPM and Arch repos
if [ -f "./update-rpm-repo.sh" ]; then
    GPG_FINGERPRINT="$GPG_FINGERPRINT" bash ./update-rpm-repo.sh
fi
if [ -f "./update-pacman-repo.sh" ]; then
    GPG_FINGERPRINT="$GPG_FINGERPRINT" bash ./update-pacman-repo.sh
fi

# Generate directory indexes
echo "Generating directory indexes..."
python3 generate-indexes.py public

# Generate HTML and packages.json
if [ -f "index.html.template" ]; then
    echo "Generating web and metadata..."
    python3 generate-web-index.py "$RELEASE_URL" "$GPG_FINGERPRINT"
fi

# Build _redirects atomically
REDIRECTS_FILE="public/_redirects"
REDIRECTS_TMP="${REDIRECTS_FILE}.tmp"

# Start fresh
: > "$REDIRECTS_TMP"

# If patch-packages.py already wrote redirects, include them
if [ -n "$RELEASE_URL" ] && [ -f "$REDIRECTS_FILE" ]; then
    cat "$REDIRECTS_FILE" >> "$REDIRECTS_TMP"
fi

# Process RPMs
if [ -d "public/rpm" ]; then
    mkdir -p incoming
    shopt -s nullglob
    for rpm_file in public/rpm/*.rpm; do
        shopt -u nullglob
        filename=$(basename "$rpm_file")
        echo "/rpm/$filename $RELEASE_URL/$filename 302" >> "$REDIRECTS_TMP"
        cp "$rpm_file" incoming/
        rm "$rpm_file"
    done
    shopt -u nullglob
fi

# Process Arch packages
if [ -d "public/arch" ]; then
    mkdir -p incoming
    shopt -s nullglob
    for pkg_file in public/arch/*.pkg.tar.*; do
        shopt -u nullglob
        if [[ "$pkg_file" == *.sig ]]; then continue; fi
        filename=$(basename "$pkg_file")
        echo "/arch/$filename $RELEASE_URL/$filename 302" >> "$REDIRECTS_TMP"
        cp "$pkg_file" incoming/
        rm "$pkg_file"
        if [ -f "$pkg_file.sig" ]; then
            sig_filename="$filename.sig"
            echo "/arch/$sig_filename $RELEASE_URL/$sig_filename 302" >> "$REDIRECTS_TMP"
            rm "$pkg_file.sig"
        fi
    done
    shopt -u nullglob
fi

# Deduplicate and atomically write _redirects
sort -u "$REDIRECTS_TMP" > "$REDIRECTS_FILE"
rm -f "$REDIRECTS_TMP"

# Create _headers for Cloudflare Pages
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
  Content-Type: application/zstd
/skills/*.md
  Content-Type: text/markdown; charset=utf-8
EOF

echo "Repository updated successfully."
