import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../color_utils.dart';
import '../hub.dart';
import '../hue_ble.dart';
import '../hue_protocol_ext.dart';
import '../models.dart';
import '../paced_value.dart';
import '../store.dart';
import 'add_lights_page.dart';
import 'common.dart';
import 'designs.dart';
import 'diagnostics_page.dart';
import 'group_edit_page.dart';
import 'info_sheets.dart';
import 'routines_page.dart';
import 'target_page.dart';

/// Home. One shell (top bar, design switcher, all off) around one of four
/// layouts, picked with the Design button: Clear, Glow, Rooms, Wireframe.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final design = AppDesign.fromName(store.design);
        final nav = _Nav(context, store, hub);
        final lightsOn = hub
            .connected([for (final l in store.lights) l.id])
            .where((l) => l.state.on)
            .length;
        return Scaffold(
          appBar: AppBar(
            title: Text(design == AppDesign.glow ? 'Home' : 'Lights'),
            actions: [
              IconButton(
                tooltip: 'Design',
                icon: const Icon(Icons.palette_outlined),
                onPressed: () => showDesignPicker(context),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'routines' => nav.push(const RoutinesPage()),
                  'add' => nav.push(const AddLightsPage()),
                  'group' => nav.push(const GroupEditPage()),
                  'reorder' => nav.push(const _ReorderFavoritesPage()),
                  _ => nav.push(const DiagnosticsPage()),
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'routines',
                    child: Text('Routines'),
                  ),
                  const PopupMenuItem(value: 'add', child: Text('Add lights')),
                  const PopupMenuItem(value: 'group', child: Text('New group')),
                  if (store.favorites.length > 1)
                    const PopupMenuItem(
                      value: 'reorder',
                      child: Text('Reorder favourites'),
                    ),
                  const PopupMenuItem(
                    value: 'diagnostics',
                    child: Text('Diagnostics'),
                  ),
                ],
              ),
            ],
          ),
          body: store.lights.isEmpty
              ? _Empty(onAdd: () => nav.push(const AddLightsPage()))
              : Column(
                  children: [
                    _MasterBar(nav, design: design),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: KeyedSubtree(
                          key: ValueKey(design),
                          child: switch (design) {
                            AppDesign.clear => _ListLayout(nav, dense: false),
                            AppDesign.wireframe => _ListLayout(
                              nav,
                              dense: true,
                            ),
                            AppDesign.glow => _GlowLayout(
                              nav,
                              lightsOn: lightsOn,
                            ),
                            AppDesign.rooms => _RoomsLayout(nav),
                          },
                        ),
                      ),
                    ),
                  ],
                ),
          bottomNavigationBar: store.lights.isEmpty
              ? null
              : _BottomBar(nav, design: design),
        );
      },
    );
  }
}

/// What every layout needs: data plus the common actions.
class _Nav {
  _Nav(this.context, this.store, this.hub);

  final BuildContext context;
  final AppStore store;
  final HueHub hub;

  void push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  void open(String id) => push(TargetPage(targetId: id));

  void info(String id) => store.group(id) != null
      ? showGroupInfo(context, id)
      : showLightInfo(context, id);

  List<String> ids(String id) => store.lightIdsFor(id);

  bool connected(String id) => hub.connected(ids(id)).isNotEmpty;

  bool isOn(String id) => hub.anyOn(ids(id));

  /// Full-brightness colour of the first lit light, or null.
  Color? color(String id) {
    final lit = hub.connected(ids(id)).where((l) => l.state.on).firstOrNull;
    return lit == null ? null : stateColor(lit.state);
  }

  /// "80% · 2700 K · 2/3 on", "Off", "Not connected".
  String summary(String id) {
    final all = ids(id);
    final lights = hub.connected(all);
    if (lights.isEmpty) return all.isEmpty ? 'No lights' : 'Not connected';
    final lit = lights.where((l) => l.state.on).toList();
    if (lit.isEmpty) return 'Off';
    final s = lit.first.state;
    final pct = (s.brightness / maxBrightness * 100).round();
    final what = s.effect != HueEffect.none
        ? s.effect.label
        : s.mode == HueMode.color
        ? 'Colour'
        : s.mireds != null
        ? '${miredsToKelvin(s.mireds!)} K'
        : '';
    final count = all.length > 1 ? ' · ${lit.length}/${all.length} on' : '';
    return '$pct%${what.isEmpty ? '' : ' · $what'}$count';
  }

