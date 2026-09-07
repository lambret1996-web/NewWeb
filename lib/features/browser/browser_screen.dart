import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/db/database_helper.dart';
import '../../core/services/adblock_service.dart';
import '../../core/services/download_service.dart';
import '../../core/services/offline_service.dart';
import '../../core/services/settings_service.dart';
import '../../native/native_bridge.dart';
import 'bookmarks_page.dart';
import 'cache_manager_page.dart';
import 'download_page.dart';
import 'history_page.dart';
import 'offline_pages_page.dart';
import 'reader_page.dart';
import 'settings_page.dart';
import 'tab_manager.dart';
import 'webview_page.dart';
import 'widgets/address_bar.dart';
import 'widgets/gesture_layer.dart';
import 'widgets/progress_bar.dart';
import 'widgets/tab_switcher.dart';
import 'widgets/tool_bar.dart';

/// 浏览器主界面：地址栏 + 多标签 WebView + 手势层 + 工具栏。
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final TextEditingController _addressController = TextEditingController();
  final TabManager _tabManager = TabManager();
  final Map<String, GlobalKey<WebViewPageState>> _webViewKeys = {};
  String _lastActiveTabId = '';

  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _incognito = false;
  StreamSubscription<Map<String, dynamic>>? _nativeSub;

  @override
  void initState() {
    super.initState();
    _tabManager.addListener(_onTabsChanged);
    DownloadService.instance.lastCompleted.addListener(_onDownloadCompleted);
    unawaited(_initTabs());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DatabaseHelper.instance.initDefaultBookmarks();
      AdBlockService.instance.init();
      DownloadService.instance.ensureListening();
    });
    _loadIncognito();
    _listenNativeEvents();
  }

  /// 初始化标签：优先恢复上次会话（非无痕），否则新建默认标签。
  Future<void> _initTabs() async {
    final incognito = await SettingsService.instance.isIncognitoEnabled();
    if (mounted && incognito) setState(() => _incognito = true);
    await _tabManager.setPersistSession(!incognito);
    if (!incognito) {
      final restored = await _tabManager.restoreSession();
      if (restored) return;
    }
    _tabManager.addTab();
  }

  Future<void> _loadIncognito() async {
    final value = await SettingsService.instance.isIncognitoEnabled();
    if (!mounted) return;
    setState(() => _incognito = value);
    await _tabManager.setPersistSession(!value);
  }

  /// 监听原生事件：长按菜单动作（翻译此页 / 下载链接/图片）。
  void _listenNativeEvents() {
    _nativeSub = NativeBridge.events().listen((e) {
      final event = e['event'] as String?;
      if (event == null) return;
      switch (event) {
        case 'translatePage':
          _translatePage();
        case 'download':
          final url = e['url'] as String? ?? '';
          if (url.isNotEmpty) {
            _confirmDownload(url);
          }
      }
    }, onError: (Object e) {
      debugPrint('[Browser] 原生事件错误: $e');
    });
  }

  /// 下载前确认弹窗。
  Future<void> _confirmDownload(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('开始下载？'),
        content: Text(
          url,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      DownloadService.instance.start(url);
      _showMessage('已开始下载');
    }
  }

  @override
  void dispose() {
    _nativeSub?.cancel();
    _tabManager.removeListener(_onTabsChanged);
    DownloadService.instance.lastCompleted.removeListener(_onDownloadCompleted);
    _tabManager.dispose();
    _addressController.dispose();
    super.dispose();
  }

  void _onTabsChanged() {
    final active = _tabManager.activeTab;
    if (active != null) {
      _addressController.text = active.url;
      // 标签切换时补截图
      if (active.id != _lastActiveTabId) {
        _lastActiveTabId = active.id;
        _refreshSnapshot();
      }
    }
  }

  GlobalKey<WebViewPageState> _keyOf(String tabId) =>
      _webViewKeys.putIfAbsent(tabId, () => GlobalKey<WebViewPageState>());

  WebViewPageState? _currentWebView() =>
      _webViewKeys[_tabManager.activeTabId]?.currentState;

  void _onProgress(double progress) => setState(() => _progress = progress);

  void _onCanGoBackChanged(bool value) => setState(() => _canGoBack = value);

  void _onCanGoForwardChanged(bool value) => setState(() => _canGoForward = value);

  void _submit(String input) {
    FocusScope.of(context).unfocus();
    _currentWebView()?.load(input);
  }

  void _openTabSwitcher() {
    FocusScope.of(context).unfocus();
    Navigator.of(context)
        .push<String>(
          CupertinoPageRoute(
            builder: (_) => TabSwitcherPage(
              manager: _tabManager,
              onNewTab: () {
                _tabManager.addTab(url: 'about:blank');
                Navigator.of(context).pop();
              },
              onCloseSelected: (ids) {
                if (ids.isEmpty) {
                  // 关闭全部
                  for (final t in _tabManager.tabs.toList()) {
                    _tabManager.closeTab(t.id);
                  }
                } else {
                  for (final id in ids) {
                    _tabManager.closeTab(id);
                  }
                }
              },
              onBookmarkSelected: (ids) async {
                var count = 0;
                for (final id in ids) {
                  final tab = _tabManager.tabs
                      .where((t) => t.id == id)
                      .firstOrNull;
                  if (tab == null ||
                      tab.url.isEmpty ||
                      tab.url.startsWith('about:')) {
                    continue;
                  }
                  final existing =
                      await DatabaseHelper.instance.findBookmarkByUrl(tab.url);
                  if (existing == null) {
                    await DatabaseHelper.instance
                        .addBookmark(tab.title, tab.url);
                    count++;
                  }
                }
                if (mounted) {
                  _showMessage(count > 0
                      ? '已添加 $count 个书签'
                      : '没有可添加的书签');
                }
              },
            ),
          ),
        )
        .then((selectedTabId) {
          if (selectedTabId != null && mounted) {
            _tabManager.switchTab(selectedTabId);
            _refreshSnapshot();
          }
        });
  }

  /// 更多菜单项定义（id 用于排序持久化）。
  List<Map<String, dynamic>> get _menuItems => [
        {'id': 'bookmarks', 'icon': Icons.bookmark_border, 'label': '书签'},
        {'id': 'history', 'icon': Icons.history, 'label': '历史记录'},
        {'id': 'add_bookmark', 'icon': Icons.add, 'label': '添加到书签'},
        {'id': 'translate', 'icon': Icons.translate, 'label': '翻译此页'},
        {'id': 'reader', 'icon': Icons.menu_book_outlined, 'label': '阅读模式'},
        {'id': 'save_offline', 'icon': Icons.download_outlined, 'label': '保存离线页面'},
        {'id': 'offline_pages', 'icon': Icons.offline_pin_outlined, 'label': '离线页面'},
        {'id': 'downloads', 'icon': Icons.file_download_outlined, 'label': '下载管理'},
        {'id': 'cache', 'icon': Icons.cleaning_services_outlined, 'label': '缓存管理'},
        {'id': 'settings', 'icon': Icons.settings_outlined, 'label': '设置'},
      ];

  void _openMoreMenu() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _MoreMenuSheet(
        items: _menuItems,
        onTapItem: (id) {
          Navigator.of(sheetContext).pop();
          switch (id) {
            case 'bookmarks': _openBookmarks(context);
            case 'history': _openHistory(context);
            case 'add_bookmark': _addBookmark(context);
            case 'translate': _translatePageFromSheet(context);
            case 'reader': _openReader(context);
            case 'save_offline': _saveOffline(context);
            case 'offline_pages': _openOfflinePages(context);
            case 'downloads': _openDownloads(context);
            case 'cache': _openCacheManager(context);
            case 'settings': _openSettings(context);
          }
        },
      ),
    );
  }

  void _openBookmarks(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    Navigator.of(context)
        .push<String>(CupertinoPageRoute(builder: (_) => const BookmarksPage()))
        .then((url) {
      if (url != null && mounted) {
        _currentWebView()?.load(url);
      }
    });
  }

  void _openHistory(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    Navigator.of(context)
        .push<String>(CupertinoPageRoute(builder: (_) => const HistoryPage()))
        .then((url) {
      if (url != null && mounted) {
        _currentWebView()?.load(url);
      }
    });
  }

  Future<void> _addBookmark(BuildContext sheetContext) async {
    Navigator.of(sheetContext).pop();
    final active = _tabManager.activeTab;
    if (active == null || active.url.isEmpty || active.url.startsWith('about:')) {
      _showMessage('当前页面无法添加书签');
      return;
    }
    final existing = await DatabaseHelper.instance.findBookmarkByUrl(active.url);
    if (existing != null) {
      _showMessage('该书签已存在');
      return;
    }
    await DatabaseHelper.instance.addBookmark(active.title, active.url);
    if (!mounted) return;
    _showMessage('已添加到书签');
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 保存离线页面：触发当前页采集，结果经 JS Bridge 回传后落盘。
  void _saveOffline(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    final webView = _currentWebView();
    if (webView == null) return;
    _showMessage('正在保存离线页面…');
    webView.saveOffline();
  }

  void _saveOfflineCollected(String title, String url, String html) async {
    try {
      await OfflineService.instance.save(title, url, html);
      if (!mounted) return;
      _showMessage('离线页面已保存');
    } catch (e) {
      debugPrint('[Offline] 保存失败: $e');
      if (!mounted) return;
      _showMessage('离线保存失败');
    }
  }

  void _openOfflinePages(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    Navigator.of(context)
        .push<String>(CupertinoPageRoute(builder: (_) => const OfflinePagesPage()))
        .then((path) {
      if (path != null && mounted) {
        _currentWebView()?.loadFile(path);
      }
    });
  }

  void _openSettings(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    Navigator.of(context)
        .push<void>(CupertinoPageRoute(builder: (_) => const SettingsPage()))
        .then((_) => _loadIncognito());
  }

  /// 翻译此页（已翻译则恢复原文）。
  void _translatePageFromSheet(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    _translatePage();
  }

  Future<void> _translatePage() async {
    final webView = _currentWebView();
    if (webView == null) return;
    final result = await webView.translatePage();
    if (!mounted) return;
    switch (result) {
      case 'started':
        _showMessage('正在翻译当前页面…');
      case 'restored':
        _showMessage('已恢复原文');
      case 'noop':
        _showMessage('当前页面没有可翻译的文本');
    }
  }

  /// 阅读模式：提取正文并打开阅读页。
  void _openReader(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    final webView = _currentWebView();
    if (webView == null) return;
    _showMessage('正在提取正文…');
    webView.extractReader().then((data) {
      if (!mounted) return;
      if (data == null || data['html'] == null || data['html']!.isEmpty) {
        _showMessage('未提取到正文内容');
        return;
      }
      Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => ReaderPage(
            title: data['title'] ?? '阅读模式',
            html: data['html']!,
            sourceUrl: data['url'] ?? '',
          ),
        ),
      );
    });
  }

  void _openDownloads(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    Navigator.of(context)
        .push<void>(CupertinoPageRoute(builder: (_) => const DownloadPage()));
  }

  void _openCacheManager(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
    Navigator.of(context)
        .push<void>(CupertinoPageRoute(builder: (_) => const CacheManagerPage()));
  }

  /// 页面加载完成：更新标签元数据并写入历史（无痕模式下不记录）。
  void _onPageFinished(String tabId, String url) {
    final tab = _tabManager.tabs.where((t) => t.id == tabId).firstOrNull;
    if (tab == null) return;
    _tabManager.updateTab(tabId, isLoading: false, url: url);
    if (!_incognito) {
      DatabaseHelper.instance.addHistory(tab.title, url);
    }
    _refreshSnapshot();
  }

  /// 截取当前激活标签的最后浏览快照（无痕模式不截图），写入磁盘持久化。
  /// 延迟 400ms 等待页面渲染稳定（对齐 Chrome 快照时机）。
  Future<void> _refreshSnapshot() async {
    if (_incognito) return;
    final active = _tabManager.activeTab;
    if (active == null) return;
    await Future.delayed(const Duration(milliseconds: 400));
    final current = _tabManager.activeTab;
    if (current == null || current.id != active.id) return;
    final shot = await NativeBridge.captureSnapshot(active.url);
    if (!mounted) return;
    if (shot == null) return;
    // 写入稳定磁盘路径（App 重启后仍可读）
    try {
      final dir = await getApplicationSupportDirectory();
      final snapDir = Directory('${dir.path}/snapshots');
      if (!snapDir.existsSync()) snapDir.createSync(recursive: true);
      final file = File('${snapDir.path}/${active.id}.png');
      await file.writeAsBytes(shot);
      _tabManager.updateSnapshot(active.id, bytes: shot, diskPath: file.path);
    } catch (_) {
      _tabManager.updateSnapshot(active.id, bytes: shot);
    }
  }

  /// 下载完成弹窗队列。
  final List<DownloadTaskInfo> _downloadQueue = [];
  bool _downloadDialogShowing = false;

  void _onDownloadCompleted() {
    final task = DownloadService.instance.lastCompleted.value;
    if (task == null) return;
    _downloadQueue.add(task);
    _processDownloadQueue();
  }

  Future<void> _processDownloadQueue() async {
    if (_downloadDialogShowing || _downloadQueue.isEmpty) return;
    _downloadDialogShowing = true;
    final task = _downloadQueue.removeAt(0);
    if (!mounted) {
      _downloadDialogShowing = false;
      _processDownloadQueue();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.fileName ?? '文件',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              DownloadService.formatSize(task.total),
              style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
          ],
        ),
        actions: [
          if (task.filePath != null)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                NativeBridge.previewFile(task.filePath!);
              },
              child: const Text('打开文件'),
            ),
          if (task.filePath != null)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Share.shareXFiles([XFile(task.filePath!)]);
              },
              child: const Text('分享文件'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    _downloadDialogShowing = false;
    _processDownloadQueue();
  }

  /// 分享当前页面（调用 iOS 原生 UIActivityViewController）。
  Future<void> _shareCurrentPage() async {
    final active = _tabManager.activeTab;
    if (active == null || active.url.isEmpty || active.url.startsWith('about:')) {
      _showMessage('当前页面无法分享');
      return;
    }
    await NativeBridge.shareUrl(
      url: active.url,
      title: active.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                AddressBar(
                  controller: _addressController,
                  onSubmit: _submit,
                  onReload: () => _currentWebView()?.reload(),
                ),
                ProgressBar(progress: _progress),
                if (_incognito)
                  Container(
                    width: double.infinity,
                    color: const Color(0xFF1F2937),
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: const Text(
                      '无痕浏览中 · 不记录历史记录',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: _tabManager,
              builder: (context, _) {
                final activeId = _tabManager.activeTabId;
                return GestureLayer(
                  onEdgeBack: () => _currentWebView()?.goBack(),
                  onEdgeForward: () => _currentWebView()?.goForward(),
                  isAtTop: () async => _currentWebView()?.isAtTop() ?? true,
                  onRefresh: () async {
                    await _currentWebView()?.reload();
                  },
                  child: IndexedStack(
                    index: _tabManager.tabs.indexWhere((t) => t.id == activeId),
                    children: _tabManager.tabs.map((tab) {
                      final tabId = tab.id;
                      final keepAlive = _tabManager.keepAliveTabIds;
                      return WebViewPage(
                        key: _keyOf(tabId),
                        initialUrl: tab.url,
                        active: keepAlive.contains(tabId),
                        snapshotBytes: tab.snapshot,
                        snapshotPath: tab.snapshotPath,
                        initialScrollY: tab.scrollY,
                        onScrollSaved: (dy) {
                          _tabManager.updateTab(tabId, scrollY: dy);
                        },
                        onLoadUrl: (url) {
                          _tabManager.updateTab(tabId, url: url);
                          _currentWebView()?.load(url);
                        },
                        onProgress: _onProgress,
                        onUrlChanged: (url) {
                          if (url != null) {
                            _tabManager.updateTab(tabId, url: url);
                          }
                        },
                        onPageStarted: (url) {
                          _tabManager.updateTab(tabId, url: url, isLoading: true);
                        },
                        onPageFinished: (url) {
                          _onPageFinished(tabId, url);
                        },
                        onTitleChanged: (title) {
                          _tabManager.updateTab(tabId, title: title);
                        },
                        onOfflineCollected: _saveOfflineCollected,
                        onCanGoBackChanged: _onCanGoBackChanged,
                        onCanGoForwardChanged: _onCanGoForwardChanged,
                      );
                    }).toList(),
                  ),
                );
              },
            ),
          ),
          ToolBar(
            canGoBack: _canGoBack,
            canGoForward: _canGoForward,
            onBack: () => _currentWebView()?.goBack(),
            onForward: () => _currentWebView()?.goForward(),
            onShare: _shareCurrentPage,
            onTabs: _openTabSwitcher,
            onMore: _openMoreMenu,
            tabCount: _tabManager.count,
          ),
        ],
      ),
    );
  }
}

