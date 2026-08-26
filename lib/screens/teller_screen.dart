import 'dart:async';
// import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/client_service.dart';
import 'menu_screen.dart';

class TellerScreen extends StatefulWidget {
  final String hostAddress;
  final int port;

  const TellerScreen({
    super.key,
    required this.hostAddress,
    required this.port,
  });

  @override
  State<TellerScreen> createState() => _TellerScreenState();
}

class _TellerScreenState extends State<TellerScreen> {
  late final ClientService _client;
  final AudioPlayer _audioPlayer = AudioPlayer();
  Timer? _reconnectTimer;
  bool _connected = false;

  // Window assignment
  bool _windowAssigned = false;
  String _selectedWindow = '';
  List<String> _availableWindows = [];
  bool _showWindowPicker = false;

  // Ticket state
  String _currentTicket = '---';

  // Sound
  String? _selectedSoundPath;

  // Queue state
  int _pendingCount = 0;
  List<String> _nextUp = [];
  final Map<String, String> _windowTickets = {};

  @override
  void initState() {
    super.initState();
    _client = ClientService(hostAddress: widget.hostAddress, port: widget.port);
    _client.onConnected = () {
      setState(() => _connected = true);
      _client.send('register', {'role': 'teller'});
    };
    _client.onDisconnected = () {
      setState(() {
        _connected = false;
        _windowAssigned = false;
        _selectedWindow = '';
        _currentTicket = '---';
        _pendingCount = 0;
        _nextUp = [];
        _windowTickets.clear();
        _showWindowPicker = false;
      });
      _scheduleReconnect();
    };
    _client.onMessage = _handleMessage;
    _connect();
  }

  void _handleMessage(String type, Map<String, dynamic> data) {
    if (!mounted) return;
    switch (type) {
      case 'registered':
        // Host will send available_windows next
        break;
      case 'available_windows':
        final available = List<String>.from(
            (data['available'] as List? ?? []).map((e) => e.toString()));
        setState(() {
          _availableWindows = available;
          _showWindowPicker = true;
        });
        break;
      case 'window_assigned':
        setState(() {
          _selectedWindow = data['window'] as String? ?? '';
          _windowAssigned = true;
          _showWindowPicker = false;
        });
        break;
      case 'window_taken':
        final available = List<String>.from(
            (data['available'] as List? ?? []).map((e) => e.toString()));
        setState(() {
          _availableWindows = available;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('That window is already taken. Pick another.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        break;
      case 'ticket_assigned':
        setState(() {
          _currentTicket = data['ticket'] as String? ?? '---';
        });
        break;
      case 'queue_update':
        setState(() {
          _pendingCount = data['pendingCount'] as int? ??
              int.tryParse(data['pendingCount'].toString()) ??
              _pendingCount;
          if (data['nextUp'] is List) {
            _nextUp = List<String>.from(
                (data['nextUp'] as List).map((e) => e.toString()));
          }
          if (data['windows'] is List) {
            _windowTickets.clear();
            for (final w in data['windows'] as List) {
              final name = w['name'] as String? ?? '';
              final ticket = w['ticket'] as String? ?? '---';
              if (name.isNotEmpty) _windowTickets[name] = ticket;
            }
          }
        });
        break;
    }
  }

  Future<void> _connect() async {
    try {
      await _client.connect();
    } catch (e) {
      debugPrint('Failed to connect: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_connected && mounted) {
        debugPrint('Attempting reconnect...');
        _connect();
      }
    });
  }

  void _selectWindow(String window) {
    _client.send('select_window', {'window': window});
  }

  void _callNext() {
    if (!_connected || !_windowAssigned) return;
    _playChime();
    _client.send('call_next_ticket', {
      'window': _selectedWindow,
    });
  }

  void _callCurrent() {
    if (!_connected || !_windowAssigned || _currentTicket == '---') return;
    _playChime();
    _client.send('call_current_ticket', {
      'window': _selectedWindow,
      'ticket': _currentTicket,
    });
  }

  Future<void> _playChime() async {
    if (_selectedSoundPath == null || _selectedSoundPath!.isEmpty) return;
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(_selectedSoundPath!));
    } catch (e) {
      debugPrint('Error playing chime: $e');
    }
  }

