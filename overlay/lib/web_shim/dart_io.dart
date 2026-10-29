import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as pkg_archive;
import 'package:path/path.dart' as p;

import 'js_bridge.dart';
import 'vfs.dart';
import 'web_core_bridge.dart';

class Platform {
  static const bool isLinux = true;
  static const bool isWindows = false;
  static const bool isMacOS = false;
  static const bool isAndroid = false;
  static const bool isIOS = false;
  static const bool isFuchsia = false;

  static const String operatingSystem = 'linux';
  static const String operatingSystemVersion = 'Linux 6.6 (FlClash-web)';
  static const String resolvedExecutable = '/usr/local/bin/FlClash';
  static const String pathSeparator = '/';
  static const String localeName = 'en_US';
  static const int numberOfProcessors = 4;
  static const String version = '3.11.0 (stable) on "linux_x64"';

  static final Map<String, String> environment = const {
    'HOME': '/data',
    'USER': 'root',
    'PATH': '/usr/local/bin:/usr/bin:/bin',
  };

  static final List<String> executableArguments = const [];
  static Uri get script => Uri.parse('file:///usr/local/bin/FlClash');
  static String get localHostname => 'flclash-web';
}

const int pid = 42;

Never exit(int code) {
  throw UnsupportedError('exit($code) called on FlClash-web');
}

class ProcessInfo {
  static int get currentRss => 64 * 1024 * 1024;
  static int get maxRss => 128 * 1024 * 1024;
}

class OSError implements Exception {
  static const int noErrorCode = -1;
  final String message;
  final int errorCode;

  const OSError([this.message = '', this.errorCode = noErrorCode]);

  @override
  String toString() => 'OSError: $message (errno = $errorCode)';
}

abstract class IOException implements Exception {
  const IOException();
}

class HttpException implements IOException {
  final String message;
  final Uri? uri;

  const HttpException(this.message, {this.uri});

  @override
  String toString() =>
      uri != null ? 'HttpException: $message, uri = $uri' : 'HttpException: $message';
}

class FileSystemException implements IOException {
  final String message;
  final String? path;
  final OSError? osError;

  const FileSystemException([this.message = '', this.path = '', this.osError]);

  @override
  String toString() => 'FileSystemException: $message, path = $path';
}

class PathNotFoundException extends FileSystemException {
  const PathNotFoundException(
    String path,
    OSError osError, [
    String message = '',
  ]) : super(message, path, osError);
}

class PathExistsException extends FileSystemException {
  const PathExistsException(String path, OSError osError, [String message = ''])
    : super(message, path, osError);
}

class FileSystemEntityType {
  final int _type;
  const FileSystemEntityType._internal(this._type);

  static const file = FileSystemEntityType._internal(0);
  static const directory = FileSystemEntityType._internal(1);
  static const link = FileSystemEntityType._internal(2);
  static const unixDomainSock = FileSystemEntityType._internal(3);
  static const pipe = FileSystemEntityType._internal(4);
  static const notFound = FileSystemEntityType._internal(5);

  @override
  String toString() => const [
    'file',
    'directory',
    'link',
    'unixDomainSock',
    'pipe',
    'notFound',
  ][_type];
}

class FileStat {
  final DateTime changed;
  final DateTime modified;
  final DateTime accessed;
  final FileSystemEntityType type;
  final int mode;
  final int size;

  const FileStat._({
    required this.changed,
    required this.modified,
    required this.accessed,
    required this.type,
    required this.mode,
    required this.size,
  });

  static Future<FileStat> stat(String path) async => statSync(path);

  static FileStat statSync(String path) {
    final node = WebFileSystem.instance.stat(path);
    if (node == null) {
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      return FileStat._(
        changed: epoch,
        modified: epoch,
        accessed: epoch,
        type: FileSystemEntityType.notFound,
        mode: 0,
        size: -1,
      );
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(node.mtimeMs);
    return FileStat._(
      changed: dt,
      modified: dt,
      accessed: dt,
      type: node.isDir
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file,
      mode: node.isDir ? 0x41ed : 0x81a4,
      size: node.size,
    );
  }

  String modeString() => 'rwxr-xr-x';
}

class FileMode {
  final int _mode;
  const FileMode._internal(this._mode);
  static const read = FileMode._internal(0);
  static const write = FileMode._internal(1);
  static const append = FileMode._internal(2);
  static const writeOnly = FileMode._internal(3);
  static const writeOnlyAppend = FileMode._internal(4);

  bool get isAppend => _mode == 2 || _mode == 4;
}

class FileLock {
  final int _type;
  const FileLock._internal(this._type);
  static const shared = FileLock._internal(1);
  static const exclusive = FileLock._internal(2);
  static const blockingShared = FileLock._internal(3);
  static const blockingExclusive = FileLock._internal(4);

  @override
  String toString() => 'FileLock($_type)';
}

abstract class FileSystemEntity {
  String get path;

  Uri get uri => Uri.file(path);

  bool get isAbsolute => p.posix.isAbsolute(path);

  FileSystemEntity get absolute;

  Directory get parent =>
      Directory(p.posix.dirname(WebFileSystem.instance.normalize(path)));

  Future<bool> exists();
  bool existsSync();

  Future<FileSystemEntity> rename(String newPath);
  FileSystemEntity renameSync(String newPath);

  Future<String> resolveSymbolicLinks() async => resolveSymbolicLinksSync();
  String resolveSymbolicLinksSync() => WebFileSystem.instance.normalize(path);

