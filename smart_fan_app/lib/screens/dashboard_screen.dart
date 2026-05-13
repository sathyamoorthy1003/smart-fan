import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'pairing_screen.dart';
import '../main.dart' show fanModeNotifier;

class DashboardScreen extends StatefulWidget {
  final String deviceId;
  const DashboardScreen({super.key, required this.deviceId});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  // ── Colors (dynamic: NIGHT=dark, others=light) ───────────────────────────
  bool get _isNight => _mode == 'NIGHT';
  Color get _bg     => _isNight ? const Color(0xFF080C18) : const Color(0xFFF1F5F9);
  Color get _card   => _isNight ? const Color(0xFF111827) : const Color(0xFFFFFFFF);
  Color get _border => _isNight ? const Color(0xFF1E293B) : const Color(0xFF94A3B8);
  Color get _dim    => _isNight ? const Color(0xFF64748B) : const Color(0xFF475569);
  Color get _text   => _isNight ? Colors.white : const Color(0xFF1E293B);
  List<BoxShadow> get _cardShadow => _isNight
      ? []
      : [BoxShadow(color: const Color(0xFF94A3B8).withAlpha(40), blurRadius: 8, offset: const Offset(0, 2))];
  // ── Accent colors (same across themes) ────────────────────────────────────
  static const _accent  = Color(0xFFFF6B00);
  static const _green   = Color(0xFF10B981);
  static const _red     = Color(0xFFEF4444);
  static const _cyan    = Color(0xFF06B6D4);
  static const _yellow  = Color(0xFFF59E0B);
  static const _purple  = Color(0xFF8B5CF6);
  static const _blue    = Color(0xFF3B82F6);
  static const _teal    = Color(0xFF14B8A6);

  // ── State ─────────────────────────────────────────────────────────────────
  String _mode       = 'AUTO';
  bool   _fanRunning = false;
  double _temp       = 0;
  int    _speed      = 0;
  String _mist       = 'OFF';
  bool   _lightOn    = false;
  bool   _swingMode  = false;
  String _direction  = 'CENTER';
  bool   _pirL = false, _pirC = false, _pirR = false;
  int    _uptime     = 0;
  bool   _online     = false;
  String? _cmdError;

  // Local-only: tracks which direction endpoints are selected for manual swing
  final Set<String> _selectedDirs = {};

  StreamSubscription<DocumentSnapshot>? _sub;
  late AnimationController _pulseCtrl;
  late AnimationController _fanCtrl;
  bool _cmdInProgress = false;

  DocumentReference get _ref =>
      FirebaseFirestore.instance.collection('devices').doc(widget.deviceId);

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _fanCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat();

