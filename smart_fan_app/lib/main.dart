import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'screens/pairing_screen.dart';
import 'screens/dashboard_screen.dart';

// ─── Global mode notifier — DashboardScreen writes, MaterialApp reads ─────────
final ValueNotifier<String> fanModeNotifier = ValueNotifier<String>('AUTO');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const SmartFanApp());
}

// ─── App root — listens to fanModeNotifier and switches theme ─────────────────
class SmartFanApp extends StatefulWidget {
  const SmartFanApp({super.key});
  @override
  State<SmartFanApp> createState() => _SmartFanAppState();
}

class _SmartFanAppState extends State<SmartFanApp> {
  @override
  void initState() {
    super.initState();
    fanModeNotifier.addListener(_onModeChange);
  }

  @override
  void dispose() {
    fanModeNotifier.removeListener(_onModeChange);
    super.dispose();
  }

  void _onModeChange() => setState(() {});

  ThemeData _darkTheme() => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF080C18),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFFF6B00),
      secondary: Color(0xFF00E5FF),
      surface: Color(0xFF111827),
    ),
    fontFamily: 'Roboto',
    useMaterial3: true,
  );

  ThemeData _lightTheme() => ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF1F5F9),
    colorScheme: const ColorScheme.light(
      primary: Color(0xFFFF6B00),
      secondary: Color(0xFF06B6D4),
      surface: Color(0xFFFFFFFF),
    ),
    fontFamily: 'Roboto',
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) {
    final isNight = fanModeNotifier.value == 'NIGHT';
    return MaterialApp(
      title: 'Smart Fan',
      debugShowCheckedModeBanner: false,
      theme: isNight ? _darkTheme() : _lightTheme(),
      home: const AuthGate(),
    );
  }
}

// ─── Auth Gate — checks cached user first, streams as fallback ───────────────
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // If already signed in from a previous session, go straight to router
  bool get _alreadySignedIn => FirebaseAuth.instance.currentUser != null;
  bool _signingIn = false;

  @override
  void initState() {
    super.initState();
    if (!_alreadySignedIn) {
      _doSignIn();
    }
  }

  Future<void> _doSignIn() async {
    setState(() => _signingIn = true);
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
    if (mounted) setState(() => _signingIn = false);
  }

  @override
  Widget build(BuildContext context) {
    // Already signed in — go straight to router, no loading needed
    if (_alreadySignedIn) return const DeviceRouter();

    // Signing in — show splash, then route when done
    if (_signingIn) {
      final theme = Theme.of(context);
      final isDark = theme.brightness == Brightness.dark;
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72, height: 72,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFFF6B00),
                ),
                child: const Icon(Icons.air, color: Colors.white, size: 36),
              ),
              const SizedBox(height: 24),
              Text('SMART FAN', style: TextStyle(
                color: isDark ? Colors.white : const Color(0xFF1E293B),
                fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 3,
              )),
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: Color(0xFFFF6B00), strokeWidth: 2),
              const SizedBox(height: 16),
              Text('Signing in...', style: TextStyle(
                color: isDark ? Colors.white54 : const Color(0xFF64748B),
                fontSize: 13,
              )),
            ],
          ),
        ),
      );
    }

    // Sign-in done (success or fail) — go to router (will show pairing if no user)
    return const DeviceRouter();
  }
}

// ─── Device Router ────────────────────────────────────────────────────────────
class DeviceRouter extends StatefulWidget {
  const DeviceRouter({super.key});
  @override
  State<DeviceRouter> createState() => _DeviceRouterState();
}

class _DeviceRouterState extends State<DeviceRouter> {
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted && !_timedOut) setState(() => _timedOut = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white54 : const Color(0xFF64748B);
    final titleColor = isDark ? Colors.white : const Color(0xFF1E293B);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const PairingScreen();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('devices')
          .where('ownerId', isEqualTo: user.uid)
          .where('paired', isEqualTo: true)
          .limit(1)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          return DashboardScreen(deviceId: snapshot.data!.docs.first.id);
        }
        if (snapshot.hasError ||
            (snapshot.hasData && snapshot.data!.docs.isEmpty)) {
          return const PairingScreen();
        }
        if (_timedOut) {
          return Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off, color: Colors.redAccent, size: 52),
                    const SizedBox(height: 16),
                    Text('No Internet Connection',
                        style: TextStyle(color: titleColor, fontSize: 17,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('Connect to WiFi or mobile data and try again.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: textColor, fontSize: 12)),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => setState(() => _timedOut = false),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF6B00)),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        // Loading
        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF6B00), Color(0xFFFF9A3C)],
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                    ),
                    boxShadow: [BoxShadow(
                        color: const Color(0xFFFF6B00).withAlpha(80),
                        blurRadius: 20)],
                  ),
                  child: const Icon(Icons.air, color: Colors.white, size: 36),
                ),
                const SizedBox(height: 24),
                Text('SMART FAN', style: TextStyle(
                  color: titleColor, fontSize: 18,
                  fontWeight: FontWeight.w800, letterSpacing: 3,
                )),
                const SizedBox(height: 24),
                const CircularProgressIndicator(
                    color: Color(0xFFFF6B00), strokeWidth: 2),
                const SizedBox(height: 16),
                Text('Loading device...', style: TextStyle(
                    color: textColor, fontSize: 13)),
              ],
            ),
          ),
        );
      },
    );
  }
}
