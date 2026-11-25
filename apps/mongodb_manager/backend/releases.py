"""Release metadata shared by the Manager and its single-file SSH worker."""
import json
import re
import threading
import time
from pathlib import Path
from urllib.request import urlopen

UBUNTU = "https://changelogs.ubuntu.com/meta-release-lts"
MONGO = "https://downloads.mongodb.org/current.json"
_lock = threading.Lock()
_next_refresh = 0


def parse(ubuntu, mongo):
    lts = {}
    for block in ubuntu.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line)
        version = re.match(r"(\d+\.\d+).* LTS", fields.get("Version", ""))
        name = fields.get("Dist", "")
        if version and re.fullmatch("[a-z]+", name):
            lts[name] = version[1]
    supported = {}
    for release in mongo["versions"]:
        match = re.fullmatch(r"(\d+\.\d+)\.\d+", release["version"])
        if not match or release.get("development_release"):
            continue
        series = match[1]
        for download in release["downloads"]:
            for package in download.get("packages", []):
                path = re.fullmatch(r"https://repo\.mongodb\.org/apt/ubuntu/dists/([a-z]+)/mongodb-org/"
                                    + re.escape(series) + r"/multiverse/binary-(amd64|arm64)/mongodb-org-server_[^/]+\.deb", package)
                if path and path[1] in lts:
                    supported.setdefault(series, set()).add(path[1])
    if not supported:
        raise ValueError("Không đọc được danh mục MongoDB cho Ubuntu.")
    return {"lts": lts, "supported": {s: sorted(v, key=list(lts).index) for s, v in supported.items()}}


def catalog():
    global _catalog, _next_refresh
    with _lock:
        if time.monotonic() >= _next_refresh:
            try:
                with urlopen(UBUNTU, timeout=5) as res:
                    ubuntu = res.read().decode()
                with urlopen(MONGO, timeout=8) as res:
                    fresh = parse(ubuntu, json.load(res))
                _catalog = dict(fresh, cached=False)
                delay = 3600
            except (OSError, ValueError, TypeError, KeyError):
                _catalog = dict(_catalog, cached=True)
                delay = 60
            _next_refresh = time.monotonic() + delay
        return _catalog


_catalog = json.loads(Path(__file__).with_name("release-catalog.json").read_text())
