/// Lightweight public profiles: a single intentionally-public AtKey
/// `profile.scytale` per Atsign (name, short bio, optional avatar).
library;

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../models/models.dart';

class ProfileService extends ChangeNotifier {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  AtClient get _atClient => AtClientManager.getInstance().atClient;

  final Map<String, Profile> _cache = {};

  AtKey _profileKey(String atSign) => AtKey()
    ..key = 'profile'
    ..namespace = appNamespace
    ..sharedBy = atSign
    ..metadata = (Metadata()..isPublic = true);

  Profile? cached(String atSign) => _cache[atSign];

  /// Publish (or update) our own public profile.
  Future<void> saveMyProfile(Profile profile) async {
    final me = _atClient.getCurrentAtSign()!.toAtsign();
    await _atClient.put(_profileKey(me), jsonEncode(profile.toJson()));
    _cache[me] = profile;
    notifyListeners();
  }

  /// Fetch a profile (own or a peer's). Peers' profiles are public keys,
  /// resolved via plookup and cached by the SDK.
  Future<Profile?> fetch(String atSignRaw, {bool refresh = false}) async {
    final atSign = atSignRaw.toAtsign();
    if (!refresh && _cache.containsKey(atSign)) return _cache[atSign];
    try {
      final result = await _atClient.get(
        _profileKey(atSign),
        getRequestOptions: GetRequestOptions()..bypassCache = refresh,
      );
      if (result.value == null) return null;
      final profile = Profile.fromJson(jsonDecode(result.value));
      _cache[atSign] = profile;
      notifyListeners();
      return profile;
    } catch (e) {
      // Peer may simply not have published a profile yet.
      debugPrint('no profile for $atSign: $e');
      return null;
    }
  }
}
