"""spf_covers.py DOMAIN ADDR...: does DOMAIN's SPF record allow each ADDR?

Evaluates the mechanisms that can cover a server's own address: ip4, ip6, a,
mx, include and redirect (up to 10 lookups, as SPF itself allows). Prints one
line per address, "ADDR ok MECHANISM" or "ADDR missing", and exits 1 if any
address is not covered, 2 if the domain has no SPF record. Uses dig.
"""
import ipaddress
import subprocess
import sys

MAX_LOOKUPS = 10


def dig(name, rtype):
    out = subprocess.run(["dig", "+short", "+time=3", "+tries=2", name, rtype],
                         capture_output=True, text=True).stdout
    return [line.strip() for line in out.splitlines() if line.strip()]


def spf_record(domain):
    for line in dig(domain, "TXT"):
        # A TXT record may be split into several quoted strings: "a" "b".
        text = "".join(line.strip('"').split('" "'))
        if text.lower().startswith("v=spf1"):
            return text
    return None


def addresses(name):
    out = []
    for rtype in ("A", "AAAA"):
        for value in dig(name, rtype):
            try:
                out.append(ipaddress.ip_address(value))
            except ValueError:
                pass  # a CNAME line in +short output
    return out


def networks(domain, budget):
    """(network, mechanism) pairs DOMAIN's SPF allows; budget counts lookups."""
    record = spf_record(domain)
    if record is None:
        return None
    nets = []
    for term in record.split()[1:]:
        term = term.lstrip("+")
        if term[:1] in "-~?":
            continue  # fail/softfail/neutral mechanisms never allow
        key, _, value = term.partition(":")
        key = key.lower()
        if key.startswith("redirect="):
            key, value = "redirect", term.split("=", 1)[1]
        if key in ("ip4", "ip6"):
            nets.append((ipaddress.ip_network(value, strict=False), term))
        elif key in ("a", "mx", "include", "redirect"):
            budget[0] -= 1
            if budget[0] < 0:
                break
            target = value or domain
            if key == "a":
                nets += [(ipaddress.ip_network(a), term) for a in addresses(target)]
            elif key == "mx":
                for mx in dig(target, "MX"):
                    host = mx.split()[-1].rstrip(".")
                    nets += [(ipaddress.ip_network(a), f"{term} ({host})") for a in addresses(host)]
            else:
                sub = networks(target, budget)
                if sub:
                    nets += [(n, f"{term} > {m}") for n, m in sub]
    return nets


def main():
    domain, addrs = sys.argv[1], sys.argv[2:]
    nets = networks(domain, [MAX_LOOKUPS])
    if nets is None:
        print(f"{domain}: no SPF record")
        return 2
    status = 0
    for addr in addrs:
        ip = ipaddress.ip_address(addr)
        match = next((m for n, m in nets if n.version == ip.version and ip in n), None)
        if match:
            print(f"{addr} ok {match}")
        else:
            print(f"{addr} missing")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
