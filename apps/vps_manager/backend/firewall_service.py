"""Combine UFW and Oracle Cloud firewall layers into one view and one operation."""
import ipaddress
import socket
import time
from concurrent.futures import ThreadPoolExecutor

from . import oci_firewall as oci

ANY = {"any", "0.0.0.0/0", "::/0"}
_cache = {}


def parse_range(text):
    text = str(text).strip().replace(":", "-")
    lo, _, hi = text.partition("-")
    try:
        lo, hi = int(lo), int(hi or lo)
    except ValueError:
        raise ValueError("Port không hợp lệ. Dùng 443 hoặc 8000-8100.") from None
    if not (1 <= lo <= hi <= 65535):
        raise ValueError("Port phải nằm trong 1-65535 và đầu dải không lớn hơn cuối dải.")
    return lo, hi


def parse_source(text):
    text = (text or "").strip()
    if text.lower() in {"", "any", "anywhere"}:
        return "0.0.0.0/0"
    try:
        return str(ipaddress.ip_network(text, strict=False))
    except ValueError:
        raise ValueError("Source CIDR không hợp lệ, ví dụ 0.0.0.0/0 hoặc 203.0.113.0/24.") from None


def coverage(rules, proto, lo, hi):
    """open | restricted | denied | closed for one proto/range."""
    cover = [r for r in rules if r["proto"] in {proto, "all"} and r["min"] is not None and r["min"] <= lo and r["max"] >= hi]
    allows = [r for r in cover if r.get("action", "allow") in {"allow", "limit"}]
    if any(r["source"] in ANY for r in allows):
        return "open"
    if allows:
        return "restricted"
    return "denied" if cover else "closed"


def probe_tcp(host, port):
    try:
        with socket.create_connection((host, port), 0.8):
            return "open"
    except OSError:
        return "closed"


def build_rows(ufw, listening, oci_rules, host, probe=probe_tcp):
    keys = {}

    def row(proto, lo, hi):
        return keys.setdefault((proto, lo, hi), {"proto": proto, "min": lo, "max": hi, "listening": [], "internal": None})

    for item in listening:
        row(item["proto"], item["port"], item["port"])
    ufw_rules = [r for r in ufw["rules"] if r["proto"] in {"tcp", "udp"}] if ufw.get("installed") else []
    for r in ufw_rules:
        if r["action"] == "allow" and (r["min"], r["max"]) != (1, 65535):
            row(r["proto"], r["min"], r["max"])
    for r in oci_rules or []:
        if r["proto"] in {"tcp", "udp"} and (r["min"], r["max"]) != (1, 65535):
            row(r["proto"], r["min"], r["max"])
    rows = sorted(keys.values(), key=lambda r: (r["min"], r["max"], r["proto"]))
    for r in rows:
        inside = [i for i in listening if i["proto"] == r["proto"] and r["min"] <= i["port"] <= r["max"]]
        r["listening"] = [{"port": i["port"], "process": i["process"], "local_only": i["local_only"]} for i in inside]
        checks = [i["internal"] for i in inside if i["internal"] is not None]
        r["internal"] = (any(checks) if checks else None)
        r["ufw"] = ("inactive" if not ufw.get("active") else coverage(ufw_rules, r["proto"], r["min"], r["max"])) if ufw.get("installed") else None
        r["oci"] = coverage(oci_rules, r["proto"], r["min"], r["max"]) if oci_rules is not None else None
        r["external"] = None
        r["warnings"] = []
    local = host in {"", "localhost", "127.0.0.1", "::1"}
    targets = [r for r in rows if r["proto"] == "tcp" and r["min"] == r["max"] and r["listening"] and not local]
    if targets:
        with ThreadPoolExecutor(max_workers=min(16, len(targets))) as pool:
            for r, state in zip(targets[:60], pool.map(lambda r: probe(host, r["min"]), targets[:60])):
                r["external"] = state
    for r in rows:
        ufw_open = r["ufw"] in {"open", "restricted"}
        if ufw_open and r["oci"] in {"closed", "denied"}:
            r["warnings"].append("oci_blocked")
        if r["ufw"] in {"closed", "denied"} and r["oci"] == "open" and r["listening"]:
            r["warnings"].append("ufw_blocked")
        if r["listening"] and all(i["local_only"] for i in r["listening"]):
            r["warnings"].append("local_only")
        elif r["external"] == "closed" and r["internal"] and r["ufw"] in {"open", "inactive", None} and r["oci"] in {"open", None}:
            r["warnings"].append("blocked_elsewhere")
    return rows


