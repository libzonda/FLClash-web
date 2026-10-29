import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'js_bridge.dart';

class VfsNode {
  String path;
  bool isDir;
  int size;
  int mtimeMs;
  Uint8List? bytes;

  VfsNode({
    required this.path,
    required this.isDir,
    this.size = 0,
    int? mtimeMs,
    this.bytes,
  }) : mtimeMs = mtimeMs ?? DateTime.now().millisecondsSinceEpoch;
}

class WebNetInterface {
  final String name;
  final List<String> addresses;

  WebNetInterface({required this.name, required this.addresses});
}

class WebFileSystem {
  WebFileSystem._();

  static final WebFileSystem instance = WebFileSystem._();

  final Map<String, VfsNode> _nodes = {};
  final List<WebNetInterface> _networkInterfaces = [];
  bool _initialized = false;
  bool isCoreListening = false;
  int coreStartTimeMs = 0;

  List<WebNetInterface> get networkInterfaces {
    ensureInitialized();
    return List.unmodifiable(_networkInterfaces);
  }

  void refreshNetworkInterfaces() {
    ensureInitialized();
    try {
      final res = JsBridge.syncJsonRequest('GET', '/api/fs/interfaces');
      if (res['networkInterfaces'] is List) {
        _networkInterfaces.clear();
        for (final item in (res['networkInterfaces'] as List)) {
          if (item is Map) {
            final name = item['name']?.toString() ?? 'eth0';
            final addrs =
                (item['addresses'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const [];
            _networkInterfaces.add(
              WebNetInterface(name: name, addresses: addrs),
            );
          }
        }
      }
    } catch (_) {}
  }

  String normalize(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return '/data';
    var cleaned = p.posix.normalize(
      trimmed.startsWith('/') ? trimmed : '/data/$trimmed',
    );
    if (cleaned.length > 1 && cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  bool _isLocalOnlyPath(String normPath) {
    return normPath == '/downloads' || normPath.startsWith('/downloads/');
  }

  void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _ensureLocalDirs();
    try {
      final snap = JsBridge.syncJsonRequest('GET', '/api/fs/snapshot');
      if (snap['entries'] is List) {
        for (final item in (snap['entries'] as List)) {
          if (item is! Map) continue;
          final path = normalize(item['path']?.toString() ?? '');
          final isDir = item['isDir'] == true;
          final size = (item['size'] as num?)?.toInt() ?? 0;
          final mtimeMs =
              (item['mtimeMs'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch;
          Uint8List? content;
          final b64 = item['contentBase64'] as String?;
          if (b64 != null && b64.isNotEmpty) {
            content = base64Decode(b64);
          }
          _nodes[path] = VfsNode(
            path: path,
            isDir: isDir,
            size: content?.length ?? size,
            mtimeMs: mtimeMs,
            bytes: content,
          );
          _ensureParentDirsInMemory(path);
        }
      }
      isCoreListening = snap['isListening'] == true;
      coreStartTimeMs = (snap['startTimeMs'] as num?)?.toInt() ?? 0;
      if (snap['networkInterfaces'] is List) {
        _networkInterfaces.clear();
        for (final item in (snap['networkInterfaces'] as List)) {
          if (item is Map) {
            final name = item['name']?.toString() ?? 'eth0';
            final addrs =
                (item['addresses'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const [];
            _networkInterfaces.add(
              WebNetInterface(name: name, addresses: addrs),
            );
          }
        }
      }
    } catch (_) {
      // Ignore snapshot errors in offline test environments
    }
  }

  void _ensureLocalDirs() {
    for (final dir in [
      '/',
      '/data',
      '/data/profiles',
      '/data/providers',
      '/tmp',
      '/downloads',
    ]) {
      _nodes[dir] = VfsNode(path: dir, isDir: true);
    }
  }

  void _ensureParentDirsInMemory(String normPath) {
    var current = p.posix.dirname(normPath);
    while (current.isNotEmpty && current != '/' && current != '.') {
      _nodes.putIfAbsent(current, () => VfsNode(path: current, isDir: true));
      final next = p.posix.dirname(current);
      if (next == current) break;
      current = next;
    }
  }

  VfsNode? stat(String rawPath) {
    ensureInitialized();
    final norm = normalize(rawPath);
    final cached = _nodes[norm];
    if (cached != null) return cached;
    if (_isLocalOnlyPath(norm)) return null;

    final remote = JsBridge.syncJsonRequest(
      'GET',
      '/api/fs/stat?path=${Uri.encodeQueryComponent(norm)}',
    );
    if (remote['exists'] == true) {
      final node = VfsNode(
        path: norm,
        isDir: remote['isDir'] == true,
        size: (remote['size'] as num?)?.toInt() ?? 0,
        mtimeMs:
            (remote['mtimeMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
      _nodes[norm] = node;
      _ensureParentDirsInMemory(norm);
      return node;
    }
    return null;
  }

  bool exists(String rawPath) => stat(rawPath) != null;

  bool isDirectory(String rawPath) => stat(rawPath)?.isDir == true;

  bool isFile(String rawPath) {
    final node = stat(rawPath);
    return node != null && !node.isDir;
  }

  Uint8List readBytes(String rawPath) {
    ensureInitialized();
    final norm = normalize(rawPath);
    final cached = _nodes[norm];
    if (cached != null && !cached.isDir && cached.bytes != null) {
      return Uint8List.fromList(cached.bytes!);
    }
    if (_isLocalOnlyPath(norm)) {
      throw Exception('File not found: $norm');
    }
    final remote = JsBridge.syncReadBase64(norm);
    if (remote['exists'] == true && remote['isDir'] != true) {
      final b64 = remote['contentBase64'] as String? ?? '';
      final bytes = b64.isEmpty ? Uint8List(0) : base64Decode(b64);
      final mtime =
          (remote['mtimeMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      _nodes[norm] = VfsNode(
        path: norm,
        isDir: false,
        size: bytes.length,
        mtimeMs: mtime,
        bytes: bytes,
      );
      _ensureParentDirsInMemory(norm);
      return Uint8List.fromList(bytes);
    }
    throw Exception('File not found: $norm');
  }

  void updateCacheFromServerWrite({
    required String rawPath,
    required int size,
    required int mtimeMs,
    Uint8List? bytes,
  }) {
    ensureInitialized();
    final norm = normalize(rawPath);
    _ensureParentDirsInMemory(norm);
    _nodes[norm] = VfsNode(
      path: norm,
      isDir: false,
      size: bytes?.length ?? size,
      mtimeMs: mtimeMs,
      bytes: bytes,
    );
  }

  void writeBytes(String rawPath, List<int> data, {bool append = false}) {
    ensureInitialized();
    final norm = normalize(rawPath);
    _ensureParentDirsInMemory(norm);
    final incoming = data is Uint8List ? data : Uint8List.fromList(data);
    Uint8List finalBytes;
    if (append && exists(norm) && isFile(norm)) {
      final existing = readBytes(norm);
      final builder = BytesBuilder(copy: false)
        ..add(existing)
        ..add(incoming);
      finalBytes = builder.toBytes();
    } else {
      finalBytes = Uint8List.fromList(incoming);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    _nodes[norm] = VfsNode(
      path: norm,
      isDir: false,
      size: finalBytes.length,
      mtimeMs: now,
      bytes: finalBytes,
    );

    if (norm.startsWith('/downloads/')) {
      final filename = p.posix.basename(norm);
      JsBridge.triggerDownload(filename, finalBytes);
      return;
    }

    final mode = append ? 'append' : 'write';
    JsBridge.syncBinaryWrite(
      '/api/fs/write?path=${Uri.encodeQueryComponent(norm)}&mode=$mode',
      append ? incoming : finalBytes,
    );
  }

  void mkdir(String rawPath, {bool recursive = false}) {
    ensureInitialized();
    final norm = normalize(rawPath);
    if (recursive) {
      _ensureParentDirsInMemory('$norm/child');
    } else {
      _nodes[norm] = VfsNode(path: norm, isDir: true);
    }
    if (!_isLocalOnlyPath(norm)) {
      JsBridge.syncJsonRequest(
        'POST',
        '/api/fs/mkdir?path=${Uri.encodeQueryComponent(norm)}&recursive=$recursive',
      );
    }
  }

  void delete(String rawPath, {bool recursive = false}) {
    ensureInitialized();
    final norm = normalize(rawPath);
    _nodes.remove(norm);
    if (recursive) {
      final prefix = '$norm/';
      _nodes.removeWhere((key, _) => key.startsWith(prefix));
    }
    if (!_isLocalOnlyPath(norm)) {
      JsBridge.syncJsonRequest(
        'POST',
        '/api/fs/delete?path=${Uri.encodeQueryComponent(norm)}&recursive=$recursive',
      );
    }
  }

  void rename(String fromRaw, String toRaw) {
    ensureInitialized();
    final from = normalize(fromRaw);
    final to = normalize(toRaw);
    if (from == to) return;

    final existing = stat(from);
    if (existing != null) {
      _ensureParentDirsInMemory(to);
      if (existing.isDir) {
        final prefix = '$from/';
        final updates = <String, VfsNode>{};
        final removals = <String>[from];
        for (final entry in _nodes.entries) {
          if (entry.key.startsWith(prefix)) {
            final suffix = entry.key.substring(from.length);
            final newPath = '$to$suffix';
            removals.add(entry.key);
            updates[newPath] = VfsNode(
              path: newPath,
              isDir: entry.value.isDir,
              size: entry.value.size,
              mtimeMs: entry.value.mtimeMs,
              bytes: entry.value.bytes,
            );
          }
        }
        for (final k in removals) {
          _nodes.remove(k);
        }
        _nodes[to] = VfsNode(path: to, isDir: true, mtimeMs: existing.mtimeMs);
        _nodes.addAll(updates);
      } else {
        final bytes = existing.bytes;
        _nodes.remove(from);
        _nodes[to] = VfsNode(
          path: to,
          isDir: false,
          size: existing.size,
          mtimeMs: DateTime.now().millisecondsSinceEpoch,
          bytes: bytes,
        );
      }
    }

    if (to.startsWith('/downloads/')) {
      final bytes = _nodes[to]?.bytes ?? readBytes(from);
      JsBridge.triggerDownload(p.posix.basename(to), bytes);
      return;
    }

    JsBridge.syncJsonRequest('POST', '/api/fs/rename', {
      'from': from,
      'to': to,
    });
  }

  void copy(String fromRaw, String toRaw) {
    ensureInitialized();
    final from = normalize(fromRaw);
    final to = normalize(toRaw);
    if (from == to) return;

    if (to.startsWith('/downloads/')) {
      final bytes = readBytes(from);
      _nodes[to] = VfsNode(
        path: to,
        isDir: false,
        size: bytes.length,
        bytes: bytes,
      );
      JsBridge.triggerDownload(p.posix.basename(to), bytes);
      return;
    }

    final srcNode = stat(from);
    if (srcNode != null && srcNode.bytes != null) {
      writeBytes(to, srcNode.bytes!);
      return;
    }

    final res = JsBridge.syncJsonRequest('POST', '/api/fs/copy', {
      'from': from,
      'to': to,
    });
    _ensureParentDirsInMemory(to);
    _nodes[to] = VfsNode(
      path: to,
      isDir: false,
      size: (res['size'] as num?)?.toInt() ?? (srcNode?.size ?? 0),
      mtimeMs:
          (res['mtimeMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  List<VfsNode> list(String rawDir, {bool recursive = false}) {
    ensureInitialized();
    final norm = normalize(rawDir);
    final prefix = norm == '/' ? '/' : '$norm/';
    final results = <VfsNode>[];
    for (final entry in _nodes.entries) {
      final path = entry.key;
      if (path == norm || !path.startsWith(prefix)) continue;
      final rel = path.substring(prefix.length);
      if (!recursive && rel.contains('/')) continue;
      results.add(entry.value);
    }
    return results;
  }
}

