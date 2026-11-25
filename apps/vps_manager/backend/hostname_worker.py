"""Rename a Linux host through hostnamectl and fixed configuration paths."""
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile


def valid_hostname(name):
    return (isinstance(name,str) and 0 < len(name) <= 63 and not name.isdigit()
            and not re.fullmatch(r"[0-9.]+",name) and name.split(".")[0] != "localhost"
            and not name.endswith(".localhost")
            and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?",label) for label in name.split(".")))


def hosts_content(source, old, new):
    reserved = {"localhost","localhost.localdomain","ip6-localhost","ip6-loopback"}
    previous = {old.lower(),old.split(".")[0].lower()} - reserved
    wanted = list(dict.fromkeys([new,new.split(".")[0]]))
    lines = source.splitlines(keepends=True)
    mapped = False
    for index,line in enumerate(lines):
        fields,mark,comment = line.rstrip("\r\n").partition("#")
        tokens = fields.split()
        if len(tokens)<2:
            continue
        try:
            ipaddress.ip_address(tokens[0])
        except ValueError:
            continue
        aliases = tokens[1:]
        lower = {name.lower() for name in aliases}
        if not previous.intersection(lower):
            if set(wanted).intersection(lower):
                raise ValueError("Tên mới đã có ánh xạ khác trong /etc/hosts.")
            if tokens[0]!="127.0.1.1" or mapped:
                continue
        names = [a for a in aliases if a.lower() not in previous and a.lower() not in wanted]
        # Keep localhost canonical on its loopback entry.
        if aliases[0].lower() in previous:
            names = wanted+names
        else:
            names += wanted
        lines[index] = tokens[0]+"\t"+" ".join(names)+("  #"+comment if mark else "")+"\n"
        mapped = True
    result = "".join(lines)
    if not mapped:
        result += ("" if not result or result.endswith("\n") else "\n")+"127.0.1.1\t"+" ".join(wanted)+"\n"
    return result


def write_config(path, data):
    if path.is_symlink():
        raise ValueError("Tệp cấu hình là symlink: "+str(path))
    fd,tmp=tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd,"wb") as stream:
            stream.write(data)
        if path.exists():
            st=path.stat()
            os.chown(tmp,st.st_uid,st.st_gid)
            shutil.copystat(path,tmp)
        else:
            os.chmod(tmp,0o644)
        os.replace(tmp,path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def ctl(*args):
    result=subprocess.run(["hostnamectl",*args],text=True,capture_output=True,timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "hostnamectl thất bại.")
    return result.stdout.strip()


def rename(expected,name,emit):
    if not valid_hostname(name):
        raise ValueError("Hostname không hợp lệ.")
    old=socket.gethostname()
    if old!=expected:
        raise ValueError("Hostname hiện tại đã thay đổi. Làm mới trước khi thử lại.")
    static=ctl("--static")
    hosts=Path("/etc/hosts")
    cloud=Path("/etc/cloud/cloud.cfg.d/zz-zm-manager-hostname.cfg")
    cloud.parent.mkdir(parents=True,exist_ok=True)
    before={hosts:hosts.read_bytes(),cloud:cloud.read_bytes() if cloud.exists() else None}
    content=hosts_content(before[hosts].decode("utf-8","surrogateescape"),old,name)
    changes={hosts:content.encode("utf-8","surrogateescape"),cloud:b"#cloud-config\npreserve_hostname: true\n"}
    applied=[]
    attempted=False
    emit(old+" → "+name)
    try:
        for path,data in changes.items():
            if data!=before[path]:
                write_config(path,data)
                applied.append(path)
                emit("Đã cập nhật "+str(path))
        attempted=True
        ctl("--static","--transient","set-hostname",name)
        if socket.gethostname()!=name or ctl("--static")!=name:
            raise RuntimeError("Không xác minh được hostname sau khi đổi.")
        emit("Đã xác minh hostname · "+name)
        return {"hostname":name,"previous":old}
    except Exception as exc:
        failures=[]
        if attempted:
            for flag,value in [("--static",static),("--transient",old)]:
                try:
                    ctl(flag,"set-hostname",value)
                except Exception as error:
                    failures.append(str(error))
        for path in reversed(applied):
            try:
                if before[path] is None:
                    path.unlink()
                else:
                    write_config(path,before[path])
            except Exception as error:
                failures.append(str(error))
        if failures:
            raise RuntimeError(str(exc)+" · Lỗi phục hồi: "+"; ".join(failures)) from exc
        raise


def serve(request):
    try:
        p=request["params"]
        result=rename(p["expected"],p["hostname"],lambda msg:print(json.dumps({"event":msg}),flush=True))
        print(json.dumps({"result":result}),flush=True)
    except Exception as exc:
        print(json.dumps({"error":str(exc)}),flush=True)
        sys.exit(1)


if __name__=="__main__":
    serve(json.load(sys.stdin))
