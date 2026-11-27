from unittest.mock import Mock

import pytest
from apps.vps_manager.backend import worker


def test_failed_reload_restores_old_site(tmp_path, monkeypatch):
    directory = tmp_path / "conf.d"
    directory.mkdir()
    site = directory / "zm-example.test.conf"
    original = "# ZM VPS Manager\n# Original site\n"
    site.write_text(original)
    monkeypatch.setattr(worker, "Path", lambda value: tmp_path)
    monkeypatch.setattr(worker, "probe", lambda url, domain: "200")
    run = Mock(side_effect=["", "", ValueError("reload"), "", ""])
    monkeypatch.setattr(worker, "command", run)
    with pytest.raises(ValueError, match="reload"):
        worker.nginx_site("example.test", 3000)
    assert site.read_text() == original
    assert next((tmp_path/"zm-backups").glob("*.conf")).read_text() == original
    assert run.call_args_list[-2].args[0] == ["nginx", "-t"]


def test_cloudflare_failure_restores_renewal_credentials(tmp_path, monkeypatch):
    monkeypatch.setattr(worker, "Path", lambda _: tmp_path)
    monkeypatch.setattr(worker.shutil, "which", lambda _: "/usr/bin/certbot")
    credential = tmp_path / "example.test.ini"
    credential.write_text("previous credential")
    token = "test-token-for-dns-plugin"

    def certbot(args, timeout):
        assert token not in str(args)
        assert credential.read_text() == f"dns_cloudflare_api_token = {token}\n"
        assert credential.stat().st_mode & 0o777 == 0o600
        assert "--dns-cloudflare" in args
        raise ValueError("failure")

    monkeypatch.setattr(worker, "command", certbot)
    with pytest.raises(ValueError, match="Certbot thất bại"):
        worker.issue_certificate("example.test", dict(method="cloudflare", email="ops@example.test", token=token))
    assert credential.read_text() == "previous credential"


def test_https_survives_edit_and_disable(tmp_path, monkeypatch):
    (tmp_path / "conf.d").mkdir()
    monkeypatch.setattr(worker, "Path", lambda _: tmp_path)
    monkeypatch.setattr(worker, "command", Mock(return_value=""))
    monkeypatch.setattr(worker, "probe", lambda *args: "200")
    monkeypatch.setattr(worker.socket, "getaddrinfo", lambda *args: [])
    monkeypatch.setattr(worker, "issue_certificate", lambda *_: "/etc/letsencrypt/live/zm-example.test")
    worker.nginx_site("example.test", 3000, "create")
    worker.nginx_site("example.test", 3000, "certificate", {})
    worker.nginx_site("example.test", 3000, "disable")
    worker.nginx_site("example.test", 8080, "edit")
    assert worker.site_inventory(tmp_path) == [
        dict(domain="example.test", enabled=False, https=True, port=8080)
    ]
    worker.nginx_site("example.test", 8080, "enable")
    worker.nginx_site("example.test", 8080, "renew-test")
    assert worker.command.call_args.args[0] == ["certbot", "renew", "--dry-run", "--cert-name", "zm-example.test"]


def test_nested_server_parser_and_weighted_pool():
    source = worker.website_config("api.example.test", 3000, {
        "kind":"WebSocket","names":["ws.example.test"],"backend":"localhost:3000 weight=2, localhost:3001 backup",
        "algorithm":"least_conn"})
    nodes = worker.nginx_blocks(source)
    assert [w[0] for w, _ in nodes] == ["upstream", "server"]
    assert (["least_conn"], []) in nodes[0][1]
    assert (["server_name","api.example.test","ws.example.test"], []) in nodes[1][1]
    assert (["proxy_set_header","Connection","upgrade"], []) in list(worker.walk_directives(nodes))


def test_template_rejects_injected_backend():
    with pytest.raises(ValueError,match="Backend"):
        worker.website_config("api.example.test", 3000, {"backend":"localhost:80; include /tmp/x"})


def test_http_validation_refuses_wildcard(monkeypatch):
    monkeypatch.setattr(worker.shutil, "which", lambda _: "/usr/bin/certbot")
    run = Mock()
    monkeypatch.setattr(worker,"command",run)
    with pytest.raises(ValueError,match="Wildcard"):
        worker.issue_certificate("example.test",{"method":"http","names":["*.example.test"],"email":"admin@example.test"})
    run.assert_not_called()