def link_for(store, ident):
    try:
        link = store.get("oci-links", ident)
        return link, store.get("oci-accounts", link["account_id"])
    except KeyError:
        return None, None


def cached_inspect(account, region, instance_id, fresh=False):
    key = (account["id"], region, instance_id)
    hit = _cache.get(key)
    if hit and not fresh and time.time() - hit[0] < 20:
        return hit[1]
    data = oci.inspect(account, region, instance_id)
    _cache[key] = (time.time(), data)
    return data


def status(machine, store, ident, call):
    hint = [machine["port"]] if machine.get("mode") == "ssh" else []
    data = call("fw-status", {"ssh_ports": hint})
    link, account = link_for(store, ident)
    result = dict(data, accounts=[oci.public_account(a) for a in store.all("oci-accounts")], link=None, oci=None, oci_error="")
    if link and account:
        result["link"] = {"account_id": account["id"], "account": account["name"], "region": link.get("region", "")}
        if data["oracle"].get("detected"):
            try:
                region = link.get("region") or data["oracle"]["region"]
                result["oci"] = cached_inspect(account, region, data["oracle"]["instance_id"])
            except oci.OciError as exc:
                result["oci_error"] = str(exc)
    oci_rules = oci.all_rules(result["oci"]["vnics"][0]) if result["oci"] else None
    result["rows"] = build_rows(data["ufw"], data["listening"], oci_rules, machine.get("host") if machine.get("mode") == "ssh" else "")
    result["oracle_detected"] = data["oracle"].get("detected", False)
    return result


def run_change(machine, store, ident, params, call, emit):
    op, layers = params["op"], set(params["layers"])
    if not layers:
        raise ValueError("Chọn ít nhất một lớp firewall.")
    hint = [machine["port"]] if machine.get("mode") == "ssh" else []
    info = call("fw-info", {"ssh_ports": hint})
    if op == "enable":
        return call("fw-ufw", {"op": "enable", "ssh_ports": info["ssh_ports"]})
    lo, hi = parse_range(params["port"])
    source = parse_source(params["source"])
    protocols = [p for p in ("tcp", "udp") if p in params["protocols"]]
    if not protocols:
        raise ValueError("Chọn TCP hoặc UDP.")
    if op == "close" and "tcp" in protocols and any(lo <= p <= hi for p in info["ssh_ports"]):
        raise ValueError("Từ chối: dải port chứa cổng SSH " + ", ".join(map(str, info["ssh_ports"])) + ".")
    account = region = vnic = None
    if "oci" in layers:
        link, account = link_for(store, ident)
        if not info["oracle"].get("detected"):
            raise ValueError("VPS này không phải Oracle Cloud. Bỏ chọn lớp Oracle Cloud.")
        if not link or not account:
            raise ValueError("Chưa liên kết tài khoản Oracle Cloud cho VPS này. Mở Cấu hình Oracle Cloud.")
        region = link.get("region") or info["oracle"]["region"]
        emit("Oracle Cloud · đọc Instance, VNIC, Subnet, Security List, NSG")
        vnic = cached_inspect(account, region, info["oracle"]["instance_id"], True)["vnics"][0]
    results, failures = [], []
    if "ufw" in layers:
        try:
            results += call("fw-ufw", {"op": op, "port": params["port"], "protocols": protocols, "source": source if source != "0.0.0.0/0" else "any",
                                       "ssh_ports": info["ssh_ports"]})["results"]
        except (ValueError, RuntimeError) as exc:
            failures.append(str(exc))
    if "oci" in layers:
        action = oci.add_rule if op == "open" else oci.remove_rule
        for proto in protocols:
            try:
                emit("Oracle Cloud · " + op + " " + proto + "/" + params["port"])
                results.append(action(account, region, vnic, params.get("oci_target", "auto"), proto, lo, hi, source))
            except oci.OciError as exc:
                failures.append(str(exc))
        _cache.pop((account["id"], region, info["oracle"]["instance_id"]), None)
    for item in results:
        emit(item["detail"])
    if failures:
        raise RuntimeError("; ".join(failures) + (" · Đã hoàn tất: " + " | ".join(i["detail"] for i in results) if results else ""))
    return {"results": results}
