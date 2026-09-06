import 'package:flutter/material.dart';

import '../../core/db/database_helper.dart';
import '../../core/models/bookmark.dart';
import '../../core/models/history_entry.dart';
import '../../core/services/settings_service.dart';

/// 新标签页：搜索框 + 快捷方式 + 最近访问。
class NewTabPage extends StatefulWidget {
  const NewTabPage({super.key, required this.onLoadUrl});

  /// 用户点击快捷方式/搜索后回调，加载指定 URL。
  final ValueChanged<String> onLoadUrl;

  @override
  State<NewTabPage> createState() => _NewTabPageState();
}

class _NewTabPageState extends State<NewTabPage> {
  final TextEditingController _searchController = TextEditingController();
  List<Bookmark> _shortcuts = [];
  List<HistoryEntry> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bookmarks = await DatabaseHelper.instance.getBookmarks();
    final history = await DatabaseHelper.instance.getHistory(limit: 6);
    if (!mounted) return;
    setState(() {
      _shortcuts = bookmarks.take(8).toList();
      _recent = history;
      _loading = false;
    });
  }

  Future<void> _submit(String input) async {
    final text = input.trim();
    if (text.isEmpty) return;
    final engine = await SettingsService.instance.getSearchEngine();
    final searchUrl = SettingsService.searchUrlOf(engine);
    // 是网址则直接打开，否则搜索
    final isUrl = RegExp(r'^(https?://|www\.)', caseSensitive: false)
            .hasMatch(text) ||
        text.contains('.') && !text.contains(' ');
    final url = isUrl
        ? (text.startsWith('http') ? text : 'https://$text')
        : '$searchUrl${Uri.encodeComponent(text)}';
    widget.onLoadUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF5F6F8);
    final cardColor = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1F2937);
    final subColor = isDark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);

    return Container(
      color: bgColor,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
          child: Column(
            children: [
              // 搜索框
              Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(fontSize: 16, color: textColor),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜索或输入网址',
                    hintStyle: TextStyle(fontSize: 15, color: subColor),
                    prefixIcon: Icon(Icons.search, color: subColor, size: 20),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                  onSubmitted: _submit,
                ),
              ),
              const SizedBox(height: 32),

              // 快捷方式
              if (_shortcuts.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '快捷方式',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: subColor),
                  ),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: _shortcuts.length,
                  itemBuilder: (context, index) {
                    final bm = _shortcuts[index];
                    return GestureDetector(
                      onTap: () => widget.onLoadUrl(bm.url),
                      child: Column(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Text(
                              bm.title.isEmpty
                                  ? '网'
                                  : bm.title.characters.first.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF3B82F6),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            bm.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: textColor),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 28),
              ],

              // 最近访问
              if (_recent.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '最近访问',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: subColor),
                  ),
                ),
                const SizedBox(height: 8),
                ..._recent.map((h) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.history, size: 18, color: subColor),
                      title: Text(
                        h.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: textColor),
                      ),
                      subtitle: Text(
                        h.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: subColor),
                      ),
                      onTap: () => widget.onLoadUrl(h.url),
                    )),
              ],

              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
