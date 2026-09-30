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

/// Shown while a scene is playing: its name, a speed slider and Stop.
class PlayingBar extends StatelessWidget {
  const PlayingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final name = hub.playingScene;
        if (name == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Card(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.play_arrow_rounded),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Playing $name',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: hub.stopScene,
                      child: const Text('Stop'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text('Slow', style: theme.textTheme.bodySmall),
                    Expanded(
                      child: Slider(
                        semanticFormatterCallback: (_) => 'Play speed',
                        value: hub.playSpeed,
                        onChanged: hub.setPlaySpeed,
                      ),
                    ),
                    Text('Fast', style: theme.textTheme.bodySmall),
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
          const SliverToBoxAdapter(child: PlayingBar()),
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
    _motif(canvas, size, base, next);
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

  static bool _has(String name, List<String> words) => words.any(name.contains);

  /// Our own small picture on top of the colour fields, chosen by what the
  /// scene's name suggests: a horizon, trees, waves, stars, embers or city
  /// lights. Silhouettes are a dark shade of the palette.
  void _motif(Canvas canvas, Size size, Color base, double Function() next) {
    final name = scene.name.toLowerCase();
    final w = size.width, h = size.height;
    final dark = Color.lerp(base, Colors.black, 0.78)!;
    final fill = Paint()..color = dark.withValues(alpha: 0.9);
    final bright = _colors.reduce(
      (a, b) => a.computeLuminance() > b.computeLuminance() ? a : b,
    );
    if (_has(name, [
      'sun',
      'dawn',
      'dusk',
      'golden',
      'horizon',
      'savanna',
      'desert',
      'tropic',
      'sahara',
      'twilight',
      'glow',
    ])) {
      canvas.drawCircle(
        Offset(w * (0.3 + next() * 0.4), h * 0.52),
        h * 0.2,
        Paint()
          ..color = Color.lerp(
            bright,
            Colors.white,
            0.55,
          )!.withValues(alpha: 0.95)
          ..maskFilter = const ui.MaskFilter.blur(BlurStyle.normal, 6),
      );
      final hills = Path()..moveTo(0, h);
      hills.lineTo(0, h * 0.72);
      for (var x = 0.0; x <= w; x += w / 6) {
        hills.quadraticBezierTo(
          x + w / 12,
          h * (0.6 + next() * 0.15),
          x + w / 6,
          h * 0.74,
        );
      }
      hills.lineTo(w, h);
      canvas.drawPath(hills, fill);
    } else if (_has(name, [
      'forest',
      'wood',
      'tree',
      'spring',
      'autumn',
      'jungle',
      'meadow',
      'garden',
      'pine',
      'leaf',
      'fall',
      'emerald',
      'nature',
    ])) {
      for (var layer = 0; layer < 2; layer++) {
        final paint = Paint()
          ..color = dark.withValues(alpha: layer == 0 ? 0.55 : 0.9);
        final base0 = h * (layer == 0 ? 0.92 : 1.02);
        var x = -w * 0.05;
        while (x < w) {
          final tw = w * (0.12 + next() * 0.08);
          final th = h * (0.35 + next() * 0.3) * (layer == 0 ? 0.8 : 1);
          canvas.drawPath(
            Path()
              ..moveTo(x, base0)
              ..lineTo(x + tw / 2, base0 - th)
              ..lineTo(x + tw, base0)
              ..close(),
            paint,
          );
          x += tw * (0.6 + next() * 0.3);
        }
      }
    } else if (_has(name, [
      'ocean',
      'water',
      'lagoon',
      'beach',
      'sea',
      'lake',
      'rain',
      'river',
      'wave',
      'reef',
      'surf',
      'bay',
      'tide',
      'mist',
    ])) {
      for (var i = 0; i < 5; i++) {
        final y = h * (0.5 + i * 0.11);
        final path = Path()..moveTo(0, y);
        for (var x = 0.0; x < w; x += w / 4) {
          path.quadraticBezierTo(x + w / 8, y - h * 0.07, x + w / 4, y);
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = h * 0.035
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: 0.12 + i * 0.04),
        );
      }
    } else if (_has(name, [
      'star',
      'night',
      'galaxy',
      'space',
      'aurora',
      'moon',
      'cosmos',
      'midnight',
      'nebula',
      'sky',
      'lunar',
      'comet',
    ])) {
      for (var i = 0; i < 26; i++) {
        canvas.drawCircle(
          Offset(w * next(), h * next() * 0.85),
          0.6 + next() * 1.4,
          Paint()..color = Colors.white.withValues(alpha: 0.4 + next() * 0.5),
        );
      }
      canvas.drawCircle(
        Offset(w * 0.78, h * 0.26),
        h * 0.11,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..maskFilter = const ui.MaskFilter.blur(BlurStyle.normal, 3),
      );
    } else if (_has(name, [
      'fire',
      'candle',
      'cozy',
      'ember',
      'hearth',
      'cabin',
      'flame',
      'warm',
      'toasty',
      'lantern',
      'relax',
      'read',
    ])) {
      final c = Offset(w * 0.5, h * 0.95);
      canvas.drawCircle(
        c,
        h * 0.5,
        Paint()
          ..color = bright.withValues(alpha: 0.6)
          ..maskFilter = ui.MaskFilter.blur(BlurStyle.normal, h * 0.3),
      );
      for (var i = 0; i < 14; i++) {
        canvas.drawCircle(
          Offset(w * (0.25 + next() * 0.5), h * (0.3 + next() * 0.6)),
          0.8 + next() * 1.4,
          Paint()
            ..color = Color.lerp(
              bright,
              Colors.white,
              0.5,
            )!.withValues(alpha: 0.7),
        );
      }
    } else if (_has(name, [
      'city',
      'neon',
      'tokyo',
      'miami',
      'party',
      'disco',
      'rave',
      'club',
      'cyber',
      'vegas',
      'downtown',
      'street',
      'arcade',
    ])) {
      var x = 0.0;
      while (x < w) {
        final bw = w * (0.06 + next() * 0.08);
        final bh = h * (0.25 + next() * 0.4);
        canvas.drawRect(Rect.fromLTWH(x, h - bh, bw, bh), fill);
        x += bw + w * 0.01;
      }
      for (var i = 0; i < 18; i++) {
        canvas.drawCircle(
          Offset(w * next(), h * (0.45 + next() * 0.5)),
          1 + next() * 1.6,
          Paint()..color = _colors[i % _colors.length].withValues(alpha: 0.9),
        );
      }
    } else {
      // Bokeh: soft rings of out-of-focus light.
      for (var i = 0; i < 9; i++) {
        final c = _colors[i % _colors.length];
        final r = h * (0.06 + next() * 0.12);
        final o = Offset(w * next(), h * next());
        canvas.drawCircle(
          o,
          r,
          Paint()..color = Colors.white.withValues(alpha: 0.07),
        );
        canvas.drawCircle(
          o,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Color.lerp(c, Colors.white, 0.5)!.withValues(alpha: 0.45),
        );
      }
    }
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
