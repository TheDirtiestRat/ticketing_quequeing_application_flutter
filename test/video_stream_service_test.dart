import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ticketing_quequeing_application/services/video_stream_service.dart';

void main() {
  late Directory tempDirectory;
  late VideoStreamService videoStream;
  late HttpClient httpClient;
  late String videoUrl;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('video-stream-test');
    final videoFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}test.mp4',
    );
    await videoFile.writeAsBytes('0123456789'.codeUnits);

    videoStream = VideoStreamService()..setPaths([videoFile.path]);
    await videoStream.start();
    httpClient = HttpClient();
    videoUrl = videoStream.getUrls('127.0.0.1').single;
  });

  tearDown(() async {
    httpClient.close(force: true);
    await videoStream.stop();
    await tempDirectory.delete(recursive: true);
  });

  test('serves the selected file to clients', () async {
    final request = await httpClient.getUrl(Uri.parse(videoUrl));
    final response = await request.close();

    expect(response.statusCode, HttpStatus.ok);
    expect(
      await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      ),
      '0123456789'.codeUnits,
    );
  });

  test('supports byte-range requests for video playback', () async {
    final request = await httpClient.getUrl(Uri.parse(videoUrl));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
    final response = await request.close();

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 2-5/10',
    );
    expect(
      await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      ),
      '2345'.codeUnits,
    );
  });
}
