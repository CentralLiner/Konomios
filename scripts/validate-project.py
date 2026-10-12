#!/usr/bin/env python3
"""Validate the hand-authored Xcode project and its checked-in build inputs.

This runs on Linux as well as macOS. It checks project integrity, source/resource
membership, deployment settings, privacy declarations, and the shared test scheme.
It does not replace compilation or tests with Apple's iOS SDK.
"""

from __future__ import annotations

import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
TOKEN = re.compile(
    r'(?P<ignored>\s+|/\*.*?\*/|//[^\n]*)'
    r'|(?P<quoted>"(?:\\.|[^"\\])*")'
    r'|(?P<punct>[{}()=;,])'
    r'|(?P<atom>[^\s{}()=;,"/]+(?:/[^\s{}()=;,"/]*)*)',
    re.DOTALL,
)


def check(condition: bool, explanation: str) -> None:
    if not condition:
        raise ValueError(explanation)


def parse_project(text: str) -> dict:
    tokens = []
    cursor = 0
    while cursor < len(text):
        match = TOKEN.match(text, cursor)
        check(match is not None, f"Invalid project syntax at offset {cursor}")
        assert match is not None
        cursor = match.end()
        if match.lastgroup != "ignored":
            tokens.append((match.lastgroup, match.group()))
    index = 0

    def take(expected: str | None = None) -> tuple[str, str]:
        nonlocal index
        check(index < len(tokens), "Unexpected end of project file")
        token = tokens[index]
        index += 1
        check(expected is None or token[1] == expected, f"Expected {expected!r}; got {token[1]!r}")
        return token

    def value():
        kind, token = take()
        if token == "{":
            result = {}
            while index < len(tokens) and tokens[index][1] != "}":
                key = value()
                check(isinstance(key, str), "Dictionary key must be a string")
                check(key not in result, f"Duplicate project dictionary key: {key}")
                take("=")
                result[key] = value()
                take(";")
            take("}")
            return result
        if token == "(":
            result = []
            while index < len(tokens) and tokens[index][1] != ")":
                result.append(value())
                if tokens[index][1] == ",":
                    take(",")
                else:
                    check(tokens[index][1] == ")", "Array values must be comma separated")
            take(")")
            return result
        check(kind in ("quoted", "atom"), f"Unexpected value token: {token}")
        return json.loads(token) if kind == "quoted" else token

    result = value()
    check(index == len(tokens), "Unexpected content after project dictionary")
    check(isinstance(result, dict), "Project root must be a dictionary")
    return result


