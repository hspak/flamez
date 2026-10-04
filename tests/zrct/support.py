from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil


gpu_display = os.environ.get("ZRCT_DISPLAY_SMOKE") == "1"


@contextmanager
def imported_session(context):
    source = context.suite.repository / "src/testdata/session-v1-exec-history.json"
    destination = context.desktop.root / "data/session.json"
    shutil.copyfile(source, destination)
    context.bundle.manifest["metadata"]["fixture"] = dict(path=str(source), content=json.loads(source.read_text()))
    yield destination


def validate_export(original, exported):
    before = json.loads(Path(original).read_text())
    after = json.loads(Path(exported).read_text())
    for field in ("flamez", "processes", "elapsed_ns", "metadata", "root_exit", "capture_fidelity"):
        if before[field] != after[field]:
            raise AssertionError(f"Export changed {field}: {after[field]!r}")
    return after
