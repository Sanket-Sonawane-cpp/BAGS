import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/hazards.dart';
import '../../core/models/alert_event.dart';
import '../../core/providers.dart';
import '../../core/services/location_service.dart';
import 'hazard_routing.dart';
import 'navigation_providers.dart';
import 'route_progress.dart';
import 'routing_service.dart';

/// Map with A-to-B driving routes and live turn-by-turn guidance.
///
/// Pick a start (defaults to the current location) and a destination by
/// search or by long-pressing the map, then Start to follow the route: the
/// map tracks the car, shows the next maneuver, and reroutes after a wrong
/// turn. Reported hazards show as colored dots, and routes steer around them.
/// A hazard reported ahead mid-drive brings up an offer of a route around
/// it, taken automatically after a countdown — and so does a quicker route
/// once a hazard is cleared (e.g. by a server reset). Independent of the
/// detection
/// pipeline; it only shares [LocationService] and the alert feed.
class NavigationScreen extends ConsumerStatefulWidget {
  const NavigationScreen({super.key});

  @override
  ConsumerState<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends ConsumerState<NavigationScreen> {
  final MapController _map = MapController();
  bool _mapReady = false;

  LatLng? _me;
  LocationAccess? _access;

  /// null means "my location".
  Place? _from;
  Place? _to;

  NavRoute? _route;

  /// Hazards on [_route], and how many on the fastest route it avoids.
  List<HazardOnRoute> _onRoute = const [];
  int _avoided = 0;

  bool _routing = false;
  String? _error;

  /// Bumped per route request, so a slow response can't overwrite the route
  /// for a destination picked after it.
  int _routeRequest = 0;

  RouteProgress? _progress;
  NavUpdate? _update;
  StreamSubscription<Position>? _positionSub;
  DateTime? _lastReroute;
  bool _rerouting = false;

  /// Hazards on the road ahead already dealt with this drive — offered a
  /// way around, or known to be unavoidable — so they aren't offered again.
  final List<AlertEvent> _handled = [];

  /// Known hazards as of the last change, to spot ones that were cleared.
  List<AlertEvent> _knownBefore = const [];

  /// A new route waiting on the driver: around a newly reported hazard, or
  /// quicker now that one was cleared.
  _RerouteOffer? _offer;
  Timer? _offerTimer;

  /// Bumped per offer, so a slow plan can't resurface after the drive ended
  /// or a newer hazard superseded it.
  int _offerRequest = 0;

  /// Re-syncs hazards with the server once there's a GPS fix. Pushes only
  /// reach cars within 2 km of a report, so this is how hazards further
  /// along the route show up; it also catches ones this phone reported (the
  /// server doesn't push those back to it) and ones cleared on the server.
  Timer? _hazardRefresh;

  bool get _navigating => _positionSub != null;

  /// Further than this from the route line counts as a wrong turn. Generous,
  /// because GPS in a city is routinely 10–30 m off.
  static const double _offRouteMeters = 50;

  /// Minimum gap between reroutes, so a bad GPS patch doesn't hammer the
  /// public routing server with a request per fix.
  static const Duration _rerouteCooldown = Duration(seconds: 15);

  static const double _followZoom = 17;

  /// Short, so a hazard reported far ahead (beyond push range) is offered
  /// for rerouting within seconds. One small request to our own server.
  static const Duration _hazardRefreshInterval = Duration(seconds: 15);

  /// How long the driver has to decline a reroute before it's taken.
  static const int _offerSeconds = 10;

  /// A quicker route is only offered when it saves at least this much (and
  /// 5% of the time left), so routing noise doesn't keep asking.
  static const double _minSavingSeconds = 60;

  /// Hazards within this of where the map first centres are fetched.
  static const double _nearbyHazardMeters = 5000;

  @override
  void initState() {
    super.initState();
    // Deferred because it reads providers, which can't happen mid-construction.
    WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _hazardRefresh?.cancel();
    _offerTimer?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final service = ref.read(locationServiceProvider);
    final access = await service.ensurePermission();
    if (!mounted) return;
    setState(() => _access = access);
    if (access != LocationAccess.granted) return;

    try {
      // The cached fix paints the map immediately; the fresh one refines it.
      final last = await service.getLastKnownPosition();
      if (last != null) _setMe(last, recenter: true);
      final fresh = await service.getCurrentPosition().timeout(
        const Duration(seconds: 10),
      );
      _setMe(fresh, recenter: last == null);
      _syncHazards();
      _hazardRefresh ??= Timer.periodic(
        _hazardRefreshInterval,
        (_) => _syncHazards(),
      );
    } on Exception catch (error) {
      if (mounted && _me == null) setState(() => _error = 'No GPS fix: $error');
    }
  }

  void _setMe(Position position, {bool recenter = false}) {
    if (!mounted) return;
    final point = LatLng(position.latitude, position.longitude);
    setState(() => _me = point);
    if (recenter && _mapReady && _route == null) _map.move(point, 15);
  }

  /// Hazards around the car — and, while navigating, far enough to cover
  /// the rest of the route.
  void _syncHazards() {
    final here = _me;
    if (here == null) return;
    final left = _navigating ? _update?.remainingMeters ?? 0 : 0.0;
    unawaited(_refreshHazards(here, math.max(_nearbyHazardMeters, left)));
  }

  Future<void> _refreshHazards(LatLng center, double radiusMeters) => ref
      .read(knownHazardsProvider.notifier)
      .refreshAround(center, radiusMeters);

  Future<void> _pick({required bool origin}) async {
    final picked = await showSearch<_Pick?>(
      context: context,
      delegate: _PlaceSearch(
        service: ref.read(routingServiceProvider),
        near: _me,
        offerMyLocation: origin,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (origin) {
        _from = picked.place;
      } else {
        _to = picked.place;
      }
    });
    await _buildRoute();
  }

  Future<void> _dropPin(LatLng point) async {
    setState(
      () => _to = Place(
        name:
            'Dropped pin (${point.latitude.toStringAsFixed(5)}, '
            '${point.longitude.toStringAsFixed(5)})',
        point: point,
      ),
    );
    await _buildRoute();
  }

  Future<void> _swap() async {
    final me = _me;
    final newTo =
        _from ?? (me == null ? null : Place(name: 'My location', point: me));
    if (newTo == null) return;
    setState(() {
      _from = _to;
      _to = newTo;
    });
    await _buildRoute();
  }

  void _clear() => setState(() {
    _to = null;
    _route = null;
    _onRoute = const [];
    _avoided = 0;
    _error = null;
    _routeRequest++;
  });

  Future<void> _buildRoute() async {
    final to = _to;
    final from = _from?.point ?? _me;
    if (to == null) return;
    if (from == null) {
      setState(() => _error = 'Waiting for a GPS fix — or pick a start point');
      return;
    }

    final request = ++_routeRequest;
    setState(() {
      _routing = true;
      _error = null;
    });
    try {
      // Hazards anywhere between the two ends, with room for a detour.
      const distance = Distance();
      await _refreshHazards(
        LatLng(
          (from.latitude + to.point.latitude) / 2,
          (from.longitude + to.point.longitude) / 2,
        ),
        distance(from, to.point) / 2 + 2000,
      );
      final plan = await ref
          .read(hazardRoutePlannerProvider)
          .plan(from, to.point, ref.read(knownHazardsProvider));
      if (!mounted || request != _routeRequest) return;
      setState(() => _applyPlan(plan));
      _fit(plan.route);
    } on Exception catch (error) {
      if (mounted && request == _routeRequest) {
        setState(() {
          _route = null;
          _onRoute = const [];
          _error = '$error';
        });
      }
    } finally {
      if (mounted && request == _routeRequest) setState(() => _routing = false);
    }
  }

  /// Call inside setState.
  void _applyPlan(PlannedRoute plan) {
    _route = plan.route;
    _onRoute = plan.onRoute;
    _avoided = plan.avoidedCount;
  }

  void _fit(NavRoute route) {
    if (!_mapReady || route.points.length < 2) return;
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(route.points),
        // Clears the planning card on top.
        padding: const EdgeInsets.fromLTRB(40, 240, 40, 40),
      ),
    );
  }

  Future<void> _start() async {
    final me = _me;
    if (me == null) {
      setState(() => _error = 'Need a GPS fix to start navigating');
      return;
    }
    // Guidance follows the car, so a previewed route from somewhere else is
    // replaced by one from where the car actually is.
    if (_from != null) {
      setState(() => _from = null);
      await _buildRoute();
    }
    final route = _route;
    if (route == null || !mounted) return;

    final progress = RouteProgress(route);
    _publishRoute(route);
    setState(() {
      _progress = progress;
      _update = progress.update(me);
      _lastReroute = null;
      // The plan already chose to pass these; don't offer them again. Ones
      // that were only warnings are offered if they're confirmed later.
      _handled
        ..clear()
        ..addAll(_avoidable(_onRoute));
      _positionSub = ref
          .read(locationServiceProvider)
          .positionStream()
          .listen(
            _onPosition,
            onError: (Object error) {
              if (mounted) setState(() => _error = 'GPS lost: $error');
            },
          );
    });
    if (_mapReady) _map.move(me, _followZoom);
  }

  void _stop() {
    _positionSub?.cancel();
    _dismissOffer();
    _publishRoute(null);
    setState(() {
      _positionSub = null;
      _progress = null;
      _update = null;
    });
  }

  void _onPosition(Position position) {
    final progress = _progress;
    if (!mounted || progress == null) return;

    final point = LatLng(position.latitude, position.longitude);
    final update = progress.update(point);
    setState(() {
      _me = point;
      _update = update;
      _error = null;
    });
    if (_mapReady) _map.move(point, _map.camera.zoom);

    if (update.arrived) {
      _stop();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('You have arrived')));
    } else if (update.offRouteMeters > _offRouteMeters) {
      unawaited(_reroute(point));
    }
  }

  /// Finds a new route from [from] after a wrong turn. It already steers
  /// around every known hazard, so any pending offer is moot.
  Future<void> _reroute(LatLng from) async {
    final to = _to;
    final now = DateTime.now();
    final last = _lastReroute;
    if (to == null || _rerouting) return;
    if (last != null && now.difference(last) < _rerouteCooldown) return;
    _lastReroute = now;
    _rerouting = true;

    try {
      final plan = await ref
          .read(hazardRoutePlannerProvider)
          .plan(from, to.point, ref.read(knownHazardsProvider));
      if (!mounted || !_navigating) return;
      _dismissOffer();
      _follow(plan);
    } on Exception {
      // Keep guiding along the old route; the next off-route fix after the
      // cooldown tries again.
    } finally {
      _rerouting = false;
    }
  }

  /// Tells the server which route this car is driving (null: none), so
  /// hazards reported anywhere ahead on it are pushed here, not only ones
  /// within its push radius. Sent straight away rather than at the next
  /// location ping.
  void _publishRoute(NavRoute? route) {
    ref.read(activeRouteProvider.notifier).set(route?.points);
    ref.read(locationPingerProvider).pingNow();
  }

  /// Switches guidance to [plan], from wherever the car is now.
  void _follow(PlannedRoute plan) {
    final progress = RouteProgress(plan.route);
    final me = _me;
    _publishRoute(plan.route);
    setState(() {
      _applyPlan(plan);
      _progress = progress;
      _update = me == null ? null : progress.update(me);
      _handled.addAll(_avoidable(plan.onRoute));
    });
  }

  static Iterable<AlertEvent> _avoidable(Iterable<HazardOnRoute> onRoute) =>
      onRoute.where((h) => h.blocksThisRoute).map((h) => h.hazard);

  /// Keeps [_onRoute] current, and while navigating offers a way around a
  /// hazard newly reported (or newly confirmed) on the road ahead, or the
  /// quicker way once a hazard is cleared.
  void _onHazardsChanged(List<AlertEvent> hazards) {
    final before = _knownBefore;
    _knownBefore = hazards;
    bool known(AlertEvent hazard) => hazards.any((h) => _sameHazard(h, hazard));
    // A cleared hazard reported again later is news again.
    _handled.retainWhere(known);

    final route = _route;
    if (route == null) return;

    final onRoute = hazardsOnRoute(route, hazards);
    setState(() => _onRoute = onRoute);

    final me = _me;
    final along = _update?.alongMeters ?? 0;
    if (!_navigating || me == null) return;

    const distance = Distance();
    final fresh = onRoute
        .where(
          (h) =>
              h.blocksThisRoute &&
              h.alongMeters > along &&
              distance(me, LatLng(h.hazard.latitude, h.hazard.longitude)) >
                  HazardRoutePlanner.endpointClearanceMeters &&
              !_handled.any((seen) => _sameHazard(seen, h.hazard)),
        )
        .firstOrNull;
    if (fresh != null) {
      unawaited(_offerReroute(me, fresh.hazard));
      return;
    }

    // The road a cleared hazard closed may now be the quicker way.
    final cleared = before.any((old) => worthAvoiding(old) && !known(old));
    if (cleared) unawaited(_offerFasterRoute(me));
  }

  /// Plans a route around [hazard] and offers it, or says there's none.
  Future<void> _offerReroute(LatLng from, AlertEvent hazard) async {
    final to = _to;
    if (to == null) return;
    _handled.add(hazard);
    final request = ++_offerRequest;

    final PlannedRoute plan;
    try {
      plan = await ref
          .read(hazardRoutePlannerProvider)
          .plan(from, to.point, ref.read(knownHazardsProvider));
    } on Exception {
      // Routing server unreachable: let the next sync offer it again.
      _handled.remove(hazard);
      return;
    }
    if (!mounted || !_navigating || request != _offerRequest) return;

    final label = hazardStyle(hazard.type).label;
    if (plan.onRoute.any(
      (h) => h.blocksThisRoute && _sameHazard(h.hazard, hazard),
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label reported ahead — no way around it')),
      );
      return;
    }

    _showOffer(
      _RerouteOffer(hazard: hazard, plan: plan, secondsLeft: _offerSeconds),
    );
  }

  /// Offers the fastest route from [from] if it beats the rest of the
  /// current one by enough to be worth switching, without passing more
  /// blocking hazards than it.
  Future<void> _offerFasterRoute(LatLng from) async {
    final to = _to;
    final update = _update;
    // A pending offer already re-planned with what's known.
    if (to == null || update == null || _offer != null) return;
    final request = ++_offerRequest;

    final PlannedRoute plan;
    try {
      plan = await ref
          .read(hazardRoutePlannerProvider)
          .plan(from, to.point, ref.read(knownHazardsProvider));
    } on Exception {
      return; // The current route still works.
    }
    if (!mounted || !_navigating || request != _offerRequest) return;

    int blocking(Iterable<HazardOnRoute> onRoute) => _avoidable(onRoute).length;
    final left = update.remainingSeconds;
    final saved = left - plan.route.durationSeconds;
    final aheadNow = _onRoute.where((h) => h.alongMeters > update.alongMeters);
    if (saved < math.max(_minSavingSeconds, left * 0.05) ||
        blocking(plan.onRoute) > blocking(aheadNow)) {
      return;
    }
    _showOffer(_RerouteOffer(plan: plan, secondsLeft: _offerSeconds));
  }

  /// Shows [offer], counting down to taking it.
  void _showOffer(_RerouteOffer offer) {
    _offerTimer?.cancel();
    setState(() => _offer = offer);
    _offerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final offer = _offer;
      if (!mounted || offer == null) return;
      if (offer.secondsLeft <= 1) {
        _acceptOffer();
      } else {
        setState(() => _offer = offer.tick());
      }
    });
  }

  void _acceptOffer() {
    final offer = _offer;
    if (offer == null) return;
    _dismissOffer();
    if (!_navigating) return;
    _follow(offer.plan);
    final hazard = offer.hazard;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hazard == null
              ? 'Switched to the faster route'
              : 'Rerouted around '
                    '${_withArticle(hazardStyle(hazard.type).label.toLowerCase())}'
                    ' ahead',
        ),
      ),
    );
  }

  /// Drops the offer, keeping the current route. The hazard stays handled,
  /// so it isn't offered again.
  void _dismissOffer() {
    _offerTimer?.cancel();
    _offerTimer = null;
    _offerRequest++;
    if (_offer != null && mounted) setState(() => _offer = null);
  }

  static bool _sameHazard(AlertEvent a, AlertEvent b) =>
      a.id == b.id ||
      (a.type == b.type &&
          const Distance()(
                LatLng(a.latitude, a.longitude),
                LatLng(b.latitude, b.longitude),
              ) <
              KnownHazards.mergeRadiusMeters);

  void _showHazard(AlertEvent hazard) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${hazardStyle(hazard.type).label} · '
            '${hazard.confirmed ? '' : 'unconfirmed · '}'
            '${hazard.reports == 1 ? '1 report' : '${hazard.reports} cars'}'
            ', last seen ${formatAgo(hazard.timestamp)}',
          ),
        ),
      );
  }

  void _recenter() {
    final me = _me;
    if (me == null || !_mapReady) return;
    _map.move(me, _navigating ? _followZoom : 15);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(knownHazardsProvider, (_, next) => _onHazardsChanged(next));
    final hazards = ref.watch(knownHazardsProvider);
    final route = _route;
    final me = _me;

    return Scaffold(
      appBar: AppBar(title: const Text('Navigate')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: me ?? const LatLng(20, 0),
              initialZoom: me == null ? 2 : 15,
              onMapReady: () {
                _mapReady = true;
                if (_me != null) _map.move(_me!, 15);
              },
              onLongPress: _navigating ? null : (_, point) => _dropPin(point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                // OSM's tile policy blocks clients that don't identify themselves.
                userAgentPackageName: 'io.github.aditya692005.bags',
              ),
              if (_offer != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _offer!.plan.route.points,
                      strokeWidth: 6,
                      color: Colors.green.shade600,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                      pattern: StrokePattern.dashed(segments: const [12, 8]),
                    ),
                  ],
                ),
              if (route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: route.points,
                      strokeWidth: 6,
                      color: Colors.blue.shade700,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  for (final hazard in hazards)
                    Marker(
                      point: LatLng(hazard.latitude, hazard.longitude),
                      width: 26,
                      height: 26,
                      child: _HazardDot(
                        hazard: hazard,
                        onTap: () => _showHazard(hazard),
                      ),
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  if (_from != null)
                    Marker(
                      point: _from!.point,
                      child: const Icon(Icons.trip_origin, color: Colors.green),
                    ),
                  if (_to != null)
                    Marker(
                      point: _to!.point,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.place,
                        color: Colors.red,
                        size: 40,
                      ),
                    ),
                  if (me != null)
                    Marker(
                      point: me,
                      width: 22,
                      height: 22,
                      child: const _MyLocationDot(),
                    ),
                ],
              ),
              const RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: _navigating ? _guidanceCard(context) : _planCard(context),
          ),
          if (_offer != null)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: _RerouteCard(
                offer: _offer!,
                totalSeconds: _offerSeconds,
                currentSeconds: _update?.remainingSeconds,
                onAccept: _acceptOffer,
                onKeep: _dismissOffer,
              ),
            ),
        ],
      ),
      floatingActionButton: me == null || _offer != null
          ? null
          : FloatingActionButton.small(
              onPressed: _recenter,
              tooltip: 'My location',
              child: const Icon(Icons.my_location),
            ),
    );
  }

  Widget _planCard(BuildContext context) {
    final route = _route;
    final theme = Theme.of(context);
    final blocking = _avoidable(_onRoute).length;
    final warnings = _onRoute.length - blocking;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _PlaceField(
                        icon: Icons.trip_origin,
                        iconColor: Colors.green,
                        text: _from?.name ?? 'My location',
                        onTap: () => _pick(origin: true),
                      ),
                      _PlaceField(
                        icon: Icons.place,
                        iconColor: Colors.red,
                        text: _to?.name ?? 'Search or long-press the map',
                        placeholder: _to == null,
                        onTap: () => _pick(origin: false),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _to == null ? null : _swap,
                  icon: const Icon(Icons.swap_vert),
                  tooltip: 'Swap start and destination',
                ),
              ],
            ),
            if (_access != null && _access != LocationAccess.granted)
              _Note(
                'Location ${_access!.name} — navigation needs GPS',
                error: true,
              ),
            if (_error != null) _Note(_error!, error: true),
            if (route != null && !_routing && _avoided > 0)
              _Note(
                'Avoiding $_avoided reported '
                '${_avoided == 1 ? 'hazard' : 'hazards'}',
              ),
            if (route != null && !_routing && blocking > 0)
              _Note(
                'Passes $blocking reported '
                '${blocking == 1 ? 'hazard' : 'hazards'} '
                '— no way around',
                error: true,
              ),
            if (route != null && !_routing && warnings > 0)
              _Note(
                '$warnings reported '
                '${warnings == 1 ? 'hazard' : 'hazards'}'
                ' on the way, not worth a detour — drive carefully',
              ),
            if (_routing)
              const Padding(
                padding: EdgeInsets.only(top: 8, right: 8),
                child: LinearProgressIndicator(),
              ),
            if (route != null && !_routing)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_formatLength(route.distanceMeters)} · '
                        '${_formatDuration(route.durationSeconds)}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton(onPressed: _clear, child: const Text('Clear')),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      onPressed: _start,
                      icon: const Icon(Icons.navigation),
                      label: const Text('Start'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _guidanceCard(BuildContext context) {
    final update = _update;
    final step = update?.nextStep;
    final theme = Theme.of(context);
    final hazardAhead = update == null
        ? null
        : _onRoute.where((h) => h.alongMeters > update.alongMeters).firstOrNull;

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_maneuverIcon(step), size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (update != null && step != null)
                        Text(
                          _formatLength(update.distanceToNextMeters),
                          style: theme.textTheme.headlineSmall,
                        ),
                      Text(
                        step?.instruction ?? 'Follow the route',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (update != null && hazardAhead != null)
              _HazardAhead(
                hazard: hazardAhead.hazard,
                inMeters: hazardAhead.alongMeters - update.alongMeters,
                sameDirection: hazardAhead.sameDirection,
              ),
            if (_error != null) _Note(_error!, error: true),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    update == null
                        ? 'Waiting for GPS...'
                        : '${_formatLength(update.remainingMeters)} · '
                              '${_formatDuration(update.remainingSeconds)} left',
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _stop,
                  icon: const Icon(Icons.close),
                  label: const Text('End'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData _maneuverIcon(RouteStep? step) {
  if (step == null) return Icons.navigation;
  final modifier = step.modifier ?? '';
  return switch (step.maneuverType) {
    'arrive' => Icons.flag,
    'roundabout' || 'rotary' => Icons.roundabout_right,
    'merge' => Icons.merge,
    'fork' => modifier.contains('left') ? Icons.fork_left : Icons.fork_right,
    _ => switch (modifier) {
      'left' => Icons.turn_left,
      'right' => Icons.turn_right,
      'slight left' => Icons.turn_slight_left,
      'slight right' => Icons.turn_slight_right,
      'sharp left' => Icons.turn_sharp_left,
      'sharp right' => Icons.turn_sharp_right,
      'uturn' => Icons.u_turn_left,
      _ => Icons.straight,
    },
  };
}

String _formatLength(double meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 10).round() * 10} m';
}

String _withArticle(String noun) =>
    '${'aeiou'.contains(noun[0]) ? 'an' : 'a'} $noun';

String _formatDuration(double seconds) {
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${minutes % 60} min';
}

class _PlaceField extends StatelessWidget {
  const _PlaceField({
    required this.icon,
    required this.iconColor,
    required this.text,
    required this.onTap,
    this.placeholder = false,
  });

  final IconData icon;
  final Color iconColor;
  final String text;
  final VoidCallback onTap;
  final bool placeholder;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: iconColor),
      title: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: placeholder ? const TextStyle(color: Colors.grey) : null,
      ),
      onTap: onTap,
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 8),
      child: Text(
        text,
        style: TextStyle(
          color: error ? Theme.of(context).colorScheme.error : Colors.blueGrey,
        ),
      ),
    );
  }
}

