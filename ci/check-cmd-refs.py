#!/usr/bin/env python3
"""Static check that every cmd/srv/*.sh and cmd/box/*.sh file:
1. Defines its expected cmd_<name>() entrypoint (or declares it from lib/*.sh).
2. Does not call functions defined in another cmd/*.sh file without loading it.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEF_RE = re.compile(r"^[ \t]*([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{", re.M)
LOAD_RE = re.compile(r"\b(?:load_cmd|run_cmd)\s+([a-z0-9-]+)")
SOURCE_LIB_RE = re.compile(r"\.\s+\"?\$(?:REPO|SRV_ROOT)/lib/([a-zA-Z0-9_.-]+\.sh)\"?")
LOAD_LIB_RE = re.compile(r"\bload_lib\s+([a-zA-Z0-9_-]+)")


def get_defs(path: str) -> set[str]:
    with open(path, encoding="utf-8") as fh:
        return set(DEF_RE.findall(fh.read()))


def check_tool(main_script: str, cmd_dir: str, eager_libs: list[str]) -> int:
    issues = 0
    core_defs = get_defs(os.path.join(ROOT, main_script))
    for lib in eager_libs:
        core_defs |= get_defs(os.path.join(ROOT, lib))

    cmd_paths = sorted(glob.glob(os.path.join(ROOT, cmd_dir, "*.sh")))
    cmd_defs: dict[str, set[str]] = {}
    fn_owner: dict[str, str] = {}
    for path in cmd_paths:
        fname = os.path.basename(path)
        defs = get_defs(path)
        cmd_defs[fname] = defs
        for fn in defs:
            fn_owner[fn] = fname

    for path in cmd_paths:
        fname = os.path.basename(path)
        cmd_name = fname[:-3]
        expected_fn = f"cmd_{cmd_name.replace('-', '_')}"
        with open(path, encoding="utf-8") as fh:
            text = fh.read()

        # Check entrypoint exists (either defined here, in sourced/lazy-loaded lib, or declared)
        sourced_libs = SOURCE_LIB_RE.findall(text) + [f"{m}.sh" for m in LOAD_LIB_RE.findall(text)]
        local_defs = set(cmd_defs[fname])
        for lib in sourced_libs:
            libp = os.path.join(ROOT, "lib", lib)
            if os.path.isfile(libp):
                local_defs |= get_defs(libp)
        if expected_fn not in local_defs and f"declare -F {expected_fn}" not in text:
            print(f"ERROR: {cmd_dir}/{fname}: missing entrypoint {expected_fn}()", file=sys.stderr)
            issues += 1

        # Check cross-file cmd/* calls
        loaded = {c + ".sh" for c in LOAD_RE.findall(text)} | {fname}
        for fn, owner in fn_owner.items():
            if owner in loaded or fn in core_defs:
                continue
            pat = re.compile(rf"(?<![a-zA-Z0-9_-]){re.escape(fn)}(?![a-zA-Z0-9_-])")
            for lineno, line in enumerate(text.splitlines(), 1):
                code = line.split("#", 1)[0]
                if pat.search(code):
                    print(
                        f"ERROR: {cmd_dir}/{fname}:{lineno} calls '{fn}' "
                        f"(defined in {cmd_dir}/{owner}, not loaded)",
                        file=sys.stderr,
                    )
                    issues += 1

    # Ensure main_script and eager_libs don't call non-cmd helpers moved into cmd/*
    for sp in [main_script] + eager_libs:
        with open(os.path.join(ROOT, sp), encoding="utf-8") as fh:
            text = fh.read()
        for fn, owner in fn_owner.items():
            if fn.startswith("cmd_") or fn in core_defs:
                continue
            pat = re.compile(rf"(?<![a-zA-Z0-9_-]){re.escape(fn)}(?![a-zA-Z0-9_-])")
            for lineno, line in enumerate(text.splitlines(), 1):
                code = line.split("#", 1)[0]
                if pat.search(code):
                    print(
                        f"ERROR: {sp}:{lineno} calls '{fn}' (defined in {cmd_dir}/{owner})",
                        file=sys.stderr,
                    )
                    issues += 1
    return issues


def main() -> int:
    # Discover eagerly sourced libs in srv and box
    def eager_libs(script: str) -> list[str]:
        with open(os.path.join(ROOT, script), encoding="utf-8") as fh:
            return [os.path.join("lib", m) for m in SOURCE_LIB_RE.findall(fh.read())]

    total = 0
    total += check_tool("srv", "cmd/srv", eager_libs("srv"))
    total += check_tool("box", "cmd/box", eager_libs("box"))
    # Top-level `declare -A/-a` in sourced files becomes function-local when
    # loaded inside load_lib()/load_cmd(); require -g.
    for pat in ("lib/*.sh", "cmd/srv/*.sh", "cmd/box/*.sh"):
        for path in sorted(glob.glob(os.path.join(ROOT, pat))):
            with open(path, encoding="utf-8") as fh:
                for lineno, line in enumerate(fh, 1):
                    if re.match(r"^declare\s+-[aA]\b", line):
                        rel = os.path.relpath(path, ROOT)
                        print(f"ERROR: {rel}:{lineno}: top-level 'declare -A/-a' must use -g (sourced inside a function)", file=sys.stderr)
                        total += 1
    if total:
        print(f"check-cmd-refs: {total} error(s) found", file=sys.stderr)
        return 1
    print("cmd/srv and cmd/box cross-references ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
