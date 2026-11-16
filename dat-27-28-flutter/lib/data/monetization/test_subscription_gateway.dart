import 'dart:async';

import '../../application/monetization/subscription_gateway.dart';

/// Proposed price for DAT-39 (open question in Jira). Shown only in test
/// mode; with real billing the price comes from the store.
const String proposedMonthlyPrice = r'$0.99';

/// Test mode for demos and the simulator: subscribing works instantly and
/// no store or money is involved. Turn it on with
/// `flutter run --dart-define=BILLING=test`.
class TestSubscriptionGateway implements SubscriptionGateway {
  TestSubscriptionGateway({this.delay = const Duration(milliseconds: 600)});

  final Duration delay;
  final StreamController<BillingEvent> _events =
      StreamController<BillingEvent>.broadcast();

  @override
  bool get isTest => true;

  @override
  bool get checksOnLaunch => false;

  @override
  Stream<BillingEvent> get events => _events.stream;

  @override
  Future<SubscriptionOffer?> loadOffer() async => const SubscriptionOffer(
        productId: 'test_ad_free_monthly',
        title: 'DataMuncher Ad-free (test)',
        price: proposedMonthlyPrice,
      );

  @override
  Future<void> buy(SubscriptionOffer offer) async {
    await Future<void>.delayed(delay);
    if (!_events.isClosed) _events.add(const BillingOwned());
  }

  /// Test mode keeps whatever plan the app last saved.
  @override
  Future<bool?> restore() async => null;

  @override
  void dispose() => _events.close();
}
