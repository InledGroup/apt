import os
import re
import sys
import hashlib

def get_file_stats(path):
    """
    Calculates size and hashes (MD5, SHA1, SHA256, SHA512) of a file.
    Calcula el tamaño y hashes (MD5, SHA1, SHA256, SHA512) de un archivo.
    """
    with open(path, 'rb') as f:
        data = f.read()
    return {
        'size': len(data),
        'md5': hashlib.md5(data).hexdigest(),
        'sha1': hashlib.sha1(data).hexdigest(),
        'sha256': hashlib.sha256(data).hexdigest(),
        'sha512': hashlib.sha512(data).hexdigest()
    }

def patch_packages_file(packages_path, release_url_base):
    """
    Patches the Packages file so Filename points to an absolute URL.
    Parchea el archivo Packages para que Filename apunte a una URL absoluta.
    """
    if not os.path.exists(packages_path):
        return False

    with open(packages_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Split by double newline to separate records
    # Separar por doble salto de línea para procesar cada paquete individualmente
    records = re.split(r'\n\n+', content)
    new_records = []

    for record in records:
        if not record.strip():
            continue
        
        # Replace Filename: path/to/file.deb -> Filename: URL/file.deb
        # Reemplazar la ruta local del archivo por la URL absoluta de GitHub Releases
        match = re.search(r'^Filename: (.*)$', record, re.MULTILINE)
        if match:
            basename = os.path.basename(match.group(1))
            new_filename = f"{release_url_base}/{basename}"
            record = re.sub(r'^Filename: .*$', f"Filename: {new_filename}", record, flags=re.MULTILINE)
        
        new_records.append(record.strip())

    if not new_records:
        return False

    # Write back the patched content
    # Escribir el contenido parcheado de nuevo en el archivo
    with open(packages_path, 'w', encoding='utf-8') as f:
        f.write('\n\n'.join(new_records) + '\n\n')
    
    print(f"  - Patched {packages_path}")
    return True

def update_release_file(release_path):
    """
    Updates the Release file recalculating hashes and removing non-existent files.
    Actualiza el archivo Release recalculando hashes y eliminando archivos inexistentes.
    """
    if not os.path.exists(release_path):
        return
    
    print(f"  - Updating {release_path}...")
    with open(release_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    release_dir = os.path.dirname(release_path)
    new_lines = []
    current_section = None
    
    # Hash section headers
    # Cabeceras de las secciones de hashes en el archivo Release
    sections = {
        'MD5Sum:': 'md5',
        'SHA1:': 'sha1',
        'SHA256:': 'sha256',
        'SHA512:': 'sha512'
    }
    
    for line in lines:
        stripped = line.strip()
        
        # Check if we are entering a hash section
        # Detectar si entramos en una sección de hashes
        found_section = False
        for s_header, s_key in sections.items():
            if line.startswith(s_header):
                current_section = s_key
                new_lines.append(line)
                found_section = True
                break
        if found_section:
            continue
        
        # If line doesn't start with space, we are out of a hash section
        # Si la línea no empieza con espacio, hemos salido de la sección de hashes
        if not line.startswith(' '):
            current_section = None
            new_lines.append(line)
            continue
            
        # If we are in a hash section, process the file entry
        # Si estamos en una sección de hashes, procesamos la entrada del archivo
        if current_section and line.startswith(' '):
            parts = stripped.split()
            if len(parts) == 3:
                # Format: <hash> <size> <relative_path>
                file_rel_path = parts[2]
                full_path = os.path.join(release_dir, file_rel_path)
                
                if os.path.exists(full_path):
                    # Recalculate stats for existing files
                    # Recalcular estadísticas para archivos existentes
                    stats = get_file_stats(full_path)
                    new_lines.append(f" {stats[current_section]} {stats['size']} {file_rel_path}\n")
                else:
                    # File does not exist (e.g. deleted Packages.gz), omit it to force APT to use Packages
                    # El archivo no existe (ej: Packages.gz borrado), lo omitimos para forzar a APT a usar Packages plano
                    print(f"    [!] Removing reference to missing file: {file_rel_path}")
                    continue
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)
            
    with open(release_path, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 patch-packages.py <base_dir> <release_url>")
        sys.exit(1)
        
    base_dir = sys.argv[1]
    release_url = sys.argv[2]
    
    print(f"--- Starting metadata patching in {base_dir} ---")
    
    # 1. Patch Packages files and remove compressed versions
    # 1. Parchear archivos Packages y eliminar versiones comprimidas
    for root, dirs, files in os.walk(base_dir):
        if "Packages" in files:
            pkg_path = os.path.join(root, "Packages")
            patch_packages_file(pkg_path, release_url)
            
            # Remove compressed versions to force APT to use the patched Packages file
            # Borrar versiones comprimidas para obligar a APT a usar el archivo Packages parcheado
            for ext in [".gz", ".bz2", ".lzma", ".xz"]:
                comp_path = pkg_path + ext
                if os.path.exists(comp_path):
                    os.remove(comp_path)
                    print(f"  - Removed {comp_path}")

    # 2. Update Release files
    # 2. Actualizar archivos Release
    for root, dirs, files in os.walk(base_dir):
        if "Release" in files:
            release_path = os.path.join(root, "Release")
            update_release_file(release_path)

    print("--- Metadata patching completed ---")
