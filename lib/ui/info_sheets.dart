import 'package:flutter/material.dart';

import '../hub.dart';
import 'common.dart';
import 'group_edit_page.dart';

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
                    child: Text(
                      '${AppScope.of(context).scheduler?.armedCount(id) ?? 0} '
                      'upcoming routine runs stored',
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
                const SizedBox(height: 16),
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
