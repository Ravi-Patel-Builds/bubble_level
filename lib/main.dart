// =============================================================================
//  Bubble Level — Complete App (Phase 1 Engine + Phase 2 UI)
//  Architecture: ValueNotifier-driven, zero-setState sensor pipeline.
//  UI: Glassmorphic, edge-to-edge, CustomPainter-powered level displays.
// =============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

// =============================================================================
//  ENTRY POINT
// =============================================================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge: hide status + navigation bars, enforce portrait lock.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(const _BubbleLevelApp());
}

// =============================================================================
//  DESIGN TOKENS
// =============================================================================
class _DS {
  _DS._();

  // Palette
  static const obsidian     = Color(0xFF0A0A0C);
  static const obsidianMid  = Color(0xFF12121A);
  static const emerald      = Color(0xFF10B981);
  static const emeraldGlow  = Color(0x6010B981);
  static const amber        = Color(0xFFF59E0B);
  static const steel        = Color(0xFF3A3A4A);
  static const glassWhite   = Color(0x0DFFFFFF); // 5 % white
  static const glassBorder  = Color(0x22FFFFFF); // ~13 % white
  static const textDim      = Color(0x99FFFFFF);
  static const textBright   = Color(0xFFFFFFFF);

  // Ruler ticks
  static const rulerWidth   = 28.0;          // logical px band on each edge
  static const rulerBg      = Color(0xFF0E0E14);

  // Bubble
  static const bubbleRadius = 14.0;
  static const ringCount    = 3;             // concentric rings in Bull's Eye
}

// =============================================================================
//  ROOT APP
// =============================================================================
class _BubbleLevelApp extends StatelessWidget {
  const _BubbleLevelApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bubble Level',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _DS.obsidian,
        colorScheme: const ColorScheme.dark(
          surface: _DS.obsidian,
          primary: _DS.emerald,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: _DS.emerald,
          inactiveTrackColor: _DS.steel,
          thumbColor: _DS.emerald,
          overlayColor: _DS.emeraldGlow,
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: _DS.textDim, fontSize: 12),
        ),
      ),
      home: const LevelPage(),
    );
  }
}

// =============================================================================
//  LEVEL PAGE  ← owns LevelController lifecycle
// =============================================================================
class LevelPage extends StatefulWidget {
  const LevelPage({super.key});

  @override
  State<LevelPage> createState() => _LevelPageState();
}

class _LevelPageState extends State<LevelPage> {
  late final LevelController _ctrl;

  // Local state for the viscosity slider — uses setState because it only
  // rebuilds the Dock widget (cheap), not the sensor path.
  double _alpha = 0.5;

  @override
  void initState() {
    super.initState();
    _ctrl = LevelController()..init();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onAlphaChanged(double v) {
    setState(() {
      _alpha = v;
      _ctrl.alpha = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      backgroundColor: _DS.obsidian,
      body: Stack(
        children: [
          // ── Layer 0 : Static edge rulers (never re-render) ─────────────────
          Positioned.fill(
            child: ValueListenableBuilder<RulerMetrics>(
              valueListenable: _ctrl.rulerMetrics,
              builder: (context, metrics, _) => CustomPaint(
                painter: _RulerPainter(metrics: metrics),
              ),
            ),
          ),

          // ── Layer 1 : Level display — animated crossfade on mode switch ───
          // isSurfaceMode only fires when crossing the 45° threshold (rare),
          // so the AnimatedSwitcher never triggers during the hot sensor path.
          Positioned(
            left: _DS.rulerWidth,
            right: _DS.rulerWidth,
            top: 0,
            bottom: 0,
            child: ValueListenableBuilder<bool>(
              valueListenable: _ctrl.isSurfaceMode,
              builder: (context, isSurface, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                // FadeTransition: no layout jump, pure opacity cross-dissolve.
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: child,
                ),
                // StackFit.expand propagates tight constraints so CustomPaint
                // fills the space without an explicit SizedBox.expand() wrapper.
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    ?currentChild,
                  ],
                ),
                child: isSurface
                    ? _BullsEyeCanvas(key: const ValueKey(true),  ctrl: _ctrl)
                    : _TubularCanvas(key: const ValueKey(false), ctrl: _ctrl),
              ),
            ),
          ),

          // ── Layer 2 : Inclinometer readout (surgical text rebuild) ─────────
          Positioned(
            top: size.height * 0.12,
            left: _DS.rulerWidth + 16,
            right: _DS.rulerWidth + 16,
            child: _InclinometerReadout(ctrl: _ctrl),
          ),

          // ── Layer 3 : Glassmorphic Pro-Tools Dock (static blur) ────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ProToolsDock(
              ctrl: _ctrl,
              alpha: _alpha,
              onAlphaChanged: _onAlphaChanged,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
//  CANVAS WIDGETS  — thin StatelessWidgets that carry a Key for AnimatedSwitcher.
//  Separating them into distinct types (not just different keys on the same
//  widget) guarantees AnimatedSwitcher treats them as genuinely different nodes.
// =============================================================================

/// Bull's Eye canvas — subscribes to both pitch and roll notifiers.
/// Only the inner CustomPaint re-renders on each sensor tick.
class _BullsEyeCanvas extends StatelessWidget {
  const _BullsEyeCanvas({super.key, required this.ctrl});
  final LevelController ctrl;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: ctrl.pitch,
      builder: (context, pitch, _) => ValueListenableBuilder<double>(
        valueListenable: ctrl.roll,
        builder: (context, roll, _) => CustomPaint(
          painter: _BullsEyePainter(pitch: pitch, roll: roll),
        ),
      ),
    );
  }
}

/// Tubular canvas — subscribes to roll notifier only.
class _TubularCanvas extends StatelessWidget {
  const _TubularCanvas({super.key, required this.ctrl});
  final LevelController ctrl;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: ctrl.roll,
      builder: (context, roll, _) => CustomPaint(
        painter: _TubularPainter(tilt: roll),
      ),
    );
  }
}

