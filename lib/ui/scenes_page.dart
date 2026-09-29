import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../color_utils.dart';
import '../models.dart';
import '../scenes.dart';
import '../scenes_data.dart';
import 'common.dart';

Color sceneColor(SceneColor c) =>
    c.isWhite ? kelvinColor(miredsToKelvin(c.ct!).toDouble()) : xyColor(c.xy!);

Gradient sceneGradient(HueScene s) {
  final colors = [for (final c in s.colors) sceneColor(c)];
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: colors.length == 1 ? [colors.first, colors.first] : colors,
  );
}

/// Applies [scene] to [targetId]'s lights and offers to save it as a preset.
Future<void> applyScene(
  BuildContext context,
  String targetId,
  HueScene scene,
) async {
  final app = AppScope.of(context);
  HapticFeedback.lightImpact();
  try {
    await app.hub.applyScene(app.store.lightIdsFor(targetId), scene);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(scene.name),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Save as preset',
          onPressed: () async {
            final looks = app.hub.snapshot(app.store.lightIdsFor(targetId));
            if (looks.isEmpty) return;
            await app.store.savePreset(
              Preset(
                id: newId('p'),
                name: scene.name,
                scopeId: targetId,
                looks: looks,
              ),
            );
          },
        ),
      ),
    );
}

/// All scenes, grouped by gallery set, applied to [targetId] on tap.
class ScenesPage extends StatelessWidget {
  const ScenesPage({super.key, required this.targetId});

  final String targetId;

  @override
  Widget build(BuildContext context) {
    final sets = <String, List<HueScene>>{};
    for (final s in hueScenes) {
      (sets[s.set] ??= []).add(s);
    }
    final theme = Theme.of(context);
    final store = AppScope.of(context).store;
    return Scaffold(
      appBar: AppBar(title: Text('Scenes · ${store.nameOf(targetId)}')),
      body: CustomScrollView(
        slivers: [
          for (final e in sets.entries) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Text(
                  e.key == 'Defaults' ? 'Whites' : e.key,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.5,
                ),
                itemCount: e.value.length,
                itemBuilder: (context, i) => SceneTile(
                  scene: e.value[i],
                  onTap: () => applyScene(context, targetId, e.value[i]),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

/// A rounded tile painted with the scene's palette and its name.
class SceneTile extends StatelessWidget {
  const SceneTile({super.key, required this.scene, required this.onTap});

  final HueScene scene;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final avg = Color.lerp(
      sceneColor(scene.colors.first),
      sceneColor(scene.colors.last),
      0.5,
    )!;
    final dark = ThemeData.estimateBrightnessForColor(avg) == Brightness.dark;
    return Material(
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(gradient: sceneGradient(scene)),
        child: InkWell(
          onTap: onTap,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                scene.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: dark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
