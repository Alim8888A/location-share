import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/location_service.dart';
import '../services/socket_service.dart';
import 'map_screen.dart';

/// 主页：创建共享 / 加入共享
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.name, required this.server});

  final String name;
  final String server;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _roomCtrl = TextEditingController();
  bool _joining = false;

  Future<void> _enterRoom(String room) async {
    if (_joining) return;
    setState(() => _joining = true);
    final ok = await LocationService.ensurePermissions();
    if (!ok && mounted) {
      setState(() => _joining = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('需要定位权限才能共享位置，请在系统设置中开启')));
      return;
    }
    final socket = SocketService.instance;
    try {
      await socket.connectAndJoin(
          serverUrl: widget.server, roomCode: room, name: widget.name);
    } catch (_) {}
    // 等待 joined 确认
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!socket.joined && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    setState(() => _joining = false);
    if (!socket.joined) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(socket.lastError ?? '连接服务器失败，请检查地址与网络')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MapScreen(roomCode: room)),
    );
  }

  void _createRoom() {
    final code = generateRoomCode();
    _roomCtrl.text = code;
    _enterRoom(code);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('你好，${widget.name}'),
            Text(widget.server,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              _ActionCard(
                icon: Icons.add_location_alt_rounded,
                title: '创建共享',
                subtitle: '生成房间码，发给想共享位置的人（支持2人及以上）',
                color: cs.primary,
                onTap: _createRoom,
              ),
              const SizedBox(height: 16),
              _ActionCard(
                icon: Icons.group_rounded,
                title: '加入共享',
                subtitle: '输入对方给你的房间码加入',
                color: cs.tertiary,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _roomCtrl,
                          textCapitalization: TextCapitalization.characters,
                          maxLength: 8,
                          decoration: InputDecoration(
                            labelText: '房间码',
                            counterText: '',
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onSubmitted: (v) {
                            if (v.trim().length >= 4) _enterRoom(v);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: () {
                          if (_roomCtrl.text.trim().length >= 4) {
                            _enterRoom(_roomCtrl.text);
                          }
                        },
                        child: const Text('加入'),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '同一房间内的所有成员可互相看到实时位置，并可发起群组语音通话。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.child,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final Widget? child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 30),
                  const SizedBox(width: 12),
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 6),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
              if (child != null) child!,
            ],
          ),
        ),
      ),
    );
  }
}

class ClipboardCopyButton extends StatelessWidget {
  const ClipboardCopyButton({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.copy_rounded, size: 20),
      onPressed: () {
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已复制：$text'), duration: const Duration(seconds: 1)));
      },
    );
  }
}
