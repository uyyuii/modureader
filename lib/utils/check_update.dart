import 'package:flutter/widgets.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/update/app_update.dart';
import 'package:anx_reader/widgets/settings/app_update_dialog.dart';

bool _startupChecked = false;
bool _dialogOpen = false;

Future<void> checkUpdate(bool manualCheck) async {
  final updater = AppUpdateController.instance;
  if (!manualCheck) {
    // Opt-out for the automatic startup request. Check here rather than at
    // the call site so every future checkUpdate(false) caller is covered.
    // Do not mark _startupChecked when skipping, so re-enabling the option
    // can still run a check within this session. Manual checks are unaffected.
    if (!Prefs().autoCheckUpdateOnLaunch) return;
    if (_startupChecked) return;
    _startupChecked = true;
    await updater.check();
    // Startup network failures must not interrupt reading or masquerade as
    // "up to date". The About page keeps the status and offers a manual retry.
    if (!updater.newer ||
        updater.phase == UpdatePhase.error ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
  }
  final context = navigatorKey.currentContext;
  if (context == null || !context.mounted || _dialogOpen) return;
  _dialogOpen = true;
  try {
    final dialog = showAppUpdateDialog(context);
    if (manualCheck) await updater.check();
    await dialog;
  } finally {
    _dialogOpen = false;
  }
}
