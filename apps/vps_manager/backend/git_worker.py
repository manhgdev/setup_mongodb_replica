"""Git identity and outbound SSH keys for the connected Unix account."""
import base64
import contextlib
import fcntl
import hashlib
import json
import os
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

PROVIDERS = {
    "github.com": "+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
    "gitlab.com": "eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8",
    "bitbucket.org": "ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM",
}
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\Z")
BEGIN = "# BEGIN ZM Git aliases"
END = "# END ZM Git aliases"


def event(message):
    print(json.dumps({"event": message}), flush=True)


def command(*argv, secret="", env=None, timeout=30):
    return subprocess.run(argv, input=secret, capture_output=True, text=True, errors="replace",
                          start_new_session=True, timeout=timeout, env=dict(os.environ, LC_ALL="C",
                          SSH_ASKPASS_REQUIRE="never", **(env or {})))


def safe_name(name):
    if (not NAME.fullmatch(name) or name.lower().endswith(".pub") or
        name.lower().startswith(("authorized_keys", "known_hosts", "config")) or
        name.lower() in {"environment", "rc", "authorized_principals"}):
        raise ValueError("Tên key không hợp lệ.")
    return name


def directory(path):
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("Thư mục SSH không an toàn.")
    path.chmod(0o700)


def regular(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise ValueError("File SSH không an toàn.")
    return info


def public(path):
    if regular(path).st_size > 32768:
        raise ValueError("Public key quá dài.")
    line = path.read_text().strip()
    if "\n" in line:
        raise ValueError("Public key không hợp lệ.")
    parts = line.split()
    if len(parts) < 2 or not re.fullmatch(r"(ssh-|ecdsa-|sk-)[\w@.-]+", parts[0]):
        raise ValueError("Public key không hợp lệ.")
    blob = base64.b64decode(parts[1], validate=True)
    if blob[:4] != len(parts[0]).to_bytes(4,"big") or not blob[4:].startswith(parts[0].encode()):
        raise ValueError("Public key không hợp lệ.")
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
    return dict(name=path.name[:-4], public=" ".join(parts[:2]), fingerprint=fingerprint, type=parts[0])


def private(path):
    regular(path)
    with path.open("rb") as f:
        if not re.fullmatch(rb"-----BEGIN (OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----", f.readline(128).strip()):
            raise ValueError("Không tìm thấy private key hợp lệ.")


def agent(folder, start=False):
    sock = folder / "agent.sock"
    env = {"SSH_AUTH_SOCK": str(sock)}
    if sock.exists() and (not stat.S_ISSOCK(sock.lstat().st_mode) or sock.lstat().st_uid != os.getuid()):
        raise ValueError("Socket SSH agent không hợp lệ.")
    status = command("ssh-add", "-l", env=env)
    if status.returncode == 2 and start:
        sock.unlink(missing_ok=True)
        if command("ssh-agent", "-a", str(sock), "-s").returncode:
            raise ValueError("Không khởi động được SSH agent.")
        status = command("ssh-add", "-l", env=env)
    return env, status


def configuration(ssh):
    path = ssh / "config"
    source = ""
    if os.path.lexists(path):
        if regular(path).st_size > 1024 * 1024:
            raise ValueError("SSH config quá lớn.")
        source = path.read_bytes().decode()
    aliases = {}
    if BEGIN in source or END in source:
        block, sep, rest = source.partition(END+"\n")
        if not sep or not block.startswith(BEGIN+"\n") or BEGIN in rest or END in rest:
            raise ValueError("Khối alias trong SSH config đã thay đổi.")
        for row in block.splitlines()[1:]:
            if row.startswith("# account "):
                alias, host, name = row[10:].split()
                if not NAME.fullmatch(alias) or host not in PROVIDERS:
                    raise ValueError("Alias không hợp lệ.")
                aliases[alias] = (host, safe_name(name))
        if alias_block(aliases) != block+sep:
            raise ValueError("Khối alias đã được sửa thủ công. Kiểm tra ~/.ssh/config.")
        source = rest
    return aliases, source


def alias_block(aliases):
    if not aliases:
        return ""
    lines = [BEGIN]
    for alias, (host, name) in sorted(aliases.items()):
        lines.extend([f"# account {alias} {host} {name}", f"Host {alias}", f"    HostName {host}",
                      "    User git", f"    IdentityFile ~/.ssh/{name}", "    IdentitiesOnly yes",
                      "    IdentityAgent ~/.ssh/zm-git-agent/agent.sock"])
    return "\n".join([*lines, "Host *", END, ""])


def write_config(ssh, aliases, source):
    with tempfile.NamedTemporaryFile(dir=ssh, delete=False) as f:
        tmp = Path(f.name)
        try:
            f.write((alias_block(aliases)+source).encode())
            f.flush()
            os.replace(tmp, ssh/"config")
        finally:
            tmp.unlink(missing_ok=True)


def status(ssh, folder):
    def output(binary, *args):
        if not shutil.which(binary):
            return ""
        proc = command(binary, *args)
        return (proc.stdout or proc.stderr).strip() if not proc.returncode else ""
    aliases, _ = configuration(ssh)
    loaded = ""
    if folder.is_dir() and not folder.is_symlink() and shutil.which("ssh-add"):
        loaded = agent(folder)[1].stdout
    keys = []
    for path in sorted(ssh.glob("*.pub")):
        try:
            key = public(path)
        except (ValueError,OSError):
            continue
        try:
            private(ssh/key["name"])
            safe_name(key["name"])
            paired = True
        except (ValueError,OSError):
            paired = False
        keys.append(dict(key, paired=paired, loaded=key["fingerprint"] in loaded))
    missing_public = []
    for path in sorted(ssh.glob("*")):
        if os.path.lexists(ssh/(path.name+".pub")) or path.name.endswith(".pub"):
            continue
        try:
            safe_name(path.name)
            private(path)
        except (ValueError,OSError):
            continue
        missing_public.append(path.name)
    return dict(missing_public=missing_public, account=pwd.getpwuid(os.getuid()).pw_name, git=output("git","--version"), ssh=output("ssh","-V"),
                username=output("git","config","--global","--get","user.name"),
                email=output("git","config","--global","--get","user.email"), keys=keys, aliases=aliases)


def test_connection(host, key, env):
    event("Kiểm tra fingerprint máy chủ " + host)
    scan = command("ssh-keyscan","-T","5","-t","ed25519",host)
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp)/"host.pub"
        known = Path(temp)/"known_hosts"
        for row in scan.stdout.splitlines():
            parts = row.split()
            if len(parts)!=3 or parts[:2]!=[host,"ssh-ed25519"]:
                continue
            path.write_text(" ".join(parts[1:]))
            if public(path)["fingerprint"] != "SHA256:"+PROVIDERS[host]:
                raise ValueError("Fingerprint SSH khác giá trị chính thức. Đã dừng kết nối.")
            known.write_text(row+"\n")
            break
        if not known.exists():
            raise ValueError("Không đọc được host key qua TCP 22. Kiểm tra DNS và mạng VPS.")
        event("Xác thực SSH bằng key đã chọn")
        proc = command("ssh","-F","/dev/null","-o","BatchMode=yes","-o","IdentitiesOnly=yes",
                       "-o","ConnectTimeout=8","-o","HostKeyAlgorithms=ssh-ed25519","-o","StrictHostKeyChecking=yes",
                       "-o","GlobalKnownHostsFile=/dev/null","-o",f"UserKnownHostsFile={known}",
                       "-i",str(key),"-T","git@"+host,env=env)
        greeting = (proc.stdout+proc.stderr).lower()
        marker = {"github.com":"successfully authenticated","gitlab.com":"welcome to gitlab",
                  "bitbucket.org":"authenticated via ssh key"}[host]
        if marker not in greeting or proc.returncode not in (0,1):
            raise ValueError("Xác thực SSH thất bại. Kiểm tra public key ở tài khoản Git và nạp key vào agent.")
    event("Đã xác thực với "+host)


