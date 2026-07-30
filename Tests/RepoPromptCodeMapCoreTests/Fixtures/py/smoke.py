from enum import Enum


class Status(Enum):
    READY = "ready"
    BLOCKED = "blocked"


class Worker:
    queue_name = "default"

    def run(self, status: Status) -> str:
        return f"{status.value}:{self.queue_name}"


def build_worker() -> Worker:
    return Worker()