  Future<FileStat> stat() async => statSync();
  FileStat statSync() => FileStat.statSync(path);

  Future<FileSystemEntity> delete({bool recursive = false}) async =>
      deleteSync(recursive: recursive);

  FileSystemEntity deleteSync({bool recursive = false}) {
    WebFileSystem.instance.delete(path, recursive: recursive);
    return this;
  }

  static Future<bool> isDirectory(String path) async => isDirectorySync(path);
  static bool isDirectorySync(String path) =>
      WebFileSystem.instance.isDirectory(path);

  static Future<bool> isFile(String path) async => isFileSync(path);
  static bool isFileSync(String path) => WebFileSystem.instance.isFile(path);

  static Future<bool> isLink(String path) async => false;
  static bool isLinkSync(String path) => false;

  static Future<FileSystemEntityType> type(
    String path, {
    bool followLinks = true,
  }) async => typeSync(path, followLinks: followLinks);

  static FileSystemEntityType typeSync(
    String path, {
    bool followLinks = true,
  }) => FileStat.statSync(path).type;
}

class File extends FileSystemEntity {
  @override
  final String path;

  File(this.path);

  factory File.fromUri(Uri uri) => File(uri.toFilePath());

  @override
  File get absolute => File(WebFileSystem.instance.normalize(path));

  @override
  Future<bool> exists() async => existsSync();

  @override
  bool existsSync() => WebFileSystem.instance.isFile(path);

  Future<File> create({bool recursive = false, bool exclusive = false}) async =>
      createSync(recursive: recursive, exclusive: exclusive);

  File createSync({bool recursive = false, bool exclusive = false}) {
    if (!existsSync()) {
      WebFileSystem.instance.writeBytes(path, Uint8List(0));
    }
    return this;
  }

  @override
  Future<File> rename(String newPath) async => renameSync(newPath);

  @override
  File renameSync(String newPath) {
    WebFileSystem.instance.rename(path, newPath);
    return File(newPath);
  }

  Future<File> copy(String newPath) async => copySync(newPath);

  File copySync(String newPath) {
    WebFileSystem.instance.copy(path, newPath);
    return File(newPath);
  }

  Future<int> length() async => lengthSync();

  int lengthSync() {
    final node = WebFileSystem.instance.stat(path);
    if (node == null || node.isDir) {
      throw PathNotFoundException(
        path,
        const OSError('No such file', 2),
        'Cannot get length',
      );
    }
    return node.size;
  }

  Future<DateTime> lastModified() async => lastModifiedSync();

  DateTime lastModifiedSync() {
    final node = WebFileSystem.instance.stat(path);
    if (node == null) {
      return DateTime.now();
    }
    return DateTime.fromMillisecondsSinceEpoch(node.mtimeMs);
  }

  Future<dynamic> setLastModified(DateTime time) async =>
      setLastModifiedSync(time);

  void setLastModifiedSync(DateTime time) {
    final node = WebFileSystem.instance.stat(path);
    if (node != null) {
      node.mtimeMs = time.millisecondsSinceEpoch;
    }
  }

  Future<Uint8List> readAsBytes() async => readAsBytesSync();

  Uint8List readAsBytesSync() {
    try {
      return WebFileSystem.instance.readBytes(path);
    } catch (e) {
      throw PathNotFoundException(path, OSError(e.toString(), 2));
    }
  }

  Future<String> readAsString({Encoding encoding = utf8}) async =>
      readAsStringSync(encoding: encoding);

  String readAsStringSync({Encoding encoding = utf8}) {
    final bytes = readAsBytesSync();
    return encoding.decode(bytes);
  }

  Future<List<String>> readAsLines({Encoding encoding = utf8}) async =>
      readAsLinesSync(encoding: encoding);

  List<String> readAsLinesSync({Encoding encoding = utf8}) {
    final content = readAsStringSync(encoding: encoding);
    return const LineSplitter().convert(content);
  }

  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    writeAsBytesSync(bytes, mode: mode, flush: flush);
    return this;
  }

  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    WebFileSystem.instance.writeBytes(path, bytes, append: mode.isAppend);
  }

  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    writeAsStringSync(contents, mode: mode, encoding: encoding, flush: flush);
    return this;
  }

  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    final bytes = encoding.encode(contents);
    writeAsBytesSync(bytes, mode: mode, flush: flush);
  }

  Stream<List<int>> openRead([int? start, int? end]) async* {
    final bytes = readAsBytesSync();
    final s = start ?? 0;
    final e = (end != null && end < bytes.length) ? end : bytes.length;
    if (s < e && s < bytes.length) {
      yield bytes.sublist(s, e);
    } else {
      yield Uint8List(0);
    }
  }

  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    return _WebFileIOSink(this, mode: mode, encoding: encoding);
  }

  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      openSync(mode: mode);

  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    return _WebRandomAccessFile(this, mode);
  }
}

class Directory extends FileSystemEntity {
  @override
  final String path;

  Directory(this.path);

  factory Directory.fromUri(Uri uri) => Directory(uri.toFilePath());

  static Directory _current = Directory('/data');
  static Directory get current => _current;
  static set current(dynamic val) {
    if (val is Directory) {
      _current = val;
    } else if (val is String) {
      _current = Directory(val);
    }
  }

  static Directory get systemTemp => Directory('/tmp');

  @override
  Directory get absolute => Directory(WebFileSystem.instance.normalize(path));

