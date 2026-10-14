import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'brand_star.dart';

final GlobalKey<NavigatorState> notificationNavigatorKey =
    GlobalKey<NavigatorState>();

const baseUrl = 'https://www.amiidonk.hu';
const brandRed = Color(0xFFD20A12);
// Állítsd be a hírlevél tényleges feliratkozási URL-jét az élesítés előtt.
const newsletterUrl = '$baseUrl';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const NewsApp());
}

String plain(String markup) => html_parser.parse(markup).body?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

// WordPress lazy-loading images often keep the actual URL in data-src,
// data-lazy-src or srcset. Normalize them before displaying HTML.
String articleHtml(String markup) {
  final fragment = html_parser.parseFragment(markup);
  for (final img in fragment.querySelectorAll('img')) {
    String url = '';
    for (final key in ['data-src', 'data-lazy-src', 'data-original', 'data-orig-file', 'src']) {
      final value = (img.attributes[key] ?? '').trim();
      if (value.isNotEmpty && !value.startsWith('data:image/svg') &&
          !value.startsWith('data:image/gif;base64')) { url = value; break; }
    }
    if (url.isEmpty) {
      final srcset = img.attributes['data-srcset'] ?? img.attributes['srcset'] ?? '';
      if (srcset.isNotEmpty) url = srcset.split(',').first.trim().split(RegExp(r'\s+')).first;
    }
    if (url.isNotEmpty) {
      img.attributes['src'] = Uri.parse(baseUrl).resolve(url).toString();
      img.attributes.remove('srcset');
      img.attributes.remove('data-srcset');
    }
    img.attributes.remove('loading');
  }
  return fragment.outerHtml;
}

class NewsApi {
  static Future<List<dynamic>> posts({int? category, String search = ''}) async {
    final q = <String,String>{'per_page':'30','_embed':'1'};
    if (category != null) q['categories'] = '$category';
    if (search.trim().isNotEmpty) q['search'] = search.trim();
    final url = Uri.parse('$baseUrl/wp-json/wp/v2/posts').replace(queryParameters:q);
    final res = await http.get(url).timeout(const Duration(seconds:18));
    if (res.statusCode != 200) throw Exception('A hírek nem érhetők el (${res.statusCode}).');
    return jsonDecode(res.body) as List<dynamic>;
  }
  static Future<List<dynamic>> categories() async {
    final url = Uri.parse('$baseUrl/wp-json/wp/v2/categories?per_page=100&hide_empty=true');
    final res = await http.get(url).timeout(const Duration(seconds:18));
    if (res.statusCode != 200) throw Exception('Kategóriák: ${res.statusCode}');
    return jsonDecode(res.body) as List<dynamic>;
  }
}

String imageFor(dynamic post) {
  try {
    final media = post['_embedded']?['wp:featuredmedia'];
    if (media is List && media.isNotEmpty) {
      final url = (media.first['source_url'] ?? '').toString();
      if (url.isNotEmpty) return url;
    }
  } catch (_) {}
  try {
    final markup = (post['content']?['rendered'] ?? '').toString();
    final fragment = html_parser.parseFragment(markup);
    for (final img in fragment.querySelectorAll('img')) {
      for (final attr in ['data-src', 'data-lazy-src', 'data-original', 'data-orig-file', 'src']) {
        final value = (img.attributes[attr] ?? '').trim();
        if (value.isNotEmpty && !value.startsWith('data:') && !value.startsWith('blob:')) {
          return Uri.parse(baseUrl).resolve(value).toString();
        }
      }
      final srcset = img.attributes['data-srcset'] ?? img.attributes['srcset'] ?? '';
      if (srcset.isNotEmpty) {
        final first = srcset.split(',').first.trim().split(RegExp(r'\s+')).first;
        if (first.isNotEmpty) return Uri.parse(baseUrl).resolve(first).toString();
      }
    }
  } catch (_) {}
  return '';
}
Future<void> openNotificationArticle(RemoteMessage message) async {
  final postId = message.data['post_id'];
  if (postId == null || !RegExp(r'^\d+$').hasMatch(postId)) return;

  try {
    final response = await http.get(
      Uri.parse('$baseUrl/wp-json/wp/v2/posts/$postId'),
    ).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) {
      debugPrint('A cikk nem tölthető be: ${response.statusCode}');
      return;
    }
    final post = jsonDecode(response.body);
    final navigator = notificationNavigatorKey.currentState;
    if (navigator == null) return;
    navigator.push(MaterialPageRoute(builder: (_) => ArticlePage(post: post)));
  } catch (error) {
    debugPrint('Hiba az értesítés megnyitásakor: $error');
  }
}

