class CONSTANTS {
  static String GRAPHQL_ENDPOINT = "https://api.radiocrestin.ro/v1/graphql";
  static String GRAPHQL_AUTH = "Token public";
  static String API_BASE_URL = "https://api.radiocrestin.ro/api/v1";
  static String STATIONS_URL = "$API_BASE_URL/stations";
  // Device-allowlisted ("private") stations. Append
  // "?device_id=<id>&timestamp=<ts>" where ts is unix-now floored to 60s (see
  // getRoundedTimestamp60s). Returns the same station shape as STATIONS_URL but
  // with NO station_groups block; unknown/allowlist-less devices get an empty
  // list. This payload is the sole metadata source for private stations —
  // /stations-metadata only carries public stations.
  static String PRIVATE_STATIONS_URL = "$API_BASE_URL/private-stations";
  static String STATIONS_METADATA_URL = "$API_BASE_URL/stations-metadata";
  static String STATIONS_METADATA_HISTORY_URL = "$API_BASE_URL/stations-metadata-history";
  // Live playlist for a single "playlist" station. Polled every 5s while a
  // playlist station is on screen; append "?station_slug=<slug>&timestamp=<ts>"
  // where ts is unix-now floored to 5s (see getRoundedTimestamp5s).
  static String STATION_PLAYLIST_URL = "$API_BASE_URL/station-playlist";
  static String SHARE_LINKS_URL = "$API_BASE_URL/share-links";
  static String REVIEWS_URL = "$API_BASE_URL/reviews/";
  // Device/client registration upsert. Trailing slash is required so Django's
  // APPEND_SLASH never 301-redirects the POST (which would drop the body).
  static String DEVICE_REGISTER_URL = "$API_BASE_URL/devices/register/";
  static String DEFAULT_STATION_THUMBNAIL_URL = "";
  static String IMAGE_PROXY_PREFIX = "";
  static String STATIC_MP3_URL =
      "https://radio-crestin.s3.eu-central-1.amazonaws.com/media/public/simple_mp3_audio.mp3";
}
