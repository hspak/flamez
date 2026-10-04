"""Serial measurements of completed application frames, before presentation."""
from zrct import Benchmark, Suite, TestCase
from support import gpu_display, imported_session

SUITE = Suite("flamez-benchmarks", setup=imported_session, sdl_renderer="vulkan",
              display=gpu_display, benchmark=Benchmark(
    optimization="ReleaseSafe",
    fixture={"kind": "imported-exec-history", "processes": 1},
    cache="fresh process and private app state; shared OS page cache uncontrolled; details opens after drawing idle",
    fixture_files=("tests/zrct/support.py", "src/testdata/session-v1-exec-history.json")))


class Workflows(TestCase):
    def test_startup(self):
        app = self.context.benchmark.startup("startup_to_timeline",
            lambda: self.context.launch("--import", self.context.fixture),
            ready=dict(id="export-button", enabled=True))
        app.target(role="row", text_contains="sh").expect_visible()

    def test_idle_to_details(self):
        app = self.context.launch("--import", self.context.fixture)
        row = app.target(role="row", text_contains="sh")
        row.expect_visible()
        app.expect_drawing_idle()
        self.context.benchmark.action("idle_to_details", row.click,
                                      ready=dict(id="detail-pane"))
        row.expect(selected=True)
        app.target("detail-close").expect_interactable()
