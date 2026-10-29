#!/usr/bin/env python3
"""
prepare_web.py - Non-destructive build-time patcher for compiling FlClash to native Flutter Web (FlClash-web).

Usage:
  python3 scripts/prepare_web.py --apply   # Apply Web shims & import rewrites before `flutter build web`
  python3 scripts/prepare_web.py --revert  # Restore all upstream tracked files to their exact original state
"""

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
FLCLASH_DIR = ROOT_DIR / "FlClash"
OVERLAY_DIR = ROOT_DIR / "overlay"
BACKUP_MANIFEST = FLCLASH_DIR / ".web_patch_backup.json"

WEB_SYSTEM_FONTS_DART = """import 'package:flutter/foundation.dart' show visibleForTesting;

@visibleForTesting
Future<List<String>> Function() systemFontFamiliesReader = () async =>
    sortFontFamilies(const [
      'Roboto',
      'Noto Sans SC',
      'Noto Sans TC',
      'Noto Sans JP',
      'Inter',
      'JetBrains Mono',
      'DejaVu Sans',
      'Arial',
      'Helvetica',
      'monospace',
      'sans-serif',
    ]);

Future<List<String>> loadSystemFontFamilies() async {
  try {
    return await systemFontFamiliesReader();
  } catch (_) {
    return const [];
  }
}

@visibleForTesting
List<String> sortFontFamilies(Iterable<String> families) {
  final unique = <String, String>{};
  for (final family in families) {
    final name = family.trim();
    if (name.isEmpty || name.startsWith('.')) {
      continue;
    }
    unique.putIfAbsent(name.toLowerCase(), () => name);
  }
  return unique.values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

@visibleForTesting
List<String> androidFontFamilies(String fontsXml) => [
  for (final match in RegExp(
    r'<family\\b[^>]*\\bname="([^"]+)"',
  ).allMatches(fontsXml))
    match.group(1)!,
];
"""

NOOP_HOOK_DART = """import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {});
}
"""

RUST_API_PUBSPEC_WEB = """name: rust_api
description: "Flutter Rust Bridge FFI package (Web shim mode)."
version: 0.0.1
publish_to: none

environment:
  sdk: '>=3.9.2 <4.0.0'
  flutter: '>=3.3.0'

dependencies:
  archive: any
  code_assets: ^1.2.1
  flutter:
    sdk: flutter
  flutter_rust_bridge: 2.13.0
  flutter_rust_bridge_hooks: 2.13.0
  path: any

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
"""

LIB_IMPORT_REWRITES = [
    (
        re.compile(r"""^(import|export)\s+['"]dart:io['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dart_io.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]dart:ffi['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dart_ffi.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]dart:isolate['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dart_io.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:ffi/ffi\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dart_ffi.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:win32/win32\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dart_ffi.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:win32_registry/win32_registry\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dart_ffi.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:archive/archive_io\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/archive_io.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:dio/dio\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dio.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:dio/io\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/dio_io.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:drift/native\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/drift_native.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:drift_flutter/drift_flutter\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/drift_native.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:path_provider/path_provider\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:file_picker/file_picker\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:window/window\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:launch_at_startup/launch_at_startup\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:app_links/app_links\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:tray/tray\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:proxy/proxy\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]package:connectivity_plus/connectivity_plus\.dart['"](.*)$""", re.MULTILINE),
        r"\1 'package:fl_clash/web_shim/plugins_shim.dart'\2",
    ),
]

CODE_FORGE_IMPORT_REWRITES = [
    (
        re.compile(r"""^(import|export)\s+['"]dart:io['"](.*)$""", re.MULTILINE),
        r"\1 'package:rust_api/dart_io.dart'\2",
    ),
    (
        re.compile(r"""^(import|export)\s+['"]dart:isolate['"](.*)$""", re.MULTILINE),
        r"\1 'package:rust_api/dart_io.dart'\2",
    ),
]


def dedupe_imports(text: str) -> str:
    seen = set()
    out_lines = []
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("import 'package:fl_clash/web_shim/") or stripped.startswith(
            "import 'package:rust_api/"
        ):
            if stripped in seen:
                continue
            seen.add(stripped)
        out_lines.append(line)
    return "".join(out_lines)


