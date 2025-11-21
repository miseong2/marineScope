// lib/preview_screen.dart 파일 전체를 이걸로 덮어쓰세요.

import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'dart:math' as math;

class PreviewScreen extends StatefulWidget {
  final String imagePath;
  final List<Map<String, dynamic>> detectionResults;

  const PreviewScreen({
    super.key,
    required this.imagePath,
    required this.detectionResults,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late Future<ui.Image> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = _loadImage(widget.imagePath);
  }

  Future<ui.Image> _loadImage(String path) {
    final file = File(path);
    return file.readAsBytes().then((bytes) => decodeImageFromList(bytes));
  }

  @override
  Widget build(BuildContext context) {
    // Padding 위젯은 그대로 유지합니다.
    final bottomButtonArea = Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.cancel),
            label: const Text('다시 찍기'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () { Navigator.pop(context, false); },
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.upload),
            label: const Text('업로드'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () { Navigator.pop(context, true); },
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('감지 결과 확인')),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<ui.Image>(
              future: _imageFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
                  final image = snapshot.data!;
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final scale = math.min(constraints.maxWidth / image.width, constraints.maxHeight / image.height);
                      final scaledWidth = image.width * scale;
                      final scaledHeight = image.height * scale;

                      // preview_screen.dart 파일의 LayoutBuilder 안쪽,
// List<Widget> boxes = ... 부분을 아래 코드로 완전히 덮어쓰세요.

                      List<Widget> boxes = widget.detectionResults.map((result) {
                        // --- 기존 좌표 계산 로직은 그대로 둡니다 ---
                        final box = result['box'];
                        final double centerX = box[0];
                        final double centerY = box[1];
                        final double w = box[2];
                        final double h = box[3];

                        final double left = (centerX - w / 2) * scaledWidth;
                        final double top = (centerY - h / 2) * scaledHeight;
                        final double width = w * scaledWidth;
                        final double height = h * scaledHeight;

                        // [수정 1] 변수 선언은 return 키워드 '앞'에 위치해야 합니다.
                        final distance = result['distance'] as double?;
                        String distanceText = '';
                        if (distance != null) {
                          distanceText = ' ≈ ${distance.toStringAsFixed(1)}m'; // "≈ 2.5m" 형태로 표시
                        }
                        final String labelText = '${result['class']} (${(result['confidence'] * 100).toStringAsFixed(0)}%)';

                        // --- 이제 Positioned 위젯을 반환합니다 ---
                        return Positioned(
                          left: left,
                          top: top, // 박스의 top 위치를 기준으로
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 1. 라벨 (박스 바깥에 위치)
                              Container(
                                color: Colors.yellow,
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                // [수정 2] Text 위젯에서 위에서 만든 변수들을 사용합니다.
                                child: Text(
                                  labelText + distanceText, // 클래스, 신뢰도, 거리 정보를 모두 합쳐서 표시
                                  style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ),
                              // 2. 바운딩 박스 (라벨 바로 아래에 위치)
                              Container(
                                width: width,
                                height: height,
                                decoration: BoxDecoration(border: Border.all(color: Colors.yellow, width: 2)),
                              ),
                            ],
                          ),
                        );
                      }).toList();

                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Image.file(File(widget.imagePath), width: scaledWidth, height: scaledHeight),
                          ...boxes,
                        ],
                      );
                    },
                  );
                }
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ),
          // 하단 버튼 영역
          bottomButtonArea,
        ],
      ),
    );
  }
}