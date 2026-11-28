"""Source wiring checks only; native CoreGraphics/XCTest owns geometry evidence."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class RadialCircleContractTests(unittest.TestCase):
    def test_options_and_backing_use_count_derived_circle_layout(self):
        model = (ROOT / "Sources/CodaInteraction/EditorInputModel.swift").read_text(encoding="utf-8")
        views = (ROOT / "Sources/CodaApp/EditorViews.swift").read_text(encoding="utf-8")
        store = (ROOT / "Sources/CodaApp/CodaEditorStore.swift").read_text(encoding="utf-8")
        self.assertTrue("public struct RadialRingLayout" in model,
                        "Old fixed 120-degree sweep and curved pills cannot fit visible circle counts")
        self.assertIn("CGPath(ellipseIn:", model, "Options must paint and hit the same circle")
        self.assertNotRegex(model, r"public static let sweep\s*=\s*2 \* Double.pi / 3")
        radial_view = views.split("struct RadialMenuView: View", 1)[1].split("private struct HoldMenuView", 1)[0]
        self.assertNotIn("RadialGeometry.pill", radial_view)
        self.assertNotIn("RadialGeometry.sweep", radial_view)
        self.assertIn("layout.buttonCenter", radial_view)
        self.assertIn("layout.backing", radial_view)
        self.assertIn("layout.buttonPath", radial_view)
        hit = store.split("private func radialHit", 1)[1].split("private func radialIntent", 1)[0]
        self.assertIn("layout.slot(at:", hit)
        placement = store.split("private func menuPlacement", 1)[1].split("private func setRadialMode", 1)[0]
        self.assertIn("radialRings(for:", placement)
        self.assertIn("layouts:", placement)

    def test_seven_choice_fixture_uses_real_view_without_changing_paging(self):
        store = (ROOT / "Sources/CodaApp/CodaEditorStore.swift").read_text(encoding="utf-8")
        model = (ROOT / "Sources/CodaInteraction/EditorInputModel.swift").read_text(encoding="utf-8")
        ui = (ROOT / "Tests/CodaUITests/CodaLaunchTests.swift").read_text(encoding="utf-8")
        self.assertIn("public static let capacity = 3", model)
        self.assertIn("#if DEBUG\n    // Native screenshot/hover", store)
        self.assertIn("--coda-ui-fixture-radial-seven", store)
        self.assertIn("--coda-ui-fixture-radial-seven", ui)
        self.assertIn('attachScreenshot(named: "M1-radial-seven-fixture", from: app)', ui)


if __name__ == "__main__":
    unittest.main()
