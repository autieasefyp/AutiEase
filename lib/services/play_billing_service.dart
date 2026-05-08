import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

enum PlayPurchaseLifecycle { pending, active, canceled, failed }

class PlaySubscriptionPurchaseEvent {
  const PlaySubscriptionPurchaseEvent({
    required this.therapistId,
    required this.productId,
    required this.purchaseToken,
    required this.lifecycle,
    this.purchaseId = '',
    this.orderId = '',
    this.purchaseDate,
  });

  final String therapistId;
  final String productId;
  final String purchaseToken;
  final PlayPurchaseLifecycle lifecycle;
  final String purchaseId;
  final String orderId;
  final DateTime? purchaseDate;

  bool get isActive => lifecycle == PlayPurchaseLifecycle.active;

  bool get cancelAtPeriodEnd => lifecycle == PlayPurchaseLifecycle.canceled;

  String get status {
    switch (lifecycle) {
      case PlayPurchaseLifecycle.pending:
        return 'pending';
      case PlayPurchaseLifecycle.active:
        return 'active';
      case PlayPurchaseLifecycle.canceled:
        return 'canceled';
      case PlayPurchaseLifecycle.failed:
        return 'error';
    }
  }
}

class PlayPurchaseResult {
  const PlayPurchaseResult({required this.started, required this.completed});

  final bool started;
  final bool completed;
}

class PlayBillingService {
  PlayBillingService({
    required Future<String?> Function(String productId) resolveTherapistId,
    required Future<void> Function(PlaySubscriptionPurchaseEvent event)
    onPurchaseEvent,
  }) : _resolveTherapistId = resolveTherapistId,
       _onPurchaseEvent = onPurchaseEvent {
    _purchaseSubscription = _inAppPurchase.purchaseStream.listen(
      _handlePurchaseDetails,
      onError: (_) {},
    );
  }

  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  final Future<String?> Function(String productId) _resolveTherapistId;
  final Future<void> Function(PlaySubscriptionPurchaseEvent event)
  _onPurchaseEvent;
  final Map<String, String> _pendingProductToTherapist = <String, String>{};
  final Map<String, Completer<bool>> _purchaseCompleters =
      <String, Completer<bool>>{};
  late final StreamSubscription<List<PurchaseDetails>> _purchaseSubscription;

  Future<void> dispose() async {
    await _purchaseSubscription.cancel();
  }

  Future<bool> isAvailable() async => _inAppPurchase.isAvailable();

  Future<ProductDetails> getProductDetails(String productId) async {
    final response = await _inAppPurchase.queryProductDetails({productId});
    if (response.error != null) {
      throw StateError(response.error!.message);
    }
    if (response.productDetails.isEmpty) {
      throw StateError(
        'Google Play product "$productId" is not available. '
        'Verify it is active in Play Console for this app.',
      );
    }
    return response.productDetails.first;
  }

  Future<PlayPurchaseResult> purchaseSubscription({
    required String therapistId,
    required String productId,
  }) async {
    final available = await isAvailable();
    if (!available) {
      throw StateError('Google Play Billing is currently unavailable.');
    }

    final product = await getProductDetails(productId);
    _pendingProductToTherapist[productId] = therapistId;

    final completer = Completer<bool>();
    _purchaseCompleters[productId] = completer;
    final param = PurchaseParam(productDetails: product);
    final started = await _inAppPurchase.buyNonConsumable(purchaseParam: param);
    if (!started) {
      _purchaseCompleters.remove(productId);
      throw StateError('Unable to start the Google Play purchase flow.');
    }

    var completed = false;
    try {
      completed = await completer.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => false,
      );
    } finally {
      _purchaseCompleters.remove(productId);
    }
    return PlayPurchaseResult(started: true, completed: completed);
  }

  Future<void> restorePurchases() async {
    final available = await isAvailable();
    if (!available) {
      return;
    }
    await _inAppPurchase.restorePurchases();
    // Give the purchase stream a chance to deliver restored subscriptions.
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  Future<void> _handlePurchaseDetails(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      final productId = purchase.productID.trim();
      if (productId.isEmpty) {
        continue;
      }
      final therapistId =
          _pendingProductToTherapist[productId] ??
          await _resolveTherapistId(productId);
      if (therapistId == null || therapistId.trim().isEmpty) {
        continue;
      }

      final lifecycle = _resolveLifecycle(purchase);
      final event = PlaySubscriptionPurchaseEvent(
        therapistId: therapistId,
        productId: productId,
        purchaseToken: purchase.verificationData.serverVerificationData,
        lifecycle: lifecycle,
        purchaseId: (purchase.purchaseID ?? '').trim(),
        orderId: (purchase.purchaseID ?? '').trim(),
        purchaseDate: _parsePurchaseDate(purchase.transactionDate),
      );
      await _onPurchaseEvent(event);

      if (purchase.pendingCompletePurchase) {
        await _inAppPurchase.completePurchase(purchase);
      }

      final completer = _purchaseCompleters[productId];
      if (completer != null && !completer.isCompleted) {
        final completed = lifecycle == PlayPurchaseLifecycle.active;
        completer.complete(completed);
      }
    }
  }

  PlayPurchaseLifecycle _resolveLifecycle(PurchaseDetails purchase) {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        return PlayPurchaseLifecycle.pending;
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        return PlayPurchaseLifecycle.active;
      case PurchaseStatus.canceled:
        return PlayPurchaseLifecycle.canceled;
      case PurchaseStatus.error:
        return PlayPurchaseLifecycle.failed;
    }
  }

  DateTime? _parsePurchaseDate(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final millis = int.tryParse(raw);
    if (millis == null) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
}
