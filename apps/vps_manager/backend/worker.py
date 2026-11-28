"""Allowlisted operations executed on the selected Linux host."""

import fcntl
import glob
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from tempfile import NamedTemporaryFile

LETSENCRYPT_DIR = Path("/etc/letsencrypt")


def _certbot_bin():
    """Return the Certbot executable name/path if installed, else None."""
    if shutil.which("certbot"):
        return "certbot"
    for candidate in ("/opt/certbot/bin/certbot", "/snap/bin/certbot"):
        if Path(candidate).is_file():
            return candidate
    return None


def save_cloudflare_token(params):
    """Save a Cloudflare API token for Certbot DNS-01 and optionally update existing credentials."""
    token = (params.get("token") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", token):
        raise ValueError("Cloudflare API token không hợp lệ.")
    raw_name = (params.get("name") or "default").strip().lower()
    if not re.fullmatch(r"[a-z0-9_.-]{1,64}", raw_name):
        raise ValueError("Tên tệp credential không hợp lệ (chỉ dùng a-z, 0-9, ., _, -).")
    directory = LETSENCRYPT_DIR / "zm-credentials"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    target = directory / f"{raw_name}.ini"
    content = "dns_cloudflare_api_token = " + token + "\n"
    atomic_write(target, content)
    os.chmod(target, 0o600)
    updated = [str(target)]
    if params.get("update_renewal", True):
        for existing in sorted(directory.glob("*.ini")):
            if existing != target:
                atomic_write(existing, content)
                os.chmod(existing, 0o600)
                updated.append(str(existing))
        renewal_dir = LETSENCRYPT_DIR / "renewal"
        if renewal_dir.is_dir():
            for conf in sorted(renewal_dir.glob("*.conf")):
                text = conf.read_text(errors="replace")
                match = re.search(r"(?m)^\s*dns_cloudflare_credentials\s*=\s*(\S+)", text)
                if match:
                    cred_path = Path(match.group(1).strip("'\""))
                    if cred_path != target and cred_path.parent.exists():
                        atomic_write(cred_path, content)
                        os.chmod(cred_path, 0o600)
                        if str(cred_path) not in updated:
                            updated.append(str(cred_path))
                    new_text = re.sub(r"(?m)^(\s*dns_cloudflare_propagation_seconds\s*=\s*)\d+", r"\g<1>15", text)
                    if new_text != text:
                        atomic_write(conf, new_text)
    event("Cloudflare · Đã lưu token (" + str(len(updated)) + " tệp)")
    return {"credential": str(target), "updated": updated}


def _build_renewal_map(renewal_dir):
    """Map certificate/fullchain paths (and resolved targets) in renewal/*.conf to Certbot profile names."""
    mapping = {}
    if not renewal_dir.is_dir():
        return mapping
    for conf in sorted(renewal_dir.glob("*.conf")):
        try:
            text = conf.read_text(errors="replace")
        except OSError:
            continue
        for match in re.finditer(r"(?m)^\s*(?:cert|fullchain)\s*=\s*(\S+)", text):
            raw = match.group(1).strip("'\"")
            mapping[raw] = conf.stem
            try:
                mapping[str(Path(raw).resolve())] = conf.stem
            except OSError:
                pass
    return mapping


def _collect_ssl_certificates(children, root, seen=None):
    """Collect ssl_certificate values from a server block and any included config files."""
    if seen is None:
        seen = set()
    certs = []
    for words, _ in children:
        if words[0] == "ssl_certificate" and len(words) >= 2:
            certs.append(" ".join(words[1:]))
        elif words[0] == "include" and len(words) == 2:
            pattern = Path(words[1]) if Path(words[1]).is_absolute() else root / words[1]
            for inc_name in sorted(glob.glob(str(pattern))):
                inc_path = Path(inc_name)
                try:
                    real_inc = inc_path.resolve()
                except OSError:
                    continue
                if real_inc in seen or not real_inc.is_file() or real_inc.stat().st_size > 2_000_000:
                    continue
                seen.add(real_inc)
                certs.extend(_collect_ssl_certificates(nginx_blocks(real_inc.read_text(errors="replace")), root, seen))
    return certs


def _match_renewal_name(certificate, renewal_dir, renewal_map):
    """Resolve a Certbot renewal profile name from an ssl_certificate path."""
    if certificate in renewal_map:
        return renewal_map[certificate]
    try:
        resolved = str(Path(certificate).resolve())
    except OSError:
        resolved = certificate
    if resolved in renewal_map:
        return renewal_map[resolved]
    for candidate in (certificate, resolved):
        match = re.fullmatch(
            r".*/letsencrypt/(?:live|archive)/([a-zA-Z0-9_.-]+)/(?:cert|fullchain)\d*\.pem",
            candidate,
        )
        if match and (renewal_dir / f"{match[1]}.conf").is_file():
            return match[1]
    return None


def command(args, check=True, timeout=60):
    proc = subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        env={**os.environ, "LC_ALL": "C", "DEBIAN_FRONTEND": "noninteractive"},
    )
    if check and proc.returncode:
        if args[:2] == ["nginx","-t"] or args[0]=="unshare":
            location = re.search(r" in (/[^\n]+?:\d+)",proc.stderr)
            reason = "Cấu hình Nginx không hợp lệ" if "nginx:" in proc.stderr else "Không chạy được kiểm tra cô lập"
            raise ValueError(reason + (" · "+location[1] if location else "")+".")
        tail = ((proc.stderr or "") + "\n" + (proc.stdout or "")).strip()[-350:]
        show_tail = tail and (args[0] == "certbot" or "apt" in os.path.basename(args[0]))
        raise ValueError(f"{args[0]} thất bại (exit {proc.returncode})" + (f": {tail}" if show_tail else "."))
    return proc.stdout.strip()


def event(message):
    print(json.dumps({"event": message}), flush=True)


def probe(url, domain):
    try:
        req = urllib.request.Request(url, method="HEAD", headers={"Host": domain})
        with urllib.request.urlopen(req, timeout=5) as response:
            return str(response.status)
    except urllib.error.HTTPError as exc:
        return str(exc.code)
    except OSError:
        return "unreachable"


def validate_domain(domain):
    if not re.fullmatch(
        r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]",
        domain,
    ):
        raise ValueError("Domain không hợp lệ.")


MARKER = "# ZM VPS Manager\n"


def site_inventory(root):
    rows = []
    for directory, enabled in (("conf.d", True), ("zm-disabled", False)):
        for path in sorted((root / directory).glob("zm-*.conf")):
            if path.is_symlink() or not path.is_file():
                continue
            content = path.read_text()
            if content.startswith(MARKER):
                port = re.search(r"proxy_pass http://127\.0\.0\.1:(\d+);", content)
                rows.append(dict(domain=path.name[3:-5], enabled=enabled,
                                 port=int(port[1]) if port else None,
                                 https="listen 443 ssl;" in content))
    return rows


def nginx_blocks(source):
    """Collect directives per block without treating quoted delimiters as syntax."""
    tokens = re.finditer(r"""\#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\$\{\w+\}|[{};]|(?:\\.|[^\s{};\#"'\\])+""", source)
    root = []
    stack = [root]
    words = []
    for token in tokens:
        value = token.group()
        if value.startswith("#"):
            continue
        if value in {";", "{"}:
            if words:
                children = []
                stack[-1].append((words, children))
                if value == "{":
                    stack.append(children)
            words = []
        elif value == "}":
            if len(stack) > 1:
                stack.pop()
            words = []
        else:
            words.append(value.strip("'\042"))
    return root


def walk_directives(nodes):
    for words, children in nodes:
        yield words, children
        yield from walk_directives(children)


