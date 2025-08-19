import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

// shelf server
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HelpScreen(),
    );
  }
}

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  InAppWebViewController? _webViewController;
  bool _loading = true;

  // Shelf HTTP server
  HttpServer? _httpServer;
  String? _publicRootPath;
  int _port = 8080;

  @override
  void initState() {
    super.initState();
    _prepareAndStartServer();
  }

  @override
  void dispose() {
    _stopServer();
    super.dispose();
  }

  Future<void> _prepareAndStartServer() async {
    try {
      // 1) Подготовка папки public
      final docs = await getApplicationDocumentsDirectory();
      final publicDir = Directory('${docs.path}/public');
      if (!publicDir.existsSync()) {
        publicDir.createSync(recursive: true);
      }

      // 2) Копируем HTML и ассеты
      await _copyAssetFile('assets/html/index.html', '${publicDir.path}/index.html');

      final roosterFiles = <String>[
        'gromkiy-krik-vzroslogo-petuha.wav',
        'povtoryayuschiysya-krik-petuha.wav',
        'krik-petuha-v-derevne.wav',
        'petuh-30746.wav',
        'zvonkogolosyiy-petuh.wav',
        'protyajnyiy-krik-petuha.wav',
      ];
      for (final name in roosterFiles) {
        await _copyAssetFile(
          'assets/audio/roosters/$name',
          '${publicDir.path}/assets/audio/roosters/$name',
        );
      }

      final loaderImages = <String>[
        'bowl_full.png',
        'bowl_tilt.png',
        'egg.png',
      ];
      for (final img in loaderImages) {
        final src = 'assets/images/$img';
        final dst = '${publicDir.path}/assets/images/$img';
        if (await _assetExists(src)) {
          await _copyAssetFile(src, dst);
        }
      }

      _publicRootPath = publicDir.path;

      // 3) Стартуем shelf-сервер
      _port = await _startShelfServer(_publicRootPath!, desiredPort: 8080);

      if (mounted) {
        setState(() {
          _loading = true; // до полной загрузки страницы
        });
      }
    } catch (e) {
      debugPrint('Error preparing server/assets: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<int> _startShelfServer(String rootPath, {int desiredPort = 8080}) async {
    await _stopServer();

    // Static handler раздаёт весь каталог, index.html — документ по умолчанию
    final staticHandler = createStaticHandler(
      rootPath,
      defaultDocument: 'index.html',
      listDirectories: false,
      useHeaderBytesForContentType: true,
    );

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(staticHandler);

    // Пытаемся занять желаемый порт, иначе пусть ОС подберёт свободный (порт 0)
    try {
      _httpServer = await shelf_io.serve(
        handler,
        InternetAddress.loopbackIPv4,
        desiredPort,
      );
    } catch (_) {
      _httpServer = await shelf_io.serve(
        handler,
        InternetAddress.loopbackIPv4,
        0, // авто-подбор
      );
    }

    _httpServer!.autoCompress = true;
    final boundPort = _httpServer!.port;
    debugPrint('Shelf server started at http://127.0.0.1:$boundPort (root: $rootPath)');
    return boundPort;
  }

  Future<void> _stopServer() async {
    try {
      await _httpServer?.close(force: true);
      _httpServer = null;
    } catch (_) {}
  }

  Future<bool> _assetExists(String assetPath) async {
    try {
      await rootBundle.load(assetPath);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _copyAssetFile(String assetPath, String outPath) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final outFile = File(outPath);
    outFile.createSync(recursive: true);
    await outFile.writeAsBytes(bytes, flush: true);
  }

  @override
  Widget build(BuildContext context) {
    final canLoad = _publicRootPath != null && _httpServer != null;
    final initialUrl = canLoad
        ? URLRequest(url: WebUri('http://127.0.0.1:${_port.toString()}/index.html'))
        : null;

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.black, // Лоудер сам рисует градиент
        body: Stack(
          children: [
            if (initialUrl != null)
              InAppWebView(
                initialUrlRequest: initialUrl,
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  disableDefaultErrorPage: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  allowsPictureInPictureMediaPlayback: true,
                  useOnDownloadStart: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  supportZoom: false,
                  disableHorizontalScroll: false,
                  disableVerticalScroll: false,
                  allowsBackForwardNavigationGestures: true,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                onLoadStart: (controller, url) {
                  setState(() {
                    _loading = true;
                  });
                },
                onLoadStop: (controller, url) async {
                  // Проверим фактический URL
                  final href = await controller.evaluateJavascript(
                    source: "location.href",
                  );
                  debugPrint('WebView location.href: $href');
                  setState(() {
                    _loading = false;
                  });
                },
                onLoadError: (controller, url, code, message) {
                  debugPrint('Load error [$code]: $message, url=$url');
                  setState(() {
                    _loading = false;
                  });
                },
              )
            else
              const SizedBox.expand(),

            if (_loading || initialUrl == null) const EggsFallingLoader(),
          ],
        ),
      ),
    );
  }
}

class EggsFallingLoader extends StatefulWidget {
  const EggsFallingLoader({super.key});

  @override
  State<EggsFallingLoader> createState() => _EggsFallingLoaderState();
}

