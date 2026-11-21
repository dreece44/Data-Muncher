import 'package:datamuncher/application/monetization/monetization_controller.dart';
import 'package:datamuncher/application/monetization/subscription_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_monetization.dart';

void main() {
  late FakeGateway gateway;
  late MemoryPlanStore store;
  late MonetizationController m;

  setUp(() {
    gateway = FakeGateway();
    store = MemoryPlanStore();
    m = MonetizationController(gateway: gateway);
  });

  tearDown(() => m.dispose());

  test('starts free with ads and loads the price', () async {
    await m.init(store);
    expect(m.plan, Plan.free);
    expect(m.showAds, isTrue);
    expect(m.offerStatus, OfferStatus.available);
    expect(m.offer!.price, r'$0.99');
  });

  test('a saved ad-free plan shows no ads from the start', () async {
    store.plan = Plan.adFree;
    gateway.restoreResult = null; // store can't tell
    final init = m.init(store);
    expect(m.showAds, isFalse, reason: 'no ad flashes up while checking');
    await init;
    expect(m.plan, Plan.adFree);
  });

  test('the launch check downgrades when the store says it ended', () async {
    store.plan = Plan.adFree;
    gateway.restoreResult = false;
    await m.init(store);
    expect(m.plan, Plan.free);
    expect(store.plan, Plan.free);
    expect(m.message, isNull, reason: 'quiet check at launch');
  });

  test('no launch check where the store would ask to sign in (iPhone)',
      () async {
    final iphone = FakeGateway(checksOnLaunch: false, restoreResult: false);
    final c = MonetizationController(gateway: iphone);
    addTearDown(c.dispose);
    store.plan = Plan.adFree;
    await c.init(store);
    expect(iphone.restoreCalls, 0);
    expect(c.plan, Plan.adFree);
  });

  test('subscribing removes ads and is remembered', () async {
    await m.init(store);
    await m.subscribe();
    expect(m.purchasing, isTrue);
    expect(gateway.bought.single.productId, 'p');

    gateway.emit(const BillingOwned());
    await flush();

    expect(m.plan, Plan.adFree);
    expect(m.showAds, isFalse);
    expect(m.purchasing, isFalse);
    expect(store.plan, Plan.adFree);
    expect(m.message, contains("You're ad-free"));
  });

  test('cancelling the store sheet changes nothing', () async {
    await m.init(store);
    await m.subscribe();
    gateway.emit(const BillingCancelled());
    await flush();
    expect(m.plan, Plan.free);
    expect(m.purchasing, isFalse);
    expect(m.message, isNull);
  });

  test('a failed purchase says why', () async {
    await m.init(store);
    await m.subscribe();
    gateway.emit(const BillingFailed('Card declined'));
    await flush();
    expect(m.plan, Plan.free);
    expect(m.message, "The purchase didn't go through: Card declined");
  });

  test('Ask to Buy: pending, then approved later', () async {
    await m.init(store);
    await m.subscribe();
    gateway.emit(const BillingPending());
    await flush();
    expect(m.pending, isTrue);
    expect(m.purchasing, isFalse);
    expect(m.showAds, isTrue);

    gateway.emit(const BillingOwned());
    await flush();
    expect(m.pending, isFalse);
    expect(m.plan, Plan.adFree);
  });

  test('a purchase that cannot start leaves the free plan', () async {
    await m.init(store);
    gateway.buyError = StateError('store busy');
    await m.subscribe();
    expect(m.purchasing, isFalse);
    expect(m.message, "Couldn't start the purchase. Please try again.");
  });

  test('cannot subscribe twice or without a price', () async {
    gateway.offer = null;
    await m.init(store);
    expect(m.offerStatus, OfferStatus.unavailable);
    await m.subscribe();
    expect(gateway.bought, isEmpty);

    gateway.offer = const SubscriptionOffer(
        productId: 'p', title: 'Ad-free', price: r'$0.99');
    await m.loadOffer();
    expect(m.offerStatus, OfferStatus.available);
    await m.subscribe();
    await m.subscribe();
    expect(gateway.bought, hasLength(1));
  });

  test('a store error while loading the price shows unavailable', () async {
    gateway.offerError = Exception('offline');
    await m.init(store);
    expect(m.offerStatus, OfferStatus.unavailable);
  });

  group('Restore purchases', () {
    setUp(() async {
      await m.init(store);
      gateway.restoreCalls = 0;
    });

    test('finds an active subscription', () async {
      gateway.restoreResult = true;
      await m.restore();
      expect(m.plan, Plan.adFree);
      expect(m.message, 'Subscription restored. No more ads.');
    });

    test('says so when there is none', () async {
      gateway.restoreResult = false;
      await m.restore();
      expect(m.plan, Plan.free);
      expect(m.message, 'No ad-free subscription was found for this account.');
    });

    test('a restored event during the restore also counts', () async {
      gateway.restoreResult = null;
      final restoring = m.restore();
      gateway.emit(const BillingOwned(restored: true));
      await restoring;
      expect(m.plan, Plan.adFree);
      expect(m.message, 'Subscription restored. No more ads.');
    });

    test('a store error is reported', () async {
      gateway.restoreError = Exception('offline');
      await m.restore();
      expect(m.message, "Couldn't reach the store. Please try again.");
      expect(m.restoring, isFalse);
    });
  });

  test('test mode can end the subscription to show both plans', () async {
    final test = FakeGateway(isTest: true, checksOnLaunch: false);
    final c = MonetizationController(gateway: test);
    addTearDown(c.dispose);
    await c.init(store);
    await c.subscribe();
    test.emit(const BillingOwned());
    await flush();
    expect(c.plan, Plan.adFree);

    await c.endTestSubscription();
    expect(c.plan, Plan.free);
    expect(c.showAds, isTrue);
  });

  test('endTestSubscription does nothing with real billing', () async {
    store.plan = Plan.adFree;
    gateway.restoreResult = null;
    await m.init(store);
    await m.endTestSubscription();
    expect(m.plan, Plan.adFree);
  });

  test('every plan has every feature; only ads differ', () {
    expect(Plan.free.summary, 'Every feature, with ads');
    expect(Plan.adFree.summary, 'Every feature, no ads');
  });
}
