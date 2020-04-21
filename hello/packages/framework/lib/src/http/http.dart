library hello_framework.http;

import 'dart:async';
import 'dart:io';
export 'angel_http.dart';
export 'http_request_context.dart';
export 'http_response_context.dart';

/// Boots a shared server instance. Use this if launching multiple isolates.
Future<HttpServer> startShared(address, int port) =>
    HttpServer.bind(address ?? '127.0.0.1', port ?? 0, shared: true);

Future<HttpServer> Function(dynamic, int) startSharedSecure(
    SecurityContext securityContext) {
  return (address, int port) => HttpServer.bindSecure(
      address ?? '127.0.0.1', port ?? 0, securityContext,
      shared: true);
}
