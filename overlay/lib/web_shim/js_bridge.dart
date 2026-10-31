import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

@JS('window.__flclashWeb.asyncJsonRequest')
external JSPromise<JSString> _jsAsyncJsonRequest(
  JSString method,
  JSString url,
  JSString? jsonBody,
);

@JS('window.__flclashWeb.syncJsonRequest')
external JSString _jsSyncJsonRequest(
  JSString method,
  JSString url,
  JSString? jsonBody,
);

@JS('window.__flclashWeb.syncBinaryWrite')
external JSString _jsSyncBinaryWrite(
  JSString url,
  JSString base64Body,
);

@JS('window.__flclashWeb.syncReadBase64')
external JSString _jsSyncReadBase64(JSString vpath);

@JS('window.__flclashWeb.triggerDownload')
external JSBoolean _jsTriggerDownload(
  JSString filename,
  JSString base64Data,
);

@JS('window.__flclashWeb.pickFile')
external JSPromise<JSString> _jsPickFile();

@JS('window.__flclashWeb.evalClashScript')
external JSString _jsEvalClashScript(
  JSString scriptSource,
  JSString configJsonStr,
  JSString profileName,
);

@JS('window.location.protocol')
external JSString get _jsLocationProtocol;

@JS('window.location.host')
external JSString get _jsLocationHost;

@JS('window.open')
external JSAny? _jsWindowOpen(JSString url, JSString target);

class JsBridge {
  static String get wsProtocol =>
      _jsLocationProtocol.toDart == 'https:' ? 'wss:' : 'ws:';

  static String get host => _jsLocationHost.toDart;

  static String wsUrl(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return '$wsProtocol//$host$normalized';
  }

  static void openUrl(String url) {
    _jsWindowOpen(url.toJS, '_blank'.toJS);
  }

  static Future<Map<String, dynamic>> asyncJsonRequest(
    String method,
    String url, [
    Map<String, dynamic>? body,
  ]) async {
    try {
      final jsPromise = _jsAsyncJsonRequest(
        method.toJS,
        url.toJS,
        body != null ? jsonEncode(body).toJS : null,
      );
      final jsString = await jsPromise.toDart;
      final raw = jsString.toDart;
      final outer = jsonDecode(raw) as Map<String, dynamic>;
      final status = outer['status'] as int? ?? 500;
      final text = outer['text'] as String? ?? '';
      if (status >= 200 && status < 300 && text.isNotEmpty) {
        try {
          return jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {
          return {'ok': true, 'text': text};
        }
      }
      return {
        'ok': false,
        'status': status,
        'error': outer['error'] ?? text,
      };
    } catch (e) {
      return {
        'ok': false,
        'status': 500,
        'error': e.toString(),
      };
    }
  }

  static Map<String, dynamic> syncJsonRequest(
    String method,
    String url, [
    Map<String, dynamic>? body,
  ]) {
    final raw = _jsSyncJsonRequest(
      method.toJS,
      url.toJS,
      body != null ? jsonEncode(body).toJS : null,
    ).toDart;
    final outer = jsonDecode(raw) as Map<String, dynamic>;
    final status = outer['status'] as int? ?? 500;
    final text = outer['text'] as String? ?? '';
    if (status >= 200 && status < 300 && text.isNotEmpty) {
      try {
        return jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        return {'ok': true, 'text': text};
      }
    }
    return {
      'ok': false,
      'status': status,
      'error': outer['error'] ?? text,
    };
  }

  static Map<String, dynamic> syncBinaryWrite(String url, Uint8List bytes) {
    final b64 = base64Encode(bytes);
    final raw = _jsSyncBinaryWrite(url.toJS, b64.toJS).toDart;
    final outer = jsonDecode(raw) as Map<String, dynamic>;
    final status = outer['status'] as int? ?? 500;
    final text = outer['text'] as String? ?? '';
    if (status >= 200 && status < 300 && text.isNotEmpty) {
      try {
        return jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        return {'ok': true};
      }
    }
    return {'ok': false, 'status': status};
  }

  static Map<String, dynamic> syncReadBase64(String vpath) {
    final raw = _jsSyncReadBase64(vpath.toJS).toDart;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static bool triggerDownload(String filename, Uint8List bytes) {
    return _jsTriggerDownload(filename.toJS, base64Encode(bytes).toJS).toDart;
  }

  static Future<Map<String, dynamic>?> pickFile() async {
    final raw = (await _jsPickFile().toDart).toDart;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['cancelled'] == true) {
      return null;
    }
    return map;
  }

  static String evalClashScript(
    String scriptSource,
    String configJsonStr, [
    String profileName = '',
  ]) {
    final raw = _jsEvalClashScript(
      scriptSource.toJS,
      configJsonStr.toJS,
      profileName.toJS,
    ).toDart;
    final res = jsonDecode(raw) as Map<String, dynamic>;
    if (res['ok'] == true && res['data'] is String) {
      return res['data'] as String;
    }
    throw Exception(res['error'] ?? 'Script evaluation failed');
  }
}