def apply(action, p):
    ssh = Path.home()/".ssh"
    folder = ssh/"zm-git-agent"
    if action in {"install","update"}:
        for args in (["apt-get","update"],["apt-get","-y","--no-remove","install","git","openssh-client"]):
            event(" ".join(args))
            with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                  env=dict(os.environ,DEBIAN_FRONTEND="noninteractive")) as proc:
                for line in proc.stdout:
                    # Do not publish repository URLs which can contain credentials.
                    if line.startswith(("Setting up git ", "Setting up openssh-client ", "Unpacking git ", "Unpacking openssh-client ")):
                        event(line.strip())
                if proc.wait():
                    raise ValueError("APT thất bại. Kiểm tra kho gói và khóa APT trên VPS.")
        return {}
    if ssh.is_symlink():
        raise ValueError("Thư mục SSH là symlink.")
    if action == "status":
        return status(ssh,folder)
    email = p.get("email","")
    if email and (not re.fullmatch(r"[^\s@]+@[^\s@]+",email) or not email.isprintable()):
        raise ValueError("Email không hợp lệ.")
    if action == "identity":
        name = p.get("username","").strip()
        if not name or not name.isprintable() or not email:
            raise ValueError("Nhập tên và email hợp lệ.")
        for field, value in [("name",name),("email",email)]:
            if command("git","config","--global","--replace-all","user."+field,value).returncode:
                raise ValueError("Không ghi được Git user."+field)
        event("Đã lưu Git username và email")
        return {}
    directory(ssh)
    directory(folder)
    with contextlib.ExitStack() as stack:
        fd = os.open(folder, os.O_RDONLY)
        stack.callback(os.close,fd)
        fcntl.flock(fd,fcntl.LOCK_EX)
        raw_name = (p.get("name") or "").strip()
        if action == "create" and not raw_name:
            raw_name = "id_rsa" if p.get("kind", "ed25519") == "rsa" else "id_ed25519"
        name = safe_name(raw_name)
        key, pub = ssh/name, ssh/(name+".pub")
        secret = p.get("passphrase","")
        if any(x in secret for x in ("\r","\n","\0")):
            raise ValueError("Passphrase không hợp lệ.")
        if action == "restore-public":
            private(key)
            if os.path.lexists(pub):
                raise ValueError("Public key đã tồn tại.")
            result = command("ssh-keygen","-y","-f",str(key),secret=secret+"\n")
            if result.returncode:
                raise ValueError("Không đọc được public key. Kiểm tra passphrase và quyền private key.")
            p = dict(p,public_key=result.stdout)
        if action in {"import","restore-public"}:
            if (action=="import" and os.path.lexists(key)) or os.path.lexists(pub):
                raise ValueError("Tên key đã tồn tại.")
            with tempfile.TemporaryDirectory(dir=ssh) as tmp:
                candidate = Path(tmp)/"key.pub"
                candidate.write_text(p.get("public_key","").strip()+"\n")
                parsed = public(candidate)
                if command("ssh-keygen","-lf",str(candidate)).returncode:
                    raise ValueError("Public key không hợp lệ.")
                candidate.write_text(parsed["public"]+"\n")
                candidate.chmod(0o644)
                os.link(candidate,pub)
            event("Đã lưu public key")
            return {}
        if action == "create":
            if os.path.lexists(key) or os.path.lexists(pub):
                raise ValueError("Tên key đã tồn tại.")
            kind = p.get("kind","ed25519")
            if kind not in {"ed25519","rsa"}:
                raise ValueError("Loại key không hợp lệ.")
            event("Tạo cặp SSH key "+kind)
            with tempfile.TemporaryDirectory(dir=ssh) as tmp:
                new = Path(tmp)/"key"
                args = ["ssh-keygen","-q","-t",kind,"-f",str(new),"-C",email]
                if kind=="rsa":
                    args.extend(["-b","4096"])
                if command(*args,secret=secret+"\n"+secret+"\n").returncode:
                    raise ValueError("Tạo key thất bại. Kiểm tra passphrase (ít nhất 5 ký tự khi sử dụng).")
                new.chmod(0o600)
                os.link(new,key)
                try:
                    os.link(str(new)+".pub",pub)
                except Exception:
                    key.unlink()
                    raise
        else:
            if public(pub)["fingerprint"] != p.get("fingerprint"):
                raise ValueError("Key đã thay đổi. Tải lại danh sách.")
        if action in {"create","load","test","alias"}:
            private(key)
            key.chmod(0o600)
        if action in {"create","load"}:
            event("Nạp key vào SSH agent")
            env, _ = agent(folder,True)
            if command("ssh-add",str(key),env=env,secret=secret+"\n").returncode:
                raise ValueError("Key đã có trên VPS. Nạp lại vào agent với passphrase đúng.")
        elif action in {"alias","unalias","delete"}:
            aliases, source = configuration(ssh)
            original = aliases.copy()
            alias = p.get("alias","").lower()
            if action == "alias":
                if not NAME.fullmatch(alias) or alias in PROVIDERS or p["provider"] not in PROVIDERS:
                    raise ValueError("Alias hoặc nhà cung cấp không hợp lệ.")
                for row in source.splitlines():
                    tokens = shlex.split(row,comments=True)
                    if tokens and tokens[0].lower()=="host" and alias in [t.lower() for t in tokens[1:]]:
                        raise ValueError("Alias đã có trong SSH config.")
                if alias in aliases and aliases[alias]!=(p["provider"],name):
                    raise ValueError("Alias đang được sử dụng.")
                aliases[alias]=(p["provider"],name)
            elif action=="unalias":
                if aliases.get(alias,(None,None))[1]!=name:
                    raise ValueError("Alias đã thay đổi.")
                del aliases[alias]
            else:
                if os.path.lexists(key):
                    private(key)
                    pair = command("ssh-keygen","-lf",str(key))
                    if p["fingerprint"] not in pair.stdout.split() or pair.returncode:
                        raise ValueError("Fingerprint của private key không khớp. Đã giữ các file trên VPS.")
                aliases={a:v for a,v in aliases.items() if v[1]!=name}
            if aliases != original:
                if configuration(ssh) != (original,source):
                    raise ValueError("SSH config đã thay đổi. Tải lại trước khi tiếp tục.")
                write_config(ssh,aliases,source)
            if action=="delete":
                env, state = agent(folder)
                if public(pub)["fingerprint"] in state.stdout and command("ssh-add","-d",str(pub),env=env).returncode:
                    raise ValueError("Không gỡ được key khỏi agent.")
                key.unlink(missing_ok=True)
                pub.unlink()
            event("Đã cập nhật "+name)
        elif action=="test":
            host=p["provider"]
            if host not in PROVIDERS:
                raise ValueError("Nhà cung cấp không hợp lệ.")
            test_connection(host,key,agent(folder)[0])
        return {}


def serve(payload):
    try:
        result = apply(payload["action"],payload.get("params",{}))
        print(json.dumps({"result":result}),flush=True)
    except Exception as exc:
        message = str(exc) if isinstance(exc,(ValueError,OSError)) else "Tác vụ Git/SSH thất bại hoặc quá thời gian."
        print(json.dumps({"error":message}),flush=True)
        raise SystemExit(1)


if __name__=="__main__":
    serve(json.load(sys.stdin))