def test_cloudflare_requests_apex_and_wildcard(tmp_path,monkeypatch):
    monkeypatch.setattr(worker.shutil,"which",lambda _: "/usr/bin/certbot")
    monkeypatch.setattr(worker,"Path",lambda _:tmp_path)
    run = Mock()
    monkeypatch.setattr(worker,"command",run)
    token = "test-renewal-credential"
    worker.issue_certificate("example.test",dict(method="cloudflare",token=token,email="admin@example.test",
                                                names=["example.test","*.example.test"]))
    argv = run.call_args.args[0]
    assert [argv[i+1] for i, flag in enumerate(argv) if flag=="-d"] == ["example.test","*.example.test"]
    assert token not in str(argv)


def test_batch_create_restores_all_files_on_reload_failure(tmp_path, monkeypatch):
    conf = tmp_path / "conf.d"
    conf.mkdir()
    original = conf / "keep.conf"
    original.write_text("# existing")
    monkeypatch.setattr(worker, "command", Mock(side_effect=["", "", ValueError("reload"), "", ""]))
    rows = [dict(domain=name, port=3000, kind="spa") for name in ("one.test", "two.test")]
    with pytest.raises(ValueError, match="reload"):
        worker.create_websites(rows,tmp_path)
    assert list(conf.iterdir()) == [original]
    assert original.read_text() == "# existing"


def test_batch_rejects_shared_alias_before_writing(tmp_path):
    (tmp_path/"conf.d").mkdir()
    rows = [dict(domain=name,names=["shared.test"],port=3000,kind="static") for name in ("one.test","two.test")]
    with pytest.raises(ValueError, match="shared.test"):
        worker.create_websites(rows,tmp_path)
    assert not list((tmp_path/"conf.d").iterdir())


def test_certbot_renewal_status_detects_snap_timer(monkeypatch, tmp_path):
    monkeypatch.setattr(worker, "Path", lambda *parts: tmp_path / "missing")

    def fake_cmd(args, check=True, timeout=60):
        if args == ["systemctl", "is-active", "snap.certbot.renew.timer"]:
            return "active"
        if args[:2] == ["systemctl", "show"]:
            return "6h"
        return "inactive"

    monkeypatch.setattr(worker, "command", fake_cmd)
    status = worker.certbot_renewal_status()
    assert status == {"enabled": True, "method": "systemd", "unit": "snap.certbot.renew.timer", "cron": False, "stagger": "6h", "detail": "snap.certbot.renew.timer · giãn cách 6h"}


def test_enable_certbot_renewal_creates_cron_fallback_when_no_timer(monkeypatch, tmp_path):
    cron_file = tmp_path / "zm-certbot-renew"
    monkeypatch.setattr(worker, "Path", lambda *parts: cron_file if "zm-certbot-renew" in str(parts[0]) else tmp_path / "none")
    monkeypatch.setattr(worker, "command", lambda args, check=True, timeout=60: "")
    monkeypatch.setattr(worker.shutil, "which", lambda name: "/opt/certbot/bin/certbot" if name == "certbot" else None)

    result = worker.enable_certbot_renewal()
    assert result["enabled"] is True
    assert result["method"] == "cron"
    assert cron_file.is_file()
    assert (cron_file.stat().st_mode & 0o777) == 0o644
    content = cron_file.read_text()
    assert "/opt/certbot/bin/certbot renew --quiet --deploy-hook" in content
    assert "random.randrange(900)" in content


def test_website_file_renew_test_runs_dry_run_for_unmanaged_site(monkeypatch, tmp_path):
    site = tmp_path / "app.conf"
    site.write_text("server { listen 443 ssl; server_name app.example.test; ssl_certificate /etc/letsencrypt/live/app.example.test/fullchain.pem; }")
    monkeypatch.setattr(worker.shutil, "which", lambda _: "/usr/bin/certbot")
    monkeypatch.setattr(worker, "discover_sites", lambda root: {
        "sites": [{
            "file_id": "fid-1",
            "source": str(site),
            "domain": "app.example.test",
            "enabled": True,
            "https": True,
            "renewal_names": ["app.example.test"],
        }],
        "diagnostics": [],
        "broken": [],
    })
    run = Mock(return_value="")
    monkeypatch.setattr(worker, "command", run)

    res = worker.website_file("renew-test", {"file_id": "fid-1", "domain": "app.example.test"}, tmp_path)
    assert res == {"domain": "app.example.test", "renewal_test": "ok"}
    assert run.call_args.args[0] == ["certbot", "renew", "--dry-run", "--cert-name", "app.example.test"]


