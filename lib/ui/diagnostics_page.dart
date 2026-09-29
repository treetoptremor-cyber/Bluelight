import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics.dart';

/// Recent Bluetooth events and errors, newest first, with copy and clear.
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final diagnostics = Diagnostics.instance;
    return ListenableBuilder(
      listenable: diagnostics,
      builder: (context, _) {
        final lines = diagnostics.lines.reversed.toList();
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Diagnostics'),
            actions: [
              IconButton(
                tooltip: 'Copy all',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: diagnostics.lines.join('\n')),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Copied')));
                  }
                },
              ),
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: diagnostics.clear,
              ),
            ],
          ),
          body: lines.isEmpty
              ? const Center(child: Text('Nothing logged yet.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final line = lines[i];
                    final bad =
                        line.contains('failed') ||
                        line.contains('error') ||
                        line.contains(': failed');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SelectableText(
                        line,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'Menlo',
                          color: bad ? theme.colorScheme.error : null,
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
