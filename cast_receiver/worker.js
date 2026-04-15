/**
 * Cloudflare Worker for cast.radiocrestin.ro
 *
 * Serves the Google Cast Custom Web Receiver for Radio Creștin.
 * Deploy: wrangler deploy
 * Route: cast.radiocrestin.ro/*
 *
 * No secrets needed — this is a public static HTML page loaded by Chromecast.
 */

const RECEIVER_HTML = `<!DOCTYPE html>
<html lang="ro">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Radio Cre\u0219tin</title>
  <script src="//www.gstatic.com/cast/sdk/libs/caf_receiver/v3/cast_receiver_framework.js"><\/script>
  <style>
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      width: 100vw;
      height: 100vh;
      overflow: hidden;
      background: #121212;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      color: #fff;
    }

    cast-media-player {
      --background-image: none;
      --logo-image: none;
      --watermark-image: none;
      --background-color: #121212;
      --playback-logo-image: none;
      --theme-hue: 327;
      --progress-color: #E91E63;
      --splash-image: none;
      --splash-size: 0;
      position: fixed;
      top: 0; left: 0;
      width: 100%; height: 100%;
      z-index: 0;
      opacity: 0;
    }

    .bg-artwork {
      position: fixed;
      inset: -40px;
      background-size: cover;
      background-position: center;
      filter: blur(50px) saturate(1.3);
      transform: scale(1.15);
      transition: background-image 0.8s ease-in-out;
      z-index: 1;
    }

    .bg-gradient {
      position: fixed;
      inset: 0;
      background: linear-gradient(
        180deg,
        rgba(0,0,0,0.15) 0%,
        rgba(0,0,0,0.35) 35%,
        rgba(0,0,0,0.75) 70%,
        rgba(0,0,0,0.90) 100%
      );
      z-index: 2;
    }

    .content {
      position: relative;
      z-index: 3;
      width: 100%;
      height: 100%;
      display: flex;
      align-items: flex-end;
      padding: 60px 80px;
    }

    .player-card {
      display: flex;
      align-items: center;
      gap: 40px;
      max-width: 900px;
    }

    .artwork-container {
      flex-shrink: 0;
      width: 200px;
      height: 200px;
      border-radius: 20px;
      overflow: hidden;
      box-shadow: 0 20px 60px rgba(0,0,0,0.5);
    }

    .artwork-container img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      transition: opacity 0.5s ease;
    }

    .metadata {
      display: flex;
      flex-direction: column;
      gap: 8px;
      min-width: 0;
    }

    .station-name {
      font-size: 42px;
      font-weight: 800;
      letter-spacing: -0.5px;
      line-height: 1.1;
      text-shadow: 0 2px 20px rgba(0,0,0,0.5);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .song-title {
      font-size: 24px;
      font-weight: 500;
      opacity: 0.85;
      text-shadow: 0 1px 10px rgba(0,0,0,0.4);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .song-artist {
      font-size: 20px;
      font-weight: 400;
      opacity: 0.6;
      text-shadow: 0 1px 8px rgba(0,0,0,0.3);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .live-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      margin-top: 8px;
      width: fit-content;
    }

    .live-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #E91E63;
      animation: pulse 2s ease-in-out infinite;
    }

    .live-text {
      font-size: 14px;
      font-weight: 700;
      letter-spacing: 2px;
      text-transform: uppercase;
      opacity: 0.7;
    }

    @keyframes pulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.5; transform: scale(0.85); }
    }

    .logo {
      position: fixed;
      top: 40px;
      right: 60px;
      z-index: 4;
      display: flex;
      align-items: center;
      gap: 12px;
      opacity: 0.7;
    }

    .logo-text {
      font-size: 18px;
      font-weight: 700;
      letter-spacing: 0.5px;
    }

    .idle-screen {
      position: fixed;
      inset: 0;
      z-index: 10;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      background: linear-gradient(135deg, #1a0a10, #2d0e1e, #121212);
      transition: opacity 0.6s ease;
    }

    .idle-screen.hidden {
      opacity: 0;
      pointer-events: none;
    }

    .idle-title {
      font-size: 36px;
      font-weight: 800;
    }

    .idle-subtitle {
      font-size: 18px;
      opacity: 0.5;
      margin-top: 8px;
    }

    #debug {
      position: fixed;
      bottom: 10px;
      left: 10px;
      z-index: 100;
      font-size: 11px;
      color: rgba(255,255,255,0.5);
      font-family: monospace;
      max-width: 80%;
      word-break: break-all;
    }
  </style>
</head>
<body>
  <cast-media-player></cast-media-player>

  <div id="idle-screen" class="idle-screen">
    <div class="idle-title">Radio Cre\u0219tin</div>
    <div class="idle-subtitle">Se conecteaz\u0103...</div>
  </div>

  <div id="bg-artwork" class="bg-artwork"></div>
  <div class="bg-gradient"></div>

  <div class="logo">
    <span class="logo-text">Radio Cre\u0219tin</span>
  </div>

  <div class="content">
    <div class="player-card">
      <div class="artwork-container">
        <img id="artwork" src="" alt="">
      </div>
      <div class="metadata">
        <div id="station-name" class="station-name"></div>
        <div id="song-title" class="song-title"></div>
        <div id="song-artist" class="song-artist"></div>
        <div class="live-badge">
          <div class="live-dot"></div>
          <span class="live-text">Live</span>
        </div>
      </div>
    </div>
  </div>

  <div id="debug"></div>

  <script>
    var debugEl = document.getElementById('debug');
    function dbg(msg) {
      console.log('[RC] ' + msg);
      if (debugEl) debugEl.textContent = msg;
    }

    dbg('Receiver loading...');

    var context = cast.framework.CastReceiverContext.getInstance();
    var playerManager = context.getPlayerManager();

    var stationNameEl = document.getElementById('station-name');
    var songTitleEl = document.getElementById('song-title');
    var songArtistEl = document.getElementById('song-artist');
    var artworkEl = document.getElementById('artwork');
    var bgArtworkEl = document.getElementById('bg-artwork');
    var idleScreen = document.getElementById('idle-screen');

    function updateUI(metadata, source) {
      if (!metadata) { dbg(source + ': null metadata'); return; }

      var title = metadata.title || '';
      var artist = metadata.artist || '';
      var albumName = metadata.albumName || '';
      var imageUrl = '';
      var images = metadata.images;
      if (images && images.length > 0) {
        var img = images[0];
        imageUrl = (typeof img === 'string') ? img : (img.url || '');
      }

      dbg(source + ': t=' + title + ' ar=' + artist + ' al=' + albumName);

      if (!title && !artist && !albumName && !imageUrl) return;

      stationNameEl.textContent = albumName || title;
      songTitleEl.textContent = title;
      songArtistEl.textContent = artist;

      if (imageUrl && artworkEl.src !== imageUrl) {
        artworkEl.src = imageUrl;
        bgArtworkEl.style.backgroundImage = 'url(' + imageUrl + ')';
      }
      idleScreen.classList.add('hidden');
    }

    playerManager.setMessageInterceptor(
      cast.framework.messages.MessageType.LOAD,
      function(request) {
        try {
          dbg('LOAD: ' + (request.media ? request.media.contentId : 'no media'));
          if (request.media && request.media.metadata) {
            updateUI(request.media.metadata, 'LOAD');
          }
        } catch(e) { dbg('LOAD err: ' + e.message); }
        return request;
      }
    );

    playerManager.addEventListener(
      cast.framework.events.EventType.PLAYER_LOAD_COMPLETE,
      function() {
        dbg('LOAD_COMPLETE');
        var mi = playerManager.getMediaInformation();
        if (mi && mi.metadata) updateUI(mi.metadata, 'COMPLETE');
      }
    );

    playerManager.addEventListener(
      cast.framework.events.EventType.MEDIA_STATUS,
      function() {
        var s = playerManager.getPlayerState();
        dbg('STATUS: ' + s);
        var mi = playerManager.getMediaInformation();
        if (mi && mi.metadata) updateUI(mi.metadata, 'STATUS');
      }
    );

    playerManager.addEventListener(
      cast.framework.events.EventType.ERROR,
      function(event) { dbg('ERROR: ' + JSON.stringify(event)); }
    );

    playerManager.addEventListener(
      cast.framework.events.EventType.MEDIA_FINISHED,
      function() { dbg('FINISHED'); idleScreen.classList.remove('hidden'); }
    );

    dbg('Starting...');
    var options = new cast.framework.CastReceiverOptions();
    options.disableIdleTimeout = true;
    context.start(options);
    dbg('Started');
  <\/script>
</body>
</html>`;

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === '/health') {
      return new Response('ok', { status: 200 });
    }

    // Serve receiver HTML for all paths (Chromecast loads the root)
    return new Response(RECEIVER_HTML, {
      status: 200,
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-cache',
        'Access-Control-Allow-Origin': '*',
      },
    });
  },
};
