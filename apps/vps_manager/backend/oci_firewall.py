"""Oracle Cloud (OCI) network firewall access through the OCI Python SDK.

Runs on the Manager host. Secrets (API private key, passphrase) are only passed to the
SDK in memory and never appear in logs, errors or API responses.
"""
import hashlib
import ipaddress
import re

OCID = re.compile(r"^ocid1\.[a-z0-9_.-]+$")
REGION = re.compile(r"^[a-z]{2,}-[a-z0-9-]+-\d+$")
PROTO = {"6": "tcp", "17": "udp", "1": "icmp", "all": "all"}
TAG = "ZM VPS Manager"


class OciError(RuntimeError):
    pass


def sdk():
    try:
        import oci
    except ImportError:
        raise OciError("Chưa cài OCI SDK trên máy chạy Manager. Chạy: pip install oci") from None
    return oci


def key_fingerprint(pem, passphrase=""):
    from cryptography.hazmat.primitives import serialization
    try:
        key = serialization.load_pem_private_key(pem.encode(), passphrase.encode() or None)
    except Exception:
        raise OciError("Private key không đọc được (sai định dạng PEM hoặc sai passphrase).") from None
    der = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    digest = hashlib.md5(der).hexdigest()  # noqa: S324 - OCI defines API-key fingerprints as MD5
    return ":".join(digest[i:i + 2] for i in range(0, 32, 2))


def validate_account(values):
    """Validate an account record; returns a normalized copy."""
    out = dict(values)
    if not REGION.match(out.get("region", "")):
        raise OciError("Region không hợp lệ, ví dụ ap-singapore-1.")
    if out["auth"] == "api_key":
        for field in ("tenancy", "user"):
            if not OCID.match(out.get(field, "")):
                raise OciError("Thiếu hoặc sai OCID của " + field + ".")
        if "BEGIN" not in out.get("private_key", ""):
            raise OciError("Cần dán private key PEM của API Key.")
        fingerprint = key_fingerprint(out["private_key"], out.get("passphrase", ""))
        if out.get("fingerprint") and out["fingerprint"].lower() != fingerprint:
            raise OciError("Fingerprint không khớp private key. Fingerprint tính được: " + fingerprint)
        out["fingerprint"] = fingerprint
    return out


def public_account(account):
    keys = ("id", "name", "auth", "region", "tenancy", "user", "fingerprint")
    return dict({k: account.get(k, "") for k in keys}, has_key=bool(account.get("private_key")))


def message(exc):
    status = getattr(exc, "status", None)
    if status is not None and hasattr(exc, "code"):
        hints = {401: " Kiểm tra API Key, fingerprint, tenancy/user OCID.", 404: " Không tìm thấy tài nguyên hoặc policy IAM chưa cấp quyền (OCI trả 404 khi thiếu quyền).",
                 429: " OCI giới hạn tốc độ, thử lại sau."}
        text = str(getattr(exc, "message", "") or "")[:300]
        return "OCI " + str(status) + " " + str(exc.code) + ": " + text + hints.get(status, "")
    return type(exc).__name__ + ": " + str(exc)[:300]


def clients(account, region=None):
    oci = sdk()
    region = region or account.get("region")
    if not REGION.match(region or ""):
        raise OciError("Chưa chọn region OCI hợp lệ.")
    kwargs = {}
    if account["auth"] == "instance_principal":
        try:
            signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        except Exception as exc:
            raise OciError("Instance Principal không khả dụng: Manager phải chạy trên VM Oracle thuộc Dynamic Group. " + message(exc)) from None
        config = {"region": region}
        kwargs["signer"] = signer
        tenancy = signer.tenancy_id
    else:
        config = {"user": account["user"], "tenancy": account["tenancy"], "fingerprint": account["fingerprint"],
                  "key_content": account["private_key"], "region": region}
        if account.get("passphrase"):
            config["pass_phrase"] = account["passphrase"]
        try:
            oci.config.validate_config(config)
        except Exception as exc:
            raise OciError("Cấu hình API Key không hợp lệ: " + message(exc)) from None
        tenancy = account["tenancy"]
    return oci, tenancy, config, kwargs


def test(account, region=None):
    oci, tenancy, config, kwargs = clients(account, region)
    try:
        subs = oci.identity.IdentityClient(config, **kwargs).list_region_subscriptions(tenancy).data
    except Exception as exc:
        raise OciError(message(exc)) from None
    return {"ok": True, "tenancy": tenancy, "regions": sorted(s.region_name for s in subs)}


