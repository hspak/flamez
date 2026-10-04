"""Native Wayland input and density changes through the SDL window."""
from zrct import Suite, TestCase
from support import imported_session
from zrct.desktop import DesktopInput

# Place the window at 2x first: Weston does not reposition it when output
# coordinates shrink. Every later scale retains reachable native hit regions.
SUITE = Suite("flamez-desktop", setup=imported_session, width=3200, height=2200, scale=2,
              required_boundaries=("compositor_input",), sdl_renderer="vulkan")


class DesktopWorkflow(TestCase):
    def test_scale_changes_preserve_hit_testing_and_details(self):
        app = self.context.launch("--import", self.context.fixture)
        desktop = DesktopInput(self.context)
        row = app.target(role="row", text_contains="sh")
        row.expect_visible()
        for scale in (2, 1, 2):
            desktop.set_scale(scale)
            desktop.click(row)
            row.expect(selected=True)
            app.target("detail-pane").expect_visible()
            app.screenshot(self.context.bundle.root / f"scale-{scale}.png")
            desktop.click("detail-close")
            app.target("detail-pane").expect_absent_from_snapshot()
        app.expect_drawing_idle()
