import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' as pkg_dio;

import 'dio_io.dart';
import 'vfs.dart';

export 'package:dio/dio.dart' hide Dio;

class Dio with pkg_dio.DioMixin implements pkg_dio.Dio {
  Dio([pkg_dio.BaseOptions? options]) {
    this.options = options ?? pkg_dio.BaseOptions();
    httpClientAdapter = IOHttpClientAdapter();
  }

  @override
  pkg_dio.Dio clone({
    pkg_dio.BaseOptions? options,
    pkg_dio.Interceptors? interceptors,
    pkg_dio.HttpClientAdapter? httpClientAdapter,
    pkg_dio.Transformer? transformer,
  }) {
    final dio = Dio(options ?? this.options);
    if (interceptors != null) {
      dio.interceptors.addAll(interceptors);
    } else {
      dio.interceptors.addAll(this.interceptors);
    }
    dio.httpClientAdapter = httpClientAdapter ?? this.httpClientAdapter;
    dio.transformer = transformer ?? this.transformer;
    return dio;
  }

  @override
  Future<pkg_dio.Response<dynamic>> download(
    String urlPath,
    dynamic savePath, {
    pkg_dio.ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    pkg_dio.CancelToken? cancelToken,
    bool deleteOnError = true,
    String lengthHeader = pkg_dio.Headers.contentLengthHeader,
    Object? data,
    pkg_dio.Options? options,
    pkg_dio.FileAccessMode fileAccessMode = pkg_dio.FileAccessMode.write,
  }) async {
    final effectiveOptions =
        (options ?? pkg_dio.Options()).copyWith(
          method: options?.method ?? 'GET',
          responseType: pkg_dio.ResponseType.bytes,
        );
    final reqOptions = effectiveOptions.compose(
      this.options,
      urlPath,
      data: data,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
    );

    final adapter = httpClientAdapter is IOHttpClientAdapter
        ? (httpClientAdapter as IOHttpClientAdapter)
        : IOHttpClientAdapter();

    // Determine target path if savePath is a String
    String? initialSavePath;
    if (savePath is String) {
      initialSavePath = WebFileSystem.instance.normalize(savePath);
    }

    final res = adapter.performProxyRequest(
      reqOptions,
      savePath: initialSavePath,
    );
    if (res['ok'] != true) {
      throw pkg_dio.DioException(
        requestOptions: reqOptions,
        error: res['error'] ?? 'Download failed',
        type: pkg_dio.DioExceptionType.connectionError,
      );
    }

    final statusCode = (res['statusCode'] as num?)?.toInt() ?? 200;
    final statusText = res['statusText']?.toString();
    final rawHeaders = res['headers'] as Map<String, dynamic>? ?? const {};
    final headersMap = <String, List<String>>{};
    rawHeaders.forEach((k, v) {
      if (v is List) {
        headersMap[k.toLowerCase()] = v.map((e) => e.toString()).toList();
      } else if (v != null) {
        headersMap[k.toLowerCase()] = [v.toString()];
      }
    });
    final dioHeaders = pkg_dio.Headers.fromMap(headersMap);

    final String resolvedSavePath;
    if (savePath is Function) {
      resolvedSavePath = WebFileSystem.instance.normalize(
        savePath(dioHeaders).toString(),
      );
    } else {
      resolvedSavePath = initialSavePath!;
    }

    final b64 = res['bodyBase64'] as String?;
    final inlinedBytes =
        (b64 != null && b64.isNotEmpty) ? base64Decode(b64) : null;
    final savedSize =
        (res['savedSize'] as num?)?.toInt() ?? (inlinedBytes?.length ?? 0);
    final savedMtime =
        (res['savedMtime'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;

    if (initialSavePath != null) {
      WebFileSystem.instance.updateCacheFromServerWrite(
        rawPath: resolvedSavePath,
        size: savedSize,
        mtimeMs: savedMtime,
        bytes: inlinedBytes,
      );
    } else if (inlinedBytes != null) {
      WebFileSystem.instance.writeBytes(resolvedSavePath, inlinedBytes);
    }

    onReceiveProgress?.call(savedSize, savedSize);

    return pkg_dio.Response<dynamic>(
      requestOptions: reqOptions,
      statusCode: statusCode,
      statusMessage: statusText,
      headers: dioHeaders,
      data: inlinedBytes,
    );
  }
}

