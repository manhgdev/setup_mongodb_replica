"""Atomic reservations for jobs sharing a VPS or a replica set."""
import threading


def machine_keys(machine):
    if not machine:
        return set()
    host = machine.get("host", "").lower().rstrip(".") if machine.get("mode") == "ssh" else "localhost"
    return {("machine", machine["id"]), ("host", host)}


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