def _ports(rule_proto, options):
    if rule_proto == "all":
        return 1, 65535
    if rule_proto not in {"tcp", "udp"}:
        return None, None
    rng = getattr(options, "destination_port_range", None) if options else None
    return (rng.min, rng.max) if rng else (1, 65535)


def _normalize(rule, container, kind, rid=None):
    proto = PROTO.get(str(rule.protocol), str(rule.protocol))
    options = rule.tcp_options if proto == "tcp" else rule.udp_options if proto == "udp" else None
    lo, hi = _ports(proto, options)
    return {"id": rid or "", "proto": proto, "min": lo, "max": hi, "source": str(rule.source), "source_type": str(rule.source_type or "CIDR_BLOCK"),
            "stateless": bool(rule.is_stateless), "description": str(rule.description or ""), "container": container, "kind": kind}


def inspect(account, region, instance_id):
    """Instance → VNIC → subnet → VCN, Security Lists and NSGs, with ingress rules."""
    oci, _, config, kwargs = clients(account, region)
    try:
        compute = oci.core.ComputeClient(config, **kwargs)
        network = oci.core.VirtualNetworkClient(config, **kwargs)
        instance = compute.get_instance(instance_id).data
        attachments = [a for a in compute.list_vnic_attachments(instance.compartment_id, instance_id=instance_id).data
                       if a.lifecycle_state == "ATTACHED" and a.vnic_id]
        vnics = []
        for attachment in attachments:
            vnic = network.get_vnic(attachment.vnic_id).data
            subnet = network.get_subnet(vnic.subnet_id).data
            vcn = network.get_vcn(subnet.vcn_id).data
            lists = []
            for sid in subnet.security_list_ids or []:
                sl = network.get_security_list(sid).data
                lists.append({"id": sl.id, "name": sl.display_name, "rules": [_normalize(r, sl.id, "security_list") for r in sl.ingress_security_rules or []]})
            groups = []
            for nid in vnic.nsg_ids or []:
                nsg = network.get_network_security_group(nid).data
                rules = oci.pagination.list_call_get_all_results(network.list_network_security_group_security_rules, nid, direction="INGRESS").data
                groups.append({"id": nsg.id, "name": nsg.display_name, "rules": [_normalize(r, nid, "nsg", r.id) for r in rules]})
            vnics.append({"id": vnic.id, "primary": bool(vnic.is_primary), "public_ip": vnic.public_ip or "", "private_ip": vnic.private_ip or "",
                          "subnet": {"id": subnet.id, "name": subnet.display_name, "cidr": subnet.cidr_block},
                          "vcn": {"id": vcn.id, "name": vcn.display_name, "cidr": vcn.cidr_block},
                          "security_lists": lists, "nsgs": groups})
    except OciError:
        raise
    except Exception as exc:
        raise OciError(message(exc)) from None
    if not vnics:
        raise OciError("Instance không có VNIC đang gắn.")
    vnics.sort(key=lambda v: not v["primary"])
    return {"instance": {"id": instance.id, "name": instance.display_name, "shape": instance.shape, "state": instance.lifecycle_state,
                         "region": region or account.get("region"), "compartment_id": instance.compartment_id,
                         "availability_domain": instance.availability_domain}, "vnics": vnics}


def all_rules(vnic):
    return [r for c in vnic["security_lists"] + vnic["nsgs"] for r in c["rules"]]


def source_covers(rule_source, wanted):
    """True when an existing CIDR rule source includes the wanted source."""
    try:
        a, b = ipaddress.ip_network(rule_source, strict=False), ipaddress.ip_network(wanted, strict=False)
    except ValueError:
        return False
    return a.version == b.version and b.subnet_of(a)


def find_cover(rules, proto, lo, hi, source):
    return [r for r in rules if r["proto"] in {proto, "all"} and r["min"] is not None and r["min"] <= lo and r["max"] >= hi
            and r["source_type"] == "CIDR_BLOCK" and source_covers(r["source"], source)]


def choose_target(vnic, target):
    if target and target != "auto":
        kind, _, ident = target.partition(":")
        pool = vnic["nsgs"] if kind == "nsg" else vnic["security_lists"] if kind == "sl" else []
        for item in pool:
            if item["id"] == ident:
                return kind, item
        raise OciError("Security List/NSG đã chọn không thuộc VNIC chính của instance.")
    if vnic["nsgs"]:
        return "nsg", vnic["nsgs"][0]
    if vnic["security_lists"]:
        return "sl", vnic["security_lists"][0]
    raise OciError("VNIC không có Security List hoặc NSG để thêm rule.")


