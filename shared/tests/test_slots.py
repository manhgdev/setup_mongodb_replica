import pytest
from shared.manager_core.job_slots import Busy, JobSlots, machine_keys


def test_ssh_alias_cannot_start_second_host_job():
    slots = JobSlots()
    machine = dict(id="a", mode="ssh", host="example.net")
    slots.reserve("first", set(), machine_keys(machine), job_id="first")
    with pytest.raises(Busy) as error:
        slots.reserve("second", set(), machine_keys(dict(machine, id="b")))
    assert error.value.job_id == "first"
