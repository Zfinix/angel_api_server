library hello_websocket.server;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';
import 'package:angel_auth/angel_auth.dart';
import 'package:angel_framework/angel_framework.dart';
import 'package:angel_framework/http.dart';
import 'package:angel_framework/http2.dart';
import 'package:merge_map/merge_map.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'angel_websocket.dart';
import 'constants.dart';
export 'angel_websocket.dart';

part 'websocket_context.dart';

part 'websocket_controller.dart';

typedef String WebSocketResponseSerializer(data);

/// Broadcasts events from [HookedService]s, and handles incoming [WebSocketAction]s.
class AngelWebSocket {
  List<WebSocketContext> _clients = <WebSocketContext>[];
  final List<String> _servicesAlreadyWired = [];

  final StreamController<WebSocketAction> _onAction =
      new StreamController<WebSocketAction>();
  final StreamController _onData = new StreamController();
  final StreamController<WebSocketContext> _onConnection =
      new StreamController<WebSocketContext>.broadcast();
  final StreamController<WebSocketContext> _onDisconnect =
      new StreamController<WebSocketContext>.broadcast();

  final Angel app;

  /// If this is not `true`, then all client-side service parameters will be
  /// discarded, other than `params['query']`.
  final bool allowClientParams;

  /// An optional whitelist of allowed client origins, or [:null:].
  final List<String> allowedOrigins;

  /// An optional whitelist of allowed client protocols, or [:null:].
  final List<String> allowedProtocols;

  /// If `true`, then clients can authenticate their WebSockets by sending a valid JWT.
  final bool allowAuth;

  /// Send error information across WebSockets, without including debug information..
  final bool sendErrors;

  /// A list of clients currently connected to this server via WebSockets.
  List<WebSocketContext> get clients => new List.unmodifiable(_clients);

  /// Services that have already been hooked to fire socket events.
  List<String> get servicesAlreadyWired =>
      new List.unmodifiable(_servicesAlreadyWired);

  /// Used to notify other nodes of an event's firing. Good for scaled applications.
  final StreamChannel<WebSocketEvent> synchronizationChannel;

  /// Fired on any [WebSocketAction].
  Stream<WebSocketAction> get onAction => _onAction.stream;

  /// Fired whenever a WebSocket sends data.
  Stream get onData => _onData.stream;

  /// Fired on incoming connections.
  Stream<WebSocketContext> get onConnection => _onConnection.stream;

  /// Fired when a user disconnects.
  Stream<WebSocketContext> get onDisconnection => _onDisconnect.stream;

  /// Serializes data to WebSockets.
  WebSocketResponseSerializer serializer;

  /// Deserializes data from WebSockets.
  Function deserializer;

  AngelWebSocket(this.app,
      {this.sendErrors = false,
      this.allowClientParams = false,
      this.allowAuth = true,
      this.synchronizationChannel,
      this.serializer,
      this.deserializer,
      this.allowedOrigins,
      this.allowedProtocols}) {
    if (serializer == null) serializer = json.encode;
    if (deserializer == null) deserializer = (params) => params;
  }

  HookedServiceEventListener serviceHook(String path) {
    return (HookedServiceEvent e) async {
      if (e.params != null && e.params['broadcast'] == false) return;

      var event = await transformEvent(e);
      event.eventName = "$path::${event.eventName}";

      _filter(WebSocketContext socket) {
        if (e.service.configuration.containsKey('ws:filter'))
          return e.service.configuration['ws:filter'](e, socket);
        else if (e.params != null && e.params.containsKey('ws:filter'))
          return e.params['ws:filter'](e, socket);
        else
          return true;
      }

      await batchEvent(event, filter: _filter);
    };
  }

  /// Slates an event to be dispatched.
  Future<void> batchEvent(WebSocketEvent event,
      {filter(WebSocketContext socket), bool notify = true}) async {
    // Default implementation will just immediately fire events
    _clients.forEach((client) async {
      dynamic result = true;
      if (filter != null) result = await filter(client);
      if (result == true) {
        client.channel.sink.add((serializer ?? json.encode)(event.toJson()));
      }
    });

    if (synchronizationChannel != null && notify != false)
      synchronizationChannel.sink.add(event);
  }

  /// Returns a list of events yet to be sent.
  Future<List<WebSocketEvent>> getBatchedEvents() async => [];