// =============================================================================
//  INCLINOMETER READOUT
//  Only the angle text rebuilds — BackdropFilter glass is outside the listener.
// =============================================================================
class _InclinometerReadout extends StatelessWidget {
  const _InclinometerReadout({required this.ctrl});
  final LevelController ctrl;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Mode label (rebuilds on mode switch only) ───────────────────────
          ValueListenableBuilder<bool>(
            valueListenable: ctrl.isSurfaceMode,
            builder: (context, isSurface, _) => Text(
              isSurface ? 'BULL\'S EYE  ·  2D SURFACE' : 'TUBULAR  ·  WALL PLUMB',
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 2.4,
                color: _DS.textDim,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ── Large degree display (rebuilds on every sensor tick) ────────────
          ValueListenableBuilder<double>(
            valueListenable: ctrl.absoluteAngle,
            builder: (context, angle, _) {
              final isLevel = angle <= 0.5;
              return Text(
                '${angle.toStringAsFixed(1)}°',
                style: TextStyle(
                  // Upgraded: 64 px ultra-thin — commanding readout
                  fontSize: 64,
                  fontWeight: FontWeight.w100,
                  letterSpacing: -2,
                  color: isLevel ? _DS.emerald : _DS.textBright,
                  // Tabular figures: digits identical width → zero layout jitter
                  fontFeatures: const [FontFeature.tabularFigures()],
                  // Triple-layer emerald glow when level — wide halo + tight bloom
                  shadows: isLevel
                      ? [
                          // Wide diffuse halo
                          Shadow(
                            color: _DS.emerald.withAlpha(110),
                            blurRadius: 40,
                          ),
                          // Mid bloom
                          Shadow(
                            color: _DS.emerald.withAlpha(160),
                            blurRadius: 18,
                          ),
                          // Tight inner glow — makes the numeral feel lit
                          Shadow(
                            color: _DS.emerald.withAlpha(210),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          // ── Pitch / Roll sub-readouts ───────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _AngleChip(label: 'PITCH', notifier: ctrl.pitch),
              const SizedBox(width: 20),
              _AngleChip(label: 'ROLL', notifier: ctrl.roll),
            ],
          ),
        ],
      ),
    );
  }
}

/// Sub-label with individual label and live angle value.
class _AngleChip extends StatelessWidget {
  const _AngleChip({required this.label, required this.notifier});
  final String label;
  final ValueNotifier<double> notifier;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: notifier,
      builder: (context, v, _) => RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: const TextStyle(
                fontSize: 10,
                color: _DS.textDim,
                letterSpacing: 1.6,
              ),
            ),
            TextSpan(
              text: '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}°',
              style: const TextStyle(
                fontSize: 13,
                color: _DS.textBright,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
//  PRO-TOOLS DOCK  (Glassmorphic bottom strip)
//  BackdropFilter is static — only the Lock icon rebuilds via its own listener.
// =============================================================================
class _ProToolsDock extends StatelessWidget {
  const _ProToolsDock({
    required this.ctrl,
    required this.alpha,
    required this.onAlphaChanged,
  });

  final LevelController ctrl;
  final double alpha;
  final ValueChanged<double> onAlphaChanged;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(24),
        topRight: Radius.circular(24),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ────────────────────────────────────────────────────
          Container(
            width: 36,
            height: 3,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: _DS.glassBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // ── Viscosity slider ───────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.water_drop_outlined, size: 16, color: _DS.textDim),
              const SizedBox(width: 8),
              const Text(
                'VISCOSITY',
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 2,
                  color: _DS.textDim,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Expanded(
                child: Slider(
                  value: alpha,
                  min: 0.05,
                  max: 1.0,
                  onChanged: onAlphaChanged,
                ),
              ),
              SizedBox(
                width: 30,
                child: Text(
                  alpha.toStringAsFixed(2),
                  style: const TextStyle(
                    fontSize: 10,
                    color: _DS.textDim,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Action buttons ─────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Tare / Set Baseline
              _DockButton(
                icon: Icons.straighten_rounded,
                label: 'SET BASE',
                onTap: () {
                  ctrl.calibrate();
                  HapticFeedback.selectionClick();
                },
              ),

              // Reset calibration
              _DockButton(
                icon: Icons.refresh_rounded,
                label: 'RESET',
                onTap: () {
                  ctrl.resetCalibration();
                  HapticFeedback.selectionClick();
                },
              ),

              // Lock / Freeze — only this button rebuilds
              ValueListenableBuilder<bool>(
                valueListenable: ctrl.isLocked,
                builder: (context, locked, _) => _DockButton(
                  icon: locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                  label: locked ? 'UNLOCK' : 'FREEZE',
                  accent: locked ? _DS.amber : null,
                  onTap: () {
                    ctrl.toggleLock();
                    HapticFeedback.selectionClick();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Single icon + label button for the dock.
class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? _DS.textDim;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: _DS.glassWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _DS.glassBorder, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1.4,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
//  GLASS PANEL  — Thick, polished Glassmorphic container  (Phase 3 upgrade)
//
//  Render contract:
//    • BackdropFilter (sigma 15) lives HERE, outside every ValueListenableBuilder.
//    • The 1 px gradient border simulates a polished, beveled glass edge.
//    • The top inner shadow layer creates the illusion of panel depth/thickness.
//    • None of this repaints from sensor data — it is layout-stable and static.
// =============================================================================
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    // Outer shell: 1 px gradient acts as the metallic polished border.
    // The gradient runs top-left (bright white) → bottom-right (near-invisible),
    // matching a top-left virtual light source on a thick glass slab.
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x4DFFFFFF), // 30 % white — bright metallic bevel
            Color(0x18FFFFFF), // 9 % white — mid gradient
            Color(0x06FFFFFF), // 2 % white — bottom-right fades out
          ],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      padding: const EdgeInsets.all(1.0), // the border's physical thickness
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          // Upgraded: sigma 15 for a noticeably thicker, more saturated blur
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Stack(
            children: [
              // ── Glass body fill ─────────────────────────────────────────────
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  // Angled light-catch gradient: top-left slightly lighter,
                  // bottom-right darker — simulates a curved glass face.
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withAlpha(22), // ~8 % — lit face
                      Colors.white.withAlpha(8),  // ~3 % — shadow face
                    ],
                  ),
                ),
                padding: padding,
                child: child,
              ),

              // ── Inner top-edge shadow (depth / thickness illusion) ──────────
              // A soft dark gradient at the top interior edge creates the
              // perception that the glass has physical depth, like a real lens.
              // IgnorePointer ensures it never captures touch events.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.only(
                        topLeft: borderRadius.topLeft,
                        topRight: borderRadius.topRight,
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withAlpha(56), // 22 % — deep inner rim
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Inner bottom-edge counter-shadow ────────────────────────────
              // Subtle secondary darkening at the bottom interior mimics the
              // secondary refraction shadow in thick optical glass.
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 20,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.only(
                        bottomLeft: borderRadius.bottomLeft,
                        bottomRight: borderRadius.bottomRight,
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withAlpha(30), // 12 % — counter shadow
                          Colors.transparent,
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

// =============================================================================
//  PAINTER : BULL'S EYE  (2D surface leveling)  — Phase 3 photorealistic bubble
// =============================================================================

/// Draws concentric rings + a physically accurate 3D bubble.
///
/// Bubble lighting model (back → front draw order):
///   1. Ground shadow  — soft blurred ellipse below the sphere
///   2. Bubble body    — RadialGradient from bright top-left to dark bottom-right
///   3. Rim light      — thin bottom-right arc, ambient occlusion counter-light
///   4. Soft highlight — large feathered oval in the upper hemisphere
///   5. Sharp specular — crisp, near-white oval, top-left (primary light source)
///
/// Bubble turns Emerald (#10B981) + glow when both axes ≤ 0.5°.
class _BullsEyePainter extends CustomPainter {
  _BullsEyePainter({required this.pitch, required this.roll});

  final double pitch;
  final double roll;

  static const double _maxTiltDeg = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;
    final maxR = math.min(cx, cy) * 0.72;

    // ── Background disc ──────────────────────────────────────────────────────
    canvas.drawCircle(
      Offset(cx, cy),
      maxR,
      Paint()
        ..shader = RadialGradient(
          colors: [_DS.obsidianMid, _DS.obsidian],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: maxR)),
    );

    // ── Concentric rings ─────────────────────────────────────────────────────
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    for (int i = _DS.ringCount; i >= 1; i--) {
      ringPaint.color =
          i == _DS.ringCount ? _DS.steel : const Color(0xFF2A2A3A);
      canvas.drawCircle(
        Offset(cx, cy), maxR * (i / _DS.ringCount), ringPaint,
      );
    }

    // ── Crosshair ────────────────────────────────────────────────────────────
    final crossPaint = Paint()
      ..color = _DS.steel
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(cx - maxR, cy), Offset(cx + maxR, cy), crossPaint);
    canvas.drawLine(Offset(cx, cy - maxR), Offset(cx, cy + maxR), crossPaint);

    // ── Bubble position ──────────────────────────────────────────────────────
    final scale  = maxR / _maxTiltDeg;
    final clampR = maxR - _DS.bubbleRadius;

    double bx = (roll  *  scale).clamp(-clampR, clampR);
    double by = (-pitch * scale).clamp(-clampR, clampR);

    final dist = math.sqrt(bx * bx + by * by);
    if (dist > clampR) {
      bx = bx / dist * clampR;
      by = by / dist * clampR;
    }

    final bc      = Offset(cx + bx, cy + by); // bubble center
    final r       = _DS.bubbleRadius;
    final isLevel = pitch.abs() <= 0.5 && roll.abs() <= 0.5;

    // ── 1. Ground shadow ─────────────────────────────────────────────────────
    // Soft elliptical shadow directly beneath the sphere — simulates
    // a point-light source above casting a contact shadow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(bc.dx + 1.5, bc.dy + r * 0.65),
        width:  r * 2.6,
        height: r * 0.80,
      ),
      Paint()
        ..color = Colors.black.withAlpha(100)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // ── Emerald glow when level ───────────────────────────────────────────────
    if (isLevel) {
      // Wide diffuse corona
      canvas.drawCircle(
        bc, r + 12,
        Paint()
          ..color = _DS.emerald.withAlpha(55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
      );
      // Tight inner ring pulse
      canvas.drawCircle(
        Offset(cx, cy), maxR / _DS.ringCount,
        Paint()
          ..color = _DS.emerald.withAlpha(65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // ── 2. Bubble body — 3D radial gradient ──────────────────────────────────
    // Light source is top-left; bright highlight fades to deep shadow bottom-right.
    canvas.drawCircle(
      bc,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.38, -0.42),
          radius: 1.0,
          colors: isLevel
              ? [
                  const Color(0xFF72EFBE), // bright lit top-left face
                  _DS.emerald,             // mid-tone body
                  const Color(0xFF064E3B), // deep shadow bottom-right
                ]
              : [
                  const Color(0xFFEDF2FF), // near-white lit face (water/glass)
                  const Color(0xFFAABEDF), // steel-blue body
                  const Color(0xFF2D3E5F), // dark shadow bottom-right
                ],
          stops: const [0.0, 0.42, 1.0],
        ).createShader(Rect.fromCircle(center: bc, radius: r)),
    );

    // ── 3. Rim light ─────────────────────────────────────────────────────────
    // Thin bright arc on the lower-right edge simulates environmental
    // bounce light (fill light) from a surface below the sphere.
    canvas.drawArc(
      Rect.fromCircle(center: bc, radius: r - 0.8),
      math.pi * 0.25,   // start angle (lower-right quadrant)
      math.pi * 0.90,   // sweep ~162°
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = isLevel
            ? Colors.white.withAlpha(75)
            : Colors.white.withAlpha(55),
    );

    // ── 4. Soft secondary highlight ──────────────────────────────────────────
    // Large, feathered ellipse in the upper hemisphere — the diffuse
    // catch-light that reads as "wet" or "glass-like".
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(bc.dx - r * 0.18, bc.dy - r * 0.22),
        width:  r * 1.05,
        height: r * 0.62,
      ),
      Paint()
        ..color = Colors.white.withAlpha(58)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // ── 5. Sharp primary specular ────────────────────────────────────────────
    // Crisp, bright oval at top-left — the primary specular reflection
    // of the light source. No blur: sharpness signals a hard, smooth surface.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(bc.dx - r * 0.30, bc.dy - r * 0.36),
        width:  r * 0.42,
        height: r * 0.26,
      ),
      Paint()..color = Colors.white.withAlpha(238), // nearly opaque
    );

    // ── Center crosshair dot ─────────────────────────────────────────────────
    canvas.drawCircle(Offset(cx, cy), 2.5, Paint()..color = _DS.steel);
  }

  @override
  bool shouldRepaint(_BullsEyePainter old) =>
      old.pitch != pitch || old.roll != roll;
}

// =============================================================================
//  PAINTER : TUBULAR  (1D wall / plumb leveling)  — Phase 3 photorealistic bubble
// =============================================================================

/// Draws a precision glass tube with a 3D-lit pill bubble.
///
/// Bubble lighting model (back → front draw order):
///   1. Contact shadow — soft ellipse behind pill, near the tube floor
///   2. Pill body      — LinearGradient top-lit, darkens toward bottom
///   3. Rim light      — thin bright stroke on the lower edge
///   4. Soft highlight — large feathered rectangle, upper third of pill
///   5. Sharp specular — crisp narrow oval, upper-left of pill
///
/// Bubble glows Emerald when tilt ≤ 0.5°.
class _TubularPainter extends CustomPainter {
  _TubularPainter({required this.tilt});

  final double tilt;

  static const double _tubeHeight = 52.0;
  static const double _maxTiltDeg = 12.0;
  static const double _bubbleW    = 44.0;
  // Inner bubble height (tube minus top/bottom padding)
  static const double _bubbleH    = _tubeHeight - 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx    = size.width  / 2;
    final cy    = size.height / 2;
    final tubeW = size.width  * 0.72;

    final tubeRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: tubeW, height: _tubeHeight),
      const Radius.circular(_tubeHeight / 2),
    );

    // ── Tube body ─────────────────────────────────────────────────────────────
    // Three-stop gradient: dark top → deeper obsidian center → dark bottom,
    // giving the impression of a hollow cylindrical glass tube.
    canvas.drawRRect(
      tubeRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF1A1A26), // top inner wall catch-light
            _DS.obsidian,            // deep centre
            const Color(0xFF1A1A26), // bottom inner wall catch-light
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(tubeRect.outerRect),
    );

    // Tube border (metallic outer edge)
    canvas.drawRRect(
      tubeRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = _DS.steel
        ..strokeWidth = 1.0,
    );

    // Inner highlight on tube top edge (glass sheen)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy - _tubeHeight / 2 + 2),
          width: tubeW - 20,
          height: 3,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = Colors.white.withAlpha(18),
    );

    // Center tick
    final tickPaint = Paint()
      ..color = _DS.steel
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(cx, cy - _tubeHeight / 2 + 8),
      Offset(cx, cy + _tubeHeight / 2 - 8),
      tickPaint,
    );
    // Quarter ticks
    for (final xOff in [-tubeW * 0.25, tubeW * 0.25]) {
      canvas.drawLine(
        Offset(cx + xOff, cy - _tubeHeight / 2 + 14),
        Offset(cx + xOff, cy + _tubeHeight / 2 - 14),
        tickPaint..color = const Color(0xFF2A2A3A),
      );
    }

