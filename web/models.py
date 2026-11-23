import ipaddress
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


def hostname(value):
    value = value.strip()
    try:
        ipaddress.ip_address(value)
        return value
    except ValueError:
        if len(value) <= 253 and re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", value):
            return value
    raise ValueError("Host phải là IP hoặc hostname hợp lệ.")


def endpoint(value):
    value = value.strip()
    if value.startswith("["):
        match = re.fullmatch(r"\[([^]]+)\]:(\d+)", value)
        if not match:
            raise ValueError("IPv6 phải theo dạng [địa chỉ]:port.")
        host, port = match.groups()
    else:
        if value.count(":") != 1:
            raise ValueError("Địa chỉ phải theo dạng host:port.")
        host, port = value.rsplit(":", 1)
    hostname(host)
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ValueError("Port không hợp lệ.")
    return value


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


def seed_endpoint(value):
    value = value.strip()
    if ':' not in value:
        return endpoint(hostname(value) + ':27017')
    if value.startswith('[') and value.endswith(']'):
        return endpoint(value + ':27017')
    try:
        if ipaddress.ip_address(value).version == 6:
            return endpoint('[' + value + ']:27017')
    except ValueError:
        pass
    return endpoint(value)


class Profile(StrictModel):
    name: str = Field(min_length=1, max_length=80)
    seeds: list[str] = Field(min_length=1, max_length=50)
    replica_set: str = Field(default="rs0", max_length=100, pattern=r"^[A-Za-z0-9_.-]*$")
    username: str = Field(default="", max_length=200)
    password: str | None = Field(default=None, max_length=1000)
    auth_db: str = Field(default="admin", min_length=1, max_length=100)
    tls: bool = False
    tls_ca: str = Field(default="", max_length=1000)

    @field_validator("seeds")
    @classmethod
    def endpoints(cls, value):
        return list(dict.fromkeys(seed_endpoint(item) for item in value))


class Machine(StrictModel):
    auto_name: bool = False
    name: str = Field(min_length=1, max_length=80)
    mode: Literal["local", "ssh"] = "ssh"
    host: str = "127.0.0.1"
    port: int = Field(default=22, ge=1, le=65535)
    user: str = Field(default="root", pattern=r"^[A-Za-z_][A-Za-z0-9_-]{0,63}$")
    identity: str = Field(default="", max_length=1000)
    ssh_auth: Literal["key", "password"] = "key"
    ssh_password: str | None = Field(default=None, max_length=1000)
    profile_id: str = Field(default="", max_length=100)
    mongo_endpoint: str = Field(default="", max_length=300)
    service: str = Field(default="mongod", pattern=r"^mongod(?:[.@-][A-Za-z0-9_.@-]{1,90})?$")

    @field_validator("host")
    @classmethod
    def valid_host(cls, value):
        return hostname(value)

    @field_validator("mongo_endpoint")
    @classmethod
    def valid_mongo_endpoint(cls, value):
        return seed_endpoint(value) if value else ""


class ProfileProbe(Profile):
    record_id: str = Field(default="", max_length=100)


class AttachedMachine(StrictModel):
    record_id: str = Field(default="", max_length=100)
    machine: Machine


class ProfileAdopt(ProfileProbe):
    machines: list[AttachedMachine] = Field(default_factory=list, max_length=50)


class Action(StrictModel):
    action: str
    profile_id: str = ""
    machine_id: str = ""
    params: dict = Field(default_factory=dict)


class Apply(StrictModel):
    backup_confirmed: bool = Field(default=False, strict=True)
    plan_id: str
    confirmation: str = ""


class DocumentPage(StrictModel):
    database: str = Field(min_length=1, max_length=128)
    collection: str = Field(min_length=1, max_length=255)
    offset: int = Field(default=0, ge=0)
    limit: int = Field(default=10, ge=1, le=50)
    field: str = Field(default="", max_length=255)
    value: str = Field(default="", max_length=8192)


class DocumentWrite(StrictModel):
    database: str = Field(min_length=1, max_length=128)
    collection: str = Field(min_length=1, max_length=255)
    action: Literal["insert", "replace", "delete"]
    document: str | None = None
    original: str | None = None
