import 'dart:async';
import 'dart:typed_data';

class NativeType {
  const NativeType();
}

abstract base class Opaque extends NativeType {
  const Opaque();
}

final class Void extends NativeType {
  const Void();
}

final class Int8 extends NativeType {
  const Int8();
}

final class Uint8 extends NativeType {
  const Uint8();
}

final class Int16 extends NativeType {
  const Int16();
}

final class Uint16 extends NativeType {
  const Uint16();
}

final class Int32 extends NativeType {
  const Int32();
}

final class Uint32 extends NativeType {
  const Uint32();
}

final class Int64 extends NativeType {
  const Int64();
}

final class Uint64 extends NativeType {
  const Uint64();
}

final class IntPtr extends NativeType {
  const IntPtr();
}

final class Size extends NativeType {
  const Size();
}

final class Char extends NativeType {
  const Char();
}

final class UnsignedChar extends NativeType {
  const UnsignedChar();
}

final class WChar extends NativeType {
  const WChar();
}

final class NativeFunction<T extends Function> extends NativeType {
  const NativeFunction();
}

base class Struct extends NativeType {
  const Struct();
  static T create<T extends Struct>([TypedData? typedData, int offset = 0]) {
    throw UnsupportedError('Struct.create is not supported on Web');
  }
}

base class Union extends NativeType {
  const Union();
}

class Pointer<T extends NativeType> extends NativeType {
  final int address;
  dynamic _value;

  Pointer._(this.address, [this._value]);

  factory Pointer.fromAddress(int ptr) => Pointer._(ptr);

  Pointer<U> cast<U extends NativeType>() => Pointer<U>._(address, _value);

  Pointer<T> operator +(int offset) => Pointer<T>._(address + offset, _value);

  Pointer<T> elementAt(int index) => Pointer<T>._(address + index, _value);

  @override
  bool operator ==(Object other) =>
      other is Pointer && other.address == address;

  @override
  int get hashCode => address.hashCode;
}

final Pointer<Never> nullptr = Pointer<Never>._(0);

extension Int32Pointer on Pointer<Int32> {
  int get value => (_value as int?) ?? 0;
  set value(int v) => _value = v;
  int operator [](int index) => value;
  void operator []=(int index, int v) => value = v;
}

extension Uint32Pointer on Pointer<Uint32> {
  int get value => (_value as int?) ?? 0;
  set value(int v) => _value = v;
  int operator [](int index) => value;
  void operator []=(int index, int v) => value = v;
}

extension Int64Pointer on Pointer<Int64> {
  int get value => (_value as int?) ?? 0;
  set value(int v) => _value = v;
}

extension Uint64Pointer on Pointer<Uint64> {
  int get value => (_value as int?) ?? 0;
  set value(int v) => _value = v;
}

extension IntPtrPointer on Pointer<IntPtr> {
  int get value => (_value as int?) ?? 0;
  set value(int v) => _value = v;
}

extension Uint8Pointer on Pointer<Uint8> {
  int get value => (_value as int?) ?? 0;
  set value(int v) => _value = v;
  Uint8List asTypedList(int length) => Uint8List(length);
}

extension Uint16Pointer on Pointer<Uint16> {
  int get value => (_value as int?) ?? 0;
  set value(int v) => _value = v;
  Uint16List asTypedList(int length) => Uint16List(length);
}

extension PointerPointer<T extends NativeType> on Pointer<Pointer<T>> {
  Pointer<T> get value => (_value as Pointer<T>?) ?? Pointer<T>.fromAddress(0);
  set value(Pointer<T> v) => _value = v;
  Pointer<T> operator [](int index) => value;
  void operator []=(int index, Pointer<T> v) => value = v;
}

extension NativeFunctionPointer<NF extends Function>
    on Pointer<NativeFunction<NF>> {
  DF asFunction<DF extends Function>({bool isLeaf = false}) {
    throw UnsupportedError('FFI asFunction is not supported on Web');
  }
}

class DynamicLibrary {
  DynamicLibrary._();

  factory DynamicLibrary.open(String path) => DynamicLibrary._();
  factory DynamicLibrary.process() => DynamicLibrary._();
  factory DynamicLibrary.executable() => DynamicLibrary._();

  Pointer<T> lookup<T extends NativeType>(String symbolName) =>
      Pointer<T>.fromAddress(1);