// A nyilvános GitHub Releases legújabb kiadásának ellenőrzése.
const githubLatestReleaseApi =
    'https://api.github.com/repos/demanufacture13/a-mi-idonk-app/releases/latest';

List<int>? _versionParts(String version) {
  final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:[+\-].*)?$')
      .firstMatch(version.trim());
  if (match == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}

bool _isNewerVersion(String available, String installed) {
  final a = _versionParts(available);
  final b = _versionParts(installed);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

class NewsApp extends StatefulWidget {
  const NewsApp({super.key});
  @override State<NewsApp> createState() => _NewsAppState();
}
class _NewsAppState extends State<NewsApp> {
  ThemeMode mode = ThemeMode.system;
  bool notificationsEnabled = false;
  bool notificationsBusy = true;
  bool notificationsAllowed = true;
  StreamSubscription<RemoteMessage>? notificationTapSubscription;
  List<dynamic> notificationCategories = [];
  Set<int> mutedCategoryIds = {};
  bool categoriesLoaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadNotificationCategories();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeNotifications();
      _checkForUpdates();
    });
  }

  Future<void> _downloadAndInstallUpdate(String url) async {
    final navigatorContext = notificationNavigatorKey.currentContext;
    if (navigatorContext == null || !navigatorContext.mounted) return;
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>('Kapcsolódás a letöltéshez…');
    var dialogOpen = true;
    showDialog<void>(
      context: navigatorContext,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Frissítés letöltése'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, text, __) => Text(text),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (_, value, __) => LinearProgressIndicator(value: value),
              ),
            ],
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);

    final client = http.Client();
    File? apkFile;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('Letöltési hiba: HTTP ${response.statusCode}');
      }
      final length = response.contentLength;
      final directory = await getTemporaryDirectory();
      apkFile = File('${directory.path}/A_MI_IDONK_frissites.apk');
      final sink = apkFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(const Duration(seconds: 45))) {
          sink.add(chunk);
          received += chunk.length;
          if (length != null && length > 0) {
            progress.value = (received / length).clamp(0.0, 1.0);
            status.value = 'Letöltés: ${(100 * received / length).clamp(0, 100).toStringAsFixed(0)}%';
          } else {
            status.value = 'Letöltve: ${(received / 1048576).toStringAsFixed(1)} MB';
          }
        }
      } finally {
        await sink.close();
      }
      if (received < 1024 * 100 || (length != null && received != length)) {
        throw Exception('A letöltött fájl hiányos.');
      }
      final header = await apkFile.openRead(0, 4).first;
      if (header.length < 4 || header[0] != 0x50 || header[1] != 0x4b) {
        throw Exception('A letöltött fájl nem APK.');
      }
      status.value = 'Android telepítő indítása…';
      if (dialogOpen && navigatorContext.mounted) {
        Navigator.of(navigatorContext, rootNavigator: true).pop();
        dialogOpen = false;
      }
      final result = await OpenFilex.open(
        apkFile.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw Exception(result.message);
      }
    } catch (error) {
      debugPrint('Frissítés letöltése / telepítése: $error');
      if (dialogOpen && navigatorContext.mounted) {
        Navigator.of(navigatorContext, rootNavigator: true).pop();
        dialogOpen = false;
      }
      if (navigatorContext.mounted) {
        ScaffoldMessenger.of(navigatorContext).showSnackBar(
          SnackBar(content: Text('Nem sikerült elindítani a frissítést: $error')),
        );
      }
    } finally {
      client.close();
      // Az APK-t megtartjuk az Android telepítő számára.
    }
  }

  Future<void> _checkForUpdates() async {
    try {
      final package = await PackageInfo.fromPlatform();
      final response = await http.get(
        Uri.parse(githubLatestReleaseApi),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 || !mounted) return;
      final release = jsonDecode(response.body) as Map<String, dynamic>;
      final latest = (release['tag_name'] ?? '').toString();
      if (!_isNewerVersion(latest, package.version)) return;

      String? apkUrl;
      final assets = release['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is Map && (asset['name'] ?? '').toString() == 'A_MI_IDONK.apk') {
            apkUrl = asset['browser_download_url']?.toString();
            break;
          }
        }
      }
      // Csak a konkrét kiadási APK-t töltjük le; weboldalt soha.
      if (apkUrl == null ||
          Uri.tryParse(apkUrl)?.scheme != 'https' ||
          Uri.tryParse(apkUrl)?.host != 'github.com' || !mounted) return;
      final dialogContext = notificationNavigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      await showDialog<void>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('Új frissítés érhető el'),
          content: Text('Elérhető az A MI IDŐNK $latest verziója. '
              'A telepített verzió: ${package.version}. '
              'Szeretnéd letölteni és telepíteni a frissítést?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Később'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                _downloadAndInstallUpdate(apkUrl!);
              },
              child: const Text('Frissítés'),
            ),
          ],
        ),
      );
    } catch (error) {
      debugPrint('Frissítésellenőrzés nem sikerült: $error');
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final savedMode = p.getInt('theme') ?? 0;
    if (mounted) {
      setState(() => mode = savedMode >= 0 && savedMode < ThemeMode.values.length
          ? ThemeMode.values[savedMode] : ThemeMode.system);
    }
  }

  String _categoryTopic(int id) => 'kategoria_$id';

  Future<void> _loadNotificationCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final muted = (prefs.getStringList('muted_categories') ?? [])
          .map(int.tryParse).whereType<int>().toSet();
      final items = await NewsApi.categories();
      if (!mounted) return;
      setState(() { notificationCategories = items; mutedCategoryIds = muted; categoriesLoaded = true; });
      await _syncCategoryTopics();
    } catch (error) {
      debugPrint('Értesítési kategóriák: $error');
    }
  }

  Future<void> _syncCategoryTopics() async {
    if (!notificationsEnabled) return;
    for (final category in notificationCategories) {
      final id = category['id'] as int;
      if (mutedCategoryIds.contains(id)) {
        await FirebaseMessaging.instance.unsubscribeFromTopic(_categoryTopic(id));
      } else {
        await FirebaseMessaging.instance.subscribeToTopic(_categoryTopic(id));
      }
    }
    // A régi közös témát leváltjuk, különben dupla értesítések érkeznének.
    await FirebaseMessaging.instance.unsubscribeFromTopic('uj_cikkek');
  }

  Future<void> setCategoryNotifications(int id, bool enabled) async {
    final previous = Set<int>.from(mutedCategoryIds);
    setState(() {
      if (enabled) { mutedCategoryIds.remove(id); } else { mutedCategoryIds.add(id); }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('muted_categories', mutedCategoryIds.map((e) => '$e').toList());
      if (notificationsEnabled) {
        if (enabled) {
          await FirebaseMessaging.instance.subscribeToTopic(_categoryTopic(id));
        } else {
          await FirebaseMessaging.instance.unsubscribeFromTopic(_categoryTopic(id));
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => mutedCategoryIds = previous);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Értesítési hiba: $error')));
      }
    }
  }

  Future<void> _initializeNotifications() async {
    notificationTapSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) { openNotificationArticle(message); },
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      // Meglévő felhasználóknál alapértelmezésben bekapcsolva marad.
      final enabled = prefs.getBool('push_enabled') ?? true;
      if (enabled) {
        await _subscribeToNotifications();
      } else {
        await FirebaseMessaging.instance.unsubscribeFromTopic('uj_cikkek');
      }
      if (mounted) setState(() { notificationsEnabled = enabled; notificationsBusy = false; });
      if (enabled && categoriesLoaded) await _syncCategoryTopics();
    } catch (error) {
      debugPrint('Értesítések indítási hibája: $error');
      if (mounted) setState(() { notificationsBusy = false; notificationsEnabled = false; });
    }

    // Ha az alkalmazás értesítésre koppintással indult, a főoldal
    // felépülése után nyitjuk meg a cikket.
    try {
      final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) openNotificationArticle(initialMessage);
        });
      }
    } catch (error) {
      debugPrint('Indító értesítés hibája: $error');
    }
  }

  Future<void> _subscribeToNotifications() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true, badge: true, sound: true,
    );
    final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    if (!allowed) {
      if (mounted) setState(() => notificationsAllowed = false);
      throw StateError('A rendszerben nincs engedélyezve az értesítés.');
    }
    if (mounted) setState(() => notificationsAllowed = true);
    if (categoriesLoaded) {
      for (final c in notificationCategories) {
        final id = c['id'] as int;
        if (!mutedCategoryIds.contains(id)) {
          await FirebaseMessaging.instance.subscribeToTopic(_categoryTopic(id));
        }
      }
      await FirebaseMessaging.instance.unsubscribeFromTopic('uj_cikkek');
    } else {
      await FirebaseMessaging.instance.subscribeToTopic('uj_cikkek');
    }
  }

  Future<void> setNotifications(bool enabled) async {
    if (notificationsBusy) return;
    setState(() => notificationsBusy = true);
    try {
      if (enabled) {
        await _subscribeToNotifications();
      } else {
        await FirebaseMessaging.instance.unsubscribeFromTopic('uj_cikkek');
        for (final c in notificationCategories) {
          await FirebaseMessaging.instance.unsubscribeFromTopic(_categoryTopic(c['id'] as int));
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('push_enabled', enabled);
      if (mounted) setState(() => notificationsEnabled = enabled);
    } catch (error) {
      debugPrint('Értesítési beállítás hibája: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Nem sikerült módosítani az értesítéseket: $error'),
        ));
      }
    } finally {
      if (mounted) setState(() => notificationsBusy = false);
    }
  }

  Future<void> setMode(ThemeMode value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('theme', value.index);
    if (mounted) setState(() => mode = value);
  }

  @override
  void dispose() {
    notificationTapSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: notificationNavigatorKey,
    title: 'A MI IDŐNK',
    debugShowCheckedModeBanner: false,
    themeMode: mode,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: brandRed,
        brightness: Brightness.light,
        appBarTheme: const AppBarTheme(backgroundColor: brandRed, foregroundColor: Colors.white)),
    darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: brandRed,
        brightness: Brightness.dark),
    home: HomePage(
      mode: mode,
      onMode: setMode,
      notificationsEnabled: notificationsEnabled,
      notificationsBusy: notificationsBusy,
      notificationsAllowed: notificationsAllowed,
      onNotificationsChanged: setNotifications,
      notificationCategories: notificationCategories,
      mutedCategoryIds: mutedCategoryIds,
      categoriesLoaded: categoriesLoaded,
      onCategoryNotificationsChanged: setCategoryNotifications,
    ),
  );
}

