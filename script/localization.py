#!/usr/bin/env python3
"""Keeps Limare's translations in one String Catalog and checks they are complete.

    script/localization.py sync-app --derived-data <dir>   add strings the compiler extracted
    script/localization.py sync-web                        add the phone page's strings
    script/localization.py check                           fail on anything untranslated

Limare's text lives in src/macos/Limare/Localizable.xcstrings: English source text as keys,
one column per language. Xcode adds the strings it extracts from Swift when it builds; from the
command line `sync-app` does the same from a build's .stringsdata files. The phone page
(src/macos/RemoteWeb) marks its text with t('…'); `sync-web` lists those keys in
RemoteWeb/strings.json, which the Mac uses to send the page its translations, and adds them to
the catalog. Adding a language means adding it to the catalog (and the project's known regions);
`check` then lists every string that still needs it.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'src/macos/Limare')
CATALOG = os.path.join(APP, 'Localizable.xcstrings')
INFO_CATALOG = os.path.join(APP, 'InfoPlist.xcstrings')
WEB = os.path.join(ROOT, 'src/macos/RemoteWeb')
WEB_KEYS = os.path.join(WEB, 'strings.json')
PROJECT = os.path.join(ROOT, 'src/macos/Limare.xcodeproj/project.pbxproj')

# t('…') or t("…") with a literal first argument, and {{t:…}} in index.html.
JS_CALL = re.compile(r"""\bt\(\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")""")
HTML_KEY = re.compile(r'\{\{t:(.+?)\}\}')


def load(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def save(path, catalog):
    # The layout Xcode writes, so its own edits leave small diffs.
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(',', ' : '), sort_keys=True)
        f.write('\n')


def unescape_js(text):
    return re.sub(r"\\(.)", lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), text)


def web_keys():
    keys = set()
    for path in glob.glob(os.path.join(WEB, 'js/**/*.js'), recursive=True):
        if os.sep + 'vendor' + os.sep in path:
            continue
        for single, double in JS_CALL.findall(open(path, encoding='utf-8').read()):
            keys.add(unescape_js(single or double))
    keys.update(HTML_KEY.findall(open(os.path.join(WEB, 'index.html'), encoding='utf-8').read()))
    return sorted(keys)


def languages(catalog):
    """Every language the project knows, other than the source language."""
    project = open(PROJECT, encoding='utf-8').read()
    regions = re.search(r'knownRegions = \((.*?)\);', project, re.S).group(1)
    known = {r.strip().strip('"') for r in regions.split(',') if r.strip()}
    return sorted(known - {'Base', catalog['sourceLanguage']})


def is_translated(localization):
    if 'stringUnit' in localization:
        return localization['stringUnit'].get('state') == 'translated'
    variations = localization.get('variations', {})
    return bool(variations) and all(is_translated(v) for group in variations.values() for v in group.values())


def missing_translations(catalog, langs):
    missing = []
    for key, entry in catalog['strings'].items():
        if entry.get('shouldTranslate') is False or entry.get('extractionState') == 'stale':
            continue
        for lang in langs:
            if not is_translated(entry.get('localizations', {}).get(lang, {})):
                missing.append((lang, key))
    return missing


def sync_app(args):
    files = glob.glob(os.path.join(args.derived_data, 'Build/Intermediates.noindex/Limare.build/*/Limare.build/Objects-normal/*/*.stringsdata'))
    if not files:
        sys.exit(f'no .stringsdata under {args.derived_data}; build the Limare scheme with SWIFT_EMIT_LOC_STRINGS first')
    subprocess.run(['xcrun', 'xcstringstool', 'sync', CATALOG, '--stringsdata', *files], check=True)
    save(CATALOG, load(CATALOG))
    print(f'synced {len(files)} .stringsdata files into {os.path.relpath(CATALOG, ROOT)}')


def sync_web(_):
    keys = web_keys()
    with open(WEB_KEYS, 'w', encoding='utf-8') as f:
        json.dump(keys, f, ensure_ascii=False, indent=2)
        f.write('\n')
    catalog = load(CATALOG)
    added = [k for k in keys if k not in catalog['strings']]
    for key in added:
        catalog['strings'][key] = {'comment': 'Remote Access page (RemoteWeb)', 'extractionState': 'manual'}
    save(CATALOG, catalog)
    print(f'{len(keys)} page strings; {len(added)} added to the catalog')


def check(_):
    problems = []
    if not os.path.exists(WEB_KEYS) or load(WEB_KEYS) != web_keys():
        problems.append('RemoteWeb/strings.json is out of date: run script/localization.py sync-web')
    for path in (CATALOG, INFO_CATALOG):
        catalog = load(path)
        if path == CATALOG:
            absent = [k for k in web_keys() if k not in catalog['strings']]
            problems += [f'page string not in the catalog: {k!r}' for k in absent]
        problems += [f'{os.path.basename(path)}: no {lang} translation for {key!r}'
                     for lang, key in missing_translations(catalog, languages(catalog))]
    for problem in problems:
        print(problem)
    print('localization check:', 'FAIL' if problems else 'PASS', f'({len(problems)} problems)')
    sys.exit(1 if problems else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    app = commands.add_parser('sync-app', help='add strings extracted by a build')
    app.add_argument('--derived-data', required=True)
    app.set_defaults(run=sync_app)
    commands.add_parser('sync-web', help="add the phone page's strings").set_defaults(run=sync_web)
    commands.add_parser('check', help='fail on anything untranslated').set_defaults(run=check)
    args = parser.parse_args()
    args.run(args)


if __name__ == '__main__':
    main()
