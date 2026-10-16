#!/usr/bin/env python3
"""Verify the actual exported app without writing certificate identities to logs."""
import argparse
import datetime
import fnmatch
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def run(arguments):
    result = subprocess.run(arguments, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{arguments[0]} verification failed (exit {result.returncode})')
    return result.stdout, result.stderr


def signed_entitlements(path):
    stdout, _ = run(['codesign', '-d', '--entitlements', ':-', str(path)])
    return plistlib.loads(stdout) if stdout.strip() else {}


def macho_files(app):
    paths = []
    for path in app.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as file:
            if file.read(4) in MACHO:
                paths.append(path)
    return sorted(paths)


def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    facts = json.loads((Path(__file__).resolve().parent.parent / 'release-facts.json').read_text())
    for key, expected in [('CFBundleIdentifier', facts['bundleIdentifier']), ('CFBundleShortVersionString', facts['version']), ('CFBundleVersion', facts['build']), ('LSMinimumSystemVersion', facts['minimumMacOS']), ('SUFeedURL', facts['feedURL']), ('SUPublicEDKey', facts['sparklePublicEDKey'])]:
        if info.get(key) != expected:
            raise RuntimeError(f'App does not match release fact: {key}')
    for key in ['SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling']:
        if info.get(key) is not False:
            raise RuntimeError(f'Update policy is not explicitly disabled: {key}')
    if info.get('LimareBuildChannel') != 'release':
        raise RuntimeError('App is not a release-channel build; development builds never take public updates')
    if info.get('SUVerifyUpdateBeforeExtraction') is not True:
        raise RuntimeError('EdDSA verification before extraction is not enabled')

    profile_path = app / 'Contents/embedded.provisionprofile'
    raw, _ = run(['security', 'cms', '-D', '-i', str(profile_path)])
    profile = plistlib.loads(raw)
    if profile.get('Platform') != ['OSX'] or profile.get('ExpirationDate', datetime.datetime.min) <= datetime.datetime.utcnow():
        raise RuntimeError('App distribution profile is expired or not for macOS')
    teams = profile.get('TeamIdentifier', [])
    if len(teams) != 1 or not profile.get('ProvisionsAllDevices') or profile.get('ProvisionedDevices'):
        raise RuntimeError('App profile is not a Developer ID distribution profile')
    authorized = profile['Entitlements']
    with tempfile.TemporaryDirectory(prefix='limare-certificate-verification-') as temporary:
        prefix = str(Path(temporary) / 'certificate')
        run(['codesign', '-d', '--extract-certificates=' + prefix, str(app)])
        leaf = Path(prefix + '0').read_bytes()
        if hashlib.sha256(leaf).digest() not in [hashlib.sha256(cert).digest() for cert in profile.get('DeveloperCertificates', [])]:
            raise RuntimeError('App signing certificate is not authorized by its profile')
    claimed = signed_entitlements(app)
    allowed_claims = {'com.apple.application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups', 'com.apple.security.get-task-allow', 'com.apple.security.device.audio-input'}
    if set(claimed) - allowed_claims:
        raise RuntimeError('App has entitlements outside the reviewed release contract')
    if claimed.get('com.apple.application-identifier') != authorized.get('com.apple.application-identifier'):
        raise RuntimeError('Application identifier is not authorized by the embedded profile')
    if claimed.get('com.apple.security.get-task-allow', False):
        raise RuntimeError('Release permits debugger attachment')
    groups = claimed.get('keychain-access-groups', [])
    if not groups or any(not any(fnmatch.fnmatchcase(group, pattern) for pattern in authorized.get('keychain-access-groups', [])) for group in groups):
        raise RuntimeError('Keychain groups are not authorized by the embedded profile')

    for required in ['Contents/Helpers/cua-driver', 'Contents/Helpers/cloudflared', 'Contents/Frameworks/Sparkle.framework']:
        if not (app / required).exists():
            raise RuntimeError(f'Missing required code: {required}')
    binaries = macho_files(app)
    nested = [p for p in app.rglob('*') if not p.is_symlink() and p.is_dir() and p.suffix in {'.app', '.xpc', '.framework'}]
    records = []
    for path in [*binaries, *nested, app]:
        run(['codesign', '--verify', '--strict', str(path)])
        _, details = run(['codesign', '-dvvv', str(path)])
        text = details.decode(errors='replace')
        checks = [bool(re.search(r'^Authority=Developer ID Application:', text, re.M)), bool(re.search(r'^Timestamp=', text, re.M)), bool(re.search(r'flags=.*runtime', text)), f'TeamIdentifier={teams[0]}\n' in text]
        if not all(checks):
            raise RuntimeError(f'Developer ID signing contract failed: {path.relative_to(app) if path != app else app.name}')
        records.append({'component': str(path.relative_to(app)) if path != app else '.', 'developer_id': True, 'same_team': True, 'timestamp': True, 'hardened_runtime': True, 'strict_verify': True})
    for path in binaries:
        architectures, _ = run(['lipo', '-archs', str(path)])
        if 'arm64' not in architectures.decode().split():
            raise RuntimeError('An executable lacks Apple Silicon support')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    architectures, _ = run(['lipo', '-archs', str(executable)])
    if architectures.decode().strip() != 'arm64':
        raise RuntimeError('The main release executable must be arm64 only')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    return {'release_facts_match': True, 'profile_authorizes_claims': True, 'components': records, 'main_architecture': 'arm64', 'scope': 'signed app; notarization, DMG, Gatekeeper, and runtime are separate checks'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.app.resolve()), indent=2))
