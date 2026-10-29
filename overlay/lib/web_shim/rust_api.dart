import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'js_bridge.dart';
import 'web_core_bridge.dart';

export 'rust_api_editor.dart';

@JS('WebSocket')
extension type _JSWebSocket._(JSObject _) implements JSObject {
  external factory _JSWebSocket(JSString url);
  external int get readyState;
  external set onopen(JSFunction? handler);
  external set onmessage(JSFunction? handler);
  external set onclose(JSFunction? handler);
  external set onerror(JSFunction? handler);
  external void send(JSAny data);
  external void close();
}

@JS()
extension type _JSMessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

class RustLib {
  RustLib._();
  static final RustLib instance = RustLib._();

  bool _initialized = true;
  bool get initialized => _initialized;

  static Future<void> init() async {
    instance._initialized = true;
  }
}

bool get isRustLibInitialized => RustLib.instance.initialized;

class HotKeyFailure {
  final int id;
  final String reason;

  const HotKeyFailure({required this.id, required this.reason});

  @override
  int get hashCode => id.hashCode ^ reason.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HotKeyFailure &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          reason == other.reason;
}

enum HotKeyModifier { alt, capsLock, control, fn, meta, shift }

class HotKeySpec {
  final int id;
  final int key;
  final List<HotKeyModifier> modifiers;

  const HotKeySpec({
    required this.id,
    required this.key,
    required this.modifiers,
  });

  @override
  int get hashCode => id.hashCode ^ key.hashCode ^ modifiers.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HotKeySpec &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          key == other.key &&
          modifiers == other.modifiers;
}

Stream<int> hotKeyEvents() => const Stream<int>.empty();

Future<List<HotKeyFailure>> setHotKeys({required List<HotKeySpec> specs}) async {
  return const [];
}

Future<String> evaluateScript({
  required String script,
  required String config,
}) async {
  return JsBridge.evalClashScript(script, config);
}

enum IpcEventKind { connected, message, disconnected, failed }

class IpcEvent {
  final IpcEventKind kind;
  final int? pid;
  final Uint8List payload;
  final String? error;

  const IpcEvent({
    required this.kind,
    this.pid,
    required this.payload,
    this.error,
  });

  @override
  int get hashCode =>
      kind.hashCode ^ pid.hashCode ^ payload.hashCode ^ error.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IpcEvent &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          pid == other.pid &&
          payload == other.payload &&
          error == other.error;
}

class IpcServer {
  final String address;
  final StreamController<IpcEvent> _controller =
      StreamController<IpcEvent>.broadcast();
  final List<String> _pendingMessages = [];
  _JSWebSocket? _ws;
  bool _closed = false;

  IpcServer._(this.address) {
    WebCoreBridge.instance.registerServer(
      address,
      onConnect: _connectWebSocket,
      onDisconnect: _disconnectWebSocket,
    );
  }

  static Future<IpcServer> bind({required String address}) async {
    return IpcServer._(address);
  }

  void _connectWebSocket(int pid) {
    if (_closed) return;
    _ws?.close();
    final url = JsBridge.wsUrl('/ws/core');
    final ws = _JSWebSocket(url.toJS);
    _ws = ws;

    ws.onopen = ((JSAny? _) {
      if (_closed) return;
      _controller.add(
        IpcEvent(
          kind: IpcEventKind.connected,
          pid: pid,
          payload: Uint8List(0),
        ),
      );
      for (final msg in _pendingMessages) {
        ws.send(msg.toJS);
      }
      _pendingMessages.clear();
    }).toJS;

    ws.onmessage = ((_JSMessageEvent evt) {
      if (_closed) return;
      final data = evt.data;
      if (data != null && data.isA<JSString>()) {
        final str = (data as JSString).toDart;
        final bytes = Uint8List.fromList(utf8.encode(str));
        _controller.add(
          IpcEvent(kind: IpcEventKind.message, payload: bytes),
        );
      }
    }).toJS;

    ws.onclose = ((JSAny? _) {
      if (_closed) return;
      _controller.add(
        IpcEvent(
          kind: IpcEventKind.disconnected,
          payload: Uint8List(0),
        ),
      );
    }).toJS;

    ws.onerror = ((JSAny? err) {
      if (_closed) return;
      _controller.add(
        IpcEvent(
          kind: IpcEventKind.failed,
          payload: Uint8List(0),
          error: 'WebSocket connection error',
        ),
      );
    }).toJS;
  }

  void _disconnectWebSocket() {
    if (_closed) return;
    _ws?.close();
    _ws = null;
    if (!_controller.isClosed) {
      _controller.add(
        IpcEvent(
          kind: IpcEventKind.disconnected,
          payload: Uint8List(0),
        ),
      );
    }
  }

  Stream<IpcEvent> events() => _controller.stream;

  void send({required List<int> message}) {
    if (_closed) return;
    final text = utf8.decode(message);
    final ws = _ws;
    if (ws != null && ws.readyState == 1) {
      ws.send(text.toJS);
    } else {
      _pendingMessages.add(text);
    }
    if (text.contains('"setupConfig"') ||
        text.contains('"updateConfig"') ||
        text.contains('"startListener"') ||
        text.contains('"stopListener"')) {
      Future.delayed(const Duration(milliseconds: 500), () {
        WebCoreBridge.instance.notifyNetworkChanged();
      });
      Future.delayed(const Duration(milliseconds: 1500), () {
        WebCoreBridge.instance.notifyNetworkChanged();
      });
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    WebCoreBridge.instance.unregisterServer(address);
    _ws?.close();
    _ws = null;
    await _controller.close();
  }
}

