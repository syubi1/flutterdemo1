import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:object_detection/tflite/classifier.dart';
import 'package:object_detection/tflite/recognition.dart';
import 'package:object_detection/tflite/stats.dart';
import 'package:object_detection/ui/camera_view_singleton.dart';
import 'package:object_detection/ui/camera_view.dart';
import 'package:object_detection/utils/isolate_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:object_detection/tflite/recognition.dart';

/// [CameraView] sends each frame for inference
class CameraView extends StatefulWidget {
  /// Callback to pass results after inference to [HomeView]
  final Function(List<Recognition> recognitions) resultsCallback;
  /// Callback to inference stats to [HomeView]
  final Function(Stats stats) statsCallback;

  /// Constructor
  const CameraView(this.resultsCallback, this.statsCallback);

  @override
  _CameraViewState createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> with WidgetsBindingObserver {
  /// List of available cameras
  List<CameraDescription>? cameras;

  /// Controller
  CameraController? cameraController;

  /// true when inference is ongoing
  bool? predicting;

  /// Instance of [Classifier]
  Classifier? classifier;
  List<Recognition> recognitions = [];

  /// Instance of [IsolateUtils]
  IsolateUtils? isolateUtils;
  bool isInFixedBox = false;
  Rect fixedBoundingBox = Rect.fromCenter(center: Offset(200, 200), width: 200, height: 200);

  // 固定框设置
  void checkRecognitionInFixedBox(List<Recognition> recognitions) {
    this.recognitions = recognitions;
    bool isInBox = false;
    for (Recognition recognition in recognitions) {
      if (fixedBoundingBox.top <= recognition.renderLocation.top
          && fixedBoundingBox.left <= recognition.renderLocation.left
          && fixedBoundingBox.width >= recognition.renderLocation.width
          && fixedBoundingBox.height >= recognition.renderLocation.height
          && recognition.renderLocation.width * recognition.renderLocation.height
              >= fixedBoundingBox.width * fixedBoundingBox.height * 0.6) {
        isInBox = true;
        isInFixedBox = isInBox;
        break; // 如果在固定框内并且占固定框百分之70面积以上，为true
      } else {
        isInBox = false;
        isInFixedBox = isInBox;
        break;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    initStateAsync();
  }

  void initStateAsync() async {
    WidgetsBinding.instance.addObserver(this);

    // Spawn a new isolate
    isolateUtils = IsolateUtils();
    await isolateUtils!.start();

    // Camera initialization
    initializeCamera();

    // Create an instance of classifier to load model and labels
    classifier = Classifier();

    // Initially predicting = false
    predicting = false;
  }

  /// Initializes the camera by setting [cameraController]
  void initializeCamera() async {
    cameras = await availableCameras();

    // cameras[0] for rear-camera
    cameraController =
        CameraController(cameras![0], ResolutionPreset.low, enableAudio: false);

    cameraController!.initialize().then((_) async {
      // Stream of image passed to [onLatestImageAvailable] callback
      /// previewSize is size of each image frame captured by controller
      ///
      /// 352x288 on iOS, 240p (320x240) on Android with ResolutionPreset.low
      Size previewSize = cameraController!.value.previewSize ?? Size(0, 0);
      /// previewSize is size of raw input image to the model
      CameraViewSingleton.inputImageSize = previewSize;
      // the display width of image on screen is
      // same as screenWidth while maintaining the aspectRatio
      Size screenSize = MediaQuery.of(context).size;
      CameraViewSingleton.screenSize = screenSize;
      CameraViewSingleton.ratio = screenSize.width / previewSize.height;
      setState(() {
        CameraViewSingleton.ratio;
      });
      await cameraController!.startImageStream(onLatestImageAvailable);
    }).catchError((error) {
      print('Error initializing camera: $error + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"');
    });
  }

  Future<void> takePicture() async {
    print('"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"');
    if (cameraController != null && cameraController!.value.isInitialized) {
      print('"bbbbbbbbbbbbbbbbbbbbbbbbbbbbb"');
      try {
        // 拍并获取 XFile 对象
        final XFile picture = await cameraController!.takePicture();
        print('${picture.toString()} + "ccccccccccccccccccccccccccccccccc"');
        // 获取临时目录
        final directory = await getTemporaryDirectory();
        final path = '${directory.path}/${DateTime.now()}.png';
        print('${path.toString()} + "ddddddddddddddddddddddddddddddddd"');
        await picture.saveTo(path);
        print('Picture saved to $path');
      } catch (e) {
        print('Error taking picture: $e');
      }
    } else {
      print('Camera is not initialized');
    }
  }


  @override
  Widget build(BuildContext context) {
    // Return empty container while the camera is not initialized
    if (cameraController == null || !cameraController!.value.isInitialized) {
      return Container();
    }
    return Stack(
      children: [
        SizedBox(
          width: MediaQuery.of(context).size.width,
          height: 540,
          child: CameraPreview(cameraController!),
        ),
        CustomPaint(
          painter: FixedBoundingBoxPainter(fixedBoundingBox, isInFixedBox),
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: ElevatedButton(
            onPressed: takePicture,
            child: Icon(Icons.camera_alt),
          ),
        ),
        if(isInFixedBox)
        Positioned(
          top: 50,
          left: 100,
          child: Text(
            'true',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: Colors.green,
            ),
          ),
        ),
      ],
    );
  }

  /// Callback to receive each frame [CameraImage] perform inference on it
  onLatestImageAvailable(CameraImage cameraImage) async {
    if (classifier!.interpreter != null && classifier!.labels != null) {
      // If previous inference has not completed then return
      if (predicting!) {
        return;
      }

      setState(() {
        predicting = true;
      });

      var uiThreadTimeStart = DateTime.now().millisecondsSinceEpoch;

      // Data to be passed to inference isolate
      var isolateData = IsolateData(
          cameraImage, classifier!.interpreter.address, classifier!.labels);

      // We could have simply used the compute method as well however
      // it would be as in-efficient as we need to continuously passing data
      // to another isolate.

      /// perform inference in separate isolate
      Map<String, dynamic> inferenceResults = await inference(isolateData);

      var uiThreadInferenceElapsedTime =
          DateTime.now().millisecondsSinceEpoch - uiThreadTimeStart;

      // pass results to HomeView
      widget.resultsCallback(inferenceResults["recognitions"]);

      // pass stats to HomeView
      widget.statsCallback((inferenceResults["stats"] as Stats)
        ..totalElapsedTime = uiThreadInferenceElapsedTime);
      //调用位置比较方法
      checkRecognitionInFixedBox(inferenceResults["recognitions"]);
      // set predicting to false to allow new frames
      setState(() {
        predicting = false;
      });
    }
  }

  /// Runs inference in another isolate
  Future<Map<String, dynamic>> inference(IsolateData isolateData) async {
    ReceivePort responsePort = ReceivePort();
    isolateUtils!.sendPort
        .send(isolateData..responsePort = responsePort.sendPort);
    var results = await responsePort.first;
    return results;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.paused:
        cameraController!.stopImageStream();
        break;
      case AppLifecycleState.resumed:
        if (!cameraController!.value.isStreamingImages) {
          await cameraController!.startImageStream(onLatestImageAvailable);
        }
        break;
      default:
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cameraController!.dispose();
    super.dispose();
  }
}

class FixedBoundingBoxPainter extends CustomPainter {
  final Rect boundingBox;
  final bool isInFixedBox;

  FixedBoundingBoxPainter(this.boundingBox, this.isInFixedBox);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = isInFixedBox ? Colors.green : Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Draw the fixed bounding box on the canvas
    canvas.drawRect(boundingBox, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}


