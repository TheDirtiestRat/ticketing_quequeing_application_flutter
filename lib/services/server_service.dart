import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

typedef MessageCallback = void Function(
    String type, Map<String, dynamic> data, Socket sender);

class ServerService {
  int port;
  ServerSocket? _serverSocket;
  final Map<Socket, String> _clients = {};
  MessageCallback? onMessage;
  Function(Socket socket, String role)? onClientDisconnect;

  ServerService({required this.port});

  bool get isRunning => _serverSocket != null;

  int get clientCount => _clients.length;

  int get tellerCount =>
      _clients.values.where((role) => role == 'teller').length;

  int get monitorCount =>
      _clients.values.where((role) => role == 'monitor').length;

  List<Socket> get tellerClients =>
      _clients.entries.where((e) => e.value == 'teller').map((e) => e.key).toList();

  List<Socket> get monitorClients =>
      _clients.entries.where((e) => e.value == 'monitor').map((e) => e.key).toList();

  String getRole(Socket socket) => _clients[socket] ?? '';

  Future<String> getHostAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> start() async {
    _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _serverSocket!.listen(
      (socket) {
        debugPrint('Client connected: ${socket.remoteAddress.address}');
        _handleClient(socket);
      },
      onError: (error) {
        debugPrint('Server error: $error');
      },
    );
    debugPrint('Server started on port $port');
  }

  void _handleClient(Socket socket) {
    String buffer = '';
    socket.listen(
      (data) {
        buffer += utf8.decode(data);
        while (buffer.contains('\n')) {
          final index = buffer.indexOf('\n');
          final line = buffer.substring(0, index).trim();
          buffer = buffer.substring(index + 1);
          if (line.isNotEmpty) {
            try {
              final message = jsonDecode(line) as Map<String, dynamic>;
              final type = message['type'] as String? ?? '';
              final payload = message['data'] as Map<String, dynamic>? ?? {};

              if (type == 'register') {
                final role = payload['role'] as String? ?? 'monitor';
                _clients[socket] = role;
                debugPrint(
                    'Client registered as $role (${_clients.length} total)');
                sendTo(socket, 'registered', {
                  'role': role,
                  'tellerCount': tellerCount,
                  'monitorCount': monitorCount,
                });
                onMessage?.call(type, payload, socket);
              } else {
                onMessage?.call(type, payload, socket);
              }
            } catch (e) {
              debugPrint('Error parsing client message: $e');
            }
          }
        }
      },
      onDone: () {
        final role = _clients.remove(socket) ?? '';
        onClientDisconnect?.call(socket, role);
        debugPrint(
            'Client disconnected: ${socket.remoteAddress.address} (${_clients.length} remaining)');
      },
      onError: (error) {
        final role = _clients.remove(socket) ?? '';
        onClientDisconnect?.call(socket, role);
        debugPrint('Client error: $error');
      },
    );
  }

  void sendTo(Socket socket, String type, Map<String, dynamic> data) {
    final message = '${jsonEncode({'type': type, 'data': data})}\n';
    try {
      socket.add(utf8.encode(message));
    } catch (e) {
      debugPrint('Error sending to client: $e');
      _clients.remove(socket);
      try {
        socket.close();
      } catch (_) {}
    }
  }

  void broadcast(String type, Map<String, dynamic> data,
      {String? toRole}) {
    final message = '${jsonEncode({'type': type, 'data': data})}\n';
    final bytes = utf8.encode(message);
    final deadClients = <Socket>[];
    for (final entry in _clients.entries) {
      if (toRole != null && entry.value != toRole) continue;
      try {
        entry.key.add(bytes);
      } catch (e) {
        deadClients.add(entry.key);
      }
    }
    for (final client in deadClients) {
      _clients.remove(client);
      try {
        client.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    for (final client in _clients.keys.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();
    await _serverSocket?.close();
    _serverSocket = null;
    debugPrint('Server stopped');
  }
}