class _EggsFallingLoaderState extends State<EggsFallingLoader> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final List<_EggParticle> _eggs = [];
  Timer? _emitter;
  void Function()? _spawn;

  @override
  void initState() {
    super.initState();

    _ticker = createTicker((elapsed) {
      const dt = 1 / 60.0;
      for (final e in _eggs) {
        e.update(dt);
      }
      _eggs.removeWhere((e) => e.isDead);
      setState(() {});
    })..start();

    _emitter = Timer.periodic(const Duration(milliseconds: 170), (_) {
      _spawn?.call();
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _emitter?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bg = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFFFFFBEA), // тёплый белый
        Color(0xFFFFF2B3), // мягкий жёлтый
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        // Размеры и позиции мисок
        final srcSize = math.min(w, h) * 0.35;
        final dstSize = math.min(w, h) * 0.38;

        final sourceOffset = Offset(w * 0.16, h * 0.17);
        final sinkOffset = Offset(w * 0.58, h * 0.62);

        // Точка эмиссии яиц
        final emitPoint = Offset(
          sourceOffset.dx + srcSize * 0.78,
          sourceOffset.dy + srcSize * 0.46,
        );

        // Функция спавна частиц
        _spawn = () {
          final rnd = math.Random();
          final vx = 70 + rnd.nextDouble() * 110;
          final vy = 110 + rnd.nextDouble() * 90;
          final angle0 = (-15 + rnd.nextDouble() * 30) * math.pi / 180;
          _eggs.add(
            _EggParticle(
              position: emitPoint + Offset(rnd.nextDouble() * 6 - 3, rnd.nextDouble() * 6 - 3),
              velocity: Offset(vx, vy),
              angularVelocity: (rnd.nextBool() ? 1 : -1) * (0.8 + rnd.nextDouble() * 1.2),
              angle: angle0,
              lifespan: 3.2,
              gravity: 420,
              fadeOut: 0.35,
            ),
          );
        };

        return SafeArea(
          child: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(gradient: bg),
            child: Stack(
              children: [
                // Нижняя миска (приёмник)
                Positioned(
                  left: sinkOffset.dx,
                  top: sinkOffset.dy,
                  width: dstSize,
                  height: dstSize * 0.65,
                  child: Image.asset(
                    'assets/images/bowl_full.png',
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),

                // Частицы-«яйца»
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _EggsPainter(
                      eggs: _eggs,
                      eggImage: const AssetImage('assets/images/egg.png'),
                    ),
                    size: Size.infinite,
                  ),
                ),

                // Верхняя миска (источник), чуть наклонена
                Positioned(
                  left: sourceOffset.dx,
                  top: sourceOffset.dy,
                  width: srcSize,
                  height: srcSize,
                  child: Transform.rotate(
                    angle: -0.4,
                    alignment: Alignment.center,
                    child: Image.asset(
                      'assets/images/bowl_tilt.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EggParticle {
  _EggParticle({
    required this.position,
    required this.velocity,
    required this.angularVelocity,
    required this.angle,
    required this.lifespan,
    required this.gravity,
    required this.fadeOut,
  });

  Offset position;
  Offset velocity;
  double angle;
  final double angularVelocity;
  final double gravity;
  final double lifespan;
  final double fadeOut;
  double age = 0;

  bool get isDead => age > lifespan;

  void update(double dt) {
    age += dt;
    velocity = Offset(velocity.dx, velocity.dy + gravity * dt);
    position += velocity * dt;
    angle += angularVelocity * dt;
  }

  double get opacity {
    final t = (age / lifespan).clamp(0.0, 1.0);
    if (t < 1 - fadeOut) return 1.0;
    final k = (t - (1 - fadeOut)) / fadeOut;
    return (1 - k).clamp(0.0, 1.0);
  }

  double get scale {
    final t = (age / 0.25).clamp(0.0, 1.0);
    return 0.9 + 0.2 * (1 - math.cos(t * math.pi));
  }
}

class _EggsPainter extends CustomPainter {
  _EggsPainter({
    required this.eggs,
    required this.eggImage,
  });

  final List<_EggParticle> eggs;
  final AssetImage eggImage;

  ImageStream? _stream;
  ImageInfo? _imageInfo;

  void _ensureImageResolved() {
    _stream ??= eggImage.resolve(const ImageConfiguration());
    _stream!.addListener(ImageStreamListener((info, _) {
      _imageInfo = info;
    }));
  }

  @override
  void paint(Canvas canvas, Size size) {
    _ensureImageResolved();
    final img = _imageInfo?.image;
    if (img == null) return;

    final srcRect = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());

    for (final e in eggs) {
      final dstW = 28.0 * e.scale;
      final aspect = img.height / img.width;
      final dstH = dstW * aspect;

      final paint = Paint()
        ..filterQuality = FilterQuality.high
        ..color = Colors.white.withOpacity(e.opacity);

      canvas.save();
      canvas.translate(e.position.dx, e.position.dy);
      canvas.rotate(e.angle);
      final rect = Rect.fromCenter(center: Offset.zero, width: dstW, height: dstH);
      canvas.drawImageRect(img, srcRect, rect, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EggsPainter oldDelegate) => true;
}