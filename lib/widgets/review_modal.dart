import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/services/review_service.dart';
import 'package:radio_crestin/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReviewModal extends StatefulWidget {
  final int stationId;
  final String stationTitle;

  const ReviewModal({
    super.key,
    required this.stationId,
    required this.stationTitle,
  });

  static Future<bool?> show(
    BuildContext context, {
    required int stationId,
    required String stationTitle,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ReviewModal(
        stationId: stationId,
        stationTitle: stationTitle,
      ),
    );
  }

  @override
  State<ReviewModal> createState() => _ReviewModalState();
}

class _ReviewModalState extends State<ReviewModal> {
  int _selectedStars = 0;
  final _messageController = TextEditingController();
  bool _isSubmitting = false;

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

  Future<void> _submit() async {
    if (_selectedStars == 0 || _isSubmitting) return;

    setState(() => _isSubmitting = true);

    final result = await ReviewService.submitReview(
      stationId: widget.stationId,
      stars: _selectedStars,
      message: _messageController.text.trim(),
      userIdentifier: _getUserIdentifier(),
    );

    if (!mounted) return;

    setState(() => _isSubmitting = false);

    if (result.success) {
      Fluttertoast.showToast(
        msg: 'Recenzia a fost trimisă cu succes!',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.green.shade700,
        textColor: Colors.white,
      );
      Navigator.of(context).pop(true);
    } else {
      Fluttertoast.showToast(
        msg: result.error ?? 'A apărut o eroare',
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.red.shade700,
        textColor: Colors.white,
      );
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
                // Stars section
                Text(
                  'Evaluarea ta',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final starIndex = index + 1;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedStars = starIndex),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                          starIndex <= _selectedStars
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 40,
                          color: starIndex <= _selectedStars
                              ? const Color(0xFFED8A19)
                              : isDark ? Colors.white24 : Colors.black26,
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    _selectedStars == 0
                        ? 'Selectează o evaluare'
                        : '$_selectedStars ${_selectedStars == 1 ? 'stea' : 'stele'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Message section
                Text(
                  'Mesaj',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _messageController,
                  maxLength: 500,
                  maxLines: 4,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Spune-ne părerea ta despre acest radio...',
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
                    counterStyle: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white30 : Colors.black26,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Submit button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _selectedStars > 0 && !_isSubmitting ? _submit : null,
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
