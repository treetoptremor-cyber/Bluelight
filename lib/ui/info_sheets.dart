import 'package:flutter/material.dart';

import '../hub.dart';
import '../hue_ble.dart';
import '../hue_protocol_ext.dart';
import 'common.dart';
import 'group_edit_page.dart';
import 'power_on_sheet.dart';

/// The (i) details for one light: status, model, capabilities, groups, id,
/// rename and remove.
Future<void> showLightInfo(BuildContext context, String lightId) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _LightInfo(lightId),
    );

/// The (i) details for a group: members and their status, edit, delete.
Future<void> showGroupInfo(BuildContext context, String groupId) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _GroupInfo(groupId),
    );

class _LightInfo extends StatelessWidget {
  const _LightInfo(this.id);

  final String id;

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final saved = store.light(id);
        if (saved == null) return const SizedBox(height: 120);
        final theme = Theme.of(context);
        final status = hub.statusOf(id);
        final light = hub.lightOf(id);
        final connected = status == LinkStatus.connected;
        final groups = [
          for (final g in store.groups)
            if (g.lightIds.contains(id)) g.name,
        ];
        final supports = [
          'Brightness',
          if (connected && light!.supportsTemperature) 'White',
          if (connected && light!.supportsColor) 'Colour',
        ];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        saved.name,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Rename',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final name = await askName(
                          context,
                          title: 'Rename light',
                          initial: saved.name,
                        );
                        if (name != null) await store.renameLight(id, name);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _Row(
                  label: 'Status',
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5, right: 8),
                        child: CircleAvatar(
                          radius: 5,
                          backgroundColor: statusColor(
                            status,
                            theme.colorScheme,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(statusText(status, hub.errorOf(id))),
                      ),
                    ],
                  ),
                ),
                if (!connected)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => hub.retry(id),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry now'),
                    ),
                  ),
                if (light?.modelNumber case final model?)
                  _Row(label: 'Model', child: Text(model)),
                if (connected && light!.name != saved.name)
                  _Row(label: 'Bulb name', child: Text(light.name)),
                if (connected)
                  _Row(label: 'Supports', child: Text(supports.join(' · '))),
                if (connected && light!.supportsSchedules)
                  _Row(
                    label: 'On the bulb',
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${AppScope.of(context).scheduler?.armedCount(id) ?? 0} '
                            'upcoming routine runs stored',
                          ),
                        ),
                        TextButton(
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            showDragHandle: true,
                            isScrollControlled: true,
                            builder: (_) => _BulbSchedules(id),
                          ),
                          child: const Text('View'),
                        ),
                      ],
                    ),
                  ),
                _Row(
                  label: 'Groups',
                  child: Text(groups.isEmpty ? 'None' : groups.join(', ')),
                ),
                _Row(
                  label: 'Bluetooth ID',
                  child: SelectableText(id, style: theme.textTheme.bodySmall),
                ),
                const SizedBox(height: 8),
                _Actions(
                  favorite: store.isFavorite(id),
                  onFavorite: (v) => store.setFavorite(id, v),
                  onPowerOn: connected && light!.supportsPowerOn
                      ? () => showPowerOnSheet(context, [id])
                      : null,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Remove ${saved.name}?',
                      message:
                          'It is removed from this app, its groups, and its '
                          'presets and routines. The light itself is not '
                          'changed and keeps working in the Hue app.',
                      action: 'Remove',
                    );
                    if (!ok || !context.mounted) return;
                    Navigator.pop(context);
                    await store.removeLight(id);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove from this app'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GroupInfo extends StatelessWidget {
  const _GroupInfo(this.id);

  final String id;

  @override
  Widget build(BuildContext context) {
    return AppBuilder(
      builder: (context, store, hub) {
        final group = store.group(id);
        if (group == null) return const SizedBox(height: 120);
        final theme = Theme.of(context);
        final members = store.lightIdsFor(id);
        final connected = hub.connected(members).length;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.name, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  '$connected of ${members.length} lights connected',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                for (final lightId in members)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 5,
                      backgroundColor: statusColor(
                        hub.statusOf(lightId),
                        theme.colorScheme,
                      ),
                    ),
                    minLeadingWidth: 10,
                    title: Text(store.nameOf(lightId)),
                    subtitle: hub.statusOf(lightId) == LinkStatus.connected
                        ? null
                        : Text(
                            statusText(
                              hub.statusOf(lightId),
                              hub.errorOf(lightId),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                const SizedBox(height: 8),
                _Actions(
                  favorite: store.isFavorite(id),
                  onFavorite: (v) => store.setFavorite(id, v),
                  onPowerOn:
                      hub.connected(members).any((l) => l.supportsPowerOn)
                      ? () => showPowerOnSheet(context, members)
                      : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.pop(context);
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => GroupEditPage(groupId: id),
                            ),
                          );
                        },
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit group'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: () async {
                          final ok = await confirm(
                            context,
                            title: 'Delete ${group.name}?',
                            message:
                                'The group, its presets and its routines are '
                                'deleted. The lights stay.',
                            action: 'Delete',
                          );
                          if (!ok || !context.mounted) return;
                          Navigator.pop(context);
                          await store.removeGroup(id);
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                      ),
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
}