def _proto_number(proto):
    return {"tcp": "6", "udp": "17"}[proto]


def add_rule(account, region, vnic, target, proto, lo, hi, source):
    covering = find_cover(all_rules(vnic), proto, lo, hi, source)
    label = f"{proto}/{lo if lo == hi else str(lo) + '-' + str(hi)} từ {source}"
    if covering:
        return {"layer": "oci", "proto": proto, "status": "exists", "detail": "Oracle Cloud đã có rule bao phủ " + label + " (" + covering[0]["container"][-8:] + ")"}
    oci, _, config, kwargs = clients(account, region)
    models = oci.core.models
    network = oci.core.VirtualNetworkClient(config, **kwargs)
    kind, item = choose_target(vnic, target)
    options = {"destination_port_range": models.PortRange(min=lo, max=hi)}
    tcp = models.TcpOptions(**options) if proto == "tcp" else None
    udp = models.UdpOptions(**options) if proto == "udp" else None
    try:
        if kind == "nsg":
            details = models.AddNetworkSecurityGroupSecurityRulesDetails(security_rules=[models.AddSecurityRuleDetails(
                direction="INGRESS", protocol=_proto_number(proto), source=source, source_type="CIDR_BLOCK", is_stateless=False,
                description=TAG, tcp_options=tcp, udp_options=udp)])
            network.add_network_security_group_security_rules(item["id"], details)
        else:
            current = network.get_security_list(item["id"])
            new = models.IngressSecurityRule(protocol=_proto_number(proto), source=source, source_type="CIDR_BLOCK", is_stateless=False,
                                             description=TAG, tcp_options=tcp, udp_options=udp)
            network.update_security_list(item["id"], models.UpdateSecurityListDetails(
                ingress_security_rules=list(current.data.ingress_security_rules or []) + [new],
                egress_security_rules=list(current.data.egress_security_rules or [])), if_match=current.headers.get("etag"))
    except Exception as exc:
        raise OciError(message(exc)) from None
    return {"layer": "oci", "proto": proto, "status": "created", "detail": "Đã mở " + label + " trên " + ("NSG " if kind == "nsg" else "Security List ") + item["name"]}


def remove_rule(account, region, vnic, target, proto, lo, hi, source):
    label = f"{proto}/{lo if lo == hi else str(lo) + '-' + str(hi)} từ {source}"
    kind, item = choose_target(vnic, target)
    exact = [r for r in item["rules"] if r["proto"] == proto and r["min"] == lo and r["max"] == hi and r["source_type"] == "CIDR_BLOCK" and r["source"] == source]
    if not exact:
        return {"layer": "oci", "proto": proto, "status": "missing", "detail": "Oracle Cloud không có rule khớp chính xác " + label + " trên " + item["name"]}
    oci, _, config, kwargs = clients(account, region)
    models = oci.core.models
    network = oci.core.VirtualNetworkClient(config, **kwargs)
    try:
        if kind == "nsg":
            network.remove_network_security_group_security_rules(item["id"], models.RemoveNetworkSecurityGroupSecurityRulesDetails(security_rule_ids=[r["id"] for r in exact]))
        else:
            current = network.get_security_list(item["id"])
            keep = [r for r in current.data.ingress_security_rules or [] if not (
                _normalize(r, "", "")["proto"] == proto and _normalize(r, "", "")["min"] == lo and _normalize(r, "", "")["max"] == hi
                and str(r.source) == source and str(r.source_type or "CIDR_BLOCK") == "CIDR_BLOCK")]
            network.update_security_list(item["id"], models.UpdateSecurityListDetails(
                ingress_security_rules=keep, egress_security_rules=list(current.data.egress_security_rules or [])),
                if_match=current.headers.get("etag"))
    except Exception as exc:
        raise OciError(message(exc)) from None
    return {"layer": "oci", "proto": proto, "status": "removed", "detail": "Đã đóng " + label + " trên " + item["name"]}


def generate_keypair():
    """Generate a 2048-bit RSA PEM keypair and its OCI MD5 fingerprint."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    public_pem = key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()
    return {"private_key": private_pem, "public_key": public_pem, "fingerprint": key_fingerprint(private_pem)}