    // ── Bubble position ───────────────────────────────────────────────────────
    final maxOffset = (tubeW / 2) - (_bubbleW / 2) - 8;
    final scale     = maxOffset / _maxTiltDeg;
    final bx        = (tilt * scale).clamp(-maxOffset, maxOffset);
    final isLevel   = tilt.abs() <= 0.5;

    final bubbleRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx + bx, cy),
        width: _bubbleW,
        height: _bubbleH,
      ),
      const Radius.circular(_bubbleH / 2),
    );

    // ── 1. Contact shadow ─────────────────────────────────────────────────────
    // Pressed against the tube floor — an elliptical contact shadow makes the
    // bubble appear to "sit inside" the tube rather than float on top.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx + bx + 2, cy + _bubbleH * 0.38),
        width:  _bubbleW * 1.05,
        height: _bubbleH * 0.28,
      ),
      Paint()
        ..color = Colors.black.withAlpha(90)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // ── Emerald glow ──────────────────────────────────────────────────────────
    if (isLevel) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          bubbleRect.outerRect.inflate(7),
          const Radius.circular(_bubbleH / 2 + 7),
        ),
        Paint()
          ..color = _DS.emerald.withAlpha(60)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }

    // ── 2. Pill body — top-lit gradient ──────────────────────────────────────
    canvas.drawRRect(
      bubbleRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isLevel
              ? [
                  const Color(0xFF6EF0B8), // bright lit top face
                  _DS.emerald,             // mid-tone
                  const Color(0xFF064E3B), // deep shadow bottom
                ]
              : [
                  const Color(0xFFE6EEFF), // near-white lit top (glass/water)
                  const Color(0xFFAABFDE), // steel-blue mid
                  const Color(0xFF2D3E5F), // dark shadow bottom
                ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(bubbleRect.outerRect),
    );

    // ── 3. Rim light ─────────────────────────────────────────────────────────
    // Thin bright stroke on the lower half of the pill — simulates bounce
    // light reflecting off the tube floor below the bubble.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx + bx, cy + _bubbleH * 0.32),
          width: _bubbleW - 8,
          height: _bubbleH * 0.22,
        ),
        const Radius.circular(_bubbleH * 0.11),
      ),
      Paint()
        ..color = isLevel
            ? Colors.white.withAlpha(50)
            : Colors.white.withAlpha(38)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );

    // ── 4. Soft secondary highlight ──────────────────────────────────────────
    // Large, feathered pill shape in the upper third — diffuse catch-light.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx + bx - _bubbleW * 0.06, cy - _bubbleH * 0.18),
          width: _bubbleW * 0.68,
          height: _bubbleH * 0.38,
        ),
        const Radius.circular(6),
      ),
      Paint()
        ..color = Colors.white.withAlpha(52)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // ── 5. Sharp primary specular ─────────────────────────────────────────────
    // Crisp, narrow oval at the upper-left of the pill.
    // Hard edge = hard (smooth) surface. No blur.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(
            cx + bx - _bubbleW * 0.20,
            cy - _bubbleH * 0.28,
          ),
          width:  _bubbleW * 0.30,
          height: _bubbleH * 0.18,
        ),
        const Radius.circular(4),
      ),
      Paint()..color = Colors.white.withAlpha(235), // near-opaque
    );
  }

  @override
  bool shouldRepaint(_TubularPainter old) => old.tilt != tilt;
}

