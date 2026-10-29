import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Alignment, Brightness, Color, Offset, Rect, Size;

import 'dart_io.dart';
import 'js_bridge.dart';
import 'vfs.dart';
import 'web_core_bridge.dart';

// ---------------------------------------------------------------------------
// path_provider shim
// ---------------------------------------------------------------------------

Future<Directory> getApplicationSupportDirectory() async => Directory('/data');

Future<Directory> getTemporaryDirectory() async => Directory('/tmp');

Future<Directory> getApplicationCacheDirectory() async => Directory('/tmp');

Future<Directory?> getDownloadsDirectory() async => Directory('/downloads');

Future<Directory> getApplicationDocumentsDirectory() async =>
    Directory('/data');

// ---------------------------------------------------------------------------
// file_picker shim
// ---------------------------------------------------------------------------

enum FileType { any, media, image, video, audio, custom }

class PlatformFile {
  final String name;
  final String? path;
  final int size;
  final Uint8List? bytes;
  final Stream<List<int>>? readStream;
  final String? identifier;

  PlatformFile({
    required this.name,
    this.path,
    required this.size,
    this.bytes,
    this.readStream,
    this.identifier,
  });

  String? get extension =>
      name.contains('.') ? name.split('.').last : null;

  Future<Uint8List> readAsBytes() async {
    if (bytes != null) return bytes!;
    if (path != null && WebFileSystem.instance.isFile(path!)) {
      return WebFileSystem.instance.readBytes(path!);
    }
    return Uint8List(0);
  }
}

class FilePickerResult {
  final List<PlatformFile> files;

  const FilePickerResult(this.files);

  bool get isSinglePick => files.length == 1;
  int get count => files.length;
  List<String?> get paths => files.map((f) => f.path).toList();
  List<String?> get names => files.map((f) => f.name).toList();
}

class FilePicker {
  FilePicker._();

  static final FilePicker platform = FilePicker._();

  static Future<PlatformFile?> pickFile({
    String? initialDirectory,
    List<String>? allowedExtensions,
  }) async {
    final res = await platform.pickFiles(
      initialDirectory: initialDirectory,
      allowedExtensions: allowedExtensions,
    );
    if (res == null || res.files.isEmpty) return null;
    return res.files.first;
  }

  static Future<Uri?> saveFile({
    String? dialogTitle,
    required String fileName,
    String? initialDirectory,
    Uint8List? bytes,
  }) async {
    final safeName = fileName.isNotEmpty ? fileName : 'flclash_export';
    final downloadPath = '/downloads/$safeName';
    if (bytes != null) {
      WebFileSystem.instance.writeBytes(downloadPath, bytes);
    }
    return Uri.file(downloadPath);
  }

  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(dynamic)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final picked = await JsBridge.pickFile();
    if (picked == null) return null;

    final name = picked['name']?.toString() ?? 'upload.dat';
    final b64 = picked['base64']?.toString() ?? '';
    final bytes = b64.isEmpty ? Uint8List(0) : base64Decode(b64);
    final vpath = '/tmp/$name';
    WebFileSystem.instance.writeBytes(vpath, bytes);

    return FilePickerResult([
      PlatformFile(
        name: name,
        path: vpath,
        size: bytes.length,
        bytes: bytes,
      ),
    ]);
  }

  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    return '/downloads';
  }

  Future<bool?> clearTemporaryFiles() async => true;
}

// ---------------------------------------------------------------------------
// window plugin shim
// ---------------------------------------------------------------------------

enum TitleBarStyle { normal, hidden }

enum WindowEffect { none, transparent, blur, acrylic, mica, glass }

enum WindowEvent {
  close('close'),
  focus('focus'),
  blur('blur'),
  show('show'),
  hide('hide'),
  maximize('maximize'),
  unmaximize('unmaximize'),
  minimize('minimize'),
  restore('restore'),
  geometryChanged('geometry-changed'),
  enterFullScreen('enter-full-screen'),
  leaveFullScreen('leave-full-screen'),
  shouldTerminate('should-terminate'),
  activate('activate');

  const WindowEvent(this.wireName);

  final String wireName;

  static WindowEvent? fromWireName(Object? name) {
    for (final event in values) {
      if (event.wireName == name) {
        return event;
      }
    }
    return null;
  }
}

abstract mixin class WindowListener {
  void onWindowClose() {}
  void onWindowFocus() {}
  void onWindowBlur() {}
  void onWindowShow() {}
  void onWindowHide() {}
  void onWindowMaximize() {}
  void onWindowUnmaximize() {}
  void onWindowMinimize() {}
  void onWindowRestore() {}
  void onWindowGeometryChanged() {}
  void onWindowEnterFullScreen() {}
  void onWindowLeaveFullScreen() {}
  void onWindowShouldTerminate() {}
  void onWindowActivate() {}
  void onWindowEvent(WindowEvent event) {}
}

