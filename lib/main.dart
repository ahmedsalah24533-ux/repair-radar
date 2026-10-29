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
      title: 'رادار الصيانة الشامل',
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

// ==================== 1. قاعدة البيانات المحلية ====================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('repair_faults_v5.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
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
            raw_post TEXT,
            solution_signature TEXT UNIQUE,
            date_added TEXT
          )
        ''');
      },
    );
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

// ==================== 2. الشاشة الرئيسية ====================
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
      body: IndexedStack(index: _currentIndex, children: _tabs),
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

// ==================== التبويب الأول: موسوعة الأعطال ====================
class FaultsLibraryTab extends StatefulWidget {
  const FaultsLibraryTab({super.key});

  @override
  State<FaultsLibraryTab> createState() => _FaultsLibraryTabState();
}

class _FaultsLibraryTabState extends State<FaultsLibraryTab> {
  List<Map<String, dynamic>> _faults = [];
  final TextEditingController _searchController = TextEditingController();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('موسوعة أعطال السوفت والهارد'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadFaults(_searchController.text),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10.0),
            child: TextField(
              controller: _searchController,
              onChanged: (val) => _loadFaults(val),
              decoration: InputDecoration(
                hintText: 'ابحث بموديل، عطل سوفت، ثري آبي، مسار...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
              ),
            ),
          ),
          Expanded(
            child: _faults.isEmpty
                ? const Center(
                    child: Text(
                      'لا توجد أعطال مسجلة بعد.\nشغّل "رادار فيسبوك" ليجمع كل حلول السوفت وير والهارد وير تلقائياً!',
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

                      bool isSoft = (item['fault_category'] ?? '').contains('سوفت');

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        color: const Color(0xFF1E1E1E),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ExpansionTile(
                          leading: imageBytes != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(imageBytes, width: 48, height: 48, fit: BoxFit.cover),
                                )
                              : CircleAvatar(
                                  backgroundColor: isSoft ? Colors.purpleAccent : Colors.teal,
                                  child: Icon(isSoft ? Icons.phone_android : Icons.memory, color: Colors.white),
                                ),
                          title: Text(
                            '${item['brand']} - ${item['model']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.tealAccent),
                          ),
                          subtitle: Text('التصنيف: ${item['fault_category']} | ${item['symptoms']}'),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (imageBytes != null) ...[
                                    GestureDetector(
                                      onTap: () => _openFullScreenImage(imageBytes!, '${item['brand']} ${item['model']}'),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Image.memory(imageBytes, width: double.infinity, height: 200, fit: BoxFit.cover),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  const Text('✅ الحل أو التفاصيل:',
                                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amberAccent)),
                                  const SizedBox(height: 4),
                                  SelectableText(item['solution'] ?? ''),
                                  const SizedBox(height: 8),
                                  Text('🔧 تفاصيل إضافية / أدوات: ${item['ic_or_lines']}',
                                      style: const TextStyle(color: Colors.lightBlueAccent)),
                                  const Divider(),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('تاريخ الحفظ: ${item['date_added']}',
                                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
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

// ==================== التبويب الثاني: رادار فيسبوك المعدل والمطور ====================
class FacebookRadarTab extends StatefulWidget {
  const FacebookRadarTab({super.key});

  @override
  State<FacebookRadarTab> createState() => _FacebookRadarTabState();
}

class _FacebookRadarTabState extends State<FacebookRadarTab> {
  InAppWebViewController? _webController;
  bool _isRadarRunning = false;
  Timer? _humanScrollTimer;
  String _statusMessage = 'الرادار جاهز: يمسح ويقرأ كل بوستات الصفحة الحالية';
  int _extractedCount = 0;
  final Set<String> _processedSignatures = {};

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
          ? '🟢 الرادار يعمل بنشاط ويلتقط المنشورات الآن...'
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
      final randomSeconds = Random().nextInt(4) + 5; // فحص أسرع كل 5-8 ثواني
      _humanScrollTimer = Timer(Duration(seconds: randomSeconds), () async {
        if (!_isRadarRunning || _webController == null) return;

        // سكريبت متطور لفحص عناصر الصفحة والبوستات بمرونة تامة
        final jsResult = await _webController!.evaluateJavascript(source: '''
          (function() {
            window.scrollBy({ top: 350, behavior: 'smooth' });

            // الضغط على أزرار "عرض المزيد" تلقائياً
            var buttons = document.querySelectorAll('div[role="button"], span');
            buttons.forEach(function(el) {
              if (el.innerText === 'عرض المزيد' || el.innerText === 'See more') {
                el.click();
              }
            });

            // استخراج النصوص والصور من جميع عناصر الفيسبوك في الشاشة
            var collectedData = [];
            var articles = document.querySelectorAll('article, div[role="article"], div.story_body_container, div._5r67');
            
            if (articles.length === 0) {
              // طريقة بديلة لو كانت صفحة محمولة بسيطة
              articles = document.querySelectorAll('div[data-ft]');
            }

            articles.forEach(function(art) {
              var text = art.innerText || "";
              var images = art.querySelectorAll('img');
              var bestImg = "";
              var maxSz = 0;

              images.forEach(function(img) {
                var w = img.naturalWidth || img.width || 0;
                var h = img.naturalHeight || img.height || 0;
                var src = img.src || "";
                // استبعاد الصور الصغيرة والأيقونات
                if (w > 100 && h > 100 && (w * h) > maxSz && src.startsWith('http') && !src.includes('emoji') && !src.includes('profile')) {
                  maxSz = w * h;
                  bestImg = src;
                }
              });

              if (text.length > 10 || bestImg !== "") {
                collectedData.push({ text: text, imageUrl: bestImg });
              }
            });

            // لو لم يجد articles، يجمع أي نص طويل في الصفحة الظاهرة
            if (collectedData.length === 0) {
              var allDivs = document.querySelectorAll('div');
              allDivs.forEach(function(div) {
                if (div.innerText && div.innerText.length > 40 && div.innerText.length < 1000) {
                  collectedData.push({ text: div.innerText, imageUrl: "" });
                }
              });
            }

            return JSON.stringify(collectedData.slice(0, 5)); // أخذ أول 5 بوستات ظاهرة لتجنب الضغط
          })();
        ''');

        if (jsResult != null && jsResult != 'null') {
          try {
            final List<dynamic> rawList = jsonDecode(jsResult);
            for (var postObj in rawList) {
              final String cleanText = (postObj['text'] ?? '').toString().trim();
              final String imageUrl = (postObj['imageUrl'] ?? '').toString().trim();
              
              if (cleanText.length > 10 || imageUrl.isNotEmpty) {
                await _analyzeAndSavePost(cleanText, imageUrl, apiKey);
              }
            }
          } catch (_) {}
        }

        scheduleNextStep();
      });
    }

    scheduleNextStep();
  }

  Future<void> _analyzeAndSavePost(String postText, String imageUrl, String apiKey) async {
    try {
      Uint8List? imageBytes;
      String base64Image = '';

      if (imageUrl.isNotEmpty) {
        try {
          final imgResponse = await http.get(Uri.parse(imageUrl)).timeout(const Duration(seconds: 5));
          if (imgResponse.statusCode == 200 && imgResponse.bodyBytes.length > 2000) {
            imageBytes = imgResponse.bodyBytes;
            base64Image = base64Encode(imageBytes);
          }
        } catch (_) {}
      }

      final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
      final promptText = '''
