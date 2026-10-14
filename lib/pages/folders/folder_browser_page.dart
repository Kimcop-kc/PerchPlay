import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';

class FolderBrowserPage extends StatefulWidget {
  const FolderBrowserPage({super.key});

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  String _currentPath = '';
  List<FileSystemEntity> _entries = [];
  bool _loading = true;
  bool _gridView = true;

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  Future<void> _loadRoots() async {
    setState(() => _loading = true);
    try {
      // 列出可用存储根目录
      final dirs = <FileSystemEntity>[];
      // 内置存储
      final storage = Directory('/storage/emulated/0');
      if (await storage.exists()) dirs.add(storage);
      // /sdcard
      final sdcard = Directory('/sdcard');
      if (await sdcard.exists()) dirs.add(sdcard);
      // 应用文档目录
      dirs.add(Directory('/data/data/com.vidflow.player'));
      
      setState(() {
        _entries = dirs;
        _currentPath = '';
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<void> _navigate(String path) async {
    setState(() => _loading = true);
    try {
      final dir = Directory(path);
      _entries = await dir.list().toList();
      // 排序：文件夹在前，名称 A-Z
      _entries.sort((a, b) {
        final aDir = a is Directory ? 0 : 1;
        final bDir = b is Directory ? 0 : 1;
        if (aDir != bDir) return aDir - bDir;
        return a.path.compareTo(b.path);
      });
      _currentPath = path;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法访问: $e')),
        );
      }
    }
    setState(() => _loading = false);
  }

  void _navigateUp() {
    if (_currentPath.isEmpty) return;
    final parent = Directory(_currentPath).parent.path;
    if (parent == _currentPath) {
      _loadRoots();
    } else {
      _navigate(parent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return GlassPanel(
      radius: 0,
      showShadow: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (_currentPath.isNotEmpty)
            GlassButton(
              icon: Icons.arrow_back_rounded,
              compact: true,
              ghost: true,
              onTap: _navigateUp,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _currentPath.isEmpty ? '文件夹' : _currentPath.split('/').last,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GlassButton(
            icon: _gridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
            compact: true,
            ghost: true,
            foregroundColor: Colors.white54,
            onTap: () => setState(() => _gridView = !_gridView),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: GlassTheme.accentPurple),
      );
    }
    if (_currentPath.isNotEmpty) {
      // 面包屑路径
      return Column(
        children: [
          _buildBreadcrumb(),
          Expanded(
            child: _gridView ? _buildGridView() : _buildListView(),
          ),
        ],
      );
    }
    return _buildGridView();
  }

  Widget _buildBreadcrumb() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            GestureDetector(
              onTap: _loadRoots,
              child: const Icon(Icons.folder_rounded, size: 14, color: Colors.white38),
            ),
            ...parts.asMap().entries.map((e) {
              final path = '/' + parts.sublist(0, e.key + 1).join('/');
              return Row(
                children: [
                  const Icon(Icons.chevron_right_rounded, size: 14, color: Colors.white24),
                  GestureDetector(
                    onTap: () => _navigate(path),
                    child: Text(e.value,
                        style: TextStyle(
                            color: e.key == parts.length - 1
                                ? GlassTheme.accentPurple
                                : Colors.white54,
                            fontSize: 12)),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.85,
      ),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final isDir = entry is Directory;
        final isVideo = _isVideoFile(entry.path);

        return GlassCard(
          radius: GlassTheme.radiusLg,
          padding: const EdgeInsets.all(12),
          tint: isDir ? GlassTheme.tintTeal : GlassTheme.tintPurple,
          onTap: () {
            if (isDir) {
              _navigate(entry.path);
            } else if (isVideo) {
              context.pushNamed('player', extra: {
                'videoPath': entry.path,
                'videoTitle': entry.path.split('/').last,
              });
            }
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isDir
                    ? Icons.folder_rounded
                    : (isVideo ? Icons.play_circle_rounded : Icons.insert_drive_file_rounded),
                size: 40,
                color: isDir
                    ? GlassTheme.accentTeal.withOpacity(0.8)
                    : (isVideo ? GlassTheme.accentPurple : Colors.white38),
              ),
              const SizedBox(height: 8),
              Text(
                entry.path.split('/').last,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildListView() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final isDir = entry is Directory;
        final isVideo = _isVideoFile(entry.path);

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GlassCard(
            radius: GlassTheme.radiusSm,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onTap: () {
              if (isDir) {
                _navigate(entry.path);
              } else if (isVideo) {
                context.pushNamed('player', extra: {
                  'videoPath': entry.path,
                  'videoTitle': entry.path.split('/').last,
                });
              }
            },
            child: Row(
              children: [
                Icon(
                  isDir ? Icons.folder_rounded : Icons.movie_rounded,
                  size: 22,
                  color: isDir ? GlassTheme.accentTeal : GlassTheme.accentPurple,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(entry.path.split('/').last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14)),
                ),
                if (isDir)
                  const Icon(Icons.chevron_right_rounded, color: Colors.white24),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _isVideoFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['mp4', 'mkv', 'avi', 'mov', 'm4v', 'webm', 'wmv', 'flv', 'ts']
        .contains(ext);
  }
}