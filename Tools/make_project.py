#!/usr/bin/env python3
"""Generate the small dependency-free Xcode project deterministically."""
from pathlib import Path
from source_files import swift_sources
root=Path(__file__).resolve().parents[1]
files=swift_sources(root)
def ident(n): return f'{n:024X}'
objects=[]
def add(n,s): objects.append(f'{ident(n)} = {{ {s} }};')
refs=[];build=[]
for i,p in enumerate(files):
 r=100+i;b=200+i;refs.append(ident(r));build.append(ident(b))
 add(r,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{p.relative_to(root)}"; sourceTree = "<group>";')
 add(b,f'isa = PBXBuildFile; fileRef = {ident(r)};')
add(1,f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2720; }}; buildConfigurationList = {ident(10)}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {ident(2)}; productRefGroup = {ident(3)}; projectDirPath = ""; projectRoot = ""; targets = ({ident(4)});')
add(2,f'isa = PBXGroup; children = ({",".join(refs)}, {ident(9)}, {ident(3)}); sourceTree = "<group>";')
add(3,f'isa = PBXGroup; children = ({ident(5)}); name = Products; sourceTree = "<group>";')
add(4,f'isa = PBXNativeTarget; buildConfigurationList = {ident(11)}; buildPhases = ({ident(6)}, {ident(7)}, {ident(8)}); buildRules = (); dependencies = (); name = "oMLX Inspector"; productName = "oMLX Inspector"; productReference = {ident(5)}; productType = "com.apple.product-type.application";')
add(5,'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "oMLX Inspector.app"; sourceTree = BUILT_PRODUCTS_DIR;')
add(6,f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(build)}); runOnlyForDeploymentPostprocessing = 0;')
add(7,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add(8,f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident(16)}); runOnlyForDeploymentPostprocessing = 0;')
add(9,'isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/AppIcon.icns; sourceTree = "<group>";')
add(16,f'isa = PBXBuildFile; fileRef = {ident(9)};')
for n,configs in [(10,(12,13)),(11,(14,15))]:add(n,f'isa = XCConfigurationList; buildConfigurations = ({ident(configs[0])},{ident(configs[1])}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for n,name in [(12,'Debug'),(13,'Release')]:add(n,f'isa = XCBuildConfiguration; buildSettings = {{ SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 27.0; SWIFT_VERSION = 6.0; CLANG_ENABLE_MODULES = YES; }}; name = {name};')
for n,name in [(14,'Debug'),(15,'Release')]:
 opt='-Onone' if name=='Debug' else '-O'
 add(n,f'isa = XCBuildConfiguration; buildSettings = {{ PRODUCT_NAME = "oMLX Inspector"; PRODUCT_BUNDLE_IDENTIFIER = local.omlx.inspector; INFOPLIST_FILE = Resources/Info.plist; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_HARDENED_RUNTIME = YES; SWIFT_OPTIMIZATION_LEVEL = "{opt}"; SWIFT_STRICT_CONCURRENCY = complete; COMBINE_HIDPI_IMAGES = YES; }}; name = {name};')
p=root/'oMLX Inspector.xcodeproj';p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {ident(1)}; }}\n')
