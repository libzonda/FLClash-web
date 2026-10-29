import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'dart_io.dart';

export 'package:archive/archive.dart' hide InputFileStream, OutputFileStream;

class InputFileStream extends InputMemoryStream {
  final String path;

  InputFileStream(this.path) : super(File(path).readAsBytesSync());

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}
}

class OutputFileStream extends OutputMemoryStream {
  final String path;
  bool _closed = false;

  OutputFileStream(this.path) : super();

  void _flushToFile() {
    if (_closed) return;
    _closed = true;
    final bytes = getBytes();
    File(path).writeAsBytesSync(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    _flushToFile();
  }

  @override
  void closeSync() {
    _flushToFile();
  }
}

class ZipFileEncoder {
  static const int store = 0;
  static const int gzip = 1;

  late String zipPath;
  final Archive _archive = Archive();

  void create(String zipPath, {int? level, DateTime? modified}) {
    this.zipPath = zipPath;
  }

  void addArchiveFile(ArchiveFile file) {
    _archive.addFile(file);
  }

  Future<void> addFile(
    File file, [
    String? filename,
    int? level = gzip,
  ]) async {
    final bytes = await file.readAsBytes();
    final name = filename ?? p.posix.basename(file.path);
    final archiveFile = ArchiveFile(name, bytes.length, bytes);
    if (level == store) {
      archiveFile.compression = CompressionType.none;
    }
    _archive.addFile(archiveFile);
  }

  Future<void> addDirectory(
    Directory dir, {
    bool includeDirName = true,
    int? level,
    bool followLinks = true,
  }) async {
    if (!dir.existsSync()) return;
    final baseDir = includeDirName ? p.posix.dirname(dir.path) : dir.path;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        final rel = p.posix.relative(entity.path, from: baseDir);
        await addFile(entity, rel, level);
      }
    }
  }

  Future<void> close() async {
    final encoded = ZipEncoder().encode(_archive);
    if (encoded != null) {
      File(zipPath).writeAsBytesSync(Uint8List.fromList(encoded));
    }
  }

  void closeSync() {
    final encoded = ZipEncoder().encode(_archive);
    if (encoded != null) {
      File(zipPath).writeAsBytesSync(Uint8List.fromList(encoded));
    }
  }
}