def save_original(backups: dict, file_path: Path, created_files: list = None):
    rel = str(file_path.relative_to(FLCLASH_DIR))
    if created_files is not None and rel in created_files:
        return
    if rel not in backups and file_path.exists():
        backups[rel] = file_path.read_text(encoding="utf-8")


def apply_patches():
    if BACKUP_MANIFEST.exists():
        print("[prepare_web] Existing backup manifest found; reverting first to ensure clean state...")
        revert_patches()

    backups = {}
    created_files = []

    # 0. Copy overlay files into FlClash directory if overlay exists
    if OVERLAY_DIR.exists():
        for root, dirs, files in os.walk(OVERLAY_DIR):
            for file in files:
                src_path = Path(root) / file
                rel_path = src_path.relative_to(OVERLAY_DIR)
                dst_path = FLCLASH_DIR / rel_path
                dst_path.parent.mkdir(parents=True, exist_ok=True)
                if not dst_path.exists():
                    created_files.append(str(dst_path.relative_to(FLCLASH_DIR)))
                else:
                    save_original(backups, dst_path)
                shutil.copy2(src_path, dst_path)

    web_shim_dir = FLCLASH_DIR / "lib" / "web_shim"
    rust_api_lib = FLCLASH_DIR / "plugins" / "rust_api" / "lib"

    # 1. Copy canonical core shims into plugins/rust_api/lib so both code_forge and fl_clash share identical types
    shared_shim_files = [
        "js_bridge.dart",
        "vfs.dart",
        "web_core_bridge.dart",
        "dart_io.dart",
        "rust_api_editor.dart",
    ]
    for fname in shared_shim_files:
        src = web_shim_dir / fname
        dst = rust_api_lib / fname
        save_original(backups, dst)
        shutil.copyfile(src, dst)
        created_files.append(str(dst.relative_to(FLCLASH_DIR)))

        # Replace web_shim/<fname> with a re-export of package:rust_api/<fname>
        save_original(backups, src)
        src.write_text(f"export 'package:rust_api/{fname}';\n", encoding="utf-8")

    # Copy rust_api.dart into plugins/rust_api/lib/rust_api.dart
    rust_api_main_src = web_shim_dir / "rust_api.dart"
    rust_api_main_dst = rust_api_lib / "rust_api.dart"
    save_original(backups, rust_api_main_dst)
    shutil.copyfile(rust_api_main_src, rust_api_main_dst)

    save_original(backups, rust_api_main_src)
    rust_api_main_src.write_text("export 'package:rust_api/rust_api.dart';\n", encoding="utf-8")

    # Update plugins/rust_api/lib/editor.dart
    rust_api_editor_entry = rust_api_lib / "editor.dart"
    save_original(backups, rust_api_editor_entry)
    rust_api_editor_entry.write_text("export 'rust_api_editor.dart';\n", encoding="utf-8")

    # Update plugins/rust_api/pubspec.yaml
    rust_api_pubspec = FLCLASH_DIR / "plugins" / "rust_api" / "pubspec.yaml"
    save_original(backups, rust_api_pubspec)
    rust_api_pubspec.write_text(RUST_API_PUBSPEC_WEB, encoding="utf-8")

    # 2. Neutralize native build hooks in plugins/setup and plugins/rust_api
    for hook_path in [
        FLCLASH_DIR / "plugins" / "setup" / "hook" / "build.dart",
        FLCLASH_DIR / "plugins" / "rust_api" / "hook" / "build.dart",
    ]:
        if hook_path.exists():
            save_original(backups, hook_path)
            hook_path.write_text(NOOP_HOOK_DART, encoding="utf-8")

    # 3. Replace lib/common/system_fonts.dart with web-compatible font list
    sys_fonts_path = FLCLASH_DIR / "lib" / "common" / "system_fonts.dart"
    if sys_fonts_path.exists():
        save_original(backups, sys_fonts_path)
        sys_fonts_path.write_text(WEB_SYSTEM_FONTS_DART, encoding="utf-8")

    # 4. Patch serviceStartTime() in lib/providers/actions/setup.dart so reconnecting browsers resume server state
    setup_action_path = FLCLASH_DIR / "lib" / "providers" / "actions" / "setup.dart"
    if setup_action_path.exists():
        content = setup_action_path.read_text(encoding="utf-8")
        target = "Future<DateTime?> serviceStartTime() async => service?.getRunTime();"
        replacement = (
            "Future<DateTime?> serviceStartTime() async {\n"
            "    if (WebFileSystem.instance.isCoreListening && WebFileSystem.instance.coreStartTimeMs > 0) {\n"
            "      return DateTime.fromMillisecondsSinceEpoch(WebFileSystem.instance.coreStartTimeMs);\n"
            "    }\n"
            "    return service?.getRunTime();\n"
            "  }"
        )
        if target in content:
            save_original(backups, setup_action_path)
            setup_action_path.write_text(content.replace(target, replacement, 1), encoding="utf-8")

    # 4b. Patch FileImage(File(path)) in lib/plugins/app.dart and pushClipRSuperellipse in lib/ui/liquid_glass.dart
    app_plugin_path = FLCLASH_DIR / "lib" / "plugins" / "app.dart"
    if app_plugin_path.exists():
        content = app_plugin_path.read_text(encoding="utf-8")
        if "return FileImage(File(path));" in content:
            save_original(backups, app_plugin_path)
            app_plugin_path.write_text(
                content.replace(
                    "return FileImage(File(path));",
                    "return MemoryImage(File(path).readAsBytesSync());",
                ),
                encoding="utf-8",
            )

    liquid_glass_path = FLCLASH_DIR / "lib" / "ui" / "liquid_glass.dart"
    if liquid_glass_path.exists():
        content = liquid_glass_path.read_text(encoding="utf-8")
        target_clip = "builder.pushClipRSuperellipse(corners.toRSuperellipse(rect));"
        if target_clip in content:
            save_original(backups, liquid_glass_path)
            liquid_glass_path.write_text(
                content.replace(
                    target_clip,
                    "builder.pushClipRSuperellipse(corners.toRSuperellipse(rect), clipBehavior: Clip.antiAlias);",
                ),
                encoding="utf-8",
            )

    # 4c. Expand DnsOverrideKey.normalProfileKeys in lib/enum/enum.dart and ensure fake-ip range & allow-lan DNS listen in lib/common/task.dart
    enum_path = FLCLASH_DIR / "lib" / "enum" / "enum.dart"
    if enum_path.exists():
        content = enum_path.read_text(encoding="utf-8")
        target_enum = (
            "  static const normalProfileKeys = {\n"
            "    listen,\n"
            "    ipv6,\n"
            "    enhancedMode,\n"
            "    fakeIpFilter,\n"
            "    fakeIpFilterMode,\n"
            "    defaultNameserver,\n"
            "    nameserver,\n"
            "    fallback,\n"
            "    proxyServerNameserver,\n"
            "    directNameserver,\n"
            "  };"
        )
        replacement_enum = (
            "  static const normalProfileKeys = {\n"
            "    enable,\n"
            "    listen,\n"
            "    useHosts,\n"
            "    useSystemHosts,\n"
            "    ipv6,\n"
            "    respectRules,\n"
            "    preferH3,\n"
            "    enhancedMode,\n"
            "    fakeIpRange,\n"
            "    fakeIpRange6,\n"
            "    fakeIpFilter,\n"
            "    fakeIpFilterMode,\n"
            "    fakeIpTtl,\n"
            "    defaultNameserver,\n"
            "    nameserver,\n"
            "    fallback,\n"
            "    proxyServerNameserver,\n"
            "    directNameserver,\n"
            "  };"
        )
        if target_enum in content:
            save_original(backups, enum_path)
            enum_path.write_text(content.replace(target_enum, replacement_enum, 1), encoding="utf-8")

    task_path = FLCLASH_DIR / "lib" / "common" / "task.dart"
    if task_path.exists():
        content = task_path.read_text(encoding="utf-8")
        target_task = (
            "  rawDns = mergeDnsOverride(\n"
            "    rawDns,\n"
            "    overrides.dns.overrideJson(\n"
            "      overrides.dnsOverrideKeys,\n"
            "      keepEmpty: data.keepEmptyDnsOverrides,\n"
            "    ),\n"
            "  );\n"
            "  rawConfig['dns'] = rawDns;"
        )
        replacement_task = (
            "  rawDns = mergeDnsOverride(\n"
            "    rawDns,\n"
            "    overrides.dns.overrideJson(\n"
            "      overrides.dnsOverrideKeys,\n"
            "      keepEmpty: data.keepEmptyDnsOverrides,\n"
            "    ),\n"
            "  );\n"
            "  if (overrides.dnsOverrideKeys.contains(DnsOverrideKey.enhancedMode) &&\n"
            "      overrides.dns.enhancedMode == DnsMode.fakeIp) {\n"
            "    rawDns['enable'] = true;\n"
            "    if (!overrides.dnsOverrideKeys.contains(DnsOverrideKey.fakeIpRange) &&\n"
            "        overrides.dns.fakeIpRange.isNotEmpty) {\n"
            "      rawDns['fake-ip-range'] = overrides.dns.fakeIpRange;\n"
            "    }\n"
            "  }\n"
            "  if (realPatchConfig.allowLan &&\n"
            "      !overrides.dnsOverrideKeys.contains(DnsOverrideKey.listen) &&\n"
            "      rawDns['listen'] is String &&\n"
            "      (rawDns['listen'] as String).startsWith('127.0.0.1:')) {\n"
            "    rawDns['listen'] = (rawDns['listen'] as String).replaceFirst('127.0.0.1:', '0.0.0.0:');\n"
            "  }\n"
            "  rawConfig['dns'] = rawDns;"
        )
        if target_task in content:
            save_original(backups, task_path)
            task_path.write_text(content.replace(target_task, replacement_task, 1), encoding="utf-8")

    network_path = FLCLASH_DIR / "lib" / "common" / "network.dart"
    if network_path.exists():
        content = network_path.read_text(encoding="utf-8")
        target_net = (
            "    if (nameLowCase.contains('wlan') ||\n"
            "        nameLowCase.contains('wi-fi') ||\n"
            "        nameLowCase == 'en0' ||\n"
            "        nameLowCase == 'eth0') {\n"
            "      return true;\n"
            "    }"
        )
        replacement_net = (
            "    if (nameLowCase.contains('flclash') ||\n"
            "        nameLowCase.contains('meta') ||\n"
            "        nameLowCase.contains('mihomo') ||\n"
            "        nameLowCase.contains('utun') ||\n"
            "        nameLowCase.contains('wlan') ||\n"
            "        nameLowCase.contains('wi-fi') ||\n"
            "        nameLowCase == 'en0' ||\n"
            "        nameLowCase == 'eth0') {\n"
            "      return true;\n"
            "    }"
        )
        if target_net in content:
            save_original(backups, network_path)
            network_path.write_text(content.replace(target_net, replacement_net, 1), encoding="utf-8")

    # 4e. Hide window header caption (minimize/maximize/close) on Web in lib/common/layout.dart
    layout_path = FLCLASH_DIR / "lib" / "common" / "layout.dart"
    if layout_path.exists():
        content = layout_path.read_text(encoding="utf-8")
        target_shows = (
            "bool showsWindowHeader({\n"
            "  required bool isDesktop,\n"
            "  required bool isMacOS,\n"
            "  required int version,\n"
            "  required bool isMobileView,\n"
            "}) {\n"
            "  if (!isDesktop) return false;\n"
            "  return !(isMacOS && (version <= 10 || !isMobileView));\n"
            "}"
        )
        replacement_shows = (
            "bool showsWindowHeader({\n"
            "  required bool isDesktop,\n"
            "  required bool isMacOS,\n"
            "  required int version,\n"
            "  required bool isMobileView,\n"
            "}) {\n"
            "  return false;\n"
            "}"
        )
        target_height = (
            "double getWindowHeaderHeight({required bool isDesktop, required bool isMacOS}) {\n"
            "  if (!isDesktop) return 0;\n"
            "  return isMacOS ? 28 : 32;\n"
            "}"
        )
        replacement_height = (
            "double getWindowHeaderHeight({required bool isDesktop, required bool isMacOS}) {\n"
            "  return 0;\n"
            "}"
        )
        if target_shows in content and target_height in content:
            save_original(backups, layout_path)
            content = content.replace(target_shows, replacement_shows, 1)
            content = content.replace(target_height, replacement_height, 1)
            layout_path.write_text(content, encoding="utf-8")

    # Also export vfs.dart from dart_io.dart so WebFileSystem is in scope in action.dart
    rust_dart_io = rust_api_lib / "dart_io.dart"
    rust_dart_io_text = rust_dart_io.read_text(encoding="utf-8")
    if "export 'vfs.dart';" not in rust_dart_io_text:
        rust_dart_io.write_text("export 'vfs.dart';\n" + rust_dart_io_text, encoding="utf-8")

    # 5. Rewrite imports in FlClash/lib/**/*.dart (excluding lib/web_shim/**)
    patched_count = 0
    for dart_file in (FLCLASH_DIR / "lib").rglob("*.dart"):
        if web_shim_dir in dart_file.parents:
            continue
        original = dart_file.read_text(encoding="utf-8")
        modified = original
        for pattern, repl in LIB_IMPORT_REWRITES:
            modified = pattern.sub(repl, modified)
        modified = dedupe_imports(modified)
        if modified != original:
            save_original(backups, dart_file)
            dart_file.write_text(modified, encoding="utf-8")
            patched_count += 1

    # 6. Rewrite imports in FlClash/plugins/code_forge/lib/**/*.dart
    code_forge_lib = FLCLASH_DIR / "plugins" / "code_forge" / "lib"
    for dart_file in code_forge_lib.rglob("*.dart"):
        original = dart_file.read_text(encoding="utf-8")
        modified = original
        for pattern, repl in CODE_FORGE_IMPORT_REWRITES:
            modified = pattern.sub(repl, modified)
        modified = dedupe_imports(modified)
        if modified != original:
            save_original(backups, dart_file)
            dart_file.write_text(modified, encoding="utf-8")
            patched_count += 1

    manifest_data = {
        "backups": backups,
        "created_files": created_files,
    }
    BACKUP_MANIFEST.write_text(json.dumps(manifest_data, indent=2), encoding="utf-8")
    print(f"[prepare_web] Successfully patched {len(backups)} files for Flutter Web build.")


