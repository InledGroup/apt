#!/usr/bin/python3
import os
import re
import subprocess
import json

def get_apt_packages(repo_name):
    packages = []
    try:
        output = subprocess.check_output(["aptly", "-config=aptly.conf", "repo", "show", "-with-packages", repo_name], text=True)
        lines = output.splitlines()
        start_index = -1
        for i, line in enumerate(lines):
            if "Packages:" in line:
                start_index = i + 1
                break
        
        if start_index != -1:
            for line in lines[start_index:]:
                line = line.strip()
                if not line: continue
                parts = line.split("_")
                if len(parts) >= 3:
                    packages.append({
                        "name": parts[0],
                        "version": parts[1],
                        "arch": parts[2],
                        "type": "deb",
                        "file": f"{parts[0]}_{parts[1]}_{parts[2]}.deb"
                    })
    except Exception as e:
        print(f"Error APT: {e}")
    return packages

def get_rpm_packages(rpm_dir):
    packages = []
    if not os.path.exists(rpm_dir): return packages
    for f in os.listdir(rpm_dir):
        if f.endswith(".rpm"):
            match = re.match(r"^(.+)-([^-]+)-([^-]+)\.([^.]+)\.rpm$", f)
            if match:
                packages.append({"name": match.group(1), "version": match.group(2), "arch": match.group(4), "type": "rpm", "file": f})
            else:
                packages.append({"name": f.split("-")[0], "version": "unknown", "arch": "unknown", "type": "rpm", "file": f})
    return packages

def get_arch_packages(arch_dir):
    packages = []
    if not os.path.exists(arch_dir): return packages
    for f in os.listdir(arch_dir):
        if f.endswith(".pkg.tar.zst") or f.endswith(".pkg.tar.xz"):
            match = re.match(r"^(.+)-([^-]+)-([^-]+)-([^.]+)\.pkg\.tar\..+$", f)
            if match:
                packages.append({"name": match.group(1), "version": match.group(2), "arch": match.group(4), "type": "arch", "file": f})
            else:
                packages.append({"name": f.split("-")[0], "version": "unknown", "arch": "unknown", "type": "arch", "file": f})
    return packages

def generate_html(release_url):
    # 1. Escanear estado actual
    apt_pkgs = get_apt_packages("inled-repo")
    rpm_pkgs = get_rpm_packages("public/rpm")
    arch_pkgs = get_arch_packages("public/arch")
    current_pkgs = apt_pkgs + rpm_pkgs + arch_pkgs
    
    print(f"Escaneo: APT({len(apt_pkgs)}), RPM({len(rpm_pkgs)}), Arch({len(arch_pkgs)})")

    # 2. Cargar/Actualizar JSON (Persistencia de metadatos)
    db_file = "packages.json"
    history = {}
    if os.path.exists(db_file):
        try:
            with open(db_file, "r") as f:
                history = json.load(f)
        except:
            history = {}

    # Fusionar escaneo actual en el historial
    for pkg in current_pkgs:
        name = pkg["name"]
        if name not in history: history[name] = {"versions": {}}
        
        version = pkg["version"]
        if version not in history[name]["versions"]: history[name]["versions"][version] = []
        
        # Evitar duplicados por nombre de archivo
        exists = any(p["file"] == pkg["file"] for p in history[name]["versions"][version])
        if not exists:
            history[name]["versions"][version].append(pkg)

    # Guardar historial actualizado
    with open(db_file, "w") as f:
        json.dump(history, f, indent=2)

    # 3. Generar HTML desde el Historial (para que no se olvide de nada)
    packages_html = ""
    if not history:
        packages_html = '<p style="grid-column: 1/-1; text-align: center; color: var(--text-muted);">No hay paquetes disponibles.</p>'
    else:
        for name in sorted(history.keys()):
            versions = sorted(history[name]["versions"].keys(), reverse=True)
            latest_overall_ver = versions[0]
            
            # Recopilar botones de las últimas versiones de cada tipo
            buttons_pkgs = []
            for p_type in ["deb", "rpm", "arch"]:
                # Encontrar la versión más reciente que tenga este tipo
                type_versions = []
                for v in versions:
                    if any(p["type"] == p_type for p in history[name]["versions"][v]):
                        type_versions.append(v)
                
                if type_versions:
                    latest_type_ver = sorted(type_versions, reverse=True)[0]
                    buttons_pkgs.extend([p for p in history[name]["versions"][latest_type_ver] if p["type"] == p_type])
            
            desc = "Gestor de aplicaciones multiplataforma" if name == "appinstall" else "Navegador web optimizado" if name == "seafari" else f"Paquete para {name}"
            
            item_html = f'<li class="package-item">'
            item_html += f'<div class="package-header"><span class="package-name">{name}</span><span class="package-version">v{latest_overall_ver}</span></div>'
            item_html += f'<p class="package-desc">{desc}</p>'
            item_html += f'<div class="package-footer">'
            
            for pkg in sorted(buttons_pkgs, key=lambda x: (x["type"], x["arch"])):
                arch_info = f' ({pkg["arch"]})' if pkg["arch"] != "unknown" else ""
                ver_info = f' v{pkg["version"]}' if pkg["version"] != latest_overall_ver else ""
                full_label = f"{pkg['type']}{arch_info}{ver_info}"
                item_html += f'<a href="{release_url}/{pkg["file"]}" class="btn btn-sm btn-{pkg["type"]}">⬇️ {full_label}</a>'
            
            item_html += f'</div></li>'
            packages_html += item_html

    with open("index.html.template", "r") as f:
        template = f.read()
    
    final_html = template.replace("<!-- PACKAGES_LIST_PLACEHOLDER -->", packages_html).replace("<KEY_ID>", "EB2D78F1CBA07666726817967EDDC83147A77DD4")
    with open("public/index.html", "w") as f:
        f.write(final_html)

if __name__ == "__main__":
    import sys
    url = sys.argv[1] if len(sys.argv) > 1 else "https://github.com/InledGroup/apt/releases/download/packages"
    generate_html(url)
