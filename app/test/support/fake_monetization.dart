import 'dart:async';

import 'package:datamuncher/application/monetization/subscription_gateway.dart';
import 'package:datamuncher/data/ads/ad_provider.dart';
import 'package:flutter/widgets.dart';

/// A [SubscriptionGateway] the test drives by hand.
class FakeGateway implements SubscriptionGateway {
  FakeGateway({
    this.offer = const SubscriptionOffer(
        productId: 'p', title: 'Ad-free', price: r'$0.99'),
    this.restoreResult,
    this.isTest = false,
    this.checksOnLaunch = true,
  });

  SubscriptionOffer? offer;
  Object? offerError;
  Object? buyError;
  bool? restoreResult;
  Object? restoreError;
  final List<SubscriptionOffer> bought = [];
  int restoreCalls = 0;
  bool disposed = false;

  @override
  final bool isTest;

  @override
  final bool checksOnLaunch;

  final StreamController<BillingEvent> _events =
      StreamController<BillingEvent>.broadcast(sync: true);

  void emit(BillingEvent event) => _events.add(event);

  @override
  Stream<BillingEvent> get events => _events.stream;

  @override
  Future<SubscriptionOffer?> loadOffer() async {
    final error = offerError;
    if (error != null) throw error;
    return offer;
  }

  @override
  Future<void> buy(SubscriptionOffer offer) async {
    final error = buyError;
    if (error != null) throw error;
    bought.add(offer);
  }

  @override
  Future<bool?> restore() async {
    restoreCalls++;
    final error = restoreError;
    if (error != null) throw error;
    return restoreResult;
  }

  @override
  void dispose() {
    disposed = true;
    _events.close();
  }
}

/// Shows a recognisable box instead of a real ad.
class FakeAdProvider implements AdProvider {
  int built = 0;

  @override
  Widget buildBanner() {
    built++;
    return const SizedBox(
        key: ValueKey('test-ad'), width: 320, height: 50, child: Text('Test ad'));
  }
}

/// Lets queued async work finish.
Future<void> flush() => Future<void>.delayed(Duration.zero);
