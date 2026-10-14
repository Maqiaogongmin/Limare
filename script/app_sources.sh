#!/usr/bin/env bash
# Prints the app's Swift sources, one per line: everything the Limare target compiles except
# the @main entry point. Test runners compile these together with their own test file, so a new
# file or folder in the app never needs to be added to each runner by hand.
set -euo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
find "$root/src/macos/Limare" -name '*.swift' ! -name 'LimareApp.swift' -type f | sort