// =============================================================================
//  PAINTER : EDGE RULER
//  Static — painted once per rulerMetrics change (only on app start).
//  Left edge = centimetres, Right edge = inches.
// =============================================================================
class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.metrics});

  final RulerMetrics metrics;

  @override
  void paint(Canvas canvas, Size size) {
    _drawRulerBand(canvas, size, isLeft: true);
    _drawRulerBand(canvas, size, isLeft: false);
  }

  void _drawRulerBand(Canvas canvas, Size size, {required bool isLeft}) {
    final x = isLeft ? 0.0 : size.width - _DS.rulerWidth;

    // Background band
    canvas.drawRect(
      Rect.fromLTWH(x, 0, _DS.rulerWidth, size.height),
      Paint()..color = _DS.rulerBg,
    );

    // Separator line
    canvas.drawLine(
      Offset(isLeft ? x + _DS.rulerWidth : x, 0),
      Offset(isLeft ? x + _DS.rulerWidth : x, size.height),
      Paint()
        ..color = _DS.glassBorder
        ..strokeWidth = 0.5,
    );

    final tickPaint = Paint()
      ..color = _DS.textDim
      ..strokeWidth = 0.8;
    final majorPaint = Paint()
      ..color = _DS.textBright
      ..strokeWidth = 1;

    final tp = TextPainter(textDirection: TextDirection.ltr);

    if (isLeft) {
      // ── Centimetres (left) ─────────────────────────────────────────────────
      // logicalPxPerCm: how many logical pixels = 1 cm on this screen.
      final pxPerCm = metrics.logicalPxPerCm;
      final totalCm = size.height / pxPerCm;

      for (int mm = 0; mm <= totalCm * 10; mm++) {
        final y = mm * pxPerCm / 10;
        if (y > size.height) break;

        final isMajor  = mm % 10 == 0;
        final isHalf   = mm % 5  == 0;
        final tickLen  = isMajor ? 14.0 : (isHalf ? 9.0 : 5.0);
        final paint    = isMajor ? majorPaint : tickPaint;

        canvas.drawLine(
          Offset(x + _DS.rulerWidth - tickLen, y),
          Offset(x + _DS.rulerWidth, y),
          paint,
        );

        if (isMajor && mm > 0) {
          tp.text = TextSpan(
            text: '${mm ~/ 10}',
            style: const TextStyle(
              color: _DS.textDim,
              fontSize: 8,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          );
          tp.layout();
          tp.paint(
            canvas,
            Offset(x + 2, y - tp.height / 2),
          );
        }
      }

      // "CM" label at top
      _drawRotatedLabel(canvas, 'CM', Offset(x + _DS.rulerWidth / 2, 40));
    } else {
      // ── Inches (right) ────────────────────────────────────────────────────
      // 1 inch = 16 ticks (every 1/16")
      final pxPerInch = metrics.logicalPxPerInch;
      final totalInches = size.height / pxPerInch;

      for (int sixteenth = 0; sixteenth <= totalInches * 16; sixteenth++) {
        final y = sixteenth * pxPerInch / 16;
        if (y > size.height) break;

        final isInch     = sixteenth % 16 == 0;
        final isHalf     = sixteenth % 8  == 0;
        final isQuarter  = sixteenth % 4  == 0;
        final tickLen    = isInch ? 14.0 : (isHalf ? 10.0 : (isQuarter ? 7.0 : 4.0));
        final paint      = isInch ? majorPaint : tickPaint;

        canvas.drawLine(
          Offset(x, y),
          Offset(x + tickLen, y),
          paint,
        );

        if (isInch && sixteenth > 0) {
          tp.text = TextSpan(
            text: '${sixteenth ~/ 16}',
            style: const TextStyle(
              color: _DS.textDim,
              fontSize: 8,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          );
          tp.layout();
          tp.paint(canvas, Offset(x + 16, y - tp.height / 2));
        }
      }

      // "IN" label at top
      _drawRotatedLabel(canvas, 'IN', Offset(x + _DS.rulerWidth / 2, 40));
    }
  }

  /// Draws a short vertical label (rotated 90°) centered at [center].
  void _drawRotatedLabel(Canvas canvas, String text, Offset center) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: _DS.textDim,
          fontSize: 7,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-math.pi / 2);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.metrics.devicePixelRatio != metrics.devicePixelRatio;
}