  @override
  Future<bool> exists() async => existsSync();

  @override
  bool existsSync() => WebFileSystem.instance.isDirectory(path);

  Future<Directory> create({bool recursive = false}) async =>
      createSync(recursive: recursive);

  Directory createSync({bool recursive = false}) {
    WebFileSystem.instance.mkdir(path, recursive: recursive);
    return this;
  }

  Future<Directory> createTemp([String? prefix]) async =>
      createTempSync(prefix);

  Directory createTempSync([String? prefix]) {
    final name =
        '${prefix ?? 'tmp_'}${DateTime.now().microsecondsSinceEpoch}';
    final dir = Directory(p.posix.join(path, name));
    dir.createSync(recursive: true);
    return dir;
  }

  @override
  Future<Directory> rename(String newPath) async => renameSync(newPath);

  @override
  Directory renameSync(String newPath) {
    WebFileSystem.instance.rename(path, newPath);
    return Directory(newPath);
  }

  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    for (final entity in listSync(
      recursive: recursive,
      followLinks: followLinks,
    )) {
      yield entity;
    }
  }

  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    final nodes = WebFileSystem.instance.list(path, recursive: recursive);
    return nodes
        .map<FileSystemEntity>(
          (n) => n.isDir ? Directory(n.path) : File(n.path),
        )
        .toList();
  }
}

class Link extends FileSystemEntity {
  @override
  final String path;

  Link(this.path);

  factory Link.fromUri(Uri uri) => Link(uri.toFilePath());

  @override
  Link get absolute => Link(WebFileSystem.instance.normalize(path));

  @override
  Future<bool> exists() async => false;

  @override
  bool existsSync() => false;

  @override
  Future<Link> rename(String newPath) async => Link(newPath);

  @override
  Link renameSync(String newPath) => Link(newPath);

  Future<Link> create(String target, {bool recursive = false}) async => this;
  void createSync(String target, {bool recursive = false}) {}
  Future<Link> update(String target) async => this;
  void updateSync(String target) {}
  Future<String> target() async => path;
  String targetSync() => path;
}

abstract class RandomAccessFile {
  String get path;
  Future<void> close();
  void closeSync();
  Future<int> readByte();
  int readByteSync();
  Future<Uint8List> read(int count);
  Uint8List readSync(int count);
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]);
  int readIntoSync(List<int> buffer, [int start = 0, int? end]);
  Future<RandomAccessFile> writeByte(int value);
  int writeByteSync(int value);
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]);
  void writeFromSync(List<int> buffer, [int start = 0, int? end]);
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  });
  void writeStringSync(String string, {Encoding encoding = utf8});
  Future<int> position();
  int positionSync();
  Future<RandomAccessFile> setPosition(int position);
  void setPositionSync(int position);
  Future<RandomAccessFile> truncate(int length);
  void truncateSync(int length);
  Future<int> length();
  int lengthSync();
  Future<RandomAccessFile> flush();
  void flushSync();
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]);
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]);
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]);
  void unlockSync([int start = 0, int end = -1]);
}

class _WebRandomAccessFile implements RandomAccessFile {
  final File _file;
  final FileMode _mode;
  late List<int> _buffer;
  int _pos = 0;
  bool _dirty = false;

  _WebRandomAccessFile(this._file, this._mode) {
    if (_file.existsSync() &&
        (_mode == FileMode.read || _mode.isAppend || _mode == FileMode.write)) {
      if (_mode == FileMode.write || _mode == FileMode.writeOnly) {
        _buffer = <int>[];
        _dirty = true;
      } else {
        _buffer = _file.readAsBytesSync().toList();
      }
      if (_mode.isAppend) {
        _pos = _buffer.length;
      }
    } else {
      _buffer = <int>[];
      if (_mode != FileMode.read) {
        _dirty = true;
      }
    }
  }

  @override
  String get path => _file.path;

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() => flushSync();

  @override
  Future<RandomAccessFile> flush() async {
    flushSync();
    return this;
  }

  @override
  void flushSync() {
    if (_dirty) {
      _file.writeAsBytesSync(Uint8List.fromList(_buffer));
      _dirty = false;
    }
  }

  @override
  Future<int> length() async => lengthSync();

  @override
  int lengthSync() => _buffer.length;

  @override
  Future<int> position() async => _pos;

