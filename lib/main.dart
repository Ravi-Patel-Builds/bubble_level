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
import 'package:camera/camera.dart';
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
//  SURVEYOR — STATE MACHINE
// =============================================================================

/// Drives the entire AR Surveyor flow as a pure state enum.
///
/// Transitions:
///   idle → onboardingHeight  (first activation)
///   idle → aimingBase        (subsequent activations, already calibrated)
///   onboardingHeight → onboardingGuide
///   onboardingGuide  → aimingBase    (camera starts here)
///   aimingBase       → lockedBase    (user locks base distance)
///   lockedBase       → result        (user locks top angle → height computed)
///   result           → aimingBase    (remeasure)
///   any              → idle          (deactivate)
enum SurveyorState {
  idle,
  onboardingHeight,
  onboardingGuide,
  aimingBase,
  lockedBase,
  result,
}

// =============================================================================
//  HEIGHT CALCULATOR  — Two-step trigonometric surveyor math
// =============================================================================

/// Implements the classical two-angle height measurement technique.
///
/// Geometry (phone held at [userHeight] above the ground):
///
///   TOP ────────────────────┐
///                           │ H = object height (unknown)
///   Phone ── d ─────── Base┘
///
///   Step 1 (aim DOWN at base):
///     tan(α) = userHeight / d   →   d = userHeight / tan(α)
///
///   Step 2 (aim UP at top):
///     H = userHeight + d × tan(β)
///
/// where α = |downward pitch angle|, β = |upward pitch angle|.
class HeightCalculator {
  const HeightCalculator({required this.userHeightM});

  /// Eye-level / holding height in metres.
  final double userHeightM;

  static const double _minAngleDeg = 1.5; // guard: < 1.5° is near-horizontal

  bool isAngleValid(double pitchDeg) => pitchDeg.abs() >= _minAngleDeg;

  /// Step 1 — horizontal distance to the target base (metres).
  double distance(double pitchDeg) {
    final rad = pitchDeg.abs() * math.pi / 180.0;
    return userHeightM / math.tan(rad);
  }

  /// Step 2 — total object height (metres), given the locked [distanceM].
  double objectHeight(double pitchDeg, double distanceM) {
    final rad = pitchDeg.abs() * math.pi / 180.0;
    return userHeightM + distanceM * math.tan(rad);
  }
}

// =============================================================================
//  SURVEYOR CONTROLLER  — Camera lifecycle + state machine
// =============================================================================

/// Manages the AR Surveyor tool: camera, onboarding, two-step measurement.
///
/// Render contract:
///   - [cameraCtrl] is exposed read-only for [CameraPreview].
///   - [cameraReady] is the ONLY notifier the camera preview observes; it
///     fires ONLY on user action (not at sensor frequency) — safe as a VLB.
///   - Heavy-computation widgets observe [pitch] from [LevelController] directly
///     and call [HeightCalculator] inline — no sensor-tick notifiers in here.
class SurveyorController {
  // ── Public state notifiers ────────────────────────────────────────────────

  /// Current surveyor workflow state.
  final ValueNotifier<SurveyorState> state =
      ValueNotifier(SurveyorState.idle);

  /// true once [CameraController.initialize()] has completed successfully.
  final ValueNotifier<bool> cameraReady = ValueNotifier(false);

  /// Locked horizontal distance (metres) from Step 1. Null until locked.
  final ValueNotifier<double?> lockedDistance = ValueNotifier(null);

  /// Final measured object height (metres). Null until Step 2 is locked.
  final ValueNotifier<double?> measuredHeight = ValueNotifier(null);

  /// Non-null when camera initialisation fails.
  final ValueNotifier<String?> cameraError = ValueNotifier(null);

  /// Flashlight / Torch toggle state.
  final ValueNotifier<bool> isTorchOn = ValueNotifier(false);

  // ── Public camera controller (read-only, null until ready) ───────────────
  CameraController? cameraCtrl;

  // ── Calibration ───────────────────────────────────────────────────────────

  /// User-entered holding height in metres.
  double userHeightM = 1.65;

  bool _hasOnboarded = false;

  /// Whether user has completed initial onboarding.
  bool get hasOnboarded => _hasOnboarded;

  /// Access the calculator with the current user height.
  HeightCalculator get calc => HeightCalculator(userHeightM: userHeightM);

  // ── Activation ───────────────────────────────────────────────────────────

  /// Entry point: called when the SURVEYOR dock button is tapped.
  void activate() {
    if (!_hasOnboarded) {
      state.value = SurveyorState.onboardingHeight;
    } else {
      state.value = SurveyorState.aimingBase;
      _startCamera();
    }
  }

  /// Re-opens height calibration modal to overwrite userHeight.
  void editHeight() {
    state.value = SurveyorState.onboardingHeight;
  }

