import 'package:flutter/material.dart';
import 'widgets/edge_back_gesture.dart';

import '../../core/db/database_helper.dart';
import '../../core/models/bookmark.dart';

/// 书签页：查看 / 打开 / 删除书签（打开时 pop 返回 url）。
class BookmarksPage extends StatefulWidget {
  const BookmarksPage({super.key});

  @override
  State<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends State<BookmarksPage> {
  List<Bookmark> _bookmarks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await DatabaseHelper.instance.initDefaultBookmarks();
    final list = await DatabaseHelper.instance.getBookmarks();
    if (!mounted) return;
    setState(() {
      _bookmarks = list;
      _loading = false;
    });
  }

  Future<void> _delete(Bookmark bookmark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书签'),
        content: Text('确定删除「${bookmark.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFEA6668))),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DatabaseHelper.instance.deleteBookmark(bookmark.id!);
    _load();
  }

  void _showActionMenu(Bookmark bookmark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Color(0xFF3B82F6)),
              title: const Text('编辑'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _edit(bookmark);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFEA6668)),
              title: const Text('删除', style: TextStyle(color: Color(0xFFEA6668))),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _delete(bookmark);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(Bookmark bookmark) async {
    final titleController = TextEditingController(text: bookmark.title);
    final urlController = TextEditingController(text: bookmark.url);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑书签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: '名称',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '网址',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final title = titleController.text.trim();
    final url = urlController.text.trim();
    if (title.isEmpty || url.isEmpty) return;
    await DatabaseHelper.instance.updateBookmark(bookmark.id!, title, url);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return EdgeBackGesture(child: Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '书签',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _bookmarks.isEmpty
              ? const Center(
                  child: Text(
                    '暂无书签，可在菜单中「添加到书签」',
                    style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
                  ),
                )
              : ListView.separated(
                  itemCount: _bookmarks.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 68, color: Color(0xFFEDEFF3)),
                  itemBuilder: (context, index) {
                    final bookmark = _bookmarks[index];
                    return ListTile(
                      onTap: () => Navigator.of(context).pop(bookmark.url),
                      onLongPress: () => _showActionMenu(bookmark),
                      leading: _Favicon(title: bookmark.title),
                      title: Text(
                        bookmark.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        bookmark.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                      ),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz, size: 18, color: Color(0xFFB0B7C3)),
                        onSelected: (value) {
                          if (value == 'edit') _edit(bookmark);
                          if (value == 'delete') _delete(bookmark);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: Color(0xFFEA6668)))),
                        ],
                      ),
                    );
                  },
                ),
    ));
  }
}

class _Favicon extends StatelessWidget {
  const _Favicon({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final t = title.trim();
    final initial = t.isEmpty ? '网' : t.characters.first.toUpperCase();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF3B82F6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
