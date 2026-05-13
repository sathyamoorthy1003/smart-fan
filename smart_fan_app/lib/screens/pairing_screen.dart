import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dashboard_screen.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _codeController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _pair() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _error = 'Enter a device code');
      return;
    }
    setState(() { _loading = true; _error = null; });

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final query = await FirebaseFirestore.instance
          .collection('devices')
          .where('pairingCode', isEqualTo: code)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        setState(() { _error = 'Invalid code or device already paired'; _loading = false; });
        return;
      }

      final doc = query.docs.first;
      await doc.reference.update({
        'ownerId': uid,
        'paired': true,
        'pairedAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardScreen(deviceId: doc.id),
          ),
        );
      }
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;

    // Adaptive colors
    final bgColor       = isDark ? const Color(0xFF080C18) : const Color(0xFFF1F5F9);
    final cardBg        = isDark ? const Color(0xFF1A2035) : const Color(0xFFFFFFFF);
    final cardBorder    = isDark ? accent.withAlpha(80) : const Color(0xFF94A3B8);
    final titleColor    = isDark ? Colors.white : const Color(0xFF1E293B);
    final subtitleColor = isDark ? Colors.white54 : const Color(0xFF64748B);
    final hintColor     = isDark ? Colors.white24 : const Color(0xFF94A3B8);
    final inputText     = isDark ? Colors.white : const Color(0xFF1E293B);
    final footerColor   = isDark ? Colors.white30 : const Color(0xFF94A3B8);

    return Scaffold(
      backgroundColor: bgColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon
              Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [accent, accent.withAlpha(100)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(color: accent.withAlpha(80), blurRadius: 30, spreadRadius: 5),
                  ],
                ),
                child: const Icon(Icons.air, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 24),
              Text('Smart Fan', style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold, color: accent,
                letterSpacing: 1.5,
              )),
              const SizedBox(height: 8),
              Text('Connect your device', style: TextStyle(
                fontSize: 14, color: subtitleColor,
              )),
              const SizedBox(height: 40),
              // Code input
              Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cardBorder),
                  boxShadow: isDark ? [] : [
                    BoxShadow(color: const Color(0xFF94A3B8).withAlpha(40), blurRadius: 8, offset: const Offset(0, 2)),
                  ],
                ),
                child: TextField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold,
                    color: inputText,
                  ),
                  decoration: InputDecoration(
                    hintText: 'DEVICE CODE',
                    hintStyle: TextStyle(
                      fontSize: 16, letterSpacing: 4,
                      color: hintColor,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ],
              const SizedBox(height: 24),
              // Pair button
              SizedBox(
                width: double.infinity, height: 56,
                child: ElevatedButton(
                  onPressed: _loading ? null : _pair,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 8,
                    shadowColor: accent.withAlpha(100),
                  ),
                  child: _loading
                      ? const SizedBox(width: 24, height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('PAIR DEVICE', style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Enter the 6-character code\nshown on your Smart Fan display',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: footerColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