  /// Responds to an incoming action on a WebSocket.
  Future handleAction(WebSocketAction action, WebSocketContext socket) async {
    var split = action.eventName.split("::");

    if (split.length < 2) {
      socket.sendError(new AngelHttpException.badRequest());
      return null;
    }

    var service = app.findService(split[0]);

    if (service == null) {
      socket.sendError(new AngelHttpException.notFound(
          message: "No service \"${split[0]}\" exists."));
      return null;
    }

    var actionName = split[1];

    if (action.params is! Map) action.params = <String, dynamic>{};

    if (allowClientParams != true) {
      if (action.params['query'] is Map)
        action.params = {'query': action.params['query']};
      else
        action.params = {};
    }

    var params = mergeMap<String, dynamic>([
      ((deserializer ?? (params) => params)(action.params))
          as Map<String, dynamic>,
      {
        "provider": Providers.websocket,
        '__requestctx': socket.request,
        '__responsectx': socket.response
      }
    ]);

    try {
      if (actionName == indexAction) {
        socket.send(
            "${split[0]}::" + indexedEvent, await service.index(params));
        return null;
      } else if (actionName == readAction) {
        socket.send(
            "${split[0]}::" + readEvent, await service.read(action.id, params));
        return null;
      } else if (actionName == createAction) {
        return new WebSocketEvent(
            eventName: "${split[0]}::" + createdEvent,
            data: await service.create(action.data, params));
      } else if (actionName == modifyAction) {
        return new WebSocketEvent(
            eventName: "${split[0]}::" + modifiedEvent,
            data: await service.modify(action.id, action.data, params));
      } else if (actionName == updateAction) {
        return new WebSocketEvent(
            eventName: "${split[0]}::" + updatedEvent,
            data: await service.update(action.id, action.data, params));
      } else if (actionName == removeAction) {
        return new WebSocketEvent(
            eventName: "${split[0]}::" + removedEvent,
            data: await service.remove(action.id, params));
      } else {
        socket.sendError(new AngelHttpException.methodNotAllowed(
            message: "Method Not Allowed: \"$actionName\""));
        return null;
      }
    } catch (e, st) {
      catchError(e, st, socket);
    }
  }

  /// Authenticates a [WebSocketContext].
  Future handleAuth(WebSocketAction action, WebSocketContext socket) async {
    if (allowAuth != false &&
        action.eventName == authenticateAction &&
        action.params['query'] is Map &&
        action.params['query']['jwt'] is String) {
      try {
        var auth = socket.request.container.make<AngelAuth>();
        var jwt = action.params['query']['jwt'] as String;
        AuthToken token;

        token = new AuthToken.validate(jwt, auth.hmac);
        var user = await auth.deserializer(token.userId);
        socket.request
          ..container.registerSingleton<AuthToken>(token)
          ..container.registerSingleton(user, as: user.runtimeType as Type);
        socket._onAuthenticated.add(null);
        socket.send(authenticatedEvent,
            {'token': token.serialize(auth.hmac), 'data': user});
      } catch (e, st) {
        catchError(e, st, socket);
      }
    } else {
      socket.sendError(new AngelHttpException.badRequest(
          message: 'No JWT provided for authentication.'));
    }
  }

  /// Hooks a service up to have its events broadcasted.
  hookupService(Pattern _path, HookedService service) {
    String path = _path.toString();
    service.after(
      [
        HookedServiceEvent.created,
        HookedServiceEvent.modified,
        HookedServiceEvent.updated,
        HookedServiceEvent.removed
      ],
      serviceHook(path),
    );
    _servicesAlreadyWired.add(path);
  }

  /// Runs before firing [onConnection].
  Future handleConnect(WebSocketContext socket) async {}

  /// Handles incoming data from a WebSocket.
  handleData(WebSocketContext socket, data) async {
    try {
      socket._onData.add(data);
      var fromJson = json.decode(data.toString());
      var action = new WebSocketAction.fromJson(fromJson as Map);
      _onAction.add(action);

      if (action.eventName == null ||
          action.eventName is! String ||
          action.eventName.isEmpty) {
        throw new AngelHttpException.badRequest();
      }

      if (fromJson is Map && fromJson.containsKey("eventName")) {
        socket._onAction.add(new WebSocketAction.fromJson(fromJson));
        socket.on
            ._getStreamForEvent(fromJson["eventName"].toString())
            .add(fromJson["data"] as Map);
      }

      if (action.eventName == authenticateAction)
        await handleAuth(action, socket);

      if (action.eventName.contains("::")) {
        var split = action.eventName.split("::");

        if (split.length >= 2) {
          if (actions.contains(split[1])) {
            var event = await handleAction(action, socket);
            if (event is Future) event = await event;
          }
        }
      }
    } catch (e, st) {
      catchError(e, st, socket);
    }
  }

  void catchError(e, StackTrace st, WebSocketContext socket) {
    // Send an error
    if (e is AngelHttpException) {
      socket.sendError(e);
      app.logger?.severe(e.message, e.error ?? e, e.stackTrace);
    } else if (sendErrors) {
      var err = new AngelHttpException(e,
          message: e.toString(), stackTrace: st, errors: [st.toString()]);
      socket.sendError(err);
      app.logger?.severe(err.message, e, st);
    } else {
      var err = new AngelHttpException(e);
      socket.sendError(err);
      app.logger?.severe(e.toString(), e, st);
    }
  }