class HomePage extends StatefulWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  final bool notificationsEnabled;
  final bool notificationsBusy;
  final bool notificationsAllowed;
  final ValueChanged<bool> onNotificationsChanged;
  final List<dynamic> notificationCategories;
  final Set<int> mutedCategoryIds;
  final bool categoriesLoaded;
  final void Function(int, bool) onCategoryNotificationsChanged;
  const HomePage({super.key, required this.mode, required this.onMode,
    required this.notificationsEnabled, required this.notificationsBusy,
    required this.notificationsAllowed, required this.onNotificationsChanged,
    required this.notificationCategories, required this.mutedCategoryIds,
    required this.categoriesLoaded, required this.onCategoryNotificationsChanged});
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  int tab = 0;
  int? category;
  String search = '';
  late Future<List<dynamic>> posts;
  late Future<List<dynamic>> categories;
  @override void initState() { super.initState(); reload(); categories=NewsApi.categories(); }
  void reload() => posts=NewsApi.posts(category:category,search:search);
  @override Widget build(BuildContext context) => Scaffold(
    appBar:AppBar(title:const Row(mainAxisSize:MainAxisSize.min,children:[BrandStar(size:32),SizedBox(width:8),Flexible(child:Text('A MI IDŐNK',style:TextStyle(fontWeight:FontWeight.w900),overflow:TextOverflow.ellipsis))]),actions:[IconButton(icon:const Icon(Icons.search),onPressed:()=>showSearch(context:context,delegate:NewsSearchDelegate()))]),
    body: tab == 0 ? _news() : tab == 1 ? _categories() : tab == 2 ? const SavedPage() : _settings(),
    bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const [
      NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'Hírek'),
      NavigationDestination(icon:Icon(Icons.category_outlined),label:'Kategóriák'),
      NavigationDestination(icon:Icon(Icons.bookmark_outline),label:'Kedvencek'),
      NavigationDestination(icon:Icon(Icons.settings_outlined),label:'Beállítások'),
    ]),
  );
  Widget _news() => RefreshIndicator(onRefresh:() async { setState(reload); await posts; },child:FutureBuilder<List<dynamic>>(future:posts,builder:(context,snapshot){
    if (!snapshot.hasData) { if(snapshot.hasError) return ListView(children:[const SizedBox(height:80),const Icon(Icons.wifi_off,size:44),Center(child:Padding(padding:const EdgeInsets.all(16),child:Text('${snapshot.error}',textAlign:TextAlign.center))),TextButton(onPressed:()=>setState(reload),child:const Text('Újrapróbálás'))]); return const Center(child:CircularProgressIndicator()); }
    final items=snapshot.data!;
    if(items.isEmpty) return ListView(children:const [SizedBox(height:90),Center(child:Text('Nincs találat.'))]);
    return ListView.builder(itemCount:items.length,itemBuilder:(context,i)=>
      i == 0 && category == null && search.isEmpty
        ? FeaturedNewsTile(post: items[i], posts: items, index: i)
        : NewsTile(post:items[i], posts:items, index:i));
  }));
  Widget _categories() => FutureBuilder<List<dynamic>>(future:categories,builder:(context,s){
    if(s.hasError) return Center(child:Text('Nem sikerült betölteni a kategóriákat: ${s.error}'));
    if(!s.hasData) return const Center(child:CircularProgressIndicator());
    return ListView(children:[ListTile(title:const Text('Összes hír'),onTap:()=>setState((){category=null;search='';reload();tab=0;})),...s.data!.map((c)=>ListTile(title:Text(plain(c['name'] ?? '')),trailing:const Icon(Icons.chevron_right),onTap:()=>setState((){category=c['id'] as int;search='';reload();tab=0;})))]);
  });
  Widget _settings() => ListView(children:[
    const ListTile(title:Text('Megjelenés',style:TextStyle(fontWeight:FontWeight.bold))),
    RadioListTile<ThemeMode>(title:const Text('Rendszer szerint'),value:ThemeMode.system,groupValue:widget.mode,onChanged:(v)=>widget.onMode(v!)),
    RadioListTile<ThemeMode>(title:const Text('Világos'),value:ThemeMode.light,groupValue:widget.mode,onChanged:(v)=>widget.onMode(v!)),
    RadioListTile<ThemeMode>(title:const Text('Sötét'),value:ThemeMode.dark,groupValue:widget.mode,onChanged:(v)=>widget.onMode(v!)),
    const Divider(),
    const ListTile(title: Text('Cikkek betűmérete', style: TextStyle(fontWeight: FontWeight.bold))),
    const ArticleFontSizeSetting(),
    const Divider(),ListTile(leading:const Icon(Icons.mail_outline),title:const Text('Hírlevél-feliratkozás'),subtitle:const Text('Feliratkozás a weboldalon'),onTap:()=>launchUrl(Uri.parse(newsletterUrl),mode:LaunchMode.externalApplication)),
    SwitchListTile(
      secondary: const Icon(Icons.notifications_outlined),
      title: const Text('Új cikkek értesítései'),
      subtitle: Text(widget.notificationsBusy
          ? 'Beállítás folyamatban…'
          : !widget.notificationsAllowed && !widget.notificationsEnabled
              ? 'Engedélyezd az értesítéseket a készülék beállításaiban.'
              : widget.notificationsEnabled ? 'Bekapcsolva' : 'Kikapcsolva'),
      value: widget.notificationsEnabled,
      onChanged: widget.notificationsBusy ? null : widget.onNotificationsChanged,
    ),
    const ListTile(title: Text('Értesítések témakörönként', style: TextStyle(fontWeight: FontWeight.bold))),
    if (!widget.categoriesLoaded) const ListTile(title: Text('Kategóriák betöltése…'))
    else ...widget.notificationCategories.map((c) {
      final id = c['id'] as int;
      return SwitchListTile(
        title: Text(plain((c['name'] ?? '').toString())),
        value: !widget.mutedCategoryIds.contains(id),
        onChanged: widget.notificationsEnabled && !widget.notificationsBusy
          ? (v) => widget.onCategoryNotificationsChanged(id, v) : null,
      );
    }),
    const AboutListTile(applicationName:'A MI IDŐNK',applicationVersion:'1.0.7'),
  ]);
}

