#!/usr/bin/python3
"""Preview the repository web page with fake packages.

Runs the real generator (generate-web-index.py) inside an isolated sandbox
directory (/tmp/inled-preview), so the repository's own packages.json and
public/ are NEVER touched. Production deployments are unaffected: the CI
pipeline keeps using the real data as always.

Usage:
    ./preview-web.py                # generate and open in browser
    ./preview-web.py --no-open      # generate only, print the path
    ./preview-web.py --release-url URL --key-id ABCD1234
"""
import argparse
import importlib.util
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True  # avoid creating __pycache__ in the repo

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PREVIEW_DIR = "/tmp/inled-preview"

FAKE_DEBS = [
    {"name": "inled-hello", "version": "2.1.0", "arch": "amd64", "type": "deb",
     "branch": "stable", "file": "inled-hello_2.1.0_amd64.deb"},
    {"name": "inled-hello", "version": "2.2.0~rc1", "arch": "amd64", "type": "deb",
     "branch": "forky", "file": "inled-hello_2.2.0~rc1_deb14_amd64.deb"},
    {"name": "inled-hello", "version": "2.2.0+rolling", "arch": "amd64", "type": "deb",
     "branch": "rolling", "file": "inled-hello_2.2.0+rolling_rolling_amd64.deb"},
    {"name": "inled-terminal", "version": "0.9.4", "arch": "amd64", "type": "deb",
     "branch": "stable", "file": "inled-terminal_0.9.4_amd64.deb"},
    {"name": "inled-notes", "version": "1.0.0", "arch": "arm64", "type": "deb",
     "branch": "stable", "file": "inled-notes_1.0.0_arm64.deb"},
]
FAKE_RPMS = [
    {"name": "inled-hello", "version": "2.1.0", "arch": "x86_64", "type": "rpm",
     "file": "inled-hello-2.1.0-1.x86_64.rpm"},
    {"name": "inled-player", "version": "3.5", "arch": "x86_64", "type": "rpm",
     "file": "inled-player-3.5-1.x86_64.rpm"},
]
FAKE_ARCH = [
    {"name": "inled-hello", "version": "2.1.0", "arch": "x86_64", "type": "arch",
     "file": "inled-hello-2.1.0-1-x86_64.pkg.tar.zst"},
]


def load_generator():
    """Import generate-web-index.py without executing its main block."""
    path = os.path.join(SCRIPT_DIR, "generate-web-index.py")
    spec = importlib.util.spec_from_file_location("generate_web_index", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-url",
                        default="https://github.com/InledGroup/apt/releases/download/packages",
                        help="Base URL used by the download buttons")
    parser.add_argument("--key-id", default="ABCDEF1234567890",
                        help="Placeholder GPG key id for the Pacman instructions")
    parser.add_argument("--no-open", action="store_true",
                        help="Generate the page but do not open the browser")
    args = parser.parse_args()

    gen = load_generator()

    # Replace the real package scanners with fake data sources
    def fake_apt(repo_name):
        # Each repo only holds the packages of its own distribution,
        # mirroring how the real aptly repos behave
        if "forky" in repo_name:
            wanted = "forky"
        elif "rolling" in repo_name:
            wanted = "rolling"
        else:
            wanted = "stable"
        return [dict(p) for p in FAKE_DEBS if p["branch"] == wanted]

    gen.get_apt_packages = fake_apt
    gen.get_rpm_packages = lambda _dir: list(FAKE_RPMS)
    gen.get_arch_packages = lambda _dir: list(FAKE_ARCH)

    # Fresh sandbox on every run: the generator only reads/writes here
    shutil.rmtree(PREVIEW_DIR, ignore_errors=True)
    os.makedirs(PREVIEW_DIR)
    shutil.copy(os.path.join(SCRIPT_DIR, "index.html.template"), PREVIEW_DIR)
    os.chdir(PREVIEW_DIR)

    gen.generate_html(args.release_url, args.key_id)

    out = os.path.join(PREVIEW_DIR, "public", "index.html")
    print(f"Preview generated: {out}")

    if args.no_open:
        return

    opener = shutil.which("xdg-open") or shutil.which("firefox")
    if opener:
        subprocess.Popen([opener, out],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        print("No browser found. Open the file above manually.")


if __name__ == "__main__":
    main()
