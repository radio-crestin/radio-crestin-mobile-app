import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/review_service.dart';
import 'package:radio_crestin/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReviewModal extends StatefulWidget {
  final int stationId;
  final String stationTitle;
  final int? songId;
  final String? songTitle;
  final String? songArtist;
  final int initialStars;

  const ReviewModal({
    super.key,
    required this.stationId,
    required this.stationTitle,
    this.songId,
    this.songTitle,
    this.songArtist,
    this.initialStars = 0,
  });

  static Future<bool?> show(
    BuildContext context, {
    required int stationId,
    required String stationTitle,
    int? songId,
    String? songTitle,
    String? songArtist,
    int initialStars = 0,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ReviewModal(
        stationId: stationId,
        stationTitle: stationTitle,
        songId: songId,
        songTitle: songTitle,
        songArtist: songArtist,
        initialStars: initialStars,
      ),
    );
  }

  @override
  State<ReviewModal> createState() => _ReviewModalState();
}

class _ReviewModalState extends State<ReviewModal> {
  late int _selectedStars = widget.initialStars;
  final _messageController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // Auto-submit immediately when opened with prefilled stars
    if (widget.initialStars > 0) {
      _submitSilently();
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  String _getUserIdentifier() {
    final prefs = GetIt.instance<SharedPreferences>();
    var userId = prefs.getString('radio_crestin_user_id');
    if (userId == null) {
      userId = 'user_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
      prefs.setString('radio_crestin_user_id', userId);
    }
    return userId;
  }

  void _showToast(String msg, {bool isError = false}) {
    Fluttertoast.showToast(
      msg: msg,
      toastLength: isError ? Toast.LENGTH_LONG : Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      backgroundColor: isError ? AppColors.error : AppColors.primaryDark,
      textColor: Colors.white,
      fontSize: 14.0,
    );
  }

  /// Submit silently in the background (no loading state, no toast, no close).
  /// Used for the auto-submit when the modal opens.
  Future<void> _submitSilently() async {
    if (_selectedStars == 0) return;
    try {
      await ReviewService.submitReview(
        stationId: widget.stationId,
        stars: _selectedStars,
        message: '',
        userIdentifier: _getUserIdentifier(),
        songId: widget.songId,
      );
    } catch (_) {
      // Silently ignore — user can still submit manually via the button
    }
  }

  /// Submit with UI feedback — overrides the previous silent submission.
  Future<void> _submit() async {
    if (_selectedStars == 0 || _isSubmitting) return;

    setState(() => _isSubmitting = true);

    try {
      final result = await ReviewService.submitReview(
        stationId: widget.stationId,
        stars: _selectedStars,
        message: _messageController.text.trim(),
        userIdentifier: _getUserIdentifier(),
        songId: widget.songId,
      );

      if (!mounted) return;
      setState(() => _isSubmitting = false);

      if (result.success) {
        AnalyticsService.instance.trackReviewSubmitted(
          stationId: widget.stationId,
          stationName: widget.stationTitle,
          stars: _selectedStars,
          songId: widget.songId,
          hasMessage: _messageController.text.trim().isNotEmpty,
        );
        _showToast('Recenzia a fost trimisă cu succes!');
        Navigator.of(context).pop(true);
      } else {
        _showToast(result.error ?? 'A apărut o eroare la trimiterea recenziei', isError: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showToast('Eroare de conexiune. Verifică internetul și încearcă din nou.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Header
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Adaugă o recenzie',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 20,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.stationTitle,
                            style: TextStyle(
                              fontSize: 14,
                              color: isDark ? Colors.white54 : Colors.black54,
                            ),
                          ),
                          if (widget.songTitle != null && widget.songTitle!.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.06)
                                    : Colors.black.withValues(alpha: 0.04),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.music_note_rounded,
                                    size: 14,
                                    color: AppColors.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      widget.songArtist != null && widget.songArtist!.isNotEmpty
                                          ? '${widget.songTitle} - ${widget.songArtist}'
                                          : widget.songTitle!,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: isDark ? Colors.white70 : Colors.black54,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, size: 22, color: theme.colorScheme.onSurfaceVariant),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Message section
                Text(
                  'Mesaj (opțional)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _messageController,
                  onChanged: (_) => setState(() {}),
                  maxLength: 500,
                  maxLines: 4,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Spune-ne părerea ta despre această melodie...',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white24 : Colors.black26,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.03),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: isDark ? Colors.white10 : Colors.black12,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: isDark ? Colors.white10 : Colors.black12,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.all(14),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Recenziile vor fi vizibile tuturor utilizatorilor aplicației.',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white30 : Colors.black26,
                        ),
                      ),
                    ),
                    Text(
                      '${_messageController.text.length}/500',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white30 : Colors.black26,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Submit button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: !_isSubmitting ? _submit : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      disabledBackgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.06),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Trimite mesajul',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
