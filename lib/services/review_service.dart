import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:radio_crestin/constants.dart';

class ReviewService {
  static final Uri _reviewsUrl = Uri.parse(CONSTANTS.REVIEWS_URL);

  static Future<({bool success, String? error})> submitReview({
    required int stationId,
    required int stars,
    required String message,
    required String userIdentifier,
  }) async {
    try {
      final response = await http.post(
        _reviewsUrl,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'station_id': stationId,
          'message': message,
          'stars': stars,
          'user_identifier': userIdentifier,
        }),
      );

      if (response.statusCode != 200) {
        return (success: false, error: 'Eroare de rețea (${response.statusCode})');
      }

      final result = jsonDecode(response.body) as Map<String, dynamic>;

      final submitData = result['data']?['submit_review'] as Map<String, dynamic>?;
      if (submitData == null) {
        return (success: false, error: 'A apărut o eroare la trimiterea recenziei');
      }

      if (submitData['__typename'] == 'OperationInfo') {
        final messages = submitData['messages'] as List?;
        return (
          success: false,
          error: messages?.isNotEmpty == true
              ? messages![0]['message'] as String?
              : 'A apărut o eroare la trimiterea recenziei',
        );
      }

      return (success: true, error: null);
    } catch (e) {
      developer.log("ReviewService: submitReview error: $e");
      return (success: false, error: 'A apărut o eroare. Vă rugăm încercați din nou.');
    }
  }
}