  @override
  int positionSync() => _pos;

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    setPositionSync(position);
    return this;
  }

  @override
  void setPositionSync(int position) {
    _pos = position;
  }

  @override
  Future<int> readByte() async => readByteSync();

  @override
  int readByteSync() {
    if (_pos >= _buffer.length) return -1;
    return _buffer[_pos++];
  }

  @override
  Future<Uint8List> read(int count) async => readSync(count);

  @override
  Uint8List readSync(int count) {
    if (_pos >= _buffer.length || count <= 0) return Uint8List(0);
    final end = (_pos + count < _buffer.length) ? _pos + count : _buffer.length;
    final slice = Uint8List.fromList(_buffer.sublist(_pos, end));
    _pos = end;
    return slice;
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async =>
      readIntoSync(buffer, start, end);

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    final targetEnd = end ?? buffer.length;
    final count = targetEnd - start;
    final readBytes = readSync(count);
    for (var i = 0; i < readBytes.length; i++) {
      buffer[start + i] = readBytes[i];
    }
    return readBytes.length;
  }

  @override
  Future<RandomAccessFile> writeByte(int value) async {
    writeByteSync(value);
    return this;
  }

  @override
  int writeByteSync(int value) {
    writeFromSync([value & 0xff]);
    return 1;
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    writeFromSync(buffer, start, end);
    return this;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    final targetEnd = end ?? buffer.length;
    final slice = buffer.sublist(start, targetEnd);
    while (_buffer.length < _pos) {
      _buffer.add(0);
    }
    for (var i = 0; i < slice.length; i++) {
      if (_pos + i < _buffer.length) {
        _buffer[_pos + i] = slice[i];
      } else {
        _buffer.add(slice[i]);
      }
    }
    _pos += slice.length;
    _dirty = true;
  }

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) async {
    writeStringSync(string, encoding: encoding);
    return this;
  }

  @override
  void writeStringSync(String string, {Encoding encoding = utf8}) {
    writeFromSync(encoding.encode(string));
  }

  @override
  Future<RandomAccessFile> truncate(int length) async {
    truncateSync(length);
    return this;
  }

  @override
  void truncateSync(int length) {
    if (length < _buffer.length) {
      _buffer.removeRange(length, _buffer.length);
    } else {
      while (_buffer.length < length) {
        _buffer.add(0);
      }
    }
    _dirty = true;
  }

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async => this;

  @override
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) {}

  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async => this;

  @override
  void unlockSync([int start = 0, int end = -1]) {}
}

abstract interface class IOSink implements StreamSink<List<int>>, StringSink {
  late Encoding encoding;

  factory IOSink({Encoding encoding}) = _MemoryIOSink;

  @override
  void add(List<int> data);
  @override
  void write(Object? object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']);
  @override
  void writeln([Object? object = '']);
  @override
  void writeCharCode(int charCode);
  @override
  void addError(Object error, [StackTrace? stackTrace]);
  @override
  Future<dynamic> addStream(Stream<List<int>> stream);
  Future<dynamic> flush();
  @override
  Future<dynamic> close();
  @override
  Future<dynamic> get done;
}

class _MemoryIOSink implements IOSink {
  @override
  Encoding encoding;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  final Completer<void> _doneCompleter = Completer<void>();

  _MemoryIOSink({this.encoding = utf8});

  @override
  void add(List<int> data) {
    _builder.add(data);
  }

  @override
  void write(Object? object) {
    final s = object?.toString() ?? 'null';
    if (s.isNotEmpty) {
      add(encoding.encode(s));
    }
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    var first = true;
    for (final obj in objects) {
      if (!first && separator.isNotEmpty) {
        write(separator);
      }
      first = false;
      write(obj);
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<dynamic> flush() async {}

  @override
  Future<dynamic> close() async {
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  @override
  Future<dynamic> get done => _doneCompleter.future;
}

class _WebFileIOSink extends _MemoryIOSink {
  final File _file;
  final FileMode _mode;

  _WebFileIOSink(this._file, {required FileMode mode, super.encoding})
    : _mode = mode;

  @override
  Future<dynamic> flush() async {
    final bytes = _builder.takeBytes();
    if (bytes.isNotEmpty) {
      _file.writeAsBytesSync(bytes, mode: _mode);
    }
  }

  @override
  Future<dynamic> close() async {
    await flush();
    return super.close();
  }
}

class ProcessStartMode {
  final int _mode;
  const ProcessStartMode._internal(this._mode);
  static const normal = ProcessStartMode._internal(0);
  static const inheritStdio = ProcessStartMode._internal(1);
  static const detached = ProcessStartMode._internal(2);
  static const detachedWithStdio = ProcessStartMode._internal(3);

  @override
  String toString() => 'ProcessStartMode($_mode)';
}

class ProcessSignal {
  final int signalNumber;
  final String name;
  const ProcessSignal._(this.signalNumber, this.name);

  static const sighup = ProcessSignal._(1, 'SIGHUP');
  static const sigint = ProcessSignal._(2, 'SIGINT');
  static const sigquit = ProcessSignal._(3, 'SIGQUIT');
  static const sigill = ProcessSignal._(4, 'SIGILL');
  static const sigtrap = ProcessSignal._(5, 'SIGTRAP');
  static const sigabrt = ProcessSignal._(6, 'SIGABRT');
  static const sigbus = ProcessSignal._(7, 'SIGBUS');
  static const sigfpe = ProcessSignal._(8, 'SIGFPE');
  static const sigkill = ProcessSignal._(9, 'SIGKILL');
  static const sigusr1 = ProcessSignal._(10, 'SIGUSR1');
  static const sigsegv = ProcessSignal._(11, 'SIGSEGV');
  static const sigusr2 = ProcessSignal._(12, 'SIGUSR2');
  static const sigpipe = ProcessSignal._(13, 'SIGPIPE');
  static const sigalrm = ProcessSignal._(14, 'SIGALRM');
  static const sigterm = ProcessSignal._(15, 'SIGTERM');
  static const sigchld = ProcessSignal._(17, 'SIGCHLD');
  static const sigcont = ProcessSignal._(18, 'SIGCONT');
  static const sigstop = ProcessSignal._(19, 'SIGSTOP');
  static const sigtstp = ProcessSignal._(20, 'SIGTSTP');
  static const sigttin = ProcessSignal._(21, 'SIGTTIN');
  static const sigttou = ProcessSignal._(22, 'SIGTTOU');
  static const sigurg = ProcessSignal._(23, 'SIGURG');
  static const sigxcpu = ProcessSignal._(24, 'SIGXCPU');
  static const sigxfsz = ProcessSignal._(25, 'SIGXFSZ');
  static const sigvtalrm = ProcessSignal._(26, 'SIGVTALRM');
  static const sigprof = ProcessSignal._(27, 'SIGPROF');
  static const sigwinch = ProcessSignal._(28, 'SIGWINCH');
  static const sigpoll = ProcessSignal._(29, 'SIGPOLL');
  static const sigsys = ProcessSignal._(31, 'SIGSYS');

  Stream<ProcessSignal> watch() => const Stream<ProcessSignal>.empty();
}

class ProcessException implements IOException {
  final String executable;
  final List<String> arguments;
  final String message;
  final int errorCode;

  const ProcessException(
    this.executable,
    this.arguments, [
    this.message = '',
    this.errorCode = 0,
  ]);

  @override
  String toString() =>
      'ProcessException: $message (cmd: $executable, code: $errorCode)';
}

class ProcessResult {
  final int pid;
  final int exitCode;
  final dynamic stdout;
  final dynamic stderr;

  ProcessResult(this.pid, this.exitCode, this.stdout, this.stderr);
}

class Process {
  static int _nextPid = 1000;

  final int pid;
  final String _address;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _stderrController =
      StreamController<List<int>>.broadcast();
  final IOSink stdin = IOSink();

  Process._(this.pid, this._address);

  Stream<List<int>> get stdout => _stdoutController.stream;
  Stream<List<int>> get stderr => _stderrController.stream;
  Future<int> get exitCode => _exitCodeCompleter.future;

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    WebCoreBridge.instance.notifyProcessKilled(_address);
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(0);
    }
    _stdoutController.close();
    _stderrController.close();
    return true;
  }

  static Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final childPid = ++_nextPid;
    final address = arguments.isNotEmpty ? arguments.first : '';
    final proc = Process._(childPid, address);
    scheduleMicrotask(() {
      WebCoreBridge.instance.notifyProcessStarted(address, childPid);
    });
    return proc;
  }

  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async {
    return runSync(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

  static ProcessResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    final cmd = p.posix.basename(executable);
    if (cmd == 'stat') {
      return ProcessResult(1, 0, 'root:root -rwsr-x---', '');
    }
    if (cmd == 'fc-list') {
      return ProcessResult(
        1,
        0,
        'Roboto\nNoto Sans CJK SC\nDejaVu Sans\nJetBrains Mono\nInter\n',
        '',
      );
    }
    if (cmd == 'id') {
      return ProcessResult(1, 0, '0\n', '');
    }
    if (cmd == 'xdg-open' && arguments.isNotEmpty) {
      JsBridge.openUrl(arguments.first);
      return ProcessResult(1, 0, '', '');
    }
    return ProcessResult(1, 0, '', '');
  }

  static bool killPid(
    int pid, [
    ProcessSignal signal = ProcessSignal.sigterm,
  ]) => true;
}

class InternetAddressType {
  final int _type;
  const InternetAddressType._(this._type);

