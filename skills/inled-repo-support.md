---
name: inled-repo-support
description: Workflow for implementing and interacting with Inled's APT and RPM repositories. Use when creating new projects that need to publish packages to Inled's repo or when configuring a system to use Inled repositories.
---

# Inled Repo Support

This skill guides AI agents and developers in integrating their applications with Inled's central repository.

## 1. For App Developers: Automating Package Delivery

To make your application automatically upload new versions to the Inled repository, add a step to your GitHub Action after the build process.

### GitHub Action: Sending to Inled Repo
Trigger the central repository update using a `repository_dispatch` event.

```yaml
- name: Notify Inled Repo
  run: |
    curl -X POST -H "Accept: application/vnd.github.v3+json" \
         -H "Authorization: token ${{ secrets.INLED_REPO_PAT }}" \
         https://api.github.com/repos/InledGroup/apt/dispatches \
         -d '{"event_type": "package_upload", "client_payload": {"package_url": "https://github.com/${{ github.repository }}/releases/download/${{ github.ref_name }}/your-app.deb"}}'
```
*Note: `INLED_REPO_PAT` must be a Personal Access Token with write access to the central `aptrepo` repository.*

## 2. For System Configuration (Client Side)

### APT Integration (Debian/Ubuntu)
Include these commands in your installation scripts or documentation:

```bash
# Import GPG Key
wget -qO- https://apt.inled.es/archive.key | gpg --dearmor | sudo tee /usr/share/keyrings/inled-archive-keyring.gpg > /dev/null

# Add Repository Source
echo "deb [signed-by=/usr/share/keyrings/inled-archive-keyring.gpg] https://apt.inled.es stable main" | sudo tee /etc/apt/sources.list.d/inled.list
```

### DNF/YUM Integration (Fedora/RHEL)
```bash
sudo tee /etc/yum.repos.d/inled.repo <<EOF
[inled]
name=Inled Repository
baseurl=https://apt.inled.es/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://apt.inled.es/archive.key
EOF
```

### Pacman Integration (Arch Linux / PearOS)
Include these commands to trust the repository key:

```bash
# Import and trust the key
curl -s https://apt.inled.es/archive.key | sudo pacman-key -a -
sudo pacman-key --lsign-key EB2D78F1CBA07666726817967EDDC83147A77DD4

# Add the repository to /etc/pacman.conf
sudo tee -a /etc/pacman.conf <<EOF

[inled]
SigLevel = Required DatabaseOptional
Server = https://apt.inled.es/arch/
EOF

# Update databases
sudo pacman -Sy
```

## 3. Maintaining the Central Repository

### APT Signing (update-repo.sh)
The central repo re-signs `Release` files using `gpg --clearsign` for `InRelease` and `--detach-sign` for `Release.gpg`.

### RPM Signing (update-rpm-repo.sh)
RPM metadata is signed via `gpg --detach-sign --armor` on the `repomd.xml` file.

## Troubleshooting
- **403 Forbidden**: Ensure the GitHub PAT has enough permissions.
- **InRelease not found**: Check if Cloudflare Pages is serving an HTML 404 instead of the file.
