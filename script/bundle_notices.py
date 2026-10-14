#!/usr/bin/env python3
"""Write the license notices of everything Limare ships into the app bundle.

Runs as an Xcode build phase. The output is Contents/Resources/Credits.html, which the
standard About panel (Limare > About Limare) shows. Every component must bring its own
license text; the build fails when one is missing, so a new dependency cannot ship
without its notice.

Components, in order:
  - Limare itself: LICENSE
  - vendored packages: deps/<name>/LICENSE*, NOTICE*, COPYING*
  - Swift packages pinned in Package.resolved: the same files in their SPM checkout
  - LICENSES/<source>-*.txt: texts of adapted code, or a package's license kept here when
    its checkout has none (attached to the pin whose identity is <source>)
  - bundled helpers: dist/<NAME>_LICENSE.txt, written by their packaging scripts
  - Remote Access web vendor files: src/macos/RemoteWeb/vendor/<name>.LICENSE
"""

import argparse
import hashlib
import html
import json
import re
import sys
from pathlib import Path

LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|notices?)([.-].*)?$", re.IGNORECASE)
RESOLVED = "src/macos/Limare.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def fail(message):
    print(f"error: bundle_notices: {message}", file=sys.stderr)
    sys.exit(1)


def license_files(directory):
    return sorted(p for p in directory.iterdir() if p.is_file() and LICENSE_FILE.match(p.name))


def read(path):
    return path.read_text(encoding="utf-8", errors="replace").strip()


def find_checkouts(build_dir):
    for parent in [build_dir, *build_dir.parents]:
        candidate = parent / "SourcePackages" / "checkouts"
        if candidate.is_dir():
            return candidate
    fail(f"no SourcePackages/checkouts above {build_dir}")


def collect(root, checkouts):
    components = []  # (name, version, [(file label, text)])

    def add(name, version, files):
        if not files:
            fail(f"{name} has no license file")
        components.append((name, version, [(f.name, read(f)) for f in files]))

    add("Limare", "", [root / "LICENSE"])

    for package in sorted(p for p in (root / "deps").iterdir() if (p / "Package.swift").is_file()):
        add(package.name, "", license_files(package))

    overrides = {}
    for f in sorted((root / "LICENSES").glob("*.txt")):
        overrides.setdefault(f.name.split("-", 1)[0].lower(), []).append(f)

    try:
        pins = json.loads((root / RESOLVED).read_text())["pins"]
    except (OSError, KeyError, ValueError) as error:
        fail(f"cannot read {RESOLVED}: {error}")
    checkout_dirs = {p.name.lower(): p for p in checkouts.iterdir() if p.is_dir()}
    for pin in sorted(pins, key=lambda p: p["identity"]):
        identity = pin["identity"]
        checkout = checkout_dirs.get(identity)
        if checkout is None:
            fail(f"no checkout for {identity} in {checkouts}")
        state = pin.get("state", {})
        version = state.get("version") or state.get("revision", "")[:7]
        add(checkout.name, version, license_files(checkout) + overrides.pop(identity, []))

    for files in overrides.values():
        add(files[0].name.split("-", 1)[0], "adapted source", files)

    for f in sorted((root / "dist").glob("*_LICENSE.txt")):
        add(f.name[: -len("_LICENSE.txt")].lower().replace("_", "-"), "bundled helper", [f])

    for f in sorted((root / "src/macos/RemoteWeb/vendor").glob("*.LICENSE")):
        add(f.stem, "Remote Access web page", [f])

    return components


def render(components):
    # Identical texts (most Apache-2.0 LICENSE files) are printed once under every
    # component that carries them; NOTICE files differ and stay per component.
    groups = {}
    for name, version, files in components:
        label = f"{name} {version}".strip()
        for file_name, text in files:
            key = hashlib.sha256(text.encode()).hexdigest()
            groups.setdefault(key, (text, []))[1].append(f"{label} ({file_name})")

    parts = [
        "<html><head><meta charset='utf-8'><style>",
        "body{font:11px -apple-system,sans-serif} pre{font:10px Menlo,monospace;white-space:pre-wrap}",
        "</style></head><body>",
        "<p>Limare is free software under the GNU General Public License v3.0. It started as a fork "
        "of OpenMinis (GPL-3.0) and includes the third-party software listed below.</p>",
    ]
    for text, users in groups.values():
        parts.append("<h4>" + "<br>".join(html.escape(u) for u in users) + "</h4>")
        parts.append("<pre>" + html.escape(text) + "</pre>")
    parts.append("</body></html>")
    return "\n".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    components = collect(args.root.resolve(), find_checkouts(args.build_dir.resolve()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(components), encoding="utf-8")
    print(f"bundle_notices: {len(components)} components -> {args.output}")


if __name__ == "__main__":
    main()
