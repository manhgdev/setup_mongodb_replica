"""Ubuntu firewall (UFW) inspection and changes on the selected Linux host.

Runs on the target host (through SSH or locally) with root privileges.
"""
import ipaddress
import json
import re
import shutil
import socket
import subprocess
import sys
import urllib.request

IMDS = "http://169.254.169.254/opc/v2/instance/"


def emit(message):
    print(json.dumps({"event": message}), flush=True)


def run(args, timeout=30):
    return subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)


def norm_source(value):
    value = (value or "").strip()
    if value.lower() in {"", "any", "anywhere", "0.0.0.0/0", "::/0"}:
        return "any"
    return str(ipaddress.ip_network(value, strict=False))


def parse_range(text):
    text = str(text).strip().replace(":", "-")
    lo, _, hi = text.partition("-")
    lo, hi = int(lo), int(hi or lo)
    if not (1 <= lo <= hi <= 65535):
        raise ValueError("Port phải nằm trong 1-65535 và đầu dải không lớn hơn cuối dải.")
    return lo, hi


def app_ports(name):
    """Resolve a UFW application profile to (proto, lo, hi) tuples."""
    result = run(["ufw", "app", "info", name])
    out = []
    capture = False
    for line in result.stdout.splitlines():
        if re.match(r"^Ports?:", line):
            capture = True
            continue
        if capture and line.strip():
            line = line.strip()
            proto = line.rpartition("/")[2] if re.search(r"/(tcp|udp)$", line) else None
            for spec in line.split("/")[0].split(","):
                if re.fullmatch(r"[\d:]+", spec.strip()):
                    lo, hi = parse_range(spec)
                    out.append((proto, lo, hi))
    return out


def ufw_rules():
    result = run(["ufw", "status"])
    text = result.stdout
    state = {"installed": True, "active": bool(re.search(r"^Status:\s+active", text, re.M)), "rules": [], "error": ""}
    if result.returncode and not text:
        state["error"] = (result.stderr.strip().splitlines() or ["ufw lỗi"])[-1][:300]
        return state
    started = False
    for line in text.splitlines():
        if line.startswith("--"):
            started = True
            continue
        if not started or not line.strip() or "(v6)" in line:
            continue
        match = re.match(r"^(.+?)\s{2,}(ALLOW|DENY|REJECT|LIMIT)(?:\s+(IN|OUT|FWD))?\s+(.+?)\s*$", line.strip())
        if not match:
            continue
        target, action, direction, source = match.groups()
        if direction in {"OUT", "FWD"}:
            continue
        source = re.sub(r"\s*#.*$", "", source)
        try:
            src = norm_source(source if source != "Anywhere" else "any")
        except ValueError:
            src = source
        target = target.split()[-1] if " " in target.strip() and not target.strip().startswith("Anywhere") else target.strip()
        spec = re.fullmatch(r"([\d:]+(?:,[\d:]+)*)(?:/(tcp|udp))?", target)
        entries = []
        if spec:
            for part in spec.group(1).split(","):
                lo, hi = parse_range(part)
                entries.append((spec.group(2), lo, hi))
        elif target == "Anywhere":
            entries.append((None, 1, 65535))
        else:
            entries.extend(app_ports(target))
        for proto, lo, hi in entries:
            for p in ([proto] if proto else ["tcp", "udp"]):
                state["rules"].append({"proto": p, "min": lo, "max": hi, "source": src, "action": action.lower(), "raw": line.strip()[:160]})
    return state


