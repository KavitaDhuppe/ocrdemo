
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
WidgetsFlutterBinding.ensureInitialized();

try {
cameras = await availableCameras();
} catch (e) {
debugPrint('Camera initialization error: $e');
cameras = [];
}

runApp(const NulineOcrApp());
}

class NulineOcrApp extends StatelessWidget {
const NulineOcrApp({super.key});

@override
Widget build(BuildContext context) {
return MaterialApp(
debugShowCheckedModeBanner: false,
title: 'Nuline OCR',
theme: ThemeData(
brightness: Brightness.dark,
useMaterial3: true,
),
home: const OcrScannerPage(),
);
}
}

class ScanResult {
final String model;
final String serial;

const ScanResult({
required this.model,
required this.serial,
});

String get key => '$model|$serial';

@override
String toString() {
return 'Model: $model, Serial: $serial';
}
}

class OcrScannerPage extends StatefulWidget {
const OcrScannerPage({super.key});

@override
State<OcrScannerPage> createState() => _OcrScannerPageState();
}

class _OcrScannerPageState extends State<OcrScannerPage>
with WidgetsBindingObserver {
CameraController? _cameraController;

final TextRecognizer _textRecognizer =
TextRecognizer(script: TextRecognitionScript.latin);

bool _isCameraInitialized = false;
bool _isProcessing = false;
bool _isClosing = false;

String _statusText = 'Position the Nuline label inside the frame';

String _liveModel = '-';
String _liveSerial = '-';

DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

static const Duration _ocrInterval = Duration(milliseconds: 500);

// Stable detection.
final List<ScanResult> _detectionHistory = [];

static const int _historySize = 6;
static const int _requiredDetections = 3;

@override
void initState() {
super.initState();

WidgetsBinding.instance.addObserver(this);

_initializeCamera();
}

@override
void dispose() {
WidgetsBinding.instance.removeObserver(this);

_isClosing = true;

_cameraController?.dispose();
_textRecognizer.close();

super.dispose();
}

// =========================================================================
// LIFECYCLE
// =========================================================================

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
final controller = _cameraController;

if (controller == null || !controller.value.isInitialized) {
return;
}

if (state == AppLifecycleState.inactive ||
state == AppLifecycleState.paused) {
controller.dispose();

if (mounted) {
setState(() {
_cameraController = null;
_isCameraInitialized = false;
});
}
} else if (state == AppLifecycleState.resumed) {
if (!_isClosing) {
_initializeCamera();
}
}
}

// =========================================================================
// CAMERA
// =========================================================================

Future<void> _initializeCamera() async {
if (_isClosing || cameras.isEmpty) {
return;
}

if (_isCameraInitialized) {
return;
}

CameraDescription? selectedCamera;

for (final camera in cameras) {
if (camera.lensDirection == CameraLensDirection.back) {
selectedCamera = camera;
break;
}
}

selectedCamera ??= cameras.first;

final controller = CameraController(
selectedCamera,
ResolutionPreset.high,
enableAudio: false,
imageFormatGroup: Platform.isAndroid
? ImageFormatGroup.nv21
    : ImageFormatGroup.bgra8888,
);

try {
await controller.initialize();

if (_isClosing) {
await controller.dispose();
return;
}

try {
await controller.setFocusMode(FocusMode.auto);
} catch (e) {
debugPrint('Unable to set autofocus: $e');
}

_cameraController = controller;

if (!mounted) {
return;
}

setState(() {
_isCameraInitialized = true;
_statusText = 'Scanning label...';
});

await controller.startImageStream(
_processCameraImage,
);
} catch (e) {
debugPrint('Camera initialization failed: $e');

await controller.dispose();

if (!mounted) {
return;
}

setState(() {
_isCameraInitialized = false;
_statusText = 'Unable to initialize camera';
});
}
}

// =========================================================================
// CAMERA IMAGE -> OCR
// =========================================================================