def revert_patches():
    if not BACKUP_MANIFEST.exists():
        print("[prepare_web] No backup manifest found; nothing to revert.")
        return

    manifest_data = json.loads(BACKUP_MANIFEST.read_text(encoding="utf-8"))
    backups = manifest_data.get("backups", {})
    created_files = manifest_data.get("created_files", [])

    created_set = set(created_files)
    for rel_path in created_files:
        target = FLCLASH_DIR / rel_path
        if target.exists():
            try:
                target.unlink()
            except Exception:
                pass

    for rel_path, original_content in backups.items():
        if rel_path in created_set:
            continue
        target = FLCLASH_DIR / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(original_content, encoding="utf-8")

    # Clean up overlay / temporary directories
    for d in [
        FLCLASH_DIR / "lib" / "web_shim",
        FLCLASH_DIR / "core" / "cmd" / "flclash-web",
        FLCLASH_DIR / "web",
    ]:
        if d.exists():
            shutil.rmtree(d, ignore_errors=True)

    BACKUP_MANIFEST.unlink()
    print(f"[prepare_web] Reverted {len(backups)} files to clean upstream state.")


def main():
    parser = argparse.ArgumentParser(description="Prepare FlClash for native Flutter Web compilation.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--apply", action="store_true", help="Apply Flutter Web shims and import rewrites")
    group.add_argument("--revert", action="store_true", help="Revert all patched files to original state")
    args = parser.parse_args()

    if args.apply:
        apply_patches()
    elif args.revert:
        revert_patches()


if __name__ == "__main__":
    main()