def discover_sites(root):
    import glob
    import hashlib
    import ssl
    if not shutil.which("nginx"):
        return dict(sites=[],diagnostics=["Cần cài Nginx trong Software Center."],php_sockets=[],capabilities={})
    dump = subprocess.run(["nginx", "-T"], text=True, errors="replace", capture_output=True, timeout=30)
    loaded = [Path(name) for name in re.findall(r"(?m)^# configuration file (.+):$", dump.stdout)]
    queue = [(p, True) for p in loaded or [root / "nginx.conf"]]
    for directory, pattern in (("sites-enabled", "*"), ("sites-available", "*"), ("conf.d", "*.conf"), ("zm-disabled", "*.conf")):
        queue.extend((p, False) for p in sorted((root / directory).glob(pattern)))
    seen = {}
    broken = []
    sites = []
    diagnostics = []
    renewal_dir = LETSENCRYPT_DIR / "renewal"
    renewal_map = _build_renewal_map(renewal_dir)
    if dump.returncode:
        diagnostics.extend(line[:600] for line in dump.stderr.splitlines()[-3:])
    while queue:
        path, included = queue.pop(0)
        if path.is_symlink() and not path.exists():
            if path.parent==root/"sites-enabled":
                broken.append(dict(id=hashlib.sha256(str(path).encode()).hexdigest(),path=str(path),target=os.readlink(path)))
            diagnostics.append("Symlink hỏng · " + str(path))
            continue
        real = path.resolve()
        if included and seen.get(real) is False:
            sites = [s for s in sites if s["source"] != str(real)]
        if real in seen and (seen[real] or not included):
            continue
        seen[real] = included
        if not real.is_file() or real.stat().st_size > 2_000_000:
            continue
        source = real.read_text(errors="replace")
        nodes = list(walk_directives(nginx_blocks(source)))
        if dump.returncode and real.parent in (root/"sites-available",root/"sites-enabled",root/"conf.d") and not any(w==["server"] and children for w,children in nodes):
            sites.append(dict(domain=real.name,primary="",listeners=[],kind="config",target="",source=str(real),
                              managed=False,enabled=included,https=False,expires=None,port=None,
                              revision=hashlib.sha256(source.encode()).hexdigest(),file_id=hashlib.sha256(str(real).encode()).hexdigest()))
        for words, children in nodes:
            if words[0] == "include" and len(words) == 2 and included and not loaded:
                queue.extend((Path(name), True) for name in glob.glob(str(root / words[1])))
            if words != ["server"] or not children:
                continue
            def values(name):
                return [" ".join(w[1:]) for w, _ in children if w[0] == name]
            domains = " ".join(values("server_name")).split()
            listeners = values("listen") or ["80"]
            kind, target = "static", next(iter(values("root")), "")
            for w, _ in walk_directives(children):
                if w[0] in {"proxy_pass", "grpc_pass", "fastcgi_pass", "return"}:
                    kind = {"proxy_pass":"proxy", "grpc_pass":"gRPC", "fastcgi_pass":"PHP", "return":"return"}[w[0]]
                    target = " ".join(w[1:])
                    break
            if kind=="static" and any(w[0]=="try_files" and w[-1]=="/index.html" for w,_ in walk_directives(children)):
                kind="SPA"
            managed = source.startswith(MARKER) and real.name.startswith("zm-") and real.parent in (root/"conf.d", root/"zm-disabled") and bool(domains) and real.name == "zm-"+domains[0]+".conf"
            certificates = _collect_ssl_certificates(children, root)
            renewal_names = []
            for certificate in certificates:
                matched = _match_renewal_name(certificate, renewal_dir, renewal_map)
                if matched:
                    renewal_names.append(matched)
            expires = None
            if certificates:
                try:
                    cert = ssl._ssl._test_decode_cert(str(root / certificates[0]))
                    expires = int((ssl.cert_time_to_seconds(cert["notAfter"]) - time.time()) // 86400)
                except (ValueError, OSError, ssl.SSLError):
                    diagnostics.append("Không đọc được chứng chỉ · " + str(real))
            sites.append(dict(domain=" ".join(domains) or real.name, primary=domains[0] if domains else "",
                              renewal_names=sorted(set(renewal_names)),ssl_certificates=certificates,listeners=listeners, kind=kind, target=target, source=str(real),
                              file_id=hashlib.sha256(str(real).encode()).hexdigest(), managed=managed, enabled=included, https=bool(certificates), expires=expires,
                              port=int(target.rsplit(":",1)[1]) if re.fullmatch(r"http://127\.0\.0\.1:\d+",target) else None,
                              revision=hashlib.sha256(source.encode()).hexdigest()))
    listeners = {}
    for site in sites:
        if not site["enabled"]:
            continue
        for listener in site["listeners"]:
            address = listener.split()[0]
            if address.isdigit():
                address = "0.0.0.0:" + address
            for name in site["domain"].lower().split():
                key = (address, name)
                if key in listeners:
                    diagnostics.append(f"Trùng {name} · {address} · {listeners[key]} · {site['source']}")
                listeners[key] = site["source"]
    version = subprocess.run(["nginx","-V"],capture_output=True,text=True,timeout=10).stderr
    capabilities = dict(http2="--with-http_v2_module" in version,http3="--with-http_v3_module" in version,
                        brotli="brotli" in version or bool(re.search(r"load_module [^;]*brotli_filter_module",dump.stdout)))
    return dict(broken=broken,capabilities=capabilities,sites=sites, diagnostics=diagnostics, php_sockets=sorted(glob.glob("/run/php/*fpm.sock")), ssl_renewal=certbot_renewal_status())


def website_file(action, params, root):
    import difflib
    import hashlib
    import stat
    with (root / ".zm-vps.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if action in {"apply","lifecycle","external-certificate","renew-ssl","renew-test"} else fcntl.LOCK_SH)
        inventory = discover_sites(root)
        rows = [s for s in inventory["sites"] if s["file_id"] == params["file_id"]]
        if not rows:
            raise ValueError("Website không còn trong inventory.")
        path = Path(rows[0]["source"])
        old = path.read_text()
        revision = hashlib.sha256(old.encode()).hexdigest()
        if action == "renew-ssl":
            matches = [r for r in rows if r["domain"]==params["domain"] and r["enabled"] and r["https"]]
            names = sorted({name for r in matches for name in r["renewal_names"]})
            if revision != params["revision"] or not matches or not names:
                raise ValueError("Cấu hình đã thay đổi hoặc không xác định được hồ sơ Certbot cho site.")
            certbot_bin = _certbot_bin()
            if not certbot_bin:
                raise ValueError("Cần cài Certbot trong Software Center trước.")
            for name in names:
                event("Certbot · " + name)
                command([certbot_bin, "renew", "--non-interactive", "--cert-name", name], timeout=600)
            command(["nginx", "-t"])
            command(["systemctl", "reload", "nginx"])
            import ssl
            last_expires = None
            for name in names:
                cert_path = LETSENCRYPT_DIR / "live" / name / "cert.pem"
                if not cert_path.is_file():
                    cert_path = LETSENCRYPT_DIR / "live" / name / "fullchain.pem"
                cert = ssl._ssl._test_decode_cert(str(cert_path))
                if ssl.cert_time_to_seconds(cert["notAfter"]) <= time.time():
                    raise ValueError(f"Chứng chỉ {name} vẫn hết hạn sau khi chạy Certbot.")
                last_expires = cert["notAfter"]
            return {"certificate": ", ".join(names), "expires": last_expires}
        if action == "renew-test":
            matches = [r for r in rows if r["domain"]==params.get("domain") and r["enabled"] and r["https"]]
            names = {name for r in matches for name in r["renewal_names"]}
            if not matches or not names:
                raise ValueError("Cần site HTTPS đang bật và hồ sơ Certbot hợp lệ để thử gia hạn.")
            certbot_bin = _certbot_bin()
            if not certbot_bin:
                raise ValueError("Cần cài Certbot trong Software Center trước.")
            for name in sorted(names):
                event("Certbot · Kiểm tra gia hạn · " + name)
                command([certbot_bin, "renew", "--dry-run", "--cert-name", name], timeout=600)
            return {"domain":params.get("domain"),"renewal_test":"ok"}
        editable = (path.parent in [root / "conf.d", root / "sites-available"] and
                    all(w == ["server"] or w[0] == "upstream" for w, _ in nginx_blocks(old))
                    and all(row["enabled"] for row in rows))
        history = root / "zm-backups" / params["file_id"]
        if action == "lifecycle":
            operation = params["operation"]
            if path.parent != root / "sites-available" or revision != params["revision"]:
                raise ValueError("Đường dẫn hoặc phiên bản website đã thay đổi.")
            enabled_dir = root / "sites-enabled"
            links = [p for p in enabled_dir.iterdir() if p.is_symlink() and p.resolve()==path]
            original_links = [(p,os.readlink(p)) for p in links]
            new_link = enabled_dir / path.name
            created = False
            removed = False
            history.mkdir(mode=0o700, parents=True, exist_ok=True)
            backup = history / (str(time.time_ns())+".conf")
            shutil.copy2(path, backup)
            if operation not in {"enable","disable","delete"}:
                raise ValueError("Thao tác không hợp lệ.")
            try:
                if operation == "enable" and not links:
                    new_link.symlink_to(path)
                    created = True
                if operation in {"disable","delete"}:
                    for link in links:
                        link.unlink()
                    if any(row["enabled"] for row in rows) and not links:
                        raise ValueError("Site được include trực tiếp.")
                if operation == "delete":
                    path.unlink()
                    removed = True
                command(["nginx","-t"])
                command(["systemctl","reload","nginx"])
                command(["systemctl","is-active","nginx"])
            except Exception:
                if removed:
                    shutil.copy2(backup,path)
                if created:
                    new_link.unlink()
                for link,target in original_links:
                    if not link.is_symlink():
                        link.symlink_to(target)
                command(["nginx","-t"])
                command(["systemctl","reload","nginx"])
                raise
            return dict(file=str(path),operation=operation,backup=backup.name)
        if action == "detail":
            listening = command(["ss","-H","-ltnp"],False).splitlines() if shutil.which("ss") else []
            for row in rows:
                for listener in row["listeners"]:
                    address = listener.split()[0]
                    host,sep,port = address.rpartition(":")
                    host = host.strip("[]") if sep else "*"
                    for entry in listening:
                        columns = entry.split(None,5)
                        if len(columns)<6 or "nginx" in columns[5] or not port.isdigit():
                            continue
                        bound,_,bound_port = columns[3].rpartition(":")
                        if bound_port==port and (host in {"*","0.0.0.0","::"} or bound.strip("[]") in {host,"*","0.0.0.0","::"}):
                            inventory["diagnostics"].append("Cổng đang do tiến trình khác sử dụng · "+columns[3]+" · "+columns[5])

                backend = re.fullmatch(r"(?:https?://|grpc://)?([a-zA-Z0-9_.-]+):(\d+)(?:/.*)?",row["target"])
                if backend:
                    try:
                        with socket.create_connection((backend[1],int(backend[2])),timeout=1):
                            pass
                    except OSError:
                        inventory["diagnostics"].append("Backend offline · "+row["target"]+" · Kiểm tra tiến trình và cổng lắng nghe.")
            return dict(source=old, revision=revision, editable=editable, domains=[s["domain"] for s in rows],
                        history=sorted([p.name for p in history.glob("*.conf")], reverse=True)[:30],
                        diagnostics=inventory["diagnostics"])
        if action == "ssl-status":
            import ssl
            site = next((row for row in rows if row["domain"] == params.get("domain")),rows[0])
            renewal = certbot_renewal_status()
            timer = "active" if renewal["unit"] else _systemctl_output(["is-active","certbot.timer"])
            cron = renewal["cron"] or Path("/etc/cron.d/certbot").is_file()
            status = dict(timer=timer,cron=cron, renewal=renewal, served=None, error="")
            tls = next((item.split()[0] for item in site["listeners"] if "ssl" in item.split()),None)
            if tls and site["primary"]:
                endpoint = tls.rsplit(":",1)
                host = endpoint[0].strip("[]") if len(endpoint)==2 else "127.0.0.1"
                if host in {"*","0.0.0.0","::"}:
                    host = "::1" if host=="::" else "127.0.0.1"
                try:
                    with socket.create_connection((host,int(endpoint[-1])),timeout=3) as sock:
                        with ssl.create_default_context().wrap_socket(sock,server_hostname=site["primary"]) as channel:
                            cert = channel.getpeercert()
                            status["served"] = dict(expires=cert["notAfter"],names=[n for k,n in cert.get("subjectAltName",[]) if k=="DNS"])
                except (ValueError,OSError) as exc:
                    status["error"] = str(exc)
            return status
        if action == "logs":
            files = {}
            for words, _ in walk_directives(nginx_blocks(old)):
                if words[0] in {"access_log", "error_log"} and len(words)>1:
                    files.setdefault(words[0],set()).add(words[1])
            inherited = {}
            config = root / "nginx.conf"
            if config.is_file():
                for words,children in nginx_blocks(config.read_text()):
                    directives = [w for w,_ in children] if words==["http"] else [words]
                    for directive in directives:
                        if directive[0] in {"access_log","error_log"} and len(directive)>1:
                            inherited.setdefault(directive[0],set()).add(directive[1])
            for kind,paths in inherited.items():
                files.setdefault(kind,paths)
            logs = []
            for kind, paths in files.items():
                for name in sorted(paths):
                    location = Path(name).resolve()
                    if not location.is_relative_to("/var/log/nginx") or not location.is_file():
                        continue
                    try:
                        cursors = json.loads(params.get("cursor") or "{}")
                    except ValueError:
                        cursors = {}
                    with location.open("rb") as stream:
                        info = os.fstat(stream.fileno())
                        previous = cursors.get(name) if isinstance(cursors,dict) else None
                        continues = (isinstance(previous,list) and len(previous)==2 and previous[0]==info.st_ino
                                     and type(previous[1]) is int and 0<=previous[1]<=info.st_size)
                        stream.seek(previous[1] if continues else max(0,info.st_size-32768))
                        if not continues and stream.tell():
                            stream.readline(32768)
                        data = stream.read(65536)
                        end = data.rfind(b"\n")+1
                        if not end and len(data)==65536:
                            end = len(data)
                        position = stream.tell()-len(data)+end
                        lines = data[:end].decode(errors="replace").splitlines()
                    groups = {}
                    timestamps = []
                    if kind=="access_log":
                        for line in lines:
                            match = re.search(r'\[([^\]]+)\] "[^"]*" ([1-5])\d{2} ',line)
                            if match:
                                group = match[2]+"xx"
                                groups[group] = groups.get(group,0)+1
                                timestamps.append(match[1])
                    logs.append(dict(kind=kind,path=name,lines=lines,statuses=groups,cursor=[info.st_ino,position],
                                     first=next(iter(timestamps),""),last=timestamps[-1] if timestamps else ""))
            return logs
        if not editable or params.get("revision") != revision:
            raise ValueError("Tệp chỉ đọc hoặc đã thay đổi. Mở lại cấu hình.")
        candidate = params["source"]
        snapshot = params.get("snapshot")
        if snapshot:
            if not re.fullmatch(r"\d+\.conf", snapshot):
                raise ValueError("Bản sao không hợp lệ.")
            candidate = (history / snapshot).read_text()
        if action == "external-certificate":
            if not editable or len(rows)!=1 or not rows[0]["primary"] or (rows[0]["https"] and rows[0]["renewal_names"]):
                raise ValueError("Cấp SSL tại đây cần một website HTTP duy nhất hoặc site HTTPS chưa có hồ sơ Certbot.")
            domain = rows[0]["primary"]
            validate_domain(domain)
            if params["domain"]!=domain:
                raise ValueError("Tên miền đã thay đổi.")
            opening = re.search(r"(?m)^[ \t]*server[ \t]*\{",old)
            if not opening:
                raise ValueError("Cần chọn vị trí listener bằng editor.")
            cert_name = "zm-" + domain
            live_dir = LETSENCRYPT_DIR / "live" / cert_name
            renewal_file = LETSENCRYPT_DIR / "renewal" / (cert_name + ".conf")
            backup_live = None
            if live_dir.exists() and not renewal_file.is_file():
                backup_live = LETSENCRYPT_DIR / "live" / f".{cert_name}.bak-{time.time_ns()}"
                live_dir.rename(backup_live)
            try:
                cert = issue_certificate(domain,params)
            except Exception:
                if backup_live and backup_live.exists() and not live_dir.exists():
                    backup_live.rename(live_dir)
                raise
            if backup_live and backup_live.exists():
                shutil.rmtree(backup_live, ignore_errors=True)
            if not rows[0]["https"]:
                tls = (f"\n    listen 443 ssl;\n    ssl_certificate {cert}/fullchain.pem;"
                       f"\n    ssl_certificate_key {cert}/privkey.pem;")
                if params.get("force_https"):
                    tls += '\n    if ($scheme = http) { return 301 https://$host$request_uri; }'
                candidate = old[:opening.end()]+tls+old[opening.end():]
            else:
                candidate = re.sub(r"(?m)^([ \t]*ssl_certificate\s+)[^;]+;", rf"\g<1>{cert}/fullchain.pem;", old)
                candidate = re.sub(r"(?m)^([ \t]*ssl_certificate_key\s+)[^;]+;", rf"\g<1>{cert}/privkey.pem;", candidate)
        if not candidate.strip():
            raise ValueError("Cấu hình trống.")
        if action == "check":
            # Bind the candidate over its original path only inside the child mount namespace.
            with NamedTemporaryFile(mode="w",dir=history.parent if history.parent.exists() else root) as tmp:
                tmp.write(candidate)
                tmp.flush()
                command(["unshare","--mount","--propagation","private","sh","-ec",
                         'mount --bind "$1" "$2"; exec nginx -t',"nginx-preview",tmp.name,str(path)])
            return {"valid": True}
        if action == "diff":
            return dict(diff="".join(difflib.unified_diff(old.splitlines(True),candidate.splitlines(True),
                                                          fromfile=str(path),tofile="candidate")))
        if action not in {"apply","external-certificate"}:
            raise ValueError("Thao tác không hợp lệ.")
        history.mkdir(parents=True, mode=0o700, exist_ok=True)
        backup = history / (str(time.time_ns())+".conf")
        atomic_write(backup, old)
        original = path.stat()
        def write(content):
            with NamedTemporaryFile(mode="w",dir=path.parent,delete=False) as temp:
                temp.write(content)
                os.fchown(temp.fileno(),original.st_uid,original.st_gid)
                os.fchmod(temp.fileno(),stat.S_IMODE(original.st_mode))
            os.replace(temp.name,path)
        write(candidate)
        try:
            command(["nginx","-t"])
            command(["systemctl","reload","nginx"])
            command(["systemctl","is-active","nginx"])
        except Exception:
            write(old)
            command(["nginx","-t"])
            command(["systemctl","reload","nginx"])
            raise
        if action == "external-certificate":
            try:
                renewal = enable_certbot_renewal()
                event("Certbot · Tự gia hạn · " + renewal["detail"])
            except ValueError:
                pass
        return dict(file=str(path),backup=backup.name)


CERTBOT_TIMERS = ("certbot.timer", "certbot-renew.timer", "snap.certbot.renew.timer")


def _systemctl_output(args):
    try:
        return command(["systemctl", *args], False)
    except FileNotFoundError:
        return ""


def _timer_stagger(unit):
    delay = _systemctl_output(["show", "-p", "RandomizedDelaySec", "--value", unit])
    if delay in {"", "0", "0s"} or not re.fullmatch(r"\d+(?:\.\d+)?(?:[a-zA-Z]+)?(?:\s+\d+(?:[a-zA-Z]+)?)*", delay):
        return ""
    return delay


def certbot_renewal_status():
    """Return current Certbot automatic renewal status (systemd timer or cron)."""
    for unit in CERTBOT_TIMERS:
        if _systemctl_output(["is-active", unit]) == "active":
            stagger = _timer_stagger(unit)
            detail = f"{unit} · giãn cách {stagger}" if stagger else unit
            return {"enabled": True, "method": "systemd", "unit": unit, "cron": False, "stagger": stagger, "detail": detail}
    managed_cron = Path("/etc/cron.d/zm-certbot-renew")
    if managed_cron.is_file():
        return {"enabled": True, "method": "cron", "unit": "", "cron": True, "stagger": "ngẫu nhiên", "detail": str(managed_cron)}
    system_cron = Path("/etc/cron.d/certbot")
    if system_cron.is_file():
        try:
            text = system_cron.read_text()
        except OSError:
            text = ""
        if "/run/systemd/system" not in text or not Path("/run/systemd/system").exists():
            return {"enabled": True, "method": "cron", "unit": "", "cron": True, "stagger": "", "detail": str(system_cron)}
    return {"enabled": False, "method": "", "unit": "", "cron": False, "stagger": "", "detail": ""}


def enable_certbot_renewal():
    """Enable Certbot automatic renewal with per-VPS randomized timing."""
    import secrets
    status = certbot_renewal_status()
    if status["enabled"]:
        if status["method"] == "systemd" and not status["stagger"]:
            dropin = Path(f"/etc/systemd/system/{status['unit']}.d/zm-stagger.conf")
            if not dropin.is_dir():
                dropin.parent.mkdir(parents=True, exist_ok=True)
                atomic_write(dropin, "[Timer]\nRandomizedDelaySec=6h\n")
                os.chmod(dropin, 0o644)
                _systemctl_output(["daemon-reload"])
                _systemctl_output(["restart", status["unit"]])
                status["stagger"] = _timer_stagger(status["unit"]) or "6h"
                status["detail"] = f"{status['unit']} · giãn cách {status['stagger']}"
        return status
    for unit in CERTBOT_TIMERS:
        if _systemctl_output(["cat", unit]):
            if not _timer_stagger(unit):
                dropin = Path(f"/etc/systemd/system/{unit}.d/zm-stagger.conf")
                if not dropin.is_dir():
                    dropin.parent.mkdir(parents=True, exist_ok=True)
                    atomic_write(dropin, "[Timer]\nRandomizedDelaySec=6h\n")
                    os.chmod(dropin, 0o644)
                    _systemctl_output(["daemon-reload"])
            command(["systemctl", "enable", "--now", unit])
            if _systemctl_output(["is-active", unit]) == "active":
                stagger = _timer_stagger(unit)
                detail = f"{unit} · giãn cách {stagger}" if stagger else unit
                return {"enabled": True, "method": "systemd", "unit": unit, "cron": False, "stagger": stagger, "detail": detail}
    certbot_bin = shutil.which("certbot")
    if not certbot_bin:
        venv_bin = Path("/opt/certbot/bin/certbot")
        if venv_bin.is_file():
            certbot_bin = str(venv_bin)
    if not certbot_bin:
        raise ValueError("Cần cài Certbot trong Software Center trước khi bật tự gia hạn.")
    cron_path = Path("/etc/cron.d/zm-certbot-renew")
    if cron_path.is_dir():
        return {"enabled": True, "method": "cron", "unit": "", "cron": True, "stagger": "ngẫu nhiên", "detail": str(cron_path)}
    minute = secrets.randbelow(60)
    hour = secrets.randbelow(12)
    cron_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(
        cron_path,
        "SHELL=/bin/sh\n"
        "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n"
        f'{minute} {hour},{hour + 12} * * * root {sys.executable} -c "import random,time;time.sleep(random.randrange(900))" && {certbot_bin} renew --quiet --deploy-hook "nginx -t && systemctl reload nginx"\n',
    )
    os.chmod(cron_path, 0o644)
    return {"enabled": True, "method": "cron", "unit": "", "cron": True, "stagger": f"{minute:02d} {hour},{hour + 12}", "detail": f"{cron_path} ({minute:02d} {hour},{hour + 12})"}


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as tmp:
        tmp.write(content)
    os.replace(tmp.name, path)


def issue_certificate(domain, params, cert_name=None):
    mode = params["method"]
    email = params["email"]
    if mode not in {"http", "cloudflare"} or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
        raise ValueError("Kiểm tra email và phương thức xác thực.")
    if not shutil.which("certbot"):
        raise ValueError("Cài Certbot và plugin trong Software Center trước.")
    name = cert_name or ("zm-" + domain)
    args = ["certbot", "certonly", "--non-interactive", "--agree-tos", "--email", email,
            "--cert-name", name, "-d", domain, "--keep-until-expiring",
            "--deploy-hook", "nginx -t && systemctl reload nginx"]
    for alias in dict.fromkeys(params.get("names", [])):
        wildcard = alias.startswith("*.")
        validate_domain(alias[2:] if wildcard else alias)
        if wildcard and mode != "cloudflare":
            raise ValueError("Wildcard cần DNS-01 Cloudflare.")
        if alias != domain:
            args += ["-d", alias]
    credential = None
    previous = None
    wrote_credential = False
    if mode == "cloudflare":
        token = (params.get("token") or "").strip()
        directory = Path("/etc/letsencrypt/zm-credentials") if str(LETSENCRYPT_DIR) == "/etc/letsencrypt" else LETSENCRYPT_DIR / "zm-credentials"
        if token:
            if not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", token):
                raise ValueError("Cloudflare API token không hợp lệ.")
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            credential = directory / (domain + ".ini")
            previous = credential.read_text() if credential.exists() else None
            atomic_write(credential, "dns_cloudflare_api_token = " + token + "\n")
            os.chmod(credential, 0o600)
            wrote_credential = True
        else:
            for candidate in (directory / (domain + ".ini"), directory / "default.ini"):
                if candidate.is_file():
                    credential = candidate
                    break
            if not credential:
                raise ValueError("Cloudflare API token không hợp lệ.")
        args += ["--dns-cloudflare", "--dns-cloudflare-credentials", str(credential),
                 "--dns-cloudflare-propagation-seconds", "15"]
    else:
        args += ["--nginx"]
    try:
        event("Certbot · " + mode + " · " + domain)
        try:
            command(args, timeout=600)
        except Exception as first_exc:
            if mode == "cloudflare" and ("dns-cloudflare" in str(first_exc) or "exit 2" in str(first_exc)) and shutil.which("apt-get"):
                event("Đang tự cài python3-certbot-dns-cloudflare…")
                command(["apt-get", "update", "-qq"], timeout=120)
                command(["apt-get", "install", "-y", "python3-certbot-dns-cloudflare"], timeout=180)
                command(args, timeout=600)
            else:
                raise first_exc
    except Exception as exc:
        if wrote_credential and credential:
            if previous is None:
                credential.unlink(missing_ok=True)
            else:
                atomic_write(credential, previous)
        detail = str(exc).strip()
        hints = [
            (r"NXDOMAIN|No valid A|DNS problem", "Tên miền chưa trỏ DNS (A/AAAA) về IP VPS."),
            (r"Timeout during connect|Connection refused|port 80", "Không kết nối được cổng 80 từ ngoài (kiểm tra Firewall UFW/Oracle và Nginx)."),
            (r"81058|identical record|_acme-challenge", "Bản ghi TXT _acme-challenge cũ đang kẹt trên Cloudflare; xóa rồi thử lại sau 30-60s."),
            (r"Unauthorized|Authentication|403|Invalid.*token|Could not determine zone", "Cloudflare API Token sai hoặc thiếu quyền Zone:DNS:Edit."),
            (r"too many certificates|rateLimited", "Vượt giới hạn cấp chứng chỉ (rate limit) của Let's Encrypt."),
        ]
        reason = next((msg for pat, msg in hints if re.search(pat, detail, re.I)), "")
        prefix = (reason + " · ") if reason else ""
        raise ValueError("Certbot thất bại: " + prefix + (detail[-350:] if detail else "Kiểm tra /var/log/letsencrypt/letsencrypt.log trên VPS.")) from None
    return "/etc/letsencrypt/live/" + name


def website_config(domain, port, params):
    kind = params.get("kind", "proxy")
    names = list(dict.fromkeys([domain, *params.get("names", [])]))
    for alias in names:
        validate_domain(alias.removeprefix("*."))
    backend = params.get("backend") or f"127.0.0.1:{port}"
    directory = params.get("directory") or "/var/www/html"
    if not re.fullmatch(r"/(?:[A-Za-z0-9_.-]+/?)+", directory) or ".." in directory.split("/"):
        raise ValueError("Đường dẫn thư mục web không hợp lệ.")
    location = params.get("location") or "/"
    if not re.fullmatch(r"/[a-zA-Z0-9_./-]*", location):
        raise ValueError("Location không hợp lệ.")
    prefix = ""
    if kind in {"proxy", "WebSocket", "SSE", "gRPC", "PHP"}:
        entries = [entry.strip() for entry in backend.split(",")]
        for entry in entries:
            if kind == "PHP" and re.fullmatch(r"unix:/[A-Za-z0-9_./-]+\.sock", entry):
                continue
            if not re.fullmatch(r"(?:[a-zA-Z0-9_.-]+|\[[0-9a-fA-F:]+\]):\d{1,5}(?: weight=[1-9]\d{0,3})?(?: max_fails=\d{1,3})?(?: fail_timeout=\d+[smh]?)?(?: backup)?", entry) or not 1 <= int(entry.split()[0].rsplit(":",1)[1]) <= 65535:
                raise ValueError("Backend cần host:port, có thể thêm weight=N hoặc backup.")
        if len(entries)>1 or " " in backend:
            pool = "zm_" + domain.replace(".", "_").replace("-", "_")
            algorithm = params.get("algorithm", "round-robin")
            if algorithm not in {"round-robin","least_conn","ip_hash"}:
                raise ValueError("Thuật toán upstream không hợp lệ.")
            lines = ([] if algorithm == "round-robin" else [algorithm+";"]) + ["keepalive 32;"] + ["server "+item+";" for item in entries]
            prefix = "upstream "+pool+" {\n    "+"\n    ".join(lines)+"\n}\n"
            backend = pool
    if kind == "static":
        body = f"root {directory};\n    location {location} {{ try_files $uri $uri/ =404; }}"
    elif kind == "spa":
        body = f"root {directory};\n    index index.html;\n    location / {{ try_files $uri $uri/ /index.html; }}"
    elif kind == "PHP":
        body = (f"root {directory};\n    index index.php index.html;\n"
                f"    location ~ \\.php$ {{\n        try_files $uri =404;\n        include fastcgi_params;\n"
                f"        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;\n        fastcgi_pass {backend};\n    }}")
    elif kind == "redirect":
        url = params.get("redirect","")
        if not re.fullmatch(r"https?://[A-Za-z0-9.-]+(?::\d+)?(?:/[A-Za-z0-9_./%-]*)?",url):
            raise ValueError("URL chuyển hướng không hợp lệ.")
        body = f"return 301 {url.rstrip('/')}$request_uri;"
    elif kind == "gRPC":
        body = f"location {location} {{ grpc_pass grpc://{backend}; }}"
    elif kind in {"proxy","WebSocket","SSE"}:
        options = {"proxy":"", "WebSocket":'proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";',
                   "SSE":"proxy_buffering off;\n        proxy_cache off;\n        proxy_read_timeout 1h;"}[kind]
        body = (f"location {location} {{\n        proxy_pass http://{backend};\n        proxy_http_version 1.1;\n"
                "        proxy_set_header Host $host;\n        proxy_set_header X-Forwarded-Proto $scheme;\n"
                f"        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        {options}\n    }}")
    else:
        raise ValueError("Kiểu website không hợp lệ.")
    options = []
    if params.get("gzip"):
        options += ["gzip on;", "gzip_types text/plain text/css application/json application/javascript;"]
    if params.get("brotli"):
        options += ["brotli on;"]
    if params.get("allow_ips"):
        import ipaddress
        for network in params["allow_ips"].split(","):
            options.append(f"allow {ipaddress.ip_network(network.strip(),strict=False)};")
        options.append("deny all;")
    if params.get("auth_file"):
        auth_file = params["auth_file"]
        if not re.fullmatch(r"/etc/nginx/[A-Za-z0-9_./-]+", auth_file) or ".." in auth_file.split("/") or not Path(auth_file).is_file():
            raise ValueError("Chọn tệp htpasswd đang có dưới /etc/nginx.")
        options += ['auth_basic "Restricted";',f"auth_basic_user_file {auth_file};"]
    if params.get("cors"):
        origin = params["cors"]
        if not re.fullmatch(r"\*|https?://[A-Za-z0-9.-]+(?::\d+)?", origin):
            raise ValueError("CORS origin không hợp lệ.")
        options.append(f'add_header Access-Control-Allow-Origin "{origin}" always;')
    for line in params.get("headers","").splitlines():
        key,separator,value = line.partition(":")
        if not separator or not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*",key) or not re.fullmatch(r"[A-Za-z0-9 ./_:+,=-]+",value):
            raise ValueError("Header cần có dạng Tên: giá trị.")
        options.append(f'add_header {key} "{value.strip()}" always;')
    import hashlib
    zone = "zm_" + hashlib.sha256(domain.encode()).hexdigest()[:20]
    rate = params.get("rate",0)
    if rate:
        if type(rate) is not int or not 1<=rate<=10000:
            raise ValueError("Rate limit không hợp lệ.")
        prefix += f"limit_req_zone $binary_remote_addr zone={zone}:1m rate={rate}r/s;\n"
        options.append(f"limit_req zone={zone} burst=10 nodelay;")
    if params.get("cache"):
        if kind!="proxy":
            raise ValueError("Cache cần reverse proxy HTTP.")
        prefix += f"proxy_cache_path /var/cache/nginx/{zone} keys_zone={zone}:1m max_size=100m inactive=10m;\n"
        options.extend([f"proxy_cache {zone};","proxy_cache_valid 200 1m;"])
    if options:
        body = "\n    ".join([*options,body])
    listen = "80 http2" if kind == "gRPC" else "80"
    return MARKER + prefix + f"server {{\n    listen {listen};\n    server_name {' '.join(names)};\n    {body}\n}}\n"


def create_websites(rows, root):
    directory = root / "conf.d"
    if not directory.is_dir():
        raise ValueError("Cần cài Nginx trước.")
    files = {}
    domains = set()
    for row in rows:
        domain = row["domain"]
        validate_domain(domain)
        if row.get("kind") == "raw":
            content = (row.get("raw_conf") or "").strip() + "\n"
            if not content.strip():
                raise ValueError("Nhập nội dung cấu hình Nginx.")
        else:
            content = website_config(domain, row["port"], row)
        if row.get("kind","proxy")=="proxy" and not row.get("backend") and probe(f"http://127.0.0.1:{row['port']}",domain)=="unreachable":
            raise ValueError(domain + ": upstream chưa phản hồi. Kiểm tra cổng ứng dụng.")
        for name in [domain, *row.get("names", [])]:
            if name in domains:
                raise ValueError("Tên miền trùng trong danh sách: " + name)
            domains.add(name)
        save_dir = row.get("save_dir") or "conf.d"
        raw_name = Path((row.get("conf_name") or "").strip()).name
        if raw_name:
            if not re.fullmatch(r"[A-Za-z0-9._-]+", raw_name):
                raise ValueError("Tên file .conf không hợp lệ.")
            if not raw_name.endswith(".conf"):
                raw_name += ".conf"
        if save_dir == "sites-available":
            sa_dir = root / "sites-available"
            se_dir = root / "sites-enabled"
            sa_dir.mkdir(parents=True, exist_ok=True)
            se_dir.mkdir(parents=True, exist_ok=True)
            fname = raw_name or (domain + ".conf")
            files[sa_dir / fname] = (content, se_dir / fname)
        else:
            fname = raw_name or ("zm-" + domain + ".conf")
            files[directory / fname] = (content, None)
    with (root / ".zm-vps.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        dump = command(["nginx", "-T"])
        for words, _ in walk_directives(nginx_blocks(dump)):
            if words[0]=="server_name":
                conflicts=domains.intersection(name.lower() for name in words[1:])
                if conflicts:
                    raise ValueError("Domain đã được sử dụng: " + ", ".join(sorted(conflicts)))
        for path in files:
            if any(os.path.lexists(p) for p in (path,root/"zm-disabled"/path.name)):
                raise ValueError("Tệp đã tồn tại: " + path.name)
        created = []
        try:
            for path, (content, link) in files.items():
                atomic_write(path, content)
                created.append(path)
                if link is not None and not os.path.lexists(link):
                    link.symlink_to(path)
                    created.append(link)
            command(["nginx","-t"])
            command(["systemctl","reload","nginx"])
        except Exception:
            for path in created:
                path.unlink(missing_ok=True)
            command(["nginx","-t"])
            command(["systemctl","reload","nginx"],check=False)
            raise
    return {"websites":[row["domain"] for row in rows]}


def nginx_site(domain, port, operation="save", params=None):
    validate_domain(domain)
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("Cổng không hợp lệ.")
    root = Path("/etc/nginx")
    directory = root / "conf.d"
    if not directory.is_dir():
        raise ValueError("Cần cài Nginx trước.")
    path = directory / ("zm-" + domain + ".conf")
    content = website_config(domain, port, params or {})
    upstream = f"http://127.0.0.1:{port}"
    if operation in {"save", "create", "edit"} and not (params or {}).get("backend") and (params or {}).get("kind", "proxy") == "proxy" and probe(upstream, domain) == "unreachable":
        raise ValueError("Upstream chưa phản hồi. Kiểm tra cổng ứng dụng.")
    with (root / ".zm-vps.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        disabled = root / "zm-disabled" / path.name
        for candidate in (path, disabled):
            if candidate.is_symlink() or (candidate.exists() and not candidate.read_text().startswith(MARKER)):
                raise ValueError("Tệp cấu hình đang do công cụ khác quản lý.")
        if path.exists() and disabled.exists():
            raise ValueError("Site có hai bản cấu hình. Kiểm tra VPS.")
        source = disabled if disabled.exists() else path
        old = source.read_text() if source.exists() else None
        revision = (params or {}).get("revision")
        if revision:
            import hashlib
            if old is None or hashlib.sha256(old.encode()).hexdigest() != revision:
                raise ValueError("Cấu hình đã thay đổi. Tải lại website trước khi tiếp tục.")
        if operation == "create" and old is not None:
            raise ValueError("Domain đã tồn tại.")
        if operation not in {"create", "save"} and old is None:
            raise ValueError("Site không còn tồn tại.")
        destination = source
        if operation == "disable":
            disabled.parent.mkdir(mode=0o700, exist_ok=True)
            destination, content = disabled, old
        elif operation == "enable":
            destination, content = path, old
        elif operation == "delete":
            content = None
        elif operation == "renew-enable":
            if not old or "ssl_certificate " not in old:
                raise ValueError("Site chưa cấu hình SSL.")
            return {"domain": domain, "renewal": True, **enable_certbot_renewal()}
        elif operation == "renew-test":
            if source == disabled or "ssl_certificate " not in old:
                raise ValueError("Cần site HTTPS đang bật để thử gia hạn.")
            event("Certbot · Kiểm tra gia hạn · " + domain)
            command(["certbot", "renew", "--dry-run", "--cert-name", "zm-" + domain], timeout=600)
            return {"domain": domain, "renewal_test": "ok"}
        elif operation == "certificate":
            if source == disabled:
                raise ValueError("Bật site trước khi cấp chứng chỉ.")
            content = old
        elif operation not in {"create", "edit", "save"}:
            raise ValueError("Thao tác site không hợp lệ.")
        elif old and operation in {"save", "edit"} and "proxy_pass " in old:
            content = re.sub(r"proxy_pass http://127\.0\.0\.1:\d+;", f"proxy_pass {upstream};", old)
        existing = command(["nginx", "-T"])
        other = re.sub(
            r"(?ms)^# configuration file "
            + re.escape(str(path))
            + r":\n.*?(?=^# configuration file |\Z)",
            "",
            existing,
        )
        for names in re.findall(r"(?m)^\s*server_name\s+([^;]+);", other):
            if destination == path and content is not None and set([domain, *((params or {}).get("names",[]) if operation=="create" else [])]).intersection(names.lower().split()):
                raise ValueError("Domain đã có cấu hình Nginx khác.")
        if operation == "certificate":
            if "    listen 80;\n" not in content and "ssl_certificate " not in content:
                raise ValueError("Cấu hình listener này cần thiết lập TLS riêng.")
            cert = issue_certificate(domain, params)
            if "ssl_certificate " not in content:
                proto = " http2" if (params or {}).get("http2") else ""
                tls = (f"    listen 443 ssl{proto};\n    ssl_certificate {cert}/fullchain.pem;\n"
                       f"    ssl_certificate_key {cert}/privkey.pem;\n")
                if (params or {}).get("force_https"):
                    tls += '    if ($scheme = http) { return 301 https://$host$request_uri; }\n'
                if (params or {}).get("http3"):
                    tls += "    listen 443 quic;\n    add_header Alt-Svc 'h3=\":443\"; ma=86400';\n"
                content = content.replace("    listen 80;\n", "    listen 80;\n" + tls, 1)
        if old != content or source != destination:
            if old is not None:
                backup = root / "zm-backups"
                backup.mkdir(mode=0o700, exist_ok=True)
                (backup / f"{domain}-{time.time_ns()}.conf").write_text(old)
            if source != destination:
                os.replace(source, destination)
            elif content is None:
                source.unlink()
            else:
                atomic_write(source, content)
            try:
                command(["nginx", "-t"])
                command(["systemctl", "reload", "nginx"])
            except Exception:
                if source != destination:
                    os.replace(destination, source)
                elif old is None:
                    source.unlink()
                else:
                    atomic_write(source, old)
                command(["nginx", "-t"])
                command(["systemctl", "reload", "nginx"], check=False)
                raise
        if operation == "certificate":
            try:
                renewal = enable_certbot_renewal()
                event("Certbot · Tự gia hạn · " + renewal["detail"])
            except ValueError:
                pass
    if operation not in {"save", "create", "edit"} or destination == disabled:
        return {"domain": domain, "operation": operation, "enabled": path.exists()}
    try:
        dns = sorted({addr[4][0] for addr in socket.getaddrinfo(domain, None)})
    except OSError:
        dns = []
    return {
        "domain": domain,
        "upstream": probe(upstream, domain),
        "dns": dns,
        "http": probe("http://" + domain, domain),
        "https": probe("https://" + domain, domain),
    }


def native_names(entry, apt):
    return entry.get("apt" if apt else "dnf", [])


def package_version(entry, apt, user):
    if "probe" in entry:
        result = recipe_process(entry["probe"], entry.get("user"), user, 30, errexit=False)
        if result.returncode < 0 or result.returncode == 126 or re.search(r"Permission denied|Failed to connect to bus|Access denied", result.stderr, re.I):
            raise ValueError("Không đủ quyền hoặc dịch vụ kiểm tra chưa sẵn sàng.")
        out = result.stdout.strip().splitlines()[-1][:120] if not result.returncode and result.stdout.strip() else ""
        if not out and entry.get("user") and user != "root" and os.geteuid() == 0:
            root_res = recipe_process(entry["probe"], True, "root", 30, errexit=False)
            if not root_res.returncode and root_res.stdout.strip():
                out = root_res.stdout.strip().splitlines()[-1][:120]
        return out
    for name in native_names(entry, apt):
        if apt:
            result = subprocess.run(["dpkg-query", "-W", "-f=${db:Status-Abbrev} ${Version}", name], capture_output=True, text=True)
            if result.returncode not in (0, 1):
                raise ValueError("Không đọc được trạng thái dpkg.")
            data = result.stdout.split()
            if len(data) == 2 and data[0] in {"ii", "hi"}:
                return data[1]
        else:
            result = subprocess.run(["rpm", "-q", "--qf", "%{VERSION}-%{RELEASE}", name], capture_output=True, text=True)
            if result.returncode == 0:
                return result.stdout.strip()
            if result.returncode != 1 or result.stderr.strip():
                raise ValueError("Không đọc được trạng thái RPM.")
        found = shutil.which(name, path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin")
        if found:
            return found
    return ""


def recipe_process(script, as_user, user, timeout, errexit=True):
    import pwd
    flags = "-ec" if errexit else "-c"
    extra_path = "/usr/local/sbin:/usr/local/bin:/snap/bin"
    args = ["env", f"PATH={extra_path}:" + os.environ.get("PATH", ""), "bash", flags, script]
    if as_user:
        account = pwd.getpwnam(user)
        prefix = f'export NVM_DIR="$HOME/.nvm"; if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh"; fi; export PATH="$HOME/.bun/bin:$HOME/.local/bin:{extra_path}:$PATH"; '
        args = ["env", "HOME=" + account.pw_dir, "USER=" + user, "LOGNAME=" + user, "bash", flags, prefix + script]
        if os.geteuid()!=account.pw_uid:
            args=["runuser","-u",user,"--",*args]
    return subprocess.run(args,text=True,capture_output=True,timeout=timeout)


def setup_units(item,user):
    if item=="yt-nightly-timer":
        directory=Path("/etc/systemd/system")
        units={"zm-yt-nightly.service":"[Unit]\nDescription=Update yt-dlp nightly\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/yt-dlp-nightly --update-to nightly\n",
               "zm-yt-nightly.timer":"[Unit]\nDescription=Check yt-dlp nightly at 08:00\n[Timer]\nOnCalendar=*-*-* 08:00:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n"}
        for name,content in units.items():
            path=directory/name
            if path.exists() and path.read_text()!=content:
                raise ValueError("Unit đã có cấu hình khác: "+name)
        for name,content in units.items():
            atomic_write(directory/name,content)
            (directory/name).chmod(0o644)
        command(["systemctl","daemon-reload"])
    if item=="pm2-startup":
        import pwd
        account=pwd.getpwnam(user)
        output=recipe_process('command -v pm2; command -v node',True,user,30)
        paths=output.stdout.strip().splitlines()
        if len(paths)!=2 or not all(re.fullmatch(r"/[A-Za-z0-9_./+-]+",x) for x in [*paths,account.pw_dir]):
            raise ValueError("Không xác định được Node và PM2 của tài khoản.")
        if not re.fullmatch(r"[A-Za-z0-9_-]+",user):
            raise ValueError("Tên tài khoản systemd không hợp lệ.")
        name=f"pm2-{user}.service"
        unit=Path("/etc/systemd/system")/name
        if not unit.exists():
            content=(f"[Unit]\nDescription=PM2 ({user})\nAfter=network.target\n[Service]\nUser={user}\nType=forking\n"
                     f"Environment=HOME={account.pw_dir}\nEnvironment=PATH={Path(paths[1]).parent}:/usr/local/bin:/usr/bin:/bin\n"
                     f"PIDFile={account.pw_dir}/.pm2/pm2.pid\nExecStart={paths[0]} resurrect\nExecStop={paths[0]} kill\n"
                     "[Install]\nWantedBy=multi-user.target\n")
            atomic_write(unit,content)
            unit.chmod(0o644)
            command(["systemctl","daemon-reload"])
        command(["systemctl","enable",name])


def install_catalog(requested, entries, apt, dnf, user):
    if not apt and not dnf:
        raise ValueError("Máy cần APT hoặc DNF.")
    if not requested or any(item not in entries for item in requested):
        raise ValueError("Chọn phần mềm trong danh mục.")
    ordered=[]
    def add(item):
        if item not in ordered:
            for dep in entries[item].get("deps",[]):
                add(dep)
            ordered.append(item)
    for item in requested:
        add(item)
    refreshed=False
    for item in ordered:
        entry=entries[item]
        if package_version(entry,apt,user):
            event("Đã có · "+item)
            continue
        event("Đang cài · "+item)
        if "install" in entry:
            setup_units(item,user)
            result=recipe_process(entry["install"],entry.get("user"),user,1200)
            if result.returncode:
                tail = ((result.stderr or "") + "\n" + (result.stdout or "")).strip()[-350:]
                raise ValueError(f"Cài {item} thất bại (exit {result.returncode})" + (f": {tail}" if tail else "."))
        else:
            choices=native_names(entry,apt)
            if not choices:
                raise ValueError(f"{item} chưa có ánh xạ cho DNF.")
            if apt:
                if not refreshed:
                    command([apt,"-o","APT::Update::Error-Mode=any","update"],timeout=600)
                    refreshed=True
                name=next((name for name in choices if re.search(r"Candidate:\s+(?!\(none\))\S+",command(["apt-cache","policy",name],False))),None)
                if not name:
                    raise ValueError(f"Kho APT chưa cung cấp {item}.")
                guard=["--no-remove"]
                if item=="libavcodec-extra":
                    plan=command([apt,"--simulate","install",name])
                    removed=re.findall(r"^Remv (\S+)",plan,re.M)
                    if removed and all(re.fullmatch(r"libavcodec[0-9]+(?::[a-z0-9]+)?",pkg) for pkg in removed):
                        event("Thay thư viện codec bằng bản extra · "+", ".join(removed))
                        guard=[]
                elif item=="ufw":
                    plan=command([apt,"--simulate","install",name])
                    removed=re.findall(r"^Remv (\S+)",plan,re.M)
                    if removed and all(pkg in {"iptables-persistent","netfilter-persistent"} for pkg in removed):
                        event("Thay thế gói xung đột firewall · "+", ".join(removed))
                        guard=[]
                command([apt,"-o","DPkg::Lock::Timeout=120",*guard,"install","-y",name],timeout=1200)
            else:
                name=choices[0]
                if len(choices)>1:
                    candidate=next((n for n in choices if n in command([dnf,"-q","repoquery","--available","--qf","%{name}",n],False).splitlines()),None)
                    if not candidate:
                        raise ValueError("Kho DNF chưa cung cấp "+item+".")
                    name=candidate
                command([dnf,"install","-y",name],timeout=1200)
        if not package_version(entry,apt,user):
            raise ValueError("Chưa xác minh được sau khi cài · "+item)
        event("Hoàn tất · "+item)
    return {"packages":requested}


UNINSTALL_RECIPES={
    "bun":("rm -rf \"$HOME/.bun\"",True),
    "nvm":("rm -rf \"$HOME/.nvm\"",True),
    "node-lts":("rm -rf \"$HOME/.nvm/versions/node\"",True),
    "pm2":("npm uninstall -g pm2",True),
    "yarn":("npm uninstall -g yarn",True),
    "fast-cli":("npm uninstall -g fast-cli",True),
    "pm2-logrotate":("pm2 uninstall pm2-logrotate",True),
    "python-env":("rm -rf \"$HOME/.venvs/zm-vps\"",True),
    "yt-dlp":("rm -f /usr/local/bin/yt-dlp",False),
    "yt-dlp-nightly":("rm -f /usr/local/bin/yt-dlp \"$HOME/.local/bin/yt-dlp\"",True),
    "bench-sh":("rm -f \"$HOME/.local/bin/bench.sh\"",True),
    "docker-engine":("apt-get -o DPkg::Lock::Timeout=120 remove -y docker-ce docker-ce-cli containerd.io",False),
    "docker-compose":("apt-get -o DPkg::Lock::Timeout=120 remove -y docker-compose-plugin",False),
    "go-backports":("apt-get -o DPkg::Lock::Timeout=120 remove -y golang-go",False),
    "speedtest":("apt-get -o DPkg::Lock::Timeout=120 remove -y speedtest",False),
    "pm2-startup":("pm2 unstartup systemd -u \"$USER\" --hp \"$HOME\" || true",True),
    "docker-service":("systemctl disable --now docker.service docker.socket",False),
    "redis-server-service":("systemctl disable --now redis-server.service",False),
    "vnstat-service":("systemctl disable --now vnstat.service",False),
    "fail2ban-service":("systemctl disable --now fail2ban.service",False),
    "nginx-service":("systemctl disable --now nginx.service",False),
    "cron-service":("systemctl disable --now cron.service",False),
    "timezone-vn":("timedatectl set-timezone UTC",False),
    "certbot-venv":("rm -rf /opt/certbot /usr/local/bin/certbot",False),
    "certbot-snap":("snap remove certbot",False),
    "certbot-timer":("systemctl disable --now certbot.timer",False),
    "yt-nightly-timer":("systemctl disable --now zm-yt-nightly.timer",False),
}


def uninstall_catalog(requested,entries,apt,dnf,user):
    if not apt and not dnf:
        raise ValueError("Chỉ hỗ trợ gỡ phần mềm trên Ubuntu/Debian hoặc RHEL/CentOS.")
    protected={"python3","ca-certificates","openssl"}
    for item in requested:
        if item in protected:
            raise ValueError(f"Không cho phép gỡ gói hệ thống quan trọng: {item}")
        if item not in entries:
            raise ValueError("Gói không có trong danh mục: "+item)
    for item in requested:
        entry=entries[item]
        if not package_version(entry,apt,user):
            event("Chưa cài · "+item)
            continue
        event("Đang gỡ · "+item)
        if item in UNINSTALL_RECIPES:
            script,as_user=UNINSTALL_RECIPES[item]
            result=recipe_process(script,as_user,user,600)
            if result.returncode:
                tail=((result.stderr or "")+"\n"+(result.stdout or "")).strip()[-350:]
                raise ValueError(f"Gỡ {item} thất bại (exit {result.returncode})" + (f": {tail}" if tail else "."))
        elif "install" in entry:
            raise ValueError(f"Gói {item} chưa hỗ trợ gỡ tự động.")
        else:
            choices=native_names(entry,apt)
            removed=False
            for name in choices:
                if apt and command(["dpkg-query","-W","-f=${db:Status-Abbrev}",name],False).strip() in {"ii","hi"}:
                    command([apt,"-o","DPkg::Lock::Timeout=120","remove","-y",name],timeout=600)
                    removed=True
                elif dnf and command(["rpm","-q",name],False):
                    command([dnf,"remove","-y",name],timeout=600)
                    removed=True
            if not removed:
                raise ValueError(f"Không tìm thấy gói hệ thống để gỡ: {item}")
        event("Đã gỡ · "+item)
    return {"packages":requested}


MAINTENANCE = {
    "update-index":"Cập nhật danh mục gói",
    "upgrade-packages":"Nâng cấp các gói hệ thống",
    "refresh-ca":"Làm mới kho chứng chỉ CA",
    "repair-ca":"Cài lại OpenSSL và chứng chỉ CA",
}


def package_maintenance(task,apt,dnf):
    if task not in MAINTENANCE or not (apt or dnf):
        raise ValueError("Thao tác bảo trì chưa được hỗ trợ.")
    event(MAINTENANCE[task])
    if task in {"update-index","upgrade-packages","repair-ca"}:
        command([apt,"-o","APT::Update::Error-Mode=any","update"] if apt else [dnf,"makecache"],timeout=900)
    if task=="upgrade-packages":
        command([apt,"-o","DPkg::Lock::Timeout=120","--no-remove","-y","upgrade"] if apt else [dnf,"-y","upgrade"],timeout=3600)
    if task=="repair-ca":
        command([apt,"-y","--no-remove","install","--reinstall","openssl","ca-certificates"] if apt else [dnf,"-y","reinstall","openssl","ca-certificates"],timeout=1200)
    if task in {"refresh-ca","repair-ca"}:
        command(["update-ca-certificates"] if apt else ["update-ca-trust","extract"],timeout=180)
    return {"operation":task}


def package_query(scope, query, offset, apt, dnf, limit=30):
    if not apt and not dnf:
        raise ValueError("VPS cần APT hoặc DNF.")
    if scope == "installed":
        if apt:
            lines = command(["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${binary:Package}\t${Version}\\n"]).splitlines()
            pairs = [line.split("\t")[1:] for line in lines if line[1:2]=="i" and line.count("\t")==2]
        else:
            pairs = [line.split("\t") for line in command(["rpm","-qa","--qf","%{NAME}.%{ARCH}\t%{VERSION}-%{RELEASE}\\n"]).splitlines() if "\t" in line]
    elif scope == "repository":
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.+_-]{0,99}", query):
            raise ValueError("Nhập tên hoặc tiền tố gói hợp lệ.")
        if apt:
            pairs = [(name,"") for name in command(["apt-cache","pkgnames",query]).splitlines()]
        else:
            lines = command(["dnf","-q","repoquery","--available","--latest-limit","1","--qf","%{name}\t%{evr}",query+"*"], timeout=120)
            pairs = [line.split("\t") for line in lines.splitlines() if "\t" in line]
    else:
        raise ValueError("Nguồn gói không hợp lệ.")
    matches = sorted({(name,version) for name,version in pairs if query.casefold() in name.casefold()})
    return {"total":len(matches),"items":[{"name":n,"version":v} for n,v in matches[offset:offset+limit]]}


def native_plan(name, apt, dnf):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.+_-]{0,99}",name):
        raise ValueError("Tên gói không hợp lệ.")
    if apt:
        policy = command(["apt-cache","policy",name])
        candidate = re.search(r"^\s*Candidate:\s*(\S+)",policy,re.M)
        if not candidate or candidate[1]=="(none)":
            raise ValueError("Kho APT không có phiên bản cài được.")
        target = name+"="+candidate[1]
        args = ["apt-get","--no-remove","install",target]
        summary = command(["apt-get","-s",*args[1:]])
    elif dnf:
        result = command(["dnf","-q","repoquery","--available","--latest-limit","1","--arch",platform.machine()+",noarch","--qf","%{name}\t%{name}-%{epoch}:%{version}-%{release}.%{arch}",name])
        targets = sorted(line.split("\t")[1] for line in result.splitlines() if line.startswith(name+"\t"))
        if not targets:
            raise ValueError("Kho DNF không có phiên bản cài được.")
        target = targets[0]
        args = ["dnf","install",target]
        summary = "DNF · "+target
    else:
        raise ValueError("VPS cần APT hoặc DNF.")
    return {"target":target,"summary":summary}, args


PROTECTED_UNIT_EXACT = {
    "ssh.service", "sshd.service", "dbus.service", "dbus-broker.service",
    "NetworkManager.service", "polkit.service", "rsyslog.service", "syslog.service",
    "blk-availability.service", "finalrd.service", "rc-local.service",
}
PROTECTED_UNIT_PREFIXES = (
    "systemd-", "network", "netplan", "udev", "getty@", "serial-getty@",
    "user@", "cloud-init", "waagent", "oracle-cloud-agent",
    "plymouth", "console-", "kmod", "lvm2", "multipathd", "dm-event",
    "apt-daily", "dpkg-db-backup", "e2scrub", "fstrim", "man-db", "motd-news",
    "emergency", "rescue", "ua-timer", "ubuntu-advantage",
)


APP_UNIT_EXACT = {
    "nginx.service", "mongod.service", "redis-server.service", "redis.service",
    "docker.service", "containerd.service", "fail2ban.service", "vnstat.service",
    "certbot.timer", "certbot.service", "zm-yt-nightly.timer", "zm-yt-nightly.service",
    "mongodb-manager.service", "vps-manager.service",
}
APP_UNIT_PREFIXES = ("pm2-",)


def _is_protected_unit(unit):
    return unit in PROTECTED_UNIT_EXACT or unit.startswith(PROTECTED_UNIT_PREFIXES)


def _unit_category(unit):
    if _is_protected_unit(unit):
        return "system"
    if unit in APP_UNIT_EXACT or unit.startswith(APP_UNIT_PREFIXES):
        return "app"
    return "system"


def _run_systemctl(args):
    proc = subprocess.run(
        ["systemctl", *args],
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, "LC_ALL": "C"},
    )
    if proc.returncode and proc.stderr.strip():
        raise ValueError(proc.stderr.strip().splitlines()[0][:200])
    return proc.stdout


def service_query():
    if not shutil.which("systemctl"):
        raise ValueError("VPS không có systemd (systemctl).")
    files_out = _run_systemctl(["list-unit-files", "--plain", "--no-legend", "--no-pager"])
    units_out = _run_systemctl(["list-units", "--all", "--plain", "--no-legend", "--no-pager"])
    records = {}
    for raw in files_out.splitlines():
        parts = raw.split()
        if len(parts) < 2:
            continue
        name, state = parts[0], parts[1]
        if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.(service|timer)", name) or "@." in name:
            continue
        records[name] = {
            "name": name,
            "kind": "timer" if name.endswith(".timer") else "service",
            "category": _unit_category(name),
            "enabled": state,
            "active": "inactive",
            "sub": "dead",
            "description": "",
            "pid": None,
            "memory_bytes": None,
            "protected": _is_protected_unit(name),
        }
    for raw in units_out.splitlines():
        line = raw.lstrip("● ").strip()
        parts = line.split(None, 4)
        if len(parts) < 4:
            continue
        name, _load, active, sub = parts[:4]
        desc = parts[4] if len(parts) > 4 else ""
        if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.(service|timer)", name) or "@." in name:
            continue
        entry = records.setdefault(name, {
            "name": name,
            "kind": "timer" if name.endswith(".timer") else "service",
            "category": _unit_category(name),
            "enabled": "transient",
            "active": active,
            "sub": sub,
            "description": desc,
            "pid": None,
            "memory_bytes": None,
            "protected": _is_protected_unit(name),
        })
        entry["active"] = active
        entry["sub"] = sub
        if desc:
            entry["description"] = desc
    active_names = [u["name"] for u in records.values() if u["active"] == "active"][:80]
    if active_names:
        show_out = _run_systemctl(["show", *active_names, "--property=Id,MainPID,MemoryCurrent", "--no-pager"])
        for block in show_out.strip().split("\n\n"):
            props = {}
            for line in block.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    props[k] = v
            uid = props.get("Id", "")
            if uid not in records:
                continue
            pid_val = props.get("MainPID", "")
            if pid_val.isdigit() and int(pid_val) > 0:
                records[uid]["pid"] = int(pid_val)
            mem_val = props.get("MemoryCurrent", "")
            if mem_val.isdigit():
                mem = int(mem_val)
                if 0 <= mem < (1 << 60):
                    records[uid]["memory_bytes"] = mem
    items = sorted(
        records.values(),
        key=lambda r: (
            0 if r["category"] == "app" else 1,
            0 if r["active"] == "active" else 1 if r["active"] == "failed" else 2,
            -(r["memory_bytes"] or 0),
            r["name"],
        ),
    )
    return {"items": items}


def service_control(unit, operation):
    if not shutil.which("systemctl"):
        raise ValueError("VPS không có systemd (systemctl).")
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.(service|timer)", unit) or "@." in unit:
        raise ValueError("Tên dịch vụ không hợp lệ.")
    if operation not in {"start", "stop", "restart", "enable", "disable"}:
        raise ValueError("Thao tác dịch vụ không hợp lệ.")
    if operation in {"stop", "disable"} and _is_protected_unit(unit):
        raise ValueError("Không thể tắt hoặc vô hiệu hóa dịch vụ hệ thống quan trọng: " + unit)
    event(f"systemctl {operation} {unit}")
    if operation == "enable":
        command(["systemctl", "enable", "--now", unit], timeout=60)
    elif operation == "disable":
        command(["systemctl", "disable", "--now", unit], timeout=60)
    else:
        command(["systemctl", operation, unit], timeout=60)
    return {"unit": unit, "operation": operation}


def execute(action, p):
    apt = shutil.which("apt-get")
    dnf = shutil.which("dnf")
    packages = p["catalog"]
    if action == "service-query":
        return service_query()
    if action == "service-control":
        return service_control(p.get("name", ""), p.get("operation", ""))
    if action == "package-query":
        return package_query(p["scope"],p["query"],p["offset"],apt,dnf,p.get("limit",30))
    if action in {"package-plan","native-install"}:
        plan,args=native_plan(p["name"],apt,dnf)
        if action=="package-plan":
            return plan
        if plan["target"]!=p["target"]:
            raise ValueError("Phiên bản trong kho đã đổi. Mở lại kế hoạch.")
        event(plan["target"])
        command([args[0],"-y",*args[1:]],timeout=900)
        return {"installed":plan["target"]}
    if action == "pm2":
        # jlist may include secrets. Return only process names and numeric ports.
        home = Path.home()
        if not (home / ".pm2/pm2.pid").is_file():
            return []
        try:
            pid = int((home / ".pm2/pm2.pid").read_text().strip())
            if pid < 1 or not Path(f"/proc/{pid}").exists():
                return []
        except (ValueError, OSError):
            return []
        bins = [
            node.parent
            for node in sorted(
                (home / ".nvm/versions/node").glob("*/bin/node"), reverse=True
            )
        ]
        os.environ["PATH"] = os.pathsep.join(
            [os.environ["PATH"], str(home / ".bun/bin"), *map(str, bins)]
        )
        if not shutil.which("pm2"):
            return []
        rows = json.loads(command(["pm2", "jlist"]))
        result = []
        for row in rows:
            env = row.get("pm2_env") or {}
            port = str(env.get("PORT") or (env.get("env") or {}).get("PORT") or "")
            if (
                env.get("status") == "online"
                and port.isdigit()
                and 1 <= int(port) <= 65535
            ):
                result.append({"name": row["name"], "port": int(port)})
        return result
    def _read_metrics():
        disk = shutil.disk_usage("/")
        meminfo = dict((key,int(value)*1024) for key,value in
                       re.findall(r"^(MemTotal|MemAvailable):\s+(\d+) kB",Path("/proc/meminfo").read_text(),re.M))
        top_processes = []
        ps = subprocess.run(
            ["ps", "-eo", "pid=,user=,%cpu=,%mem=,rss=,time=,args=", "--sort=-%cpu,-%mem,-rss"],
            capture_output=True, text=True,
        )
        if ps.returncode == 0:
            self_pid = os.getpid()
            for line in ps.stdout.splitlines():
                parts = line.split(None, 6)
                if len(parts) == 7:
                    try:
                        pid = int(parts[0])
                        cmd = parts[6].strip()
                        if pid == self_pid or "host_worker.py" in cmd or "ps -eo pid=,user=" in cmd:
                            continue
                        exe = cmd.split()[0].strip("[]") if cmd else ""
                        top_processes.append({
                            "pid": pid,
                            "user": parts[1],
                            "cpu": float(parts[2]),
                            "mem": float(parts[3]),
                            "rss": int(parts[4]) * 1024,
                            "time": parts[5],
                            "name": Path(exe).name or cmd[:24],
                            "cmd": cmd[:180],
                        })
                    except ValueError:
                        continue
                    if len(top_processes) >= 5:
                        break
        return {
            "cpu": os.cpu_count(),
            "disk_free": disk.free,
            "disk_total": disk.total,
            "disk_used": disk.used,
            "memory": str(meminfo["MemTotal"]//1024)+" kB",
            "memory_total": meminfo["MemTotal"],
            "memory_available": meminfo.get("MemAvailable"),
            "uptime_seconds": int(float(Path("/proc/uptime").read_text().split()[0])),
            "load_average": list(os.getloadavg()),
            "top_processes": top_processes,
        }
    if action == "metrics":
        return _read_metrics()
    if action == "overview":
        os_info = Path("/etc/os-release").read_text()
        name = re.search(r'^PRETTY_NAME="?(.*?)"?$', os_info, re.M)
        metrics = _read_metrics()
        versions = {}
        probe_errors = {}
        if apt or dnf:
            dpkg_map = {}
            if apt:
                dq = subprocess.run(["dpkg-query", "-W", "-f=${Package}\t${db:Status-Abbrev}\t${Version}\n"], capture_output=True, text=True)
                if dq.returncode in (0, 1):
                    for line in dq.stdout.splitlines():
                        parts = line.split("\t")
                        if len(parts) == 3 and parts[1].strip() in {"ii", "hi"}:
                            dpkg_map[parts[0]] = parts[2]
            from concurrent.futures import ThreadPoolExecutor
            custom = {}
            for pkg, entry in p.get("entries", {}).items():
                if "probe" not in entry and apt:
                    ver = next((dpkg_map[n] for n in native_names(entry, apt) if n in dpkg_map), "")
                    if not ver:
                        ver = next((shutil.which(n, path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin") for n in native_names(entry, apt) if shutil.which(n, path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin")), "")
                    versions[pkg] = ver
                else:
                    custom[pkg] = entry
            def _probe_one(item):
                k, e = item
                try:
                    return k, package_version(e, apt, p["login_user"]), None
                except (subprocess.SubprocessError, OSError, ValueError) as exc:
                    return k, None, str(exc)[:200]
            if custom:
                with ThreadPoolExecutor(max_workers=8) as pool:
                    for k, ver, err in pool.map(_probe_one, custom.items()):
                        if err is not None:
                            probe_errors[k] = err
                        else:
                            versions[k] = ver
        return {
            "host": socket.gethostname(),
            "os": name[1] if name else platform.system(),
            "arch": platform.machine(),
            "kernel": platform.release(),
            "manager": "apt" if apt else "dnf" if dnf else "",
            "packages": versions,
            "probe_errors": probe_errors,
            "nginx": command(["systemctl", "is-active", "nginx"], False)
            if shutil.which("systemctl")
            else "unknown",
            **metrics,
        }
    if action == "repair-link":
        root = Path("/etc/nginx")
        with (root/".zm-vps.lock").open("a") as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            record = next((link for link in discover_sites(root)["broken"] if link["id"]==p["file_id"]),None)
            if not record:
                raise ValueError("Liên kết đã thay đổi.")
            path = Path(record["path"])
            backup = root/"zm-backups"/("link-"+str(time.time_ns()))
            backup.mkdir(parents=True,mode=0o700)
            (backup/path.name).symlink_to(record["target"])
            path.unlink()
            try:
                command(["nginx","-t"])
                command(["systemctl","reload","nginx"])
            except Exception:
                path.symlink_to(record["target"])
                raise
            return {"removed":record["path"],"backup":str(backup/path.name)}
    if action in {"detail","logs","apply","diff","check","lifecycle","ssl-status","external-certificate","renew-ssl","renew-test"}:
        return website_file(action,p,Path("/etc/nginx"))
    if action == "inventory":
        return discover_sites(Path("/etc/nginx"))
    if action == "sites":
        return site_inventory(Path("/etc/nginx"))
    if action == "site":
        if p.get("operation")=="create" and p.get("websites"):
            return create_websites(p["websites"],Path("/etc/nginx"))
        return nginx_site(p["domain"], p["port"], p.get("operation", "save"), p)
    if action=="maintain":
        return package_maintenance(p["operation"],apt,dnf)
    if action=="install":
        return install_catalog(p["packages"],p["entries"],apt,dnf,p["login_user"])
    if action=="uninstall":
        return uninstall_catalog(p["packages"],p["entries"],apt,dnf,p["login_user"])
    if action == "nginx-test":
        proc = subprocess.run(["nginx", "-t"], capture_output=True, text=True, timeout=30)
        out = ((proc.stderr or "") + "\n" + (proc.stdout or "")).strip()
        return {"ok": proc.returncode == 0, "output": out}
    if action == "nginx-reload":
        event("nginx -t && systemctl reload nginx")
        command(["nginx", "-t"])
        command(["systemctl", "reload", "nginx"])
        return {"reloaded": True}
    if action == "ssl-renew-enable":
        event("Bật tự động gia hạn SSL…")
        return {"renewal": True, **enable_certbot_renewal()}
    if action == "cloudflare-token":
        return save_cloudflare_token(p)
    if action == "ssl-renew-test":
        if not shutil.which("certbot"):
            raise ValueError("Cần cài Certbot trong Software Center trước.")
        event("Certbot · Kiểm tra gia hạn toàn bộ chứng chỉ…")
        command(["certbot", "renew", "--dry-run"], timeout=600)
        return {"renewal_test": "ok"}
    if action == "nginx-export":
        root = Path("/etc/nginx")
        inv = discover_sites(root)
        wanted = set(p.get("file_ids") or [])
        include_ssl = bool(p.get("include_ssl"))
        seen = set()
        exported = []
        for site in inv["sites"]:
            fid = site["file_id"]
            if (wanted and fid not in wanted) or fid in seen:
                continue
            seen.add(fid)
            src = Path(site["source"])
            if not src.is_file():
                continue
            item = {"filename": src.name, "in_conf_d": "/conf.d/" in str(src), "content": src.read_text(errors="replace"), "enabled": site["enabled"], "ssl": []}
            if include_ssl:
                cert_names = set(re.findall(r"/etc/letsencrypt/live/([^/\s;]+)/", item["content"]))
                for cname in cert_names:
                    cert_dir = Path("/etc/letsencrypt/live") / cname
                    fc, pk = cert_dir / "fullchain.pem", cert_dir / "privkey.pem"
                    if fc.exists() and pk.exists():
                        item["ssl"].append({"domain": cname, "fullchain": fc.read_text(), "privkey": pk.read_text()})
            exported.append(item)
        return {"sites": exported}
    if action == "nginx-import":
        if not shutil.which("nginx") and not Path("/etc/nginx").exists():
            raise ValueError("Nginx chưa được cài trên VPS đích. Cài Nginx trong Software Center trước.")
        root = Path("/etc/nginx")
        overwrite = bool(p.get("overwrite"))
        imported = []
        created_paths = []
        for item in p.get("sites") or []:
            name = Path(item["filename"]).name
            if not name or "/" in name or ".." in name:
                continue
            dest = (root / "conf.d" / name) if item.get("in_conf_d") else (root / "sites-available" / name)
            dest.parent.mkdir(parents=True, exist_ok=True)
            existed = dest.exists()
            if existed and not overwrite:
                imported.append(name + " (bỏ qua: đã tồn tại)")
                continue
            needed_certs = set(re.findall(r"/etc/letsencrypt/live/([^/\s;]+)/", item["content"]))
            for cert in item.get("ssl") or []:
                cdir = Path("/etc/letsencrypt/live") / Path(cert["domain"]).name
                cdir.mkdir(parents=True, exist_ok=True)
                atomic_write(cdir / "fullchain.pem", cert["fullchain"])
                atomic_write(cdir / "privkey.pem", cert["privkey"])
                os.chmod(cdir / "privkey.pem", 0o600)
            missing_certs = [c for c in needed_certs if not (Path("/etc/letsencrypt/live") / c / "fullchain.pem").exists()]
            if missing_certs:
                raise ValueError("Thiếu chứng chỉ SSL trên VPS nguồn/đích cho: " + ", ".join(missing_certs) + ". Hãy kiểm tra VPS nguồn hoặc bỏ tích SSL/cấp SSL lại.")
            event("Ghi " + str(dest))
            atomic_write(dest, item["content"])
            if not existed:
                created_paths.append(dest)
            if not item.get("in_conf_d") and item.get("enabled", True):
                link = root / "sites-enabled" / name
                link.parent.mkdir(parents=True, exist_ok=True)
                if not link.exists():
                    link.symlink_to(dest)
                    created_paths.append(link)
            imported.append(name)
        event("nginx -t && systemctl reload nginx")
        try:
            command(["nginx", "-t"])
            command(["systemctl", "reload", "nginx"])
        except Exception:
            for cp in reversed(created_paths):
                cp.unlink(missing_ok=True)
            raise
        if p.get("update_renewal") and p.get("token") and p.get("email") and _certbot_bin():
            save_cloudflare_token({"token": p["token"], "name": "default", "update_renewal": True})
            issued_any = False
            for item in p.get("sites") or []:
                certs = sorted(set(re.findall(r"/etc/letsencrypt/live/([^/\s;]+)/", item.get("content", ""))))
                domains = [
                    d for w, children in walk_directives(nginx_blocks(item.get("content", "")))
                    if w == ["server"]
                    for cw, _ in children if cw[0] == "server_name"
                    for d in cw[1:] if "." in d and not d.startswith("*")
                ]
                domains = list(dict.fromkeys(domains))
                if not certs or not domains:
                    continue
                for cname in certs:
                    if (LETSENCRYPT_DIR / "renewal" / f"{cname}.conf").is_file():
                        continue
                    live_dir = LETSENCRYPT_DIR / "live" / cname
                    backup_live = None
                    if live_dir.exists():
                        backup_live = LETSENCRYPT_DIR / "live" / f".{cname}.bak-{time.time_ns()}"
                        live_dir.rename(backup_live)
                    try:
                        issue_certificate(domains[0], {"method": "cloudflare", "email": p["email"], "token": p["token"], "names": domains[1:]}, cert_name=cname)
                        issued_any = True
                        if backup_live and backup_live.exists():
                            shutil.rmtree(backup_live, ignore_errors=True)
                    except Exception as exc:
                        if backup_live and backup_live.exists() and not live_dir.exists():
                            backup_live.rename(live_dir)
                        event(f"Cảnh báo cấp lại SSL ({cname}): {exc}")
            if issued_any:
                try:
                    renewal = enable_certbot_renewal()
                    event("Certbot · Tự gia hạn · " + renewal["detail"])
                except ValueError:
                    pass
                command(["nginx", "-t"])
                command(["systemctl", "reload", "nginx"])
        return {"imported": imported}
    raise ValueError("Thao tác không hợp lệ.")


def serve(request):
    try:
        print(
            json.dumps({"result": execute(request["action"], request["params"])}),
            flush=True,
        )
    except Exception as exc:
        print(json.dumps({"error": str(exc)}), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    serve(json.load(sys.stdin))
