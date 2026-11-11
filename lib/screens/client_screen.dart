import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:flutter/services.dart';

import '../services/client_service.dart';

import 'package:window_manager/window_manager.dart';

class ClientScreen extends StatefulWidget {
  final String hostAddress;
  final int port;

  const ClientScreen({
    super.key,
    required this.hostAddress,
    required this.port,
  });

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen>
    with SingleTickerProviderStateMixin {
  bool _isFullScreen = false;
  late final AnimationController _windowShakeController;
  late final Animation<double> _windowShake;
  Timer? _windowHighlightTimer;
  String? _callingWindow;

  late final ClientService _client;
  late final Player _player;
  late final VideoController _videoController;
  final AudioPlayer _announcementPlayer = AudioPlayer();
  final FlutterTts _textToSpeech = FlutterTts();
  Future<void> _speechReady = Future<void>.value();
  Future<void> _announcementQueue = Future<void>.value();

  String _status = 'Connecting...';
  bool _isConnected = false;
  double _videoVolume = 100;

  String window1Ticket = '---';
  String window2Ticket = '---';
  List<Map<String, String>> nextQueue = [];
  int pendingCount = 0;

  List<String> _playlist = [];
  int _currentPlaylistIndex = -1;
  StreamSubscription<dynamic>? _completedSub;

  late Timer _clockTimer;
  String _currentTime = '';

  @override
  void initState() {
    super.initState();
    _windowShakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _windowShake = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -8), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -8, end: 8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8, end: -6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6, end: 5), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 5, end: -2), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -2, end: 0), weight: 1),
    ]).animate(_windowShakeController);
    _player = Player();
    _videoController = VideoController(_player);
    _speechReady = _initializeSpeech();
    _initPlayer();
    _initClient();
    _startClock();
    _syncFullScreenState();
  }

  Future<void> _syncFullScreenState() async {
    bool isFS = await windowManager.isFullScreen();
    if (mounted) {
      setState(() {
        _isFullScreen = isFS;
      });
    }
  }

  void _handleFullscreenShortcut(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;

    if (isShiftPressed && event.logicalKey == LogicalKeyboardKey.keyF) {
      _toggleFullScreen();
    }
  }

  Future<void> _toggleFullScreen() async {
    bool isFS = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFS);

    debugPrint('Pressed Going to Fullscreen');

    if (mounted) {
      setState(() {
        _isFullScreen = !isFS;
      });
    }
  }

  void _initPlayer() {
    _completedSub = _player.stream.completed.listen((completed) async {
      if (!mounted || !completed || _playlist.isEmpty) return;

      // Move to the next video.
      // If the current video is the last one, return to index 0.
      final nextIndex = (_currentPlaylistIndex + 1) % _playlist.length;

      await _playIndex(nextIndex);
    });
  }

  void _initClient() {
    _client = ClientService(hostAddress: widget.hostAddress, port: widget.port);

    _client.onConnected = () {
      _client.send('register', {'role': 'monitor'});
      if (mounted) {
        setState(() {
          _isConnected = true;
          _status = 'Connected to ${widget.hostAddress}:${widget.port}';
        });
      }
    };

    _client.onDisconnected = () {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _status = 'Disconnected - Reconnecting...';
        });
        _reconnect();
      }
    };

    _client.onMessage = (type, data) {
      if (!mounted) return;
      switch (type) {
        case 'queue_update':
          _handleQueueUpdate(data);
          break;
        case 'play_video':
          _handlePlayVideo(data);
          break;
        case 'play_video_list':
          _handlePlayVideoList(data);
          break;
        case 'set_video_volume':
          _handleVideoVolume(data);
          break;
        case 'ticket_called':
          _highlightCallingWindow(data);
          _queueTicketAnnouncement(data);
          break;
      }
    };

    _client.connect().catchError((e) {
      debugPrint('Initial connection failed: $e');
      if (mounted) {
        setState(() {
          _status = 'Connection failed - Retrying...';
        });
        _reconnect();
      }
    });
  }

  Future<void> _reconnect() async {
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted || _client.isConnected) return;
    try {
      await _client.connect();
    } catch (e) {
      debugPrint('Reconnect failed: $e');
      _reconnect();
    }
  }

  void _highlightCallingWindow(Map<String, dynamic> data) {
    final window = data['window']?.toString();
    if (window != 'Window 1' && window != 'Window 2') return;

    _windowHighlightTimer?.cancel();
    setState(() => _callingWindow = window);
    _windowShakeController.forward(from: 0);
    _windowHighlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || _callingWindow != window) return;
      setState(() => _callingWindow = null);
    });
  }

  void _handleQueueUpdate(Map<String, dynamic> data) {
    setState(() {
      final windows = data['windows'];
      if (windows is List) {
        for (final entry in windows) {
          if (entry is! Map) continue;
          final name = entry['name']?.toString();
          final ticket = entry['ticket']?.toString() ?? '---';
          if (name == 'Window 1') {
            window1Ticket = ticket;
          } else if (name == 'Window 2') {
            window2Ticket = ticket;
          }
        }
      } else {
        window1Ticket = data['window1']?.toString() ?? window1Ticket;
        window2Ticket = data['window2']?.toString() ?? window2Ticket;
      }
      if (data['pendingCount'] != null) {
        pendingCount =
            int.tryParse(data['pendingCount'].toString()) ?? pendingCount;
      }
      if (data['nextUp'] is List) {
        final list = List<dynamic>.from(data['nextUp'] as List);
        nextQueue = list
            .map((ticket) => {'ticket': ticket.toString(), 'status': 'Ready'})
            .toList();
      }
    });
  }

  void _handlePlayVideo(Map<String, dynamic> data) {
    final path = data['path'] as String?;
    if (path == null || path.isEmpty) return;
    final uri = _toMediaUri(path);
    _playlist = [uri];
    _currentPlaylistIndex = 0;
    _playCurrentMedia();
  }

  void _handlePlayVideoList(Map<String, dynamic> data) {
    final mediaLocations = data['urls'] ?? data['paths'];
    if (mediaLocations is! List) return;
    final locations = mediaLocations.whereType<String>().toList();
    if (locations.isEmpty) return;
    _playlist = locations.map(_toMediaUri).toList();
    _currentPlaylistIndex = 0;
    _playCurrentMedia();
  }

  void _handleVideoVolume(Map<String, dynamic> data) {
    final volume = data['volume'];
    if (volume is! num) return;
    _videoVolume = volume.clamp(0, 100).toDouble();
    _player.setVolume(_videoVolume).catchError((Object error) {
      debugPrint('Failed to set video volume: $error');
    });
  }

  Future<void> _initializeSpeech() async {
    try {
      await _textToSpeech.setLanguage('en-US');
      await _textToSpeech.setSpeechRate(0.45);
      await _textToSpeech.setVolume(1);
      await _textToSpeech.setPitch(1);
      await _textToSpeech.awaitSpeakCompletion(true);
    } catch (error) {
      debugPrint('Failed to initialize ticket announcements: $error');
    }
  }

  void _queueTicketAnnouncement(Map<String, dynamic> data) {
    final ticket = data['ticket']?.toString().trim() ?? '';
    final window = data['window']?.toString().trim() ?? '';
    if (ticket.isEmpty || window.isEmpty) return;

    _announcementQueue = _announcementQueue
        .then((_) => _announceTicket(ticket, window))
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Failed to announce ticket $ticket: $error');
          },
        );
  }

  Future<void> _announceTicket(String ticket, String window) async {
    try {
      await _announcementPlayer.stop();
      await _announcementPlayer.setVolume(0.7);
      final playbackCompleted = _announcementPlayer.onPlayerComplete.first;
      await _announcementPlayer.play(BytesSource(_createNotificationSound()));
      await playbackCompleted.timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('Failed to play ticket notification sound: $error');
    }
    if (!mounted) return;
    await _speechReady;
    if (!mounted) return;
    await _textToSpeech.speak(
      '${ticket.replaceAll(RegExp(r'[-_]'), ' ')}, please proceed to $window.',
    );
  }

  Uint8List _createNotificationSound() {
    const sampleRate = 22050;
    const notes = [
      (frequency: 880.0, duration: 0.18),
      (frequency: 1174.66, duration: 0.28),
    ];
    final samples = <int>[];
    for (final note in notes) {
      final noteSamples = (sampleRate * note.duration).round();
      for (var i = 0; i < noteSamples; i++) {
        final progress = i / noteSamples;
        final envelope = math.pow(1 - progress, 2);
        final sample =
            math.sin(2 * math.pi * note.frequency * i / sampleRate) *
            envelope *
            0.55;
        samples.add((sample * 32767).round());
      }
      samples.addAll(List<int>.filled((sampleRate * 0.035).round(), 0));
    }

    final data = ByteData(44 + samples.length * 2);
    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        data.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  String _toMediaUri(String path) {
    if (path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('file://')) {
      return path;
    }
    return Uri.file(path).toString();
  }

  Future<void> _playCurrentMedia() async {
    if (_currentPlaylistIndex < 0 ||
        _currentPlaylistIndex >= _playlist.length) {
      return;
    }
    try {
      await _player.setVolume(_videoVolume);
      await _player.open(Media(_playlist[_currentPlaylistIndex]));
      await _player.play();
    } catch (e) {
      debugPrint('Failed to play media: $e');
    }
  }

  Future<void> _playIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    setState(() {
      _currentPlaylistIndex = index;
    });
    await _playCurrentMedia();
  }

  void _startClock() {
    _updateTime();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _updateTime();
    });
  }

  void _updateTime() {
    final now = DateTime.now();
    final hour = now.hour == 0
        ? 12
        : (now.hour > 12 ? now.hour - 12 : now.hour);
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    final period = now.hour >= 12 ? 'PM' : 'AM';
    final newTime = '$hour:$minute:$second $period';
    if (_currentTime != newTime) {
      setState(() {
        _currentTime = newTime;
      });
    }
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _windowHighlightTimer?.cancel();
    _windowShakeController.dispose();
    _completedSub?.cancel();
    _client.disconnect();
    _announcementPlayer.dispose();
    _textToSpeech.stop();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            HardwareKeyboard.instance.isShiftPressed &&
            event.logicalKey == LogicalKeyboardKey.keyF) {
          _toggleFullScreen();

          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFDCDFE4),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 12,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            color: Colors.black,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: Video(controller: _videoController),
                                ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 14,
                                    ),
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Color(0xFF1D4ED8),
                                          Color(0xFF1E3A8A),
                                        ],
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        const Text(
                                          'ACLC ORMOC',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 26,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Text(
                                          _isConnected
                                              ? 'Please have your tickets ready'
                                              : 'Connecting to server...',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 12,
                                  left: 12,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _isConnected
                                          ? Colors.green.withValues(alpha: 0.8)
                                          : Colors.red.withValues(alpha: 0.8),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _isConnected
                                              ? Icons.circle
                                              : Icons.circle,
                                          size: 8,
                                          color: Colors.white,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          _isConnected ? 'ONLINE' : 'OFFLINE',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 5,
                        child: Column(
                          children: [
                            const _HeaderPill(
                              title: 'NOW SERVING',
                              color: Color(0xFF4338CA),
                              textColor: Colors.white,
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: _WindowDisplayCard(
                                title: 'Window 1',
                                ticket: window1Ticket,
                                isCalling: _callingWindow == 'Window 1',
                                shakeAnimation: _windowShake,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: _WindowDisplayCard(
                                title: 'Window 2',
                                ticket: window2Ticket,
                                isCalling: _callingWindow == 'Window 2',
                                shakeAnimation: _windowShake,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 5,
                        child: Column(
                          children: [
                            const _HeaderPill(
                              title: 'NEXT IN LINE',
                              color: Color(0xFFE2E8F0),
                              textColor: Color(0xFF334155),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: nextQueue.isEmpty
                                  ? const Center(
                                      child: Text(
                                        'No tickets queued',
                                        style: TextStyle(color: Colors.black45),
                                      ),
                                    )
                                  : LayoutBuilder(
                                      builder: (context, constraints) {
                                        final rowHeight = math.max(
                                          60.0,
                                          constraints.maxHeight /
                                              nextQueue.length,
                                        );

                                        return ListView.builder(
                                          padding: EdgeInsets.zero,
                                          itemCount: nextQueue.length,
                                          itemExtent: rowHeight,
                                          itemBuilder: (context, index) {
                                            final item = nextQueue[index];

                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 12,
                                              ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 10,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Row(
                                                  children: [
                                                    Text(
                                                      '${index + 1}',
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 14,
                                                        color: Colors.black54,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 16),
                                                    Expanded(
                                                      child: Text(
                                                        item['ticket'] ?? '',
                                                        style: const TextStyle(
                                                          fontSize: 22,
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          color: Colors.black87,
                                                        ),
                                                      ),
                                                    ),
                                                    Text(
                                                      item['status'] ?? 'Ready',
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: Colors.black54,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    ),
                            ),
                            // const SizedBox(height: 4),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE2E8F0),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Center(
                                child: Text(
                                  '$pendingCount PENDING',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF334155),
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: 10,
                  right: 10,
                  top: 0,
                  bottom: 10,
                ),
                child: Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    // widthFactor: 0.98,
                    child: Container(
                      height: 64,
                      padding: const EdgeInsets.only(
                        left: 10,
                        right: 10,
                        top: 10,
                        bottom: 10,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF1E3A8A),
                            Color.fromARGB(255, 2, 4, 10),
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                      child: Row(
                        // mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ElevatedButton(
                            onPressed: _toggleFullScreen,
                            style: ElevatedButton.styleFrom(
                              // fixedSize: const Size(50, 50),
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8), // Change to BorderRadius.zero for sharp corners
                              ),
                            ),
                            child: Icon(
                              _isFullScreen
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                          SizedBox(width: 12),
                          Text(
                            _status,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              letterSpacing: 0.5,
                            ),
                          ),
                          // CustomMarqueeText(text: "Hello There my Fello Dude's this Application is Created by Mr. Dirty Rats"),
                          Spacer(),
                          Text(
                            "Develop By: @Mr.DirtiestRat with the @Programmers Guild",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          SizedBox(width: 12),
                          Text(
                            _currentTime,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final String title;
  final Color color;
  final Color textColor;

  const _HeaderPill({
    required this.title,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          title,
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w900,
            fontSize: 13,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

class _WindowDisplayCard extends StatelessWidget {
  final String title;
  final String ticket;
  final bool isCalling;
  final Animation<double> shakeAnimation;

  const _WindowDisplayCard({
    required this.title,
    required this.ticket,
    required this.isCalling,
    required this.shakeAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: shakeAnimation,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isCalling ? const Color(0xFFFEF3C7) : const Color(0xFFCBD5E1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isCalling ? const Color(0xFFF59E0B) : Colors.transparent,
            width: 3,
          ),
          boxShadow: isCalling
              ? [
                  BoxShadow(
                    color: Colors.amber.withValues(alpha: 0.4),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: isCalling
                        ? const Color(0xFF92400E)
                        : const Color(0xFF475569),
                  ),
                ),
                if (isCalling) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.campaign_rounded,
                    size: 20,
                    color: Color(0xFFD97706),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: isCalling ? const Color(0xFFFFFBEB) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    ticket,
                    style: TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      color: isCalling
                          ? const Color(0xFFB45309)
                          : const Color(0xFF4338CA),
                      letterSpacing: 2.0,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      builder: (context, child) => Transform.translate(
        offset: Offset(shakeAnimation.value, 0),
        child: child,
      ),
    );
  }
}
