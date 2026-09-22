#!/usr/bin/env python3
"""Generate AudioSplit.xcodeproj with both app targets.

The SwiftPM package stays the source of truth for the engine, the CLI harnesses
and the tests — `swift test` must keep working from a terminal. The Xcode project
exists to build, sign and ship the apps, and consumes the package products so
there is exactly one copy of every source file.

Two targets, because the platforms can do different things:

  AudioSplit        macOS   the routing engine; needs the Core Audio HAL
  AudioSplitRemote  iOS     a remote control; iOS has no HAL at all

Regenerate with:  python3 Scripts/generate-xcodeproj.py
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "AudioSplit.xcodeproj"

TARGETS = [
    {
        "name": "AudioSplit",
        "sources": "Sources/AudioSplitApp",
        "plist": "Sources/AudioSplitApp/Info.plist",
        "bundle_id": "com.audiosplit.AudioSplit",
        "product": "AudioSplitEngine",
        "sdk": "macosx",
        "resources": ["Resources/AppIcon.icns"],
        "settings": [
            "MACOSX_DEPLOYMENT_TARGET = 14.4;",
            "SUPPORTED_PLATFORMS = macosx;",
            'LD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n'
            '\t\t\t\t\t"@executable_path/../Frameworks",\n\t\t\t\t);',
        ],
    },
    {
        "name": "AudioSplitRemote",
        "sources": "Sources/AudioSplitRemote",
        "plist": "Sources/AudioSplitRemote/Info.plist",
        "bundle_id": "com.audiosplit.AudioSplitRemote",
        "product": "AudioSplitShared",
        "sdk": "iphoneos",
        "resources": [],
        "settings": [
            "IPHONEOS_DEPLOYMENT_TARGET = 17.0;",
            "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";",
            # 1,2 = iPhone and iPad, both from one binary.
            'TARGETED_DEVICE_FAMILY = "1,2";',
            "SUPPORTS_MACCATALYST = NO;",
            'LD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n'
            '\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t);',
        ],
    },
]


def oid(*parts):
    """Stable 24-hex object id, so regenerating produces a minimal diff."""
    return hashlib.sha256("::".join(parts).encode()).hexdigest()[:24].upper()


def main():
    file_refs, build_files, groups = [], [], []
    target_blocks, config_blocks, config_lists = [], [], []
    package_products, phase_blocks = [], []
    target_ids, product_children = [], []
    group_children = []

    for target in TARGETS:
        name = target["name"]
        sources = sorted((ROOT / target["sources"]).rglob("*.swift"))
        if not sources:
            print(f"no Swift sources under {target['sources']}", file=sys.stderr)
            return 1

        ids = {
            "target": oid("target", name),
            "product": oid("product", name + ".app"),
            "group": oid("group", name),
            "sources": oid("phase", "sources", name),
            "frameworks": oid("phase", "frameworks", name),
            "resources": oid("phase", "resources", name),
            "configlist": oid("configlist", name),
            "debug": oid("config", name, "Debug"),
            "release": oid("config", name, "Release"),
            "packageProduct": oid("packageproduct", name, target["product"]),
            "packageBuildFile": oid("buildfile", name, target["product"]),
        }
        target_ids.append(f'\t\t\t\t{ids["target"]} /* {name} */,')
        product_children.append(f'\t\t\t\t{ids["product"]} /* {name}.app */,')
        group_children.append(f'\t\t\t\t{ids["group"]} /* {name} */,')

        children, source_entries = [], []
        for path in sources:
            rel = path.relative_to(ROOT).as_posix()
            ref = oid("fileref", rel)
            build = oid("buildfile", rel)
            file_refs.append(
                f'\t\t{ref} /* {path.name} */ = {{isa = PBXFileReference; '
                f'lastKnownFileType = sourcecode.swift; name = "{path.name}"; '
                f'path = "{rel}"; sourceTree = "<group>"; }};'
            )
            build_files.append(
                f'\t\t{build} /* {path.name} in Sources */ = {{isa = PBXBuildFile; '
                f'fileRef = {ref} /* {path.name} */; }};'
            )
            children.append(f'\t\t\t\t{ref} /* {path.name} */,')
            source_entries.append(f'\t\t\t\t{build} /* {path.name} in Sources */,')

        # Info.plist shows in the group but is never compiled.
        plist_ref = oid("fileref", target["plist"])
        file_refs.append(
            f'\t\t{plist_ref} /* Info.plist */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = text.plist.xml; name = "Info.plist"; '
            f'path = "{target["plist"]}"; sourceTree = "<group>"; }};'
        )
        children.append(f'\t\t\t\t{plist_ref} /* Info.plist */,')

        resource_entries = []
        for resource in target["resources"]:
            ref = oid("fileref", name, resource)
            build = oid("buildfile", name, resource)
            leaf = pathlib.Path(resource).name
            file_refs.append(
                f'\t\t{ref} /* {leaf} */ = {{isa = PBXFileReference; '
                f'lastKnownFileType = image.icns; name = "{leaf}"; '
                f'path = "{resource}"; sourceTree = "<group>"; }};'
            )
            build_files.append(
                f'\t\t{build} /* {leaf} in Resources */ = {{isa = PBXBuildFile; '
                f'fileRef = {ref} /* {leaf} */; }};'
            )
            children.append(f'\t\t\t\t{ref} /* {leaf} */,')
            resource_entries.append(f'\t\t\t\t{build} /* {leaf} in Resources */,')

        build_files.append(
            f'\t\t{ids["packageBuildFile"]} /* {target["product"]} in Frameworks */ = '
            f'{{isa = PBXBuildFile; productRef = {ids["packageProduct"]} '
            f'/* {target["product"]} */; }};'
        )
        package_products.append(
            f'\t\t{ids["packageProduct"]} /* {target["product"]} */ = {{\n'
            f'\t\t\tisa = XCSwiftPackageProductDependency;\n'
            f'\t\t\tproductName = {target["product"]};\n\t\t}};'
        )

        file_refs.append(
            f'\t\t{ids["product"]} /* {name}.app */ = {{isa = PBXFileReference; '
            f'explicitFileType = wrapper.application; includeInIndex = 0; '
            f'path = {name}.app; sourceTree = BUILT_PRODUCTS_DIR; }};'
        )

        groups.append(
            f'\t\t{ids["group"]} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n'
            f'\t\t\tchildren = (\n' + "\n".join(children) + "\n\t\t\t);\n"
            f'\t\t\tname = {name};\n\t\t\tsourceTree = "<group>";\n\t\t}};'
        )

        phase_blocks.append(
            f'\t\t{ids["sources"]} /* Sources */ = {{\n'
            f'\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n'
            f'\t\t\tfiles = (\n' + "\n".join(source_entries) + "\n\t\t\t);\n"
            f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};'
        )
        phase_blocks.append(
            f'\t\t{ids["frameworks"]} /* Frameworks */ = {{\n'
            f'\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n'
            f'\t\t\tfiles = (\n\t\t\t\t{ids["packageBuildFile"]} '
            f'/* {target["product"]} in Frameworks */,\n\t\t\t);\n'
            f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};'
        )
        phase_blocks.append(
            f'\t\t{ids["resources"]} /* Resources */ = {{\n'
            f'\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n'
            f'\t\t\tfiles = (\n' + "\n".join(resource_entries) + "\n\t\t\t);\n"
            f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};'
        )

        target_blocks.append(
            f'\t\t{ids["target"]} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n'
            f'\t\t\tbuildConfigurationList = {ids["configlist"]} '
            f'/* Build configuration list for PBXNativeTarget "{name}" */;\n'
            f'\t\t\tbuildPhases = (\n\t\t\t\t{ids["sources"]} /* Sources */,\n'
            f'\t\t\t\t{ids["frameworks"]} /* Frameworks */,\n'
            f'\t\t\t\t{ids["resources"]} /* Resources */,\n\t\t\t);\n'
            f'\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n'
            f'\t\t\tname = {name};\n'
            f'\t\t\tpackageProductDependencies = (\n\t\t\t\t{ids["packageProduct"]} '
            f'/* {target["product"]} */,\n\t\t\t);\n'
            f'\t\t\tproductName = {name};\n'
            f'\t\t\tproductReference = {ids["product"]} /* {name}.app */;\n'
            f'\t\t\tproductType = "com.apple.product-type.application";\n\t\t}};'
        )

        extra = "\n".join(f"\t\t\t\t{line}" for line in target["settings"])
        common = (
            f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
            f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
            f'\t\t\t\tENABLE_HARDENED_RUNTIME = YES;\n'
            f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n'
            f'\t\t\t\tINFOPLIST_FILE = "{target["plist"]}";\n'
            f'\t\t\t\tMARKETING_VERSION = 1.0;\n'
            f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {target["bundle_id"]};\n'
            f'\t\t\t\tPRODUCT_NAME = {name};\n'
            f'\t\t\t\tSDKROOT = {target["sdk"]};\n'
            f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
            f'\t\t\t\tSWIFT_VERSION = 6.0;\n' + extra
        )
        for config, key in (("Debug", "debug"), ("Release", "release")):
            config_blocks.append(
                f'\t\t{ids[key]} /* {config} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n'
                f'\t\t\tbuildSettings = {{\n{common}\n\t\t\t}};\n'
                f'\t\t\tname = {config};\n\t\t}};'
            )
        config_lists.append(
            f'\t\t{ids["configlist"]} /* Build configuration list for '
            f'PBXNativeTarget "{name}" */ = {{\n\t\t\tisa = XCConfigurationList;\n'
            f'\t\t\tbuildConfigurations = (\n\t\t\t\t{ids["debug"]} /* Debug */,\n'
            f'\t\t\t\t{ids["release"]} /* Release */,\n\t\t\t);\n'
            f'\t\t\tdefaultConfigurationIsVisible = 0;\n'
            f'\t\t\tdefaultConfigurationName = Release;\n\t\t}};'
        )

    project_id = oid("project")
    main_group = oid("group", "main")
    products_group = oid("group", "Products")
    package_ref = oid("packageref", "local")
    project_list = oid("configlist", "project")
    project_debug = oid("config", "project", "Debug")
    project_release = oid("config", "project", "Release")

    project_common = (
        "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n"
        "\t\t\t\tCLANG_ENABLE_MODULES = YES;\n"
        "\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;\n"
        "\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;\n"
        "\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;\n"
    )

    groups.append(
        f'\t\t{products_group} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n' + "\n".join(product_children) + "\n\t\t\t);\n"
        f'\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};'
    )
    groups.append(
        f'\t\t{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
        + "\n".join(group_children)
        + f'\n\t\t\t\t{products_group} /* Products */,\n\t\t\t);\n'
        f'\t\t\tsourceTree = "<group>";\n\t\t}};'
    )

    pbxproj = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{chr(10).join(groups)}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
{chr(10).join(target_blocks)}
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{project_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t}};
\t\t\tbuildConfigurationList = {project_list} /* Build configuration list for PBXProject "AudioSplit" */;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group};
\t\t\tpackageReferences = (
\t\t\t\t{package_ref} /* XCLocalSwiftPackageReference "." */,
\t\t\t);
\t\t\tproductRefGroup = {products_group} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
{chr(10).join(target_ids)}
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{chr(10).join(phase_blocks)}
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{project_debug} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{project_common}\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{project_release} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{project_common}\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
{chr(10).join(config_blocks)}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{project_list} /* Build configuration list for PBXProject "AudioSplit" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{project_debug} /* Debug */,
\t\t\t\t{project_release} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
{chr(10).join(config_lists)}
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
\t\t{package_ref} /* XCLocalSwiftPackageReference "." */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = .;
\t\t}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
{chr(10).join(package_products)}
/* End XCSwiftPackageProductDependency section */
\t}};
\trootObject = {project_id} /* Project object */;
}}
"""

    PROJECT.mkdir(parents=True, exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(pbxproj)
    print(f"generated {PROJECT.relative_to(ROOT)} with {len(TARGETS)} app target(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
