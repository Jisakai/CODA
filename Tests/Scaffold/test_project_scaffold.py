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
            "wordmarkOpacity: Double = 0.72",
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

    def test_app_launches_into_the_black_fonted_canvas(self):
        self.assertIn("rootView: CodaCanvas().preferredColorScheme(.dark)", self.app)
        self.assertIn("CodaDesignTokens.Colors.oled", self.app)
        self.assertIn("lightFontPostScriptName", self.app)
        self.assertIn("UIFont(", self.app)
        self.assertIn("font-registered", self.app)
        self.assertIn("wordmarkOpacity", self.app)
        self.assertIn('accessibilityIdentifier("coda.wordmark")', self.app)
        self.assertIn(".ignoresSafeArea()", self.app)
        self.assertIn(".statusBarHidden(true)", self.app)

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
            r"(?ms)^final class CodaSceneDelegate: UIResponder, UIWindowSceneDelegate \{"
            r"\n(.*?)^\}", self.app
        )
        self.assertIsNotNone(scene_delegate)
        for connection in (
            "var window: UIWindow?",
            "willConnectTo session: UISceneSession",
            "UIWindow(windowScene: windowScene)",
            "window.rootViewController = CodaHostingController(",
            "rootView: CodaCanvas().preferredColorScheme(.dark)",
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


if __name__ == "__main__":
    unittest.main()