  Future<void> _selectSoundFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (result == null) return;
      final path = result.files.single.path;
      if (path == null) return;
      setState(() {
        _selectedSoundPath = path;
      });
    } catch (e) {
      debugPrint('Error selecting sound file: $e');
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _audioPlayer.dispose();
    _client.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showWindowPicker) {
      return _buildWindowPickerScreen();
    }
    if (!_windowAssigned) {
      return _buildWaitingScreen();
    }
    return _buildMainScreen();
  }

  Widget _buildWindowPickerScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: Center(
        child: Container(
          width: 500,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.laptop_mac_rounded,
                size: 56,
                color: Colors.indigo,
              ),
              const SizedBox(height: 16),
              const Text(
                'Select Your Window',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Choose which window you are assigned to',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 32),
              if (_availableWindows.isEmpty)
                const Text(
                  'All windows are occupied',
                  style: TextStyle(color: Colors.red, fontSize: 16),
                )
              else
                ..._availableWindows.map((w) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton.icon(
                          onPressed: () => _selectWindow(w),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.indigo,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          icon: const Icon(Icons.laptop_mac_rounded, size: 24),
                          label: Text(
                            w,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    )),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    _client.disconnect();
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const MenuScreen()),
                    );
                  },
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Back to Menu'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.indigo),
            const SizedBox(height: 20),
            Text(
              _connected ? 'Waiting for host...' : 'Connecting...',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: Row(
        children: [
          _buildSidebar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Connection + window pills
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: _connected
                                ? Colors.green.withValues(alpha: 0.1)
                                : Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _connected ? Icons.wifi : Icons.wifi_off,
                                size: 16,
                                color: _connected ? Colors.green : Colors.red,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _connected ? 'ONLINE' : 'OFFLINE',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color:
                                      _connected ? Colors.green : Colors.red,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.indigo.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _selectedWindow,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.indigo,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Currently serving label
                    const Text(
                      'Currently Serving',
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),

                    // Big ticket display
                    Text(
                      _currentTicket,
                      style: const TextStyle(
                        fontSize: 96,
                        fontWeight: FontWeight.bold,
                        color: Colors.indigo,
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Action buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 240,
                          height: 56,
                          child: ElevatedButton.icon(
                            onPressed: _connected ? _callNext : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.indigo,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.grey.shade300,
                              disabledForegroundColor: Colors.grey.shade500,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: const Icon(Icons.notifications_active,
                                size: 24),
                            label: const Text(
                              'CALL NEXT',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 260,
                          height: 56,
                          child: ElevatedButton.icon(
                            onPressed: _connected && _currentTicket != '---'
                                ? _callCurrent
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF059669),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.grey.shade300,
                              disabledForegroundColor: Colors.grey.shade500,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon:
                                const Icon(Icons.volume_up_rounded, size: 24),
                            label: const Text(
                              'CALL CURRENT',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Sound selector
                    InkWell(
                      onTap: _selectSoundFile,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: _selectedSoundPath != null
                              ? Colors.green.withValues(alpha: 0.08)
                              : Colors.orange.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _selectedSoundPath != null
                                ? Colors.green.withValues(alpha: 0.3)
                                : Colors.orange.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _selectedSoundPath != null
                                  ? Icons.music_note
                                  : Icons.music_off,
                              size: 18,
                              color: _selectedSoundPath != null
                                  ? Colors.green[700]
                                  : Colors.orange[700],
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _selectedSoundPath != null
                                  ? 'Chime: ${_selectedSoundPath!.split(RegExp(r'[/\\]')).last}'
                                  : 'Select Chime Sound',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _selectedSoundPath != null
                                    ? Colors.green[700]
                                    : Colors.orange[700],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 40),

                    // Queue info
                    Container(
                      width: 500,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _QueueStat(
                                label: 'Pending',
                                value: '$_pendingCount',
                                color: Colors.orange,
                              ),
                              for (final w in _windowTickets.entries)
                                _QueueStat(
                                  label: w.key,
                                  value: w.value,
                                  color: Colors.indigo,
                                ),
                            ],
                          ),
                          if (_nextUp.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Next in line',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: _nextUp
                                  .where((t) => t != '---')
                                  .map((t) => Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFEEF2FF),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          t,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.indigo,
                                          ),
                                        ),
                                      ))
                                  .toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        child: Container(
          width: 220,
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.confirmation_num_rounded,
                      color: Colors.indigo, size: 28),
                  SizedBox(width: 12),
                  Text(
                    'Queue System',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'TELLER · $_selectedWindow',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _connected
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _connected ? Icons.wifi : Icons.wifi_off,
                      size: 18,
                      color: _connected ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _connected ? 'Connected to host' : 'Disconnected',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _connected ? Colors.green : Colors.red,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              const Divider(),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    _client.disconnect();
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const MenuScreen()),
                    );
                  },
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Back to Menu'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _QueueStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey[500],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}
