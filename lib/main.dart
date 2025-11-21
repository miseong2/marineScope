import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img; // <<< 상단에 import 추가
import 'package:flutter/services.dart'; // <<< 상단에 import 추가

import 'camera_screen.dart';
import 'firebase_options.dart';
import 'preview_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Marine-Scope',
      home: MapScreen(cameras: cameras),
    );
  }
}

class MapScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const MapScreen({super.key, required this.cameras});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const Map<String, double> KNOWN_OBJECT_SIZES_CM = {
    'Styrofoam3': 30.0,
    'PET': 21.0,
    'Plastic': 25.0,
    'Glass3': 15.0,
    'Metal': 20.0,
    'Plastic Bag': 30.0,
    'Net3': 100.0, // 그물은 매우 가변적이므로 큰 값을 기준으로 설정
  };

// [상수 2] 카메라의 유효 초점 거리 (단위: 픽셀)
// (640 / 2) / tan(85도 / 2 * pi / 180) 공식을 통해 계산된 근사치.
// 갤럭시 S23 기준 (화각 85도, YOLO 입력 640x640)
  static const double EFFECTIVE_FOCAL_LENGTH_PIXELS = 381.0;

// [상수 3] YOLO 모델의 입력 이미지 크기
  static const double YOLO_INPUT_IMAGE_SIZE = 640.0;


// [함수 1] AI 비전 기반 절대 거리(빗변) 계산 함수
  double? _calculateAiDistance(Map<String, dynamic> detection) {
    final String className = detection['class'];
    final List<dynamic> box = detection['box']; // 정규화된 [center_x, center_y, width, height]

    final double knownSizeCm = KNOWN_OBJECT_SIZES_CM[className]!;

    // 2. 바운딩 박스의 픽셀 크기 계산
    // box[2]는 너비, box[3]은 높이 (0.0 ~ 1.0 사이의 정규화된 값)
    // 이 중 더 긴 쪽을 기준으로 사용 (폐기물이 옆으로 누워있을 경우 대비)
    final double longSideNormalized = (box[2] > box[3]) ? box[2] : box[3];
    final double objectPixelSize = longSideNormalized * YOLO_INPUT_IMAGE_SIZE;

    if (objectPixelSize <= 0) return null;

    // 3. 거리 계산 공식 적용 (결과는 cm 단위)
    // 거리(cm) = (실제 크기(cm) * 초점 거리(px)) / 이미지 위 크기(px)
    final double distanceCm = (knownSizeCm * EFFECTIVE_FOCAL_LENGTH_PIXELS) / objectPixelSize;
    print("distanceM = ${distanceCm / 100.0}");
    // 4. 단위를 cm에서 m로 변환하여 반환
    return distanceCm / 100.0;
  }