// =============================================================================
//  RULER METRICS  (Phase 1 value object — unchanged)
// =============================================================================

/// Physical ruler conversion data derived from the device's pixel ratio.
///
/// physicalDpi ≈ devicePixelRatio × 160  (Android mdpi = 1.0× baseline).
/// Phase 2 Ruler painter consumes [logicalPxPerCm] / [logicalPxPerInch].
class RulerMetrics {
  const RulerMetrics({
    required this.devicePixelRatio,
    required this.pxPerInch,
    required this.pxPerCm,
  });

  final double devicePixelRatio;
  final double pxPerInch;
  final double pxPerCm;

  double get logicalPxPerInch => pxPerInch / devicePixelRatio;
  double get logicalPxPerCm   => pxPerCm   / devicePixelRatio;

  static const RulerMetrics zero = RulerMetrics(
    devicePixelRatio: 1.0,
    pxPerInch: 160.0,
    pxPerCm: 62.99,
  );
}

// =============================================================================
//  LEVEL CONTROLLER  (Phase 1 engine — unchanged)
// =============================================================================

/// Central engine driving every sensor-reactive widget in the app.
///
/// Lifecycle: create → init() → dispose().
class LevelController {
  // ── Public ValueNotifiers ─────────────────────────────────────────────────
  final ValueNotifier<double> pitch         = ValueNotifier(0.0);
  final ValueNotifier<double> roll          = ValueNotifier(0.0);
  final ValueNotifier<double> absoluteAngle = ValueNotifier(0.0);
  final ValueNotifier<bool>   isSurfaceMode = ValueNotifier(true);
  final ValueNotifier<bool>   isLocked      = ValueNotifier(false);
  final ValueNotifier<RulerMetrics> rulerMetrics =
      ValueNotifier(RulerMetrics.zero);

