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
