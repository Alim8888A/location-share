import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nameCtrl = TextEditingController();
  final _serverCtrl = TextEditingController(text: 'ws://192.168.1.100:8888');
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final sp = await SharedPreferences.getInstance();
    setState(() {
      _nameCtrl.text = sp.getString('name') ?? '';
      _serverCtrl.text = sp.getString('server') ?? 'ws://192.168.1.100:8888';
      _loading = false;
    });
  }

  Future<void> _go() async {
    final name = _nameCtrl.text.trim();
    final server = _serverCtrl.text.trim();
    if (name.isEmpty) {
      _toast('请输入昵称');
      return;
    }
    if (server.isEmpty) {
      _toast('请输入服务器地址');
      return;
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString('name', name);
    await sp.setString('server', server);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeScreen(name: name, server: server)),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primaryContainer, cs.surface],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: _loading
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(Icons.location_on_rounded,
                            size: 72, color: cs.primary),
                        const SizedBox(height: 8),
                        Text('位置共享',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .headlineLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('与家人朋友实时共享位置 · 随时语音通话',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 36),
                        TextField(
                          controller: _nameCtrl,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: '你的昵称',
                            prefixIcon: const Icon(Icons.person_rounded),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _serverCtrl,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(
                            labelText: '服务器地址',
                            hintText: 'ws://192.168.1.100:8888',
                            prefixIcon: const Icon(Icons.dns_rounded),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                        const SizedBox(height: 28),
                        FilledButton.icon(
                          onPressed: _go,
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text('进入', style: TextStyle(fontSize: 16)),
                          ),
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