  // ── Viscosity ─────────────────────────────────────────────────────────────
  /// α ∈ (0, 1]. Bound to the viscosity slider in [_ProToolsDock].
  double alpha = 0.5;

  // ── Calibration offsets ───────────────────────────────────────────────────
  double _calOffsetPitch = 0.0;
  double _calOffsetRoll  = 0.0;

  // ── Smoothed accelerometer state ──────────────────────────────────────────
  double _smoothedX = 0.0;
  double _smoothedY = 0.0;
  double _smoothedZ = 0.0;

  // ── Haptic debounce ───────────────────────────────────────────────────────
  static const Duration _hapticDebounce = Duration(milliseconds: 800);
  DateTime _lastHapticTime = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription<AccelerometerEvent>? _accelSub;

  // ---------------------------------------------------------------------------
  void init() {
    _initRulerMetrics();
    _startAccelerometer();
  }

  void _initRulerMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr  = view.devicePixelRatio;
    final pxPerInch = dpr * 160.0;
    rulerMetrics.value = RulerMetrics(
      devicePixelRatio: dpr,
      pxPerInch: pxPerInch,
      pxPerCm: pxPerInch / 2.54,
    );
  }

  void _startAccelerometer() {
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(
      _onAccelerometerEvent,
      onError: (Object e) => debugPrint('[LevelController] Error: $e'),
      cancelOnError: false,
    );
  }

  // ---------------------------------------------------------------------------
  //  SENSOR PIPELINE
  // ---------------------------------------------------------------------------
  void _onAccelerometerEvent(AccelerometerEvent event) {
    if (isLocked.value) return;

    // ① Low-pass filter
    _smoothedX = alpha * event.x + (1.0 - alpha) * _smoothedX;
    _smoothedY = alpha * event.y + (1.0 - alpha) * _smoothedY;
    _smoothedZ = alpha * event.z + (1.0 - alpha) * _smoothedZ;

    final ax = _smoothedX;
    final ay = _smoothedY;
    final az = _smoothedZ;

    // ② & ③ Calibrated angles (degrees)
    final rawPitch = math.atan2(ay, az) * (180.0 / math.pi);
    final rawRoll  = math.atan2(ax, az) * (180.0 / math.pi);

    final calibratedPitch = rawPitch - _calOffsetPitch;
    final calibratedRoll  = rawRoll  - _calOffsetRoll;

    final absAngle = math.sqrt(
      calibratedPitch * calibratedPitch + calibratedRoll * calibratedRoll,
    ).clamp(0.0, 90.0);

    // ④ Publish
    pitch.value         = calibratedPitch;
    roll.value          = calibratedRoll;
    absoluteAngle.value = absAngle;
    isSurfaceMode.value = absAngle < 45.0;

    // ⑤ Debounced haptic
    _maybeFireHaptic(calibratedPitch, calibratedRoll);
  }

  // ---------------------------------------------------------------------------
  //  HAPTICS
  // ---------------------------------------------------------------------------
  static const double _levelDeadZone = 0.5;

  void _maybeFireHaptic(double p, double r) {
    if (p.abs() > _levelDeadZone || r.abs() > _levelDeadZone) return;
    final now = DateTime.now();
    if (now.difference(_lastHapticTime) >= _hapticDebounce) {
      _lastHapticTime = now;
      HapticFeedback.mediumImpact();
    }
  }

  // ---------------------------------------------------------------------------
  //  CALIBRATION
  // ---------------------------------------------------------------------------

  /// SET — stores current tilt as the zero baseline.
  void calibrate() {
    _calOffsetPitch = math.atan2(_smoothedY, _smoothedZ) * (180.0 / math.pi);
    _calOffsetRoll  = math.atan2(_smoothedX, _smoothedZ) * (180.0 / math.pi);
    debugPrint(
      '[LevelController] Calibrated — '
      'Δpitch=${_calOffsetPitch.toStringAsFixed(2)}° '
      'Δroll=${_calOffsetRoll.toStringAsFixed(2)}°',
    );
  }

  /// RESET — returns to hardware default.
  void resetCalibration() {
    _calOffsetPitch = 0.0;
    _calOffsetRoll  = 0.0;
    debugPrint('[LevelController] Calibration reset.');
  }

  // ---------------------------------------------------------------------------
  //  LOCK
  // ---------------------------------------------------------------------------
  void toggleLock() {
    isLocked.value = !isLocked.value;
    debugPrint('[LevelController] ${isLocked.value ? "LOCKED" : "UNLOCKED"}');
  }

  // ---------------------------------------------------------------------------
  //  RULER HELPERS
  // ---------------------------------------------------------------------------
  double get devicePixelRatio  => rulerMetrics.value.devicePixelRatio;
  double get logicalPxPerInch  => rulerMetrics.value.logicalPxPerInch;
  double get logicalPxPerCm    => rulerMetrics.value.logicalPxPerCm;
  double cmToLogicalPx(double cm)     => cm   * logicalPxPerCm;
  double inchToLogicalPx(double inch) => inch * logicalPxPerInch;

  // ---------------------------------------------------------------------------
  //  DISPOSE
  // ---------------------------------------------------------------------------
  void dispose() {
    _accelSub?.cancel();
    _accelSub = null;
    pitch.dispose();
    roll.dispose();
    absoluteAngle.dispose();
    isSurfaceMode.dispose();
    isLocked.dispose();
    rulerMetrics.dispose();
    debugPrint('[LevelController] Disposed.');
  }
}