def test_discover_sites_resolves_renewal_from_include_and_renewal_map(monkeypatch, tmp_path):
    nginx_root = tmp_path / "nginx"
    (nginx_root / "conf.d").mkdir(parents=True)
    (nginx_root / "snippets").mkdir()
    (nginx_root / "sites-enabled").mkdir()
    (nginx_root / "sites-available").mkdir()
    (nginx_root / "zm-disabled").mkdir()

    le_dir = tmp_path / "letsencrypt"
    (le_dir / "renewal").mkdir(parents=True)
    (le_dir / "live" / "app-0001").mkdir(parents=True)
    cert_file = le_dir / "live" / "app-0001" / "fullchain.pem"
    cert_file.write_text("dummy")
    (le_dir / "renewal" / "custom-profile.conf").write_text(f"fullchain = {cert_file}\n")

    snippet = nginx_root / "snippets" / "ssl-app.conf"
    snippet.write_text(f"ssl_certificate {cert_file};\n")
    site = nginx_root / "conf.d" / "app.conf"
    site.write_text(f"server {{\n    listen 443 ssl;\n    server_name app.example.test;\n    include {snippet};\n}}\n")

    monkeypatch.setattr(worker, "LETSENCRYPT_DIR", le_dir)
    monkeypatch.setattr(worker.shutil, "which", lambda name: "/usr/sbin/nginx" if name == "nginx" else None)

    class FakeProc:
        def __init__(self, stdout="", stderr="", returncode=0):
            self.stdout = stdout
            self.stderr = stderr
            self.returncode = returncode

    def fake_run(args, **kwargs):
        if args[:2] == ["nginx", "-T"]:
            return FakeProc(stdout=f"# configuration file {site}:\n")
        return FakeProc(stderr="")

    monkeypatch.setattr(worker.subprocess, "run", fake_run)

    inv = worker.discover_sites(nginx_root)
    assert len(inv["sites"]) == 1
    assert inv["sites"][0]["https"] is True
    assert inv["sites"][0]["renewal_names"] == ["custom-profile"]


def test_website_file_renew_ssl_supports_multiple_profiles(monkeypatch, tmp_path):
    import hashlib
    import ssl as py_ssl

    site = tmp_path / "app.conf"
    content = "server { listen 443 ssl; server_name app.example.test; }"
    site.write_text(content)
    revision = hashlib.sha256(content.encode()).hexdigest()

    le_dir = tmp_path / "letsencrypt"
    for name in ("rsa-prof", "ecdsa-prof"):
        (le_dir / "live" / name).mkdir(parents=True)
        (le_dir / "live" / name / "cert.pem").write_text("dummy")

    monkeypatch.setattr(worker, "LETSENCRYPT_DIR", le_dir)
    monkeypatch.setattr(worker.shutil, "which", lambda _: "/usr/bin/certbot")
    monkeypatch.setattr(worker, "discover_sites", lambda root: {
        "sites": [{
            "file_id": "fid-2",
            "source": str(site),
            "domain": "app.example.test",
            "enabled": True,
            "https": True,
            "renewal_names": ["ecdsa-prof", "rsa-prof"],
        }],
        "diagnostics": [],
        "broken": [],
    })
    monkeypatch.setattr(py_ssl._ssl, "_test_decode_cert", lambda path: {"notAfter": "Nov 27 00:00:00 2030 GMT"})
    run = Mock(return_value="")
    monkeypatch.setattr(worker, "command", run)

    res = worker.website_file("renew-ssl", {"file_id": "fid-2", "domain": "app.example.test", "revision": revision}, tmp_path)
    assert res["certificate"] == "ecdsa-prof, rsa-prof"
    cmds = [call.args[0] for call in run.call_args_list]
    assert ["certbot", "renew", "--non-interactive", "--cert-name", "ecdsa-prof"] in cmds
    assert ["certbot", "renew", "--non-interactive", "--cert-name", "rsa-prof"] in cmds
    assert ["nginx", "-t"] in cmds
    assert ["systemctl", "reload", "nginx"] in cmds