  static const IPv4 = InternetAddressType._(0);
  static const IPv6 = InternetAddressType._(1);
  static const unix = InternetAddressType._(2);
  static const any = InternetAddressType._(-1);

  String get name => switch (_type) {
    0 => 'IPv4',
    1 => 'IPv6',
    2 => 'Unix',
    _ => 'ANY',
  };
}

class InternetAddress {
  final String address;
  final String? _host;
  final InternetAddressType type;

  InternetAddress(this.address, {InternetAddressType? type})
    : _host = address,
      type =
          type ??
          (address.contains(':')
              ? InternetAddressType.IPv6
              : InternetAddressType.IPv4);

  factory InternetAddress.fromRawAddress(
    Uint8List rawAddress, {
    InternetAddressType? type,
  }) {
    if (rawAddress.length == 4) {
      return InternetAddress(
        '${rawAddress[0]}.${rawAddress[1]}.${rawAddress[2]}.${rawAddress[3]}',
        type: InternetAddressType.IPv4,
      );
    }
    if (rawAddress.length == 16) {
      final groups = <String>[];
      for (var i = 0; i < 16; i += 2) {
        final v = (rawAddress[i] << 8) | rawAddress[i + 1];
        groups.add(v.toRadixString(16));
      }
      return InternetAddress(
        groups.join(':'),
        type: InternetAddressType.IPv6,
      );
    }
    return InternetAddress('127.0.0.1');
  }

  static final InternetAddress loopbackIPv4 = InternetAddress('127.0.0.1');
  static final InternetAddress loopbackIPv6 = InternetAddress('::1');
  static final InternetAddress anyIPv4 = InternetAddress('0.0.0.0');
  static final InternetAddress anyIPv6 = InternetAddress('::');

  String get host => _host ?? address;

  Uint8List get rawAddress {
    if (type == InternetAddressType.IPv4) {
      final parts = address.split('.');
      if (parts.length == 4) {
        return Uint8List.fromList(
          parts.map((e) => int.tryParse(e) ?? 0).toList(),
        );
      }
      return Uint8List(4);
    }
    return Uint8List(16);
  }

  bool get isLoopback =>
      address == '127.0.0.1' || address == '::1' || address == 'localhost';
  bool get isLinkLocal =>
      address.startsWith('169.254.') ||
      address.toLowerCase().startsWith('fe80:');
  bool get isMulticast => false;