أنت مهندس صيانة موبايلات خبير. حلل النص والصورة المرفقة:
النص: "$postText"

استخرج البيانات بصيغة JSON فقط بدون أي نص إضافي:
{
  "brand": "اسم الشركة مثل Samsung أو Xiaomi أو iPhone أو عام",
  "model": "موديل الهاتف أو غير محدد",
  "fault_category": "التصنيف (سوفت وير / فلاشة / FRP / هاردوير - باور / شحن / إضاءة / شبكة / صوت)",
  "symptoms": "وصف المشكلة باختصار",
  "solution": "تفاصيل الحل أو الشرح أو الخطوات",
  "ic_or_lines": "الآيسيهات أو الأدوات أو المسارات",
  "unique_solution_hash": "بصمة فريدة مختصرة للنص لمنع التكرار"
}
''';

      final List<Content> contents = [];
      if (imageBytes != null) {
        contents.add(Content.multi([TextPart(promptText), DataPart('image/jpeg', imageBytes)]));
      } else {
        contents.add(Content.text(promptText));
      }

      final response = await model.generateContent(contents);
      final reply = (response.text ?? '').trim();

      if (reply.isNotEmpty) {
        final jsonStr = reply.replaceAll('```json', '').replaceAll('```', '').trim();
        final Map<String, dynamic> data = jsonDecode(jsonStr);

        final String solutionHash = data['unique_solution_hash'] ?? data['solution'] ?? postText;
        if (_processedSignatures.contains(solutionHash)) return;
        _processedSignatures.add(solutionHash);

        await DatabaseHelper.instance.insertFault({
          'brand': data['brand'] ?? 'عام',
          'model': data['model'] ?? 'غير محدد',
          'fault_category': data['fault_category'] ?? 'صيانة عامة',
          'symptoms': data['symptoms'] ?? '',
          'solution': data['solution'] ?? '',
          'ic_or_lines': data['ic_or_lines'] ?? '',
          'image_base64': base64Image,
          'raw_post': postText,
          'solution_signature': solutionHash,
          'date_added': DateTime.now().toString().substring(0, 16),
        });

        if (mounted) {
          setState(() {
            _extractedCount++;
            _statusMessage = '✅ تم صيد عطل: ${data['brand']} ${data['model']}';
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
                      fontSize: 12,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRadarRunning ? Colors.redAccent : Colors.teal,
                  ),
                  onPressed: _toggleRadar,
                  icon: Icon(_isRadarRunning ? Icons.stop : Icons.play_arrow, color: Colors.white),
                  label: Text(
                    _isRadarRunning ? 'إيقاف الرادار' : 'تشغيل الرادار',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
              onWebViewCreated: (controller) => _webController = controller,
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('قاعدة البيانات فارغة!')));
        return;
      }
      final jsonString = jsonEncode(allFaults);
      final directory = await getTemporaryDirectory();
      final backupFile = File('${directory.path}/repair_faults_backup.json');
      await backupFile.writeAsString(jsonString);
      await Share.shareXFiles([XFile(backupFile.path)], text: 'نسخة احتياطية شاملة ($_totalSavedFaults عطل)');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  Future<void> _importDatabaseBackup() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 تم استرجاع ودمج $added عطل بنجاح!')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  @override
  Widget andBuild(BuildContext context) => build(context);

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
                title: const Text('إجمالي الأعطال والحلول المحفوظة', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('$_totalSavedFaults عطل مسجل بدون إنترنت'),
                trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: _loadSettingsAndStats),
              ),
            ),
            const SizedBox(height: 20),
            const Text('📦 النسخ الاحتياطي (Backup & Restore)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: _exportDatabaseBackup,
                    icon: const Icon(Icons.upload_file, color: Colors.white),
                    label: const Text('تصدير الموسوعة', style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade700, padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: _importDatabaseBackup,
                    icon: const Icon(Icons.download_for_offline, color: Colors.white),
                    label: const Text('استرجاع موسوعة', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
            const Divider(height: 40),
            const Text('🔑 مفتاح الذكاء الاصطناعي (Gemini API Key)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.tealAccent)),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'الصق مفتاح Gemini API...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade800, padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: _saveApiKey,
                child: const Text('حفظ المفتاح', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
