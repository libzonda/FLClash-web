import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'vfs.dart';

class EditorOpenError implements Exception {
  final EditorOpenErrorKind kind;
  final String message;

  const EditorOpenError({required this.kind, required this.message});

  @override
  String toString() => 'EditorOpenError(${kind.name}: $message)';
}

enum EditorOpenErrorKind { notFound, notUtf8, unreadable }

class GuideBlock {
  final int startLine;
  final int endLine;
  final int indentLevel;
  final int leadingSpaces;

  const GuideBlock({
    required this.startLine,
    required this.endLine,
    required this.indentLevel,
    required this.leadingSpaces,
  });

  @override
  int get hashCode =>
      startLine.hashCode ^
      endLine.hashCode ^
      indentLevel.hashCode ^
      leadingSpaces.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GuideBlock &&
          runtimeType == other.runtimeType &&
          startLine == other.startLine &&
          endLine == other.endLine &&
          indentLevel == other.indentLevel &&
          leadingSpaces == other.leadingSpaces;
}

class RustFoldRange {
  final int startLine;
  final int endLine;

  const RustFoldRange({required this.startLine, required this.endLine});

  @override
  int get hashCode => startLine.hashCode ^ endLine.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RustFoldRange &&
          runtimeType == other.runtimeType &&
          startLine == other.startLine &&
          endLine == other.endLine;
}

class RopeBridge {
  String _text;
  List<String>? _linesCache;
  List<int>? _lineStartOffsetsCache;
  bool _isDisposed = false;

  RopeBridge._(this._text);

  bool get isDisposed => _isDisposed;

  void dispose() {
    _isDisposed = true;
  }

  void _invalidate() {
    _linesCache = null;
    _lineStartOffsetsCache = null;
  }

  void _ensureLines() {
    if (_linesCache != null && _lineStartOffsetsCache != null) return;
    final lines = <String>[];
    final starts = <int>[0];
    var start = 0;
    for (var i = 0; i < _text.length; i++) {
      if (_text.codeUnitAt(i) == 10) {
        var lineEnd = i;
        if (lineEnd > start && _text.codeUnitAt(lineEnd - 1) == 13) {
          lineEnd--;
        }
        lines.add(_text.substring(start, lineEnd));
        start = i + 1;
        starts.add(start);
      }
    }
    var lastEnd = _text.length;
    if (lastEnd > start && _text.codeUnitAt(lastEnd - 1) == 13) {
      lastEnd--;
    }
    lines.add(_text.substring(start, lastEnd));
    _linesCache = lines;
    _lineStartOffsetsCache = starts;
  }

  static RopeBridge create({required String initialText}) {
    return RopeBridge._(initialText);
  }

  static Future<RopeBridge> fromUtf8({required List<int> bytes}) async {
    try {
      final str = utf8.decode(bytes);
      return RopeBridge._(str);
    } on FormatException catch (e) {
      throw EditorOpenError(
        kind: EditorOpenErrorKind.notUtf8,
        message: e.message,
      );
    }
  }

  static Future<RopeBridge> openFile({required String path}) async {
    if (!WebFileSystem.instance.isFile(path)) {
      throw EditorOpenError(
        kind: EditorOpenErrorKind.notFound,
        message: 'File not found: $path',
      );
    }
    try {
      final bytes = WebFileSystem.instance.readBytes(path);
      return await fromUtf8(bytes: bytes);
    } on EditorOpenError {
      rethrow;
    } catch (e) {
      throw EditorOpenError(
        kind: EditorOpenErrorKind.unreadable,
        message: e.toString(),
      );
    }
  }

  String getText() => _text;

  BigInt lenChars() => BigInt.from(_text.length);

  BigInt lenLines() {
    _ensureLines();
    return BigInt.from(_linesCache!.length);
  }

  String line({required BigInt lineIdx}) {
    _ensureLines();
    final idx = lineIdx.toInt();
    if (idx < 0 || idx >= _linesCache!.length) return '';
    return _linesCache![idx];
  }

  List<String> cachedLinesRange({
    required BigInt startLine,
    required BigInt endLine,
  }) {
    _ensureLines();
    final s = startLine.toInt().clamp(0, _linesCache!.length);
    final e = endLine.toInt().clamp(s, _linesCache!.length);
    return _linesCache!.sublist(s, e);
  }

  BigInt lineToChar({required BigInt lineIdx}) {
    _ensureLines();
    final idx = lineIdx.toInt();
    if (idx <= 0) return BigInt.zero;
    if (idx >= _lineStartOffsetsCache!.length) {
      return BigInt.from(_text.length);
    }
    return BigInt.from(_lineStartOffsetsCache![idx]);
  }

  BigInt charToLine({required BigInt charIdx}) {
    _ensureLines();
    final target = charIdx.toInt().clamp(0, _text.length);
    final starts = _lineStartOffsetsCache!;
    var low = 0;
    var high = starts.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (starts[mid] <= target) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return BigInt.from(math.max(0, high));
  }

  void insert({required BigInt charIdx, required String text}) {
    final idx = charIdx.toInt().clamp(0, _text.length);
    _text = _text.substring(0, idx) + text + _text.substring(idx);
    _invalidate();
  }

