#!/usr/bin/env python3
"""Normalize Developer ID signing of all nested code, inner to outer.

Run only on the Developer ID exported candidate from the clean source clone.
Never use this script to turn a development app into a public release.
"""
import argparse
import os
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from verify_release_bundle import macho_files, run, signed_entitlements, verify


def sign(app):
    main_claims = signed_entitlements(app)
    raw, _ = run(['security', 'cms', '-D', '-i', str(app / 'Contents/embedded.provisionprofile')])
    profile = plistlib.loads(raw)
    teams = profile.get('TeamIdentifier', [])
    _, signature = run(['codesign', '-dvvv', str(app)])
    if len(teams) != 1 or b'Authority=Developer ID Application:' not in signature or main_claims.get('com.apple.application-identifier') != profile['Entitlements'].get('com.apple.application-identifier'):
        raise RuntimeError('Input must already be a Developer ID export with matching distribution profile')
    identities, _ = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
    matches = re.findall(rb'\b([0-9A-F]{40})\s+"Developer ID Application:', identities)
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one valid local Developer ID Application identity')
    identity = matches[0].decode()
    env = dict(os.environ, CONFIGURATION='Release', DEVELOPMENT_TEAM=teams[0], CODE_SIGN_IDENTITY=identity, EXPANDED_CODE_SIGN_IDENTITY=identity, CODE_SIGNING_ALLOWED='YES')
    helper_signer = Path(__file__).parent / 'sign_helper.sh'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    main_binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    for path in macho_files(app):
        if path == main_binary:
            continue
        result = subprocess.run([str(helper_signer), str(path)], env=env, capture_output=True)
        if result.returncode:
            raise RuntimeError(f'Nested executable signing failed: {path.relative_to(app)}')
    bundles = [p for p in app.rglob('*') if not p.is_symlink() and p.is_dir() and p.suffix in {'.app', '.xpc', '.framework'}]
    for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        result = subprocess.run([str(helper_signer), str(path)], env=env, capture_output=True)
        if result.returncode:
            raise RuntimeError(f'Nested bundle signing failed: {path.relative_to(app)}')
    with tempfile.TemporaryDirectory(prefix='limare-signing-entitlements-') as temporary:
        entitlements = Path(temporary) / 'release.plist'
        entitlements.write_bytes(plistlib.dumps(main_claims))
        run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', '--entitlements', str(entitlements), str(app)])
    return verify(app)


if __name__ == '__main__':
    import json
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    print(json.dumps(sign(args.app.resolve()), indent=2))
