import pytest
from apps.vps_manager.backend import sysadmin_worker as sw


def test_valid_username_and_protected_paths():
    sw.valid_username("deploy_01")
    with pytest.raises(ValueError):
        sw.valid_username("Root")
    with pytest.raises(ValueError):
        sw.valid_username("bad user")

    assert str(sw.valid_path("/data/app")) == "/data/app"
    for protected in ["/", "/etc", "/usr", "/var", "/boot", "/root"]:
        with pytest.raises(ValueError):
            sw.valid_path(protected)
    with pytest.raises(ValueError):
        sw.valid_path("relative/path")


def test_delete_user_safety_guards():
    with pytest.raises(ValueError, match="root"):
        sw.user_delete({"username": "root"}, "ubuntu")
    with pytest.raises(ValueError, match="đang dùng"):
        sw.user_delete({"username": "ubuntu"}, "ubuntu")


def test_storage_mount_safety_guards(monkeypatch):
    fake_storage = {
        "disks": [
            {
                "name": "sda",
                "path": "/dev/sda",
                "size": 50_000_000_000,
                "type": "disk",
                "fstype": "",
                "mountpoint": "",
                "protected": True,
                "children": [
                    {
                        "name": "sda1",
                        "path": "/dev/sda1",
                        "size": 49_000_000_000,
                        "type": "part",
                        "fstype": "ext4",
                        "mountpoint": "/",
                        "uuid": "1111",
                        "protected": True,
                    }
                ],
            },
            {
                "name": "sdb",
                "path": "/dev/sdb",
                "size": 100_000_000_000,
                "type": "disk",
                "fstype": "",
                "mountpoint": "",
                "protected": False,
                "children": [
                    {
                        "name": "sdb1",
                        "path": "/dev/sdb1",
                        "size": 100_000_000_000,
                        "type": "part",
                        "fstype": "ext4",
                        "mountpoint": "",
                        "uuid": "2222",
                        "protected": False,
                    }
                ],
            },
        ],
        "mounts": [],
        "fstab": [],
    }
    monkeypatch.setattr(sw, "list_storage", lambda: fake_storage)

    with pytest.raises(ValueError, match="hệ thống"):
        sw.storage_mount({"op": "format", "device": "/dev/sda1", "confirm_device": "/dev/sda1"})

    with pytest.raises(ValueError, match="xác nhận"):
        sw.storage_mount({"op": "format", "device": "/dev/sdb1", "confirm_device": "/dev/wrong"})