  /// Toggles camera torch mode safely using official camera package API.
  Future<void> toggleTorch() async {
    final ctrl = cameraCtrl;
    if (ctrl == null || !ctrl.value.isInitialized) {
      debugPrint('[Flashlight] Camera is not initialized.');
      return;
    }
    try {
      if (isTorchOn.value) {
        await ctrl.setFlashMode(FlashMode.off);
        isTorchOn.value = false;
      } else {
        await ctrl.setFlashMode(FlashMode.torch);
        isTorchOn.value = true;
      }
    } catch (e) {
      debugPrint('[Flashlight] Error setting flash mode: $e');
    }
  }

  /// Exits surveyor mode and stops the camera.
  void deactivate() {
    _stopCamera();
    lockedDistance.value = null;
    measuredHeight.value = null;
    cameraError.value = null;
    state.value = SurveyorState.idle;
  }

  // ── Onboarding ────────────────────────────────────────────────────────────

  /// Called when the user confirms their height on Screen 1.
  void completeHeightEntry(double heightM) {
    userHeightM = heightM;
    if (_hasOnboarded) {
      state.value = SurveyorState.aimingBase;
      if (cameraCtrl == null || !cameraCtrl!.value.isInitialized) {
        _startCamera();
      }
    } else {
      state.value = SurveyorState.onboardingGuide;
    }
  }

  /// Called when the user taps "Start" on Screen 2 (the guide).
  Future<void> startFromGuide() async {
    _hasOnboarded = true;
    state.value = SurveyorState.aimingBase;
    await _startCamera();
  }

  // ── Measurement ──────────────────────────────────────────────────────────

  /// Step 1 LOCK — stores the distance and advances to lockedBase.
  /// Requires pitch to be tilted down ≥ 1.5° for a valid reading.
  void lockBase(double pitchDeg) {
    if (!calc.isAngleValid(pitchDeg)) return;
    final d = calc.distance(pitchDeg);
    if (d <= 0 || d.isInfinite || d.isNaN) return;
    lockedDistance.value = d;
    state.value = SurveyorState.lockedBase;
    HapticFeedback.heavyImpact();
    debugPrint('[Surveyor] Base locked — distance: ${d.toStringAsFixed(3)} m');
  }

  /// Step 2 LOCK — computes final height and advances to result.
  /// Requires pitch to be tilted up ≥ 1.5° for a valid reading.
  void lockTop(double pitchDeg) {
    final d = lockedDistance.value;
    if (d == null || !calc.isAngleValid(pitchDeg)) return;
    final h = calc.objectHeight(pitchDeg, d);
    measuredHeight.value = h;
    state.value = SurveyorState.result;
    HapticFeedback.heavyImpact();
    debugPrint('[Surveyor] Top locked — height: ${h.toStringAsFixed(3)} m');
  }

  /// Resets to Step 1 to allow remeasurement of the same target.
  void remeasure() {
    lockedDistance.value = null;
    measuredHeight.value = null;
    state.value = SurveyorState.aimingBase;
  }

