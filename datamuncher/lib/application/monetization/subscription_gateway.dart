import 'package:flutter/foundation.dart';

/// PB-26 / DAT-39: the optional ad-free subscription, as the app sees it.
///
/// Implemented by the real App Store / Google Play billing
/// (`StoreSubscriptionGateway`) and by a test mode for demos
/// (`TestSubscriptionGateway`), so the rest of the app never talks to a
/// store directly.

/// The subscription as the store describes it.
@immutable
class SubscriptionOffer {
  const SubscriptionOffer({
    required this.productId,
    required this.title,
    required this.price,
  });

  final String productId;
  final String title;

  /// Already formatted by the store for the user's country, e.g. "$0.99".
  final String price;
}

/// Something the store reported about the subscription.
sealed class BillingEvent {
  const BillingEvent();
}

/// The user has the subscription: just bought, or found by a restore.
class BillingOwned extends BillingEvent {
  const BillingOwned({this.restored = false});
  final bool restored;
}

/// Waiting for approval, e.g. Ask to Buy or a delayed payment.
class BillingPending extends BillingEvent {
  const BillingPending();
}

/// The user closed the store's purchase sheet.
class BillingCancelled extends BillingEvent {
  const BillingCancelled();
}

class BillingFailed extends BillingEvent {
  const BillingFailed(this.message);
  final String message;
}

abstract interface class SubscriptionGateway {
  /// True in test mode: no store and no money involved.
  bool get isTest;

  /// Whether [restore] can run quietly at every launch to catch a
  /// subscription that has ended. True on Google Play. False on the App
  /// Store, where a restore can ask the user to sign in, so it only runs
  /// when the user taps Restore purchases.
  bool get checksOnLaunch;

  /// Purchase results, including ones that arrive later (Ask to Buy,
  /// purchases made before the app was last closed).
  Stream<BillingEvent> get events;

  /// The subscription's name and price, or null if the store can't offer it
  /// (store unreachable, or the product isn't set up in the store yet).
  Future<SubscriptionOffer?> loadOffer();

  /// Opens the store's purchase sheet. The result arrives on [events].
  Future<void> buy(SubscriptionOffer offer);

  /// Asks the store which subscriptions this account already has.
  ///
  /// Returns true if the ad-free subscription is active, false if the store
  /// says definitely not, and null if the store can't tell (on iPhone a
  /// restore also lists subscriptions that have ended).
  Future<bool?> restore();

  void dispose();
}
