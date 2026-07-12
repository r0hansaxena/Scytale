import 'package:flutter/material.dart';

/// Global navigator key so services (e.g. an incoming call) can push
/// screens without a BuildContext.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
