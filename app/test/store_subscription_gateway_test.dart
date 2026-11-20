import 'dart:async';

import 'package:datamuncher/application/monetization/subscription_gateway.dart';
import 'package:datamuncher/data/monetization/store_subscription_gateway.dart';
import 'package:datamuncher/data/monetization/test_subscription_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

class FakeStoreClient implements StoreClient {
  bool available = true;
  List<ProductDetails> products = [product()];
  final StreamController<List<PurchaseDetails>> purchases =
      StreamController<List<PurchaseDetails>>.broadcast();
  final List<ProductDetails> bought = [];
  final List<PurchaseDetails> completed = [];

  /// What a restore sends on the purchase stream.
  List<PurchaseDetails> restoreSends = [];

  static ProductDetails product([String id = adFreeProductId]) =>
      ProductDetails(
        id: id,
        title: 'Ad-free',
        description: 'No ads',
        price: r'$0.99',
        rawPrice: 0.99,
        currencyCode: 'USD',
      );

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => purchases.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async =>
      ProductDetailsResponse(
        productDetails: products.where((p) => ids.contains(p.id)).toList(),
        notFoundIDs: [
          for (final id in ids)
            if (!products.any((p) => p.id == id)) id
        ],
      );

  @override
  Future<bool> buyNonConsumable(ProductDetails product) async {
    bought.add(product);
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async =>
      completed.add(purchase);

  @override
  Future<void> restorePurchases() async => purchases.add(restoreSends);
}

PurchaseDetails purchase(PurchaseStatus status,
    {String productId = adFreeProductId, bool needsCompleting = true}) {
  return PurchaseDetails(
    purchaseID: 'tx1',
    productID: productId,
    verificationData: PurchaseVerificationData(
        localVerificationData: '', serverVerificationData: '', source: 'test'),
    transactionDate: '0',
    status: status,
  )..pendingCompletePurchase = needsCompleting;
}

void main() {
  late FakeStoreClient client;
  late List<BillingEvent> events;

  StoreSubscriptionGateway gateway({bool onlyActive = true}) {
    final g = StoreSubscriptionGateway(
      client: client,
      restoreListsOnlyActive: onlyActive,
      restoreWait: const Duration(milliseconds: 50),
    );
    g.events.listen(events.add);
    addTearDown(g.dispose);
    return g;
  }

  setUp(() {
    client = FakeStoreClient();
    events = [];
  });

  test('loads the price from the store', () async {
    final offer = await gateway().loadOffer();
    expect(offer!.productId, adFreeProductId);
    expect(offer.price, r'$0.99');
  });

  test('no offer when the store is unreachable or the product is missing',
      () async {
    client.available = false;
    expect(await gateway().loadOffer(), isNull);
    client
      ..available = true
      ..products = [FakeStoreClient.product('something_else')];
    expect(await gateway().loadOffer(), isNull);
  });

  test('buys the loaded product', () async {
    final g = gateway();
    final offer = await g.loadOffer();
    await g.buy(offer!);
    expect(client.bought.single.id, adFreeProductId);
  });

  test('buying before loading the offer is refused', () async {
    const offer = SubscriptionOffer(
        productId: adFreeProductId, title: 'x', price: 'x');
    expect(() => gateway().buy(offer), throwsStateError);
  });

  test('turns store updates into events and finishes every purchase',
      () async {
    gateway();
    final updates = [
      purchase(PurchaseStatus.pending, needsCompleting: false),
      purchase(PurchaseStatus.purchased),
      purchase(PurchaseStatus.canceled),
      purchase(PurchaseStatus.error)
        ..error = IAPError(source: 'test', code: 'x', message: 'Declined'),
      purchase(PurchaseStatus.purchased, productId: 'other_product'),
    ];
    client.purchases.add(updates);
    await pumpEventQueue();

    expect(events, [
      isA<BillingPending>(),
      isA<BillingOwned>().having((e) => e.restored, 'restored', false),
      isA<BillingCancelled>(),
      isA<BillingFailed>().having((e) => e.message, 'message', 'Declined'),
    ]);
    expect(client.completed, hasLength(4),
        reason: 'including the other product, but not the pending one');
  });

  test('restore: active subscription found', () async {
    client.restoreSends = [purchase(PurchaseStatus.restored)];
    expect(await gateway().restore(), isTrue);
    expect(events.single,
        isA<BillingOwned>().having((e) => e.restored, 'restored', true));
  });

  test('restore on Google Play: nothing found means it ended', () async {
    expect(await gateway(onlyActive: true).restore(), isFalse);
  });

  test('restore on the App Store: nothing found means unknown', () async {
    expect(await gateway(onlyActive: false).restore(), isNull);
  });

  test('only Google Play checks quietly at launch', () {
    expect(gateway(onlyActive: true).checksOnLaunch, isTrue);
    expect(gateway(onlyActive: false).checksOnLaunch, isFalse);
  });

  group('test mode', () {
    test('offers the proposed price and subscribes without a store',
        () async {
      final g = TestSubscriptionGateway(delay: Duration.zero);
      addTearDown(g.dispose);
      final got = <BillingEvent>[];
      g.events.listen(got.add);

      final offer = await g.loadOffer();
      expect(offer!.price, proposedMonthlyPrice);
      expect(g.isTest, isTrue);
      expect(g.checksOnLaunch, isFalse);

      await g.buy(offer);
      await pumpEventQueue();
      expect(got.single, isA<BillingOwned>());
      expect(await g.restore(), isNull);
    });
  });
}