  static InternetAddress? tryParse(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains(':')) {
      return InternetAddress(trimmed, type: InternetAddressType.IPv6);
    }
    final parts = trimmed.split('.');
    if (parts.length == 4 &&
        parts.every((part) {
          final v = int.tryParse(part);
          return v != null && v >= 0 && v <= 255;
        })) {
      return InternetAddress(trimmed, type: InternetAddressType.IPv4);
    }
    return null;
  }

  static Future<List<InternetAddress>> lookup(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) async {
    return [InternetAddress.tryParse(host) ?? InternetAddress('127.0.0.1')];
  }

  Future<InternetAddress> reverse() async => this;
}

class NetworkInterface {
  final String name;
  final int index;
  final List<InternetAddress> addresses;

  NetworkInterface(this.name, this.index, this.addresses);

  static bool get listSupported => true;

  static Future<List<NetworkInterface>> list({
    bool includeLoopback = false,
    bool includeLinkLocal = false,
    InternetAddressType type = InternetAddressType.any,
  }) async {
    WebFileSystem.instance.refreshNetworkInterfaces();
    final serverIfaces = WebFileSystem.instance.networkInterfaces;
    final result = <NetworkInterface>[];
    var idx = 1;
    for (final iface in serverIfaces) {
      final addrs = <InternetAddress>[];
      for (final raw in iface.addresses) {
        final parsed = InternetAddress.tryParse(raw);
        if (parsed == null) continue;
        if (type != InternetAddressType.any && parsed.type != type) continue;
        addrs.add(parsed);
      }
      if (addrs.isNotEmpty) {
        result.add(NetworkInterface(iface.name, idx++, addrs));
      }
    }
    return result;
  }
}

class SocketException implements IOException {
  final String message;
  final OSError? osError;
  final InternetAddress? address;
  final int? port;

  const SocketException(
    this.message, {
    this.osError,
    this.address,
    this.port,
  });

  const SocketException.closed()
    : message = 'Socket has been closed',
      osError = null,
      address = null,
      port = null;

  @override
  String toString() => 'SocketException: $message';
}

class HandshakeException extends TlsException {
  const HandshakeException([super.message = '', super.osError]);
}

class TlsException implements IOException {
  final String message;
  final OSError? osError;
  const TlsException([this.message = '', this.osError]);
}

class CertificateException extends TlsException {
  const CertificateException([super.message = '', super.osError]);
}

class SocketDirection {
  final int _value;
  const SocketDirection._(this._value);
  static const receive = SocketDirection._(0);
  static const send = SocketDirection._(1);
  static const both = SocketDirection._(2);

  @override
  String toString() => 'SocketDirection($_value)';
}

class SocketOption {
  final int _value;
  const SocketOption._(this._value);
  static const tcpNoDelay = SocketOption._(0);

  @override
  String toString() => 'SocketOption($_value)';
}

class RawSocketOption {
  final int level;
  final int option;
  final Uint8List value;
  const RawSocketOption(this.level, this.option, this.value);
}

class RawSocketEvent {
  final int _value;
  const RawSocketEvent._(this._value);
  static const read = RawSocketEvent._(0);
  static const write = RawSocketEvent._(1);
  static const readClosed = RawSocketEvent._(2);
  static const closed = RawSocketEvent._(3);

  @override
  String toString() => 'RawSocketEvent($_value)';
}

class ConnectionTask<S> {
  final Future<S> socket;
  final void Function() _onCancel;

  ConnectionTask._({required this.socket, required void Function() onCancel})
    : _onCancel = onCancel;

  void cancel() => _onCancel();
}

class Socket extends Stream<Uint8List> implements IOSink {
  @override
  Encoding encoding = utf8;

  InternetAddress get address => InternetAddress.loopbackIPv4;
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;
  int get port => 0;
  int get remotePort => 0;

  static Future<Socket> connect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) async {
    return Socket();
  }

  static Future<ConnectionTask<Socket>> startConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) async {
    return ConnectionTask<Socket>._(
      socket: Future.value(Socket()),
      onCancel: () {},
    );
  }

  void destroy() {}
  bool setOption(SocketOption option, bool enabled) => true;
  Uint8List getRawOption(RawSocketOption option) => Uint8List(0);
  void setRawOption(RawSocketOption option) {}

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return const Stream<Uint8List>.empty().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}
  @override
  Future<dynamic> close() async {}
  @override
  Future<dynamic> get done => Future.value();
  @override
  Future<dynamic> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

