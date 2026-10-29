import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/host.dart';
import '../core/identity.dart';
import '../core/protocol.dart';
import 'controller.dart';

// Compatibility names for existing importers. New widgets use semantic roles.
const purple = Color(0xFF0066CC);
const ink = Color(0xFF1D1D1F);
const muted = Color(0xFF636366);
const canvas = Color(0xFFF5F5F7);
const line = Color(0xFFE5E5EA);

class _Palette {
  const _Palette(this.dark);
  final bool dark;
  static _Palette of(BuildContext context) =>
      _Palette(Theme.of(context).brightness == Brightness.dark);
  Color get background => dark ? const Color(0xFF101012) : canvas;
  Color get surface => dark ? const Color(0xFF1C1C1E) : Colors.white;
  Color get inset => dark ? const Color(0xFF2C2C2E) : canvas;
  Color get text => dark ? const Color(0xFFF5F5F7) : ink;
  Color get secondary => dark ? const Color(0xFFAEAEB2) : muted;
  Color get action => dark ? const Color(0xFF409CFF) : purple;
  Color get selection =>
      dark ? const Color(0xFF142840) : const Color(0xFFEDF5FF);
  Color get selectedText => dark ? const Color(0xFF80B9FF) : purple;
  Color get separator => dark ? const Color(0xFF3A3A3C) : line;
  Color get outline => dark ? const Color(0xFF8E8E93) : const Color(0xFF86868B);
  Color get success => dark ? const Color(0xFF82D39C) : const Color(0xFF207442);
  Color get warning => dark ? const Color(0xFFF2C66D) : const Color(0xFF855500);
  Color get warningFill =>
      dark ? const Color(0xFF322711) : const Color(0xFFFFF6E5);
  Color get error => dark ? const Color(0xFFFF9A9E) : const Color(0xFFBA2428);
  Color get errorFill =>
      dark ? const Color(0xFF351B1D) : const Color(0xFFFFF0F0);
}

ThemeData appTheme({
  Brightness brightness = Brightness.light,
  bool highContrast = false,
}) {
  final p = _Palette(brightness == Brightness.dark);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.action,
    onPrimary: p.dark ? p.background : Colors.white,
    secondary: p.action,
    onSecondary: p.dark ? p.background : Colors.white,
    error: p.error,
    onError: p.dark ? p.background : Colors.white,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.secondary,
    outline: p.outline,
    outlineVariant: highContrast ? p.outline : p.separator,
    surfaceContainerHighest: p.inset,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: Platform.isWindows ? 'Segoe UI' : null,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  final buttonStyle = ButtonStyle(
    animationDuration: Duration.zero,
    minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
    shape: WidgetStatePropertyAll(shape),
    textStyle: WidgetStatePropertyAll(
      TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        fontFamily: Platform.isWindows ? 'Segoe UI' : null,
      ),
    ),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return p.action.withValues(alpha: .18);
      }
      if (states.contains(WidgetState.pressed)) {
        return p.action.withValues(alpha: .14);
      }
      if (states.contains(WidgetState.hovered)) {
        return p.action.withValues(alpha: .08);
      }
      return null;
    }),
    side: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: p.action, width: 2)
          : null,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: p.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.action.withValues(alpha: .1),
    textTheme: base.textTheme
        .copyWith(
          headlineMedium: TextStyle(
            fontSize: 26,
            height: 1.2,
            letterSpacing: -.3,
            fontWeight: FontWeight.w600,
            color: p.text,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: p.text,
          ),
          titleMedium: TextStyle(
            fontSize: 17,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: p.text,
          ),
          bodyLarge: TextStyle(fontSize: 15, height: 1.5, color: p.text),
          bodyMedium: TextStyle(fontSize: 15, height: 1.5, color: p.text),
          bodySmall: TextStyle(fontSize: 13, height: 1.4, color: p.secondary),
        )
        .apply(fontFamily: Platform.isWindows ? 'Segoe UI' : null),
    iconTheme: IconThemeData(color: p.secondary, size: 20),
    dividerColor: highContrast ? p.outline : p.separator,
    dividerTheme: DividerThemeData(
      color: highContrast ? p.outline : p.separator,
      thickness: 1,
      space: 24,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: buttonStyle.copyWith(
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? BorderSide(color: scheme.onPrimary, width: 2)
              : null,
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return p.inset;
          if (states.contains(WidgetState.pressed)) {
            return p.dark ? const Color(0xFFB8D7FF) : const Color(0xFF003B78);
          }
          if (states.contains(WidgetState.hovered)) {
            return p.dark ? const Color(0xFF80B9FF) : const Color(0xFF004F9E);
          }
          return p.action;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? p.secondary
              : scheme.onPrimary,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonStyle.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? p.secondary : p.action,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused) ? p.action : p.outline,
            width: states.contains(WidgetState.focused) ? 2 : 1,
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: buttonStyle.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? p.secondary : p.action,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: buttonStyle.copyWith(
        padding: const WidgetStatePropertyAll(EdgeInsets.all(10)),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? p.outline : p.secondary,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: TextStyle(color: p.secondary),
      labelStyle: TextStyle(color: p.secondary),
      helperMaxLines: 3,
      errorMaxLines: 4,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: p.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: p.action, width: 2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: highContrast ? p.outline : p.separator),
      ),
      titleTextStyle: TextStyle(
        fontSize: 20,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      contentTextStyle: TextStyle(fontSize: 15, height: 1.5, color: p.text),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.selection,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? p.selectedText
              : p.secondary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 21,
          color: states.contains(WidgetState.selected)
              ? p.selectedText
              : p.secondary,
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.secondary,
      textColor: p.text,
      minVerticalPadding: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : p.surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? p.action : p.outline,
      ),
    ),
  );
}

