import 'dart:async';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'notification_service.g.dart';

@Riverpod(keepAlive: true)
NotificationService notificationService(Ref ref) {
  return NotificationService();
}

enum ToastType { info, success, error, extension }

/// [ChangeNotifier] only exposes `notifyListeners` to its own subclasses, so
/// the one call site gets a name it is allowed to use.
class _NotificationListeners extends ChangeNotifier {
  void emit() => notifyListeners();
}

class ToastItem {
  final String id;
  final String? title;
  final String message;
  final ToastType type;
  final IconData? icon;
  final Widget? leading;
  final Duration duration;
  final VoidCallback? onAction;
  final String? actionLabel;
  final DateTime createdAt;

  ToastItem({
    required this.id,
    this.title,
    required this.message,
    this.type = ToastType.info,
    this.icon,
    this.leading,
    this.duration = const Duration(milliseconds: 3000),
    this.onAction,
    this.actionLabel,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

/// A global service to manage UI notifications (Material 3 Expressive Toasts & SnackBars)
/// without needing a [BuildContext].
///
/// A [Listenable], not a [ChangeNotifier], even though the listener set is a
/// ChangeNotifier underneath. riverpod_lint's unsupported_provider_value
/// reports on a provider that hands out a ChangeNotifier, and reporting it
/// crashes the analysis server against analyzer 14.4.0 - the lint passes a
/// message argument the registered message does not take - so a type that is
/// not one keeps `dart analyze` working. Every caller only ever needed to
/// listen, and that is unchanged.
class NotificationService implements Listenable {
  final _NotificationListeners _listeners = _NotificationListeners();

  @override
  void addListener(VoidCallback listener) => _listeners.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _listeners.removeListener(listener);

  void notifyListeners() => _listeners.emit();

  /// Drops every listener. Left as a public method because
  /// [ChangeNotifier.dispose] used to be inherited; nothing in the app calls
  /// it, a test does.
  void dispose() => _listeners.dispose();

  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  final List<ToastItem> _toasts = [];
  List<ToastItem> get toasts => List.unmodifiable(_toasts);

  static const int maxToasts = 4;
  final Map<String, Timer> _dismissTimers = {};

  void showToast({
    String? title,
    required String message,
    ToastType type = ToastType.info,
    IconData? icon,
    Widget? leading,
    Duration duration = const Duration(milliseconds: 3000),
    VoidCallback? onAction,
    String? actionLabel,
  }) {
    final id = UniqueKey().toString();
    final item = ToastItem(
      id: id,
      title: title,
      message: message,
      type: type,
      icon: icon,
      leading: leading,
      duration: duration,
      onAction: onAction,
      actionLabel: actionLabel,
    );

    if (_toasts.length >= maxToasts) {
      final oldest = _toasts.first;
      dismissToast(oldest.id);
    }

    _toasts.add(item);
    notifyListeners();

    _dismissTimers[id] = Timer(duration, () {
      dismissToast(id);
    });
  }

  void dismissToast(String id) {
    _dismissTimers[id]?.cancel();
    _dismissTimers.remove(id);
    final index = _toasts.indexWhere((t) => t.id == id);
    if (index != -1) {
      _toasts.removeAt(index);
      notifyListeners();
    }
  }

  void pauseTimer(String id) {
    _dismissTimers[id]?.cancel();
  }

  void resumeTimer(
    String id, {
    Duration remaining = const Duration(milliseconds: 1500),
  }) {
    // A hover can end because the card was disposed rather than because the
    // pointer left - the layer stands down whole when the player opens - and
    // by then the toast may already be gone. Re-arming for an id that is no
    // longer in the queue strands a timer in the map that nothing will ever
    // cancel.
    if (!_toasts.any((t) => t.id == id)) return;
    _dismissTimers[id]?.cancel();
    _dismissTimers[id] = Timer(remaining, () {
      dismissToast(id);
    });
  }

  void showSuccess(
    String message, {
    String? title,
    IconData? icon,
    Duration duration = const Duration(milliseconds: 3000),
  }) {
    showToast(
      title: title,
      message: message,
      type: ToastType.success,
      icon: icon ?? Icons.check_circle_rounded,
      duration: duration,
    );
  }

  void showError(
    String message, {
    String? title,
    IconData? icon,
    Duration duration = const Duration(milliseconds: 4000),
  }) {
    showToast(
      title: title,
      message: message,
      type: ToastType.error,
      icon: icon ?? Icons.error_outline_rounded,
      duration: duration,
    );
  }

  void showInfo(
    String message, {
    String? title,
    IconData? icon,
    Duration duration = const Duration(milliseconds: 3000),
  }) {
    showToast(
      title: title,
      message: message,
      type: ToastType.info,
      icon: icon ?? Icons.info_outline_rounded,
      duration: duration,
    );
  }

  void showExtension(
    String message, {
    String? title,
    IconData? icon,
    Widget? leading,
    Duration duration = const Duration(milliseconds: 3200),
  }) {
    showToast(
      title: title,
      message: message,
      type: ToastType.extension,
      icon: icon ?? Icons.extension_rounded,
      leading: leading,
      duration: duration,
    );
  }

  void showSnackBar(
    String message, {
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 4),
    SnackBarAction? action,
  }) {
    showToast(
      message: message,
      type: ToastType.info,
      duration: duration,
      onAction: action?.onPressed,
      actionLabel: action?.label,
    );
  }

  void clearSnackBars() {
    for (final timer in _dismissTimers.values) {
      timer.cancel();
    }
    _dismissTimers.clear();
    _toasts.clear();
    notifyListeners();
    messengerKey.currentState?.clearSnackBars();
  }
}