  void remove({required BigInt start, required BigInt end}) {
    final s = start.toInt().clamp(0, _text.length);
    final e = end.toInt().clamp(s, _text.length);
    _text = _text.substring(0, s) + _text.substring(e);
    _invalidate();
  }

  String slice({required BigInt start, required BigInt end}) {
    final s = start.toInt().clamp(0, _text.length);
    final e = end.toInt().clamp(s, _text.length);
    return _text.substring(s, e);
  }

  RopeBridge snapshot() => RopeBridge._(_text);

  Future<Uint8List> utf8Bytes() async => Uint8List.fromList(utf8.encode(_text));

  bool sameText({
    required RopeBridge original,
    required BigInt spliceStart,
    required BigInt spliceLen,
    required String spliceText,
  }) {
    final orig = original._text;
    final s = spliceStart.toInt().clamp(0, orig.length);
    final len = spliceLen.toInt().clamp(0, orig.length - s);
    final expected = orig.substring(0, s) + spliceText + orig.substring(s + len);
    return _text == expected;
  }
}

class RopeUpload {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool _isDisposed = false;

  RopeUpload({required BigInt capacity});

  bool get isDisposed => _isDisposed;

  void dispose() {
    _isDisposed = true;
    _builder.clear();
  }

  Future<void> push({required List<int> chunk}) async {
    _builder.add(chunk);
  }

  Future<RopeBridge> finish() async {
    final bytes = _builder.takeBytes();
    return RopeBridge.fromUtf8(bytes: bytes);
  }
}

int _leadingSpacesOf(String line, int tabSize) {
  var count = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 32) {
      count++;
    } else if (c == 9) {
      count += tabSize;
    } else {
      break;
    }
  }
  return count;
}

bool _isBlankLine(String line) => line.trim().isEmpty;

Future<List<RustFoldRange>> foldsComputeAll({
  required RopeBridge rope,
  required BigInt tabSize,
}) async {
  rope._ensureLines();
  final lines = rope._linesCache!;
  final ts = math.max(1, tabSize.toInt());
  final result = <RustFoldRange>[];
  final n = lines.length;

  for (var i = 0; i < n; i++) {
    if (_isBlankLine(lines[i])) continue;
    final baseIndent = _leadingSpacesOf(lines[i], ts);
    var lastChild = i;
    for (var j = i + 1; j < n; j++) {
      if (_isBlankLine(lines[j])) continue;
      final indent = _leadingSpacesOf(lines[j], ts);
      if (indent > baseIndent) {
        lastChild = j;
      } else {
        break;
      }
    }
    if (lastChild > i) {
      result.add(RustFoldRange(startLine: i, endLine: lastChild));
    }
  }
  return result;
}

BigInt? foldsFindMatchingBracket({
  required RopeBridge rope,
  required BigInt targetOffset,
}) {
  final text = rope.getText();
  final offset = targetOffset.toInt();
  if (offset < 0 || offset >= text.length) return null;

  const openers = '{([';
  const closers = '})]';
  final ch = text[offset];
  final openIdx = openers.indexOf(ch);
  if (openIdx != -1) {
    final targetClose = closers[openIdx];
    var depth = 1;
    for (var i = offset + 1; i < text.length; i++) {
      final c = text[i];
      if (c == ch) depth++;
      if (c == targetClose) {
        depth--;
        if (depth == 0) return BigInt.from(i);
      }
    }
    return null;
  }
  final closeIdx = closers.indexOf(ch);
  if (closeIdx != -1) {
    final targetOpen = openers[closeIdx];
    var depth = 1;
    for (var i = offset - 1; i >= 0; i--) {
      final c = text[i];
      if (c == ch) depth++;
      if (c == targetOpen) {
        depth--;
        if (depth == 0) return BigInt.from(i);
      }
    }
  }
  return null;
}

List<GuideBlock> guidesComputeViewport({
  required RopeBridge rope,
  required BigInt firstVisible,
  required BigInt lastVisible,
  required BigInt tabSize,
}) {
  rope._ensureLines();
  final lines = rope._linesCache!;
  final ts = math.max(1, tabSize.toInt());
  final first = firstVisible.toInt().clamp(0, lines.length);
  final last = lastVisible.toInt().clamp(first, lines.length - 1);
  final blocks = <GuideBlock>[];

  for (var i = first; i <= last && i < lines.length; i++) {
    if (_isBlankLine(lines[i])) continue;
    final spaces = _leadingSpacesOf(lines[i], ts);
    final level = spaces ~/ ts;
    for (var lvl = 1; lvl <= level; lvl++) {
      blocks.add(
        GuideBlock(
          startLine: i,
          endLine: i,
          indentLevel: lvl,
          leadingSpaces: lvl * ts,
        ),
      );
    }
  }
  return blocks;
}

Future<List<String>> wordsExtract({required RopeBridge rope}) async {
  final text = rope.getText();
  final matches = RegExp(r'[A-Za-z_][A-Za-z0-9_-]{2,}').allMatches(text);
  final unique = <String>{};
  for (final m in matches) {
    unique.add(m.group(0)!);
    if (unique.length >= 2000) break;
  }
  return unique.toList();
}

