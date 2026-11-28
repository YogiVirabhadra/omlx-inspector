#!/usr/bin/env python3
"""Generate the small, dependency-free Xcode project deterministically.

Run this whenever Swift files are added, removed, or renamed under `Sources`:

    python3 Tools/make_project.py

Object identifiers are fixed numbers rendered as 24 hex digits, so regenerating an
unchanged source tree produces an identical project file.
"""
from pathlib import Path

from source_files import swift_sources

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'oMLX Inspector.xcodeproj'

# Fixed object identifiers.
PROJECT_OBJECT = 1
MAIN_GROUP = 2
PRODUCTS_GROUP = 3
APP_TARGET = 4
APP_PRODUCT = 5
SOURCES_PHASE = 6
FRAMEWORKS_PHASE = 7
RESOURCES_PHASE = 8
ICON_FILE = 9
PROJECT_CONFIGURATIONS = 10
TARGET_CONFIGURATIONS = 11
PROJECT_DEBUG, PROJECT_RELEASE = 12, 13
TARGET_DEBUG, TARGET_RELEASE = 14, 15
ICON_BUILD_FILE = 16
FIRST_SOURCE_REFERENCE = 100
FIRST_SOURCE_BUILD_FILE = 200


def ident(number: int) -> str:
    return f'{number:024X}'


def generate() -> str:
    objects: list[str] = []

    def add(number: int, body: str) -> None:
        objects.append(f'{ident(number)} = {{ {body} }};')

    source_references: list[str] = []
    source_build_files: list[str] = []
    for offset, path in enumerate(swift_sources(ROOT)):
        reference = FIRST_SOURCE_REFERENCE + offset
        build_file = FIRST_SOURCE_BUILD_FILE + offset
        source_references.append(ident(reference))
        source_build_files.append(ident(build_file))
        add(reference, 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                       f'path = "{path.relative_to(ROOT)}"; sourceTree = "<group>";')
        add(build_file, f'isa = PBXBuildFile; fileRef = {ident(reference)};')

    add(PROJECT_OBJECT,
        'isa = PBXProject; attributes = { LastUpgradeCheck = 2720; }; '
        f'buildConfigurationList = {ident(PROJECT_CONFIGURATIONS)}; compatibilityVersion = "Xcode 14.0"; '
        f'developmentRegion = en; knownRegions = (en, Base); mainGroup = {ident(MAIN_GROUP)}; '
        f'productRefGroup = {ident(PRODUCTS_GROUP)}; projectDirPath = ""; projectRoot = ""; '
        f'targets = ({ident(APP_TARGET)});')
    add(MAIN_GROUP,
        f'isa = PBXGroup; children = ({",".join(source_references)}, {ident(ICON_FILE)}, '
        f'{ident(PRODUCTS_GROUP)}); sourceTree = "<group>";')
    add(PRODUCTS_GROUP, f'isa = PBXGroup; children = ({ident(APP_PRODUCT)}); name = Products; sourceTree = "<group>";')
    add(APP_TARGET,
        f'isa = PBXNativeTarget; buildConfigurationList = {ident(TARGET_CONFIGURATIONS)}; '
        f'buildPhases = ({ident(SOURCES_PHASE)}, {ident(FRAMEWORKS_PHASE)}, {ident(RESOURCES_PHASE)}); '
        'buildRules = (); dependencies = (); name = "oMLX Inspector"; productName = "oMLX Inspector"; '
        f'productReference = {ident(APP_PRODUCT)}; productType = "com.apple.product-type.application";')
    add(APP_PRODUCT,
        'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; '
        'path = "oMLX Inspector.app"; sourceTree = BUILT_PRODUCTS_DIR;')
    add(SOURCES_PHASE,
        f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(source_build_files)}); '
        'runOnlyForDeploymentPostprocessing = 0;')
    add(FRAMEWORKS_PHASE,
        'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); '
        'runOnlyForDeploymentPostprocessing = 0;')
    add(RESOURCES_PHASE,
        f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident(ICON_BUILD_FILE)}); '
        'runOnlyForDeploymentPostprocessing = 0;')
    add(ICON_FILE,
        'isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/AppIcon.icns; '
        'sourceTree = "<group>";')
    add(ICON_BUILD_FILE, f'isa = PBXBuildFile; fileRef = {ident(ICON_FILE)};')

    for configuration_list, (debug, release) in [
        (PROJECT_CONFIGURATIONS, (PROJECT_DEBUG, PROJECT_RELEASE)),
        (TARGET_CONFIGURATIONS, (TARGET_DEBUG, TARGET_RELEASE)),
    ]:
        add(configuration_list,
            f'isa = XCConfigurationList; buildConfigurations = ({ident(debug)},{ident(release)}); '
            'defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

    for number, name in [(PROJECT_DEBUG, 'Debug'), (PROJECT_RELEASE, 'Release')]:
        add(number,
            'isa = XCBuildConfiguration; buildSettings = { SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 27.0; '
            f'SWIFT_VERSION = 6.0; CLANG_ENABLE_MODULES = YES; }}; name = {name};')

    for number, name in [(TARGET_DEBUG, 'Debug'), (TARGET_RELEASE, 'Release')]:
        optimization = '-Onone' if name == 'Debug' else '-O'
        add(number,
            'isa = XCBuildConfiguration; buildSettings = { PRODUCT_NAME = "oMLX Inspector"; '
            'PRODUCT_BUNDLE_IDENTIFIER = io.github.yogivirabhadra.omlx-inspector; INFOPLIST_FILE = Resources/Info.plist; '
            'CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_HARDENED_RUNTIME = YES; '
            f'SWIFT_OPTIMIZATION_LEVEL = "{optimization}"; SWIFT_STRICT_CONCURRENCY = complete; '
            f'COMBINE_HIDPI_IMAGES = YES; }}; name = {name};')

    return ('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
            + '\n'.join(objects)
            + f'\n}}; rootObject = {ident(PROJECT_OBJECT)}; }}\n')


def main() -> None:
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / 'project.pbxproj').write_text(generate())


if __name__ == '__main__':
    main()