def listening():
    result = run(["ss", "-H", "-lntup"])
    ports = {}
    for line in result.stdout.splitlines():
        cols = line.split()
        if len(cols) < 5:
            continue
        proto = "tcp" if cols[0].startswith("tcp") else "udp"
        local = cols[4]
        host, _, port = local.rpartition(":")
        if not port.isdigit():
            continue
        proc = re.search(r'\(\("([^"]+)"', line)
        item = ports.setdefault((proto, int(port)), {"proto": proto, "port": int(port), "addresses": [], "process": ""})
        item["addresses"].append(host.strip("[]"))
        if proc and not item["process"]:
            item["process"] = proc.group(1)
    rows = list(ports.values())
    for row in rows:
        row["local_only"] = all(a in {"127.0.0.1", "::1"} or a.startswith("127.") for a in row["addresses"])
        row["internal"] = None
        if row["proto"] == "tcp":
            target = "127.0.0.1" if row["local_only"] or "*" in row["addresses"] or "0.0.0.0" in row["addresses"] else row["addresses"][0]
            if target in {"::", "[::]"}:
                target = "::1"
            try:
                with socket.create_connection((target, row["port"]), 1.5):
                    row["internal"] = True
            except OSError:
                row["internal"] = False
    return sorted(rows, key=lambda r: (r["port"], r["proto"]))


def ssh_ports(hint):
    found = {int(p) for p in hint or [] if str(p).isdigit()}
    result = run(["ss", "-H", "-ltnp"])
    for line in result.stdout.splitlines():
        if '"sshd"' in line:
            port = line.split()[3].rpartition(":")[2]
            if port.isdigit():
                found.add(int(port))
    if shutil.which("sshd"):
        out = run(["sshd", "-T"]).stdout
        found.update(int(m) for m in re.findall(r"^port (\d+)$", out, re.M))
    return sorted(found or {22})


def oracle():
    try:
        req = urllib.request.Request(IMDS, headers={"Authorization": "Bearer Oracle"})
        with urllib.request.urlopen(req, timeout=2) as response:
            meta = json.load(response)
    except Exception:
        return {"detected": False}
    return {"detected": True, "instance_id": meta.get("id", ""), "display_name": meta.get("displayName", ""),
            "region": meta.get("canonicalRegionName") or meta.get("region", ""), "compartment_id": meta.get("compartmentId", ""),
            "shape": meta.get("shape", ""), "availability_domain": meta.get("availabilityDomain", ""),
            "tenancy_id": meta.get("tenantId", "")}


def _iptables_rule_args(proto, lo, hi, source):
    spec = str(lo) if lo == hi else f"{lo}:{hi}"
    args = ["-p", proto, "-m", proto, "--dport", spec]
    if source and source != "any" and ":" not in source:
        args += ["-s", source]
    args += ["-j", "ACCEPT"]
    return args


def _sync_iptables_port(op, proto, lo, hi, source, ufw_active):
    """Ensure Oracle/netfilter-persistent iptables INPUT rules do not block an opened port."""
    if not shutil.which("iptables"):
        return
    if source and source != "any" and ":" in source:
        return
    rules_out = run(["iptables", "-S", "INPUT"])
    if rules_out.returncode:
        return
    lines = [ln.strip() for ln in rules_out.stdout.splitlines() if ln.strip()]
    changed = False
    has_oracle_reject = any(" -j REJECT" in ln and "icmp-host-prohibited" in ln for ln in lines)
    if op == "open" and ufw_active and has_oracle_reject:
        emit("Xóa rule REJECT mặc định trên iptables INPUT để UFW có hiệu lực")
        while run(["iptables", "-D", "INPUT", "-j", "REJECT", "--reject-with", "icmp-host-prohibited"]).returncode == 0:
            changed = True
    elif not ufw_active:
        has_drop_or_reject = any(" -j REJECT" in ln or " -j DROP" in ln for ln in lines)
        rule = _iptables_rule_args(proto, lo, hi, source)
        if op == "open" and has_drop_or_reject:
            if run(["iptables", "-C", "INPUT", *rule]).returncode != 0:
                pos = next((idx for idx, ln in enumerate(lines[1:], start=1) if " -j REJECT" in ln or " -j DROP" in ln), 1)
                emit(f"iptables INSERT INPUT {pos} allow {proto}/{lo if lo == hi else f'{lo}-{hi}'}")
                if run(["iptables", "-I", "INPUT", str(pos), *rule]).returncode == 0:
                    changed = True
        elif op == "close":
            while run(["iptables", "-D", "INPUT", *rule]).returncode == 0:
                changed = True
    if changed and shutil.which("netfilter-persistent"):
        run(["netfilter-persistent", "save"])


