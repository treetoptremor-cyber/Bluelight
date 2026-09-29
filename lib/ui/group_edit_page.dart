import 'package:flutter/material.dart';

import '../models.dart';
import 'common.dart';

/// Create a group ([groupId] null) or edit one: name and member lights.
class GroupEditPage extends StatefulWidget {
  const GroupEditPage({super.key, this.groupId});

  final String? groupId;

  @override
  State<GroupEditPage> createState() => _GroupEditPageState();
}

class _GroupEditPageState extends State<GroupEditPage> {
  final _name = TextEditingController();
  final _members = <String>{};
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final id = widget.groupId;
    final group = id == null ? null : AppScope.of(context).store.group(id);
    if (group != null) {
      _name.text = group.name;
      _members.addAll(group.lightIds);
    }
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty && _members.isNotEmpty;

  Future<void> _save() async {
    final store = AppScope.of(context).store;
    final lights = [
      for (final l in store.lights)
        if (_members.contains(l.id)) l.id,
    ];
    await store.saveGroup(
      LightGroup(
        id: widget.groupId ?? newId('g'),
        name: _name.text.trim(),
        lightIds: lights,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupId == null ? 'New group' : 'Edit group'),
        actions: [
          TextButton(
            onPressed: _valid ? _save : null,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            autofocus: widget.groupId == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'e.g. Living room',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Text('Lights', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          if (store.lights.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Add lights first, then group them.'),
            ),
          for (final l in store.lights)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _members.contains(l.id),
              title: Text(l.name),
              onChanged: (v) => setState(() {
                v == true ? _members.add(l.id) : _members.remove(l.id);
              }),
            ),
        ],
      ),
    );
  }
}
