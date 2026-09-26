import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing_service.dart';

final routingServiceProvider = Provider<RoutingService>((ref) {
  final service = RoutingService();
  ref.onDispose(service.dispose);
  return service;
});
