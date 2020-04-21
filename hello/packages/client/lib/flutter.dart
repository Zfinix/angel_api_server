library hello_client.flutter;

import 'dart:async';
import 'package:http/http.dart' as http;
import 'base_angel_client.dart';
export 'angel_client.dart';

/// Queries an Angel server via REST.
class Rest extends BaseAngelClient {
  Rest(String basePath) : super(new http.Client() as http.BaseClient, basePath);

  @override
  Stream<String> authenticateViaPopup(String url,
      {String eventName = 'token'}) {
    throw new UnimplementedError(
        'Opening popup windows is not supported in the `flutter` client.');
  }
}
