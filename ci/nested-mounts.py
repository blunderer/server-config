"""Inspect rendered Quadlet .container units; fail if any mount sits inside a read-only mount."""
import glob
import os
import sys

svc_dir = sys.argv[1]
qdir = sys.argv[2]
found = False

for path in sorted(glob.glob(os.path.join(qdir, "*.container"))):
    name = os.path.basename(path)[:-len(".container")]
    mounts = []
    with open(path, encoding="utf-8") as fh:
        for raw_ln in fh:
            ln = raw_ln.strip()
            if not ln or ln.startswith(("#", ";")) or "=" not in ln:
                continue
            key, val = ln.split("=", 1)
            key = key.strip()
            val = val.strip()
            if key == "Volume":
                parts = val.split(":", 2)
                if len(parts) < 2:
                    continue
                target = parts[1]
                opts = parts[2].split(",") if len(parts) == 3 else []
                mounts.append((target, "ro" in opts))
            elif key == "Secret":
                opts = val.split(",")[1:]
                kv = dict(o.split("=", 1) for o in opts if "=" in o)
                if kv.get("type") == "mount" and kv.get("target"):
                    mounts.append((kv["target"], True))

    for target, _ in mounts:
        for p_target, p_ro in mounts:
            if not p_ro:
                continue
            if target.startswith(p_target.rstrip("/") + "/"):
                print(f"{svc_dir}/{name}: {target} is inside the read-only mount {p_target}")
                found = True

sys.exit(1 if found else 0)
