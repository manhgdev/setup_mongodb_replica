import ipaddress
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


from shared.manager_core.machines import Machine, StrictModel, endpoint, hostname, public_endpoint, public_host, seed_endpoint

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
