import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RepairRadarApp());
}

class RepairRadarApp extends StatelessWidget {
  const RepairRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'رادار الأعطال الذكي',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.tealAccent,
          secondary: Colors.amberAccent,
        ),
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: MainHomeScreen(),
      ),
    );
  }
}

// ==================== 1. قاعدة البيانات المحلية (نصوص + صور مدمجة) ====================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('repair_faults_v2.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);
    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE faults (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        brand TEXT,
        model TEXT,
        fault_category TEXT,
        symptoms TEXT,
        solution TEXT,
        ic_or_lines TEXT,
        image_base64 TEXT,
        raw_post TEXT UNIQUE,
        date_added TEXT
      )
    ''');
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE faults ADD COLUMN image_base64 TEXT;');
    }
  }

  Future<int> insertFault(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert(
      'faults',
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, dynamic>>> searchFaults(String query) async {
    final db = await instance.database;
    if (query.trim().isEmpty) {
      return await db.query('faults', orderBy: 'id DESC');
    }
    return await db.query(
      'faults',
      where:
          'model LIKE ? OR brand LIKE ? OR fault_category LIKE ? OR symptoms LIKE ? OR solution LIKE ? OR ic_or_lines LIKE ?',
      whereArgs: List.filled(6, '%$query%'),
      orderBy: 'id DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getAllFaults() async {
    final db = await instance.database;
    return await db.query('faults', orderBy: 'id DESC');
  }

  Future<int> deleteFault(int id) async {
    final db = await instance.database;
    return await db.delete('faults', where: 'id = ?', whereArgs: [id]);
  }
}

// ==================== 2. الشاشة الرئيسية للتطبيق ====================
class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _tabs = [
    const FaultsLibraryTab(),
    const FacebookRadarTab(),
    const BackupAndSettingsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: Colors.tealAccent,
        unselectedItemColor: Colors.grey,
        backgroundColor: const Color(0xFF1E1E1E),
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.build_circle_outlined),
            label: 'موسوعة الأعطال',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.radar),
            label: 'رادار فيسبوك',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.import_export),
            label: 'نقل البيانات والإعدادات',
          ),
        ],
      ),
    );
  }
}

// ==================== التبويب الأول: موسوعة الأعطال + الإدخال اليدوي بالكاميرا ====================
class FaultsLibraryTab extends StatefulWidget {
  const FaultsLibraryTab({super.key});

  @override
  State<FaultsLibraryTab> createState() => _FaultsLibraryTabState();
}

class _FaultsLibraryTabState extends State<FaultsLibraryTab> {
  List<Map<String, dynamic>> _faults = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isLoadingAI = false;

  @override
  void initState() {
    super.initState();
    _loadFaults();
  }

  Future<void> _loadFaults([String query = '']) async {
    final data = await DatabaseHelper.instance.searchFaults(query);
    setState(() => _faults = data);
  }

  void _openFullScreenImage(Uint8List imageBytes, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black87,
              title: Text(title, style: const TextStyle(fontSize: 16)),
            ),
            body: Center(
              child: InteractiveViewer(
                panEnabled: true,
                minScale: 0.5,
                maxScale: 6.0,
                child: Image.memory(imageBytes, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAddManualFaultSheet() {
    final brandCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final categoryCtrl = TextEditingController(text: 'باور / شحن');
    final symptomsCtrl = TextEditingController();
    final solutionCtrl = TextEditingController();
    final icLinesCtrl = TextEditingController();
    Uint8List? pickedImageBytes;
    bool isAnalyzingImage = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> pickBoardImage(ImageSource source) async {
              final picker = ImagePicker();
              final XFile? file = await picker.pickImage(
                source: source,
                imageQuality: 75,
                maxWidth: 1280,
              );
              if (file != null) {
                final bytes = await file.readAsBytes();
                setModalState(() => pickedImageBytes = bytes);
              }
            }

            Future<void> analyzeImageAndNotesWithAI() async {
              final prefs = await SharedPreferences.getInstance();
              final apiKey = prefs.getString('gemini_api_key') ?? '';
              if (apiKey.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('أدخل مفتاح Gemini API في الإعدادات أولاً')),
                );
                return;
              }
              if (pickedImageBytes == null &&
                  symptomsCtrl.text.trim().isEmpty &&
                  solutionCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('التقط صورة للبوردة أو اكتب ملاحظة سريعة في خانة الأعراض أولاً!')),
                );
                return;
              }

              setModalState(() => isAnalyzingImage = true);
              try {
                final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
                final userNotes = '${modelCtrl.text} ${symptomsCtrl.text} ${solutionCtrl.text}';
                final prompt = '''
