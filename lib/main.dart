import 'package:flutter/material.dart';

import 'app/controller.dart';
import 'app/ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Bootstrap());
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<AppController> _load = AppController.load();
  AppController? _controller;
  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Reset this device?'),
        content: const Text(
          'This deletes this device\'s identity and all of its pairings. '
          'Remove it from your other devices, then pair again. '
          'Use this only if Try again keeps failing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(
      () => _load = AppController.resetStorage().then(
        (_) => AppController.load(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppController>(
    future: _load,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        _controller = snapshot.data;
        return ClipboardApp(controller: snapshot.data!);
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        darkTheme: appTheme(brightness: Brightness.dark),
        highContrastTheme: appTheme(highContrast: true),
        highContrastDarkTheme: appTheme(
          brightness: Brightness.dark,
          highContrast: true,
        ),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.content_paste_outlined, size: 32),
                        const SizedBox(height: 24),
                        Text(
                          snapshot.hasError
                              ? 'Could not open secure storage'
                              : 'Opening LocalClipboard…',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        if (!snapshot.hasError)
                          const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (snapshot.hasError) ...[
                          const Text(
                            'Check that your device credential store is available, then try again.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: () =>
                                setState(() => _load = AppController.load()),
                            child: const Text('Try again'),
                          ),
                          if (snapshot.error is StorageFailure) ...[
                            const SizedBox(height: 8),
                            // Inside MaterialApp, so the dialog finds a Navigator.
                            Builder(
                              builder: (context) => TextButton(
                                onPressed: () => _confirmReset(context),
                                child: const Text('Reset this device…'),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