  // ── Camera lifecycle ──────────────────────────────────────────────────────

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        cameraError.value = 'No camera detected on this device.';
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      cameraCtrl = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await cameraCtrl!.initialize();
      cameraReady.value = true;
      debugPrint('[Surveyor] Camera ready.');
    } on CameraException catch (e) {
      cameraError.value = e.code == 'cameraPermission'
          ? 'Camera permission denied.\n\nGo to Settings → Apps → Bubble Level → Permissions and enable Camera.'
          : 'Camera error: ${e.description}';
      debugPrint('[Surveyor] CameraException: ${e.code} — ${e.description}');
    }
  }

  void _stopCamera() {
    if (isTorchOn.value) {
      isTorchOn.value = false;
    }
    cameraCtrl?.dispose();
    cameraCtrl = null;
    cameraReady.value = false;
    debugPrint('[Surveyor] Camera released.');
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  void dispose() {
    _stopCamera();
    state.dispose();
    cameraReady.dispose();
    lockedDistance.dispose();
    measuredHeight.dispose();
    cameraError.dispose();
    isTorchOn.dispose();
    debugPrint('[SurveyorController] Disposed.');
  }
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
  late final SurveyorController _surveyorCtrl;

  // Viscosity slider — setState is safe here: it only rebuilds the dock,
  // never the sensor path or camera layer.
  double _alpha = 0.5;

  @override
  void initState() {
    super.initState();
    _ctrl = LevelController()..init();
    _surveyorCtrl = SurveyorController();
  }

  @override
  void dispose() {
    _surveyorCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onAlphaChanged(double v) => setState(() {
        _alpha = v;
        _ctrl.alpha = v;
      });

  // Convenience: is the user actively measuring (not idle / onboarding)?
  bool _isActiveSurveyor(SurveyorState s) =>
      s == SurveyorState.aimingBase ||
      s == SurveyorState.lockedBase ||
      s == SurveyorState.result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _DS.obsidian,
      // Prevent the keyboard from resizing the canvas (height input field).
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // ══════════════════════════════════════════════════════════════════
          //  LAYER 0 — Camera preview
          //  CameraPreview sits at the absolute base of the stack.
          //  cameraReady fires ONLY on user action — never at sensor frequency.
          //  RULE: this Positioned must NEVER be inside a high-frequency VLB.
          // ══════════════════════════════════════════════════════════════════
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _surveyorCtrl.cameraReady,
              builder: (_, ready, _) {
                if (!ready || _surveyorCtrl.cameraCtrl == null) {
                  return const SizedBox.shrink();
                }
                return CameraPreview(_surveyorCtrl.cameraCtrl!);
              },
            ),
          ),

          // ── Obsidian overlay — fades to 40 % when camera is live ───────────
          // Keeps the ruler + glass panels readable over the raw camera feed.
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _surveyorCtrl.cameraReady,
              builder: (_, ready, _) => IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  color: _DS.obsidian.withAlpha(ready ? 102 : 255), // 40% / 100%
                ),
              ),
            ),
          ),

          // ══════════════════════════════════════════════════════════════════
          //  LAYER 1 — Static edge rulers (fires once per app start)
          // ══════════════════════════════════════════════════════════════════
          Positioned.fill(
            child: ValueListenableBuilder<RulerMetrics>(
              valueListenable: _ctrl.rulerMetrics,
              builder: (_, metrics, _) =>
                  CustomPaint(painter: _RulerPainter(metrics: metrics)),
            ),
          ),

          // ══════════════════════════════════════════════════════════════════
          //  LAYER 2 — Level canvas (hidden in active surveyor mode)
          // ══════════════════════════════════════════════════════════════════
          Positioned(
            left: _DS.rulerWidth,
            right: _DS.rulerWidth,
            top: 0,
            bottom: 0,
            child: ValueListenableBuilder<SurveyorState>(
              valueListenable: _surveyorCtrl.state,
              builder: (_, sState, _) {
                if (_isActiveSurveyor(sState)) return const SizedBox.shrink();
                return ValueListenableBuilder<bool>(
                  valueListenable: _ctrl.isSurfaceMode,
                  builder: (_, isSurface, _) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    layoutBuilder: (cur, prev) => Stack(
                      fit: StackFit.expand,
                      children: [...prev, ?cur],
                    ),
                    child: isSurface
                        ? _BullsEyeCanvas(
                            key: const ValueKey(true), ctrl: _ctrl)
                        : _TubularCanvas(
                            key: const ValueKey(false), ctrl: _ctrl),
                  ),
                );
              },
            ),
          ),

          // ══════════════════════════════════════════════════════════════════
          //  LAYER 3 — Surveyor crosshair (visible in aimingBase / lockedBase)
          //  CrosshairPainter is static — no sensor VLB needed.
          // ══════════════════════════════════════════════════════════════════
          Positioned(
            left: _DS.rulerWidth,
            right: _DS.rulerWidth,
            top: 0,
            bottom: 0,
            child: ValueListenableBuilder<SurveyorState>(
              valueListenable: _surveyorCtrl.state,
              builder: (_, sState, _) {
                final show = sState == SurveyorState.aimingBase ||
                    sState == SurveyorState.lockedBase;
                if (!show) return const SizedBox.shrink();
                return CustomPaint(
                  painter: _CrosshairPainter(
                    isLocked: sState == SurveyorState.lockedBase,
                  ),
                );
              },
            ),
          ),

          // ══════════════════════════════════════════════════════════════════
          //  LAYER 4 — Top Navigation Controls (Flashlight & Surveyor Exit)
          // ══════════════════════════════════════════════════════════════════
          Positioned(
            top: 20,
            left: _DS.rulerWidth + 12,
            right: _DS.rulerWidth + 12,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Global Flashlight Toggle (Top-Left)
                _FlashlightButton(surveyorCtrl: _surveyorCtrl),

                // Surveyor Exit Navigation (Top-Right, only when active)
                ValueListenableBuilder<SurveyorState>(
                  valueListenable: _surveyorCtrl.state,
                  builder: (_, sState, _) {
                    if (!_isActiveSurveyor(sState)) {
                      return const SizedBox.shrink();
                    }
                    return _SurveyorCloseButton(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _surveyorCtrl.deactivate();
                      },
                    );
                  },
                ),
              ],
            ),
          ),

          // ══════════════════════════════════════════════════════════════════
          //  LAYER 5 — Top panel: inclinometer OR surveyor readings
          //  Switches based on surveyor state (fires on user action only).
          //  The hot-path (20 Hz pitch VLB) lives INSIDE the child widgets.
          // ══════════════════════════════════════════════════════════════════
          Positioned(
            top: 76,
            left: _DS.rulerWidth + 12,
            right: _DS.rulerWidth + 12,
            child: ValueListenableBuilder<SurveyorState>(
              valueListenable: _surveyorCtrl.state,
              builder: (_, sState, _) {
                if (_isActiveSurveyor(sState)) {
                  return _SurveyorTopPanel(
                    surveyorCtrl: _surveyorCtrl,
                    levelCtrl: _ctrl,
                  );
                }
                return _InclinometerReadout(ctrl: _ctrl);
              },
            ),
          ),

          // ══════════════════════════════════════════════════════════════════
          //  LAYER 6 — Bottom: normal dock OR surveyor action panel
          // ══════════════════════════════════════════════════════════════════
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<SurveyorState>(
              valueListenable: _surveyorCtrl.state,
              builder: (_, sState, _) {
                if (_isActiveSurveyor(sState)) {
                  return _SurveyorBottomPanel(
                    surveyorCtrl: _surveyorCtrl,
                    levelCtrl: _ctrl,
                    state: sState,
                  );
                }
                return _ProToolsDock(
                  ctrl: _ctrl,
                  alpha: _alpha,
                  onAlphaChanged: _onAlphaChanged,
                  surveyorCtrl: _surveyorCtrl,
                );
              },
            ),
          ),

          // ══════════════════════════════════════════════════════════════════
          //  LAYER 6 — Onboarding overlay (full-screen, modal-like)
          //  Only visible during the two onboarding states; removed otherwise.
          // ══════════════════════════════════════════════════════════════════
          Positioned.fill(
            child: ValueListenableBuilder<SurveyorState>(
              valueListenable: _surveyorCtrl.state,
              builder: (_, sState, _) {
                final show = sState == SurveyorState.onboardingHeight ||
                    sState == SurveyorState.onboardingGuide;
                if (!show) return const SizedBox.shrink();
                return _SurveyorOnboardingOverlay(
                    surveyorCtrl: _surveyorCtrl);
              },
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
    required this.surveyorCtrl,
  });

  final LevelController ctrl;
  final double alpha;
  final ValueChanged<double> onAlphaChanged;
  final SurveyorController surveyorCtrl;

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
            children: [
              // Tare / Set Baseline
              Expanded(
                child: _DockButton(
                  icon: Icons.straighten_rounded,
                  label: 'SET BASE',
                  onTap: () {
                    ctrl.calibrate();
                    HapticFeedback.selectionClick();
                  },
                ),
              ),
              const SizedBox(width: 6),

              // Reset calibration
              Expanded(
                child: _DockButton(
                  icon: Icons.refresh_rounded,
                  label: 'RESET',
                  onTap: () {
                    ctrl.resetCalibration();
                    HapticFeedback.selectionClick();
                  },
                ),
              ),
              const SizedBox(width: 6),

              // Lock / Freeze — only this button rebuilds
              Expanded(
                child: ValueListenableBuilder<bool>(
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
              ),
              const SizedBox(width: 6),

              // Surveyor — launches the AR measuring tool
              Expanded(
                child: _DockButton(
                  icon: Icons.architecture_rounded,
                  label: 'SURVEYOR',
                  onTap: () {
                    HapticFeedback.selectionClick();
                    surveyorCtrl.activate();
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
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        decoration: BoxDecoration(
          color: _DS.glassWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _DS.glassBorder, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.0,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Glassmorphic floating button for toggling flashlight/torch.
class _FlashlightButton extends StatelessWidget {
  const _FlashlightButton({required this.surveyorCtrl});
  final SurveyorController surveyorCtrl;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: surveyorCtrl.isTorchOn,
      builder: (context, isOn, _) {
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            surveyorCtrl.toggleTorch();
          },
          child: _GlassPanel(
            borderRadius: BorderRadius.circular(14),
            padding: const EdgeInsets.all(10),
            child: Icon(
              isOn ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
              size: 20,
              color: isOn ? _DS.amber : _DS.textDim,
            ),
          ),
        );
      },
    );
  }
}

/// Glassmorphic "X" button for exiting Surveyor mode.
class _SurveyorCloseButton extends StatelessWidget {
  const _SurveyorCloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: _GlassPanel(
        borderRadius: BorderRadius.circular(14),
        padding: const EdgeInsets.all(10),
        child: const Icon(
          Icons.close_rounded,
          size: 20,
          color: _DS.textBright,
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
    super.key,
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
//  SURVEYOR UI — ONBOARDING OVERLAY  (2-screen glassmorphic modal)
// =============================================================================

/// Full-screen overlay displayed during the two onboarding states.
/// Stateful to own the height [TextEditingController] and unit toggle.
class _SurveyorOnboardingOverlay extends StatefulWidget {
  const _SurveyorOnboardingOverlay({required this.surveyorCtrl});
  final SurveyorController surveyorCtrl;

  @override
  State<_SurveyorOnboardingOverlay> createState() =>
      _SurveyorOnboardingOverlayState();
}

class _SurveyorOnboardingOverlayState
    extends State<_SurveyorOnboardingOverlay> {
  late final TextEditingController _heightCtrl;
  bool _isMetric = true;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _heightCtrl = TextEditingController(
      text: widget.surveyorCtrl.userHeightM.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _heightCtrl.dispose();
    super.dispose();
  }

  // Convert current input to metres for storage.
  double? _parsedMetres() {
    final v = double.tryParse(_heightCtrl.text.trim());
    if (v == null || v <= 0) return null;
    return _isMetric ? v : v * 0.3048; // feet → metres
  }

  void _onUnitToggle(bool metric) {
    final current = double.tryParse(_heightCtrl.text.trim()) ?? 1.65;
    final converted = metric ? current * 0.3048 : current / 0.3048;
    setState(() {
      _isMetric = metric;
      _heightCtrl.text = converted.toStringAsFixed(2);
      _validationError = null;
    });
  }

  void _onNext() {
    final metres = _parsedMetres();
    if (metres == null || metres < 0.5 || metres > 3.0) {
      setState(() => _validationError =
          'Enter a realistic height (${_isMetric ? "0.5–3.0 m" : "1.6–9.8 ft"})');
      return;
    }
    widget.surveyorCtrl.completeHeightEntry(metres);
  }

  @override
  Widget build(BuildContext context) {
    // Dim the background (obsidian 70 %) and centre the glass card.
    return Material(
      color: _DS.obsidian.withAlpha(178),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ValueListenableBuilder<SurveyorState>(
              valueListenable: widget.surveyorCtrl.state,
              builder: (_, state, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                transitionBuilder: (child, anim) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.12, 0),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                      parent: anim, curve: Curves.easeOutCubic)),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: state == SurveyorState.onboardingHeight
                    ? _buildHeightScreen()
                    : _buildGuideScreen(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Screen 1: Enter holding height ────────────────────────────────────────
  Widget _buildHeightScreen() {
    return _GlassPanel(
      key: const ValueKey('screen_height'),
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _DS.emerald.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.architecture_rounded,
                    size: 18, color: _DS.emerald),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SURVEYOR',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 2.5,
                          color: _DS.emerald,
                          fontWeight: FontWeight.w600)),
                  Text('Step 1 of 2 — Calibration',
                      style: TextStyle(fontSize: 12, color: _DS.textDim)),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  if (widget.surveyorCtrl.hasOnboarded) {
                    widget.surveyorCtrl.state.value = SurveyorState.aimingBase;
                  } else {
                    widget.surveyorCtrl.deactivate();
                  }
                },
                child: const Icon(Icons.close_rounded,
                    color: _DS.textDim, size: 20),
              ),
            ],
          ),

          const SizedBox(height: 24),
          const Text('Your holding height',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w300,
                  color: _DS.textBright)),
          const SizedBox(height: 6),
          const Text(
            'Enter the height at which you hold the phone '
            '(eye level or arm raised).',
            style: TextStyle(fontSize: 12, color: _DS.textDim, height: 1.5),
          ),

          const SizedBox(height: 20),

          // Unit toggle
          Row(
            children: [
              _UnitChip(
                  label: 'm',
                  selected: _isMetric,
                  onTap: () => _onUnitToggle(true)),
              const SizedBox(width: 8),
              _UnitChip(
                  label: 'ft',
                  selected: !_isMetric,
                  onTap: () => _onUnitToggle(false)),
              const Spacer(),
            ],
          ),

          const SizedBox(height: 12),

          // Height input field
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _DS.glassBorder),
              borderRadius: BorderRadius.circular(12),
              color: Colors.white.withAlpha(8),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              controller: _heightCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w200,
                color: _DS.textBright,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                suffix: Text(
                  _isMetric ? 'm' : 'ft',
                  style: const TextStyle(
                      fontSize: 18, color: _DS.textDim),
                ),
              ),
              onChanged: (_) =>
                  setState(() => _validationError = null),
            ),
          ),

          // Quick-pick presets
          const SizedBox(height: 16),
          const Text('COMMON HEIGHTS',
              style: TextStyle(
                  fontSize: 9, letterSpacing: 2, color: _DS.textDim)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PresetChip(
                  label: 'Eye level  1.65 m',
                  onTap: () => setState(() {
                        _isMetric = true;
                        _heightCtrl.text = '1.65';
                        _validationError = null;
                      })),
              _PresetChip(
                  label: 'Arm raised  2.10 m',
                  onTap: () => setState(() {
                        _isMetric = true;
                        _heightCtrl.text = '2.10';
                        _validationError = null;
                      })),
              _PresetChip(
                  label: 'Chest  1.30 m',
                  onTap: () => setState(() {
                        _isMetric = true;
                        _heightCtrl.text = '1.30';
                        _validationError = null;
                      })),
            ],
          ),

          if (_validationError != null) ...[
            const SizedBox(height: 12),
            Text(_validationError!,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFEF4444))),
          ],

          const SizedBox(height: 24),
          // Next button
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: _onNext,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_DS.emerald, Color(0xFF059669)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                        widget.surveyorCtrl.hasOnboarded
                            ? 'SAVE HEIGHT'
                            : 'NEXT',
                        style: const TextStyle(
                            fontSize: 13,
                            letterSpacing: 2.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    const SizedBox(width: 8),
                    Icon(
                        widget.surveyorCtrl.hasOnboarded
                            ? Icons.check_rounded
                            : Icons.arrow_forward_rounded,
                        size: 16,
                        color: Colors.white),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Screen 2: Quick guide ─────────────────────────────────────────────────
  Widget _buildGuideScreen() {
    return _GlassPanel(
      key: const ValueKey('screen_guide'),
      padding: const EdgeInsets.all(28),      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _DS.amber.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.menu_book_rounded,
                    size: 18, color: _DS.amber),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SURVEYOR',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 2.5,
                          color: _DS.amber,
                          fontWeight: FontWeight.w600)),
                  Text('Step 2 of 2 — Quick Guide',
                      style: TextStyle(fontSize: 12, color: _DS.textDim)),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  if (widget.surveyorCtrl.hasOnboarded) {
                    widget.surveyorCtrl.state.value = SurveyorState.aimingBase;
                  } else {
                    widget.surveyorCtrl.deactivate();
                  }
                },
                child: const Icon(Icons.close_rounded,
                    color: _DS.textDim, size: 20),
              ),
            ],
          ),

          const SizedBox(height: 24),
          const Text('How to measure',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w300,
                  color: _DS.textBright)),

          const SizedBox(height: 20),

          // Step 1 card
          _GuideStep(
            number: '1',
            color: _DS.amber,
            icon: Icons.arrow_downward_rounded,
            title: 'Aim at the BASE',
            body:
                'Point the crosshair at the bottom of the object. '
                'Tap LOCK — the horizontal distance is calculated.',
          ),

          const SizedBox(height: 12),

          // Step 2 card
          _GuideStep(
            number: '2',
            color: _DS.emerald,
            icon: Icons.arrow_upward_rounded,
            title: 'Tilt up to the TOP',
            body:
                'Without moving your feet, tilt the phone up to '
                'the top of the object. Tap LOCK — height is calculated.',
          ),

          const SizedBox(height: 8),

          // Math note
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(6),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _DS.glassBorder),
            ),
            child: const Text(
              'Math:  d = h_eye / tan(α)  ·  H = h_eye + d × tan(β)',
              style: TextStyle(
                  fontSize: 10,
                  color: _DS.textDim,
                  fontFeatures: [FontFeature.tabularFigures()],
                  letterSpacing: 0.4),
            ),
          ),

          const SizedBox(height: 24),

          // Start button
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: widget.surveyorCtrl.startFromGuide,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_DS.emerald, Color(0xFF059669)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.videocam_rounded,
                        size: 18, color: Colors.white),
                    SizedBox(width: 10),
                    Text('START SURVEYING',
                        style: TextStyle(
                            fontSize: 13,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Small helper widgets for the onboarding screens ────────────────────────────

class _UnitChip extends StatelessWidget {
  const _UnitChip(
      {required this.label,
      required this.selected,
      required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? _DS.emerald : Colors.white.withAlpha(12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? _DS.emerald : _DS.glassBorder),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : _DS.textDim)),
        ),
      );
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(8),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _DS.glassBorder),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 11, color: _DS.textDim)),
        ),
      );
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
  });
  final String number;
  final Color color;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withAlpha(12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(8)),
              child: Center(
                child: Text(number,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(icon, size: 13, color: color),
                    const SizedBox(width: 5),
                    Text(title,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ]),
                  const SizedBox(height: 5),
                  Text(body,
                      style: const TextStyle(
                          fontSize: 12,
                          color: _DS.textDim,
                          height: 1.45)),
                ],
              ),
            ),
          ],
        ),
      );
}