أنت مهندس صيانة هواتف محترف. قام الفني بتصوير هذه البوردة/المخطط وكتب هذه الملاحظة: "$userNotes"
حلل الصورة والملاحظة واستخرج بيانات العطل بدقة بصيغة JSON فقط كالتالي:
{
  "brand": "اسم الشركة مثل Samsung أو Xiaomi",
  "model": "موديل الجهاز",
  "fault_category": "تصنيف العطل (باور / شحن / إضاءة / شبكة / بيانات)",
  "symptoms": "الأعراض وقراءات الباور سبلاي أو الممانعة",
  "solution": "شرح الحل بالتفصيل وما يظهر في الصورة من مسارات أو آيسيهات أو قفلات",
  "ic_or_lines": "أرقام الآيسيهات أو أسماء المسارات مثل VPH_PWR"
}
''';

                final List<Content> contents = [];
                if (pickedImageBytes != null) {
                  contents.add(Content.multi([
                    TextPart(prompt),
                    DataPart('image/jpeg', pickedImageBytes!),
                  ]));
                } else {
                  contents.add(Content.text(prompt));
                }

                final response = await model.generateContent(contents);
                final cleanJson =
                    (response.text ?? '').replaceAll('```json', '').replaceAll('```', '').trim();
                final Map<String, dynamic> data = jsonDecode(cleanJson);

                setModalState(() {
                  brandCtrl.text = data['brand'] ?? brandCtrl.text;
                  modelCtrl.text = data['model'] ?? modelCtrl.text;
                  categoryCtrl.text = data['fault_category'] ?? categoryCtrl.text;
                  symptomsCtrl.text = data['symptoms'] ?? symptomsCtrl.text;
                  solutionCtrl.text = data['solution'] ?? solutionCtrl.text;
                  icLinesCtrl.text = data['ic_or_lines'] ?? icLinesCtrl.text;
                });
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('تعذر التحليل التلقائي: $e')),
                );
              } finally {
                setModalState(() => isAnalyzingImage = false);
              }
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                  left: 16,
                  right: 16,
                  top: 16,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(
                        child: Text(
                          '📸 تسجيل عطل جديد / تصوير بوردة',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => pickBoardImage(ImageSource.camera),
                              icon: const Icon(Icons.camera_alt, color: Colors.amberAccent),
                              label: const Text('تصوير بالكاميرا'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => pickBoardImage(ImageSource.gallery),
                              icon: const Icon(Icons.photo_library, color: Colors.tealAccent),
                              label: const Text('من المعرض'),
                            ),
                          ),
                        ],
                      ),
                      if (pickedImageBytes != null) ...[
                        const SizedBox(height: 8),
                        Stack(
                          alignment: Alignment.topLeft,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                pickedImageBytes!,
                                height: 150,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                            IconButton(
                              icon: const CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.red,
                                child: Icon(Icons.close, size: 16, color: Colors.white),
                              ),
                              onPressed: () => setModalState(() => pickedImageBytes = null),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
                          onPressed: isAnalyzingImage ? null : analyzeImageAndNotesWithAI,
                          icon: isAnalyzingImage
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.auto_fix_high, color: Colors.amberAccent),
                          label: const Text(
                            'تحليل الصورة وترتيب البيانات بالذكاء الاصطناعي ✨',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: brandCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'الشركة (مثال: Samsung)', isDense: true),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: modelCtrl,
                              decoration:
                                  const InputDecoration(labelText: 'الموديل (مثال: A12)', isDense: true),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: categoryCtrl,
                        decoration: const InputDecoration(
                            labelText: 'تصنيف العطل (باور، إضاءة، شحن...)', isDense: true),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: symptomsCtrl,
                        decoration: const InputDecoration(
                          labelText: 'الأعراض / سحب الباور سبلاي (أو اكتب ملاحظتك هنا قبل التحليل)',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: solutionCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'خطوات الحل والتركة المجربة',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: icLinesCtrl,
                        decoration: const InputDecoration(
                          labelText: 'الآيسيهات أو المسارات (مثال: VPH_PWR / MT6358)',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: () async {
                            if (modelCtrl.text.trim().isEmpty &&
                                solutionCtrl.text.trim().isEmpty) {
                              return;
                            }
                            await DatabaseHelper.instance.insertFault({
                              'brand': brandCtrl.text.trim().isEmpty ? 'يدوي' : brandCtrl.text.trim(),
                              'model': modelCtrl.text.trim().isEmpty ? 'عام' : modelCtrl.text.trim(),
                              'fault_category': categoryCtrl.text.trim(),
                              'symptoms': symptomsCtrl.text.trim(),
                              'solution': solutionCtrl.text.trim(),
                              'ic_or_lines': icLinesCtrl.text.trim(),
                              'image_base64':
                                  pickedImageBytes != null ? base64Encode(pickedImageBytes!) : '',
                              'raw_post': 'MANUAL_${DateTime.now().millisecondsSinceEpoch}',
                              'date_added': DateTime.now().toString().substring(0, 16),
                            });
                            _loadFaults(_searchController.text);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          icon: const Icon(Icons.save, color: Colors.white),
                          label: const Text(
                            'حفظ العطل والصورة في موسوعتي',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _askGeminiDirectly(String query) async {
    if (query.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('gemini_api_key') ?? '';
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى وضع مفتاح Gemini API في تبويب الإعدادات أولاً')),
      );
      return;
    }

    setState(() => _isLoadingAI = true);
    try {
      final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
      final prompt = '''
