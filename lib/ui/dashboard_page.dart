import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hub.dart';
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

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Lights'),
            actions: [
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
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
                  children: [
                    _Header(
                      'Groups',
                      action: TextButton.icon(
                        onPressed: () => _push(context, const GroupEditPage()),
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
                      _TargetTile(
                        id: g.id,
                        name: g.name,
                        lightIds: store.lightIdsFor(g.id),
                        hub: hub,
                        onInfo: () => showGroupInfo(context, g.id),
                        onOpen: () =>
                            _push(context, TargetPage(targetId: g.id)),
                      ),
                    const _Header('Lights'),
                    for (final l in store.lights)
                      _TargetTile(
                        id: l.id,
                        name: l.name,
                        lightIds: [l.id],
                        hub: hub,
                        onInfo: () => showLightInfo(context, l.id),
                        onOpen: () =>
                            _push(context, TargetPage(targetId: l.id)),
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
    required this.id,
    required this.name,
    required this.lightIds,
    required this.hub,
    required this.onInfo,
    required this.onOpen,
  });

  final String id;
  final String name;
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
        title: Text(name, style: Theme.of(context).textTheme.titleMedium),
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