// [함수 2] 센서(기울기)를 이용해 수평 거리(밑변)로 변환하는 함수
  double _calculateHorizontalDistance(double absoluteDistance, double pitch) {
    // 1. [핵심 변환 로직] 센서 좌표계(90~270)를 물리적 각도(0~90)로 변환합니다.
    //    - pitch가 180(수평)이면 -> (180 - 180).abs() = 0도
    //    - pitch가 90(수직 아래)이면 -> (90 - 180).abs() = 90도
    //    - pitch가 152.5이면 -> (152.5 - 180).abs() = 27.5도 (수평선과의 실제 각도)
    final double angleFromHorizontal = (pitch - 180).abs();

    // 2. 변환된 물리적 각도를 라디안으로 변환합니다.
    final double angleRad = angleFromHorizontal * (pi / 180.0);

    // 3. cos 함수로 최종 수평 거리를 계산합니다.
    //    이제 불필요한 안전장치는 필요 없습니다.
    final double horizontalDistance = absoluteDistance * cos(angleRad);
    return horizontalDistance;
  }

  final Completer<GoogleMapController> _controller = Completer();
  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(37.5665, 126.9780),
    zoom: 14.0,
  );

  final Set<Marker> _markers = {};
  StreamSubscription? _firestoreSubscription;

  Interpreter? _interpreter;
  List<String>? _labels;
  static const String _modelPath = 'assets/models/best_float16.tflite';
  static const String _labelPath = 'assets/models/labels.txt';
  late Future<void> _loadingFuture; // <<< 1. 새로운 Future 변수 선언

  @override
  void initState() {
    super.initState();
    _loadingFuture = _loadModel();
    _moveToCurrentLocation();
    _listenToWasteDetections();
  }

  Future<void> _loadModel() async {
    try {
      // 1. TFLite 인터프리터(해석기) 로드
      _interpreter = await Interpreter.fromAsset(_modelPath);
      print('AI 모델 로딩 성공');

      // 2. 레이블 파일 로드
      final labelsData = await rootBundle.loadString(_labelPath);
      _labels = labelsData.split('\n');
      print('레이블 로딩 성공: $_labels');

    } catch (e) {
      print('AI 모델 로딩 실패: $e');
    }
  }

  @override
  void dispose() {
    _firestoreSubscription?.cancel();
    super.dispose();
  }

  // --- 기존의 모든 헬퍼 함수들은 그대로 유지됩니다 ---
  // (이 아래의 _showImageDialog, _listenToWasteDetections 등은 변경 사항이 없습니다)
  void _showImageDialog(String imageUrl) { showDialog(context: context, builder: (context) => AlertDialog(contentPadding: const EdgeInsets.all(8.0), content: Column(mainAxisSize: MainAxisSize.min, children: [Image.network(imageUrl, fit: BoxFit.contain, loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? loadingProgress) { if (loadingProgress == null) return child; return Center(child: CircularProgressIndicator(value: loadingProgress.expectedTotalBytes != null ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes! : null,),);},),],), actions: <Widget>[TextButton(child: const Text('닫기'), onPressed: () {Navigator.of(context).pop();},),],),); }
  void _listenToWasteDetections() { final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2)); final query = FirebaseFirestore.instance.collection('detections').where('timestamp', isGreaterThanOrEqualTo: twoDaysAgo); _firestoreSubscription = query.snapshots().listen((QuerySnapshot snapshot) { final newMarkers = snapshot.docs.map((doc) { final data = doc.data() as Map<String, dynamic>; final geoPoint = data['location'] as GeoPoint; final timestamp = data['timestamp'] as Timestamp; final imageUrl = data['imageUrl'] as String; final formattedDate = DateFormat('yyyy-MM-dd HH:mm').format(timestamp.toDate()); return Marker(markerId: MarkerId(doc.id), position: LatLng(geoPoint.latitude, geoPoint.longitude), icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed), infoWindow: InfoWindow(title: data['waste_type'], snippet: '촬영 시각: $formattedDate', onTap: () {_showImageDialog(imageUrl);},),); }).toSet(); setState(() {_markers.clear(); _markers.addAll(newMarkers);}); }); }
  double _calculateDistance(double pitch, double height) { double pitchRad = pitch * (pi / 180); double distance = height * tan(pitchRad); return distance.abs(); }
  LatLng _calculateTargetCoordinates(LatLng startPoint, double bearing, double distance) { const double earthRadius = 6371000; double lat1 = startPoint.latitude * (pi / 180); double lon1 = startPoint.longitude * (pi / 180); double bearingRad = bearing * (pi / 180); double lat2 = asin(sin(lat1) * cos(distance / earthRadius) + cos(lat1) * sin(distance / earthRadius) * cos(bearingRad)); double lon2 = lon1 + atan2(sin(bearingRad) * sin(distance / earthRadius) * cos(lat1), cos(distance / earthRadius) - sin(lat1) * sin(lat2)); return LatLng(lat2 * (180 / pi), lon2 * (180 / pi)); }
  Future<String> _uploadImageToStorage(String imagePath) async { String fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg'; Reference storageRef = FirebaseStorage.instance.ref().child('wastes/$fileName'); UploadTask uploadTask = storageRef.putFile(File(imagePath)); TaskSnapshot snapshot = await uploadTask; return await snapshot.ref.getDownloadURL(); }
  //Future<Map<String, dynamic>> _runFakeYoloModel(String imagePath) async { await Future.delayed(const Duration(seconds: 2)); return {'waste_type': 'plastic_bottle', 'confidence': 0.87,}; }
  Future<void> _uploadWasteData(LatLng correctedLocation, Map<String, dynamic> yoloResult, String imageUrl) async {
    await FirebaseFirestore.instance.collection('detections').add({
      'location': GeoPoint(correctedLocation.latitude, correctedLocation.longitude),
      // [핵심 수정] yoloResult['waste_type'] 대신 yoloResult['class']를 사용합니다.
      'waste_type': yoloResult['class'],
      'confidence': yoloResult['confidence'],
      'imageUrl': imageUrl,
      'timestamp': Timestamp.now(),
    });
  }

  Future<void> _moveToCurrentLocation() async { try { Position position = await _determinePosition(); final GoogleMapController controller = await _controller.future; await controller.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(position.latitude, position.longitude), zoom: 16.0,),)); } catch (e) { print("현재 위치로 이동하는 데 실패했습니다: $e"); } }
  Future<Position> _determinePosition() async { bool serviceEnabled; LocationPermission permission; serviceEnabled = await Geolocator.isLocationServiceEnabled(); if (!serviceEnabled) { return Future.error('Location services are disabled.'); } permission = await Geolocator.checkPermission(); if (permission == LocationPermission.denied) { permission = await Geolocator.requestPermission(); if (permission == LocationPermission.denied) { return Future.error('Location permissions are denied'); } } if (permission == LocationPermission.deniedForever) { return Future.error('Location permissions are permanently denied, we cannot request permissions.'); } return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high); }

  // main.dart 파일의 _runRealYoloModel 함수를 이걸로 완전히 덮어쓰세요.
  // main.dart의 _runRealYoloModel 함수를 이걸로 완전히 덮어쓰세요.

  Future<List<Map<String, dynamic>>?> _runRealYoloModel(String imagePath) async {
    if (_interpreter == null || _labels == null) {
      print("!!!!! 오류: 모델 또는 레이블이 로드되지 않았습니다.");
      return null;
    }

    // 1. 이미지 전처리
    final image = img.decodeImage(await File(imagePath).readAsBytes());
    if (image == null) return null;

    // 불필요한 let 함수를 제거하고 표준적인 방식으로 수정
    final imageBytes = img.copyResize(image, width: 640, height: 640)
        .getBytes(order: img.ChannelOrder.rgb);
    final imageFloats = imageBytes.map((e) => e / 255.0).toList();
    final input = Float32List.fromList(imageFloats).reshape([1, 640, 640, 3]);

    // 2. 추론
    final output = List.filled(1 * 11 * 8400, 0.0).reshape([1, 11, 8400]);
    _interpreter!.run(input, output);

    // 3. 후처리
    List<Map<String, dynamic>> detections = [];
    final transposedOutput = output[0];

    for (int i = 0; i < 8400; i++) {
      double maxScore = 0;
      int maxScoreIndex = -1;
      for (int j = 4; j < 11; j++) {
        if (transposedOutput[j][i] > maxScore) {
          maxScore = transposedOutput[j][i];
          maxScoreIndex = j - 4;
        }
      }

      if (maxScore > 0.25) { // 신뢰도 임계값
        // 1. [수정] 먼저 변수에 이름을 저장합니다.
        final String detectedClass = _labels![maxScoreIndex].trim();

        // 2. [추가] "스파이 코드"로 실제 이름을 콘솔에 출력합니다.
        print("AI 모델이 감지한 실제 클래스 이름: [$detectedClass]");

        // 3. [수정] 저장된 변수를 사용해 맵에 추가합니다.
        detections.add({
          'class': detectedClass,
          'confidence': maxScore,
          'box': [ // 정규화된 [center_x, center_y, width, height]
            transposedOutput[0][i],
            transposedOutput[1][i],
            transposedOutput[2][i],
            transposedOutput[3][i],
          ]
        });
      }
    }

    if (detections.isEmpty) return null;

    detections.sort((a, b) => (b['confidence'] as double).compareTo(a['confidence'] as double));

    return detections;
  }

  // main.dart의 build 메소드 전체를 이걸로 덮어쓰세요.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // body 부분을 FutureBuilder로 감싸서 로딩 상태를 관리합니다.
      body: FutureBuilder<void>(
        future: _loadingFuture, // initState에서 할당한 로딩 작업을 감시
        builder: (context, snapshot) {

          // [상태 1] AI 모델이 로딩 중일 때...
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text('AI 모델을 로딩 중입니다...'),
                ],
              ),
            );
          }

          // [상태 2] 로딩 중 에러가 발생했을 때...
          if (snapshot.hasError) {
            return Center(
              child: Text('모델 로딩 중 오류 발생: ${snapshot.error}'),
            );
          }

          // [상태 3] 로딩이 성공적으로 완료되었을 때...
          // 멘토님의 기존 GoogleMap 코드를 여기에 그대로 보여줍니다.
          return GoogleMap(
            mapType: MapType.normal,
            initialCameraPosition: _initialPosition,
            onMapCreated: (GoogleMapController controller) {
              if (!_controller.isCompleted) {
                _controller.complete(controller);
              }
            },
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            markers: _markers,
          );
        },
      ),

      // FloatingActionButton은 로딩 상태와 상관없이 항상 같은 위치에 표시됩니다.
      floatingActionButton: FloatingActionButton.extended(
        // main.dart의 FloatingActionButton.extended 내부 onPressed 로직을 이걸로 덮어쓰세요.

        // main.dart의 FloatingActionButton.extended 내부 onPressed 로직 전체를 이걸로 덮어쓰세요.

        onPressed: () async {
          try {
            if (_interpreter == null || _labels == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("AI 모델이 아직 로딩 중입니다.")),
              );
              return;
            }

            final resultData = await Navigator.push<Map<String, dynamic>>(
              context,
              MaterialPageRoute(
                builder: (context) => CameraScreen(cameras: widget.cameras),
              ),
            );

            if (resultData != null) {
              final String imagePath = resultData['imagePath'];
              List<Map<String, dynamic>>? detections = await _runRealYoloModel(imagePath);

              if (detections == null || detections.isEmpty) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("폐기물을 감지하지 못했습니다.")),
                  );
                }
                return;
              }

              // [디버깅 로그 시작] ---------------------------------------------
              print("-----------[데이터 추적 시작]-----------");
              final double pitch = resultData['pitch'];
              print("1. CameraScreen에서 전달받은 Pitch 값: $pitch");

              for (var detection in detections) {
                final String className = detection['class'];
                print("2. '$className'에 대한 거리 계산 시작...");

                final double? absoluteDistance = _calculateAiDistance(detection);
                print("3. 계산된 절대 거리(빗변): $absoluteDistance");

                if (absoluteDistance != null) {
                  final double horizontalDistance = _calculateHorizontalDistance(absoluteDistance, pitch);
                  print("4. 계산된 최종 수평 거리(밑변): $horizontalDistance");
                  detection['distance'] = horizontalDistance;
                } else {
                  print("4. 절대 거리 계산 실패! (KNOWN_OBJECT_SIZES_CM 확인 필요)");
                  detection['distance'] = null;
                }
                print("-----------------------------------------");
              }
              // [디버깅 로그 끝] -----------------------------------------------


              if (!mounted) return;

              final bool? shouldUpload = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (context) => PreviewScreen(
                    imagePath: imagePath,
                    detectionResults: detections,
                  ),
                ),
              );

              if (shouldUpload == true) {
                // (이하 업로드 로직은 기존과 동일)
                final bestResult = detections.first;
                final double? calculatedDistance = bestResult['distance'];
                if (calculatedDistance == null || calculatedDistance <= 0) { // 0m도 실패로 간주
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("거리 계산에 실패하여 업로드할 수 없습니다.")),
                    );
                  }
                  return;
                }
                final Position startPosition = resultData['position'];
                final double azimuth = resultData['azimuth'];
                final LatLng correctedCoordinates = _calculateTargetCoordinates(
                  LatLng(startPosition.latitude, startPosition.longitude),
                  azimuth,
                  calculatedDistance,
                );
                String imageUrl = await _uploadImageToStorage(imagePath);
                await _uploadWasteData(correctedCoordinates, bestResult, imageUrl);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("${bestResult['class']}를 약 ${calculatedDistance.toStringAsFixed(1)}m 앞에서 발견! 업로드 완료!")),
                  );
                }
              }
            }
          } catch (e) {
            print("오류 발생: $e");
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("오류가 발생했습니다: $e")),
              );
            }
          }
        },
        label: const Text('폐기물 촬영'),
        icon: const Icon(Icons.camera_alt),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}