/// A reported hazard on the map, in its type's color and icon.
class _HazardDot extends StatelessWidget {
  const _HazardDot({required this.hazard, required this.onTap});

  final AlertEvent hazard;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = hazardStyle(hazard.type);
    return Tooltip(
      message: hazard.confirmed ? style.label : '${style.label} (unconfirmed)',
      child: GestureDetector(
        onTap: onTap,
        // Faded until confirmed: shown, but not yet routed around.
        child: Opacity(
          opacity: hazard.confirmed ? 1 : 0.5,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: style.color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(blurRadius: 4, color: Colors.black38),
              ],
            ),
            child: Icon(style.icon, size: 14, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// "Accident in 600 m" under the next maneuver, for a hazard that couldn't
/// be routed around.
class _HazardAhead extends StatelessWidget {
  const _HazardAhead({
    required this.hazard,
    required this.inMeters,
    required this.sameDirection,
  });

  final AlertEvent hazard;
  final double inMeters;

  /// False when only cars coming the other way reported it.
  final bool sameDirection;

  @override
  Widget build(BuildContext context) {
    final style = hazardStyle(hazard.type);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(style.icon, color: style.color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${style.label} in ${_formatLength(inMeters)}'
              '${sameDirection ? '' : ' · seen by oncoming traffic'}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// A new route counting down to being taken automatically: around
/// [hazard], or — with no hazard — quicker now that one was cleared.
class _RerouteOffer {
  const _RerouteOffer({
    required this.plan,
    required this.secondsLeft,
    this.hazard,
  });

  final AlertEvent? hazard;
  final PlannedRoute plan;
  final int secondsLeft;

  _RerouteOffer tick() =>
      _RerouteOffer(hazard: hazard, plan: plan, secondsLeft: secondsLeft - 1);
}

/// "Accident reported ahead" or "Road cleared": take the new route or keep
/// the current one.
class _RerouteCard extends StatelessWidget {
  const _RerouteCard({
    required this.offer,
    required this.totalSeconds,
    required this.currentSeconds,
    required this.onAccept,
    required this.onKeep,
  });

  final _RerouteOffer offer;
  final int totalSeconds;

  /// Time left on the current route, to show what the new one costs.
  final double? currentSeconds;
  final VoidCallback onAccept;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hazard = offer.hazard;
    final style = hazard == null ? null : hazardStyle(hazard.type);
    final route = offer.plan.route;
    final current = currentSeconds;
    final extraMinutes = current == null
        ? 0
        : ((route.durationSeconds - current) / 60).round();
    final difference = switch (extraMinutes) {
      > 0 => ' (+$extraMinutes min)',
      < 0 => ' (${-extraMinutes} min faster)',
      _ => '',
    };

    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  style?.icon ?? Icons.bolt,
                  color: style?.color ?? Colors.green.shade700,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        style == null
                            ? 'Road cleared — faster route'
                            : '${style.label} reported ahead',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'New route: ${_formatLength(route.distanceMeters)} · '
                        '${_formatDuration(route.durationSeconds)}$difference',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: offer.secondsLeft / totalSeconds),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onKeep,
                    child: const Text('Keep route'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: onAccept,
                    child: Text('New route (${offer.secondsLeft})'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MyLocationDot extends StatelessWidget {
  const _MyLocationDot();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
      ),
    );
  }
}

/// A search result; [place] null means "my location". Wrapped so that
/// choosing my location is distinguishable from dismissing the search.
class _Pick {
  const _Pick(this.place);

  final Place? place;
}

/// Place search. Runs only on submit, never per keystroke: Nominatim's usage
/// policy forbids search-as-you-type on its public server.
class _PlaceSearch extends SearchDelegate<_Pick?> {
  _PlaceSearch({
    required this.service,
    required this.near,
    required this.offerMyLocation,
  }) : super(searchFieldLabel: 'Search for a place');

  final RoutingService service;
  final LatLng? near;
  final bool offerMyLocation;

  String? _lastQuery;
  Future<List<Place>>? _results;

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const BackButtonIcon(),
    onPressed: () => close(context, null),
  );

  @override
  Widget buildSuggestions(BuildContext context) {
    return ListView(
      children: [
        if (offerMyLocation)
          ListTile(
            leading: const Icon(Icons.my_location),
            title: const Text('My location'),
            onTap: () => close(context, const _Pick(null)),
          ),
        const ListTile(
          leading: Icon(Icons.keyboard_return),
          title: Text('Type a place or address, then press search'),
          enabled: false,
        ),
      ],
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return buildSuggestions(context);

    // buildResults runs on every rebuild; only hit the server for a new query.
    if (trimmed != _lastQuery) {
      _lastQuery = trimmed;
      _results = service.search(trimmed, near: near);
    }

    return FutureBuilder<List<Place>>(
      future: _results,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${snapshot.error}'),
          );
        }
        final places = snapshot.data ?? const [];
        if (places.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No matches'),
          );
        }
        return ListView(
          children: [
            for (final place in places)
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(
                  place.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => close(context, _Pick(place)),
              ),
          ],
        );
      },
    );
  }
}
