#!/bin/bash
set -e

PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

echo "=== Syntax and static checks ==="

# Shell scripts - bash syntax
for script in update-repo.sh update-pacman-repo.sh update-rpm-repo.sh; do
    if bash -n "$script" 2>/dev/null; then
        pass "$script syntax is valid"
    else
        fail "$script syntax error"
    fi
done

# Python scripts - syntax
for script in generate-web-index.py generate-indexes.py patch-packages.py prune-release.py; do
    if python3 -c "compile(open('$script').read(), '$script', 'exec')" 2>/dev/null; then
        pass "$script syntax is valid"
    else
        fail "$script syntax error"
    fi
done

echo ""
echo "=== Package version parsing tests ==="

# Test RPM version parsing
RPM_PARSE=$(python3 -c "
import re
f = 'pulsaros-1.0.17-1.x86_64.rpm'
m = re.match(r'^(?P<name>.+?)-(?P<version>\d.*?)\.(?P<arch>x86_64|aarch64|arm64|noarch|i386|i686|armv7hl)\.rpm$', f)
print('name=' + m.group(1) + ', version=' + m.group(2) + ', arch=' + m.group(3))
")
if [ "$RPM_PARSE" = "name=pulsaros, version=1.0.17-1, arch=x86_64" ]; then
    pass "RPM version parsing: $RPM_PARSE"
else
    fail "RPM version parsing: got '$RPM_PARSE'"
fi

# Test Arch version parsing
ARCH_PARSE=$(python3 -c "
import re
f = 'seafari-1.11.0-1-x86_64.pkg.tar.zst'
m = re.match(r'^(?P<name>.+?)-(?P<version>\d[^-]*)-(?P<pkgrel>\d+)-(?P<arch>[^.]+)\.pkg\.tar\..+$', f)
print('name=' + m.group(1) + ', version=' + m.group(2) + ', pkgrel=' + m.group(3) + ', arch=' + m.group(4))
")
if [ "$ARCH_PARSE" = "name=seafari, version=1.11.0, pkgrel=1, arch=x86_64" ]; then
    pass "Arch version parsing: $ARCH_PARSE"
else
    fail "Arch version parsing: got '$ARCH_PARSE'"
fi

# Test Pruner Package parsing
PRUNER_PARSE=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('prune_release', 'prune-release.py')
pr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr)

p1 = pr.parse_package_filename('seafari_2.8.18_amd64.deb')
p2 = pr.parse_package_filename('seafari-2.8.18-1.x86_64.rpm')
p3 = pr.parse_package_filename('seafari-2.8.18-1-x86_64.pkg.tar.zst')

assert p1['name'] == 'seafari' and p1['type'] == 'deb' and p1['dist'] == 'stable'
assert p2['name'] == 'seafari' and p2['type'] == 'rpm'
assert p3['name'] == 'seafari' and p3['type'] == 'arch'
print('OK')
")
if [ "$PRUNER_PARSE" = "OK" ]; then
    pass "Pruner package classification works"
else
    fail "Pruner package classification failed"
fi

echo ""
echo "=== Web index generation test ==="

# Backup original packages.json
if [ -f packages.json ]; then
    cp packages.json packages.json.bak
fi

# Create mock packages on disk so the scan finds them
mkdir -p public/rpm public/arch
touch public/rpm/appinstall-1.0.0-1.x86_64.rpm
touch public/arch/appinstall-1.0.0-1-x86_64.pkg.tar.zst
touch public/arch/seafari-1.11.0-1-x86_64.pkg.tar.zst

# Create test current_assets.txt
cat > current_assets.txt <<'TESTASSETS'
appinstall-1.0.0-1.x86_64.rpm
appinstall-1.0.0-1-x86_64.pkg.tar.zst
seafari-1.11.0-1-x86_64.pkg.tar.zst
TESTASSETS

# Create test packages.json
cat > packages.json <<'TESTPKG'
{
  "appinstall": {
    "versions": {
      "1.0.0": [
        {"name": "appinstall", "version": "1.0.0", "arch": "x86_64", "type": "rpm", "file": "appinstall-1.0.0-1.x86_64.rpm"},
        {"name": "appinstall", "version": "1.0.0", "arch": "x86_64", "type": "arch", "file": "appinstall-1.0.0-1-x86_64.pkg.tar.zst"}
      ]
    }
  },
  "seafari": {
    "versions": {
      "1.11.0": [
        {"name": "seafari", "version": "1.11.0", "arch": "x86_64", "type": "arch", "file": "seafari-1.11.0-1-x86_64.pkg.tar.zst"}
      ]
    }
  }
}
TESTPKG

# Generate web index
if python3 generate-web-index.py "https://github.com/InledGroup/apt/releases/download/packages" "EB2D78F1CBA07666726817967EDDC83147A77DD4" 2>/dev/null; then
    pass "generate-web-index.py ran successfully"
else
    fail "generate-web-index.py failed"
fi

# Verify output
if [ -f public/index.html ]; then
    pass "public/index.html was generated"

    # Check search box exists
    if grep -q 'id="search"' public/index.html; then
        pass "Search box is present in HTML"
    else
        fail "Search box missing in HTML"
    fi

    # Check key ID was replaced
    if grep -q 'EB2D78F1CBA07666726817967EDDC83147A77DD4' public/index.html; then
        pass "Key ID is present in generated HTML"
    else
        fail "Key ID missing in generated HTML"
    fi

    # Check packages are listed
    if grep -q 'appinstall' public/index.html; then
        pass "Package 'appinstall' appears in HTML"
    else
        fail "Package 'appinstall' missing from HTML"
    fi

    if grep -q 'seafari' public/index.html; then
        pass "Package 'seafari' appears in HTML"
    else
        fail "Package 'seafari' missing from HTML"
    fi
else
    fail "public/index.html was not generated"
fi

# Verify packages.json still valid
if python3 -c "import json; d=json.load(open('packages.json')); assert len(d) > 0" 2>/dev/null; then
    pass "packages.json is valid and non-empty"
else
    fail "packages.json is invalid or empty"
fi

# Clean up mock files
rm -f public/rpm/appinstall-1.0.0-1.x86_64.rpm
rm -f public/arch/appinstall-1.0.0-1-x86_64.pkg.tar.zst
rm -f public/arch/seafari-1.11.0-1-x86_64.pkg.tar.zst
rm -f current_assets.txt

# Restore backup
if [ -f packages.json.bak ]; then
    mv packages.json.bak packages.json
fi

echo ""
echo "=== HTML validation checks ==="

# Check HTML lang
if grep -q 'lang="en"' index.html.template; then
    pass "Template lang is 'en'"
else
    fail "Template lang is not 'en'"
fi

# Check template has KEY_ID placeholder
if grep -q '&lt;KEY_ID&gt;\|<KEY_ID>' index.html.template; then
    pass "Template uses <KEY_ID> placeholder"
else
    fail "Template missing <KEY_ID> placeholder"
fi

echo ""
echo "=== Atomic write tests ==="

# Test that generate-web-index.py uses atomic write
if grep -q 'os.replace' generate-web-index.py; then
    pass "generate-web-index.py uses atomic write (os.replace)"
else
    fail "generate-web-index.py does not use atomic write"
fi

if grep -q 'os.replace' patch-packages.py; then
    pass "patch-packages.py uses atomic write (os.replace)"
else
    fail "patch-packages.py does not use atomic write"
fi

echo ""
echo "=== GPG fingerprint extraction test ==="

GNUPGHOME=$(mktemp -d)
export GNUPGHOME

cat > /tmp/gpg-test-key <<TESTGPG
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: Test Repo
Name-Email: test@example.com
Expire-Date: 0
%commit
TESTGPG

if gpg --batch --generate-key /tmp/gpg-test-key 2>/dev/null; then
    FPR=$(gpg --list-keys --with-colons "test@example.com" 2>/dev/null | grep '^fpr:' | head -1 | cut -d: -f10)
    if [ -n "$FPR" ]; then
        pass "GPG fingerprint extraction works: $FPR"
    else
        fail "GPG fingerprint extraction returned empty"
    fi
else
    fail "GPG key generation failed"
fi

rm -rf "$GNUPGHOME" /tmp/gpg-test-key

echo ""
echo "=== Summary ==="
echo "Passed: $PASS, Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