class RawSocket extends Stream<RawSocketEvent> {
  static Future<RawSocket> connect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) async {
    return RawSocket();
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return const Stream<RawSocketEvent>.empty().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class ServerSocket extends Stream<Socket> {
  final int port;
  final InternetAddress address;

  ServerSocket._(this.address, this.port);

  static Future<ServerSocket> bind(
    dynamic address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
  }) async {
    final addr = address is InternetAddress
        ? address
        : InternetAddress(address.toString());
    return ServerSocket._(addr, port == 0 ? 19090 : port);
  }

  Future<ServerSocket> close() async => this;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return const Stream<Socket>.empty().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class RawServerSocket extends Stream<RawSocket> {
  final int port;
  final InternetAddress address;

  RawServerSocket._(this.address, this.port);

  static Future<RawServerSocket> bind(
    dynamic address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
  }) async {
    final addr = address is InternetAddress
        ? address
        : InternetAddress(address.toString());
    return RawServerSocket._(addr, port == 0 ? 19090 : port);
  }

  Future<RawServerSocket> close() async => this;

  @override
  StreamSubscription<RawSocket> listen(
    void Function(RawSocket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return const Stream<RawSocket>.empty().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class X509Certificate {
  final Uint8List der = Uint8List(0);
  final String pem = '';
  final String subject = '';
  final String issuer = '';
  final DateTime startValidity = DateTime.now();
  final DateTime endValidity = DateTime.now();
}

class SecurityContext {
  static final SecurityContext defaultContext = SecurityContext();
  void setTrustedCertificates(String file, {String? password}) {}
  void setTrustedCertificatesBytes(List<int> certBytes, {String? password}) {}
}

abstract class HttpHeaders {
  static const acceptHeader = 'accept';
  static const acceptCharsetHeader = 'accept-charset';
  static const acceptEncodingHeader = 'accept-encoding';
  static const acceptLanguageHeader = 'accept-language';
  static const acceptRangesHeader = 'accept-ranges';
  static const ageHeader = 'age';
  static const allowHeader = 'allow';
  static const authorizationHeader = 'authorization';
  static const cacheControlHeader = 'cache-control';
  static const connectionHeader = 'connection';
  static const contentEncodingHeader = 'content-encoding';
  static const contentLanguageHeader = 'content-language';
  static const contentLengthHeader = 'content-length';
  static const contentLocationHeader = 'content-location';
  static const contentMD5Header = 'content-md5';
  static const contentRangeHeader = 'content-range';
  static const contentTypeHeader = 'content-type';
  static const dateHeader = 'date';
  static const etagHeader = 'etag';
  static const expectHeader = 'expect';
  static const expiresHeader = 'expires';
  static const fromHeader = 'from';
  static const hostHeader = 'host';
  static const ifMatchHeader = 'if-match';
  static const ifModifiedSinceHeader = 'if-modified-since';
  static const ifNoneMatchHeader = 'if-none-match';
  static const ifRangeHeader = 'if-range';
  static const ifUnmodifiedSinceHeader = 'if-unmodified-since';
  static const lastModifiedHeader = 'last-modified';
  static const locationHeader = 'location';
  static const maxForwardsHeader = 'max-forwards';
  static const pragmaHeader = 'pragma';
  static const proxyAuthenticateHeader = 'proxy-authenticate';
  static const proxyAuthorizationHeader = 'proxy-authorization';
  static const rangeHeader = 'range';
  static const refererHeader = 'referer';
  static const retryAfterHeader = 'retry-after';
  static const serverHeader = 'server';
  static const teHeader = 'te';
  static const trailerHeader = 'trailer';
  static const transferEncodingHeader = 'transfer-encoding';
  static const upgradeHeader = 'upgrade';
  static const userAgentHeader = 'user-agent';
  static const varyHeader = 'vary';
  static const viaHeader = 'via';
  static const warningHeader = 'warning';
  static const wwwAuthenticateHeader = 'www-authenticate';

  ContentType? contentType;
  int contentLength = -1;
  bool chunkedTransferEncoding = false;
  bool persistentConnection = true;

  List<String>? operator [](String name);
  String? value(String name);
  void add(String name, Object value, {bool preserveHeaderCase = false});
  void set(String name, Object value, {bool preserveHeaderCase = false});
  void remove(String name, Object value);
  void removeAll(String name);
  void forEach(void Function(String name, List<String> values) action);
  void clear();
}

class HeaderValue {
  final String value;
  final Map<String, String?> parameters;

  HeaderValue([this.value = '', Map<String, String?> parameters = const {}])
    : parameters = Map<String, String?>.unmodifiable(parameters);

  static HeaderValue parse(
    String value, {
    String parameterSeparator = ';',
    String? valueSeparator,
    bool preserveBackslash = false,
  }) {
    final parts = value.split(parameterSeparator);
    final mainVal = parts.isNotEmpty ? parts.first.trim() : '';
    final params = <String, String?>{};
    for (var i = 1; i < parts.length; i++) {
      final seg = parts[i].trim();
      if (seg.isEmpty) continue;
      final eq = seg.indexOf('=');
      if (eq == -1) {
        params[seg.toLowerCase()] = null;
      } else {
        final k = seg.substring(0, eq).trim().toLowerCase();
        var v = seg.substring(eq + 1).trim();
        if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
          v = v.substring(1, v.length - 1);
        }
        params[k] = v;
      }
    }
    return HeaderValue(mainVal, params);
  }

  @override
  String toString() => value;
}

class ContentType extends HeaderValue {
  final String primaryType;
  final String subType;
  final String? charset;

  ContentType(
    this.primaryType,
    this.subType, {
    this.charset,
    Map<String, String?> parameters = const {},
  }) : super('$primaryType/$subType', {
         ...parameters,
         if (charset != null) 'charset': charset,
       });

  static final ContentType text = ContentType(
    'text',
    'plain',
    charset: 'utf-8',
  );
  static final ContentType html = ContentType('text', 'html', charset: 'utf-8');
  static final ContentType json = ContentType(
    'application',
    'json',
    charset: 'utf-8',
  );
  static final ContentType binary = ContentType('application', 'octet-stream');

  String get mimeType => '$primaryType/$subType';

  static ContentType parse(String value) {
    final hv = HeaderValue.parse(value);
    final slash = hv.value.indexOf('/');
    final primary = slash == -1
        ? hv.value
        : hv.value.substring(0, slash).trim();
    final sub = slash == -1 ? '' : hv.value.substring(slash + 1).trim();
    return ContentType(
      primary,
      sub,
      charset: hv.parameters['charset'],
      parameters: hv.parameters,
    );
  }
}

class _SimpleHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  ContentType? contentType;
  @override
  int contentLength = -1;
  @override
  bool chunkedTransferEncoding = false;
  @override
  bool persistentConnection = true;

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) {
    final v = _map[name.toLowerCase()];
    if (v == null || v.isEmpty) return null;
    return v.join(', ');
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = [value.toString()];
  }

  @override
  void remove(String name, Object value) {
    _map[name.toLowerCase()]?.remove(value.toString());
  }

  @override
  void removeAll(String name) {
    _map.remove(name.toLowerCase());
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  void clear() => _map.clear();
}

abstract class HttpStatus {
  static const int ok = 200;
  static const int created = 201;
  static const int accepted = 202;
  static const int noContent = 204;
  static const int partialContent = 206;
  static const int multiStatus = 207;
  static const int movedPermanently = 301;
  static const int found = 302;
  static const int notModified = 304;
  static const int badRequest = 400;
  static const int unauthorized = 401;
  static const int forbidden = 403;
  static const int notFound = 404;
  static const int methodNotAllowed = 405;
  static const int conflict = 409;
  static const int tooManyRequests = 429;
  static const int internalServerError = 500;
  static const int badGateway = 502;
  static const int serviceUnavailable = 503;
  static const int gatewayTimeout = 504;
}

class HttpClient {
  Duration? connectionTimeout;
  Duration idleTimeout = const Duration(seconds: 15);
  int? maxConnectionsPerHost;
  bool autoUncompress = true;
  String? userAgent;

  String Function(Uri url)? findProxy;
  bool Function(X509Certificate cert, String host, int port)?
  badCertificateCallback;
  Future<ConnectionTask<Socket>> Function(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  )?
  connectionFactory;

  HttpClient([SecurityContext? context]);

  static String findProxyFromEnvironment(
    Uri url, {
    Map<String, String>? environment,
  }) => 'DIRECT';

  void close({bool force = false}) {}
}

class HttpResponse extends _MemoryIOSink {
  int statusCode = HttpStatus.ok;
  String reasonPhrase = 'OK';
  final HttpHeaders headers = _SimpleHttpHeaders();
}

abstract class HttpRequest extends Stream<Uint8List> {
  String get method => 'GET';
  Uri get uri => Uri.parse('/');
  Uri get requestedUri => Uri.parse('http://127.0.0.1/');
  HttpHeaders get headers => _SimpleHttpHeaders();
  HttpResponse get response => HttpResponse();
}

class HttpServer extends Stream<HttpRequest> {
  final InternetAddress address;
  final int port;

  HttpServer._(this.address, this.port);

  static Future<HttpServer> bind(
    dynamic address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
  }) async {
    final addr = address is InternetAddress
        ? address
        : InternetAddress(address.toString());
    return HttpServer._(addr, port == 0 ? 19090 : port);
  }

  Future<void> close({bool force = false}) async {}

  @override
  StreamSubscription<HttpRequest> listen(
    void Function(HttpRequest event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return const Stream<HttpRequest>.empty().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

abstract class HttpOverrides {
  static HttpOverrides? _global;
  static HttpOverrides? get current => _global;
  static set global(HttpOverrides? overrides) {
    _global = overrides;
  }

  HttpClient createHttpClient(SecurityContext? context) => HttpClient(context);

  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      'DIRECT';
}

const Encoding systemEncoding = utf8;

class ZLibCodec extends Codec<List<int>, List<int>> {
  const ZLibCodec();

  @override
  Converter<List<int>, List<int>> get encoder => const _ZLibEncoder();

  @override
  Converter<List<int>, List<int>> get decoder => const _ZLibDecoder();

  List<int> encode(List<int> bytes) => encoder.convert(bytes);
  List<int> decode(List<int> bytes) => decoder.convert(bytes);
}

class _ZLibEncoder extends Converter<List<int>, List<int>> {
  const _ZLibEncoder();
  @override
  List<int> convert(List<int> input) =>
      const pkg_archive.ZLibEncoder().encode(input);
}

class _ZLibDecoder extends Converter<List<int>, List<int>> {
  const _ZLibDecoder();
  @override
  List<int> convert(List<int> input) =>
      const pkg_archive.ZLibDecoder().decodeBytes(input);
}

class GZipCodec extends Codec<List<int>, List<int>> {
  const GZipCodec();

  @override
  Converter<List<int>, List<int>> get encoder => const _GZipEncoder();

  @override
  Converter<List<int>, List<int>> get decoder => const _GZipDecoder();

  List<int> encode(List<int> bytes) => encoder.convert(bytes);
  List<int> decode(List<int> bytes) => decoder.convert(bytes);
}

class _GZipEncoder extends Converter<List<int>, List<int>> {
  const _GZipEncoder();
  @override
  List<int> convert(List<int> input) =>
      const pkg_archive.GZipEncoder().encode(input) ?? <int>[];
}

class _GZipDecoder extends Converter<List<int>, List<int>> {
  const _GZipDecoder();
  @override
  List<int> convert(List<int> input) =>
      const pkg_archive.GZipDecoder().decodeBytes(input);
}

const GZipCodec gzip = GZipCodec();
const ZLibCodec zlib = ZLibCodec();

class Isolate {
  static Future<R> run<R>(
    FutureOr<R> Function() computation, {
    String? debugName,
  }) async {
    return await computation();
  }
}