  /// Transforms a [HookedServiceEvent], so that it can be broadcasted.
  Future<WebSocketEvent> transformEvent(HookedServiceEvent event) async {
    return new WebSocketEvent(eventName: event.eventName, data: event.result);
  }

  /// Hooks any [HookedService]s that are not being broadcasted yet.
  wireAllServices(Angel app) {
    for (Pattern key in app.services.keys.where((x) {
      return !_servicesAlreadyWired.contains(x) &&
          app.services[x] is HookedService;
    })) {
      hookupService(key, app.services[key] as HookedService);
    }
  }

  /// Configures an [Angel] instance to listen for WebSocket connections.
  Future configureServer(Angel app) async {
    app..container.registerSingleton(this);

    if (runtimeType != AngelWebSocket)
      app..container.registerSingleton<AngelWebSocket>(this);

    // Set up services
    wireAllServices(app);

    app.onService.listen((_) {
      wireAllServices(app);
    });

    if (synchronizationChannel != null) {
      synchronizationChannel.stream.listen((e) => batchEvent(e, notify: false));
    }

    app.shutdownHooks.add((_) => synchronizationChannel?.sink?.close());
  }

  /// Handles an incoming [WebSocketContext].
  Future<void> handleClient(WebSocketContext socket) async {
    var origin = socket.request.headers.value('origin');
    if (allowedOrigins != null && !allowedOrigins.contains(origin)) {
      throw new AngelHttpException.forbidden(
          message:
              'WebSocket connections are not allowed from the origin "$origin".');
    }

    _clients.add(socket);
    await handleConnect(socket);

    _onConnection.add(socket);

    socket.request.container.registerSingleton<WebSocketContext>(socket);

    socket.channel.stream.listen(
      (data) {
        _onData.add(data);
        handleData(socket, data);
      },
      onDone: () {
        _onDisconnect.add(socket);
        _clients.remove(socket);
      },
      onError: (e) {
        _onDisconnect.add(socket);
        _clients.remove(socket);
      },
      cancelOnError: true,
    );
  }

  /// Handles an incoming HTTP request.
  Future<bool> handleRequest(RequestContext req, ResponseContext res) async {
    if (req is HttpRequestContext && res is HttpResponseContext) {
      if (!WebSocketTransformer.isUpgradeRequest(req.rawRequest))
        throw new AngelHttpException.badRequest();
      await res.detach();
      var ws = await WebSocketTransformer.upgrade(req.rawRequest);
      var channel = new IOWebSocketChannel(ws);
      var socket = new WebSocketContext(channel, req, res);
      scheduleMicrotask(() => handleClient(socket));
      return false;
    } else if (req is Http2RequestContext && res is Http2ResponseContext) {
      var connection =
          req.headers['connection']?.map((s) => s.toLowerCase().trim());
      var upgrade = req.headers.value('upgrade')?.toLowerCase();
      var version = req.headers.value('sec-websocket-version');
      var key = req.headers.value('sec-websocket-key');
      var protocol = req.headers.value('sec-websocket-protocol');

      if (connection == null) {
        throw new AngelHttpException.badRequest(
            message: 'Missing `connection` header.');
      } else if (!connection.contains('upgrade')) {
        throw new AngelHttpException.badRequest(
            message: 'Missing "upgrade" in `connection` header.');
      } else if (upgrade != 'websocket') {
        throw new AngelHttpException.badRequest(
            message: 'The `upgrade` header must equal "websocket".');
      } else if (version != '13') {
        throw new AngelHttpException.badRequest(
            message: 'The `sec-websocket-version` header must equal "13".');
      } else if (key == null) {
        throw new AngelHttpException.badRequest(
            message: 'Missing `sec-websocket-key` header.');
      } else if (protocol != null &&
          allowedProtocols != null &&
          !allowedProtocols.contains(protocol)) {
        throw new AngelHttpException.badRequest(
            message: 'Disallowed `sec-websocket-protocol` header "$protocol".');
      } else {
        var stream = res.detach();
        var ctrl = new StreamChannelController<List<int>>();

        ctrl.local.stream.listen((buf) {
          stream.sendData(buf);
        }, onDone: () {
          stream.outgoingMessages.close();
        });

        if (req.hasParsedBody) {
          await ctrl.local.sink.close();
        } else {
          await req.body.pipe(ctrl.local.sink);
        }

        var sink = utf8.encoder.startChunkedConversion(ctrl.foreign.sink);
        sink.add("HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: ${WebSocketChannel.signKey(key)}\r\n");
        if (protocol != null) sink.add("Sec-WebSocket-Protocol: $protocol\r\n");
        sink.add("\r\n");

        var ws = new WebSocketChannel(ctrl.foreign);
        var socket = new WebSocketContext(ws, req, res);
        scheduleMicrotask(() => handleClient(socket));
        return false;
      }
    } else {
      throw new ArgumentError(
          'Not an HTTP/1.1 or HTTP/2 RequestContext+ResponseContext pair: $req, $res');
    }
  }
}