أنت خبير صيانة هاردوير هواتف محمولة ومخططات (Schematics & Troubleshooting).
الفني يسألك عن هذا العطل: "$query"
أعطه خطوات الفحص العملية بالترتيب (قراءات الباور سبلاي، خطوط الفولت مثل VPH_PWR أو VBAT، الآيسيهات المسؤولة، الممانعات المتوقعة، وأشهر التركيبات أو القفلات المعروفة لهذا الموديل).
''';
      final response = await model.generateContent([Content.text(prompt)]);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('تحليل الذكاء الاصطناعي لـ: $query'),
            content: SingleChildScrollView(
              child: SelectableText(response.text ?? 'لم يتم العثور على إجابة'),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await DatabaseHelper.instance.insertFault({
                    'brand': 'بحث ذكاء اصطناعي',
                    'model': query,
                    'fault_category': 'استشارة مباشرة',
                    'symptoms': query,
                    'solution': response.text ?? '',
                    'ic_or_lines': 'مخططات صيانة',
                    'image_base64': '',
                    'raw_post': 'AI_${DateTime.now().millisecondsSinceEpoch}',
                    'date_added': DateTime.now().toString().substring(0, 16),
                  });
                  _loadFaults(_searchController.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('حفظ في موسوعتي 💾'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إغلاق'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ في الاتصال: $e')),
      );
    } finally {
      setState(() => _isLoadingAI = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('موسوعة الأعطال والمسارات'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadFaults(_searchController.text),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.tealAccent,
        foregroundColor: Colors.black,
        onPressed: _showAddManualFaultSheet,
        icon: const Icon(Icons.add_a_photo),
        label: const Text('إضافة عطل / تصوير بوردة',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (val) => _loadFaults(val),
                    decoration: InputDecoration(
                      hintText: 'ابحث بموديل (مثلاً A12) أو مسار أو آي سي...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: const Color(0xFF1E1E1E),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                  ),
                  onPressed:
                      _isLoadingAI ? null : () => _askGeminiDirectly(_searchController.text),
                  icon: _isLoadingAI
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome, color: Colors.white),
                  label: const Text('اسأل AI', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _faults.isEmpty
                ? const Center(
                    child: Text(
                      'لا توجد أعطال مسجلة بهذا الاسم بعد.\nشغّل "رادار فيسبوك" أو اضغط زر "إضافة عطل / تصوير بوردة" بالأسفل!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: _faults.length,
                    itemBuilder: (context, index) {
                      final item = _faults[index];
                      final String base64Img = item['image_base64'] ?? '';
                      Uint8List? imageBytes;
                      if (base64Img.isNotEmpty) {
                        try {
                          imageBytes = base64Decode(base64Img);
                        } catch (_) {}
                      }

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        color: const Color(0xFF1E1E1E),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ExpansionTile(
                          leading: imageBytes != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    imageBytes,
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : const CircleAvatar(
                                  backgroundColor: Colors.teal,
                                  child: Icon(Icons.memory, color: Colors.white),
                                ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${item['brand']} - ${item['model']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, color: Colors.tealAccent),
                                ),
                              ),
                              if (imageBytes != null)
                                const Icon(Icons.image, color: Colors.amberAccent, size: 18),
                            ],
                          ),
                          subtitle:
                              Text('العطل: ${item['fault_category']} | ${item['symptoms']}'),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (imageBytes != null) ...[
                                    GestureDetector(
                                      onTap: () => _openFullScreenImage(
                                        imageBytes!,
                                        '${item['brand']} ${item['model']} - ${item['fault_category']}',
                                      ),
                                      child: Stack(
                                        alignment: Alignment.bottomLeft,
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(10),
                                            child: Image.memory(
                                              imageBytes,
                                              width: double.infinity,
                                              height: 200,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                          Container(
                                            margin: const EdgeInsets.all(8),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.black87,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.zoom_in,
                                                    color: Colors.tealAccent, size: 18),
                                                SizedBox(width: 4),
                                                Text('اضغط لتكبير البوردة / المسار',
                                                    style: TextStyle(fontSize: 12)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  const Text('✅ الحل المستخلص:',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold, color: Colors.amberAccent)),
                                  const SizedBox(height: 4),
                                  SelectableText(item['solution'] ?? ''),
                                  const SizedBox(height: 8),
                                  Text('🔧 الآيسيهات/المسارات: ${item['ic_or_lines']}',
                                      style: const TextStyle(color: Colors.lightBlueAccent)),
                                  const Divider(),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('تاريخ الحفظ: ${item['date_added']}',
                                          style: const TextStyle(
                                              fontSize: 12, color: Colors.grey)),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            color: Colors.redAccent),
                                        onPressed: () async {
                                          await DatabaseHelper.instance.deleteFault(item['id']);
                                          _loadFaults(_searchController.text);
                                        },
                                      ),
                                    ],
                                  )
                                ],
                              ),
                            )
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ==================== التبويب الثاني: رادار فيسبوك الذكي ====================
class FacebookRadarTab extends StatefulWidget {
  const FacebookRadarTab({super.key});

  @override
  State<FacebookRadarTab> createState() => _FacebookRadarTabState();
}

class _FacebookRadarTabState extends State<FacebookRadarTab> {
  InAppWebViewController? _webController;
  bool _isRadarRunning = false;
  Timer? _humanScrollTimer;
  String _statusMessage = 'افتح جروب الصيانة أو ابحث عن موديل، ثم شغّل الرادار';
  int _extractedCount = 0;
  final Set<String> _processedPostsHash = {};

  void _toggleRadar() async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('gemini_api_key') ?? '';
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى إدخال مفتاح Gemini API في الإعدادات أولاً!')),
      );
      return;
    }

    setState(() {
      _isRadarRunning = !_isRadarRunning;
      _statusMessage = _isRadarRunning
          ? '🟢 الرادار يعمل: يقرأ البوستات ويفحص صور البورد والمسارات...'
          : '⏸ تم إيقاف الرادار مؤقتاً';
    });

    if (_isRadarRunning) {
      _startHumanLikeBrowsing(apiKey);
    } else {
      _humanScrollTimer?.cancel();
    }
  }

  void _startHumanLikeBrowsing(String apiKey) {
    void scheduleNextStep() {
      if (!_isRadarRunning) return;
      final randomSeconds = Random().nextInt(6) + 8;
      _humanScrollTimer = Timer(Duration(seconds: randomSeconds), () async {
        if (!_isRadarRunning || _webController == null) return;

        final jsResult = await _webController!.evaluateJavascript(source: '''
          (function() {
            var scrollDist = Math.floor(Math.random() * 350) + 350;
            window.scrollBy({ top: scrollDist, behavior: 'smooth' });

            var spans = document.querySelectorAll('span, div[role="button"]');
            spans.forEach(function(el) {
              if (el.innerText === 'عرض المزيد' || el.innerText === 'See more') {
                el.click();
              }
            });

            var posts = [];
            var blocks = document.querySelectorAll('div[data-tracking-duration-id], div[role="article"], article, div._55wo');
            blocks.forEach(function(b) {
              var txt = b.innerText || "";
              var imgs = b.querySelectorAll('img');
              var bestImgUrl = "";
              var maxArea = 0;
              imgs.forEach(function(img) {
                var w = img.naturalWidth || img.width || 0;
                var h = img.naturalHeight || img.height || 0;
                var src = img.src || "";
                if (w > 180 && h > 180 && (w * h) > maxArea && src.startsWith('http') && !src.includes('emoji') && !src.includes('static')) {
                  maxArea = w * h;
                  bestImgUrl = src;
                }
              });

              if (txt.length > 35 || bestImgUrl !== "") {
                posts.push({ text: txt, imageUrl: bestImgUrl });
              }
            });
            return JSON.stringify(posts);
          })();
        ''');

        if (jsResult != null && jsResult != 'null') {
          try {
            final List<dynamic> rawList = jsonDecode(jsResult);
            for (var postObj in rawList) {
              final String cleanText = (postObj['text'] ?? '').toString().trim();
              final String imageUrl = (postObj['imageUrl'] ?? '').toString().trim();
              final String signature =
                  (cleanText.length > 80 ? cleanText.substring(0, 80) : cleanText) + imageUrl;

              if (signature.isNotEmpty && !_processedPostsHash.contains(signature)) {
                _processedPostsHash.add(signature);
                await _analyzeAndSavePostWithImage(cleanText, imageUrl, apiKey);
              }
            }
          } catch (_) {}
        }

        scheduleNextStep();
      });
    }

    scheduleNextStep();
  }

  Future<void> _analyzeAndSavePostWithImage(
      String postText, String imageUrl, String apiKey) async {
    try {
      Uint8List? imageBytes;
      String base64Image = '';

      if (imageUrl.isNotEmpty) {
        try {
          final imgResponse =
              await http.get(Uri.parse(imageUrl)).timeout(const Duration(seconds: 8));
          if (imgResponse.statusCode == 200 && imgResponse.bodyBytes.length > 5000) {
            imageBytes = imgResponse.bodyBytes;
            base64Image = base64Encode(imageBytes);
          }
        } catch (_) {}
      }

      final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
      final promptText = '''
