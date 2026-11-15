#!/usr/bin/env python3
"""Generate the dependency-free Xcode project deterministically using only Python stdlib."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
PROJECT = IOS / "VictoriaTracker.xcodeproj"
objects = {}
existing_objects = {}
project_file = PROJECT / "project.pbxproj"
if project_file.exists():
    # Preserve signing choices made in Xcode when discovering new source files.
    parsed = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(project_file)],
                            check=True, capture_output=True, text=True)
    existing_objects = json.loads(parsed.stdout)["objects"]
def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def put(identifier, **values):
    objects[uid(identifier)] = values
    return uid(identifier)
def ref(path, kind):
    return put("file:" + path, isa="PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="<group>")
def build_ref(file_id):
    return put("build:" + file_id, isa="PBXBuildFile", fileRef=file_id)
def configs(name, base, settings):
    ids = []
    for mode in ("Debug", "Release"):
        values = dict(settings)
        old = existing_objects.get(uid(name + mode), {}).get("buildSettings", {})
        for key in ("DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY",
                    "PROVISIONING_PROFILE_SPECIFIER", "PROVISIONING_PROFILE",
                    "PRODUCT_BUNDLE_IDENTIFIER", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
            if key in old:
                values[key] = old[key]
        if name == "project":
            values.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O", DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
            if mode == "Debug": values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        item = dict(isa="XCBuildConfiguration", buildSettings=values, name=mode)
        if base: item["baseConfigurationReference"] = base
        ids.append(put(name + mode, **item))
    return put(name + "configs", isa="XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

sources = [ref(str(p.relative_to(IOS)), "sourcecode.swift") for p in sorted((IOS / "VictoriaTracker").rglob("*.swift"))]
tests = [ref(str(p.relative_to(IOS)) if p.is_relative_to(IOS) else "../" + str(p.relative_to(ROOT)), "sourcecode.swift") for p in sorted((ROOT / "tests/swift").glob("*.swift"))]
privacy = ref("VictoriaTracker/Resources/PrivacyInfo.xcprivacy", "text.xml")
catalogs = [ref(str(p.relative_to(IOS)), "text.json.xcstrings") for p in sorted((IOS / "VictoriaTracker/Resources").glob("*.xcstrings"))]
growth = [ref(str(p.relative_to(IOS)), "text") for p in sorted((IOS / "VictoriaTracker/Resources/Growth").glob("*.csv"))]
assets = [ref(str(p.relative_to(IOS)), "folder.assetcatalog") for p in sorted((IOS / "VictoriaTracker/Resources").glob("*.xcassets"))]
plist = ref("VictoriaTracker/Resources/Info.plist", "text.plist.xml")
base = ref("Config.xcconfig", "text.xcconfig")
app_product = put("app-product", isa="PBXFileReference", explicitFileType="wrapper.application", path="VictoriaTracker.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = put("test-product", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="VictoriaTrackerTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
products = put("products", isa="PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
main = put("main", isa="PBXGroup", children=sources + tests + catalogs + assets + growth + [privacy, plist, base, products], sourceTree="<group>")
app_sources = put("app-sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=[build_ref(s) for s in sources], runOnlyForDeploymentPostprocessing=0)
test_sources = put("test-sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=[build_ref(s) for s in tests], runOnlyForDeploymentPostprocessing=0)
resources = put("resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=[build_ref(privacy)] + [build_ref(c) for c in catalogs + assets + growth], runOnlyForDeploymentPostprocessing=0)
app_frameworks = put("app-frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
test_frameworks = put("test-frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
credential_guard = put("credential-guard", isa="PBXShellScriptBuildPhase", buildActionMask=2147483647,
    files=[], inputPaths=["$(SRCROOT)/../scripts/security_checks.py"], outputPaths=[],
    runOnlyForDeploymentPostprocessing=0, alwaysOutOfDate=1, name="Validate public client configuration",
    shellPath="/bin/sh", shellScript='/usr/bin/python3 -B "$SRCROOT/../scripts/security_checks.py" ios-config\n', showEnvVarsInLog=0)
shared = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "complete", "TARGETED_DEVICE_FAMILY": "1", "CODE_SIGN_STYLE": "Automatic", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES"}
project_configs = configs("project", None, shared)
app_configs = configs("app", base, {"PRODUCT_NAME": "VictoriaTracker", "PRODUCT_MODULE_NAME": "VictoriaTracker", "PRODUCT_BUNDLE_IDENTIFIER": "com.victoriatracker.app", "INFOPLIST_FILE": "VictoriaTracker/Resources/Info.plist", "ENABLE_TESTABILITY": "YES", "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "15", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]})
test_configs = configs("tests", base, {"PRODUCT_NAME": "VictoriaTrackerTests", "PRODUCT_BUNDLE_IDENTIFIER": "com.victoriatracker.app.tests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/VictoriaTracker.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/VictoriaTracker", "BUNDLE_LOADER": "$(TEST_HOST)", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]})
proxy = put("proxy", isa="PBXContainerItemProxy", containerPortal=uid("project"), proxyType=1, remoteGlobalIDString=uid("app"), remoteInfo="VictoriaTracker")
dependency = put("dependency", isa="PBXTargetDependency", target=uid("app"), targetProxy=proxy)
app = put("app", isa="PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[credential_guard, app_sources, app_frameworks, resources], buildRules=[], dependencies=[], name="VictoriaTracker", productName="VictoriaTracker", productReference=app_product, productType="com.apple.product-type.application")
test_target = put("tests", isa="PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=[test_sources, test_frameworks], buildRules=[], dependencies=[dependency], name="VictoriaTrackerTests", productName="VictoriaTrackerTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
root = put("project", isa="PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600", "TargetAttributes": {app: {"CreatedOnToolsVersion": "16.0"}, test_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app}}}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "zh-HK", "Base"], mainGroup=main, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, test_target])
def dump(value, depth=0):
    if isinstance(value, dict): return "{\n" + "".join("\t" * (depth + 1) + json.dumps(str(k)) + " = " + dump(v, depth + 1) + ";\n" for k, v in value.items()) + "\t" * depth + "}"
    if isinstance(value, list): return "(" + ", ".join(dump(v, depth) for v in value) + ("," if value else "") + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)
PROJECT.mkdir(parents=True, exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + dump({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": root}) + "\n")
scheme_dir = PROJECT / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
def buildable(id_, name, target):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id_}" BuildableName="{name}" BlueprintName="{target}" ReferencedContainer="container:VictoriaTracker.xcodeproj"/>'
(scheme_dir / "VictoriaTracker.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable(app, 'VictoriaTracker.app', 'VictoriaTracker')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable(test_target, 'VictoriaTrackerTests.xctest', 'VictoriaTrackerTests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable(app, 'VictoriaTracker.app', 'VictoriaTracker')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable(app, 'VictoriaTracker.app', 'VictoriaTracker')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated ios/VictoriaTracker.xcodeproj")