class DesktopWindow {
  DesktopWindow._();

  static final DesktopWindow instance = DesktopWindow._();

  final ObserverList<WindowListener> _listeners =
      ObserverList<WindowListener>();

  List<WindowListener> get listeners => List<WindowListener>.of(_listeners);
  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(WindowListener listener) => _listeners.add(listener);
  void removeListener(WindowListener listener) => _listeners.remove(listener);

  Rect _bounds = const Rect.fromLTWH(0, 0, 1280, 800);
  bool _isMaximized = false;
  bool _isMinimized = false;
  bool _isFullScreen = false;
  bool _isAlwaysOnTop = false;

  Future<void> ensureInitialized() async {}
  Future<void> show({bool inactive = false}) async {}
  Future<void> hide() async {}
  Future<bool> isVisible() async => true;
  Future<void> focus() async {}
  Future<void> close() async {}
  Future<void> setPreventClose(bool value) async {}
  Future<bool> isMaximized() async => _isMaximized;
  Future<void> maximize() async => _isMaximized = true;
  Future<void> unmaximize() async => _isMaximized = false;
  Future<bool> isMinimized() async => _isMinimized;
  Future<void> minimize() async => _isMinimized = true;
  Future<void> restore() async {
    _isMinimized = false;
    _isMaximized = false;
  }

  Future<bool> isFullScreen() async => _isFullScreen;
  Future<void> setFullScreen(bool value) async => _isFullScreen = value;
  Future<Rect> getBounds() async => _bounds;
  Future<void> setBounds({Offset? position, Size? size}) async {
    _bounds = Rect.fromLTWH(
      position?.dx ?? _bounds.left,
      position?.dy ?? _bounds.top,
      size?.width ?? _bounds.width,
      size?.height ?? _bounds.height,
    );
  }

  Future<Size> getSize() async => _bounds.size;
  Future<void> setSize(Size size) => setBounds(size: size);
  Future<Offset> getPosition() async => _bounds.topLeft;
  Future<bool> isPositionSupported() async => false;
  Future<void> setPosition(Offset position) => setBounds(position: position);
  Future<void> setAlignment(Alignment alignment) async {}
  Future<void> center() async {}
  Future<void> setMinimumSize(Size size) async {}
  Future<bool> isAlwaysOnTop() async => _isAlwaysOnTop;
  Future<void> setAlwaysOnTop(bool value) async => _isAlwaysOnTop = value;
  Future<void> setTitleBarStyle(
    TitleBarStyle style, {
    bool windowButtonVisibility = true,
  }) async {}
  Future<void> setSkipTaskbar(bool value) async {}
  Future<void> setRoundedCorners(bool value) async {}
  Future<bool> isEffectSupported(WindowEffect effect) async => false;
  Future<void> setEffect(
    WindowEffect effect, {
    Color? tint,
    Brightness? brightness,
  }) async {}
  Future<void> startDragging() async {}
}

final DesktopWindow desktopWindow = DesktopWindow.instance;

Future<Offset> calcWindowPosition(Size windowSize, Alignment alignment) async {
  return Offset.zero;
}

// ---------------------------------------------------------------------------
// launch_at_startup shim
// ---------------------------------------------------------------------------

class LaunchAtStartup {
  LaunchAtStartup._();
  static final LaunchAtStartup instance = LaunchAtStartup._();

  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {}

  Future<bool> enable() async => true;
  Future<bool> disable() async => true;
  Future<bool> isEnabled() async => false;
}

final LaunchAtStartup launchAtStartup = LaunchAtStartup.instance;

// ---------------------------------------------------------------------------
// app_links shim
// ---------------------------------------------------------------------------

class AppLinks {
  Stream<Uri> get uriLinkStream => const Stream<Uri>.empty();
  Future<Uri?> getInitialLink() async => null;
}

// ---------------------------------------------------------------------------
// tray plugin shim
// ---------------------------------------------------------------------------

final class TrayCapabilities {
  const TrayCapabilities({
    required this.supported,
    required this.title,
    required this.toolTip,
    required this.iconEvents,
    required this.menuControl,
  });

  final bool supported;
  final bool title;
  final bool toolTip;
  final bool iconEvents;
  final bool menuControl;

  static const TrayCapabilities none = TrayCapabilities(
    supported: false,
    title: false,
    toolTip: false,
    iconEvents: false,
    menuControl: false,
  );