    _sub = _ref.snapshots().listen(
      (snap) {
        if (!mounted || !snap.exists) return;
        final d = snap.data() as Map<String, dynamic>? ?? {};
        final s = (d['status'] as Map<String, dynamic>?) ?? {};
        if (!mounted) return;
        setState(() {
          _mode      = (s['mode'] as String?)       ?? 'AUTO';
          _fanRunning= (s['fanRunning'] as bool?)    ?? false;
          _temp      = (s['temperature'] as num?)?.toDouble() ?? 0.0;
          _speed     = (s['speed'] as num?)?.toInt() ?? 0;
          _mist      = (s['mistState'] as String?)   ?? 'OFF';
          _lightOn   = (s['lightOn'] as bool?)       ?? false;
          _swingMode = (s['swingMode'] as bool?)     ?? false;
          _direction = (s['direction'] as String?)   ?? 'CENTER';
          _pirL      = (s['pirL'] as bool?)          ?? false;
          _pirC      = (s['pirC'] as bool?)          ?? false;
          _pirR      = (s['pirR'] as bool?)          ?? false;
          _uptime    = (s['uptime'] as num?)?.toInt() ?? 0;
          _online    = true;
          // Clear swing selection when mode switches to AUTO
          if (_mode == 'AUTO') _selectedDirs.clear();
        });
        // Update global theme notifier
        fanModeNotifier.value = _mode;
      },
      onError: (e) {
        if (!mounted) return;
        setState(() { _online = false; });
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulseCtrl.dispose();
    _fanCtrl.dispose();
    super.dispose();
  }

  // ── Command helper ─────────────────────────────────────────────────────────
  Future<void> _cmd(String type) async {
    if (_cmdInProgress) return;
    if (!mounted) return;
    setState(() { _cmdInProgress = true; _cmdError = null; });
    try {
      await _ref.update({
        'command': {
          'type': type,
          'timestamp': FieldValue.serverTimestamp(),
          'processed': false,
        }
      });
    } catch (e) {
      if (mounted) setState(() => _cmdError = 'Command failed: $e');
    } finally {
      if (mounted) setState(() => _cmdInProgress = false);
    }
  }

  Future<void> _unpair() async {
    try {
      await _ref.update({'ownerId': FieldValue.delete(), 'paired': false});
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const PairingScreen()),
        (_) => false,
      );
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  Color _modeColor(String m) => switch (m) {
    'MANUAL' => _accent,
    'TRAVEL' => _blue,
    'OFFICE' => _teal,
    'NIGHT'  => _purple,
    _        => _green,
  };

  String _uptimeStr() {
    if (_uptime >= 3600) return '${_uptime ~/ 3600}h ${(_uptime % 3600) ~/ 60}m';
    if (_uptime >= 60)   return '${_uptime ~/ 60}m ${_uptime % 60}s';
    return '${_uptime}s';
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: CustomScrollView(
          physics: const ClampingScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 12),
                  _buildHeader(),
                  if (_cmdError != null) ...[
                    const SizedBox(height: 8),
                    _buildErrorBanner(),
                  ],
                  const SizedBox(height: 14),
                  _buildTempCard(),
                  const SizedBox(height: 12),
                  _buildStatsRow(),
                  const SizedBox(height: 12),
                  _buildFanStatus(),
                  const SizedBox(height: 12),
                  _buildPirSection(),
                  const SizedBox(height: 16),
                  _buildModeSelector(),
                  const SizedBox(height: 12),
                  _buildFanControl(),
                  const SizedBox(height: 12),
                  _buildSpeedControls(),
                  const SizedBox(height: 12),
                  _buildMistCard(),
                  const SizedBox(height: 12),
                  _buildLightCard(),
                  const SizedBox(height: 20),
                  _buildUnpairBtn(),
                  const SizedBox(height: 24),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
        boxShadow: _cardShadow,
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [_accent, _accent.withAlpha(160)]),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.air, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SMART FAN',
                style: TextStyle(color: _text, fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: 2)),
            Text('Device • ${widget.deviceId}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _dim, fontSize: 10)),
          ]),
        ),
        const SizedBox(width: 8),
        // Online indicator
        AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, __) => Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _online
                  ? Color.lerp(_green.withAlpha(128), _green, _pulseCtrl.value)!
                  : _red,
              boxShadow: [BoxShadow(
                color: (_online ? _green : _red).withAlpha(100),
                blurRadius: 8,
              )],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Mode badge
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: _modeColor(_mode).withAlpha(40),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _modeColor(_mode).withAlpha(120)),
          ),
          child: Text(_mode,
              style: TextStyle(
                  color: _modeColor(_mode),
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  letterSpacing: 1)),
        ),
      ]),
    );
  }

  // ── Error banner ──────────────────────────────────────────────────────────
  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _red.withAlpha(25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _red.withAlpha(80)),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, color: _red, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(_cmdError!, style: TextStyle(color: _red, fontSize: 11))),
        GestureDetector(
          onTap: () => setState(() => _cmdError = null),
          child: Icon(Icons.close, color: _red, size: 16),
        ),
      ]),
    );
  }

  // ── Temperature card ──────────────────────────────────────────────────────
  Widget _buildTempCard() {
    final tc = _temp >= 35 ? _red : _temp >= 30 ? _accent : _temp >= 25 ? _yellow : _cyan;
    final pct = ((_temp - 15).clamp(0, 30) / 30).toDouble();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
        boxShadow: _cardShadow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.thermostat, color: tc, size: 15),
          const SizedBox(width: 6),
          Text('TEMPERATURE',
              style: TextStyle(color: _dim, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: tc.withAlpha(30),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _temp >= 35 ? 'HOT 🔥' : _temp >= 30 ? 'WARM' : _temp >= 25 ? 'NORMAL' : 'COOL',
              style: TextStyle(color: tc, fontSize: 10, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_temp.toStringAsFixed(1),
              style: TextStyle(color: tc, fontSize: 44, fontWeight: FontWeight.w200, height: 1)),
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 2),
            child: Text('°C', style: TextStyle(color: tc.withAlpha(160), fontSize: 18, fontWeight: FontWeight.w300)),
          ),
          const Spacer(),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('PWM SPEED', style: TextStyle(color: _dim, fontSize: 9, letterSpacing: 1)),
            Text('$_speed', style: TextStyle(color: _accent, fontSize: 30, fontWeight: FontWeight.w300, height: 1.1)),
          ]),
        ]),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 5,
            backgroundColor: _border,
            valueColor: AlwaysStoppedAnimation<Color>(tc),
          ),
        ),
      ]),
    );
  }

  // ── Stats row ─────────────────────────────────────────────────────────────
  Widget _buildStatsRow() {
    return Row(children: [
      _statCard('MIST',  _mist,              _mist != 'OFF' ? _cyan : _dim,   Icons.water_drop),
      const SizedBox(width: 10),
      _statCard('LIGHT', _lightOn ? 'ON' : 'OFF', _lightOn ? _yellow : _dim,  _lightOn ? Icons.lightbulb : Icons.lightbulb_outline),
      const SizedBox(width: 10),
      _statCard('SWING', _swingMode ? 'ON' : 'OFF', _swingMode ? _green : _dim, _swingMode ? Icons.sync : Icons.sync_disabled),
    ]);
  }

  Widget _statCard(String label, String val, Color c, IconData icon) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
        boxShadow: _cardShadow,
      ),
      child: Column(children: [
        Icon(icon, color: c, size: 20),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(color: _dim, fontSize: 9, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(val, style: TextStyle(color: c, fontSize: 15, fontWeight: FontWeight.w700)),
      ]),
    ));
  }

  // ── Fan status ────────────────────────────────────────────────────────────
  Widget _buildFanStatus() {
    final dirIcon = switch (_direction) {
      'LEFT'  => Icons.arrow_back,
      'RIGHT' => Icons.arrow_forward,
      'L-C'   => Icons.compare_arrows,
      'R-C'   => Icons.compare_arrows,
      'SWING' => Icons.swap_horiz,
      _       => Icons.center_focus_strong,
    };
    final dirCol = _direction == 'SWING'
        ? _accent
        : (_direction.contains('L') || _direction.contains('R'))
            ? _cyan
            : _green;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
          boxShadow: _cardShadow),
      child: Row(children: [
        _miniStat('FAN',    _fanRunning ? 'RUNNING' : 'IDLE', _fanRunning ? _green : _dim, Icons.air),
        _divider(),
        _miniStat('DIR',    _direction,  dirCol,  dirIcon),
        _divider(),
        _miniStat('UPTIME', _uptimeStr(), _dim, Icons.timer_outlined),
      ]),
    );
  }

  Widget _miniStat(String lbl, String val, Color c, IconData ic) =>
      Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(ic, color: c, size: 16),
        const SizedBox(height: 4),
        Text(lbl, style: TextStyle(color: _dim, fontSize: 8, letterSpacing: 1)),
        const SizedBox(height: 2),
        Text(val,
            style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis),
      ]));

  Widget _divider() => Container(width: 1, height: 36, color: _border);

  // ── PIR section ────────────────────────────────────────────────────────────
  Widget _buildPirSection() {
    final any = _pirL || _pirC || _pirR;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
          boxShadow: _cardShadow),
      child: Row(children: [
        Text('MOTION', style: TextStyle(color: _dim, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        _pirChip('L', _pirL),
        const SizedBox(width: 6),
        _pirChip('C', _pirC),
        const SizedBox(width: 6),
        _pirChip('R', _pirR),
        const Spacer(),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: any ? _green.withAlpha(38) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: any ? _green.withAlpha(80) : _border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.sensors, color: any ? _green : _dim, size: 13),
            const SizedBox(width: 4),
            Text(any ? 'DETECTED' : 'CLEAR',
                style: TextStyle(color: any ? _green : _dim, fontSize: 9, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }

  Widget _pirChip(String lbl, bool on) => AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    width: 34, height: 28,
    decoration: BoxDecoration(
      color: on ? _green : _border,
      borderRadius: BorderRadius.circular(8),
      boxShadow: on ? [BoxShadow(color: _green.withAlpha(100), blurRadius: 8)] : [],
    ),
    child: Center(child: Text(lbl,
        style: TextStyle(color: on ? Colors.white : _dim, fontWeight: FontWeight.w800, fontSize: 11))),
  );

  // ── Fan Control: ON/OFF + Direction (multi-select swing) ──────────────────────
  Widget _buildFanControl() {
    final canCtrl = _mode != 'AUTO';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ─ Section label
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text('FAN CONTROL',
            style: TextStyle(color: _dim, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
      ),
      // ─ Fan ON / OFF
      Row(children: [
        Expanded(
          child: GestureDetector(
            onTap: (canCtrl && !_cmdInProgress)
                ? () => _cmd(_fanRunning ? 'FAN_OFF' : 'FAN_ON')
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: canCtrl
                    ? (_fanRunning ? _green.withAlpha(50) : _red.withAlpha(30))
                    : _card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: canCtrl
                      ? (_fanRunning ? _green : _red).withAlpha(180)
                      : _border,
                  width: 1.5,
                ),
                boxShadow: canCtrl && _fanRunning
                    ? [BoxShadow(color: _green.withAlpha(70), blurRadius: 14)]
                    : [],
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                AnimatedBuilder(
                  animation: _fanCtrl,
                  builder: (_, __) => Transform.rotate(
                    angle: canCtrl && _fanRunning ? _fanCtrl.value * 6.28 : 0,
                    child: Icon(Icons.air,
                        color: canCtrl ? (_fanRunning ? _green : _red) : _dim,
                        size: 24),
                  ),
                ),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('FAN', style: TextStyle(color: _dim, fontSize: 9, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                  Text(_fanRunning ? 'ON' : 'OFF',
                      style: TextStyle(
                          color: canCtrl ? (_fanRunning ? _green : _red) : _dim,
                          fontWeight: FontWeight.w800,
                          fontSize: 18)),
                ]),
              ]),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      // ─ Direction (multi-select for swing)
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('DIRECTION',
                style: TextStyle(color: _dim, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
          ),
          // Hint
          Text(
            _selectedDirs.length == 2
                ? 'SWING: ${_selectedDirs.join(' ↔ ')}'
                : _selectedDirs.length == 1
                    ? 'TAP ANOTHER TO SWING'
                    : 'TAP TO SELECT',
            style: TextStyle(
                color: _selectedDirs.length == 2 ? _cyan : _dim,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(children: [
        _dirBtn('LEFT',   Icons.arrow_back,           canCtrl),
        const SizedBox(width: 8),
        _dirBtn('CENTER', Icons.center_focus_strong,   canCtrl),
        const SizedBox(width: 8),
        _dirBtn('RIGHT',  Icons.arrow_forward,         canCtrl),
      ]),
      // Swing-off button — shown only when swing is active
      if (_swingMode && canCtrl) ...[
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _cmdInProgress ? null : () {
            setState(() => _selectedDirs.clear());
            _cmd('SWING_OFF');
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: _red.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _red.withAlpha(100)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.sync_disabled, color: _red, size: 16),
              const SizedBox(width: 8),
              Text('STOP SWING', style: TextStyle(color: _red, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1)),
            ]),
          ),
        ),
      ],
    ]);
  }

  // ─ Direction button (multi-select toggle)
  Widget _dirBtn(String lbl, IconData ic, bool en) {
    final sel = _selectedDirs.contains(lbl);
    // Highlight if: selected by user OR if no user selection and it matches current ESP32 direction (single-point)
    final isCurrent = !_swingMode && _direction.toUpperCase() == lbl;
    final active = sel || isCurrent;
    final c = sel ? _cyan : (isCurrent ? _green : (en ? _dim : _dim.withAlpha(100)));
    final borderC = sel ? _cyan : (isCurrent ? _green : (en ? _border : _border.withAlpha(80)));

    return Expanded(child: GestureDetector(
      onTap: (!en || _cmdInProgress) ? null : () {
        setState(() {
          if (_selectedDirs.contains(lbl)) {
            // Deselect
            _selectedDirs.remove(lbl);
          } else {
            if (_selectedDirs.length < 2) {
              _selectedDirs.add(lbl);
            } else {
              // Already 2 selected — replace oldest with new
              _selectedDirs.clear();
              _selectedDirs.add(lbl);
            }
          }
        });

        // Send command based on selection
        if (_selectedDirs.length == 2) {
          // Two endpoints selected → swing command
          final haL = _selectedDirs.contains('LEFT');
          final haC = _selectedDirs.contains('CENTER');
          final haR = _selectedDirs.contains('RIGHT');
          if (haL && haR)      _cmd('SWING_LR');
          else if (haL && haC) _cmd('SWING_LC');
          else if (haR && haC) _cmd('SWING_RC');
        } else if (_selectedDirs.length == 1) {
          // One endpoint → point to that direction, no swing
          final dir = _selectedDirs.first;
          if (dir == 'LEFT')   _cmd('DIR_LEFT');
          else if (dir == 'CENTER') _cmd('DIR_CENTER');
          else if (dir == 'RIGHT')  _cmd('DIR_RIGHT');
        } else {
          // Deselected all → stop swing, go center
          _cmd('SWING_OFF');
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: active ? c.withAlpha(45) : _card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderC, width: active ? 1.5 : 1),
          boxShadow: sel
              ? [BoxShadow(color: _cyan.withAlpha(60), blurRadius: 12)]
              : isCurrent
                  ? [BoxShadow(color: _green.withAlpha(50), blurRadius: 8)]
                  : [],
        ),
        child: Column(children: [
          Icon(ic, color: c, size: 22),
          const SizedBox(height: 4),
          Text(lbl,
              style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          if (sel) ...[
            const SizedBox(height: 2),
            Container(
              width: 16, height: 3,
              decoration: BoxDecoration(
                color: _cyan,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ]),
      ),
    ));
  }

  // ── Mode selector ─────────────────────────────────────────────────────────
  Widget _buildModeSelector() {
    const modes = [
      ('AUTO',   _green,  Icons.auto_mode),
      ('MANUAL', _accent, Icons.tune),
      ('TRAVEL', _blue,   Icons.flight),
      ('OFFICE', _teal,   Icons.business),
      ('NIGHT',  _purple, Icons.dark_mode),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text('MODE',
            style: TextStyle(color: _dim, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
      ),
      Row(children: modes.map((m) {
        final active = m.$1 == _mode;
        return Expanded(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: GestureDetector(
            onTap: _cmdInProgress ? null : () => _cmd(m.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: active ? m.$2.withAlpha(50) : _card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: active ? m.$2 : _border,
                    width: active ? 1.5 : 1),
                boxShadow: active
                    ? [BoxShadow(color: m.$2.withAlpha(60), blurRadius: 12, spreadRadius: -2)]
                    : [],
              ),
              child: Column(children: [
                Icon(m.$3, color: active ? m.$2 : _dim, size: 20),
                const SizedBox(height: 4),
                Text(m.$1,
                    style: TextStyle(
                        color: active ? m.$2 : _dim,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ]),
            ),
          ),
        ));
      }).toList()),
    ]);
  }

  // ── Speed controls ────────────────────────────────────────────────────────
  Widget _buildSpeedControls() {
    final canCtrl = _mode != 'AUTO' && _mode != 'OFFICE';
    return Row(children: [
      _ctrlBtn('SPD −', Icons.remove_circle_outline, canCtrl, () => _cmd('SPEED-')),
      const SizedBox(width: 8),
      _ctrlBtn('SPD +', Icons.add_circle_outline,    canCtrl, () => _cmd('SPEED+')),
      const SizedBox(width: 8),
      _ctrlBtn('SWING', Icons.swap_horiz,             canCtrl, () => _cmd('SWING_TOGGLE')),
    ]);
  }

  Widget _ctrlBtn(String lbl, IconData ic, bool en, VoidCallback fn) =>
      Expanded(child: GestureDetector(
        onTap: (en && !_cmdInProgress) ? fn : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: en ? _accent.withAlpha(100) : _border),
            boxShadow: _cardShadow,
          ),
          child: Column(children: [
            Icon(ic, color: en ? _accent : _dim, size: 22),
            const SizedBox(height: 4),
            Text(lbl,
                style: TextStyle(
                    color: en ? _text : _dim, fontSize: 10, fontWeight: FontWeight.w600)),
          ]),
        ),
      ));

  // ── Mist card — full width, large controls ───────────────────────────────
  Widget _buildMistCard() {
    final lvl = switch (_mist) { 'LOW' => 1, 'ALL' => 2, _ => 0 };
    final c   = lvl == 0 ? _dim : _cyan;
    final canDec = lvl > 0 && !_cmdInProgress;
    final canInc = lvl < 2 && !_cmdInProgress;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: lvl > 0 ? _cyan.withAlpha(25) : _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: lvl > 0 ? _cyan.withAlpha(180) : _border,
          width: lvl > 0 ? 1.5 : 1,
        ),
        boxShadow: lvl > 0
            ? [BoxShadow(color: _cyan.withAlpha(50), blurRadius: 16)]
            : _cardShadow,
      ),
      child: Column(children: [
        // Header row
        Row(children: [
          Icon(Icons.water_drop, color: c, size: 18),
          const SizedBox(width: 8),
          Text('MIST CONTROL',
              style: TextStyle(color: _dim, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
          const Spacer(),
          // Level badge
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.withAlpha(lvl > 0 ? 40 : 20),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.withAlpha(100)),
            ),
            child: Text(_mist,
                style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
          ),
        ]),
        const SizedBox(height: 16),
        // Main control row: big − | indicators | big +
        Row(children: [
          // DECREASE button
          GestureDetector(
            onTap: canDec ? () => _cmd('MIST-') : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 56, height: 56,
              decoration: BoxDecoration(
                color: canDec ? _cyan.withAlpha(50) : _border.withAlpha(40),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: canDec ? _cyan.withAlpha(200) : _border, width: 1.5),
                boxShadow: canDec ? [BoxShadow(color: _cyan.withAlpha(60), blurRadius: 10)] : [],
              ),
              child: Icon(Icons.remove_rounded, color: canDec ? _cyan : _dim, size: 28),
            ),
          ),
          // Level indicators — centre
          Expanded(child: Column(children: [
            // 3-step dot bar
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _mistDot(lvl >= 0, lvl == 0 ? _border : _cyan.withAlpha(80), 10),
              const SizedBox(width: 8),
              _mistDot(lvl >= 1, _cyan.withAlpha(180), 12),
              const SizedBox(width: 8),
              _mistDot(lvl >= 2, _cyan, 14),
            ]),
            const SizedBox(height: 10),
            // Level labels
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _levelLabel('OFF',  lvl == 0, _dim),
              const SizedBox(width: 16),
              _levelLabel('LOW',  lvl == 1, _cyan),
              const SizedBox(width: 16),
              _levelLabel('ALL',  lvl == 2, _cyan),
            ]),
          ])),
          // INCREASE button
          GestureDetector(
            onTap: canInc ? () => _cmd('MIST+') : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 56, height: 56,
              decoration: BoxDecoration(
                color: canInc ? _cyan.withAlpha(50) : _border.withAlpha(40),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: canInc ? _cyan.withAlpha(200) : _border, width: 1.5),
                boxShadow: canInc ? [BoxShadow(color: _cyan.withAlpha(60), blurRadius: 10)] : [],
              ),
              child: Icon(Icons.add_rounded, color: canInc ? _cyan : _dim, size: 28),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _mistDot(bool active, Color c, double size) => AnimatedContainer(
    duration: const Duration(milliseconds: 250),
    width: size, height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: active ? c : _border.withAlpha(80),
      boxShadow: active ? [BoxShadow(color: c.withAlpha(150), blurRadius: 6)] : [],
    ),
  );

  Widget _levelLabel(String lbl, bool active, Color c) => Text(
    lbl,
    style: TextStyle(
      color: active ? c : _dim.withAlpha(120),
      fontSize: active ? 12 : 10,
      fontWeight: active ? FontWeight.w800 : FontWeight.w500,
      letterSpacing: 0.5,
    ),
  );

  // ── Light card — full width ───────────────────────────────────────────────
  Widget _buildLightCard() => GestureDetector(
    onTap: _cmdInProgress ? null : () => _cmd(_lightOn ? 'LIGHT_OFF' : 'LIGHT_ON'),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: _lightOn ? _yellow.withAlpha(35) : _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _lightOn ? _yellow.withAlpha(200) : _border,
          width: _lightOn ? 1.5 : 1,
        ),
        boxShadow: _lightOn
            ? [BoxShadow(color: _yellow.withAlpha(60), blurRadius: 18)]
            : _cardShadow,
      ),
      child: Row(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _lightOn ? _yellow.withAlpha(60) : _border.withAlpha(60),
            shape: BoxShape.circle,
          ),
          child: Icon(
            _lightOn ? Icons.lightbulb : Icons.lightbulb_outline,
            color: _lightOn ? _yellow : _dim,
            size: 26,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('LIGHT',
              style: TextStyle(color: _dim, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(_lightOn ? 'ON' : 'OFF',
              style: TextStyle(
                color: _lightOn ? _yellow : _text,
                fontWeight: FontWeight.w800, fontSize: 22,
              )),
        ])),
        // Toggle pill
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 52, height: 28,
          decoration: BoxDecoration(
            color: _lightOn ? _yellow.withAlpha(180) : _border.withAlpha(100),
            borderRadius: BorderRadius.circular(14),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 300),
            alignment: _lightOn ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Container(
                width: 22, height: 22,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ]),
    ),
  );

  // ── Unpair button ─────────────────────────────────────────────────────────
  Widget _buildUnpairBtn() => Center(
    child: TextButton.icon(
      onPressed: () => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Unpair Device?', style: TextStyle(color: _text)),
          content: Text('This will disconnect your phone from Smart Fan.',
              style: TextStyle(color: _text.withAlpha(180))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: _dim))),
            TextButton(
                onPressed: () { Navigator.pop(ctx); _unpair(); },
                child: const Text('Unpair', style: TextStyle(color: Colors.redAccent))),
          ],
        ),
      ),
      icon: Icon(Icons.link_off, size: 14, color: _dim),
      label: Text('Unpair Device', style: TextStyle(color: _dim, fontSize: 12)),
    ),
  );
}
