import 'package:flutter/material.dart';

class ConnectivityBanner extends StatelessWidget {
  final bool isOffline;
  final bool showBackOnline;

  const ConnectivityBanner({
    super.key,
    required this.isOffline,
    required this.showBackOnline,
  });

  @override
  Widget build(BuildContext context) {
    if (isOffline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            decoration: const BoxDecoration(
              color: Color(0xFFBF360C),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.wifi_off, size: 16, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  'Fără conexiune la internet',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1, thickness: 0.5),
        ],
      );
    }
    if (showBackOnline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            decoration: const BoxDecoration(
              color: Color(0xFF2E7D32),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.wifi, size: 16, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  'Conexiune la internet restabilită',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1, thickness: 0.5),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}
