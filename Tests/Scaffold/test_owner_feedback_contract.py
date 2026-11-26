"""Runnable production-data and presentation-boundary checks (not Swift emulation)."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class OwnerFeedbackContractTests(unittest.TestCase):
    def test_production_additive_choices_preserve_every_original_tone(self):
        data = json.loads((ROOT / "Sources/CodaMusic/Resources/vocab.json").read_text())
        by_id = {quality["id"]: quality for quality in data}
        self.assertEqual(len(by_id), len(data))
        for base, expected in (("major", ("add9", "add11")),
                               ("minor", ("minorAdd9", "minorAdd11"))):
            self.assertEqual(by_id[base]["suggestions"][:2], list(expected))
            for identifier in expected:
                with self.subTest(quality=identifier):
                    original = set(by_id[base]["intervals"])
                    extended = set(by_id[identifier]["intervals"])
                    self.assertLess(original, extended)
                    self.assertEqual(len(extended - original), 1)
                    self.assertEqual(by_id[identifier]["family"], by_id[base]["family"])

    def test_every_production_vocabulary_reference_resolves_and_stays_playable(self):
        data = json.loads((ROOT / "Sources/CodaMusic/Resources/vocab.json").read_text())
        identifiers = {quality["id"] for quality in data}
        for quality in data:
            with self.subTest(quality=quality["id"]):
                self.assertIn(quality["family"], ("major", "minor", "odd"))
                self.assertEqual(len(quality["suggestions"]), 3)
                self.assertEqual(len(set(quality["suggestions"])), 3)
                self.assertNotIn(quality["id"], quality["suggestions"])
                self.assertTrue(set(quality["suggestions"]) <= identifiers)
                self.assertEqual(quality["intervals"], sorted(set(quality["intervals"])))
                self.assertEqual(quality["intervals"][0], 0)
                self.assertLessEqual(len(quality["intervals"]), 12)

    def test_touched_menus_have_one_opaque_custom_surface_boundary(self):
        views = (ROOT / "Sources/CodaApp/EditorViews.swift").read_text(encoding="utf-8")
        tokens = (ROOT / "Sources/CodaApp/CodaDesignTokens.swift").read_text(encoding="utf-8")
        # Native presentations would bypass CODA's shared opaque composition.
        self.assertNotRegex(views, r"\.(?:popover|sheet|glassEffect|presentationBackground)\(")
        self.assertNotRegex(views, r"\b(?:Menu|Picker)\(")
        self.assertNotRegex(views, r"\.(?:ultraThin|thin|regular|thick)Material\b")
        base = re.search(r"static let darkGlass = (.+)", tokens).group(1)
        self.assertNotIn("opacity", base)
        self.assertNotIn("top.drawer", views)
        for name in ("SynthDrawer", "EditorSettingsPopover", "RadialMenuView",
                     "HoldMenuView", "KnobResetMenu"):
            body = views.split(f"struct {name}: View", 1)[1].split("\nprivate struct ", 1)[0]
            self.assertRegex(body, r"CodaAcrylic\(store: store\)|AcrylicPanel\(store: store\)")


if __name__ == "__main__":
    unittest.main()
