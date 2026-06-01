import os
import re
import sys
import hashlib

def get_file_stats(path):
    with open(path, 'rb') as f:
        data = f.read()
    return {
        'size': len(data),
        'md5': hashlib.md5(data).hexdigest(),
        'sha1': hashlib.sha1(data).hexdigest(),
        'sha256': hashlib.sha256(data).hexdigest()
    }

def patch_packages_file(packages_path, release_url_base):
    if not os.path.exists(packages_path):
        return None

    with open(packages_path, 'r') as f:
        content = f.read()

    blocks = content.split('\n\n')
    new_blocks = []

    for block in blocks:
        if not block.strip(): continue
        match = re.search(r'^Filename: (.*)$', block, re.MULTILINE)
        if match:
            basename = os.path.basename(match.group(1))
            new_filename = f"{release_url_base}/{basename}"
            block = re.sub(r'^Filename: .*$', f"Filename: {new_filename}", block, flags=re.MULTILINE)
        new_blocks.append(block)

    patched_content = '\n\n'.join(new_blocks) + '\n\n'
    with open(packages_path, 'w') as f:
        f.write(patched_content)
    
    # Also patch Packages.gz if it exists (simplification: just delete it or recreate it)
    # For now, we assume only uncompressed Packages is used or we need to fix both.
    # To keep it simple, we focus on the plain Packages file.
    return get_file_stats(packages_path)

def update_release_file(release_path, package_stats):
    if not os.path.exists(release_path): return
    
    with open(release_path, 'r') as f:
        lines = f.readlines()
    
    new_lines = []
    current_section = None
    
    for line in lines:
        if line.startswith('MD5Sum:'): current_section = 'md5'
        elif line.startswith('SHA1:'): current_section = 'sha1'
        elif line.startswith('SHA256:'): current_section = 'sha256'
        elif not line.startswith(' '): current_section = None
        
        if current_section and line.startswith(' '):
            # Format:  hash size path
            parts = line.strip().split()
            if len(parts) == 3:
                path = parts[2]
                if path in package_stats:
                    stats = package_stats[path]
                    new_lines.append(f" {stats[current_section]} {stats['size']} {path}\n")
                    continue
        new_lines.append(line)
        
    with open(release_path, 'w') as f:
        f.writelines(new_lines)

if __name__ == "__main__":
    base_dir = sys.argv[1]
    release_url = sys.argv[2]
    
    all_stats = {}
    for root, dirs, files in os.walk(base_dir):
        if "Packages" in files:
            pkg_path = os.path.join(root, "Packages")
            rel_path = os.path.relpath(pkg_path, base_dir)
            print(f"Patching {pkg_path}...")
            stats = patch_packages_file(pkg_path, release_url)
            if stats:
                all_stats[rel_path] = stats
                # If Packages.gz exists, it's better to remove it so apt uses the patched Packages
                gz_path = pkg_path + ".gz"
                if os.path.exists(gz_path):
                    os.remove(gz_path)

    # Find and update Release files
    for root, dirs, files in os.walk(base_dir):
        if "Release" in files:
            release_path = os.path.join(root, "Release")
            print(f"Updating hashes in {release_path}...")
            update_release_file(release_path, all_stats)
            
            # Re-sign the Release file to create InRelease and Release.gpg
            # This requires gpg to be available and the key to be the same
            # Since we are in the script, we can call gpg if we have the info
            # Or we can do it in the main bash script.