Future<void> _processCameraImage(CameraImage image) async {
if (_isProcessing || _isClosing) {
return;
}

final now = DateTime.now();

if (now.difference(_lastProcessed) < _ocrInterval) {
return;
}

_lastProcessed = now;
_isProcessing = true;

try {
final controller = _cameraController;

if (controller == null || !controller.value.isInitialized) {
return;
}

final inputImage = _inputImageFromCameraImage(
image,
controller.description,
);

if (inputImage == null) {
return;
}

final recognizedText = await _textRecognizer.processImage(
inputImage,
);

// ---------------------------------------------------------------------
// DIAGNOSTIC OCR OUTPUT
// ---------------------------------------------------------------------

debugPrint(
'================ OCR RESULT ================',
);

for (final block in recognizedText.blocks) {
for (final line in block.lines) {
debugPrint(
'OCR LINE: "${line.text}" '
'BOX=${line.boundingBox}',
);
}
}

debugPrint(
'============================================',
);

if (_isClosing) {
return;
}

final result = _extractScanResult(recognizedText);

if (result == null) {
if (mounted) {
setState(() {
_statusText = 'Searching for Model and Serial...';
});
}

return;
}

debugPrint('VALID RESULT: $result');

if (mounted) {
setState(() {
_liveModel = result.model;
_liveSerial = result.serial;
_statusText = 'Model and Serial detected';
});
}

_addDetection(result);

final stableResult = _getStableResult();

if (stableResult != null && mounted) {
await _handleSuccessfulScan(stableResult);
}
} catch (e) {
debugPrint('OCR processing error: $e');
} finally {
_isProcessing = false;
}
}

// =========================================================================
// INPUT IMAGE
// =========================================================================

InputImage? _inputImageFromCameraImage(
CameraImage image,
CameraDescription camera,
) {
try {
final format = InputImageFormatValue.fromRawValue(
image.format.raw,
);

if (format == null) {
debugPrint(
'Unsupported image format: ${image.format.raw}',
);

return null;
}

final rotation = _getInputImageRotation(camera);

final bytes = _concatenatePlanes(image.planes);

if (bytes.isEmpty) {
return null;
}

final metadata = InputImageMetadata(
size: Size(
image.width.toDouble(),
image.height.toDouble(),
),
rotation: rotation,
format: format,
bytesPerRow: image.planes.first.bytesPerRow,
);

return InputImage.fromBytes(
bytes: bytes,
metadata: metadata,
);
} catch (e) {
debugPrint('InputImage conversion error: $e');

return null;
}
}

Uint8List _concatenatePlanes(List<Plane> planes) {
final WriteBuffer allBytes = WriteBuffer();

for (final plane in planes) {
allBytes.putUint8List(plane.bytes);
}

return allBytes.done().buffer.asUint8List();
}

// =========================================================================
// ROTATION
// =========================================================================

InputImageRotation _getInputImageRotation(
CameraDescription camera,
) {
final sensorOrientation = camera.sensorOrientation;

if (Platform.isIOS) {
return InputImageRotationValue.fromRawValue(
sensorOrientation,
) ??
InputImageRotation.rotation0deg;
}

final orientation =
_cameraController?.value.deviceOrientation ??
DeviceOrientation.portraitUp;

final rotation = _rotationFromDeviceOrientation(
orientation,
sensorOrientation,
camera.lensDirection,
);

return InputImageRotationValue.fromRawValue(
rotation,
) ??
InputImageRotation.rotation0deg;
}

int _rotationFromDeviceOrientation(
DeviceOrientation orientation,
int sensorOrientation,
CameraLensDirection lensDirection,
) {
const orientations = <DeviceOrientation, int>{
DeviceOrientation.portraitUp: 0,
DeviceOrientation.landscapeLeft: 90,
DeviceOrientation.portraitDown: 180,
DeviceOrientation.landscapeRight: 270,
};

final deviceOrientation = orientations[orientation] ?? 0;

if (lensDirection == CameraLensDirection.front) {
return (sensorOrientation + deviceOrientation) % 360;
}

return (sensorOrientation - deviceOrientation + 360) % 360;
}

// =========================================================================
// EXTRACTION
// =========================================================================

ScanResult? _extractScanResult(
RecognizedText recognizedText,
) {
final lines = <TextLine>[];

for (final block in recognizedText.blocks) {
lines.addAll(block.lines);
}

if (lines.isEmpty) {
return null;
}

final model = _extractModel(lines);
final serial = _extractSerial(lines);

debugPrint(
'EXTRACTION RESULT -> '
'MODEL=$model SERIAL=$serial',
);

if (model == null || serial == null) {
return null;
}

return ScanResult(
model: model,
serial: serial,
);
}

// =========================================================================
// MODEL EXTRACTION
//
// Generic:
// Find "Model" and select the OCR value aligned with that label.
//
// No specific model number such as MF70BT / HR600G is hard-coded.
// =========================================================================

