import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ticketing_quequeing_application/components/marque.dart';

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

class _ClientScreenState extends State<ClientScreen> {
  bool _isFullScreen = false;

  late final ClientService _client;
  late final Player _player;
  late final VideoController _videoController;

  String _status = 'Connecting...';
  bool _isConnected = false;

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
    _player = Player();
    _videoController = VideoController(_player);
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

  Future<void> _toggleFullScreen() async {
    bool isFS = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFS);

    print("Pressed Going to Fullscreen");

    if (mounted) {
      setState(() {
        _isFullScreen = !isFS;
      });
    }
  }

  void _initPlayer() {
    _completedSub = _player.stream.completed.listen((completed) async {
      if (!mounted || !completed) return;
      if (_currentPlaylistIndex < _playlist.length - 1) {
        await _playIndex(_currentPlaylistIndex + 1);
      }
    });
  }

  void _initClient() {
    _client = ClientService(hostAddress: widget.hostAddress, port: widget.port);

    _client.onConnected = () {
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

  void _handleQueueUpdate(Map<String, dynamic> data) {
    setState(() {
      window1Ticket = data['window1'] ?? '---';
      window2Ticket = data['window2'] ?? '---';
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
    final paths = data['paths'];
    if (paths is! List) return;
    final rawPaths = List<String>.from(paths);
    if (rawPaths.isEmpty) return;
    _playlist = rawPaths.map((p) => _toMediaUri(p)).toList();
    _currentPlaylistIndex = 0;
    if (_playlist.isNotEmpty) {
      final medias = _playlist.map((p) => Media(p)).toList();
      _player.open(Playlist(medias)).then((_) => _player.play());
    }
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
    _completedSub?.cancel();
    _client.disconnect();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: _WindowDisplayCard(
                              title: 'Window 2',
                              ticket: window2Ticket,
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
                                : ListView.builder(
                                    itemCount: nextQueue.length,
                                    itemBuilder: (context, index) {
                                      final item = nextQueue[index];
                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8.0,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Text(
                                              '${index + 1}',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
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
                                                  fontWeight: FontWeight.w900,
                                                  color: Colors.black87,
                                                  letterSpacing: 1.0,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFF1F5F9),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                item['status'] ?? 'Ready',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.black54,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          const SizedBox(height: 8),
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
              padding: const EdgeInsets.only(left: 10, right: 10, top: 0, bottom: 10),
              child: Align(
                alignment: Alignment.center,
                child: FractionallySizedBox(
                  // widthFactor: 0.98,
                  child: Container(
                    height: 64,
                    padding: const EdgeInsets.only(left: 10, right: 10, top: 10, bottom: 10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1E3A8A), Color.fromARGB(255, 2, 4, 10)],
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
                        SizedBox(width: 12,),
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

  const _WindowDisplayCard({required this.title, required this.ticket});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFCBD5E1),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  ticket,
                  style: const TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF4338CA),
                    letterSpacing: 2.0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