Future<T?> _showTask<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push<T>(
    _TaskRoute<T>(
      reducedMotion:
          MediaQuery.disableAnimationsOf(context) ||
          FocusManager.instance.highlightMode == FocusHighlightMode.traditional,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (context) {
        final narrow = MediaQuery.sizeOf(context).width < 600;
        final theme = Theme.of(context);
        return themes.wrap(
          SafeArea(
            child: Theme(
              data: theme.copyWith(
                dialogTheme: theme.dialogTheme.copyWith(
                  alignment: narrow ? Alignment.bottomCenter : Alignment.center,
                  insetPadding: EdgeInsets.symmetric(
                    horizontal: narrow ? 16 : 32,
                    vertical: 16,
                  ),
                ),
              ),
              child: Builder(builder: builder),
            ),
          ),
        );
      },
    ),
  );
}

class _TaskRoute<T> extends RawDialogRoute<T> {
  _TaskRoute({
    required WidgetBuilder builder,
    required this.reducedMotion,
    required String label,
  }) : super(
         barrierLabel: label,
         barrierColor: const Color(0x66000000),
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         requestFocus: true,
         transitionDuration: reducedMotion
             ? Duration.zero
             : const Duration(milliseconds: 300),
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionBuilder: (context, animation, secondaryAnimation, child) {
           if (reducedMotion) return child;
           final narrow = MediaQuery.sizeOf(context).width < 600;
           return FadeTransition(
             opacity: animation,
             child: narrow
                 ? SlideTransition(
                     position: animation.drive(
                       Tween(begin: const Offset(0, .045), end: Offset.zero),
                     ),
                     child: child,
                   )
                 : ScaleTransition(
                     scale: animation.drive(Tween(begin: .985, end: 1.0)),
                     child: child,
                   ),
           );
         },
       );
  final bool reducedMotion;

  @override
  Simulation? createSimulation({required bool forward}) {
    if (reducedMotion) return null;
    return SpringSimulation(
      SpringDescription.withDampingRatio(mass: 1, stiffness: 438.65, ratio: 1),
      controller!.value,
      forward ? 1 : 0,
      controller!.velocity,
      tolerance: const Tolerance(distance: .001, velocity: .001),
    );
  }
}

// The button/list tile retains its own gesture, focus, and activation semantics.
// This listener supplies presentation feedback without claiming the gesture.
class _SpringPress extends StatefulWidget {
  const _SpringPress({
    required this.child,
    this.enabled = true,
    this.scale = false,
  });
  final Widget child;
  final bool enabled;
  final bool scale;
  @override
  State<_SpringPress> createState() => _SpringPressState();
}

class _SpringPressState extends State<_SpringPress>
    with SingleTickerProviderStateMixin {
  late final _press = AnimationController.unbounded(vsync: this, value: 0);
  int? _pointer;

  void _target(double value) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _press.value = 0;
      return;
    }
    _press.animateWith(
      SpringSimulation(
        SpringDescription.withDampingRatio(mass: 1, stiffness: 750, ratio: 1),
        _press.value,
        value,
        _press.velocity,
        tolerance: const Tolerance(distance: .001, velocity: .001),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _SpringPress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _pointer = null;
      _press.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _press.value = 0;
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: widget.enabled
        ? (event) {
            if (_pointer != null) return;
            _pointer = event.pointer;
            _target(1);
          }
        : null,
    onPointerMove: (event) {
      if (_pointer != event.pointer) return;
      final box = context.findRenderObject()! as RenderBox;
      _target(
        (Offset.zero & box.size).contains(box.globalToLocal(event.position))
            ? 1
            : 0,
      );
    },
    onPointerUp: (event) {
      if (_pointer != event.pointer) return;
      _pointer = null;
      _target(0);
    },
    onPointerCancel: (event) {
      if (_pointer != event.pointer) return;
      _pointer = null;
      _target(0);
    },
    child: AnimatedBuilder(
      animation: _press,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: (1 - .08 * _press.value).clamp(0.0, 1.0),
        child: Transform.scale(
          scale: widget.scale ? 1 - .015 * _press.value : 1,
          child: child,
        ),
      ),
    ),
  );
}