String? _extractModel(List<TextLine> lines) {
for (final label in lines) {
if (!_isModelLabel(label.text)) {
continue;
}

debugPrint(
'MODEL LABEL FOUND: '
'"${label.text}" '
'BOX=${label.boundingBox}',
);

final candidates = _findRightSideCandidates(
label,
lines,
);

for (final candidate in candidates) {
final cleaned = _cleanModelNumber(
candidate.text,
);

debugPrint(
'MODEL RIGHT CANDIDATE: '
'"${candidate.text}" '
'-> "$cleaned"',
);

if (_isValidModel(cleaned, label, candidate)) {
debugPrint(
'MODEL ACCEPTED: $cleaned',
);

return cleaned;
}
}

final sameRowCandidates = _findSameRowCandidates(
label,
lines,
);

for (final candidate in sameRowCandidates) {
final cleaned = _cleanModelNumber(
candidate.text,
);

debugPrint(
'MODEL SAME-ROW CANDIDATE: '
'"${candidate.text}" '
'-> "$cleaned"',
);

if (_isValidModel(cleaned, label, candidate)) {
debugPrint(
'MODEL SAME-ROW ACCEPTED: $cleaned',
);

return cleaned;
}
}
}

return null;
}

bool _isModelLabel(String text) {
final normalized = text
    .toUpperCase()
    .replaceAll(
RegExp(r'[^A-Z0-9]'),
'',
);

return normalized == 'MODEL' ||
normalized == 'M0DEL' ||
normalized == 'MODEI' ||
normalized == 'MODLE';
}

String _cleanModelNumber(String value) {
var cleaned = value.trim();

cleaned = cleaned.replaceAll(
RegExp(
r'^[\s:;=#\-_/]+|[\s:;=#\-_/]+$',
),
'',
);

cleaned = cleaned.replaceAll(
RegExp(r'\s+'),
' ',
);

return cleaned;
}

bool _isValidModel(
String value,
TextLine label,
TextLine candidate,
) {
final cleaned = value.trim();

if (cleaned.isEmpty) {
return false;
}

if (!RegExp(
r'[A-Z0-9]',
caseSensitive: false,
).hasMatch(cleaned)) {
return false;
}

final normalized = cleaned
    .toUpperCase()
    .replaceAll(
RegExp(r'[^A-Z0-9]'),
'',
);

// Never return a label as the model.
const rejectedLabels = {
'MODEL',
'MODE',
'MODLE',
'M0DEL',
'SERIAL',
'SERIALNO',
'SERIALNUMBER',
'SNO',
'SN',
};

if (rejectedLabels.contains(normalized)) {
return false;
}

// Reject obvious specification labels.
const rejectedWords = {
'VOLT',
'VOLTAGE',
'HZ',
'AMP',
'AMPS',
'CURRENT',
'WATT',
'WATTS',
'POWER',
'PH',
'PHASE',
};

if (rejectedWords.contains(normalized)) {
return false;
}

return true;
}

// =========================================================================
// SERIAL EXTRACTION
//
// Generic:
// Find "Serial", "Serial No.", etc. and select the OCR value
// aligned with that label.
// =========================================================================

String? _extractSerial(List<TextLine> lines) {
for (final label in lines) {
if (!_isSerialLabel(label.text)) {
continue;
}

debugPrint(
'SERIAL LABEL FOUND: '
'"${label.text}" '
'BOX=${label.boundingBox}',
);

final candidates = _findRightSideCandidates(
label,
lines,
);

for (final candidate in candidates) {
final cleaned = _cleanSerialNumber(
candidate.text,
);

debugPrint(
'SERIAL RIGHT CANDIDATE: '
'"${candidate.text}" '
'-> "$cleaned"',
);

if (_isValidSerial(cleaned)) {
debugPrint(
'SERIAL ACCEPTED: $cleaned',
);

return cleaned;
}
}

final sameRowCandidates = _findSameRowCandidates(
label,
lines,
);

for (final candidate in sameRowCandidates) {
final cleaned = _cleanSerialNumber(
candidate.text,
);

debugPrint(
'SERIAL SAME-ROW CANDIDATE: '
'"${candidate.text}" '
'-> "$cleaned"',
);

if (_isValidSerial(cleaned)) {
debugPrint(
'SERIAL SAME-ROW ACCEPTED: $cleaned',
);

return cleaned;
}
}
}

return null;
}