def validate() -> None:
    project = parse_project((ROOT / "KonomiTV.xcodeproj/project.pbxproj").read_text())
    objects = project["objects"]
    check(objects[project["rootObject"]]["isa"] == "PBXProject", "Invalid project root")

    def references(value):
        if isinstance(value, dict):
            for key, child in value.items():
                yield from references(key)
                yield from references(child)
        elif isinstance(value, list):
            for child in value:
                yield from references(child)
        elif isinstance(value, str) and re.fullmatch(r"[A-F0-9]{24}", value):
            yield value

    for reference in references(project):
        check(reference in objects, f"Dangling object reference: {reference}")

    root_project = objects[project["rootObject"]]
    file_paths = {}

    def walk_group(identifier: str, parent: Path, ancestors: frozenset[str]) -> None:
        check(identifier not in ancestors, "Cycle in project groups")
        entry = objects[identifier]
        if entry["isa"] == "PBXGroup":
            check(entry.get("sourceTree") == "<group>", "Unexpected group source tree")
            directory = parent / entry.get("path", "")
            for child in entry["children"]:
                walk_group(child, directory, ancestors | {identifier})
        elif entry["isa"] == "PBXFileReference" and entry["sourceTree"] == "<group>":
            path = parent / entry["path"]
            check(path.exists(), f"Missing project input: {path.relative_to(ROOT)}")
            check(identifier not in file_paths, f"File reference appears in multiple groups: {path}")
            file_paths[identifier] = path

    walk_group(root_project["mainGroup"], ROOT, frozenset())
    targets = {objects[target]["name"]: objects[target] for target in root_project["targets"]}
    check(set(targets) == {"KonomiTV", "KonomiTVTests"}, "Expected app and unit-test targets")
    app = targets["KonomiTV"]
    check(app["productType"] == "com.apple.product-type.application", "App target is not an application")

    def phase_files(target: dict, phase_type: str) -> set[Path]:
        phases = [objects[item] for item in target["buildPhases"] if objects[item]["isa"] == phase_type]
        check(len(phases) == 1, f"Expected one {phase_type} on {target['name']}")
        paths = []
        for identifier in phases[0]["files"]:
            build_file = objects[identifier]
            check(build_file["isa"] == "PBXBuildFile", "Invalid build phase entry")
            reference = build_file["fileRef"]
            check(reference in file_paths, f"Build input has no local path: {reference}")
            paths.append(file_paths[reference])
        check(len(paths) == len(set(paths)), f"Duplicate inputs in {phase_type}")
        return set(paths)

    sources = phase_files(app, "PBXSourcesBuildPhase")
    check(sources == set((ROOT / "KonomiTV").rglob("*.swift")), "App source files and project membership differ")
    check(len(sources) >= 7, "Expected the complete wrapper implementation")
    check(sum("@main" in path.read_text() for path in sources) == 1, "Expected one Swift app entry point")
    test_sources = phase_files(targets["KonomiTVTests"], "PBXSourcesBuildPhase")
    check(test_sources == set((ROOT / "Tests").glob("*.swift")), "Test source files and project membership differ")
    check(len(test_sources) >= 2, "Expected address and playback-session tests")
    resources = phase_files(app, "PBXResourcesBuildPhase")
    check(resources == {
        ROOT / "KonomiTV/Resources/MediaBridge.js",
        ROOT / "KonomiTV/PrivacyInfo.xcprivacy",
        ROOT / "KonomiTV/Assets.xcassets",
    }, "Missing or unexpected app resources")

    def configurations(owner: dict) -> dict[str, dict]:
        identifiers = objects[owner["buildConfigurationList"]]["buildConfigurations"]
        return {objects[item]["name"]: objects[item]["buildSettings"] for item in identifiers}

    project_settings = configurations(root_project)
    check(set(project_settings) == {"Debug", "Release"}, "Debug/Release project configurations required")
    for name, target_settings in configurations(app).items():
        settings = project_settings[name] | target_settings
        check(settings["IPHONEOS_DEPLOYMENT_TARGET"] == "18.3", "Minimum iOS version must be 18.3")
        check(settings["SWIFT_VERSION"] == "5.0", "Swift language version must be 5.0")
        check(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "$(BUNDLE_IDENTIFIER)", "Bundle ID must be configurable")
        check(settings["BUNDLE_IDENTIFIER"] == "dev.konomitv.wrapper", "Unexpected default bundle identifier")
        check(settings["INFOPLIST_FILE"] == "KonomiTV/Info.plist", "Unexpected Info.plist path")
        check(settings["TARGETED_DEVICE_FAMILY"] == "1,2", "iPhone/iPad device families required")
        check(settings["SUPPORTED_PLATFORMS"] == "iphoneos iphonesimulator", "Device and simulator builds required")
        check(settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon", "App icon not configured")
        check("DEVELOPMENT_TEAM" not in settings, "Signing team must not be required")

    with (ROOT / "KonomiTV/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    check("audio" in info["UIBackgroundModes"], "Background audio mode is required for PiP")
    check(bool(info.get("NSLocalNetworkUsageDescription")), "Local network usage description missing")
    check("UILaunchScreen" in info, "Launch screen declaration missing")
    ats = info.get("NSAppTransportSecurity", {})
    check(not ats.get("NSAllowsArbitraryLoads"), "ATS must require secure native connections")
    check(not ats.get("NSAllowsArbitraryLoadsInWebContent"), "Web content must retain ATS protection")
    for key in ("UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"):
        check({"UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}.issubset(info[key]), "Portrait and landscape orientations are required")
    with (ROOT / "KonomiTV/PrivacyInfo.xcprivacy").open("rb") as stream:
        privacy = plistlib.load(stream)
    check(privacy["NSPrivacyTracking"] is False, "Wrapper must not declare tracking")
    check(any(item["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryUserDefaults" and "CA92.1" in item["NSPrivacyAccessedAPITypeReasons"] for item in privacy["NSPrivacyAccessedAPITypes"]), "UserDefaults reason declaration missing")

    scheme = ET.parse(ROOT / "KonomiTV.xcodeproj/xcshareddata/xcschemes/KonomiTV.xcscheme").getroot()
    for reference in scheme.findall(".//BuildableReference"):
        check(reference.attrib["BlueprintIdentifier"] in objects, "Scheme references an unknown target")
    testables = scheme.findall("./TestAction/Testables/TestableReference/BuildableReference")
    check(len(testables) == 1 and testables[0].attrib["BlueprintName"] == "KonomiTVTests", "Shared scheme must run unit tests")
    dependencies = [objects[item] for item in targets["KonomiTVTests"]["dependencies"]]
    check(any(objects[item["target"]]["name"] == "KonomiTV" for item in dependencies), "Hosted unit-test target must depend on the app")

    catalog = ROOT / "KonomiTV/Assets.xcassets/AppIcon.appiconset"
    icon = json.loads((catalog / "Contents.json").read_text())
    check(bool(icon["images"]), "App icon images missing")
    for item in icon["images"]:
        png = (catalog / item["filename"]).read_bytes()
        check(png.startswith(b"\x89PNG\r\n\x1a\n"), "App icon must be a PNG")
        width, height, bits, color = struct.unpack(">IIBB", png[16:26])
        expected = round(float(item["size"].split("x")[0]) * float(item.get("scale", "1x")[:-1]))
        check(width == height == expected and bits == 8 and color == 2, "App icon dimensions or RGB format are invalid")
    print(f"Validated Xcode project: {len(sources)} app sources, {len(test_sources)} test sources, {len(resources)} resources, shared test scheme, privacy manifest, and icon.")


if __name__ == "__main__":
    try:
        validate()
    except (KeyError, OSError, ValueError, ET.ParseError, plistlib.InvalidFileException) as error:
        print(f"Project validation failed: {error}", file=sys.stderr)
        sys.exit(1)