// =============================================================================
//  SURVEYOR UI — TOP PANEL  (live readings inside the glass inclinometer slot)
// =============================================================================

/// Replaces the inclinometer readout when the surveyor is actively measuring.
///
/// The outer [ValueListenableBuilder] on [surveyorCtrl.state] fires only on
/// user action. The inner VLB on [levelCtrl.pitch] runs at 20 Hz — only the
/// distance/height number and the angle chip rebuild.
class _SurveyorTopPanel extends StatelessWidget {
  const _SurveyorTopPanel({
    required this.surveyorCtrl,
    required this.levelCtrl,
  });
  final SurveyorController surveyorCtrl;
  final LevelController levelCtrl;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SurveyorState>(
      valueListenable: surveyorCtrl.state,
      builder: (_, state, _) {
        if (state == SurveyorState.result) return _buildResultPanel();
        return _buildLivePanel(state);
      },
    );
  }

  Widget _buildLivePanel(SurveyorState state) {
    final isStep1 = state == SurveyorState.aimingBase;
    return _GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Step label row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isStep1 ? 'STEP 1 OF 2' : 'STEP 2 OF 2',
                style: const TextStyle(
                    fontSize: 10, letterSpacing: 2.4, color: _DS.textDim),
              ),
              Text(
                isStep1 ? 'AIM AT BASE  ↓' : 'AIM AT TOP  ↑',
                style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.8,
                    fontWeight: FontWeight.w600,
                    color: isStep1 ? _DS.amber : _DS.emerald),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Live number — rebuilds at 20 Hz (only this text node)
          ValueListenableBuilder<double>(
            valueListenable: levelCtrl.pitch,
            builder: (_, pitch, _) {
              final calc = surveyorCtrl.calc;
              final valid = calc.isAngleValid(pitch);

              String readout;
              Color color;
              if (isStep1) {
                readout = valid
                    ? '${calc.distance(pitch).toStringAsFixed(2)} m'
                    : '— m';
                color = _DS.textBright;
              } else {
                final d = surveyorCtrl.lockedDistance.value;
                if (d != null && valid) {
                  readout =
                      '${calc.objectHeight(pitch, d).toStringAsFixed(2)} m';
                  color = _DS.emerald;
                } else {
                  readout = '— m';
                  color = _DS.textBright;
                }
              }
              return Text(
                readout,
                style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w100,
                  letterSpacing: -1.5,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  shadows: color == _DS.emerald
                      ? [
                          Shadow(
                              color: _DS.emerald.withAlpha(130),
                              blurRadius: 28),
                          Shadow(
                              color: _DS.emerald.withAlpha(200),
                              blurRadius: 8),
                        ]
                      : null,
                ),
              );
            },
          ),

          // Pitch + locked distance sub-row
          ValueListenableBuilder<double>(
            valueListenable: levelCtrl.pitch,
            builder: (_, pitch, _) => Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'PITCH  ${pitch >= 0 ? '+' : ''}${pitch.toStringAsFixed(1)}°',
                  style: const TextStyle(
                      fontSize: 11,
                      color: _DS.textDim,
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
                if (!isStep1 &&
                    surveyorCtrl.lockedDistance.value != null) ...[
                  const Text('   ·   ',
                      style: TextStyle(color: _DS.steel)),
                  Text(
                    'd = ${surveyorCtrl.lockedDistance.value!.toStringAsFixed(2)} m',
                    style: TextStyle(
                        fontSize: 11,
                        color: _DS.amber,
                        fontFeatures: const [
                          FontFeature.tabularFigures()
                        ]),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Edit Height action button inside Surveyor HUD
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              surveyorCtrl.editHeight();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _DS.glassBorder, width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.height_rounded, size: 13, color: _DS.emerald),
                  const SizedBox(width: 4),
                  Text(
                    'Eye Height: ${surveyorCtrl.userHeightM.toStringAsFixed(2)}m',
                    style: const TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.6,
                      color: _DS.textDim,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.edit_rounded, size: 11, color: _DS.textBright),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultPanel() {
    return ValueListenableBuilder<double?>(
      valueListenable: surveyorCtrl.measuredHeight,
      builder: (_, height, _) => ValueListenableBuilder<double?>(
        valueListenable: surveyorCtrl.lockedDistance,
        builder: (_, distance, _) => _GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('MEASUREMENT COMPLETE',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2.4,
                      color: _DS.emerald,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                height != null
                    ? '${height.toStringAsFixed(2)} m'
                    : '— m',
                style: const TextStyle(
                  fontSize: 58,
                  fontWeight: FontWeight.w100,
                  letterSpacing: -2,
                  color: _DS.emerald,
                  fontFeatures: [FontFeature.tabularFigures()],
                  shadows: [
                    Shadow(
                        color: Color(0x8010B981), blurRadius: 32),
                    Shadow(
                        color: Color(0xCC10B981), blurRadius: 10),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('OBJECT HEIGHT   ',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.8,
                          color: _DS.textDim)),
                  if (distance != null)
                    Text(
                      'distance ${distance.toStringAsFixed(2)} m',
                      style: const TextStyle(
                          fontSize: 10,
                          color: _DS.amber,
                          fontFeatures: [
                            FontFeature.tabularFigures()
                          ]),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  surveyorCtrl.editHeight();
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _DS.glassBorder, width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.height_rounded, size: 13, color: _DS.emerald),
                      const SizedBox(width: 4),
                      Text(
                        'Eye Height: ${surveyorCtrl.userHeightM.toStringAsFixed(2)}m',
                        style: const TextStyle(
                          fontSize: 10,
                          letterSpacing: 0.6,
                          color: _DS.textDim,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.edit_rounded, size: 11, color: _DS.textBright),
                    ],
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
//  SURVEYOR UI — BOTTOM ACTION PANEL  (lock buttons + exit)
// =============================================================================

/// Replaces the Pro-Tools dock when the surveyor is actively measuring.
/// The glass panel is static (BackdropFilter outside all hot-path VLBs).
/// Only the lock button label rebuilds via a state VLB — user-action frequency.
class _SurveyorBottomPanel extends StatelessWidget {
  const _SurveyorBottomPanel({
    required this.surveyorCtrl,
    required this.levelCtrl,
    required this.state,
  });
  final SurveyorController surveyorCtrl;
  final LevelController levelCtrl;
  final SurveyorState state;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(24),
        topRight: Radius.circular(24),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 3,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: _DS.glassBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          if (state == SurveyorState.result) ...[
            // ── Result actions ─────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _SurveyorActionButton(
                    icon: Icons.replay_rounded,
                    label: 'REMEASURE',
                    color: _DS.amber,
                    onTap: surveyorCtrl.remeasure,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SurveyorActionButton(
                    icon: Icons.check_rounded,
                    label: 'DONE',
                    color: _DS.emerald,
                    onTap: surveyorCtrl.deactivate,
                  ),
                ),
              ],
            ),
          ] else ...[
            // ── Step instructions ──────────────────────────────────────────
            Text(
              state == SurveyorState.aimingBase
                  ? 'Point crosshair at the BASE of the object, then lock.'
                  : 'Tilt up to the TOP of the object, then lock.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, color: _DS.textDim, height: 1.4),
            ),
            const SizedBox(height: 16),
            // ── Big LOCK button ────────────────────────────────────────────
            ValueListenableBuilder<double>(
              valueListenable: levelCtrl.pitch,
              builder: (_, pitch, _) {
                final valid = surveyorCtrl.calc.isAngleValid(pitch);
                return GestureDetector(
                  onTap: () {
                    if (!valid) return;
                    if (state == SurveyorState.aimingBase) {
                      surveyorCtrl.lockBase(pitch);
                    } else {
                      surveyorCtrl.lockTop(pitch);
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      gradient: valid
                          ? const LinearGradient(
                              colors: [_DS.emerald, Color(0xFF059669)])
                          : null,
                      color: valid ? null : _DS.steel,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: valid
                          ? [
                              BoxShadow(
                                  color: _DS.emerald.withAlpha(80),
                                  blurRadius: 20,
                                  spreadRadius: 2)
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_rounded,
                            size: 20,
                            color: valid
                                ? Colors.white
                                : Colors.white38),
                        const SizedBox(width: 10),
                        Text(
                          state == SurveyorState.aimingBase
                              ? 'LOCK BASE'
                              : 'LOCK TOP',
                          style: TextStyle(
                            fontSize: 14,
                            letterSpacing: 2.5,
                            fontWeight: FontWeight.w700,
                            color: valid
                                ? Colors.white
                                : Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ── Exit link ──────────────────────────────────────────────────
            GestureDetector(
              onTap: surveyorCtrl.deactivate,
              child: const Text('EXIT SURVEYOR',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2,
                      color: _DS.textDim,
                      decoration: TextDecoration.underline,
                      decorationColor: _DS.textDim)),
            ),
          ],
        ],
      ),
    );
  }
}

class _SurveyorActionButton extends StatelessWidget {
  const _SurveyorActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: color.withAlpha(28),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withAlpha(100)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 1.8,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ],
          ),
        ),
      );
}

// =============================================================================
//  PAINTER : CROSSHAIR  (AR Surveyor overlay — purely static)
// =============================================================================

/// Draws a precision camera crosshair over the level canvas.
/// No sensor data is consumed — [shouldRepaint] only returns true when
/// [isLocked] changes (on user action, not at sensor frequency).
class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter({required this.isLocked});
  final bool isLocked;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;

    final lineColor = isLocked ? _DS.emerald : Colors.white.withAlpha(200);
    final dimColor  = lineColor.withAlpha(40);

    final thinPaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final dimPaint = Paint()
      ..color = dimColor
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    // Full-width horizon guide line
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), dimPaint);

    // Crosshair lines with centre gap
    const gap = 18.0;
    const arm = 52.0;
    // horizontal
    canvas.drawLine(Offset(cx - arm - gap, cy), Offset(cx - gap, cy), thinPaint);
    canvas.drawLine(Offset(cx + gap, cy), Offset(cx + arm + gap, cy), thinPaint);
    // vertical
    canvas.drawLine(Offset(cx, cy - arm - gap), Offset(cx, cy - gap), thinPaint);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, cy + arm + gap), thinPaint);

    // Centre ring
    canvas.drawCircle(Offset(cx, cy), gap - 2, thinPaint..strokeWidth = 1.2);

    // Glow when locked
    if (isLocked) {
      canvas.drawCircle(
        Offset(cx, cy),
        gap + 6,
        Paint()
          ..color = _DS.emerald.withAlpha(55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    // Corner bracket helper
    void bracket(double x, double y, double dx, double dy) {
      const s = 16.0;
      canvas.drawLine(Offset(x, y), Offset(x + dx * s, y), thinPaint..strokeWidth = 1.5);
      canvas.drawLine(Offset(x, y), Offset(x, y + dy * s), thinPaint..strokeWidth = 1.5);
    }

    const m = 44.0; // margin from centre
    bracket(cx - m, cy - m,  1,  1); // top-left
    bracket(cx + m, cy - m, -1,  1); // top-right
    bracket(cx - m, cy + m,  1, -1); // bottom-left
    bracket(cx + m, cy + m, -1, -1); // bottom-right

    // Step labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = TextSpan(
      text: isLocked ? 'STEP 2 — AIM AT TOP' : 'STEP 1 — AIM AT BASE',
      style: TextStyle(
        fontSize: 10,
        letterSpacing: 1.6,
        color: lineColor,
        fontWeight: FontWeight.w500,
      ),
    );
    tp.layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy + arm + gap + 10));
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) => old.isLocked != isLocked;
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