bool _isSerialLabel(String text) {
final normalized = text
    .toUpperCase()
    .replaceAll(
RegExp(r'[\s.:=#_\-]'),
'',
);

return normalized == 'SERIAL' ||
normalized == 'SERIALNO' ||
normalized == 'SERIALNUMBER' ||
normalized == 'SNO' ||
normalized == 'SN';
}

// =========================================================================
// SPATIAL CANDIDATES
//
// The important rule here is:
//
// 1. Candidate must be to the right.
// 2. Candidate must be vertically aligned with the label.
// 3. Candidates are sorted primarily by vertical alignment.
//
// This prevents a value from the row above/below from being selected
// simply because it happens to be horizontally closer.
// =========================================================================

List<TextLine> _findRightSideCandidates(
TextLine label,
List<TextLine> lines,
) {
final labelBox = label.boundingBox;

final candidates = <TextLine>[];

for (final candidate in lines) {
if (identical(candidate, label)) {
continue;
}

final box = candidate.boundingBox;

// Candidate must start to the right of the label.
if (box.left <= labelBox.right) {
continue;
}

final labelCenterY = labelBox.center.dy;
final candidateCenterY = box.center.dy;

final verticalDifference =
(candidateCenterY - labelCenterY).abs();

final maxHeight = math.max(
labelBox.height,
box.height,
);

// Allow a reasonable OCR bounding-box difference.
final allowedVerticalDifference =
maxHeight * 0.90;

if (verticalDifference >
allowedVerticalDifference) {
continue;
}

candidates.add(candidate);
}

// IMPORTANT:
// First preference = closest vertical alignment.
// Second preference = closest horizontal distance.
candidates.sort(
(a, b) {
final verticalA =
(a.boundingBox.center.dy -
labelBox.center.dy)
    .abs();

final verticalB =
(b.boundingBox.center.dy -
labelBox.center.dy)
    .abs();

final verticalCompare =
verticalA.compareTo(verticalB);

if (verticalCompare != 0) {
return verticalCompare;
}

final horizontalA =
a.boundingBox.left -
labelBox.right;

final horizontalB =
b.boundingBox.left -
labelBox.right;

return horizontalA.compareTo(horizontalB);
},
);

return candidates;
}

// =========================================================================
// SAME ROW FALLBACK
// =========================================================================

List<TextLine> _findSameRowCandidates(
TextLine label,
List<TextLine> lines,
) {
final labelBox = label.boundingBox;

final candidates = <TextLine>[];

for (final candidate in lines) {
if (identical(candidate, label)) {
continue;
}

final box = candidate.boundingBox;

if (box.left <= labelBox.left) {
continue;
}

final centerY = box.center.dy;
final labelCenterY = labelBox.center.dy;

final verticalDifference =
(centerY - labelCenterY).abs();

final allowedDifference = math.max(
labelBox.height,
box.height,
) *
1.5;

if (verticalDifference <=
allowedDifference) {
candidates.add(candidate);
}
}

candidates.sort(
(a, b) {
final verticalA =
(a.boundingBox.center.dy -
labelBox.center.dy)
    .abs();

final verticalB =
(b.boundingBox.center.dy -
labelBox.center.dy)
    .abs();

final verticalCompare =
verticalA.compareTo(verticalB);

if (verticalCompare != 0) {
return verticalCompare;
}

final distanceA =
a.boundingBox.left -
labelBox.right;

final distanceB =
b.boundingBox.left -
labelBox.right;

return distanceA.compareTo(distanceB);
},
);

return candidates;
}

// =========================================================================
// SERIAL CLEANUP / VALIDATION
// =========================================================================

String _cleanSerialNumber(String value) {
var cleaned = value.toUpperCase().trim();

cleaned = cleaned.replaceAll(
RegExp(
r'^[\s:;=#\-_/]+|[\s:;=#\-_/]+$',
),
'',
);

cleaned = cleaned.replaceAll(
RegExp(r'\s+'),
'',
);

cleaned = cleaned.replaceAll(
RegExp(r'[^A-Z0-9]'),
'',
);

return cleaned;
}