def test_external_certificate_reissues_when_https_site_missing_renewal_profile(monkeypatch, tmp_path):
    avail = tmp_path / "sites-available"
    avail.mkdir()
    site = avail / "api.example.test.conf"
    site.write_text(
        "server {\n    listen 443 ssl;\n    server_name api.example.test;\n"
        "    ssl_certificate /etc/letsencrypt/live/zm-api.example.test/fullchain.pem;\n"
        "    ssl_certificate_key /etc/letsencrypt/live/zm-api.example.test/privkey.pem;\n}\n"
    )
    import hashlib
    revision = hashlib.sha256(site.read_text().encode()).hexdigest()

    le_dir = tmp_path / "letsencrypt"
    copied_live = le_dir / "live" / "zm-api.example.test"
    copied_live.mkdir(parents=True)
    (copied_live / "fullchain.pem").write_text("copied")
    (le_dir / "renewal").mkdir(parents=True)

    monkeypatch.setattr(worker, "LETSENCRYPT_DIR", le_dir)
    monkeypatch.setattr(worker, "discover_sites", lambda root: {
        "sites": [{
            "file_id": "fid-3",
            "source": str(site),
            "domain": "api.example.test",
            "primary": "api.example.test",
            "enabled": True,
            "https": True,
            "renewal_names": [],
        }],
        "diagnostics": [],
        "broken": [],
    })
    monkeypatch.setattr(worker, "issue_certificate", lambda domain, params: str(le_dir / "live" / ("zm-" + domain)))
    monkeypatch.setattr(worker, "command", lambda args, check=True, timeout=60: "")
    monkeypatch.setattr(worker, "enable_certbot_renewal", lambda: {"detail": "certbot.timer"})

    res = worker.website_file(
        "external-certificate",
        {"file_id": "fid-3", "domain": "api.example.test", "revision": revision, "source": "", "method": "http", "email": "admin@example.test"},
        tmp_path,
    )
    assert res["file"] == str(site)
    assert not copied_live.exists()
    assert f"{le_dir}/live/zm-api.example.test/fullchain.pem" in site.read_text()


def test_save_cloudflare_token_updates_credentials_and_reuses_default(monkeypatch, tmp_path):
    le_dir = tmp_path / "letsencrypt"
    cred_dir = le_dir / "zm-credentials"
    cred_dir.mkdir(parents=True)
    old_ini = cred_dir / "api.example.test.ini"
    old_ini.write_text("dns_cloudflare_api_token = old_token_1234567890\n")
    renewal_dir = le_dir / "renewal"
    renewal_dir.mkdir()
    custom_ini = tmp_path / "custom-cf.ini"
    custom_ini.write_text("dns_cloudflare_api_token = old_custom_1234567890\n")
    (renewal_dir / "zm-api.example.test.conf").write_text(f"dns_cloudflare_credentials = {custom_ini}\n")

    monkeypatch.setattr(worker, "LETSENCRYPT_DIR", le_dir)
    res = worker.save_cloudflare_token({"token": "cfut_newToken1234567890abcd", "name": "default", "update_renewal": True})

    default_ini = cred_dir / "default.ini"
    assert res["credential"] == str(default_ini)
    assert "dns_cloudflare_api_token = cfut_newToken1234567890abcd\n" == default_ini.read_text()
    assert "dns_cloudflare_api_token = cfut_newToken1234567890abcd\n" == old_ini.read_text()
    assert "dns_cloudflare_api_token = cfut_newToken1234567890abcd\n" == custom_ini.read_text()
    assert (default_ini.stat().st_mode & 0o777) == 0o600

    monkeypatch.setattr(worker.shutil, "which", lambda _: "/usr/bin/certbot")
    run = Mock(return_value="")
    monkeypatch.setattr(worker, "command", run)
    worker.issue_certificate("new.example.test", {"method": "cloudflare", "email": "admin@example.test", "token": ""})
    assert str(default_ini) in run.call_args.args[0]
