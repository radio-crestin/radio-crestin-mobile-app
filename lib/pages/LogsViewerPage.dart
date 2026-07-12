import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/analytics_service.dart';
import '../services/local_log_store.dart';
import '../services/log_upload_service.dart';
import '../theme.dart';

/// Developer-mode viewer for the on-device log files ([LocalLogStore]).
///
/// Shows every record newest-first in a lazily built monospace list (the
/// store holds up to ~1.5MB, so one giant `Text` would jank), with
/// pull-to-refresh and app-bar actions to copy, share the raw files, and
/// upload them to PostHog.
class LogsViewerPage extends StatefulWidget {
  const LogsViewerPage({super.key});

  /// Pushes the viewer onto the navigation stack.
  static void show(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const LogsViewerPage()),
    );
  }

  @override
  State<LogsViewerPage> createState() => _LogsViewerPageState();
}

class _LogsViewerPageState extends State<LogsViewerPage> {
  List<String> _lines = const [];
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lines = <String>[];
    for (final file in await LocalLogStore.instance.collectLogFiles()) {
      // Files come newest-first; reverse each so lines are newest-first too.
      lines.addAll((await file.readAsLines()).reversed);
    }
    if (!mounted) return;
    setState(() {
      _lines = lines;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    final text = await LocalLogStore.instance.readRecent();
    if (text.isEmpty) {
      _showSnack('Niciun log de copiat');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('Loguri copiate');
  }

  Future<void> _share() async {
    final files = await LocalLogStore.instance.collectLogFiles();
    if (files.isEmpty) {
      _showSnack('Niciun log de distribuit');
      return;
    }
    await SharePlus.instance.share(ShareParams(
      files: [for (final f in files) XFile(f.path, mimeType: 'text/plain')],
      subject: 'Loguri Radio Crestin',
    ));
  }

  Future<void> _upload() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    final result = await LogUploadService.instance.upload(trigger: 'manual');
    if (!mounted) return;
    setState(() => _uploading = false);
    _showSnack(result.success
        ? 'Loguri trimise (${result.parts} părți)'
        : 'Trimiterea logurilor a eșuat. Încearcă din nou.');
    if (result.success) {
      AnalyticsService.instance
          .capture('button_clicked', {'button_name': 'logs_viewer_upload'});
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        duration: const Duration(seconds: 2),
        backgroundColor: AppColors.primaryDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        centerTitle: true,
        title: Text(
          'Loguri aplicație',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 22),
            tooltip: 'Reîncarcă',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: 'Copiază',
            onPressed: _copy,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share, size: 20),
            tooltip: 'Distribuie fișierele',
            onPressed: _share,
          ),
          IconButton(
            icon: _uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppColors.primary,
                    ),
                  )
                : const Icon(Icons.cloud_upload_outlined, size: 22),
            tooltip: 'Trimite către noi',
            onPressed: _uploading ? null : _upload,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.primary,
              ),
            )
          : _lines.isEmpty
              ? const Center(child: Text('Niciun log încă.'))
              : RefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _load,
                  child: SelectionArea(
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: _lines.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          _lines[index],
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.35,
                            color: isDark
                                ? const Color(0xffd0d0d0)
                                : const Color(0xff333333),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
    );
  }
}
