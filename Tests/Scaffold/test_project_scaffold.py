import pathlib
import re
import struct
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
FONT_DIRECTORY = ROOT / "Fonts" / "Plus_Jakarta_Sans" / "static"
FONT_FILES = {
    "PlusJakartaSans-Light.ttf": "PlusJakartaSans-Light",
    "PlusJakartaSans-Regular.ttf": "PlusJakartaSans-Regular",
    "PlusJakartaSans-Medium.ttf": "PlusJakartaSans-Medium",
    "PlusJakartaSans-SemiBold.ttf": "PlusJakartaSans-SemiBold",
    "PlusJakartaSans-Bold.ttf": "PlusJakartaSans-Bold",
    "PlusJakartaSans-ExtraBold.ttf": "PlusJakartaSans-ExtraBold",
}


def postscript_name(font_path: pathlib.Path) -> str:
    """Read the PostScript name directly from a TrueType/OpenType name table."""
    data = font_path.read_bytes()
    table_count = struct.unpack_from(">H", data, 4)[0]
    name_table = None
    for index in range(table_count):
        record_offset = 12 + index * 16
        tag = data[record_offset : record_offset + 4]
        offset, length = struct.unpack_from(">II", data, record_offset + 8)
        if tag == b"name":
            name_table = data[offset : offset + length]
            break
    if name_table is None:
        raise AssertionError(f"Missing name table in {font_path.name}")

    _, record_count, string_offset = struct.unpack_from(">HHH", name_table, 0)
    candidates = []
    for index in range(record_count):
        platform, _, language, name_id, length, offset = struct.unpack_from(
            ">HHHHHH", name_table, 6 + index * 12
        )
        if name_id != 6:
            continue
        encoded = name_table[string_offset + offset : string_offset + offset + length]
        if platform in (0, 3):
            decoded = encoded.decode("utf-16-be")
        else:
            decoded = encoded.decode("mac_roman")
        candidates.append((language, decoded))

    if not candidates:
        raise AssertionError(f"Missing PostScript name in {font_path.name}")
    return candidates[0][1]


class ProjectScaffoldTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = (ROOT / "project.yml").read_text(encoding="utf-8")
        cls.tokens = (ROOT / "Sources" / "CodaApp" / "CodaDesignTokens.swift").read_text(
            encoding="utf-8"
        )
        cls.app = (ROOT / "Sources" / "CodaApp" / "CodaApp.swift").read_text(
            encoding="utf-8"
        )
        cls.views = (ROOT / "Sources" / "CodaApp" / "EditorViews.swift").read_text(
            encoding="utf-8"
        )
        cls.input_bridge = (ROOT / "Sources" / "CodaApp" / "PencilInputBridge.swift").read_text(
            encoding="utf-8"
        )

    def test_bundled_font_files_and_postscript_names(self):
        for filename, expected_name in FONT_FILES.items():
            with self.subTest(font=filename):
                font_path = FONT_DIRECTORY / filename
                self.assertTrue(font_path.is_file(), f"Missing {font_path.relative_to(ROOT)}")
                self.assertEqual(postscript_name(font_path), expected_name)
                self.assertIn(filename, self.project)
        self.assertIn("Fonts/Plus_Jakarta_Sans/OFL.txt", self.project)
        self.assertTrue((ROOT / "Fonts" / "Plus_Jakarta_Sans" / "OFL.txt").is_file())

    def test_font_registration_uses_only_required_uifonts(self):
        block = re.search(r"(?m)^        UIAppFonts:\n((?:          - .+\n)+)", self.project)
        self.assertIsNotNone(block, "project.yml must declare UIAppFonts")
        registered = [line.strip()[2:] for line in block.group(1).splitlines()]
        self.assertEqual(registered, list(FONT_FILES))
        self.assertNotRegex(self.project, r"(?i)Italic|VariableFont")

    def test_ipad_only_landscape_full_screen_configuration(self):
        self.assertRegex(
            self.project,
            r"(?ms)^    info:\n      path: build/generated/coda-Info\.plist\n      properties:\n.*?^  codaUITests:",
        )
        self.assertNotIn("GENERATE_INFOPLIST_FILE", self.project)
        self.assertIn("UILaunchScreen: {}", self.project)
        self.assertIn("build/", (ROOT / ".gitignore").read_text(encoding="utf-8"))
        self.assertIn("\nschemes:\n  coda:\n", self.project)
        self.assertNotRegex(self.project, r"(?m)^    scheme:")
        self.assertIn('TARGETED_DEVICE_FAMILY: "2"', self.project)
        self.assertIn('IPHONEOS_DEPLOYMENT_TARGET: "27.2"', self.project)
        self.assertIn("SUPPORTS_MACCATALYST: NO", self.project)
        self.assertNotIn("CODE_SIGN_ENTITLEMENTS", self.project)
        self.assertIn("UIRequiresFullScreen: true", self.project)
        orientation_block = re.search(
            r'(?m)^        "UISupportedInterfaceOrientations~ipad":\n'
            r"((?:          - .+\n)+)",
            self.project,
        )
        self.assertIsNotNone(orientation_block)
        self.assertEqual(
            [line.strip()[2:] for line in orientation_block.group(1).splitlines()],
            ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        )
        self.assertNotIn("UIInterfaceOrientationPortrait", self.project)

    def test_design_tokens_cover_scoped_visual_system(self):
        expected_tokens = (
            "topBarHeight: CGFloat = 52",
            "timelineHeight: CGFloat = 20",
            "chordStripHeight: CGFloat = 104",
            "pitchGutterWidth: CGFloat = 56",
            "innerPill: CGFloat = 4",
            "control: CGFloat = 6",
            "card: CGFloat = 8",
            'lightFontPostScriptName = "PlusJakartaSans-Light"',
            'extraBoldFontPostScriptName = "PlusJakartaSans-ExtraBold"',
            "drawerFraction: CGFloat = 0.30",
            "holdDuration: Double = 0.4",
            "barrelDeadZoneDegrees: Double = 12",
        )
        for token in expected_tokens:
            with self.subTest(token=token):
                self.assertIn(token, self.tokens)
        self.assertIn("static let oled = Color(red: 0, green: 0, blue: 0)", self.tokens)
        expected_colors = (
            "22.0 / 255, green: 22.0 / 255, blue: 24.0 / 255",
            "226.0 / 255, green: 226.0 / 255, blue: 236.0 / 255",
            "132.0 / 255, green: 155.0 / 255, blue: 181.0 / 255",
            "130.0 / 255, green: 167.0 / 255, blue: 146.0 / 255",
            "158.0 / 255, green: 146.0 / 255, blue: 184.0 / 255",
            "221.0 / 255, green: 183.0 / 255, blue: 255.0 / 255",
        )
        for color in expected_colors:
            with self.subTest(color=color):
                self.assertIn(color, self.tokens)
        self.assertNotRegex(self.tokens, r"(?i)#[fF](?:fF)?(?:cC00|59b0b)(?:[fF]{0,2})")

    def test_app_launches_the_empty_native_editor_and_registers_the_font(self):
        self.assertIn("CodaCanvas(store: editorStore).preferredColorScheme(.dark)", self.app)
        self.assertIn("EditorTopBar(store: store)", self.views)
        self.assertIn("TimelineStripView(store: store)", self.views)
        self.assertIn("ChordStripView(store: store)", self.views)
        self.assertIn("PianoRollView(store: store)", self.views)
        self.assertIn('accessibilityIdentifier("font.registration")', self.views)
        self.assertIn("font-registered", self.views)
        self.assertIn("CodaDesignTokens.Colors.oled", self.views)
        self.assertIn(".ignoresSafeArea()", self.views)
        self.assertIn(".statusBarHidden(true)", self.views)
        self.assertIn("touch.type == .pencil", self.input_bridge)
        self.assertIn("UITouch.TouchType.direct.rawValue", self.input_bridge)
        self.assertIn("recognizer.rollAngle", self.input_bridge)

    def test_scene_root_hosts_swiftui_and_requests_landscape_lock(self):
        self.assertRegex(
            self.project,
            r"(?m)^        UIApplicationSceneManifest:\n"
            r"          UIApplicationSupportsMultipleScenes: false\n"
            r"          UISceneConfigurations:\n"
            r"            UIWindowSceneSessionRoleApplication:\n"
            r"              - UISceneConfigurationName: Coda\n"
            r"                UISceneDelegateClassName: \$\(PRODUCT_MODULE_NAME\)\.CodaSceneDelegate\n",
        )
        self.assertRegex(
            self.app, r"@main\s+final class CodaApp: UIResponder, UIApplicationDelegate"
        )
        scene_delegate = re.search(
            r"(?ms)^@MainActor\nfinal class CodaSceneDelegate: UIResponder, UIWindowSceneDelegate \{"
            r"\n(.*?)^\}", self.app
        )
        self.assertIsNotNone(scene_delegate)
        for connection in (
            "var window: UIWindow?",
            "willConnectTo session: UISceneSession",
            "UIWindow(windowScene: windowScene)",
            "window.rootViewController = CodaHostingController(",
            "rootView: CodaCanvas(store: editorStore).preferredColorScheme(.dark)",
            "self.window = window",
            "window.makeKeyAndVisible()",
        ):
            with self.subTest(connection=connection):
                self.assertIn(connection, scene_delegate.group(1))
        hosting_controller = re.search(
            r"(?ms)^private final class CodaHostingController<Content: View>: "
            r"UIHostingController<Content> \{\n(.*?)^\}", self.app
        )
        self.assertIsNotNone(hosting_controller)
        self.assertRegex(
            hosting_controller.group(1),
            r"override var supportedInterfaceOrientations: UIInterfaceOrientationMask"
            r"\s*\{\s*\.landscape\s*\}",
        )
        self.assertRegex(
            hosting_controller.group(1),
            r"override var prefersInterfaceOrientationLocked: Bool\s*\{\s*true\s*\}",
        )

    def test_runtime_has_no_external_package_declarations(self):
        self.assertNotIn("packages:", self.project)
        self.assertNotIn("package:", self.project)

    def test_combined_m1_scheme_and_screenshot_artifacts_are_narrowly_wired(self):
        workflow = (ROOT / ".github" / "workflows" / "unsigned-ipa.yml").read_text(
            encoding="utf-8"
        )
        for target in ("codaUITests", "CodaMusicTests", "CodaInteractionTests", "CodaAudioTests"):
            with self.subTest(target=target):
                self.assertIn(f"        - {target}", self.project)
        self.assertIn("CodaInteractionTests:", self.project)
        self.assertIn("-resultBundlePath build/generated/coda-m1-tests.xcresult", workflow)
        self.assertIn("xcrun xcresulttool export attachments", workflow)
        self.assertIn("-default-test-execution-time-allowance 180", workflow)
        self.assertIn("-maximum-test-execution-time-allowance 240", workflow)
        self.assertIn("Prepare exact iPadOS 27.2 simulator destination", workflow)
        self.assertIn("xcrun simctl bootstatus \"$udid\" -b", workflow)
        self.assertIn("build/generated/ui-attachments/manifest.json", workflow)
        for name in (
            "M1-empty-editor.png",
            "M1-four-bar-fixture.png",
            "M1-synth-drawer.png",
            "M1-radial-edge-fixture.png",
        ):
            with self.subTest(attachment=name):
                self.assertIn(name, workflow)
                self.assertIn(name, (ROOT / "scripts" / "export_ui_screenshots.py").read_text(encoding="utf-8"))
        self.assertNotIn("coda-m1-tests.xcresult", workflow.split("path: |", 1)[-1])


if __name__ == "__main__":
    unittest.main()
