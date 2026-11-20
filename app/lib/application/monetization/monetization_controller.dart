import 'dart:async';

import 'package:flutter/foundation.dart';

import 'subscription_gateway.dart';

/// Which plan the user is on.
///
/// Both plans include every feature (DAT-38): the only difference is
/// whether ads are shown.
enum Plan {
  free('Free', 'Every feature, with ads'),
  adFree('Ad-free', 'Every feature, no ads');

  const Plan(this.label, this.summary);

  final String label;
  final String summary;
}

/// Where the last known plan is saved between launches.
abstract interface class PlanStore {
  Plan? read();
  Future<void> write(Plan plan);
}

class MemoryPlanStore implements PlanStore {
  MemoryPlanStore([this.plan]);

  Plan? plan;

  @override
  Plan? read() => plan;

  @override
  Future<void> write(Plan plan) async => this.plan = plan;
}

enum OfferStatus { loading, available, unavailable }

/// Plan, price and purchase state for the whole app (DAT-38, DAT-39).
///
/// Starts from the saved plan so an ad-free user never sees an ad while the
/// store is checked, then asks the store to confirm.
class MonetizationController extends ChangeNotifier {
  MonetizationController({required SubscriptionGateway gateway})
      : _gateway = gateway;

  final SubscriptionGateway _gateway;
  StreamSubscription<BillingEvent>? _events;
  PlanStore? _store;

  Plan _plan = Plan.free;
  OfferStatus _offerStatus = OfferStatus.loading;
  SubscriptionOffer? _offer;
  bool _purchasing = false;
  bool _restoring = false;
  bool _userRestore = false;
  bool _pending = false;
  String? _message;
  bool _disposed = false;

  Plan get plan => _plan;

  /// DAT-38: ads are shown on the free plan only. They never block a feature.
  bool get showAds => _plan == Plan.free;

  bool get isTest => _gateway.isTest;
  OfferStatus get offerStatus => _offerStatus;
  SubscriptionOffer? get offer => _offer;
  bool get purchasing => _purchasing;
  bool get restoring => _restoring;
  bool get busy => _purchasing || _restoring;

  /// Waiting for approval (e.g. Ask to Buy).
  bool get pending => _pending;

  /// The latest result to show the user, if any. Cleared by [clearMessage].
  String? get message => _message;

  /// Reads the saved plan, starts listening to the store, loads the price
  /// and quietly checks the subscription is still active.
  Future<void> init(PlanStore store) async {
    _store = store;
    _plan = store.read() ?? Plan.free;
    _events ??= _gateway.events.listen(_onEvent);
    _notify();
    await loadOffer();
    if (_gateway.checksOnLaunch) await _refresh(userAsked: false);
  }

  Future<void> loadOffer() async {
    _offerStatus = OfferStatus.loading;
    _notify();
    try {
      _offer = await _gateway.loadOffer();
    } catch (e) {
      debugPrint('Loading the subscription failed: $e');
      _offer = null;
    }
    _offerStatus =
        _offer == null ? OfferStatus.unavailable : OfferStatus.available;
    _notify();
  }

  /// Opens the store's purchase sheet.
  Future<void> subscribe() async {
    final offer = _offer;
    if (offer == null || busy || _plan == Plan.adFree) return;
    _purchasing = true;
    _message = null;
    _notify();
    try {
      await _gateway.buy(offer);
      // The outcome arrives as a BillingEvent.
    } catch (e) {
      debugPrint('Starting the purchase failed: $e');
      _purchasing = false;
      _message = "Couldn't start the purchase. Please try again.";
      _notify();
    }
  }

  /// "Restore purchases": for a new phone or a reinstall.
  Future<void> restore() => _refresh(userAsked: true);

  /// Test mode only: go back to the free plan, to show both plans in a demo.
  Future<void> endTestSubscription() async {
    if (!isTest) return;
    await _setPlan(Plan.free);
    _message = 'Test subscription ended. Ads are back.';
    _notify();
  }

  void clearMessage() {
    if (_message == null) return;
    _message = null;
    _notify();
  }

  Future<void> _refresh({required bool userAsked}) async {
    if (_restoring) return;
    _restoring = true;
    _userRestore = userAsked;
    if (userAsked) _message = null;
    _notify();
    try {
      final active = await _gateway.restore();
      if (active == true) {
        await _setPlan(Plan.adFree);
      } else if (active == false) {
        // The store is sure: the subscription has ended or never existed.
        await _setPlan(Plan.free);
      }
      // When the store can't say (null), a restored purchase may still have
      // arrived as an event while waiting, so go by the plan now.
      if (userAsked) {
        _message = _plan == Plan.adFree
            ? 'Subscription restored. No more ads.'
            : 'No ad-free subscription was found for this account.';
      }
    } catch (e) {
      debugPrint('Restoring purchases failed: $e');
      if (userAsked) {
        _message = "Couldn't reach the store. Please try again.";
      }
    } finally {
      _restoring = false;
      _userRestore = false;
      _notify();
    }
  }

  Future<void> _onEvent(BillingEvent event) async {
    // Read before any await: a restore can finish while this one waits.
    final userRestore = _userRestore;
    switch (event) {
      case BillingOwned(:final restored):
        final wasFree = _plan == Plan.free;
        _purchasing = false;
        _pending = false;
        await _setPlan(Plan.adFree);
        // The quiet check at launch shouldn't pop up a message.
        if (wasFree && (!restored || userRestore)) {
          _message = restored
              ? 'Subscription restored. No more ads.'
              : "You're ad-free. Thanks for supporting DataMuncher!";
        }
      case BillingPending():
        _purchasing = false;
        _pending = true;
        _message = 'Waiting for the purchase to be approved. Ads disappear '
            'as soon as it is.';
      case BillingCancelled():
        _purchasing = false;
      case BillingFailed(:final message):
        _purchasing = false;
        _pending = false;
        _message = "The purchase didn't go through: $message";
    }
    _notify();
  }

  Future<void> _setPlan(Plan plan) async {
    if (plan == _plan && _store?.read() == plan) return;
    _plan = plan;
    if (plan == Plan.adFree) _pending = false;
    await _store?.write(plan);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    _gateway.dispose();
    super.dispose();
  }
}