class ArticleFontSizeSetting extends StatefulWidget {
  const ArticleFontSizeSetting({super.key});
  @override State<ArticleFontSizeSetting> createState() => _ArticleFontSizeSettingState();
}
class _ArticleFontSizeSettingState extends State<ArticleFontSizeSetting> {
  int size = 18;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => size = prefs.getInt('article_font_size') ?? 18);
  }
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 18, label: Text('Normál')),
        ButtonSegment(value: 22, label: Text('Nagy')),
        ButtonSegment(value: 26, label: Text('Extra nagy')),
      ],
      selected: {size},
      onSelectionChanged: (values) async {
        final next = values.first;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('article_font_size', next);
        if (mounted) setState(() => size = next);
      },
    ),
  );
}

class UnreadMarker extends StatefulWidget {
  final String postId;
  const UnreadMarker({super.key, required this.postId});
  @override State<UnreadMarker> createState() => _UnreadMarkerState();
}
class _UnreadMarkerState extends State<UnreadMarker> {
  bool unread = false;
  @override void initState() { super.initState(); _check(); }
  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => unread = !(prefs.getStringList('read_articles') ?? []).contains(widget.postId));
  }
  @override Widget build(BuildContext context) => unread
    ? const Padding(padding: EdgeInsets.only(bottom: 5), child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.fiber_manual_record, size: 11, color: brandRed),
        SizedBox(width: 4), Text('Még nem olvastad', style: TextStyle(fontSize: 12, color: brandRed)),
      ])) : const SizedBox.shrink();
}

