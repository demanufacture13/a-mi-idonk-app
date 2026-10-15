import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter/services.dart';
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
const facebookPageUrl = 'https://www.facebook.com/amiidonk';
const articleShareActionUrl = 'https://www.amiidonk.hu/?ami_app_share=1';
const brandRed = Color(0xFFD20A12);
// Állítsd be a hírlevél tényleges feliratkozási URL-jét az élesítés előtt.
const newsletterUrl = '$baseUrl';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  if (Platform.isAndroid) await configureListeningService();
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
          if (asset is Map && (asset['name'] ?? '').toString() == 'app-release.apk') {
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
    body: tab == 0 ? _news() : tab == 1 ? _categories() : tab == 2 ? const SavedPage() : tab == 3 ? const ListeningPage() : _settings(),
    bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const [
      NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'Hírek'),
      NavigationDestination(icon:Icon(Icons.category_outlined),label:'Kategóriák'),
      NavigationDestination(icon:Icon(Icons.bookmark_outline),label:'Kedvencek'),
      NavigationDestination(icon:Icon(Icons.headphones_outlined),selectedIcon:Icon(Icons.headphones),label:'Hallgatás'),
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
    ListTile(leading: const Icon(Icons.facebook), title: const Text('Facebook-oldalunk'), subtitle: const Text('A MI IDŐNK a Facebookon'), trailing: const Icon(Icons.open_in_new), onTap: () => launchUrl(Uri.parse(facebookPageUrl), mode: LaunchMode.externalApplication)),
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
    const AboutListTile(applicationName:'A MI IDŐNK',applicationVersion:'1.0.12'),
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


// Hírek hallgatása: a cikkeket a WordPress nyilvános REST API-jából tölti.
// A háttérben történő, képernyőzár melletti lejátszáshoz később Android
// foreground media service és médiavezérlő integráció szükséges.
// A Hallgatás TTS-folyamata Android foreground service-ben fut.
// A háttér-isolate önállóan léptet a szakaszok és cikkek között.
@pragma('vm:entry-point')
void listeningServiceEntry(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final tts = FlutterTts();
  List<dynamic> queue = [];
  List<String> segments = [];
  int article = 0, segment = 0, generation = 0;
  double rate = 0.48;
  bool playing = false;
  await tts.setLanguage('hu-HU');

  List<String> splitText(dynamic item) {
    final text = '${plain((item['title']?['rendered'] ?? '').toString())}. '
        '${plain((item['content']?['rendered'] ?? '').toString())}';
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final result = <String>[];
    var buffer = '';
    for (final sentence in sentences) {
      if (buffer.isNotEmpty && buffer.length + sentence.length > 220) {
        result.add(buffer.trim()); buffer = '';
      }
      if (sentence.length > 220) {
        if (buffer.isNotEmpty) { result.add(buffer.trim()); buffer = ''; }
        for (var i = 0; i < sentence.length; i += 220) {
          result.add(sentence.substring(i, i + 220 > sentence.length ? sentence.length : i + 220));
        }
      } else { buffer += '$sentence '; }
    }
    if (buffer.trim().isNotEmpty) result.add(buffer.trim());
    return result;
  }

  void publish() {
    service.invoke('listen_state', {
      'article': article, 'segment': segment,
      'playing': playing, 'count': segments.length,
      'finishedId': null,
    });
    if (service is AndroidServiceInstance) {
      final title = queue.isNotEmpty && article < queue.length
          ? plain('${queue[article]['title']?['rendered'] ?? ''}') : 'A MI IDŐNK';
      service.setForegroundNotificationInfo(
        title: 'A MI IDŐNK – Hallgatás',
        content: playing ? title : 'Felolvasás szüneteltetve',
      );
    }
  }

  Future<void> speak() async {
    if (!playing || segment >= segments.length) return;
    final token = generation;
    await tts.setSpeechRate(rate);
    if (token != generation || !playing) return;
    await tts.speak(segments[segment]);
  }

  tts.setCompletionHandler(() async {
    if (!playing) return;
    if (segment + 1 < segments.length) {
      segment++;
    } else {
      if (queue.isNotEmpty && article < queue.length) {
        service.invoke('listen_heard', {'id': '${queue[article]['id']}'});
      }
      article++;
      segment = 0;
      if (article >= queue.length) {
        playing = false;
        publish();
        return;
      }
      segments = splitText(queue[article]);
    }
    publish();
    await speak();
  });
  tts.setErrorHandler((_) { playing = false; publish(); });

  service.on('listen_start').listen((data) async {
    generation++;
    playing = false;
    await tts.stop();
    if (data == null) return;
    queue = (data['queue'] as List?) ?? [];
    article = (data['article'] as num?)?.toInt() ?? 0;
    segment = (data['segment'] as num?)?.toInt() ?? 0;
    rate = (data['rate'] as num?)?.toDouble() ?? 0.48;
    if (queue.isEmpty || article < 0 || article >= queue.length) return;
    segments = splitText(queue[article]);
    playing = true;
    publish();
    await speak();
  });
  service.on('listen_pause').listen((_) async {
    generation++;
    playing = false;
    await tts.stop();
    publish();
  });
  service.on('listen_resume').listen((_) async {
    if (queue.isEmpty || article >= queue.length) return;
    if (segment >= segments.length) segment = 0;
    playing = true;
    publish();
    await speak();
  });
  service.on('listen_seek').listen((data) async {
    generation++;
    final resume = playing;
    playing = false;
    await tts.stop();
    if (data != null) {
      article = ((data['article'] as num?)?.toInt() ?? article).clamp(0, queue.isEmpty ? 0 : queue.length - 1);
      if (queue.isNotEmpty) segments = splitText(queue[article]);
      segment = ((data['segment'] as num?)?.toInt() ?? 0).clamp(0, segments.isEmpty ? 0 : segments.length - 1);
    }
    playing = resume;
    publish();
    if (playing) await speak();
  });
  service.on('listen_rate').listen((data) async {
    generation++;
    final resume = playing;
    playing = false;
    await tts.stop();
    rate = (data?['rate'] as num?)?.toDouble() ?? rate;
    playing = resume;
    publish();
    if (playing) await speak();
  });
  service.on('listen_stop').listen((_) async {
    generation++;
    playing = false;
    await tts.stop();
    queue = []; segments = []; article = 0; segment = 0;
    publish();
    service.stopSelf();
  });
  publish();
}

Future<void> configureListeningService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: listeningServiceEntry,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'amiidonk_listening',
      initialNotificationTitle: 'A MI IDŐNK – Hallgatás',
      initialNotificationContent: 'A felolvasás előkészítése',
      foregroundServiceNotificationId: 1414,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

class ListeningPage extends StatefulWidget {
  const ListeningPage({super.key});
  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage> {
  final FlutterTts _tts = FlutterTts();
  List<dynamic> _categories = [];
  List<dynamic> _articles = [];
  List<dynamic> _queue = [];
  final List<dynamic> _archiveQueue = [];
  final TextEditingController _archiveSearch = TextEditingController();
  List<dynamic> _archiveResults = [];
  bool _archiveLoading = false;
  bool _archiveSearched = false;
  bool _archiveHasMore = false;
  String? _archiveError;
  int _archivePage = 0;
  int? _archiveYear;
  Set<int> _selected = {};
  bool _loading = true, _playing = false, _paused = false;
  bool _shuffle = false, _skipHeard = false;
  int _limit = 10, _articleIndex = 0, _segmentIndex = 0;
  double _rate = 0.48;
  List<String> _segments = [];
  String? _error;
  int _playbackGeneration = 0;
  StreamSubscription<Map<String, dynamic>?>? _backgroundState;
  StreamSubscription<Map<String, dynamic>?>? _backgroundHeard;
  bool get _androidBackground => Platform.isAndroid;
  final FlutterBackgroundService _background = FlutterBackgroundService();

  Future<void> _sendBackgroundStart() async {
    if (!await _background.isRunning()) await _background.startService();
    // A szolgáltatás elindulása aszinkron; a konfiguráció után rövid idő kellhet.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    _background.invoke('listen_start', {
      'queue': _queue, 'article': _articleIndex,
      'segment': _segmentIndex, 'rate': _rate,
    });
  }


  @override
  void initState() {
    super.initState();
    if (_androidBackground) {
      _backgroundState = _background.on('listen_state').listen((data) {
        if (!mounted || data == null) return;
        final index = (data['article'] as num?)?.toInt() ?? _articleIndex;
        if (index < 0 || index >= _queue.length) return;
        setState(() {
          _articleIndex = index;
          _segmentIndex = (data['segment'] as num?)?.toInt() ?? _segmentIndex;
          _playing = data['playing'] == true;
          _paused = !_playing;
        });
        _prepareSegments();
      });
      _backgroundHeard = _background.on('listen_heard').listen((data) async {
        if (data == null) return;
        final id = '${data['id']}';
        final prefs = await SharedPreferences.getInstance();
        final heard = prefs.getStringList('listened_articles') ?? [];
        if (!heard.contains(id)) heard.add(id);
        if (heard.length > 1000) heard.removeRange(0, heard.length - 1000);
        await prefs.setStringList('listened_articles', heard);
      });
    }
    _tts.setLanguage('hu-HU');
    _tts.setSpeechRate(_rate);
    _tts.setCompletionHandler(_onSegmentComplete);
    _tts.setErrorHandler((message) {
      if (mounted) setState(() { _playing = false; _paused = true; });
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cats = await NewsApi.categories();
      final uri = Uri.parse('$baseUrl/wp-json/wp/v2/posts').replace(
        queryParameters: {'per_page':'100', '_embed':'1'});
      final response = await http.get(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      final articles = jsonDecode(response.body) as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _categories = cats;
        _articles = articles;
        _selected = (prefs.getStringList('listen_categories') ?? [])
            .map(int.tryParse).whereType<int>().toSet();
        _selected.removeWhere((id) => !cats.any((c) => c['id'] == id));
        _shuffle = prefs.getBool('listen_shuffle') ?? false;
        _skipHeard = prefs.getBool('listen_skip_heard') ?? false;
        _limit = [5, 10, 20, 50, 100].contains(prefs.getInt('listen_limit')) ? prefs.getInt('listen_limit')! : 10;
        _rate = prefs.getDouble('listen_rate') ?? 0.48;
        _loading = false;
      });
      await _tts.setSpeechRate(_rate);
      await _buildQueue();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Nem sikerült betölteni a híreket: $e'; });
    }
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('listen_categories', _selected.map((x) => '$x').toList());
    await p.setBool('listen_shuffle', _shuffle);
    await p.setBool('listen_skip_heard', _skipHeard);
    await p.setInt('listen_limit', _limit);
    await p.setDouble('listen_rate', _rate);
  }

  Future<void> _buildQueue() async {
    await _stop(reset: true);
    final p = await SharedPreferences.getInstance();
    final heard = (p.getStringList('listened_articles') ?? []).toSet();
    final filtered = _articles.where((a) {
      final ids = (a['categories'] as List? ?? []).whereType<int>();
      final matches = _selected.isEmpty || ids.any(_selected.contains);
      return matches && (!_skipHeard || !heard.contains('${a['id']}'));
    }).take(_limit).toList();
    if (_shuffle) filtered.shuffle();
    final existingIds = filtered.map((a) => a['id']).toSet();
    for (final article in _archiveQueue) {
      if (existingIds.add(article['id'])) filtered.add(article);
    }
    if (!mounted) return;
    setState(() { _queue = filtered; _articleIndex = 0; _segmentIndex = 0; });
    _prepareSegments();
  }

  Future<void> _searchArchive({bool more = false}) async {
    if (_archiveLoading) return;
    final term = _archiveSearch.text.trim();
    if (term.isEmpty) {
      setState(() { _archiveError = 'Írj be egy keresőkifejezést.'; _archiveSearched = false; });
      return;
    }
    final page = more ? _archivePage + 1 : 1;
    setState(() {
      _archiveLoading = true;
      _archiveError = null;
      if (!more) { _archiveResults = []; _archiveHasMore = false; }
    });
    try {
      final q = <String,String>{
        'search': term, 'per_page': '20', 'page': '$page', '_embed': '1',
        'orderby': 'date', 'order': 'desc',
      };
      if (_selected.isNotEmpty) q['categories'] = _selected.join(',');
      if (_archiveYear != null) {
        q['after'] = '${_archiveYear!}-01-01T00:00:00';
        q['before'] = '${_archiveYear!}-12-31T23:59:59';
      }
      final uri = Uri.parse('$baseUrl/wp-json/wp/v2/posts').replace(queryParameters: q);
      final response = await http.get(uri).timeout(const Duration(seconds: 22));
      if (response.statusCode != 200) {
        throw Exception('A keresés nem sikerült (HTTP ${response.statusCode}).');
      }
      final items = jsonDecode(response.body) as List<dynamic>;
      final totalPages = int.tryParse(response.headers['x-wp-totalpages'] ?? '') ?? page;
      if (!mounted) return;
      setState(() {
        _archiveResults = more ? [..._archiveResults, ...items] : items;
        _archivePage = page;
        _archiveHasMore = page < totalPages;
        _archiveSearched = true;
      });
    } catch (e) {
      if (mounted) setState(() => _archiveError = '$e');
    } finally {
      if (mounted) setState(() => _archiveLoading = false);
    }
  }

  void _addArchiveArticle(dynamic article, {bool playNow = false}) {
    final id = article['id'];
    if (!_queue.any((a) => a['id'] == id)) {
      _archiveQueue.add(article);
      setState(() => _queue.add(article));
    }
    if (playNow) {
      final index = _queue.indexWhere((a) => a['id'] == id);
      _playArchiveAt(index);
    }
  }

  Future<void> _playArchiveAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await _stop(reset: true);
    if (!mounted) return;
    setState(() { _articleIndex = index; _segmentIndex = 0; _playing = true; _paused = false; });
    _prepareSegments();
    await _speak();
  }

  Widget _archiveFinder() {
    const red = Color(0xFFD20A12);
    const muted = Color(0xFFBBBBBB);
    final now = DateTime.now().year;
    return Card(color: const Color(0xFF292929), child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.manage_search, color: red), SizedBox(width: 8),
          Expanded(child: Text('Keresés a teljes cikkarchívumban',
            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)))]),
        const SizedBox(height: 8),
        const Text('Régi cikkeket is megtalálhatsz, és hozzáadhatod a lejátszási listádhoz.',
          style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 10),
        TextField(
          controller: _archiveSearch,
          style: const TextStyle(color: Colors.white),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _searchArchive(),
          decoration: InputDecoration(
            hintText: 'Cím, téma vagy kulcsszó...',
            hintStyle: const TextStyle(color: muted),
            prefixIcon: const Icon(Icons.search, color: muted),
            filled: true, fillColor: const Color(0xFF1B1B1B),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Text('Megjelenés éve:', style: TextStyle(color: Colors.white70)),
          const SizedBox(width: 12),
          Expanded(child: DropdownButton<int?>(
            isExpanded: true, value: _archiveYear,
            dropdownColor: const Color(0xFF292929),
            style: const TextStyle(color: Colors.white),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('Bármelyik év')),
              for (var year = now; year >= 2000; year--)
                DropdownMenuItem<int?>(value: year, child: Text('$year')),
            ],
            onChanged: (v) => setState(() => _archiveYear = v),
          )),
        ]),
        const Text('A fent kijelölt kategóriákra is szűr. Ha nincs kijelölés, mindegyikben keres.',
          style: TextStyle(color: muted, fontSize: 11)),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: red),
          onPressed: _archiveLoading ? null : () => _searchArchive(),
          icon: const Icon(Icons.search), label: const Text('Cikkek keresése'),
        )),
        if (_archiveLoading) const Padding(padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator(color: red))),
        if (_archiveError != null) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(_archiveError!, style: const TextStyle(color: Colors.orangeAccent))),
        if (_archiveSearched && !_archiveLoading && _archiveResults.isEmpty && _archiveError == null)
          const Padding(padding: EdgeInsets.only(top: 12),
            child: Text('Nincs találat. Próbálj másik kifejezést vagy évet.',
              style: TextStyle(color: muted))),
        if (_archiveResults.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Találatok (${_archiveResults.length})',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          for (final article in _archiveResults) ...[
            const Divider(color: Colors.white12),
            Text(plain('${article['title']?['rendered'] ?? ''}'),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('${article['date'] ?? ''}'.split('T').first,
              style: const TextStyle(color: muted, fontSize: 12)),
            Row(children: [
              TextButton.icon(
                onPressed: _queue.any((a) => a['id'] == article['id']) ? null :
                  () => _addArchiveArticle(article),
                icon: Icon(_queue.any((a) => a['id'] == article['id']) ? Icons.check : Icons.playlist_add),
                label: Text(_queue.any((a) => a['id'] == article['id']) ? 'Listában' : 'Listához adom'),
              ),
              const SizedBox(width: 6),
              TextButton.icon(onPressed: () => _addArchiveArticle(article, playNow: true),
                icon: const Icon(Icons.play_arrow), label: const Text('Meghallgatom')),
            ]),
          ],
          if (_archiveHasMore) Center(child: OutlinedButton.icon(
            onPressed: _archiveLoading ? null : () => _searchArchive(more: true),
            icon: const Icon(Icons.expand_more), label: const Text('További találatok'),
          )),
        ],
      ]),
    ));
  }

  void _prepareSegments() {
    if (_articleIndex >= _queue.length) { _segments = []; return; }
    final a = _queue[_articleIndex];
    final text = '${plain((a['title']?['rendered'] ?? '').toString())}. '
        '${plain((a['content']?['rendered'] ?? '').toString())}';
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final parts = <String>[];
    var buffer = '';
    for (final sentence in sentences) {
      if (buffer.isNotEmpty && buffer.length + sentence.length > 220) {
        parts.add(buffer.trim()); buffer = '';
      }
      if (sentence.length > 220) {
        if (buffer.isNotEmpty) { parts.add(buffer.trim()); buffer = ''; }
        for (var i = 0; i < sentence.length; i += 220) {
          parts.add(sentence.substring(i, (i + 220 > sentence.length ? sentence.length : i + 220)));
        }
      } else { buffer += '$sentence '; }
    }
    if (buffer.trim().isNotEmpty) parts.add(buffer.trim());
    _segments = parts;
  }

  Future<void> _markHeard() async {
    if (_articleIndex >= _queue.length) return;
    final p = await SharedPreferences.getInstance();
    final ids = p.getStringList('listened_articles') ?? [];
    final id = '${_queue[_articleIndex]['id']}';
    if (!ids.contains(id)) ids.add(id);
    if (ids.length > 1000) ids.removeRange(0, ids.length - 1000);
    await p.setStringList('listened_articles', ids);
  }

  void _onSegmentComplete() {
    if (!mounted || !_playing) return;
    if (_segmentIndex + 1 < _segments.length) {
      setState(() => _segmentIndex++);
      _speak();
    } else {
      _markHeard();
      if (_articleIndex + 1 < _queue.length) {
        setState(() { _articleIndex++; _segmentIndex = 0; });
        _prepareSegments();
        _speak();
      } else {
        setState(() { _playing = false; _paused = false; });
      }
    }
  }

  Future<void> _speak() async {
    if (!_playing || _segmentIndex >= _segments.length) return;
    final generation = _playbackGeneration;
    await _tts.setSpeechRate(_rate);
    if (!mounted || !_playing || generation != _playbackGeneration) return;
    if (_androidBackground) {
      await _sendBackgroundStart();
    } else {
      await _tts.speak(_segments[_segmentIndex]);
    }
  }

  Future<void> _stop({bool reset = false}) async {
    _playbackGeneration++;
    if (mounted) setState(() {
      _playing = false; _paused = !reset;
      if (reset) _segmentIndex = 0;
    });
    if (_androidBackground) {
      if (reset) {
        _background.invoke('listen_stop');
      } else {
        _background.invoke('listen_pause');
      }
    } else {
      await _tts.stop();
    }
  }

  Future<void> _toggle() async {
    if (_playing) { await _stop(); return; }
    if (_queue.isEmpty) return;
    if (_segmentIndex >= _segments.length) _segmentIndex = 0;
    setState(() { _playing = true; _paused = false; });
    await _speak();
  }

  Future<void> _jumpArticle(int delta) async {
    if (_queue.isEmpty) return;
    final next = (_articleIndex + delta).clamp(0, _queue.length - 1).toInt();
    final resume = _playing;
    await _stop(reset: true);
    if (!mounted) return;
    setState(() { _articleIndex = next; _segmentIndex = 0; _playing = resume; _paused = !resume; });
    _prepareSegments();
    if (resume) await _speak();
  }

  Future<void> _seek(double fraction) async {
    if (_segments.isEmpty) return;
    final resume = _playing;
    await _stop();
    if (!mounted) return;
    setState(() {
      _segmentIndex = (fraction * (_segments.length - 1)).round().clamp(0, _segments.length - 1);
      _playing = resume;
      _paused = !resume;
    });
    if (resume) await _speak();
  }

  Future<void> _changeRate(double value) async {
    final resume = _playing;
    await _stop();
    if (!mounted) return;
    setState(() { _rate = value; _playing = resume; _paused = !resume; });
    await _tts.setSpeechRate(value);
    await _saveSettings();
    if (resume) await _speak();
  }

  @override
  void dispose() { _playbackGeneration++; _archiveSearch.dispose(); _backgroundState?.cancel(); _backgroundHeard?.cancel(); _tts.stop(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD20A12);
    const panel = Color(0xFF292929);
    const muted = Color(0xFFBBBBBB);
    final current = _queue.isNotEmpty && _articleIndex < _queue.length
        ? _queue[_articleIndex] : null;
    final fraction = _segments.isEmpty ? 0.0 :
        (_segmentIndex / _segments.length).clamp(0.0, 1.0);
    return Container(
      color: const Color(0xFF171717),
      child: _loading ? const Center(child: CircularProgressIndicator(color: red)) :
      _error != null ? Center(child: Padding(padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
          TextButton(onPressed: () { setState(() { _loading = true; _error = null; }); _load(); }, child: const Text('Újrapróbálás')),
        ]))) : ListView(padding: const EdgeInsets.all(16), children: [
        const Row(children: [Icon(Icons.headphones, color: red, size: 30), SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('A MI IDŐNK', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20)),
            Text('HÍREK HALLGATÁSA', style: TextStyle(color: muted, fontSize: 12, letterSpacing: 1.5)),
          ]))]),
        const SizedBox(height: 18),
        Card(color: panel, child: Padding(padding: const EdgeInsets.all(14), child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Milyen témákat hallgatnál?', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Kiválaszthatsz több kategóriát. Ha egyet sem jelölsz, minden kategória szerepel.', style: TextStyle(color: muted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 2, children: _categories.map((c) {
              final id = c['id'] as int;
              final selected = _selected.contains(id);
              return FilterChip(
                label: Text(plain('${c['name']}')),
                selected: selected,
                selectedColor: red,
                checkmarkColor: Colors.white,
                labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87),
                onSelected: (yes) async {
                  setState(() { if (yes) { _selected.add(id); } else { _selected.remove(id); } });
                  await _saveSettings(); await _buildQueue();
                },
              );
            }).toList()),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Cikkek száma', style: TextStyle(color: Colors.white)),
              const Spacer(),
              DropdownButton<int>(value: _limit, dropdownColor: panel,
                style: const TextStyle(color: Colors.white),
                items: [5, 10, 20, 50, 100].map((n) => DropdownMenuItem(value: n, child: Text('$n cikk'))).toList(),
                onChanged: (n) async { if (n == null) return; setState(() => _limit = n); await _saveSettings(); await _buildQueue(); }),
            ]),
            SwitchListTile.adaptive(contentPadding: EdgeInsets.zero,
              title: const Text('Shuffle – véletlen sorrend', style: TextStyle(color: Colors.white)),
              activeTrackColor: red, value: _shuffle,
              onChanged: (v) async { setState(() => _shuffle = v); await _saveSettings(); await _buildQueue(); }),
            SwitchListTile.adaptive(contentPadding: EdgeInsets.zero,
              title: const Text('Meghallgatott cikkek kihagyása', style: TextStyle(color: Colors.white)),
              activeTrackColor: red, value: _skipHeard,
              onChanged: (v) async { setState(() => _skipHeard = v); await _saveSettings(); await _buildQueue(); }),
          ]))),
        const SizedBox(height: 12),
        _archiveFinder(),
        const SizedBox(height: 12),
        Card(color: panel, child: Padding(padding: const EdgeInsets.all(14), child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Expanded(child: Text('Lejátszási lista', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold))),
              Text('${_queue.length} cikk', style: const TextStyle(color: muted))]),
            if (_queue.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('Nincs megjeleníthető cikk. Válassz másik kategóriát, vagy kapcsold ki a meghallgatott cikkek kihagyását.', style: TextStyle(color: muted))),
            ..._queue.asMap().entries.map((entry) {
              final i = entry.key; final a = entry.value;
              final active = i == _articleIndex;
              return ListTile(contentPadding: EdgeInsets.zero, dense: true,
                leading: Icon(active ? Icons.graphic_eq : Icons.article_outlined, color: active ? red : muted),
                title: Text(plain('${a['title']?['rendered'] ?? ''}'), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontWeight: active ? FontWeight.bold : FontWeight.normal)),
                onTap: () async {
                  final resume = _playing; await _stop(reset: true);
                  if (!mounted) return;
                  setState(() { _articleIndex = i; _segmentIndex = 0; _playing = resume; });
                  _prepareSegments(); if (resume) await _speak();
                },
              );
            }),
          ]))),
        const SizedBox(height: 12),
        Card(color: panel, child: Padding(padding: const EdgeInsets.all(16), child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('MOST HALLGATOD', style: TextStyle(color: muted, fontSize: 11, letterSpacing: 1.2)),
            const SizedBox(height: 8),
            Text(current == null ? 'Válassz egy cikket' : plain('${current['title']?['rendered'] ?? ''}'),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
            const SizedBox(height: 10),
            Slider(value: fraction, activeColor: red, inactiveColor: Colors.white24,
              onChanged: current == null ? null : _seek),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('${(fraction * 100).round()}% • ${_segmentIndex + (current == null ? 0 : 1)}/${_segments.length} szakasz', style: const TextStyle(color: muted, fontSize: 12)),
              Text('${_articleIndex + (current == null ? 0 : 1)}/${_queue.length} cikk', style: const TextStyle(color: muted, fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(onPressed: current == null ? null : () => _seek((fraction - 0.1).clamp(0.0, 1.0)),
                icon: const Icon(Icons.replay_10, color: Colors.white)),
              IconButton(onPressed: current == null ? null : () => _jumpArticle(-1),
                icon: const Icon(Icons.skip_previous, color: Colors.white, size: 30)),
              IconButton.filled(onPressed: current == null ? null : _toggle,
                style: IconButton.styleFrom(backgroundColor: red, padding: const EdgeInsets.all(16)),
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 30)),
              IconButton(onPressed: current == null ? null : () => _jumpArticle(1),
                icon: const Icon(Icons.skip_next, color: Colors.white, size: 30)),
              IconButton(onPressed: current == null ? null : () => _seek((fraction + 0.1).clamp(0.0, 1.0)),
                icon: const Icon(Icons.forward_10, color: Colors.white)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.speed, color: muted), const SizedBox(width: 8),
              const Text('Sebesség', style: TextStyle(color: Colors.white)),
              const Spacer(),
              DropdownButton<double>(value: _rate, dropdownColor: panel,
                style: const TextStyle(color: Colors.white),
                items: const [
                  DropdownMenuItem(value: 0.36, child: Text('0,75×')),
                  DropdownMenuItem(value: 0.48, child: Text('1×')),
                  DropdownMenuItem(value: 0.60, child: Text('1,25×')),
                  DropdownMenuItem(value: 0.72, child: Text('1,5×')),
                ],
                onChanged: (v) { if (v != null) _changeRate(v); }),
            ]),
            const Text('A tekerés szövegszakaszok között történik, nem másodpercre pontosan.', style: TextStyle(color: muted, fontSize: 11)),
          ]))),
        const SizedBox(height: 16),
      ]),
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
  final FlutterTts tts = FlutterTts();
  bool saved = false, playing = false, paused = false, playerExpanded = true;
  int fontSize = 18, segmentIndex = 0;
  double readingProgress = 0, speechRate = 0.48;
  List<String> segments = [];
  List<dynamic> related = [];
  late final WebViewController controller;
  String get id => '${widget.post['id']}';
  String get articleTitle => plain((widget.post['title']?['rendered'] ?? '').toString());

  @override
  void initState() {
    super.initState();
    _prepareSegments();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('ReadingProgress', onMessageReceived: (message) {
        final value = double.tryParse(message.message);
        if (value != null && mounted) setState(() => readingProgress = value.clamp(0.0, 1.0));
      })
      ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: (request) {
        if (request.url.startsWith(articleShareActionUrl)) {
          _shareArticle();
          return NavigationDecision.prevent;
        }
        if (request.url.contains('ami_app_related=')) {
          final target = Uri.tryParse(request.url)?.queryParameters['ami_app_related'];
          for (final item in related) {
            if ('${item['id']}' == target) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => ArticlePage(post: item)));
              break;
            }
          }
          return NavigationDecision.prevent;
        }
        return NavigationDecision.navigate;
      }));
    _load();
    _loadRelated();
    tts.setLanguage('hu-HU');
    tts.setSpeechRate(speechRate);
    tts.setCompletionHandler(() {
      if (!mounted || !playing) return;
      if (segmentIndex + 1 < segments.length) {
        setState(() => segmentIndex++);
        _speakCurrent();
      } else {
        setState(() { playing = false; paused = false; segmentIndex = segments.length; });
      }
    });
    tts.setErrorHandler((message) {
      if (mounted) setState(() { playing = false; paused = true; });
    });
  }

  void _prepareSegments() {
    final text = '$articleTitle. ${plain((widget.post['content']?['rendered'] ?? '').toString())}';
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    segments = [];
    var current = '';
    for (final sentence in sentences) {
      if (current.length + sentence.length > 220 && current.isNotEmpty) {
        segments.add(current.trim());
        current = '';
      }
      if (sentence.length > 220) {
        if (current.isNotEmpty) { segments.add(current.trim()); current = ''; }
        for (var i = 0; i < sentence.length; i += 220) {
          segments.add(sentence.substring(i, i + 220 > sentence.length ? sentence.length : i + 220));
        }
      } else { current += '$sentence '; }
    }
    if (current.trim().isNotEmpty) segments.add(current.trim());
  }

  Future<void> _loadRelated() async {
    try {
      final categories = widget.post['categories'];
      if (categories is! List || categories.isEmpty) return;
      final result = await NewsApi.posts(category: categories.first is int ? categories.first as int : int.tryParse('${categories.first}'));
      if (mounted) {
        setState(() => related = result.where((p) => '${p['id']}' != id).take(3).toList());
        _renderArticleHtml();
      }
    } catch (_) { /* A cikk a kapcsolódó ajánlások nélkül is olvasható. */ }
  }

  @override
  void didChangeDependencies() { super.didChangeDependencies(); _renderArticleHtml(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final seen = p.getStringList('read_articles') ?? [];
    if (!seen.contains(id)) {
      seen.add(id);
      if (seen.length > 1500) seen.removeRange(0, seen.length - 1500);
      await p.setStringList('read_articles', seen);
    }
    if (mounted) {
      setState(() { saved = (p.getStringList('saved') ?? []).contains(id); fontSize = p.getInt('article_font_size') ?? 18; });
      _renderArticleHtml();
    }
  }

  void _navigateArticle(int direction) {
    final list = widget.posts; final index = widget.index;
    if (list == null || index == null) return;
    final next = index + direction;
    if (next < 0 || next >= list.length) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ArticlePage(post: list[next], posts: list, index: next)));
  }

  Future<void> _shareArticle() async { await Share.share((widget.post['link'] ?? baseUrl).toString(), subject: articleTitle); }
  Future<void> _toggleSaved() async {
    final p = await SharedPreferences.getInstance();
    final ids = p.getStringList('saved') ?? [];
    if (ids.contains(id)) { ids.remove(id); } else { ids.add(id); await p.setString('article_$id', jsonEncode(widget.post)); }
    await p.setStringList('saved', ids);
    if (mounted) setState(() => saved = ids.contains(id));
  }

  Future<void> _speakCurrent() async {
    if (!playing || segmentIndex >= segments.length) return;
    await tts.setSpeechRate(speechRate);
    await tts.speak(segments[segmentIndex]);
  }
  Future<void> _togglePlayback() async {
    if (playing) {
      setState(() { playing = false; paused = true; });
      await tts.stop();
    } else {
      if (segmentIndex >= segments.length) segmentIndex = 0;
      setState(() { playing = true; paused = false; });
      await _speakCurrent();
    }
  }
  Future<void> _seekTo(double value) async {
    final wasPlaying = playing;
    setState(() { playing = false; segmentIndex = (value * segments.length).floor().clamp(0, segments.isEmpty ? 0 : segments.length - 1).toInt(); });
    await tts.stop();
    if (wasPlaying && mounted) { setState(() => playing = true); await _speakCurrent(); }
  }
  Future<void> _setRate(double value) async {
    final wasPlaying = playing;
    setState(() { speechRate = value; playing = false; });
    await tts.stop();
    await tts.setSpeechRate(value);
    if (wasPlaying && mounted) { setState(() => playing = true); await _speakCurrent(); }
  }
  @override void dispose() { tts.stop(); super.dispose(); }

  void _renderArticleHtml() {
    final content = articleHtml((widget.post['content']?['rendered'] ?? '').toString());
    final title = const HtmlEscape().convert(articleTitle);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? '#121212' : '#ffffff';
    final foreground = isDark ? '#eeeeee' : '#222222';
    final relatedHtml = related.isEmpty ? '' : '<section class="related"><h2>Kapcsolódó cikkek</h2>${related.map((p) {
      final t = const HtmlEscape().convert(plain((p['title']?['rendered'] ?? '').toString()));
      final image = imageFor(p);
      final safeImage = const HtmlEscape(HtmlEscapeMode.attribute).convert(image);
      return '<a class="related-item" href="$baseUrl/?ami_app_related=${p['id']}">${image.isEmpty ? '' : '<img src="$safeImage" alt="">'}<span>$t</span></a>';
    }).join()}</section>';
    final page = '''<!doctype html><html lang="hu"><head><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>
      body {background: $background; color: $foreground; font-family: sans-serif; font-size: ${fontSize}px; line-height: 1.65; margin: 18px; overflow-wrap: break-word;}
      img, video, iframe {max-width: 100%; height: auto;} img {display: block; margin-left: auto !important; margin-right: auto !important;} figure, .wp-block-image {max-width: 100%; margin: 16px auto !important; text-align: center !important;}
      p {margin: 0 0 1.1em;} h1,h2,h3,h4 {line-height: 1.3; margin-top: 1.4em;}
      a {color: #d20a12;} blockquote {border-left: 4px solid #d20a12; padding-left: 12px; margin-left: 0;}
      figcaption {font-size: 0.85em; opacity: 0.75;} table {max-width: 100%; display: block; overflow-x: auto;}
      .share-end {display: block; box-sizing: border-box; width: 100%; margin: 30px 0 16px; padding: 16px; border-radius: 12px; background: #d20a12; color: white !important; font-size: 19px; font-weight: bold; text-align: center; text-decoration: none;}
      .related {margin-top: 32px; padding-top: 14px; border-top: 1px solid #8885;}
      .related-item {display:flex; align-items:center; gap:12px; padding: 12px 0; text-decoration:none; border-bottom:1px solid #8883; font-weight:600;}
      .related-item img {width:90px; height:65px; object-fit:cover; border-radius:8px; margin:0!important;}
    </style></head><body><h1>$title</h1>$content<a class="share-end" href="$articleShareActionUrl">Megosztás</a>$relatedHtml
    <script>function reportProgress(){var d=document.documentElement;var max=Math.max(1,d.scrollHeight-innerHeight);ReadingProgress.postMessage(String(Math.max(0,Math.min(1,scrollY/max))));}window.addEventListener('scroll',reportProgress,{passive:true});window.addEventListener('load',reportProgress);</script>
    </body></html>''';
    controller.setBackgroundColor(Theme.of(context).scaffoldBackgroundColor);
    controller.loadHtmlString(page, baseUrl: '$baseUrl/');
  }

  Widget _audioPlayer() {
    final total = segments.length;
    final progress = total == 0 ? 0.0 : (segmentIndex / total).clamp(0.0, 1.0);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 5, 10, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: dark ? const Color(0xFF181818) : const Color(0xFF252525), borderRadius: BorderRadius.circular(18)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.headphones, color: brandRed), const SizedBox(width: 8),
          const Expanded(child: Text('A MI IDŐNK  •  CIKKFELOLVASÓ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
          IconButton(onPressed: () => setState(() => playerExpanded = !playerExpanded), icon: Icon(playerExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, color: Colors.white), tooltip: playerExpanded ? 'Összecsukás' : 'Kinyitás'),
        ]),
        if (playerExpanded) ...[
          Text(articleTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          SliderTheme(data: SliderTheme.of(context).copyWith(activeTrackColor: brandRed, thumbColor: brandRed, inactiveTrackColor: Colors.white30), child: Slider(value: progress, onChanged: total == 0 ? null : _seekTo)),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('${total == 0 ? 0 : segmentIndex + 1}. szakasz', style: const TextStyle(color: Colors.white70, fontSize: 12)), Text('$total szakasz', style: const TextStyle(color: Colors.white70, fontSize: 12))]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'Vissza 1 szakasszal', onPressed: () => _seekTo((segmentIndex - 1).clamp(0, total == 0 ? 0 : total - 1) / (total == 0 ? 1 : total)), icon: const Icon(Icons.skip_previous, color: Colors.white)),
            const SizedBox(width: 8),
            FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: brandRed), onPressed: _togglePlayback, icon: Icon(playing ? Icons.pause : Icons.play_arrow), label: Text(playing ? 'Szünet' : paused ? 'Folytatás' : 'Lejátszás')),
            const SizedBox(width: 8),
            IconButton(tooltip: 'Előre 1 szakasszal', onPressed: () => _seekTo((segmentIndex + 1).clamp(0, total == 0 ? 0 : total - 1) / (total == 0 ? 1 : total)), icon: const Icon(Icons.skip_next, color: Colors.white)),
          ]),
          Row(children: [
            const Icon(Icons.speed, color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            const Text('Sebesség', style: TextStyle(color: Colors.white70)),
            const Spacer(),
            DropdownButton<double>(dropdownColor: const Color(0xFF252525), value: speechRate, style: const TextStyle(color: Colors.white), underline: const SizedBox.shrink(), items: const [
              DropdownMenuItem(value: 0.36, child: Text('0,75×')),
              DropdownMenuItem(value: 0.48, child: Text('1×')),
              DropdownMenuItem(value: 0.60, child: Text('1,25×')),
              DropdownMenuItem(value: 0.72, child: Text('1,5×')),
            ], onChanged: (value) { if (value != null) _setRate(value); }),
          ]),
          const Text('A csúszka szövegszakaszok között léptet, nem másodperc pontossággal.', style: TextStyle(color: Colors.white54, fontSize: 10)),
        ] else Row(children: [
          Expanded(child: Text(articleTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70))),
          IconButton(onPressed: _togglePlayback, icon: Icon(playing ? Icons.pause_circle : Icons.play_circle, color: brandRed, size: 34)),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('A MI IDŐNK'), actions: [
      IconButton(tooltip: 'Cikk megosztása', icon: const Icon(Icons.share_outlined), onPressed: _shareArticle),
      IconButton(icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border), onPressed: _toggleSaved),
    ]),
    body: Column(children: [
      LinearProgressIndicator(value: readingProgress, minHeight: 3, color: brandRed, backgroundColor: Colors.transparent),
      Expanded(child: WebViewWidget(controller: controller)),
      _audioPlayer(),
      if (widget.posts != null && widget.index != null)
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          TextButton.icon(onPressed: widget.index! > 0 ? () => _navigateArticle(-1) : null, icon: const Icon(Icons.chevron_left), label: const Text('Előző')),
          Text('${widget.index! + 1} / ${widget.posts!.length}'),
          TextButton.icon(onPressed: widget.index! < widget.posts!.length - 1 ? () => _navigateArticle(1) : null, icon: const Icon(Icons.chevron_right), label: const Text('Következő')),
        ]),
    ]),
  );
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