def exists(rules, proto, lo, hi, source, action="allow"):
    return any(r["action"] == action and r["proto"] == proto and r["min"] == lo and r["max"] == hi and r["source"] == source for r in rules)


def change(p):
    state = ufw_rules()
    if not state["installed"] or not shutil.which("ufw"):
        raise ValueError("UFW chưa được cài trên VPS.")
    protected = ssh_ports(p.get("ssh_ports"))
    op = p["op"]
    if op == "enable":
        for port in protected:
            emit("UFW allow SSH " + str(port) + "/tcp")
            if not exists(state["rules"], "tcp", port, port, "any"):
                done = run(["ufw", "allow", str(port) + "/tcp"])
                if done.returncode:
                    raise ValueError("UFW · " + done.stderr.strip()[:300])
        emit("ufw enable")
        done = run(["ufw", "--force", "enable"], 60)
        if done.returncode:
            raise ValueError("UFW · " + done.stderr.strip()[:300])
        if run(["systemctl", "is-enabled", "--quiet", "netfilter-persistent"]).returncode == 0:
            emit("Tắt netfilter-persistent để tránh xung đột với UFW")
            run(["systemctl", "disable", "--now", "netfilter-persistent"])
        return {"results": [{"layer": "ufw", "status": "enabled", "detail": "UFW đã bật; SSH " + ", ".join(map(str, protected)) + "/tcp được giữ mở."}]}
    lo, hi = parse_range(p["port"])
    source = norm_source(p.get("source"))
    results = []
    for proto in p["protocols"]:
        if proto not in {"tcp", "udp"}:
            raise ValueError("Giao thức không hợp lệ.")
        label = f"{proto}/{lo if lo == hi else str(lo) + '-' + str(hi)} từ {source}"
        spec = str(lo) if lo == hi else f"{lo}:{hi}"
        base = ["proto", proto, "from", "any" if source == "any" else source, "to", "any", "port", spec]
        present = exists(state["rules"], proto, lo, hi, source)
        if op == "open":
            _sync_iptables_port("open", proto, lo, hi, source, state["active"])
            if present:
                results.append({"layer": "ufw", "proto": proto, "status": "exists", "detail": "UFW đã có rule " + label}); continue
            emit("ufw allow " + label)
            done = run(["ufw", "allow", *base])
            if done.returncode:
                raise ValueError("UFW · " + (done.stderr.strip() or done.stdout.strip())[:300])
            results.append({"layer": "ufw", "proto": proto, "status": "created", "detail": "Đã mở " + label + (" (UFW đang tắt, đã mở kèm iptables)" if not state["active"] else "")})
        else:
            if proto == "tcp" and any(lo <= port <= hi for port in protected):
                raise ValueError("Từ chối: dải port chứa cổng SSH " + ", ".join(map(str, protected)) + ".")
            _sync_iptables_port("close", proto, lo, hi, source, state["active"])
            if not present:
                results.append({"layer": "ufw", "proto": proto, "status": "missing", "detail": "UFW không có rule allow khớp chính xác " + label}); continue
            emit("ufw delete allow " + label)
            done = run(["ufw", "--force", "delete", "allow", *base])
            if done.returncode:
                raise ValueError("UFW · " + (done.stderr.strip() or done.stdout.strip())[:300])
            results.append({"layer": "ufw", "proto": proto, "status": "removed", "detail": "Đã đóng " + label})
    return {"results": results}


def execute(action, p):
    if action == "fw-info":
        return {"ssh_ports": ssh_ports(p.get("ssh_ports")), "oracle": oracle()}
    if action == "fw-status":
        state = ufw_rules() if shutil.which("ufw") else {"installed": False, "active": False, "rules": [], "error": ""}
        return {"ufw": state, "listening": listening(), "ssh_ports": ssh_ports(p.get("ssh_ports")), "oracle": oracle()}
    if action == "fw-ufw":
        return change(p)
    raise ValueError("Thao tác firewall không hợp lệ.")


def serve(request):
    try:
        print(json.dumps({"result": execute(request["action"], request["params"])}), flush=True)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    serve(json.load(sys.stdin))
