import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hub.dart';
import '../models.dart';
import 'add_lights_page.dart';
import 'common.dart';
import 'diagnostics_page.dart';
import 'group_edit_page.dart';
import 'info_sheets.dart';
import 'routines_page.dart';
import 'target_page.dart';

/// Home: groups and lights by name, each with an (i) for details and a
/// power switch. Tap a row for its controls.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Future<void> _allOff(BuildContext context, HueHub hub) async {
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

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final theme = Theme.of(context);
        final favorites = store.favorites;
        Widget tile(String id, {Key? key}) {
          final group = store.group(id);
          return _TargetTile(
            key: key,
            id: id,
            name: store.nameOf(id),
            lightIds: store.lightIdsFor(id),
            hub: hub,
            favorite: store.isFavorite(id),
            onInfo: () => group != null
                ? showGroupInfo(context, id)
                : showLightInfo(context, id),
            onOpen: () => _push(context, TargetPage(targetId: id)),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Lights'),
            actions: [
              if (store.lights.isNotEmpty)
                IconButton(
                  tooltip: 'All off',
                  icon: const Icon(Icons.power_settings_new),
                  onPressed: () => _allOff(context, hub),
                ),
              IconButton(
                tooltip: 'Routines',
                icon: const Icon(Icons.schedule),
                onPressed: () => _push(context, const RoutinesPage()),
              ),
              IconButton(
                tooltip: 'Add lights',
                icon: const Icon(Icons.add),
                onPressed: () => _push(context, const AddLightsPage()),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'diagnostics') {
                    _push(context, const DiagnosticsPage());
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'diagnostics',
                    child: Text('Diagnostics'),
                  ),
                ],
              ),
            ],
          ),
          body: store.lights.isEmpty
              ? _Empty(onAdd: () => _push(context, const AddLightsPage()))
              : CustomScrollView(
                  slivers: [
                    if (favorites.isNotEmpty) ...[
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: _Header('Favourites'),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        sliver: SliverReorderableList(
                          itemCount: favorites.length,
                          onReorderStart: (_) => HapticFeedback.mediumImpact(),
                          onReorderItem: store.moveFavorite,
                          proxyDecorator: (child, _, animation) => Material(
                            color: Colors.transparent,
                            elevation: 6 * animation.value,
                            shadowColor: Colors.black38,
                            borderRadius: BorderRadius.circular(20),
                            child: child,
                          ),
                          itemBuilder: (context, i) =>
                              ReorderableDelayedDragStartListener(
                                key: ValueKey('fav-${favorites[i]}'),
                                index: i,
                                child: tile(favorites[i]),
                              ),
                        ),
                      ),
                    ],
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
                      sliver: SliverList.list(
                        children: [
                          _Header(
                            'Groups',
                            action: TextButton.icon(
                              onPressed: () =>
                                  _push(context, const GroupEditPage()),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('New group'),
                            ),
                          ),
                          if (store.groups.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: Text(
                                'Group lights to control them together.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          for (final g in store.groups)
                            if (!store.isFavorite(g.id)) tile(g.id),
                          const _Header('Lights'),
                          for (final l in store.lights)
                            if (!store.isFavorite(l.id)) tile(l.id),
                          if (favorites.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                'Tip: tap (i) → Favourite to pin lights and '
                                'groups to the top. Hold and drag to reorder.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    super.key,
    this.favorite = false,
    required this.id,
    required this.name,
    required this.lightIds,
    required this.hub,
    required this.onInfo,
    required this.onOpen,
  });

  final String id;
  final String name;
  final bool favorite;
  final List<String> lightIds;
  final HueHub hub;
  final VoidCallback onInfo;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final lights = hub.connected(lightIds);
    final on = lights.any((l) => l.state.on);
    final lit =
        lights.where((l) => l.state.on).firstOrNull ?? lights.firstOrNull;
    final color = lit == null
        ? null
        : dimmed(stateColor(lit.state), lit.state.brightness);

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 8),
        leading: LightDot(color: color, on: on),
        title: Row(
          children: [
            Flexible(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (favorite) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.star_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ],
        ),
        onTap: onOpen,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Details',
              icon: const Icon(Icons.info_outline),
              onPressed: onInfo,
            ),
            Switch(
              value: on,
              onChanged: lights.isEmpty
                  ? null
                  : (v) async {
                      HapticFeedback.selectionClick();
                      try {
                        await hub.setPower(lightIds, v);
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, {this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 0, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          ?action,
        ],
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