  F lookupFunction<T extends Function, F extends Function>(
    String symbolName, {
    bool isLeaf = false,
  }) {
    if (symbolName == 'geteuid' || symbolName == 'getuid') {
      final dynamic fn = () => 0;
      return fn as F;
    }
    throw UnsupportedError('FFI lookupFunction($symbolName) called on Web');
  }

  void close() {}
}

int sizeOf<T extends NativeType>() => 8;

abstract interface class Allocator {
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment});
  void free(Pointer<NativeType> pointer);
}

final class Utf8 extends Opaque {
  const Utf8();
}

final class Utf16 extends Opaque {
  const Utf16();
}

extension Utf8Pointer on Pointer<Utf8> {
  int get length => (_value is String) ? (_value as String).length : 0;
  String toDartString({int? length}) => (_value as String?) ?? '';
}

extension StringUtf8Pointer on String {
  Pointer<Utf8> toNativeUtf8({Allocator allocator = calloc}) {
    return Pointer<Utf8>._(1, this);
  }
}

extension Utf16Pointer on Pointer<Utf16> {
  int get length => (_value is String) ? (_value as String).length : 0;
  String toDartString({int? length}) => (_value as String?) ?? '';
}

extension StringUtf16Pointer on String {
  Pointer<Utf16> toNativeUtf16({Allocator allocator = calloc}) {
    return Pointer<Utf16>._(1, this);
  }
}

class Arena implements Allocator {
  Arena([Allocator allocator = calloc]);

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    return Pointer<T>.fromAddress(1);
  }

  Pointer<T> call<T extends NativeType>([int count = 1]) {
    return Pointer<T>.fromAddress(1);
  }

  @override
  void free(Pointer<NativeType> pointer) {}

  void releaseAll({bool reuse = false}) {}
}

class _CallocAllocator implements Allocator {
  const _CallocAllocator();

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    return Pointer<T>.fromAddress(1);
  }

  Pointer<T> call<T extends NativeType>([int count = 1]) {
    return Pointer<T>.fromAddress(1);
  }

  @override
  void free(Pointer<NativeType> pointer) {}
}

const _CallocAllocator calloc = _CallocAllocator();
const _CallocAllocator malloc = _CallocAllocator();

R using<R>(R Function(Arena) computation, [Allocator wrappedAllocator = calloc]) {
  final arena = Arena(wrappedAllocator);
  try {
    return computation(arena);
  } finally {
    arena.releaseAll();
  }
}

final class GUID extends Struct {
  final String text;
  const GUID([this.text = '']);

  factory GUID.fromString(String guid) => GUID(guid);

  Pointer<GUID> toNative({Allocator allocator = calloc}) =>
      Pointer<GUID>.fromAddress(1);
}

enum RegistryHive {
  classesRoot,
  currentUser,
  localMachine,
  allUsers,
  performanceData,
  currentConfig,
}

enum RegistryValueType {
  none,
  string,
  unexpandedString,
  binary,
  int32,
  int64,
  link,
  stringArray,
}

class RegistryValue {
  final String name;
  final RegistryValueType type;
  final Object data;

  const RegistryValue(this.name, this.type, this.data);

  const RegistryValue.string(String value, {String name = ''})
    : this(name, RegistryValueType.string, value);

  const RegistryValue.int32(int value, {String name = ''})
    : this(name, RegistryValueType.int32, value);
}

class RegistryKey {
  final String path;
  const RegistryKey(this.path);

  RegistryKey create(String subKeyName) => RegistryKey('$path\\$subKeyName');
  RegistryKey open(String subKeyName, {bool writeAccess = false}) =>
      RegistryKey('$path\\$subKeyName');
  void setValue(String name, RegistryValue value) {}
  int? getInt(String name) => null;
  String? getString(String name) => null;
  void deleteValue(String name) {}
  void deleteKey(String subKeyName, {bool recursive = false}) {}
  void close() {}
}

const RegistryKey CURRENT_USER = RegistryKey('HKEY_CURRENT_USER');
const RegistryKey LOCAL_MACHINE = RegistryKey('HKEY_LOCAL_MACHINE');

class Registry {
  static RegistryKey openPath(
    RegistryHive hive, {
    String path = '',
    dynamic desiredAccessRights,
  }) => RegistryKey(path);
}