  Future<void> toggle(String id, bool on) async {
    HapticFeedback.selectionClick();
    try {
      await hub.setPower(ids(id), on);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> allOff() async {
    HapticFeedback.mediumImpact();
    final Map<String, LightLook> before;
    try {
      before = await hub.allOff();
    } catch (e) {
      if (context.mounted) showError(context, e);
      return;
    }
    if (!context.mounted) return;
    final wasOn = {
      for (final e in before.entries)
        if (e.value.on) e.key: e.value,
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('All lights off'),
          action: wasOn.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Undo',
                  onPressed: () => hub.applyLooks(wasOn, manual: false),
                ),
        ),
      );
  }

  /// Favourites, then the other groups, then the other lights.
  (List<String>, List<String>, List<String>) sections() => (
    store.favorites,
    [
      for (final g in store.groups)
        if (!store.isFavorite(g.id)) g.id,
    ],
    [
      for (final l in store.lights)
        if (!store.isFavorite(l.id)) l.id,
    ],
  );
}

// --- Clear and Wireframe: lists

class _ListLayout extends StatelessWidget {
  const _ListLayout(this.nav, {required this.dense});

  final _Nav nav;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (favorites, groups, lights) = nav.sections();
    final theme = Theme.of(context);
    final pad = EdgeInsets.symmetric(horizontal: dense ? 10 : 14);
    Widget row(String id, {Key? key}) => _Row(
      key: key,
      nav: nav,
      id: id,
      dense: dense,
      favorite: nav.store.isFavorite(id),
    );
    return CustomScrollView(
      slivers: [
        if (favorites.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(padding: pad, child: _Header('Favourites', dense)),
          ),
          SliverPadding(
            padding: pad,
            sliver: SliverReorderableList(
              itemCount: favorites.length,
              onReorderStart: (_) => HapticFeedback.mediumImpact(),
              onReorderItem: nav.store.moveFavorite,
              proxyDecorator: (child, _, animation) => Material(
                color: Colors.transparent,
                elevation: 6 * animation.value,
                borderRadius: BorderRadius.circular(20),
                child: child,
              ),
              itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
                key: ValueKey('fav-${favorites[i]}'),
                index: i,
                child: row(favorites[i]),
              ),
            ),
          ),
        ],
        SliverPadding(
          padding: pad.copyWith(bottom: 24),
          sliver: SliverList.list(
            children: [
              _Header('Groups', dense),
              if (groups.isEmpty && nav.store.groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Text(
                    'Group lights to control them together (⋮ → New group).',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final id in groups) row(id),
              _Header('Lights', dense),
              for (final id in lights) row(id),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.nav,
    required this.id,
    required this.dense,
    required this.favorite,
  });

  final _Nav nav;
  final String id;
  final bool dense;
  final bool favorite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = nav.connected(id);
    final on = nav.isOn(id);
    final c = nav.color(id);
    return Card(
      child: ListTile(
        minTileHeight: dense ? 48 : 68,
        contentPadding: EdgeInsets.only(left: dense ? 12 : 16, right: 6),
        leading: dense
            ? Icon(
                on ? Icons.lightbulb : Icons.lightbulb_outline,
                size: 20,
                color: connected ? null : theme.colorScheme.outline,
              )
            : LightDot(
                color: connected
                    ? (c ?? theme.colorScheme.surfaceContainerHighest)
                    : null,
                on: on,
                size: 22,
              ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                nav.store.nameOf(id),
                overflow: TextOverflow.ellipsis,
                style:
                    (dense
                            ? theme.textTheme.bodyLarge
                            : theme.textTheme.titleLarge?.copyWith(
                                fontSize: 20,
                              ))
                        ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (favorite) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.star_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
        subtitle: dense ? Text(nav.summary(id)) : null,
        onTap: () => nav.open(id),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Details',
              icon: const Icon(Icons.info_outline),
              onPressed: () => nav.info(id),
            ),
            Switch(
              value: on,
              onChanged: connected ? (v) => nav.toggle(id, v) : null,
            ),
          ],
        ),
      ),
    );
  }
}

// --- Glow: tiles

class _GlowLayout extends StatelessWidget {
  const _GlowLayout(this.nav, {required this.lightsOn});

