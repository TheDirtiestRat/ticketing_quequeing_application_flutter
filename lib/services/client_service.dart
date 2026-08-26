import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

typedef MessageCallback = void Function(String type, Map<String, dynamic> data);

class ClientService {
  Socket? _socket;
  String hostAddress;
  int port;
  MessageCallback? onMessage;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;

  bool get isConnected => _socket != null;

  ClientService({required this.hostAddress, required this.port});

  Future<void> connect() async {
    _socket = await Socket.connect(hostAddress, port);
    debugPrint('Connected to server at $hostAddress:$port');
    onConnected?.call();
    _listen();
  }

  void _listen() {
    String buffer = '';
    _socket!.listen(
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
              onMessage?.call(type, payload);
            } catch (e) {
              debugPrint('Error parsing server message: $e');
            }
          }
        }
      },
      onDone: () {
        debugPrint('Disconnected from server');
        _socket = null;
        onDisconnected?.call();
      },
      onError: (error) {
        debugPrint('Connection error: $error');
        _socket = null;
        onDisconnected?.call();
      },
    );
  }

  void send(String type, Map<String, dynamic> data) {
    if (_socket == null) return;
    final message = jsonEncode({'type': type, 'data': data}) + '\n';
    try {
      _socket!.add(utf8.encode(message));
    } catch (e) {
      debugPrint('Error sending message: $e');
    }
  }

  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
    debugPrint('Disconnected from server');
  }
}
