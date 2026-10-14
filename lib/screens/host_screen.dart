import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/server_service.dart';
import '../services/video_stream_service.dart';
import 'menu_screen.dart';

class HostScreen extends StatefulWidget {
  final int port;

  const HostScreen({super.key, required this.port});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  late final ServerService _server;
  final VideoStreamService _videoStream = VideoStreamService();
  int _selectedTab = 0;
  List<String> _selectedVideos = [];
  double _videoVolume = 100;
  String _hostAddress = '127.0.0.1';

  // Ticket queue
  int _ticketStart = 100;
  int _ticketEnd = 120;
  int _nextTicket = 100;

  // Window tracking: window name -> current ticket (or '---')
  final List<String> _windows = ['Window 1', 'Window 2'];
  final Map<String, String> _windowTickets = {};
  final Map<Socket, String> _tellerWindows = {};

  @override
  void initState() {
    super.initState();
    for (final w in _windows) {
      _windowTickets[w] = '---';
    }
    _server = ServerService(port: widget.port);
    _server.onMessage = _handleClientMessage;
    _server.onClientDisconnect = _handleClientDisconnect;
    _initializeHost();
  }

  Future<void> _initializeHost() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _selectedVideos = preferences.getStringList('selected_video_paths') ?? [];
      _selectedVideos = _selectedVideos
          .where((path) => File(path).existsSync())
          .toList();
      _videoVolume = (preferences.getDouble('video_volume') ?? 100)
          .clamp(0, 100)
          .toDouble();
      _videoStream.setPaths(_selectedVideos);
      await _videoStream.start();
      _hostAddress = await _server.getHostAddress();
      await _server.start();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Failed to initialize host: $e');
      await _server.stop();
      await _videoStream.stop();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to start host: $e')));
      }
    }
  }

  List<String> get _videoUrls => _videoStream.getUrls(_hostAddress);

  void _sendVideoToMonitor(Socket monitor) {
    _server.sendTo(monitor, 'set_video_volume', {'volume': _videoVolume});
    if (_videoUrls.isNotEmpty) {
      _server.sendTo(monitor, 'play_video_list', {'urls': _videoUrls});
    }
  }

  void _broadcastVideoSelection() {
    _videoStream.setPaths(_selectedVideos);
    final urls = _videoUrls;
    if (urls.isNotEmpty) {
      _server.broadcast('play_video_list', {'urls': urls}, toRole: 'monitor');
    }
  }

  Future<void> _saveSelectedVideoPaths() async {
    try {
      final saved = await (await SharedPreferences.getInstance()).setStringList(
        'selected_video_paths',
        _selectedVideos,
      );
      if (!saved) throw StateError('Video paths could not be saved.');
    } catch (error) {
      debugPrint('Failed to save selected video paths: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save selected videos: $error')),
        );
      }
    }
  }

  Future<void> _saveVideoVolume() async {
    try {
      final saved = await (await SharedPreferences.getInstance()).setDouble(
        'video_volume',
        _videoVolume,
      );
      if (!saved) throw StateError('Video volume could not be saved.');
    } catch (error) {
      debugPrint('Failed to save video volume: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save video volume: $error')),
        );
      }
    }
  }

  void _setVideoVolume(double volume, {bool save = false}) {
    setState(() => _videoVolume = volume);
    _server.broadcast('set_video_volume', {
      'volume': _videoVolume,
    }, toRole: 'monitor');
    if (save) _saveVideoVolume();
  }

  List<String> _getOccupiedWindows() => _tellerWindows.values.toList();

  List<String> _getAvailableWindows() =>
      _windows.where((w) => !_tellerWindows.containsValue(w)).toList();

  void _handleClientMessage(
    String type,
    Map<String, dynamic> data,
    Socket sender,
  ) {
    switch (type) {
      case 'register':
        _handleRegister(data, sender);
        break;
      case 'select_window':
        _handleSelectWindow(data, sender);
        break;
      case 'call_next_ticket':
        _handleCallNext(data, sender);
        break;
      case 'call_current_ticket':
        _handleCallCurrent(data, sender);
        break;
    }
  }

  void _handleRegister(Map<String, dynamic> data, Socket sender) {
    final role = data['role'] as String? ?? '';
    if (role == 'teller') {
      _server.sendTo(sender, 'available_windows', {
        'available': _getAvailableWindows(),
        'occupied': _getOccupiedWindows(),
      });
    } else if (role == 'monitor') {
      _sendVideoToMonitor(sender);
    }
  }

  void _handleSelectWindow(Map<String, dynamic> data, Socket sender) {
    final window = data['window'] as String? ?? '';
    if (window.isEmpty || !_windows.contains(window)) return;
    if (_tellerWindows.containsValue(window)) {
      _server.sendTo(sender, 'window_taken', {
        'available': _getAvailableWindows(),
        'occupied': _getOccupiedWindows(),
      });
      return;
    }
    _tellerWindows[sender] = window;
    _server.sendTo(sender, 'window_assigned', {'window': window});
    debugPrint('Teller assigned to $window');
    if (mounted) setState(() {});
  }

  void _handleCallNext(Map<String, dynamic> data, Socket sender) {
    final window = _tellerWindows[sender];
    if (window == null) return;
    if (_nextTicket > _ticketEnd) return;

    final ticket = 'A-$_nextTicket';
    _nextTicket++;

    _windowTickets[window] = ticket;

    _broadcastTicketCall(ticket, window);

    _broadcastQueue(calledWindow: window);
    if (mounted) setState(() {});
  }

  void _handleCallCurrent(Map<String, dynamic> data, Socket sender) {
    final window = _tellerWindows[sender];
    if (window == null) return;
    final ticket = _windowTickets[window];
    if (ticket == null || ticket == '---') return;

    _broadcastTicketCall(ticket, window);

    _broadcastQueue(calledWindow: window);
    if (mounted) setState(() {});
  }

  void _broadcastTicketCall(String ticket, String window) {
    final call = {'ticket': ticket, 'window': window};
    _server.broadcast('ticket_assigned', call, toRole: 'teller');
    _server.broadcast('ticket_called', call, toRole: 'monitor');
  }

  void _handleClientDisconnect(Socket socket, String role) {
    if (role == 'teller') {
      _tellerWindows.remove(socket);
      debugPrint('Teller disconnected, window freed');
      if (mounted) setState(() {});
    }
  }

  void _broadcastQueue({String? calledWindow}) {
    final data = <String, dynamic>{
      'pendingCount': _ticketEnd - _nextTicket + 1,
      'nextUp': List.generate(
        5,
        (i) => _nextTicket + i <= _ticketEnd ? 'A-${_nextTicket + i}' : '---',
      ),
      'windows': _windows
          .map((w) => {'name': w, 'ticket': _windowTickets[w] ?? '---'})
          .toList(),
    };
    if (calledWindow != null) {
      data['calledWindow'] = calledWindow;
    }
    _server.broadcast('queue_update', data);
  }

  void _updateTicketRange() {
    _nextTicket = _ticketStart;
    for (final w in _windows) {
      _windowTickets[w] = '---';
    }
    setState(() {});
    _broadcastQueue();
  }

  Future<void> _selectVideoFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );
      if (result == null) return;
      final path = result.files.single.path;
      if (path == null) return;
      setState(() {
        _selectedVideos = [path];
      });
      await _saveSelectedVideoPaths();
      _broadcastVideoSelection();
    } catch (error) {
      debugPrint('Error selecting video file: $error');
    }
  }

  Future<void> _selectVideoDirectory() async {
    try {
      final directoryPath = await FilePicker.platform.getDirectoryPath();
      if (directoryPath == null) return;
      final dir = Directory(directoryPath);
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) {
            final ext = f.path.toLowerCase();
            return ext.endsWith('.mp4') ||
                ext.endsWith('.mov') ||
                ext.endsWith('.mkv') ||
                ext.endsWith('.webm');
          })
          .map((f) => f.path)
          .toList();
      if (files.isEmpty) return;
      setState(() {
        _selectedVideos = files;
      });
      await _saveSelectedVideoPaths();
      _broadcastVideoSelection();
    } catch (error) {
      debugPrint('Error selecting video directory: $error');
    }
  }

  @override
  void dispose() {
    _server.stop();
    _videoStream.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: Row(
        children: [
          _buildSidebar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: IndexedStack(
                index: _selectedTab,
                children: [_buildTellerControl(), _buildMonitorManager()],
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
          width: 240,
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(
                    Icons.confirmation_num_rounded,
                    color: Colors.indigo,
                    size: 28,
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Queue System',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.indigo.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'HOST - $_hostAddress:${widget.port}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.indigo,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              _SidebarButton(
                icon: Icons.point_of_sale_rounded,
                label: 'Teller Control',
                isSelected: _selectedTab == 0,
                onTap: () => setState(() => _selectedTab = 0),
              ),
              const SizedBox(height: 8),
              _SidebarButton(
                icon: Icons.tv_rounded,
                label: 'Monitor Manager',
                isSelected: _selectedTab == 1,
                onTap: () => setState(() => _selectedTab = 1),
              ),
              const Spacer(),
              const Divider(),
              // Window assignments
              if (_tellerWindows.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Window Assignments',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.blue[700],
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final entry in _tellerWindows.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            '${entry.value} → ${entry.key.remoteAddress.address}',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _server.isRunning
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _server.isRunning ? Icons.wifi : Icons.wifi_off,
                      size: 18,
                      color: _server.isRunning ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _server.isRunning
                            ? '${_server.tellerCount} teller(s) · ${_server.monitorCount} monitor(s)'
                            : 'Server offline',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _server.isRunning ? Colors.green : Colors.red,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    _server.stop();
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

  Widget _buildTellerControl() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ticket Management',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _server.isRunning
                  ? 'Server active - ${_server.tellerCount} teller(s), ${_server.monitorCount} monitor(s)'
                  : 'Server is starting...',
              style: TextStyle(
                color: _server.isRunning ? Colors.green : Colors.orange,
              ),
            ),
            const Divider(height: 40),
            // Ticket range
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Ticket Range',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Start',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                TextField(
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  controller: TextEditingController(
                                    text: _ticketStart.toString(),
                                  ),
                                  onChanged: (v) {
                                    _ticketStart = int.tryParse(v) ?? 100;
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Padding(
                            padding: EdgeInsets.only(top: 16),
                            child: Text(
                              'to',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'End',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                TextField(
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  controller: TextEditingController(
                                    text: _ticketEnd.toString(),
                                  ),
                                  onChanged: (v) {
                                    _ticketEnd = int.tryParse(v) ?? 120;
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: ElevatedButton(
                              onPressed: _updateTicketRange,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.indigo,
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('Apply'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Window status grid
            const Text(
              'Window Status',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),
            ..._windows.map(
              (w) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.laptop_mac_rounded,
                        color: _windowTickets[w] != '---'
                            ? Colors.indigo
                            : Colors.grey[400],
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        w,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _windowTickets[w] ?? '---',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _windowTickets[w] != '---'
                              ? Colors.indigo
                              : Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            // Next ticket + call button
            Center(
              child: Column(
                children: [
                  Text(
                    'Remaining: ${(_ticketEnd - _nextTicket + 1).clamp(0, 999)}',
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Next: ${_nextTicket <= _ticketEnd ? 'A-$_nextTicket' : 'DONE'}',
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonitorManager() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Video Management',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _selectVideoFile,
                    icon: const Icon(Icons.video_file),
                    label: const Text('Select Video File'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _selectVideoDirectory,
                    icon: const Icon(Icons.folder),
                    label: const Text('Select Video Folder'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.volume_up_rounded, color: Colors.indigo),
                const SizedBox(width: 8),
                const Text(
                  'Client video volume',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Expanded(
                  child: Slider(
                    value: _videoVolume,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    label: '${_videoVolume.round()}%',
                    onChanged: (value) => _setVideoVolume(value),
                    onChangeEnd: (value) => _setVideoVolume(value, save: true),
                  ),
                ),
                SizedBox(width: 44, child: Text('${_videoVolume.round()}%')),
              ],
            ),
            if (_selectedVideos.isNotEmpty) ...[
              const Text(
                'Selected Videos',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _selectedVideos.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          backgroundColor: Colors.indigo.shade100,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.indigo,
                            ),
                          ),
                        ),
                        title: Text(
                          _selectedVideos[index].split(RegExp(r'[/\\]')).last,
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ] else ...[
              const Expanded(
                child: Center(
                  child: Text(
                    'No videos selected',
                    style: TextStyle(color: Colors.black45, fontSize: 14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.indigo.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? Colors.indigo : Colors.grey[600]),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.indigo : Colors.grey[800],
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