  final _Nav nav;
  final int lightsOn;

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5 || h >= 21) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (favorites, groups, lights) = nav.sections();
    SliverGrid grid(List<String> ids) => SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.08,
      ),
      itemCount: ids.length,
      itemBuilder: (context, i) => _GlowTile(nav, ids[i]),
    );
    SliverPadding section(String title, List<String> ids) => SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(child: _Header(title, false)),
          grid(ids),
        ],
      ),
    );
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting(),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  lightsOn == 1 ? '1 light on' : '$lightsOn lights on',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (favorites.isNotEmpty) section('Favourites', favorites),
        if (groups.isNotEmpty) section('Groups', groups),
        if (lights.isNotEmpty) section('Lights', lights),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _GlowTile extends StatelessWidget {
  const _GlowTile(this.nav, this.id);

  final _Nav nav;
  final String id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = nav.connected(id);
    final on = nav.isOn(id);
    final c = nav.color(id);
    final lit = on && c != null;
    final fg = lit
        ? (ThemeData.estimateBrightnessForColor(c) == Brightness.dark
              ? Colors.white
              : const Color(0xFF1A120A))
        : theme.colorScheme.onSurface;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: lit
              ? RadialGradient(
                  center: const Alignment(-0.6, -0.8),
                  radius: 1.4,
                  colors: [
                    Color.lerp(c, Colors.white, 0.35)!,
                    c,
                    Color.lerp(c, Colors.black, 0.45)!,
                  ],
                  stops: const [0, 0.55, 1],
                )
              : null,
          color: lit ? null : const Color(0xFF1A1816),
          border: lit
              ? null
              : Border.all(color: const Color(0xFF2E2B27), width: 1.5),
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            if (lit)
              BoxShadow(color: c.withValues(alpha: 0.45), blurRadius: 24),
          ],
        ),
        child: InkWell(
          onTap: () => nav.open(id),
          onLongPress: () => nav.info(id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        nav.store.nameOf(id),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: fg,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: on ? 'Turn off' : 'Turn on',
                      onPressed: connected ? () => nav.toggle(id, !on) : null,
                      icon: Icon(Icons.power_settings_new, color: fg),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        nav.summary(id),
                        maxLines: 2,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Details',
                      onPressed: () => nav.info(id),
                      icon: Icon(Icons.info_outline, color: fg),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- Rooms: a card per group

class _RoomsLayout extends StatelessWidget {
  const _RoomsLayout(this.nav);

  final _Nav nav;

  @override
  Widget build(BuildContext context) {
    final store = nav.store;
    final theme = Theme.of(context);
    final groups = [
      for (final id in store.favorites)
        if (store.group(id) != null) id,
      for (final g in store.groups)
        if (!store.isFavorite(g.id)) g.id,
    ];
    final grouped = {for (final g in store.groups) ...g.lightIds};
    final loose = [
      for (final id in store.favorites)
        if (store.light(id) != null && !grouped.contains(id)) id,
      for (final l in store.lights)
        if (!grouped.contains(l.id) && !store.isFavorite(l.id)) l.id,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
      children: [
        for (final id in groups) _RoomCard(nav, id),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Rooms are your groups. Create one with ⋮ → New group.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        if (loose.isNotEmpty) ...[
          _Header(groups.isEmpty ? 'Lights' : 'Other lights', false),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.35,
            children: [for (final id in loose) _MiniCard(nav, id)],
          ),
        ],
      ],
    );
  }
}

class _RoomCard extends StatefulWidget {
  const _RoomCard(this.nav, this.id);

  final _Nav nav;
  final String id;

  @override
  State<_RoomCard> createState() => _RoomCardState();
}

class _RoomCardState extends State<_RoomCard> {
  late final _brightness = PacedValue<double>(
    send: (v, {required confirmed}) => widget.nav.hub.setBrightness(
      widget.nav.ids(widget.id),
      v.round(),
      fast: !confirmed,
    ),
    onError: (e) {
      if (mounted) showError(context, e);
    },
  );

  @override
  void dispose() {
    _brightness.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    final id = widget.id;
    final theme = Theme.of(context);
    final ids = nav.ids(id);
    final lights = nav.hub.connected(ids);
    final connected = lights.isNotEmpty;
    final on = nav.isOn(id);
    final lit =
        lights.where((l) => l.state.on).firstOrNull ?? lights.firstOrNull;
    final c = nav.color(id) ?? kelvinColor(2700);
    return Card(
      elevation: 1,
      shadowColor: const Color(0x22503214),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                LightDot(color: connected ? c : null, on: on, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () => nav.open(id),
                    child: Text(
                      nav.store.nameOf(id),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Details',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => nav.info(id),
                ),
                Switch(
                  value: on,
                  onChanged: connected ? (v) => nav.toggle(id, v) : null,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ListenableBuilder(
              listenable: _brightness,
              builder: (context, _) => FatSlider(
                semanticLabel: '${nav.store.nameOf(id)} brightness',
                enabled: connected,
                value:
                    _brightness.shown ??
                    (lit?.state.brightness ?? maxBrightness).toDouble(),
                min: minBrightness.toDouble(),
                max: maxBrightness.toDouble(),
                gradient: LinearGradient(colors: [dimmed(c, 1), c]),
                dragging: _brightness.dragging,
                onChangeStart: (v) {
                  if (!on) nav.toggle(id, true);
                  _brightness.start(v);
                },
                onChanged: _brightness.update,
                onChangeEnd: _brightness.end,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final lightId in ids)
                  ActionChip(
                    avatar: LightDot(
                      color: nav.connected(lightId)
                          ? (nav.color(lightId) ??
                                theme.colorScheme.surfaceContainerHighest)
                          : null,
                      on: nav.isOn(lightId),
                      size: 12,
                    ),
                    label: Text(nav.store.nameOf(lightId)),
                    onPressed: () => nav.open(lightId),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  const _MiniCard(this.nav, this.id);

  final _Nav nav;
  final String id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = nav.connected(id);
    final on = nav.isOn(id);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => nav.open(id),
        onLongPress: () => nav.info(id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  LightDot(
                    color: connected
                        ? (nav.color(id) ??
                              theme.colorScheme.surfaceContainerHighest)
                        : null,
                    on: on,
                    size: 12,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      nav.store.nameOf(id),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(nav.summary(id), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: on
                    ? FilledButton(
                        onPressed: connected
                            ? () => nav.toggle(id, false)
                            : null,
                        child: const Text('On'),
                      )
                    : OutlinedButton(
                        onPressed: connected
                            ? () => nav.toggle(id, true)
                            : null,
                        child: const Text('Off'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Shared bits

/// Dims every light that is on, next to All off. With everything off,
/// dragging switches all lights on.
class _MasterBar extends StatefulWidget {
  const _MasterBar(this.nav, {required this.design});

  final _Nav nav;
  final AppDesign design;

  @override
  State<_MasterBar> createState() => _MasterBarState();
}

class _MasterBarState extends State<_MasterBar> {
  late final _brightness = PacedValue<double>(
    send: (v, {required confirmed}) =>
        widget.nav.hub.setBrightness(_litIds(), v.round(), fast: !confirmed),
    onError: (e) {
      if (mounted) showError(context, e);
    },
  );

  List<String> get _allIds => [for (final l in widget.nav.store.lights) l.id];

  List<String> _litIds() => [
    for (final id in _allIds)
      if (widget.nav.hub.stateOf(id)?.on ?? false) id,
  ];

  @override
  void dispose() {
    _brightness.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    final theme = Theme.of(context);
    final lit = nav.hub.connected(_allIds).where((l) => l.state.on).toList();
    final connected = nav.hub.connected(_allIds).isNotEmpty;
    final average = lit.isEmpty
        ? maxBrightness.toDouble()
        : lit.map((l) => l.state.brightness).reduce((a, b) => a + b) /
              lit.length;
    final glow = widget.design == AppDesign.glow;
    final wire = widget.design == AppDesign.wireframe;
    final warm = kelvinColor(2700);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: _brightness,
              builder: (context, _) {
                final v = _brightness.shown ?? average;
                return Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    FatSlider(
                      semanticLabel: 'Dim all lights',
                      enabled: connected,
                      value: v,
                      min: minBrightness.toDouble(),
                      max: maxBrightness.toDouble(),
                      gradient: wire
                          ? const LinearGradient(
                              colors: [Color(0xFFDDDDDD), Color(0xFF888888)],
                            )
                          : LinearGradient(colors: [dimmed(warm, 1), warm]),
                      dragging: _brightness.dragging,
                      onChangeStart: (v) async {
                        HapticFeedback.selectionClick();
                        if (_litIds().isEmpty) {
                          await nav.hub.setPower(_allIds, true);
                        }
                        _brightness.start(v);
                      },
                      onChanged: _brightness.update,
                      onChangeEnd: _brightness.end,
                    ),
                    IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: Text(
                          lit.isEmpty
                              ? 'All lights off'
                              : 'All ${(v / maxBrightness * 100).round()}%',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: v > 150 && !wire
                                ? const Color(0xFF3A2A1A)
                                : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: glow
                    ? const Color(0xFF2A2724)
                    : theme.colorScheme.onSurface,
                foregroundColor: glow
                    ? Colors.white
                    : theme.colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(wire ? 8 : 26),
                ),
              ),
              onPressed: connected ? nav.allOff : null,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('All off'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar(this.nav, {required this.design});

  final _Nav nav;
  final AppDesign design;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget button(String label, IconData icon, VoidCallback onTap) => Expanded(
      child: SizedBox(
        height: design == AppDesign.wireframe ? 48 : 54,
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon),
          label: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.fromLTRB(
          12,
          4,
          12,
          design == AppDesign.glow ? 6 : 4,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: design == AppDesign.glow
              ? const Color(0xFF1C1A18)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(
            design == AppDesign.wireframe ? 8 : 28,
          ),
          border: design == AppDesign.wireframe
              ? Border.all(color: Colors.black87, width: 1.5)
              : null,
        ),
        child: Row(
          children: [
            button(
              'Routines',
              Icons.schedule,
              () => nav.push(const RoutinesPage()),
            ),
            button(
              'Add light',
              Icons.add,
              () => nav.push(const AddLightsPage()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, this.dense);

  final String title;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(6, dense ? 12 : 18, 6, 6),
      child: Text(
        dense ? title.toUpperCase() : title,
        style: theme.textTheme.titleSmall?.copyWith(
          letterSpacing: dense ? 1.2 : 0.3,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lightbulb_outline,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('No lights yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add your Hue Bluetooth lights to control them here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add lights'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reorder favourites; works in every design.
class _ReorderFavoritesPage extends StatelessWidget {
  const _ReorderFavoritesPage();

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final favorites = store.favorites;
        return Scaffold(
          appBar: AppBar(title: const Text('Reorder favourites')),
          body: ReorderableListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: favorites.length,
            onReorderItem: store.moveFavorite,
            itemBuilder: (context, i) => Card(
              key: ValueKey(favorites[i]),
              child: ListTile(
                leading: const Icon(Icons.drag_handle),
                title: Text(store.nameOf(favorites[i])),
                subtitle: Text(
                  store.group(favorites[i]) != null ? 'Group' : 'Light',
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The Design button: pick one of the four designs, with a preview of each.
Future<void> showDesignPicker(BuildContext context) {
  final store = AppScope.of(context).store;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final current = AppDesign.fromName(store.design);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  'Design',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.1,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final d in AppDesign.values)
                    _DesignCard(
                      design: d,
                      selected: d == current,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        store.setDesign(d.name);
                        Navigator.pop(context);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _DesignCard extends StatelessWidget {
  const _DesignCard({
    required this.design,
    required this.selected,
    required this.onTap,
  });

  final AppDesign design;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, card, accent) = design.swatch;
    final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final fg = dark ? Colors.white : Colors.black87;
    final scheme = Theme.of(context).colorScheme;
    final radius = design == AppDesign.wireframe ? 6.0 : 14.0;
    Widget bar(Color c, double w) => Container(
      width: w,
      height: 16,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(radius / 2),
        border: design == AppDesign.wireframe
            ? Border.all(color: Colors.black87)
            : null,
      ),
    );
    return Semantics(
      selected: selected,
      button: true,
      label: '${design.label} design',
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 3 : 1,
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        design.label,
                        style: TextStyle(
                          color: fg,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check_circle, color: accent, size: 20),
                  ],
                ),
                const SizedBox(height: 8),
                bar(card, double.infinity),
                const SizedBox(height: 6),
                Row(
                  children: [
                    bar(accent, 34),
                    const SizedBox(width: 6),
                    Expanded(child: bar(card, double.infinity)),
                  ],
                ),
                const Spacer(),
                Text(
                  design.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