class ClipboardApp extends StatelessWidget {
  const ClipboardApp({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Hopboard',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    darkTheme: appTheme(brightness: Brightness.dark),
    highContrastTheme: appTheme(highContrast: true),
    highContrastDarkTheme: appTheme(
      brightness: Brightness.dark,
      highContrast: true,
    ),
    themeAnimationDuration: Duration.zero,
    home: ClipboardHome(controller: controller),
  );
}

class ClipboardHome extends StatefulWidget {
  const ClipboardHome({super.key, required this.controller});
  final AppController controller;
  @override
  State<ClipboardHome> createState() => _ClipboardHomeState();
}

class _ClipboardHomeState extends State<ClipboardHome>
    with WidgetsBindingObserver {
  int _tab = 0;
  String? _address;
  bool _invitationVisible = false;
  final _draft = TextEditingController();
  AppController get app => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draft.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!app.mobile) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(app.setForeground(true));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(app.setForeground(false));
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      app.showError(error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final gutter = constraints.maxWidth >= 1120
            ? 32.0
            : wide
            ? 24.0
            : 16.0;
        final p = _Palette.of(context);
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _header(wide, gutter),
                if (app.hosting || app.selectedHost != null) _topbar(wide),
                if (app.busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: SingleChildScrollView(
                    key: PageStorageKey('destination-$_tab'),
                    padding: EdgeInsets.all(gutter),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1200),
                        child: FocusTraversalGroup(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (app.error != null) _errorBanner(),
                              if (app.pendingPair != null &&
                                  !_invitationVisible)
                                _approval(),
                              if (_tab == 0) _home(wide),
                              if (_tab == 1) _session(wide),
                              if (_tab == 2) _devices(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p.separator)),
                  ),
                  child: NavigationBar(
                    selectedIndex: _tab,
                    animationDuration: Duration.zero,
                    onDestinationSelected: (index) =>
                        setState(() => _tab = index),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.link_rounded),
                        label: 'Connections',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.content_paste_outlined),
                        label: 'Clipboard',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.devices_outlined),
                        label: 'Devices',
                      ),
                    ],
                  ),
                ),
        );
      },
    ),
  );

  Widget _header(bool wide, double gutter) {
    final p = _Palette.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.content_paste_outlined, size: 21),
        const SizedBox(width: 10),
        const Flexible(
          child: Text(
            'Hopboard',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -.2,
            ),
          ),
        ),
      ],
    );
    final name = Text(
      app.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 13, color: p.secondary),
    );
    final tabs = Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final destination in [
          'Connections',
          'Clipboard',
          'Devices',
        ].indexed)
          Semantics(
            selected: _tab == destination.$1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: _tab == destination.$1
                        ? p.action
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: TextButton(
                key: ValueKey('destination-${destination.$1}'),
                style: TextButton.styleFrom(
                  foregroundColor: _tab == destination.$1
                      ? p.action
                      : p.secondary,
                ),
                onPressed: () => setState(() => _tab = destination.$1),
                child: Text(destination.$2),
              ),
            ),
          ),
      ],
    );
    return Material(
      color: p.surface,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.separator)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(flex: 2, child: brand),
                if (wide && !largeText)
                  Expanded(flex: 5, child: Center(child: tabs))
                else
                  const Spacer(),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: name),
              ],
            ),
            if (wide && largeText) ...[const SizedBox(height: 12), tabs],
          ],
        ),
      ),
    );
  }

  Widget _columns({
    required String id,
    required Widget main,
    required Widget secondary,
    bool secondaryFirst = false,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final split =
          MediaQuery.sizeOf(context).width >= 1120 &&
          constraints.maxWidth >= 1000 &&
          MediaQuery.textScalerOf(context).scale(15) <= 20;
      if (!split) {
        return Column(
          key: ValueKey('$id-stacked'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: secondaryFirst
              ? [secondary, const SizedBox(height: 32), main]
              : [main, const SizedBox(height: 24), secondary],
        );
      }
      return Row(
        key: ValueKey('$id-split'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: main),
          const SizedBox(width: 24),
          Container(
            width: 345,
            padding: const EdgeInsets.only(left: 24),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: _Palette.of(context).separator),
              ),
            ),
            child: secondary,
          ),
        ],
      );
    },
  );

  Widget _topbar(bool wide) {
    final p = _Palette.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 16, vertical: 8),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.separator)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              app.status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: app.paused ? p.warning : p.secondary,
              ),
            ),
          ),
          if (app.hosting || app.selectedHost != null) ...[
            if (wide && app.hosting)
              TextButton.icon(
                onPressed: _invite,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add device'),
              ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: app.paused ? 'Resume sharing' : 'Pause sharing',
              onPressed: () => _run(() => app.setPaused(!app.paused)),
              icon: Icon(
                app.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: p.action,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Session actions',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) {
                if (action == 'invite' && app.hosting) {
                  _invite();
                }
                if (action == 'leave') {
                  _run(app.leave);
                }
              },
              itemBuilder: (context) => [
                if (app.hosting)
                  const PopupMenuItem(
                    value: 'invite',
                    child: Text('Add device'),
                  ),
                PopupMenuItem(
                  value: 'leave',
                  child: Text(app.hosting ? 'Stop session' : 'Leave session'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(String text, Color color, IconData icon) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: color),
      const SizedBox(width: 6),
      Flexible(
        child: Text(text, style: TextStyle(fontSize: 13, color: color)),
      ),
    ],
  );

  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(20)}) =>
      // A Material, not a coloured box, so ListTiles inside show tap feedback.
      Material(
        color: _Palette.of(context).surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: MediaQuery.highContrastOf(context)
              ? BorderSide(color: _Palette.of(context).outline)
              : BorderSide.none,
        ),
        child: SizedBox(
          width: double.infinity,
          child: Padding(padding: padding, child: child),
        ),
      );

  Widget _group(Widget child) => Material(
    color: Colors.transparent,
    child: SizedBox(width: double.infinity, child: child),
  );

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
    ),
  );

  Widget _home(bool wide) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading('Connections'),
      _columns(
        id: 'connections',
        secondaryFirst: true,
        main: _group(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                app.hosting || app.selectedHost != null
                    ? 'This session'
                    : 'This device',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices_outlined),
                title: Text(app.name),
                subtitle: app.hosting || app.selectedHost != null
                    ? const Text('This device')
                    : null,
                trailing: app.hosting
                    ? _pill(
                        'Host',
                        _Palette.of(context).action,
                        Icons.wifi_tethering,
                      )
                    : null,
              ),
              for (final device in app.members.where(
                (device) => device['id'] != app.identity.id,
              ))
                _memberRow(device, manage: false),
              if (app.trust.hosts.isNotEmpty) ...[
                const SizedBox(height: 24),
                Divider(color: _Palette.of(context).separator),
                const SizedBox(height: 16),
                _savedHosts(),
              ],
            ],
          ),
        ),
        secondary: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (app.hosting || app.selectedHost != null) ...[
              Text('Session', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text(
                app.paused
                    ? 'Sharing paused'
                    : app.automatic
                    ? 'Automatic sharing enabled'
                    : 'Manual sharing · you choose what to send',
                style: TextStyle(color: _Palette.of(context).secondary),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => setState(() => _tab = 1),
                child: const Text('Open clipboard'),
              ),
              const SizedBox(height: 16),
              ExpansionTile(
                key: const PageStorageKey('change-connection'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Change connection'),
                children: [
                  _joinCard(),
                  const SizedBox(height: 24),
                  _hostCard(),
                ],
              ),
            ] else ...[
              _joinCard(),
              const SizedBox(height: 24),
              Divider(color: _Palette.of(context).separator),
              const SizedBox(height: 24),
              _hostCard(),
            ],
            if (Platform.isWindows)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(
                  'Closing this window keeps Hopboard in the system tray. Choose Quit in the tray menu to stop it.',
                  style: TextStyle(
                    color: _Palette.of(context).secondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            if (app.mobile && app.hosting)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  'Keep the app open while this phone hosts.',
                  style: TextStyle(color: _Palette.of(context).secondary),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _savedHosts() => _group(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Saved hosts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final saved in app.trust.hosts.values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices_outlined),
            title: Text(saved.name),
            subtitle: Text(
              app.discovery.hosts.containsKey(saved.id)
                  ? 'Nearby on your network'
                  : saved.address,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: app.busy
                ? null
                : () => _run(() async {
                    await app.joinSaved(saved);
                    if (mounted) setState(() => _tab = 1);
                  }),
          ),
      ],
    ),
  );

  Widget _hostCard() {
    final addresses = app.interfaces.map((i) => i.address).toSet();
    if (_address == null || !addresses.contains(_address)) {
      _address = addresses.firstOrNull;
    }
    return _group(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Start a session',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 9),
          Text(
            'Choose the local network this device will host on.',
            style: TextStyle(
              color: _Palette.of(context).secondary,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 22),
          if (app.interfaces.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: _address,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Local network'),
              items: app.interfaces
                  .map(
                    (i) => DropdownMenuItem(
                      value: i.address,
                      child: Text(
                        '${i.address} · ${i.name}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: app.busy
                  ? null
                  : (value) => setState(() => _address = value),
            ),
          if (app.interfaces.isEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Connect to Wi-Fi to start.',
                    style: TextStyle(color: _Palette.of(context).secondary),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh networks',
                  onPressed: app.networkChanged,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: app.busy || _address == null || app.hosting
                  ? null
                  : () => _run(() async {
                      final interface = app.interfaces.firstWhere(
                        (i) => i.address == _address,
                      );
                      await app.startHost(interface);
                      if (mounted) setState(() => _tab = 1);
                    }),
              icon: const Icon(Icons.add_rounded, size: 19),
              label: const Text('Start session'),
            ),
          ),
          const SizedBox(height: 11),
          Text(
            app.mobile
                ? 'Keep the app open while this phone hosts.'
                : 'Best for a device that stays awake.',
            style: TextStyle(
              color: _Palette.of(context).secondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _joinCard() => _group(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Join a session', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Connect both devices to the same Wi-Fi.',
          style: TextStyle(color: _Palette.of(context).secondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _SpringPress(
              enabled: !app.busy,
              scale: true,
              child: FilledButton(
                onPressed: app.busy ? null : _manualJoin,
                child: const Text('Enter pairing code'),
              ),
            ),
            if (app.mobile)
              OutlinedButton.icon(
                onPressed: app.busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 19),
                label: const Text('Scan pairing code'),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _session(bool wide) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading('Clipboard'),
      if (!app.hosting && app.selectedHost == null)
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Start or join a session first.'),
            OutlinedButton(
              onPressed: () => setState(() => _tab = 0),
              child: const Text('Connect devices'),
            ),
          ],
        ),
      const SizedBox(height: 20),
      if (app.canAutomatic)
        _card(
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Automatic clipboard sharing',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              Platform.isWindows
                  ? 'Copy text in any app. Your connected devices receive it automatically.'
                  : 'Sync clipboard changes while Hopboard is open and focused.',
              style: TextStyle(
                fontSize: 13,
                color: _Palette.of(context).secondary,
              ),
            ),
            value: app.automatic,
            onChanged: _automatic,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        ),
      const SizedBox(height: 20),
      _columns(
        id: 'clipboard',
        main: _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.arrow_downward_rounded,
                    size: 19,
                    color: _Palette.of(context).action,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Latest shared text',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (app.item != null)
                    Flexible(
                      child: Text(
                        'From ${app.item!.senderName}',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 13,
                          color: _Palette.of(context).secondary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(
                  minHeight: 180,
                  maxHeight: 360,
                ),
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: app.item == null
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'No shared text yet',
                          style: TextStyle(
                            color: _Palette.of(context).secondary,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        child: SelectableText(
                          app.item!.text,
                          style: const TextStyle(fontSize: 15, height: 1.55),
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 18,
                runSpacing: 12,
                children: [
                  Text(
                    app.itemStatus,
                    style: TextStyle(
                      fontSize: 13,
                      color: _Palette.of(context).secondary,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: app.item == null || app.paused
                        ? null
                        : () => _run(app.copyReceived),
                    icon: const Icon(Icons.copy_rounded, size: 17),
                    label: const Text('Copy'),
                  ),
                ],
              ),
              if (app.conflictText != null) ...[
                const SizedBox(height: 18),
                Divider(color: _Palette.of(context).separator),
                const SizedBox(height: 10),
                Text(
                  'Your local copy was preserved. Choose which text to share.',
                  style: TextStyle(
                    color: _Palette.of(context).secondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: app.item == null
                          ? null
                          : () => _run(app.copyReceived),
                      child: const Text('Use received text'),
                    ),
                    OutlinedButton(
                      onPressed: !app.sharing || app.sending
                          ? null
                          : () => _run(app.sendMine),
                      child: const Text('Send my text'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        secondary: _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Send text',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),

              const SizedBox(height: 20),
              TextField(
                controller: _draft,
                minLines: 3,
                maxLines: 8,
                maxLength: 65536,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  hintText: 'Type text…',
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        !app.sharing || app.sending || _draft.text.isEmpty
                        ? null
                        : () => _run(() => app.sendText(_draft.text)),
                    icon: Icon(
                      app.sending
                          ? Icons.hourglass_top_rounded
                          : Icons.arrow_upward_rounded,
                      size: 17,
                    ),
                    label: Text(
                      app.sending ? 'Confirming delivery…' : 'Send text',
                    ),
                  ),
                  if (Platform.isIOS && app.sharing) ...[
                    Text(
                      'Paste & send immediately',
                      style: TextStyle(
                        fontSize: 13,
                        color: _Palette.of(context).secondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const SizedBox(
                      width: 175,
                      height: 52,
                      child: UiKitView(viewType: 'dev.localclipboard/paste'),
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: !app.sharing || app.sending
                          ? null
                          : () => _run(app.pasteAndSend),
                      icon: const Icon(
                        Icons.content_paste_go_rounded,
                        size: 18,
                      ),
                      label: const Text('Paste & Send'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (app.hosting && app.mobile)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: _card(
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Keep screen awake',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Phone hosting stops when the app goes into the background.',
                style: TextStyle(
                  fontSize: 13,
                  color: _Palette.of(context).secondary,
                ),
              ),
              value: app.keepScreenAwake,
              onChanged: (value) => _run(() => app.setKeepAwake(value)),
            ),
          ),
        ),
    ],
  );

  Widget _devices() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading('Devices'),
      _group(
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.devices_rounded,
            color: _Palette.of(context).action,
          ),
          title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('This device'),
          trailing: IconButton(
            tooltip: 'Rename device',
            onPressed: app.hosting || app.selectedHost != null ? null : _rename,
            icon: const Icon(Icons.edit_outlined, size: 19),
          ),
        ),
      ),
      const SizedBox(height: 20),
      _group(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'This session',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                if (app.hosting)
                  FilledButton.icon(
                    onPressed: _invite,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add device'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (app.members.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'Start or join a session to see connected devices.',
                  style: TextStyle(
                    color: _Palette.of(context).secondary,
                    fontSize: 13,
                  ),
                ),
              ),
            for (final device in app.members) _memberRow(device),
            if (app.hosting) ...[
              Divider(color: _Palette.of(context).separator),
              TextButton.icon(
                onPressed: () async {
                  final host = app.host;
                  if (host == null) return;
                  final confirmed = await _confirmChange(
                    'Clear shared text?',
                    'This removes the shared text from the session. It does not erase OS clipboards or clipboard histories.',
                    'Clear text',
                  );
                  if (confirmed && mounted && app.host == host) {
                    host.engine.clear();
                  }
                },
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: const Text('Clear shared text'),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 20),
      _group(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Saved hosts',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (app.trust.hosts.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'Nothing paired yet. Join a session to get started.',
                  style: TextStyle(
                    color: _Palette.of(context).secondary,
                    fontSize: 13,
                  ),
                ),
              ),
            for (final saved in app.trust.hosts.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.verified_user_outlined,
                  color: _Palette.of(context).action,
                ),
                title: Text(
                  saved.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${saved.address}:${saved.port}',
                  style: TextStyle(
                    color: _Palette.of(context).secondary,
                    fontSize: 13,
                  ),
                ),
                onTap: () => _run(() async {
                  await app.joinSaved(saved);
                  if (mounted) setState(() => _tab = 1);
                }),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Update address',
                      onPressed: () => _editAddress(saved),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Forget host',
                      onPressed: () async {
                        if (await _confirmChange(
                              'Forget host?',
                              'You will need to pair with ${saved.name} again to reconnect.',
                              'Forget host',
                            ) &&
                            mounted) {
                          await _run(() => app.forgetHost(saved));
                        }
                      },
                      icon: const Icon(Icons.delete_outline_rounded, size: 19),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _memberRow(
    Map<String, dynamic> device, {
    bool manage = true,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 5),
    leading: const Icon(Icons.devices_outlined),
    title: Text(
      '${device['name']}${device['id'] == app.identity.id ? ' (you)' : ''}',
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      device['online'] == true
          ? _receiptLabel(device['status'] as String?)
          : 'Offline',
      style: TextStyle(fontSize: 13, color: _Palette.of(context).secondary),
    ),
    trailing: device['host'] == true
        ? _pill('Host', _Palette.of(context).action, Icons.wifi_tethering)
        : app.hosting && manage
        ? IconButton(
            tooltip: 'Revoke access',
            icon: Icon(
              Icons.link_off_rounded,
              size: 20,
              color: _Palette.of(context).secondary,
            ),
            onPressed: () async {
              final host = app.host;
              if (host == null) return;
              final confirmed = await _confirmChange(
                'Revoke access?',
                '${device['name']} will need to pair again to join this host.',
                'Revoke access',
              );
              if (confirmed && mounted && app.host == host) {
                await _run(() => host.revoke(device['id'] as String));
              }
            },
          )
        : null,
  );

  String _receiptLabel(String? status) => switch (status) {
    'applied' => 'Ready to paste',
    'needsAction' => 'Available · copy on this device',
    'failed' => 'Clipboard needs attention',
    'paused' => 'Sharing paused',
    _ => 'Connected · available in app',
  };

  Widget _errorBanner() => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
        decoration: BoxDecoration(
          color: _Palette.of(context).errorFill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              color: _Palette.of(context).error,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                app.error!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: _Palette.of(context).error,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: app.dismissError,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _approval() => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${app.pendingPair!.name} wants to join',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _PairDetails(app.pendingPair!),
          Text(
            'Accept only if you are pairing this device right now.',
            style: TextStyle(
              color: _Palette.of(context).secondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            children: [
              FilledButton(
                onPressed: () => app.pendingPair?.decide(true),
                child: const Text('Accept device'),
              ),
              OutlinedButton(
                onPressed: () => app.pendingPair?.decide(false),
                child: const Text('Decline'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Future<bool> _confirmChange(
    String title,
    String message,
    String action,
  ) async =>
      await _showTask<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: _Palette.of(context).error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _automatic(bool enabled) async {
    if (enabled) {
      final consent = await _showTask<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Enable automatic sharing?'),
          content: const Text(
            'New text you copy will be sent to every trusted member of this session. Incoming text can replace your clipboard. Pause sharing before copying anything private.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable sharing'),
            ),
          ],
        ),
      );
      if (consent != true) return;
    }
    await _run(() => app.setAutomatic(enabled));
  }

  Future<void> _manualJoin() async {
    final result = await _showTask<Object>(
      context: context,
      builder: (_) => _CodeJoinDialog(app: app),
    );
    if (result == 'advanced') {
      await _fullInvitationJoin();
    } else if (result is _CodeJoinResult) {
      await _run(() async {
        await app.pairWithCode(result.code, result.address, result.port);
        if (mounted) setState(() => _tab = 1);
      });
    }
  }

  Future<void> _fullInvitationJoin() async {
    final input = TextEditingController();
    final value = await _showTask<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Join a session'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'On the host, choose Add device and copy the invitation. Paste the complete invitation below.',
                style: TextStyle(
                  color: _Palette.of(context).secondary,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: input,
                maxLines: 5,
                maxLength: 4096,
                decoration: const InputDecoration(
                  labelText: 'Full invitation',
                  hintText: 'Paste invitation…',
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    // The dialog exit animation may still reference its controller.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (value == null) return;
    await _run(() async {
      await app.pair(value);
      if (mounted) setState(() => _tab = 1);
    });
  }

  Future<void> _scan() async {
    final invitation = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    if (invitation != null) {
      await _run(() async {
        await app.pair(invitation);
        if (mounted) setState(() => _tab = 1);
      });
    }
  }

  Future<void> _invite() async {
    app.newInvitation();
    final invite = app.invitation;
    if (invite == null) return;
    setState(() => _invitationVisible = true);
    try {
      await _showTask<void>(
        context: context,
        builder: (context) => _InviteDialog(app: app),
      );
    } finally {
      app.closeInvitation();
      if (mounted) setState(() => _invitationVisible = false);
    }
  }

  Future<void> _rename() async {
    final input = TextEditingController(text: app.name);
    final value = await _showTask<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Name this device'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (value != null) await _run(() => app.rename(value));
  }

  Future<void> _editAddress(SavedHost saved) async {
    final address = TextEditingController(text: saved.address);
    final port = TextEditingController(text: saved.port.toString());
    final changed = await _showTask<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Update host address'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The saved host identity stays pinned. A different device cannot use this pairing.',
                style: TextStyle(
                  color: _Palette.of(context).secondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: address,
                decoration: const InputDecoration(
                  labelText: 'Local IP address',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (changed == true) {
      await _run(() async {
        final parsed = int.tryParse(port.text);
        if (!isLocalAddress(address.text.trim()) ||
            parsed == null ||
            parsed < 1 ||
            parsed > 65535) {
          throw const FormatException(
            'Enter a valid local IP address and port.',
          );
        }
        saved.address = address.text.trim();
        saved.port = parsed;
        await app.trust.save();
        await app.joinSaved(saved);
      });
    }
    Future<void>.delayed(const Duration(seconds: 1), () {
      address.dispose();
      port.dispose();
    });
  }
}

class _CodeJoinResult {
  const _CodeJoinResult(this.code, this.address, this.port);
  final String code;
  final String address;
  final int port;
}

class _CodeJoinDialog extends StatefulWidget {
  const _CodeJoinDialog({required this.app});
  final AppController app;
  @override
  State<_CodeJoinDialog> createState() => _CodeJoinDialogState();
}

class _CodeJoinDialogState extends State<_CodeJoinDialog> {
  final _code = TextEditingController();
  final _address = TextEditingController();
  String? _selected;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) {
      final hosts = widget.app.discovery.hosts.values
          .where((host) => host.id != widget.app.identity.id)
          .toList();
      final chosen = hosts.any((host) => 'host:${host.id}' == _selected)
          ? _selected
          : _selected == 'manual' || hosts.isEmpty
          ? 'manual'
          : hosts.length == 1
          ? 'host:${hosts.single.id}'
          : null;
      return AlertDialog(
        scrollable: true,
        title: const Text('Enter pairing code'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'On the first device, choose Add device. Select that host here and enter its six-digit code.',
                  style: TextStyle(
                    color: _Palette.of(context).secondary,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'nearby-$chosen-${hosts.map((host) => host.id).join(',')}',
                  ),
                  initialValue: chosen,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Host device'),
                  hint: const Text('Choose a nearby host'),
                  items: [
                    for (final host in hosts)
                      DropdownMenuItem(
                        value: 'host:${host.id}',
                        child: Text(
                          '${host.name} · ${host.address}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const DropdownMenuItem(
                      value: 'manual',
                      child: Text('Enter host address instead'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _selected = value),
                ),
                if (chosen == 'manual') ...[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _address,
                    key: const ValueKey('pair-address'),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Host address',
                      hintText: '192.168.1.5',
                      helperText: 'Shown below the code on the host.',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  autofocus: true,
                  key: const ValueKey('pair-code'),
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  style: const TextStyle(
                    fontSize: 24,
                    letterSpacing: 2,
                    fontFeatures: [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Six-digit code',
                    hintText: '000000',
                  ),
                  onSubmitted: (_) => _connect(
                    chosen,
                    hosts
                        .map((host) => (host.id, host.address, host.port))
                        .toList(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Both devices need the same Wi-Fi. Approve the connection on the host after entering the code.',
                  style: TextStyle(
                    color: _Palette.of(context).secondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'advanced'),
                  child: const Text('Use full invitation instead'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => _connect(
              chosen,
              hosts.map((host) => (host.id, host.address, host.port)).toList(),
            ),
            child: const Text('Connect'),
          ),
        ],
      );
    },
  );

  void _connect(String? chosen, List<(String, String, int)> hosts) {
    if (_code.text.length != 6) {
      setState(() => _error = 'Enter all six digits shown on the host.');
      return;
    }
    if (chosen == null) {
      setState(() => _error = 'Choose the host you want to join.');
      return;
    }
    String address;
    int port;
    if (chosen == 'manual') {
      final parts = _address.text.trim().split(':');
      address = parts.first;
      port = parts.length == 2 ? int.tryParse(parts.last) ?? 0 : defaultPort;
      if (parts.length > 2 ||
          !isLocalAddress(address) ||
          port < 1 ||
          port > 65535) {
        setState(
          () => _error = 'Enter the local IPv4 address shown on the host, with its port if shown.',
        );
        return;
      }
    } else {
      final selected = hosts.firstWhere((host) => 'host:${host.$1}' == chosen);
      address = selected.$2;
      port = selected.$3;
    }
    Navigator.pop(context, _CodeJoinResult(_code.text, address, port));
  }
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.app});
  final AppController app;
  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  Timer? _timer;
  bool _copied = false;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) => _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final host = widget.app.host;
    final remaining = host?.inviteRemaining.inSeconds ?? 0;
    final code = host?.pairCode;
    final payload = widget.app.invitation?.encode() ?? '';
    final request = widget.app.pendingPair;
    return AlertDialog(
      title: const Text('Add device'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'On your other PC, choose Enter pairing code and select this host. On a phone, you can also scan the QR code. Both devices need the same Wi-Fi.',
                style: TextStyle(
                  color: _Palette.of(context).secondary,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 18),
              if (remaining > 0 && code != null) ...[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    '${code.substring(0, 3)} ${code.substring(3)}',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: _Palette.of(context).action,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.app.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                SelectableText(
                  '${host!.address}:${host.port}',
                  style: TextStyle(
                    fontSize: 13,
                    color: _Palette.of(context).secondary,
                  ),
                ),
                const SizedBox(height: 12),
                if (host.codeExhausted)
                  Text(
                    'Code attempt limit reached. Create a new code below, or scan the QR.',
                    style: TextStyle(
                      fontSize: 13,
                      color: _Palette.of(context).secondary,
                    ),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await widget.app.copyInvitation(code);
                        if (mounted) setState(() => _copied = true);
                      } catch (error) {
                        widget.app.showError(error);
                      }
                    },
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 17,
                    ),
                    label: Text(_copied ? 'Code copied' : 'Copy code'),
                  ),
                const SizedBox(height: 10),
              ],
              if (remaining > 0)
                QrImageView(
                  data: payload,
                  size: (MediaQuery.sizeOf(context).width - 112).clamp(
                    160.0,
                    240.0,
                  ),
                  backgroundColor: Colors.white,
                )
              else
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'Invitation expired. Close this window and create a new one.',
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                remaining > 0
                    ? 'One use · expires in ${remaining}s'
                    : 'Expired',
                style: TextStyle(
                  color: _Palette.of(context).secondary,
                  fontSize: 13,
                ),
              ),
              if (request != null) ...[
                const SizedBox(height: 16),
                Text(
                  '${request.name} wants to join',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                _PairDetails(request),
                const SizedBox(height: 8),
                const Text(
                  'Accept only if you are pairing this device right now.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  children: [
                    FilledButton(
                      onPressed: () => request.decide(true),
                      child: const Text('Accept device'),
                    ),
                    TextButton(
                      onPressed: () => request.decide(false),
                      child: const Text('Decline'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: request != null
                    ? null
                    : () {
                        setState(() => _copied = false);
                        widget.app.newInvitation();
                      },
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Create new code'),
              ),
              ExpansionTile(
                title: const Text(
                  'Manual connection details',
                  style: TextStyle(fontSize: 13),
                ),
                children: [
                  SelectableText(
                    payload,
                    style: TextStyle(
                      fontSize: 13,
                      color: _Palette.of(context).secondary,
                    ),
                  ),
                  TextButton(
                    onPressed: remaining <= 0
                        ? null
                        : () async {
                            try {
                              await widget.app.copyInvitation(payload);
                            } catch (error) {
                              widget.app.showError(error);
                            }
                          },
                    child: const Text('Copy full invitation'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;
  final _scanner = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  @override
  void dispose() {
    unawaited(_scanner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan pairing code')),
    body: Stack(
      children: [
        MobileScanner(
          controller: _scanner,
          onDetect: (capture) {
            final text = capture.barcodes.firstOrNull?.rawValue;
            if (!_done && text != null && text.contains('localclipboard')) {
              _done = true;
              Navigator.pop(context, text);
            }
          },
          errorBuilder: (context, error) => const Center(
            child: Padding(
              padding: EdgeInsets.all(30),
              child: Text(
                'Camera unavailable. Allow camera access in Settings, or go back and enter the six-digit pairing code.',
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(30),
            child: Text(
              'Point your camera at the code on the host device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                backgroundColor: Colors.black54,
                height: 1.8,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// What the host knows about a pairing request beyond its self-chosen name.
class _PairDetails extends StatelessWidget {
  const _PairDetails(this.request);
  final PairRequest request;

  @override
  Widget build(BuildContext context) {
    final replaces = request.replaces;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (request.address != null)
            Text(
              'From ${request.address}',
              style: TextStyle(
                color: _Palette.of(context).secondary,
                fontSize: 13,
              ),
            ),
          if (replaces != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'This replaces the saved device "$replaces". Decline unless you are re-pairing that device.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