  static TrayCapabilities of(TargetPlatform platform) => none;
}

typedef TrayMenuItemSelectedCallback = void Function();

sealed class TrayMenuItem {
  const TrayMenuItem();
}

final class TrayMenuAction extends TrayMenuItem {
  const TrayMenuAction({
    required this.label,
    this.detail,
    this.enabled = true,
    this.onSelected,
  });

  final String label;
  final String? detail;
  final bool enabled;
  final TrayMenuItemSelectedCallback? onSelected;
}

final class TrayMenuCheckbox extends TrayMenuItem {
  const TrayMenuCheckbox({
    required this.label,
    required this.checked,
    this.detail,
    this.enabled = true,
    this.onSelected,
  });

  final String label;
  final bool checked;
  final String? detail;
  final bool enabled;
  final TrayMenuItemSelectedCallback? onSelected;
}

final class TrayMenuSubmenu extends TrayMenuItem {
  const TrayMenuSubmenu({
    required this.label,
    required this.items,
    this.detail,
    this.enabled = true,
  });

  final String label;
  final List<TrayMenuItem> items;
  final String? detail;
  final bool enabled;
}

final class TrayMenuSeparator extends TrayMenuItem {
  const TrayMenuSeparator();
}

enum TrayIconPosition { leading, trailing }

final class TrayIcon {
  const TrayIcon.asset(
    this.asset, {
    this.isTemplate = false,
    this.size = 18,
    this.position = TrayIconPosition.leading,
  });

  final String asset;
  final bool isTemplate;
  final int size;
  final TrayIconPosition position;
}

final class TraySpec {
  const TraySpec({required this.icon, this.toolTip = '', this.menu = const []});

  final TrayIcon icon;
  final String toolTip;
  final List<TrayMenuItem> menu;
}

sealed class TrayEvent {
  const TrayEvent();
}

final class TrayIconActivated extends TrayEvent {
  const TrayIconActivated();
}

final class TrayMenuRequested extends TrayEvent {
  const TrayMenuRequested();
}

final class TrayMenuItemSelected extends TrayEvent {
  const TrayMenuItemSelected(this.item);
  final TrayMenuItem item;
}

final class Tray {
  Tray._();

  static final Tray instance = Tray._();

  Stream<TrayEvent> get events => const Stream<TrayEvent>.empty();
  TrayCapabilities get capabilities => TrayCapabilities.none;
  bool get isVisible => false;

  Future<void> show(TraySpec spec) async {}
  Future<void> setTitle(String title) async {}
  Future<void> hide() async {}
  Future<void> openMenu() async {}
  void resetForTesting() {}
}

// ---------------------------------------------------------------------------
// proxy plugin shim
// ---------------------------------------------------------------------------

typedef ProxyProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      bool runInShell,
    });

typedef ProxyExecutableChecker = Future<bool> Function(String executable);

class Proxy {
  Proxy({
    ProxyProcessRunner? processRunner,
    ProxyExecutableChecker? executableChecker,
  });

  Future<bool> startProxy(
    int port, [
    List<String> bypassDomain = const [],
  ]) async => true;

  Future<bool> stopProxy() async => true;
}

// ---------------------------------------------------------------------------
// connectivity_plus shim
// ---------------------------------------------------------------------------

enum ConnectivityResult {
  bluetooth,
  wifi,
  ethernet,
  mobile,
  none,
  vpn,
  other,
}

class Connectivity {
  static final StreamController<List<ConnectivityResult>> _sharedController =
      StreamController<List<ConnectivityResult>>.broadcast();
  static bool _bridgeHooked = false;

  Connectivity() {
    if (!_bridgeHooked) {
      _bridgeHooked = true;
      WebCoreBridge.instance.addNetworkChangeListener(() {
        if (!_sharedController.isClosed) {
          _sharedController.add(const [ConnectivityResult.ethernet]);
        }
      });
    }
  }

  Future<List<ConnectivityResult>> checkConnectivity() async => const [
    ConnectivityResult.ethernet,
  ];

  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    late final StreamController<List<ConnectivityResult>> controller;
    StreamSubscription<List<ConnectivityResult>>? sub;
    controller = StreamController<List<ConnectivityResult>>.broadcast(
      onListen: () {
        Future.microtask(() {
          if (!controller.isClosed) {
            controller.add(const [ConnectivityResult.ethernet]);
          }
        });
        sub = _sharedController.stream.listen((event) {
          if (!controller.isClosed) {
            controller.add(event);
          }
        });
      },
      onCancel: () {
        sub?.cancel();
      },
    );
    return controller.stream;
  }
}

