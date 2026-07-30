#!/usr/bin/env python3
"""Static checks for Get-VersionInventory.ps1.

There is no PowerShell in the development environment, so runtime errors are only
found by the user running the script. These checks catch the classes of mistake that
have actually shipped so far:

  1. A variable read at script scope that is never assigned there - the parameter was
     dropped from the param block but its use remained. Under Set-StrictMode this is a
     hard error on the first run ("The variable '$Title' cannot be retrieved").
  2. A loop variable whose name collides with a parameter. PowerShell variable names are
     case-insensitive, so `foreach ($product in ...)` silently overwrites `-Product`.
  3. Unbalanced braces/parens/brackets, and non-ASCII characters.

Usage: python3 tools/check-script.py [path-to-ps1]
"""

import re
import sys

AUTOMATIC = {
    'true', 'false', 'null', '_', 'psscriptroot', 'myinvocation', 'args', 'error',
    'matches', 'env', 'host', 'pwd', 'psitem', 'input', 'lastexitcode', 'psversiontable',
    'erroractionpreference', 'verbosepreference', 'script', 'this', 'pscmdlet',
    'psboundparameters', 'ofs', 'stacktrace', 'foreach', 'switch',
}


def strip_function_bodies(text):
    """Remove function bodies so only script-scope code remains."""
    out = []
    i = 0
    for match in re.finditer(r'^function\s+[\w-]+\s*\{', text, re.MULTILINE):
        out.append(text[i:match.start()])
        depth = 1
        j = match.end()
        while j < len(text) and depth:
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
            j += 1
        i = j
    out.append(text[i:])
    return ''.join(out)


def strip_noise(text):
    """Drop comments and here-strings, which are not code."""
    text = re.sub(r"@[\"']\r?\n.*?\r?\n[\"']@", '', text, flags=re.DOTALL)
    text = re.sub(r'<#.*?#>', '', text, flags=re.DOTALL)
    text = re.sub(r'^\s*#.*$', '', text, flags=re.MULTILINE)
    return text


def check(path):
    raw = open(path, newline='').read()
    problems = []

    # --- balance and encoding -------------------------------------------------
    for opener, closer in (('{', '}'), ('(', ')'), ('[', ']')):
        if raw.count(opener) != raw.count(closer):
            problems.append(
                "unbalanced %s%s: %d vs %d" % (opener, closer, raw.count(opener), raw.count(closer)))

    for lineno, line in enumerate(raw.splitlines(), 1):
        for ch in line:
            if ord(ch) > 126 or (ord(ch) < 32 and ch not in '\t'):
                problems.append("non-ASCII character %r on line %d" % (ch, lineno))
                break

    # --- parameters -----------------------------------------------------------
    param_match = re.search(r'^param\s*\((.*?)^\)', raw, re.MULTILINE | re.DOTALL)
    params = set()
    if param_match:
        params = {m.lower() for m in re.findall(r'\$(\w+)', param_match.group(1))}

    # --- script-scope variable use -------------------------------------------
    body = strip_noise(strip_function_bodies(raw))
    if param_match:
        body = body.replace(param_match.group(0), '')

    assigned = {m.lower() for m in re.findall(r'\$(\w+)\s*=', body)}
    assigned |= {m.lower() for m in re.findall(r'foreach\s*\(\s*\$(\w+)\s+in', body, re.IGNORECASE)}
    assigned |= {m.lower() for m in re.findall(r'\[\w+\]::TryParse\([^,]+,\s*\[ref\]\s*\$(\w+)', body)}

    known = params | assigned | AUTOMATIC

    for name in sorted({m.lower() for m in re.findall(r'\$(\w+)', body)}):
        if name not in known:
            problems.append(
                "$%s is read at script scope but never set there - "
                "is it a parameter that was dropped from the param block?" % name)

    # --- loop variables shadowing parameters ---------------------------------
    for name in re.findall(r'foreach\s*\(\s*\$(\w+)\s+in', raw, re.IGNORECASE):
        if name.lower() in params:
            problems.append(
                "foreach variable $%s has the same name as parameter -%s; PowerShell "
                "variable names are case-insensitive, so the parameter is overwritten" % (name, name))

    return problems


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else 'Get-VersionInventory.ps1'
    found = check(target)
    if found:
        print("FAIL: %s" % target)
        for item in found:
            print("  - %s" % item)
        sys.exit(1)
    print("OK: %s" % target)