bool _isValidSerial(String value) {
final cleaned = value.trim().toUpperCase();

if (cleaned.length < 3) {
return false;
}

if (!RegExp(r'\d').hasMatch(cleaned)) {
return false;
}

if (!RegExp(r'^[A-Z0-9]+$').hasMatch(cleaned)) {
return false;
}

const rejectedWords = {
'MODEL',
'SERIAL',
'SER',
'SNO',
'SN',
'VOLT',
'VOLTAGE',
'POWER',
'AMP',
'AMPS',
'CURRENT',
'WATT',
'WATTS',
'HZ',
'PH',
'PHASE',
'TYPE',
'NULINE',
'REFRIGERATION',
'REFRIGERATOR',
'FREEZER',
'MADE',
'CHINA',
};

if (rejectedWords.contains(cleaned)) {
return false;
}

// Electrical specifications.
if (RegExp(r'^\d+V$').hasMatch(cleaned)) {
return false;
}

if (RegExp(r'^\d+HZ$').hasMatch(cleaned)) {
return false;
}

if (RegExp(r'^\d+AMP$').hasMatch(cleaned)) {
return false;
}

// Very small numbers are unlikely to be serials.
if (RegExp(r'^\d{1,2}$').hasMatch(cleaned)) {
return false;
}

return true;
}

// =========================================================================
// STABLE RESULT
// =========================================================================

void _addDetection(ScanResult result) {
_detectionHistory.add(result);

if (_detectionHistory.length > _historySize) {
_detectionHistory.removeAt(0);
}

debugPrint(
'Detection history: '
'${_detectionHistory.map((e) => e.key).join(' | ')}',
);
}

ScanResult? _getStableResult() {
if (_detectionHistory.length < _requiredDetections) {
return null;
}

final counts = <String, int>{};
final results = <String, ScanResult>{};

for (final result in _detectionHistory) {
counts[result.key] =
(counts[result.key] ?? 0) + 1;

results[result.key] = result;
}

String? bestKey;
int bestCount = 0;

for (final entry in counts.entries) {
if (entry.value > bestCount) {
bestKey = entry.key;
bestCount = entry.value;
}
}

if (bestKey == null ||
bestCount < _requiredDetections) {
return null;
}

debugPrint(
'STABLE RESULT: '
'${results[bestKey]} '
'with $bestCount detections',
);

return results[bestKey];
}

// =========================================================================
// SUCCESS
// =========================================================================

Future<void> _handleSuccessfulScan(
ScanResult result,
) async {
if (_isClosing) {
return;
}

_isClosing = true;

try {
final controller = _cameraController;

if (controller != null &&
controller.value.isStreamingImages) {
await controller.stopImageStream();
}
} catch (e) {
debugPrint(
'Unable to stop image stream: $e',
);
}

if (!mounted) {
return;
}

await showDialog<void>(
context: context,
barrierDismissible: false,
builder: (context) {
return AlertDialog(
title: const Text(
'Nuline Label Detected',
),
content: Column(
mainAxisSize: MainAxisSize.min,
crossAxisAlignment:
CrossAxisAlignment.start,
children: [
const Text(
'Model',
style: TextStyle(
fontWeight: FontWeight.bold,
),
),
const SizedBox(height: 4),
Text(
result.model,
style: const TextStyle(
fontSize: 20,
),
),
const SizedBox(height: 16),
const Text(
'Serial Number',
style: TextStyle(
fontWeight: FontWeight.bold,
),
),
const SizedBox(height: 4),
Text(
result.serial,
style: const TextStyle(
fontSize: 20,
),
),
],
),
actions: [
TextButton(
onPressed: () {
Navigator.of(context).pop();
},
child: const Text('OK'),
),
],
);
},
);

if (!mounted) {
return;
}

_isClosing = false;

setState(() {
_detectionHistory.clear();

_statusText =
'Position the Nuline label inside the frame';

_liveModel = '-';
_liveSerial = '-';
});

final controller = _cameraController;

if (controller != null &&
controller.value.isInitialized &&
!controller.value.isStreamingImages) {
try {
await controller.startImageStream(
_processCameraImage,
);
} catch (e) {
debugPrint(
'Unable to restart image stream: $e',
);
}
}
}

// =========================================================================
// UI
// =========================================================================

@override
Widget build(BuildContext context) {
return Scaffold(
backgroundColor: Colors.black,
body: SafeArea(
child: _buildScanner(),
),
);
}

