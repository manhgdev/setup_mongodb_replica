"""Atomic reservations for jobs sharing a VPS or a replica set."""
import threading


def machine_keys(machine):
    if not machine:
        return set()
    host = machine.get("host", "").lower().rstrip(".") if machine.get("mode") == "ssh" else "localhost"
    return {("machine", machine["id"]), ("host", host)}


def job_scope(plan):
    machine, source = plan.get("machine"), plan.get("source_machine")
    writes = machine_keys(machine) | machine_keys(source) | machine_keys(plan.get("receiver"))
    action = plan["public"]["action"]
    profiles = {m.get("profile_id") for m in (machine, source) if m}
    for p in (plan.get("profile"), plan.get("destination")):
        if p:
            profiles.add(p["id"])
    reads = {("profile", pid) for pid in profiles if pid}
    # Maintenance that can stop a voter shares a reservation with replica-set changes.
    independent = {"preflight", "logs", "backups", "install", "backup", "upgrade_check"}
    if action not in independent:
        writes.update(("cluster", pid) for pid in profiles if pid)
    return reads, writes


class Busy(Exception):
    def __init__(self, job_id):
        self.job_id = job_id


class JobSlots:
    def __init__(self):
        self.guard = threading.Lock()
        self.active = {}

    def reserve(self, owner, reads, writes, job_id=None):
        with self.guard:
            for held_reads, held_writes, blocking_job in self.active.values():
                if writes & (held_reads | held_writes) or reads & held_writes:
                    raise Busy(blocking_job)
            self.active[owner] = (reads, writes, job_id)

    def release(self, owner):
        with self.guard:
            del self.active[owner]