class FeaturedNewsTile extends StatelessWidget {
  final dynamic post;
  final List<dynamic> posts;
  final int index;
  const FeaturedNewsTile({super.key, required this.post, required this.posts, required this.index});
  @override Widget build(BuildContext context) {
    final image = imageFor(post);
    return Card(
      margin: const EdgeInsets.fromLTRB(10, 12, 10, 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => ArticlePage(post: post, posts: posts, index: index))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (image.isNotEmpty) Image.network(image, width: double.infinity, height: 220,
            fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('VEZETŐ HÍR', style: TextStyle(color: brandRed, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              UnreadMarker(postId: '${post['id']}'),
              Text(plain((post['title']?['rendered'] ?? '').toString()),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(plain((post['excerpt']?['rendered'] ?? '').toString()), maxLines: 3,
                overflow: TextOverflow.ellipsis),
            ],
          )),
        ]),
      ),
    );
  }
}

class NewsTile extends StatelessWidget {
  final dynamic post;
  final List<dynamic>? posts;
  final int? index;
  const NewsTile({super.key,required this.post,this.posts,this.index});
  @override Widget build(BuildContext context) {
    final image=imageFor(post);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ArticlePage(post: post, posts: posts, index: index))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (image.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(image, width: 100, height: 100, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(width: 100, height: 100, child: Icon(Icons.article_outlined))),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              UnreadMarker(postId: '${post['id']}'),
              Text(plain(post['title']['rendered'] ?? ''),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(plain(post['excerpt']['rendered'] ?? ''), maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Text((post['date'] ?? '').toString().replaceAll('T', '  '), style: Theme.of(context).textTheme.bodySmall),
            ])),
          ]),
        ),
      ),
    );
  }
}