Widget _buildScanner() {
if (!_isCameraInitialized ||
_cameraController == null ||
!_cameraController!.value.isInitialized) {
return const Center(
child: CircularProgressIndicator(),
);
}

return Stack(
fit: StackFit.expand,
children: [
CameraPreview(
_cameraController!,
),

CustomPaint(
painter: ScannerOverlayPainter(),
),

Positioned(
top: 20,
left: 20,
right: 20,
child: Row(
children: [
IconButton(
onPressed: () {
Navigator.of(context).pop();
},
icon: const Icon(
Icons.close,
color: Colors.white,
size: 30,
),
),
const Spacer(),
const Text(
'Nuline OCR',
style: TextStyle(
color: Colors.white,
fontSize: 20,
fontWeight: FontWeight.bold,
),
),
const Spacer(),
const SizedBox(width: 48),
],
),
),

Positioned(
left: 20,
right: 20,
bottom: 90,
child: Column(
children: [
Container(
padding: const EdgeInsets.symmetric(
horizontal: 16,
vertical: 10,
),
decoration: BoxDecoration(
color: Colors.black.withOpacity(0.70),
borderRadius:
BorderRadius.circular(12),
),
child: Text(
_statusText,
textAlign: TextAlign.center,
style: const TextStyle(
color: Colors.white,
fontSize: 15,
),
),
),
const SizedBox(height: 12),
Container(
padding: const EdgeInsets.all(12),
decoration: BoxDecoration(
color: Colors.black.withOpacity(0.70),
borderRadius:
BorderRadius.circular(12),
),
child: Column(
children: [
_buildLiveValue(
'MODEL',
_liveModel,
),
const SizedBox(height: 6),
_buildLiveValue(
'SERIAL',
_liveSerial,
),
],
),
),
],
),
),
],
);
}

Widget _buildLiveValue(
String label,
String value,
) {
return Row(
children: [
SizedBox(
width: 70,
child: Text(
label,
style: const TextStyle(
color: Colors.white70,
fontSize: 12,
fontWeight: FontWeight.bold,
),
),
),
Expanded(
child: Text(
value,
style: const TextStyle(
color: Colors.white,
fontSize: 15,
fontWeight: FontWeight.bold,
),
),
),
],
);
}
}

// ============================================================================
// SCANNER OVERLAY
// ============================================================================

class ScannerOverlayPainter extends CustomPainter {
@override
void paint(
Canvas canvas,
Size size,
) {
final paint = Paint()
..color = Colors.black.withOpacity(0.55)
..style = PaintingStyle.fill;

final rectWidth = size.width * 0.86;
final rectHeight = size.height * 0.28;

final left = (size.width - rectWidth) / 2;
final top = (size.height - rectHeight) / 2;

final scanRect = Rect.fromLTWH(
left,
top,
rectWidth,
rectHeight,
);

final path = Path()
..addRect(
Rect.fromLTWH(
0,
0,
size.width,
size.height,
),
)
..addRect(scanRect);

path.fillType = PathFillType.evenOdd;

canvas.drawPath(path, paint);

final borderPaint = Paint()
..color = Colors.white
..style = PaintingStyle.stroke
..strokeWidth = 2;

canvas.drawRect(
scanRect,
borderPaint,
);

final cornerPaint = Paint()
..color = Colors.white
..style = PaintingStyle.stroke
..strokeWidth = 4;

const cornerLength = 25.0;

// Top-left.
canvas.drawLine(
Offset(left, top),
Offset(
left + cornerLength,
top,
),
cornerPaint,
);

canvas.drawLine(
Offset(left, top),
Offset(
left,
top + cornerLength,
),
cornerPaint,
);

// Top-right.
canvas.drawLine(
Offset(
left + rectWidth,
top,
),
Offset(
left + rectWidth - cornerLength,
top,
),
cornerPaint,
);

canvas.drawLine(
Offset(
left + rectWidth,
top,
),
Offset(
left + rectWidth,
top + cornerLength,
),
cornerPaint,
);

// Bottom-left.
canvas.drawLine(
Offset(
left,
top + rectHeight,
),
Offset(
left + cornerLength,
top + rectHeight,
),
cornerPaint,
);

canvas.drawLine(
Offset(
left,
top + rectHeight,
),
Offset(
left,
top + rectHeight - cornerLength,
),
cornerPaint,
);

// Bottom-right.
canvas.drawLine(
Offset(
left + rectWidth,
top + rectHeight,
),
Offset(
left + rectWidth - cornerLength,
top + rectHeight,
),
cornerPaint,
);

canvas.drawLine(
Offset(
left + rectWidth,
top + rectHeight,
),
Offset(
left + rectWidth,
top + rectHeight - cornerLength,
),
cornerPaint,
);
}

@override
bool shouldRepaint(
covariant CustomPainter oldDelegate,
) {
return false;
}
}