أنت مهندس صيانة موبايلات محترف. حلل هذا المنشور والتعليقات (والصورة المرفقة إن وجدت لبوردة أو مخطط):
النص: "$postText"

إذا كان المنشور والصورة لا يحتويان على أي معلومة صيانة هواتف أو عطل أو مسار (مثلاً بيع، شراء، تهنئة، منشور شخصي)، رد بكلمة واحدة فقط: IGNORE

أما إذا كان يحتوي على عطل ومعلومة فنية أو صورة مسار/تعويض على البوردة، استخرج البيانات بصيغة JSON فقط بدون أي كلام إضافي كالتالي:
{
  "brand": "اسم الشركة مثل Samsung أو Xiaomi أو iPhone",
  "model": "موديل الهاتف مثل A12 أو Note 10",
  "fault_category": "تصنيف العطل (باور / شحن / إضاءة / بيانات / شبكة / صوت / مسارات)",
  "symptoms": "وصف العطل أو سحب الباور سبلاي",
  "solution": "الحل المفصل من النص + اشرح بالتفصيل ما تراه في الصورة المرفقة (مثل مكان القفلة أو المسار المرسوم أو الآي سي المشار إليه)",
  "ic_or_lines": "الآيسيهات أو المسارات المكتوبة في النص أو المرسومة على الصورة"
}
''';

      final List<Content> contents = [];
      if (imageBytes != null) {
        contents.add(Content.multi([
          TextPart(promptText),
          DataPart('image/jpeg', imageBytes),
        ]));
      } else {
        contents.add(Content.text(promptText));
      }

      final response = await model.generateContent(contents);
      final reply = (response.text ?? '').trim();

      if (reply.isNotEmpty && !reply.contains('IGNORE')) {
        final jsonStr = reply.replaceAll('```json', '').replaceAll('```', '').trim();
        final Map<String, dynamic> data = jsonDecode(jsonStr);

        await DatabaseHelper.instance.insertFault({
          'brand': data['brand'] ?? 'غير محدد',
          'model': data['model'] ?? 'عام',
          'fault_category': data['fault_category'] ?? 'صيانة عامة',
          'symptoms': data['symptoms'] ?? '',
          'solution': data['solution'] ?? '',
          'ic_or_lines': data['ic_or_lines'] ?? '',
          'image_base64': base64Image,
          'raw_post':
              (postText.length > 150 ? postText.substring(0, 150) : postText) + imageUrl,
          'date_added': DateTime.now().toString().substring(0, 16),
        });

        if (mounted) {
          setState(() {
            _extractedCount++;
            _statusMessage =
                '✅ تم صيد عطل ${imageBytes != null ? "مع صورة بوردة 📸" : ""}: ${data['brand']} ${data['model']}';
          });
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _humanScrollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('رادار فيسبوك الذكي'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Chip(
              label: Text('تم صيد: $_extractedCount عطل'),
              backgroundColor: Colors.teal.shade900,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: const Color(0xFF1E1E1E),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _statusMessage,
                    style: TextStyle(
                      color: _isRadarRunning ? Colors.greenAccent : Colors.amberAccent,
                      fontSize: 13,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRadarRunning ? Colors.redAccent : Colors.teal,
                  ),
                  onPressed: _toggleRadar,
                  icon: Icon(_isRadarRunning ? Icons.stop : Icons.play_arrow,
                      color: Colors.white),
                  label: Text(
                    _isRadarRunning ? 'إيقاف الرادار' : 'تشغيل الرادار',
                    style:
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://m.facebook.com')),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                userAgent:
                    'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
              ),
              onWebViewCreated: (controller) {
                _webController = controller;
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== التبويب الثالث: نقل البيانات والإعدادات ====================
class BackupAndSettingsTab extends StatefulWidget {
  const BackupAndSettingsTab({super.key});

  @override
  State<BackupAndSettingsTab> createState() => _BackupAndSettingsTabState();
}

class _BackupAndSettingsTabState extends State<BackupAndSettingsTab> {
  final TextEditingController _apiKeyController = TextEditingController();
  int _totalSavedFaults = 0;

  @override
  void initState() {
    super.initState();
    _loadSettingsAndStats();
  }

  Future<void> _loadSettingsAndStats() async {
    final prefs = await SharedPreferences.getInstance();
    _apiKeyController.text = prefs.getString('gemini_api_key') ?? '';
    final all = await DatabaseHelper.instance.getAllFaults();
    setState(() => _totalSavedFaults = all.length);
  }

  Future<void> _saveApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', _apiKeyController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ تم حفظ مفتاح الذكاء الاصطناعي بنجاح')),
    );
  }

  Future<void> _exportDatabaseBackup() async {
    try {
      final allFaults = await DatabaseHelper.instance.getAllFaults();
      if (allFaults.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('قاعدة البيانات فارغة حالياً!')),
        );
        return;
      }

      final jsonString = jsonEncode(allFaults);
      final directory = await getTemporaryDirectory();
      final backupFile =
          File('${directory.path}/repair_faults_with_images_backup.json');
      await backupFile.writeAsString(jsonString);

      await Share.shareXFiles(
        [XFile(backupFile.path)],
        text:
            'نسخة احتياطية شاملة (بالصور والمسارات) لموسوعة أعطال الصيانة ($_totalSavedFaults عطل)',
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء التصدير: $e')),
      );
    }
  }

  Future<void> _importDatabaseBackup() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final jsonString = await file.readAsString();
        final List<dynamic> importedList = jsonDecode(jsonString);

        int added = 0;
        for (var item in importedList) {
          final Map<String, dynamic> row = Map<String, dynamic>.from(item);
          row.remove('id');
          await DatabaseHelper.instance.insertFault(row);
          added++;
        }

        await _loadSettingsAndStats();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('🎉 تم استرجاع ودمج $added عطل بصورها في هاتفك بنجاح!')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ في قراءة ملف النسخة الاحتياطية: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('نقل البيانات والإعدادات')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              color: Colors.teal.shade900,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: const Icon(Icons.storage, size: 40, color: Colors.tealAccent),
                title: const Text('إجمالي الأعطال والصور المحفوظة',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle:
                    Text('$_totalSavedFaults عطل جاهز للبحث وتكبير المسارات بدون إنترنت'),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadSettingsAndStats,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('📦 نقل وحماية موسوعة الأعطال والصور (Backup & Restore)',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
            const SizedBox(height: 8),
            const Text(
              'الملف المصدر يحتوي على جميع الأعطال بالإضافة لصور البوردات والمسارات مدمجة بداخله، جاهز للنقل لأي هاتف جديد بضغطة زر.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _exportDatabaseBackup,
                    icon: const Icon(Icons.upload_file, color: Colors.white),
                    label: const Text('تصدير الموسوعة (حفظ)',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _importDatabaseBackup,
                    icon: const Icon(Icons.download_for_offline, color: Colors.white),
                    label: const Text('استرجاع موسوعة (نقل)',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
            const Divider(height: 40),
            const Text('🔑 مفتاح الذكاء الاصطناعي (Gemini API Key)',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: Colors.tealAccent)),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'الصق مفتاح Gemini API المجاني هنا...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _saveApiKey,
                child: const Text('حفظ المفتاح',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