class ArticlePage extends StatefulWidget {
  final dynamic post;
  final List<dynamic>? posts;
  final int? index;
  const ArticlePage({super.key,required this.post,this.posts,this.index});
  @override State<ArticlePage> createState()=>_ArticlePageState();
}
class _ArticlePageState extends State<ArticlePage> {
  final tts=FlutterTts();
  bool speaking=false, saved=false;
  int fontSize = 18;
  late final WebViewController controller;
  String get id => '${widget.post['id']}';
  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled);
    _load();
    tts.setLanguage('hu-HU');
    tts.setSpeechRate(0.48);
    tts.setCompletionHandler(() {
      if (mounted) setState(() => speaking = false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _renderArticleHtml();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final seen = p.getStringList('read_articles') ?? [];
    if (!seen.contains(id)) {
      seen.add(id);
      if (seen.length > 1500) seen.removeRange(0, seen.length - 1500);
      await p.setStringList('read_articles', seen);
    }
    if (mounted) {
      setState(() {
        saved = (p.getStringList('saved') ?? []).contains(id);
        fontSize = p.getInt('article_font_size') ?? 18;
      });
      _renderArticleHtml();
    }
  }
  void _navigateArticle(int direction) {
    final list = widget.posts;
    final index = widget.index;
    if (list == null || index == null) return;
    final next = index + direction;
    if (next < 0 || next >= list.length) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ArticlePage(post: list[next], posts: list, index: next)));
  }

  Future<void> _toggleSaved() async {final p=await SharedPreferences.getInstance();final ids=p.getStringList('saved')??[];if(ids.contains(id)){ids.remove(id);}else{ids.add(id);await p.setString('article_$id',jsonEncode(widget.post));}await p.setStringList('saved',ids);setState(()=>saved=ids.contains(id));}
  Future<void> _toggleTts() async {if(speaking){await tts.stop();setState(()=>speaking=false);}else{setState(()=>speaking=true);await tts.speak('${plain(widget.post['title']['rendered'] ?? '')}. ${plain(widget.post['content']['rendered'] ?? '')}');}}
  @override void dispose(){tts.stop();super.dispose();}
  void _renderArticleHtml() {
    final content = articleHtml((widget.post['content']?['rendered'] ?? '').toString());
    final title = plain((widget.post['title']?['rendered'] ?? '').toString());
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? '#121212' : '#ffffff';
    final foreground = isDark ? '#eeeeee' : '#222222';
    final page = '''<!doctype html><html lang="hu"><head><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>
      body {background: BG; color: FG; font-family: sans-serif; font-size: ${fontSize}px; line-height: 1.65; margin: 18px; overflow-wrap: break-word;}
      img, video, iframe {max-width: 100%; height: auto;} img {display: block; margin-left: auto !important; margin-right: auto !important;} figure, .wp-block-image {max-width: 100%; margin: 16px auto !important; text-align: center !important;} figure img, .wp-block-image img {margin-left: auto !important; margin-right: auto !important;}
      p {margin: 0 0 1.1em;} h1,h2,h3,h4 {line-height: 1.3; margin-top: 1.4em;}
      a {color: #d20a12;} blockquote {border-left: 4px solid #d20a12; padding-left: 12px; margin-left: 0;}
      figcaption {font-size: 0.85em; opacity: 0.75;} table {max-width: 100%; display: block; overflow-x: auto;}
    </style></head><body><h1>TITLE</h1>CONTENT</body></html>'''
        .replaceAll('BG', background)
        .replaceAll('FG', foreground)
        .replaceAll('TITLE', const HtmlEscape().convert(title))
        .replaceAll('CONTENT', content);
    controller.setBackgroundColor(Theme.of(context).scaffoldBackgroundColor);
    controller.loadHtmlString(page, baseUrl: '$baseUrl/');
  }

  @override
  Widget build(BuildContext context) {
    final title = plain((widget.post['title']?['rendered'] ?? '').toString());
    return Scaffold(
      appBar: AppBar(
        title: const Text('A MI IDŐNK'),
        actions: [
          IconButton(tooltip: 'Cikk megosztása', icon: const Icon(Icons.share_outlined),
            onPressed: () => Share.share((widget.post['link'] ?? baseUrl).toString(), subject: title)),
          IconButton(icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border), onPressed: _toggleSaved),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Expanded(child: FilledButton.icon(
              onPressed: _toggleTts,
              icon: Icon(speaking ? Icons.stop : Icons.volume_up),
              label: Text(speaking ? 'Felolvasás leállítása' : 'Cikk felolvasása'),
            )),
            IconButton(
              tooltip: 'Eredeti cikk megnyitása',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => launchUrl(Uri.parse((widget.post['link'] ?? baseUrl).toString()), mode: LaunchMode.externalApplication),
            ),
          ]),
        ),
        Expanded(child: WebViewWidget(controller: controller)),
        if (widget.posts != null && widget.index != null)
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            TextButton.icon(onPressed: widget.index! > 0 ? () => _navigateArticle(-1) : null,
              icon: const Icon(Icons.chevron_left), label: const Text('Előző')),
            Text('${widget.index! + 1} / ${widget.posts!.length}'),
            TextButton.icon(onPressed: widget.index! < widget.posts!.length - 1 ? () => _navigateArticle(1) : null,
              icon: const Icon(Icons.chevron_right), label: const Text('Következő')),
          ]),
      ]),
    );
  }
}

