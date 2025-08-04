import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SharePromotionCard extends StatefulWidget {
  final GraphQLClient client;
  final String? currentStationSlug;

  const SharePromotionCard({
    Key? key,
    required this.client,
    this.currentStationSlug,
  }) : super(key: key);

  @override
  State<SharePromotionCard> createState() => _SharePromotionCardState();
}

class _SharePromotionCardState extends State<SharePromotionCard> {
  ShareLinkData? _shareLinkData;
  bool _isLoading = true;
  String? _anonymousId;

  @override
  void initState() {
    super.initState();
    _loadShareLink();
  }

  Future<void> _loadShareLink() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _anonymousId = prefs.getString('anonymous_id');
      
      if (_anonymousId == null) {
        _anonymousId = DateTime.now().millisecondsSinceEpoch.toString();
        await prefs.setString('anonymous_id', _anonymousId!);
      }

      final shareService = ShareService(widget.client);
      final data = await shareService.getShareLink(_anonymousId!);
      
      if (mounted) {
        setState(() {
          _shareLinkData = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading share link: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).primaryColor.withOpacity(0.1),
              Theme.of(context).primaryColor.withOpacity(0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Theme.of(context).primaryColor.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_shareLinkData == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () {
        final shareUrl = _shareLinkData!.generateShareUrl(
          stationSlug: widget.currentStationSlug,
        );
        ShareHandler.shareApp(
          context: context,
          shareUrl: shareUrl,
          shareMessage: _shareLinkData!.shareMessage,
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).primaryColor.withOpacity(0.1),
              Theme.of(context).primaryColor.withOpacity(0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Theme.of(context).primaryColor.withOpacity(0.2),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.share_rounded,
                color: Theme.of(context).primaryColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _shareLinkData?.shareSectionTitle ?? 'Distribuie aplicația',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _shareLinkData!.shareSectionMessage.isNotEmpty 
                      ? _shareLinkData!.shareSectionMessage
                      : 'Ajută la răspândirea Evangheliei prin intermediul radioului creștin. Apasă aici pentru a trimite această aplicație prietenilor tăi.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      height: 1.4,
                    ),
                  ),
                  if (_shareLinkData != null && _shareLinkData!.visitCount > 0) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 14,
                            color: Theme.of(context).primaryColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${_shareLinkData!.visitCount} ${_shareLinkData!.visitCount == 1 ? 'ascultător' : 'ascultători'}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: Theme.of(context).primaryColor.withOpacity(0.5),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }
}