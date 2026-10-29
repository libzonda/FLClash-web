import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/wasm.dart';

import 'dart_io.dart';
import 'vfs.dart';

WasmSqlite3? _cachedSqlite3;
final InMemoryFileSystem _sharedSqliteVfs = InMemoryFileSystem();
bool _vfsRegistered = false;

Future<WasmSqlite3> _getSqlite3() async {
  if (_cachedSqlite3 != null) return _cachedSqlite3!;
  final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  if (!_vfsRegistered) {
    sqlite3.registerVirtualFileSystem(_sharedSqliteVfs, makeDefault: true);
    _vfsRegistered = true;
  }
  _cachedSqlite3 = sqlite3;
  return sqlite3;
}

void _writeFileToSqliteVfs(String normPath, Uint8List bytes) {
  final opened = _sharedSqliteVfs.xOpen(
    Sqlite3Filename(normPath),
    SqlFlag.SQLITE_OPEN_READWRITE | SqlFlag.SQLITE_OPEN_CREATE,
  );
  try {
    opened.file.xTruncate(bytes.length);
    if (bytes.isNotEmpty) {
      opened.file.xWrite(bytes, 0);
    }
  } finally {
    opened.file.xClose();
  }
}

Uint8List? _readFileFromSqliteVfs(String normPath) {
  try {
    final opened = _sharedSqliteVfs.xOpen(
      Sqlite3Filename(normPath),
      SqlFlag.SQLITE_OPEN_READONLY,
    );
    try {
      final size = opened.file.xFileSize();
      final buf = Uint8List(size);
      if (size > 0) {
        opened.file.xRead(buf, 0);
      }
      return buf;
    } finally {
      opened.file.xClose();
    }
  } catch (_) {
    return null;
  }
}

void _flushSqliteFileToWebFs(String rawPath) {
  final normPath = WebFileSystem.instance.normalize(rawPath);
  final bytes = _readFileFromSqliteVfs(normPath);
  if (bytes != null && bytes.isNotEmpty) {
    WebFileSystem.instance.writeBytes(normPath, bytes);
  }
}

class _VfsSyncInterceptor extends QueryInterceptor {
  final String dbPath;

  _VfsSyncInterceptor(this.dbPath);

  void _syncDb() {
    _flushSqliteFileToWebFs(dbPath);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    await super.commitTransaction(inner);
    _syncDb();
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    await super.runBatched(executor, statements);
    _syncDb();
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final res = await super.runInsert(executor, statement, args);
    _syncDb();
    return res;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final res = await super.runUpdate(executor, statement, args);
    _syncDb();
    return res;
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final res = await super.runDelete(executor, statement, args);
    _syncDb();
    return res;
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final upper = statement.trim().toUpperCase();
    if (upper.startsWith('VACUUM INTO') && args.isNotEmpty) {
      final targetRaw = args.first?.toString() ?? '';
      final targetNorm = WebFileSystem.instance.normalize(targetRaw);
      await super.runCustom(executor, 'VACUUM INTO ?', [targetNorm]);
      _flushSqliteFileToWebFs(targetNorm);
      return;
    }
    await super.runCustom(executor, statement, args);
    _syncDb();
  }
}

class NativeDatabase {
  static QueryExecutor createInBackground(
    File file, {
    bool logStatements = false,
  }) {
    final normPath = WebFileSystem.instance.normalize(file.path);
    return LazyDatabase(() async {
      final sqlite3 = await _getSqlite3();
      if (WebFileSystem.instance.isFile(normPath)) {
        try {
          final existingBytes = WebFileSystem.instance.readBytes(normPath);
          if (existingBytes.isNotEmpty) {
            _writeFileToSqliteVfs(normPath, existingBytes);
          }
        } catch (_) {}
      }
      final wasmDb = WasmDatabase(
        sqlite3: sqlite3,
        path: normPath,
        logStatements: logStatements,
        setup: (db) {
          db.execute('PRAGMA journal_mode = MEMORY;');
        },
      );
      return wasmDb.interceptWith(_VfsSyncInterceptor(normPath));
    });
  }
}

class DriftNativeOptions {
  final Future<Directory> Function()? databaseDirectory;
  final Future<String> Function()? tempDirectoryPath;

  const DriftNativeOptions({
    this.databaseDirectory,
    this.tempDirectoryPath,
  });
}

QueryExecutor driftDatabase({
  required String name,
  DriftNativeOptions? native,
}) {
  return LazyDatabase(() async {
    String dirPath = '/data';
    if (native?.databaseDirectory != null) {
      final dir = await native!.databaseDirectory!();
      dirPath = dir.path;
    }
    final dbFile = File(p.posix.join(dirPath, '$name.sqlite'));
    return NativeDatabase.createInBackground(dbFile);
  });
}