class SavedPage extends StatefulWidget {const SavedPage({super.key});@override State<SavedPage> createState()=>_SavedPageState();}
class _SavedPageState extends State<SavedPage> {
  Future<List<dynamic>> load() async {final p=await SharedPreferences.getInstance();return (p.getStringList('saved')??[]).map((id)=>p.getString('article_$id')).whereType<String>().map((s)=>jsonDecode(s)).toList();}
  @override Widget build(BuildContext context)=>FutureBuilder<List<dynamic>>(future:load(),builder:(context,s){if(!s.hasData)return const Center(child:CircularProgressIndicator());if(s.data!.isEmpty)return const Center(child:Text('Még nincs mentett cikk.'));return ListView(children:s.data!.map((p)=>NewsTile(post:p)).toList());});
}
class NewsSearchDelegate extends SearchDelegate<String> {
  @override String get searchFieldLabel=>'Keresés a hírek között';
  @override List<Widget> buildActions(BuildContext context)=>[IconButton(icon:const Icon(Icons.clear),onPressed:()=>query='')];
  @override Widget buildLeading(BuildContext context)=>IconButton(icon:const Icon(Icons.arrow_back),onPressed:()=>close(context,''));
  @override Widget buildResults(BuildContext context)=>FutureBuilder<List<dynamic>>(future:NewsApi.posts(search:query),builder:(context,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());return ListView(children:s.data!.map((p)=>NewsTile(post:p)).toList());});
  @override Widget buildSuggestions(BuildContext context)=>Center(child:Text(query.isEmpty?'Írj be egy keresőkifejezést.':'Nyomd meg a keresés gombot.'));
}
