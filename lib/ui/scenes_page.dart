import 'dart:ui' as ui;

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
  HueScene scene, {
  bool play = false,
}) async {
  final app = AppScope.of(context);
  HapticFeedback.lightImpact();
  try {
    final ids = app.store.lightIdsFor(targetId);
    if (play) {
      await app.hub.playScene(ids, scene);
    } else {
      await app.hub.applyScene(ids, scene);
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(play ? '${scene.name} · playing' : scene.name),
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
                  onPlay: () =>
                      applyScene(context, targetId, e.value[i], play: true),
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

/// Soft, blurred colour fields built from a scene's palette, so each scene
/// gets its own picture. The layout is seeded by the scene's name.
class SceneArtPainter extends CustomPainter {
  SceneArtPainter(this.scene)
    : _colors = [for (final c in scene.colors) sceneColor(c)];

  final HueScene scene;
  final List<Color> _colors;

  @override
  void paint(Canvas canvas, Size size) {
    final base = _colors.reduce((a, b) => Color.lerp(a, b, 0.5)!);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color.lerp(base, Colors.black, 0.45)!,
    );
    var seed = scene.name.codeUnits.fold<int>(
      7,
      (h, c) => (h * 31 + c) & 0x7fffffff,
    );
    double next() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    final blobs = _colors.length == 1 ? 3 : _colors.length + 2;
    for (var i = 0; i < blobs; i++) {
      final c = _colors[i % _colors.length];
      final r = size.shortestSide * (0.55 + next() * 0.5);
      final center = Offset(
        size.width * (0.05 + next() * 0.9),
        size.height * (0.05 + next() * 0.9),
      );
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..color = c.withValues(alpha: 0.85)
          ..maskFilter = ui.MaskFilter.blur(BlurStyle.normal, r * 0.55),
      );
    }
    // A little light from above, like a lit wall.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          Colors.white.withValues(alpha: 0.12),
          Colors.black.withValues(alpha: 0.28),
        ]),
    );
  }

  @override
  bool shouldRepaint(SceneArtPainter old) => old.scene != scene;
}

/// A rounded tile with the scene's generated picture and its name. The play
/// button (for scenes with several colours) keeps the colours drifting
/// between the lights, like the Hue app's dynamic scenes.
class SceneTile extends StatelessWidget {
  const SceneTile({
    super.key,
    required this.scene,
    required this.onTap,
    this.onPlay,
  });

  final HueScene scene;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(child: CustomPaint(painter: SceneArtPainter(scene))),
          Positioned.fill(
            child: InkWell(
              onTap: onTap,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 48, 12),
                  child: Text(
                    scene.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(blurRadius: 6, color: Color(0x99000000)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (onPlay != null && scene.colors.length > 1)
            Positioned(
              right: 4,
              bottom: 4,
              child: IconButton(
                tooltip: 'Play ${scene.name}',
                onPressed: onPlay,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black38,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            ),
        ],
      ),
    );
  }
}
