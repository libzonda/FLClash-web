import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' as pkg_dio;

import 'dart_io.dart';
import 'js_bridge.dart';
import 'vfs.dart';

typedef CreateHttpClient = HttpClient Function();
typedef ValidateCertificate =
    bool Function(X509Certificate? certificate, String host, int port);

class IOHttpClientAdapter implements pkg_dio.HttpClientAdapter {
  CreateHttpClient? createHttpClient;
  ValidateCertificate? validateCertificate;

  IOHttpClientAdapter({
    this.createHttpClient,
    this.validateCertificate,
    @Deprecated('Use createHttpClient instead')
    CreateHttpClient? onHttpClientCreate,
  }) {
    createHttpClient ??= onHttpClientCreate;
  }

  Map<String, dynamic> performProxyRequest(
    pkg_dio.RequestOptions options, {
    Uint8List? bodyBytes,
    String? savePath,
  }) {
    String proxyUrl = 'DIRECT';
    String? clientUserAgent;
    if (createHttpClient != null) {
      try {
        final client = createHttpClient!();
        if (client.findProxy != null) {
          proxyUrl = client.findProxy!(options.uri);
        }
        clientUserAgent = client.userAgent;
      } catch (_) {}
    }

    final headers = <String, String>{};
    if (clientUserAgent != null && clientUserAgent.isNotEmpty) {
      headers['user-agent'] = clientUserAgent;
    }
    options.headers.forEach((key, value) {
      if (value != null) {
        headers[key] = value.toString();
      }
    });

    final timeoutMs =
        options.receiveTimeout?.inMilliseconds ??
        options.connectTimeout?.inMilliseconds ??
        60000;

    final payload = <String, dynamic>{
      'method': options.method,
      'url': options.uri.toString(),
      'headers': headers,
      'timeoutMs': timeoutMs,
      'proxyUrl': proxyUrl,
      'followRedirects': options.followRedirects,
      if (bodyBytes != null && bodyBytes.isNotEmpty)
        'bodyBase64': base64Encode(bodyBytes),
      if (savePath != null && savePath.isNotEmpty) 'savePath': savePath,
    };

    return JsBridge.syncJsonRequest('POST', '/api/http-proxy', payload);
  }

  @override
  Future<pkg_dio.ResponseBody> fetch(
    pkg_dio.RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Uint8List? bodyBytes;
    if (requestStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
      bodyBytes = builder.takeBytes();
    }

    final res = performProxyRequest(options, bodyBytes: bodyBytes);
    if (res['ok'] != true) {
      throw pkg_dio.DioException(
        requestOptions: options,
        error: res['error'] ?? 'HTTP Proxy request failed',
        type: pkg_dio.DioExceptionType.connectionError,
      );
    }

    final statusCode = (res['statusCode'] as num?)?.toInt() ?? 200;
    final statusText = res['statusText']?.toString();
    final rawHeaders = res['headers'] as Map<String, dynamic>? ?? const {};
    final responseHeaders = <String, List<String>>{};
    rawHeaders.forEach((k, v) {
      if (v is List) {
        responseHeaders[k.toLowerCase()] = v.map((e) => e.toString()).toList();
      } else if (v != null) {
        responseHeaders[k.toLowerCase()] = [v.toString()];
      }
    });

    final b64 = res['bodyBase64'] as String? ?? '';
    final respBytes = b64.isEmpty ? Uint8List(0) : base64Decode(b64);

    return pkg_dio.ResponseBody.fromBytes(
      respBytes,
      statusCode,
      statusMessage: statusText,
      headers: responseHeaders,
    );
  }

  @override
  void close({bool force = false}) {}
}

