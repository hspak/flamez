"""Saved-session workflows; no tracing privileges or live workload required."""
from zrct import Suite, TestCase
from pathlib import Path
from support import imported_session, validate_export

REPOSITORY = Path(__file__).resolve().parents[2]
SUITE = Suite("flamez", REPOSITORY, ("zig", "build", "-Dautomation=true"),
              "zig-out/bin/flamez", setup=imported_session)


class ImportedSession(TestCase):
    def setUp(self):
        self.app = self.context.launch("--import", self.context.fixture)

    def test_inspect_details(self):
        self.app.target(role="row", text_contains="sh").expect_visible()
        self.app.target(role="row", text_contains="sh").click()
        self.app.target("detail-pane").expect_visible()
        self.app.target(role="row", text_contains="sh").expect(selected=True)
        self.app.target("detail-close").click()
        self.app.target("detail-pane").expect_absent_from_snapshot()

    def test_export_and_reopen(self):
        self.app.target("zoom-anchor").scroll(1, modifiers="left_control")
        self.app.target("timeline").scroll(-1, modifiers="left_shift")
        self.app.target("export-button").click()
        directory = self.context.desktop.root / "data"
        exported = self.app.expect("exported session exists", lambda: list(directory.glob("flamez-*.json")))
        validate_export(self.context.fixture, exported[0])
        self.app.close()
        self.app.process.wait(3)
        self.app = self.context.launch("--import", exported[0])
        self.app.target(role="row", text_contains="sh").expect_visible()

    def test_resize_and_idle_input(self):
        self.app.resize(1000, 700)
        self.app.expect("app remains inspectable", lambda: self.app.inspect(role="row"))
        self.app.expect_drawing_idle()
        self.app.press("left_control+s")
        self.app.expect("idle shortcut exports a session", lambda: list((self.context.desktop.root / "data").glob("flamez-*.json")))
        self.app.target("export-button").expect_visible()

    def test_zoom_anchor_during_scroll(self):
        from zrct.recording import Recording
        initial = self.app.target("zoom-anchor").resolve()["bounds"]["x"]
        with Recording(self.app, "zoom") as recording:
            self.app.target("zoom-anchor").scroll(1, modifiers="left_control")
            self.app.target("zoom-anchor").scroll(1, modifiers="left_control")
            self.app.target("zoom-anchor").scroll(-1, modifiers="left_control")
        recording.expect_anchor("zoom-anchor", axis="x", tolerance=1.5, expected=initial, visual=True)

    def test_collapse_expand_preserves_selection(self):
        self.app.close()
        self.app.process.wait(3)
        trace = REPOSITORY / "src/testdata/session-v1-analysis-bottleneck.json"
        self.app = self.context.launch("--import", trace)
        self.app.target(role="row", text_contains="zig").expect_visible()
        self.app.target(role="row", text_contains="build").click()
        self.app.target(role="row", text_contains="build").expect(selected=True)
        self.app.target("disclosure/process/1/0").click()
        self.app.target(role="row", text_contains="zig").expect_absent_from_snapshot()
        self.app.target(role="row", text_contains="build").expect(selected=True)
        self.app.target("disclosure/process/1/0").click()
        self.app.target(role="row", text_contains="zig").expect_visible()

    def test_held_input_and_resize_keep_frames_active(self):
        self.app.expect_drawing_idle()
        self.app.key_down("left_control")
        try:
            self.app.expect_always("held modifier keeps frames active",
                                   lambda: self.app.target("window").resolve()["status"] == "active",
                                   duration=.8)
            for width, height in ((980, 650), (1180, 650), (1180, 760)):
                self.app.resize(width, height)
                self.app.target("window").expect(status="active")
                self.app.target("export-button").expect_fully_visible()
        finally:
            self.app.key_up("left_control")
        self.app.expect_drawing_idle()
        self.app.target(role="row", text_contains="sh").click()
        self.app.target("detail-pane").expect_visible()
        self.app.target("detail-pane").screenshot("sdl-details")
