import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:radio_crestin/constants.dart';

class ReviewService {
  static const _submitReviewMutation = '''
mutation SubmitReview(\$message: String = "", \$stars: Int = 5, \$station_id: Int = 0, \$user_identifier: String = "") {
  submit_review(
    input: {station_id: \$station_id, message: \$message, stars: \$stars, user_identifier: \$user_identifier}
  ) {
    ... on SubmitReviewResponse {
      __typename
      created
      message
      success
      review {
        id
        message
        stars
        created_at
        station_id
        updated_at
        user_identifier
        verified
      }
    }
    ... on OperationInfo {
      __typename
      messages {
        code
        field
        kind
        message
      }
    }
  }
}
''';

  static Future<({bool success, String? error})> submitReview({
    required int stationId,
    required int stars,
    required String message,
    required String userIdentifier,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(CONSTANTS.GRAPHQL_ENDPOINT),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'query': _submitReviewMutation,
          'variables': {
            'station_id': stationId,
            'message': message,
            'stars': stars,
            'user_identifier': userIdentifier,
          },
        }),
      );

      if (response.statusCode != 200) {
        return (success: false, error: 'Eroare de rețea (${response.statusCode})');
      }

      final result = jsonDecode(response.body) as Map<String, dynamic>;

      if (result['errors'] != null) {
        final errors = result['errors'] as List;
        return (
          success: false,
          error: errors.isNotEmpty
              ? errors[0]['message'] as String?
              : 'A apărut o eroare la trimiterea recenziei',
        );
      }

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
