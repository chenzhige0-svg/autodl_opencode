#!/usr/bin/env python3
"""oc_config.py - JSON / JSONC helpers for the opencode-autodl toolkit.

Only the Python standard library is used. Commands:

  validate <file>                    exit 0 if parseable, else print reason
  normalize <in> <out>               strip comments/trailing commas -> strict JSON
  get <file> <dotted.key>            print the value at a dotted path
  set <file> <dotted.key> <value>    set a nested key in place (atomic)
  merge <base> <override> <out>      deep merge; override wins on conflict
  keys <file>                        print top-level keys, one per line

JSONC (comments + trailing commas) is accepted everywhere. Writing always
produces strict JSON, because the target config consumers expect it.
"""

import json
import os
import re
import sys
import tempfile


def strip_jsonc(text: str) -> str:
    """Remove // and /* */ comments plus trailing commas, preserving strings."""
    out = []
    i, n = 0, len(text)
    in_str = False
    str_ch = ""
    escaped = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_str:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == str_ch:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = True
            str_ch = ch
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    stripped = "".join(out)
    # remove trailing commas before } or ]
    stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
    return stripped


def load(path: str):
    with open(path, "r", encoding="utf-8-sig") as fh:
        raw = fh.read()
    try:
        return json.loads(raw), False
    except json.JSONDecodeError:
        return json.loads(strip_jsonc(raw)), True


def atomic_dump(obj, path: str) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".oc-cfg.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def deep_merge(base, override):
    if isinstance(base, dict) and isinstance(override, dict):
        result = dict(base)
        for key, val in override.items():
            if key in result:
                result[key] = deep_merge(result[key], val)
            else:
                result[key] = val
        return result
    return override


def dotted_get(obj, dotted: str):
    cur = obj
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            raise KeyError(dotted)
    return cur


def dotted_set(obj, dotted: str, value):
    parts = dotted.split(".")
    cur = obj
    for part in parts[:-1]:
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    cur[parts[-1]] = value


def cmd_validate(args):
    path = args[0]
    try:
        load(path)
    except FileNotFoundError:
        print("file not found")
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}")
        return 1
    print("valid")
    return 0


def cmd_normalize(args):
    src, dst = args[0], args[1]
    obj, _ = load(src)
    atomic_dump(obj, dst)
    return 0


def cmd_get(args):
    obj, _ = load(args[0])
    try:
        val = dotted_get(obj, args[1])
    except KeyError:
        return 1
    if isinstance(val, (dict, list)):
        print(json.dumps(val, ensure_ascii=False))
    else:
        print(val)
    return 0


def cmd_set(args):
    path, dotted, value = args[0], args[1], args[2]
    as_json = "--json" in args[3:]
    if os.path.exists(path):
        obj, _ = load(path)
    else:
        obj = {}
    try:
        newval = json.loads(value)
    except json.JSONDecodeError:
        newval = value if not as_json else value
    dotted_set(obj, dotted, newval)
    atomic_dump(obj, path)
    return 0


def cmd_merge(args):
    base_path, override_path, out = args[0], args[1], args[2]
    base, _ = load(base_path) if os.path.exists(base_path) else ({}, False)
    override, _ = load(override_path) if os.path.exists(override_path) else ({}, False)
    merged = deep_merge(base, override)
    atomic_dump(merged, out)
    return 0


def cmd_keys(args):
    obj, _ = load(args[0])
    if isinstance(obj, dict):
        for key in obj:
            print(key)
    return 0


COMMANDS = {
    "validate": cmd_validate,
    "normalize": cmd_normalize,
    "get": cmd_get,
    "set": cmd_set,
    "merge": cmd_merge,
    "keys": cmd_keys,
}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    handler = COMMANDS.get(cmd)
    if handler is None:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    try:
        return handler(argv[2:])
    except IndexError:
        print(f"missing arguments for '{cmd}'", file=sys.stderr)
        return 2
    except FileNotFoundError as exc:
        print(f"file not found: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
