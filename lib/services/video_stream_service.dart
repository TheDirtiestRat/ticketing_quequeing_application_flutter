import 'dart:io';

import 'package:flutter/foundation.dart';

class VideoStreamService {
  HttpServer? _httpServer;
  List<String> _paths = [];

  Future<void> start() async {
    _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _httpServer!.listen(_handleRequest);
  }

  int? get port => _httpServer?.port;

  void setPaths(List<String> paths) {
    _paths = List<String>.unmodifiable(paths);
  }

  List<String> getUrls(String hostAddress) {
    if (port == null) return [];
    return List<String>.generate(
      _paths.length,
      (index) => Uri(
        scheme: 'http',
        host: hostAddress,
        port: port,
        path: '/video/$index',
      ).toString(),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final match = RegExp(r'^/video/(\d+)$').firstMatch(request.uri.path);
    final index = match == null ? null : int.tryParse(match.group(1)!);
    if ((request.method != 'GET' && request.method != 'HEAD') ||
        index == null ||
        index < 0 ||
        index >= _paths.length) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final file = File(_paths[index]);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final length = await file.length();
    var start = 0;
    var end = length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null || length == 0) {
        await _rejectRange(request.response, length);
        return;
      }
      final requestedStart = int.tryParse(match.group(1)!);
      final requestedEnd = int.tryParse(match.group(2)!);
      if (requestedStart == null) {
        final suffixLength = requestedEnd;
        if (suffixLength == null || suffixLength <= 0) {
          await _rejectRange(request.response, length);
          return;
        }
        start = (length - suffixLength).clamp(0, length).toInt();
      } else {
        start = requestedStart;
        end = requestedEnd ?? end;
      }
      if (start >= length || end < start) {
        await _rejectRange(request.response, length);
        return;
      }
      end = end.clamp(0, length - 1).toInt();
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }

    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.contentType = _contentType(file.path);
    request.response.contentLength = end - start + 1;
    if (request.method == 'GET') {
      try {
        await request.response.addStream(file.openRead(start, end + 1));
      } catch (error) {
        debugPrint('Failed streaming video ${file.path}: $error');
      }
    }
    await request.response.close();
  }

  Future<void> _rejectRange(HttpResponse response, int length) async {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
    await response.close();
  }

  ContentType _contentType(String path) {
    switch (path.toLowerCase().split('.').last) {
      case 'mp4':
        return ContentType('video', 'mp4');
      case 'mov':
        return ContentType('video', 'quicktime');
      case 'webm':
        return ContentType('video', 'webm');
      case 'mkv':
        return ContentType('video', 'x-matroska');
      default:
        return ContentType.binary;
    }
  }

  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
  }
}