/// 更多菜单底部弹窗：支持重力感应开启时长按拖拽排序。
class _MoreMenuSheet extends StatefulWidget {
  const _MoreMenuSheet({required this.items, required this.onTapItem});

  final List<Map<String, dynamic>> items;
  final void Function(String id) onTapItem;

  @override
  State<_MoreMenuSheet> createState() => _MoreMenuSheetState();
}

class _MoreMenuSheetState extends State<_MoreMenuSheet> {
  bool _adBlockEnabled = false;
  List<Map<String, dynamic>> _ordered = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final adBlock = await SettingsService.instance.isAdBlockEnabled();
    final order = await SettingsService.instance.getMenuOrder();
    if (!mounted) return;
    setState(() {
      _adBlockEnabled = adBlock;
      if (order.isNotEmpty) {
        final map = {for (final e in widget.items) e['id'] as String: e};
        _ordered = [
          for (final id in order)
            if (map.containsKey(id)) map[id]!,
          for (final e in widget.items)
            if (!order.contains(e['id'])) e,
        ];
      } else {
        _ordered = List.from(widget.items);
      }
    });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final item = _ordered.removeAt(oldIndex);
    _ordered.insert(newIndex, item);
    NativeBridge.hapticFeedback(style: 'medium');
    setState(() {});
    await SettingsService.instance
        .setMenuOrder(_ordered.map((e) => e['id'] as String).toList());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            // 广告拦截状态条
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _adBlockEnabled
                    ? const Color(0xFFE8F5E9)
                    : const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    _adBlockEnabled
                        ? Icons.verified_outlined
                        : Icons.info_outline,
                    size: 16,
                    color: _adBlockEnabled
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFE65100),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _adBlockEnabled ? '广告拦截已开启' : '广告拦截未开启',
                    style: TextStyle(
                      fontSize: 12,
                      color: _adBlockEnabled
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFE65100),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '长按拖拽可调整顺序',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _ordered.length,
                itemBuilder: (context, index) {
                  final item = _ordered[index];
                  return _sheetItem(
                    key: ValueKey(item['id']),
                    context: context,
                    icon: item['icon'] as IconData,
                    label: item['label'] as String,
                    onTap: () => widget.onTapItem(item['id'] as String),
                    reorderable: true,
                  );
                },
                onReorderItem: _onReorder,
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}


/// 更多菜单项（reorderable=true 时显示拖拽手柄）。
Widget _sheetItem({
  Key? key,
  required BuildContext context,
  required IconData icon,
  required String label,
  required VoidCallback onTap,
  bool reorderable = false,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return ListTile(
    key: key,
    leading: Icon(
      icon,
      size: 22,
      color: isDark ? const Color(0xFFD1D5DB) : const Color(0xFF374151),
    ),
    title: Text(
      label,
      style: TextStyle(
        fontSize: 15,
        color: isDark ? Colors.white : const Color(0xFF1F2937),
      ),
    ),
    trailing: reorderable
        ? const Icon(Icons.drag_handle, size: 20, color: Color(0xFFB0B7C3))
        : null,
    onTap: onTap,
  );
}
