import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/providers.dart';
import '../../core/services/location_service.dart';
import 'navigation_providers.dart';
import 'route_progress.dart';
import 'routing_service.dart';

/// Map with A-to-B driving routes and live turn-by-turn guidance.
///
/// Pick a start (defaults to the current location) and a destination by
/// search or by long-pressing the map, then Start to follow the route: the
/// map tracks the car, shows the next maneuver, and reroutes after a wrong
/// turn. Independent of the detection pipeline; it only shares
/// [LocationService].
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
  bool _routing = false;
  String? _error;

  /// Bumped per route request, so a slow response can't overwrite the route
  /// for a destination picked after it.
  int _routeRequest = 0;

  RouteProgress? _progress;
  NavUpdate? _update;
  StreamSubscription<Position>? _positionSub;
  DateTime? _lastReroute;

  bool get _navigating => _positionSub != null;

  /// Further than this from the route line counts as a wrong turn. Generous,
  /// because GPS in a city is routinely 10–30 m off.
  static const double _offRouteMeters = 50;

  /// Minimum gap between reroutes, so a bad GPS patch doesn't hammer the
  /// public routing server with a request per fix.
  static const Duration _rerouteCooldown = Duration(seconds: 15);

  static const double _followZoom = 17;

  @override
  void initState() {
    super.initState();
    // Deferred because it reads providers, which can't happen mid-construction.
    WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
  }

  @override
  void dispose() {
    _positionSub?.cancel();
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
      final route = await ref
          .read(routingServiceProvider)
          .route(from, to.point);
      if (!mounted || request != _routeRequest) return;
      setState(() => _route = route);
      _fit(route);
    } on Exception catch (error) {
      if (mounted && request == _routeRequest) {
        setState(() {
          _route = null;
          _error = '$error';
        });
      }
    } finally {
      if (mounted && request == _routeRequest) setState(() => _routing = false);
    }
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
    setState(() {
      _progress = progress;
      _update = progress.update(me);
      _lastReroute = null;
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
      _reroute(point);
    }
  }

  Future<void> _reroute(LatLng from) async {
    final to = _to;
    final now = DateTime.now();
    final last = _lastReroute;
    if (to == null ||
        (last != null && now.difference(last) < _rerouteCooldown)) {
      return;
    }
    _lastReroute = now;

    try {
      final route = await ref
          .read(routingServiceProvider)
          .route(from, to.point);
      if (!mounted || !_navigating) return;
      final progress = RouteProgress(route);
      setState(() {
        _route = route;
        _progress = progress;
        _update = progress.update(from);
      });
    } on Exception {
      // Keep guiding along the old route; the next off-route fix after the
      // cooldown tries again.
    }
  }

  void _recenter() {
    final me = _me;
    if (me == null || !_mapReady) return;
    _map.move(me, _navigating ? _followZoom : 15);
  }

  @override
  Widget build(BuildContext context) {
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
        ],
      ),
      floatingActionButton: me == null
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
