import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart'; // <<< 1. flutter_compass import

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraScreen({super.key, required this.cameras});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;

  StreamSubscription? _accelerometerSubscription;
  StreamSubscription? _compassSubscription; // <<< 2. 자이로스코프 대신 나침반 구독 변수

  List<double>? _accelerometerValues;
  double? _direction; // <<< 2. 나침반 방향(azimuth)을 저장할 변수

  double _pitch = 0.0;

  @override
  void initState() {
    super.initState();
    // 화면을 세로로 고정
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    _controller = CameraController(
      widget.cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );

    // 컨트롤러 초기화가 끝나면 센서 리스너 시작
    _initializeControllerFuture = _controller.initialize().then((_) {
      if (mounted) {
        _startSensorListeners();
      }
    });
  }

  void _startSensorListeners() {
    // 가속도계 센서: 스마트폰의 기울기(pitch)를 계산하는 데 사용
    _accelerometerSubscription = accelerometerEvents.listen((event) {
      _accelerometerValues = [event.x, event.y, event.z];
      _updatePitch(); // 가속도 값으로 Pitch 업데이트
    });

    // 나침반 센서: 스마트폰이 가리키는 방향(azimuth)을 얻는 데 사용
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      setState(() {
        // event.heading은 북쪽을 0도로 하여 시계방향으로 0-360 사이의 값을 줌
        _direction = event.heading;
      });
    });
  }

  // 가속도계 값으로 Pitch(상하 기울기)를 계산하는 함수
  void _updatePitch() {
    if (_accelerometerValues == null) return;

    // y축과 z축의 값으로 올바른 Pitch(세로 기울기)를 계산합니다.
    // atan2(y, z)는 y와 z의 관계로부터 각도를 라디안으로 반환합니다.
    double pitchRad = atan2(_accelerometerValues![1], _accelerometerValues![2]);

    setState(() {
      // 1. 라디안을 각도(degree)로 변환합니다.
      // 2. +90도를 더하여 좌표계를 조정합니다.
      //    - 폰을 똑바로 세우면(y=-9.8, z=0) -> atan2 결과는 -90도 -> 최종 값 0도
      //    - 폰을 바닥을 향해 눕히면(y=0, z=-9.8) -> atan2 결과는 -180도 -> 최종 값 -90도
      _pitch = (pitchRad * 180 / pi) + 90;

      // 계산 과정에서 값이 뒤집히는 경우가 있어, -1을 곱해 최종 보정합니다.
      // 이 값은 폰 기종마다 다를 수 있으므로, 테스트 후 조정이 필요할 수 있습니다.
      //_pitch *= -1;
    });
  }

  @override
  void dispose() {
    // 화면이 사라질 때 리소스 정리
    _controller.dispose();
    _accelerometerSubscription?.cancel();
    _compassSubscription?.cancel();

    // 화면 방향 고정 해제
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  Future<void> _onTakePicturePressed() async {
    try {
      await _initializeControllerFuture;

      final image = await _controller.takePicture();
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      // 촬영 순간의 기울기와 방향 값을 캡처
      final capturedPitch = _pitch;
      final capturedAzimuth = _direction ?? 0.0; // null일 경우 기본값 0.0 사용
      print("pitch: $capturedPitch, azimuth: $capturedAzimuth");

      if (!mounted) return;

      // 캡처된 모든 데이터를 Map 형태로 이전 화면(MapScreen)으로 반환
      Navigator.pop(context, {
        'imagePath': image.path,
        'position': position,
        'pitch': capturedPitch,
        'azimuth': capturedAzimuth,
      });
    } catch (e) {
      print("촬영 중 오류 발생: $e");
      Navigator.pop(context, null);
    }
  }

  // camera_screen.dart의 build 메소드 전체를 이걸로 교체하세요.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            final mediaSize = MediaQuery.of(context).size;
            final scale = 1 / (_controller.value.aspectRatio * mediaSize.aspectRatio);

            return Stack(
              alignment: Alignment.center,
              children: [
                ClipRect(
                  clipper: _MediaSizeClipper(mediaSize),
                  child: Transform.scale(
                    scale: scale,
                    alignment: Alignment.topCenter,
                    child: CameraPreview(_controller),
                  ),
                ),
                // --- [여기가 핵심 수정 부분입니다] ---
                Positioned(
                  top: 60,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      // 기존 방향(Azimuth) 값과 함께 새로운 기울기(Pitch) 값을 표시
                      '방향(Azimuth): ${(_direction ?? 0.0).toStringAsFixed(1)}°\n'
                          '기울기(Pitch): ${_pitch.toStringAsFixed(1)}°',
                      style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5),
                    ),
                  ),
                ),
                // 원형 가이드
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.7), width: 2),
                  ),
                ),
                // 뒤로가기 버튼
                Positioned(
                  top: 50,
                  left: 20,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white, size: 30),
                    onPressed: () {
                      Navigator.pop(context);
                    },
                  ),
                ),
              ],
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
      floatingActionButton: FloatingActionButton.large(
        onPressed: _onTakePicturePressed,
        child: const Icon(Icons.camera_alt),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

class _MediaSizeClipper extends CustomClipper<Rect> {
  final Size mediaSize;
  const _MediaSizeClipper(this.mediaSize);
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, mediaSize.width, mediaSize.height);
  @override
  bool shouldReclip(CustomClipper<Rect> oldClipper) => true;
}