/// The schedules actually stored on a bulb, read back live, with a button
/// to re-sync this app's routines onto it.
class _BulbSchedules extends StatefulWidget {
  const _BulbSchedules(this.lightId);

  final String lightId;

  @override
  State<_BulbSchedules> createState() => _BulbSchedulesState();
}

class _BulbSchedulesState extends State<_BulbSchedules> {
  List<StoredSchedule>? _items;
  String? _error;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null && _error == null && !_busy) _load();
  }

  Future<void> _load() async {
    final light = AppScope.of(context).hub.lightOf(widget.lightId);
    setState(() => _busy = true);
    try {
      if (light == null) throw StateError('Not connected');
      final items = <StoredSchedule>[];
      for (final id in await light.listSchedules()) {
        final s = await light.readSchedule(id);
        if (s != null) items.add(s);
      }
      items.sort((a, b) => a.start.compareTo(b.start));
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = describeBleError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    final scheduler = AppScope.of(context).scheduler;
    setState(() {
      _busy = true;
      _items = null;
      _error = null;
    });
    await scheduler?.arm(widget.lightId);
    if (mounted) await _load();
  }

  String _describe(BuildContext context, StoredSchedule s) {
    String time(DateTime t) {
      final now = DateTime.now();
      final day = DateTime(
        t.year,
        t.month,
        t.day,
      ).difference(DateTime(now.year, now.month, now.day)).inDays;
      final when = switch (day) {
        0 => 'Today',
        1 => 'Tomorrow',
        _ => '${t.day}/${t.month}',
      };
      return '$when ${TimeOfDay.fromDateTime(t).format(context)}';
    }

    final fade = s.fade.inMinutes > 0 ? ', ${s.fade.inMinutes} min fade' : '';
    final what = s.wake
        ? 'On by ${time(s.at)}$fade'
        : 'Off from ${time(s.start)}$fade';
    if (s.ran) return '$what (ran)';
    return s.enabled ? what : '$what (disabled)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Stored on this bulb', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'What the bulb will run by itself, even with the app closed. '
              'Ours start with "HBR"; others come from the Hue app.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            if (items != null && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No schedules stored on this bulb.'),
              ),
            for (final s in items ?? const <StoredSchedule>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  s.wake ? Icons.wb_sunny_outlined : Icons.bedtime_outlined,
                ),
                title: Text(s.title.isEmpty ? 'Schedule ${s.id}' : s.title),
                subtitle: Text(_describe(context, s)),
              ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _sync,
              icon: const Icon(Icons.sync),
              label: const Text('Sync routines to this bulb now'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Favourite toggle and power-on behaviour, shared by both sheets.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.favorite,
    required this.onFavorite,
    required this.onPowerOn,
  });

  final bool favorite;
  final ValueChanged<bool> onFavorite;
  final VoidCallback? onPowerOn;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(favorite ? Icons.star_rounded : Icons.star_outline),
          title: const Text('Favourite'),
          subtitle: const Text('Pinned to the top of the dashboard'),
          value: favorite,
          onChanged: onFavorite,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.power_outlined),
          title: const Text('Power-on behaviour'),
          subtitle: Text(
            onPowerOn == null
                ? 'Available when connected'
                : 'What happens after a wall switch or power cut',
          ),
          trailing: const Icon(Icons.chevron_right),
          enabled: onPowerOn != null,
          onTap: onPowerOn,
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
