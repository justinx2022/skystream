import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_world.dart';

/// Which world the shell is currently showing.
///
/// Written by [AppScaffold] from the branch index and read by `main.dart` when
/// it builds the themes, so the whole tree - dialogs and sheets included -
/// carries the world's surfaces rather than only the branch's subtree. SKY is
/// the default because it is the branch the app opens on.
final appWorldProvider = NotifierProvider<AppWorldController, AppWorld>(
  AppWorldController.new,
);

class AppWorldController extends Notifier<AppWorld> {
  @override
  AppWorld build() => AppWorld.sky;

  /// No-ops when the world has not changed, so a shell rebuild does not churn
  /// every theme consumer.
  void setWorld(AppWorld world) {
    if (state == world) return;
    state = world;
  }
}
