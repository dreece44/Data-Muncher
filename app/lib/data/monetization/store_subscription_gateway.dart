import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../application/monetization/subscription_gateway.dart';

/// Product id of the monthly ad-free subscription (DAT-39). It must be
/// created with this exact id in App Store Connect and the Google Play
/// Console; the price is set there, not in the app.
const String adFreeProductId = 'datamuncher_ad_free_monthly';

/// The parts of `InAppPurchase` the gateway uses, so tests can stand in
/// for the store.
abstract interface class StoreClient {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids);
  Future<bool> buyNonConsumable(ProductDetails product);
  Future<void> completePurchase(PurchaseDetails purchase);
  Future<void> restorePurchases();
}

class InAppPurchaseStoreClient implements StoreClient {
  InAppPurchaseStoreClient([InAppPurchase? iap])
      : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) =>
      _iap.queryProductDetails(ids);

  // Subscriptions are bought with buyNonConsumable. On Google Play the
  // product's first offer (the base plan) is used.
  @override
  Future<bool> buyNonConsumable(ProductDetails product) =>
      _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));

  @override
  Future<void> completePurchase(PurchaseDetails purchase) =>
      _iap.completePurchase(purchase);

  @override
  Future<void> restorePurchases() => _iap.restorePurchases();
}

/// Real billing through the App Store or Google Play (DAT-39).
class StoreSubscriptionGateway implements SubscriptionGateway {
  StoreSubscriptionGateway({
    StoreClient? client,
    this.productId = adFreeProductId,
    bool? restoreListsOnlyActive,
    this.restoreWait = const Duration(seconds: 3),
  })  : _client = client ?? InAppPurchaseStoreClient(),
        // Google Play's restore returns only subscriptions that are still
        // active. The App Store's also returns ones that have ended.
        restoreListsOnlyActive = restoreListsOnlyActive ??
            (defaultTargetPlatform == TargetPlatform.android) {
    _purchases = _client.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => _events.add(BillingFailed('$e')),
    );
  }

  final StoreClient _client;
  final String productId;
  final bool restoreListsOnlyActive;

  /// How long to wait for restored purchases to arrive after a restore.
  final Duration restoreWait;

  final StreamController<BillingEvent> _events =
      StreamController<BillingEvent>.broadcast();
  late final StreamSubscription<List<PurchaseDetails>> _purchases;
  ProductDetails? _product;
  Completer<void>? _restoreFound;

  @override
  bool get isTest => false;

  @override
  bool get checksOnLaunch => restoreListsOnlyActive;

  @override
  Stream<BillingEvent> get events => _events.stream;

  @override
  Future<SubscriptionOffer?> loadOffer() async {
    if (!await _client.isAvailable()) return null;
    final response = await _client.queryProductDetails({productId});
    if (response.error != null) {
      debugPrint('Store error: ${response.error!.message}');
    }
    final matches =
        response.productDetails.where((p) => p.id == productId).toList();
    if (matches.isEmpty) return null;
    final product = _product = matches.first;
    return SubscriptionOffer(
      productId: product.id,
      title: product.title,
      price: product.price,
    );
  }

  @override
  Future<void> buy(SubscriptionOffer offer) async {
    final product = _product;
    if (product == null || product.id != offer.productId) {
      throw StateError('Load the offer before buying');
    }
    await _client.buyNonConsumable(product);
  }

  @override
  Future<bool?> restore() async {
    final found = _restoreFound = Completer<void>();
    try {
      await _client.restorePurchases();
      await found.future.timeout(restoreWait);
      return true;
    } on TimeoutException {
      return restoreListsOnlyActive ? false : null;
    } finally {
      _restoreFound = null;
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID == productId) {
        switch (purchase.status) {
          case PurchaseStatus.pending:
            _events.add(const BillingPending());
          case PurchaseStatus.purchased:
            _events.add(const BillingOwned());
            _markFound();
          case PurchaseStatus.restored:
            _events.add(const BillingOwned(restored: true));
            _markFound();
          case PurchaseStatus.canceled:
            _events.add(const BillingCancelled());
          case PurchaseStatus.error:
            _events.add(BillingFailed(
                purchase.error?.message ?? 'Unknown store error'));
        }
      }
      // Every purchase must be finished, or the store retries it forever.
      if (purchase.pendingCompletePurchase) {
        try {
          await _client.completePurchase(purchase);
        } catch (e) {
          debugPrint('Finishing a purchase failed: $e');
        }
      }
    }
  }

  void _markFound() {
    final found = _restoreFound;
    if (found != null && !found.isCompleted) found.complete();
  }

  @override
  void dispose() {
    _purchases.cancel();
    _events.close();
  }
}
