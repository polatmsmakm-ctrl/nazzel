/*
 * Nazzel page helper, injected into every page of the in-app browser.
 *  1. Adds a download button to every video / post the page shows.
 *  2. Skips YouTube video ads and hides sponsored posts (if ad blocking is on).
 * Talks to the app through window.webkit.messageHandlers.nazzel.
 */
(function () {
  'use strict';
  if (window.__nazzelLoaded) return;
  window.__nazzelLoaded = true;

  var CFG = window.__nazzelConfig || { badges: true, adblock: true };
  var host = location.hostname.replace(/^www\.|^m\./, '');
  var send = function (msg) {
    try { window.webkit.messageHandlers.nazzel.postMessage(msg); } catch (e) {}
  };

  // ---------------------------------------------------------------- sites
  var SITES = [
    { test: /(^|\.)youtube\.com$/, link: /\/(watch\?v=|shorts\/)[\w-]+/ },
    { test: /(^|\.)instagram\.com$/, link: /\/(p|reel|reels|tv)\/[\w-]+/, container: 'article' },
    { test: /(^|\.)tiktok\.com$/, link: /\/(video|photo)\/\d+/ },
    { test: /(^|\.)(x|twitter)\.com$/, link: /\/status\/\d+/, container: 'article' },
    { test: /(^|\.)facebook\.com$/, link: /\/(reel|videos|watch|share\/[rv]|posts|photo)[\/?]/, container: '[role="article"], article' },
    { test: /(^|\.)reddit\.com$/, link: /\/comments\/\w+/, container: 'shreddit-post, article' },
    { test: /(^|\.)pinterest\.[a-z.]+$/, link: /\/pin\/\d+/ },
    { test: /(^|\.)snapchat\.com$/, link: /\/(spotlight|p|add)\// },
    { test: /(^|\.)threads\.(net|com)$/, link: /\/post\/[\w-]+/ },
    { test: /(^|\.)vimeo\.com$/, link: /vimeo\.com\/\d+/ },
    { test: /(^|\.)dailymotion\.com$/, link: /\/video\/\w+/ },
    { test: /(^|\.)twitch\.tv$/, link: /\/(videos|clip)\/[\w-]+/ },
    { test: /(^|\.)soundcloud\.com$/, link: /soundcloud\.com\/[\w-]+\/[\w-]+$/ }
  ];
  var site = null;
  for (var i = 0; i < SITES.length; i++) {
    if (SITES[i].test.test(host)) { site = SITES[i]; break; }
  }

  // ---------------------------------------------------------------- styles
  var css = '' +
    '.nz-dl{position:absolute;top:8px;left:8px;z-index:2147483000;width:34px;height:34px;border-radius:17px;' +
    'background:rgba(13,148,136,.94);box-shadow:0 2px 8px rgba(0,0,0,.35);display:flex;align-items:center;' +
    'justify-content:center;cursor:pointer;-webkit-tap-highlight-color:transparent;transition:transform .15s}' +
    '.nz-dl:active{transform:scale(.88)}' +
    '.nz-dl svg{width:18px;height:18px;fill:none;stroke:#fff;stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round}' +
    '.nz-dl.nz-done{background:rgba(22,163,74,.95)}' +
    '.nz-host{position:relative!important}';

  if (CFG.adblock) {
    css += '' +
      // YouTube (mobile + desktop)
      'ytm-promoted-sparkles-web-renderer,ytm-promoted-video-renderer,ytm-companion-ad-renderer,' +
      'ytm-ad-slot-renderer,ad-slot-renderer,ytd-ad-slot-renderer,ytd-in-feed-ad-layout-renderer,' +
      'ytd-promoted-sparkles-web-renderer,ytd-display-ad-renderer,ytd-companion-slot-renderer,' +
      'ytd-action-companion-ad-renderer,ytd-banner-promo-renderer,ytd-statement-banner-renderer,' +
      'ytd-player-legacy-desktop-watch-ads-renderer,#player-ads,#masthead-ad,.ytp-ad-overlay-container,' +
      '.ytp-ad-image-overlay,.ytp-ad-text-overlay,ytm-paid-content-overlay-renderer,ytm-mealbar-promo-renderer,' +
      'ytm-statement-banner-renderer,ytd-enforcement-message-view-model,ytm-promoted-sparkles-text-search-renderer,' +
      '.ytd-merch-shelf-renderer,ytd-merch-shelf-renderer,ytm-rich-item-renderer:has(ytm-ad-slot-renderer),' +
      'ytd-rich-item-renderer:has(ytd-ad-slot-renderer),' +
      // generic
      'ins.adsbygoogle,iframe[id^="google_ads_iframe"],div[id^="google_ads_iframe"]{display:none!important}';
  }
  var style = document.createElement('style');
  style.textContent = css;
  (document.head || document.documentElement).appendChild(style);

  // ---------------------------------------------------------------- badges
  var ICON = '<svg viewBox="0 0 24 24"><path d="M12 4v11"/><path d="M7 10.5l5 5 5-5"/><path d="M5 20h14"/></svg>';
  var DONE = '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';

  function canonical(href) {
    try {
      var u = new URL(href, location.href);
      if (/youtube\.com$/.test(u.hostname.replace(/^www\.|^m\./, ''))) {
        var v = u.searchParams.get('v');
        if (v) return 'https://www.youtube.com/watch?v=' + v;
        var s = u.pathname.match(/\/shorts\/([\w-]+)/);
        if (s) return 'https://www.youtube.com/shorts/' + s[1];
      }
      if (/(x|twitter)\.com$/.test(u.hostname)) {
        var m = u.pathname.match(/^\/([^/]+)\/status\/(\d+)/);
        if (m) return 'https://x.com/' + m[1] + '/status/' + m[2];
      }
      if (/instagram\.com$/.test(u.hostname)) {
        var g = u.pathname.match(/\/(p|reel|reels|tv)\/([\w-]+)/);
        if (g) return 'https://www.instagram.com/' + (g[1] === 'reels' ? 'reel' : g[1]) + '/' + g[2] + '/';
      }
      u.hash = '';
      return u.toString();
    } catch (e) {
      return href;
    }
  }

  function addBadge(target, url) {
    if (!target || target.__nzBadge) return;
    target.__nzBadge = true;
    var cs = getComputedStyle(target);
    if (cs.position === 'static') target.classList.add('nz-host');
    var b = document.createElement('div');
    b.className = 'nz-dl';
    b.setAttribute('role', 'button');
    b.setAttribute('aria-label', 'تنزيل');
    b.innerHTML = ICON;
    var stop = function (e) { e.preventDefault(); e.stopPropagation(); if (e.stopImmediatePropagation) e.stopImmediatePropagation(); };
    ['touchstart', 'touchend', 'pointerdown', 'pointerup', 'mousedown', 'mouseup'].forEach(function (t) {
      b.addEventListener(t, function (e) { e.stopPropagation(); }, true);
    });
    b.addEventListener('click', function (e) {
      stop(e);
      send({ type: 'download', url: url });
      b.classList.add('nz-done');
      b.innerHTML = DONE;
      setTimeout(function () { b.classList.remove('nz-done'); b.innerHTML = ICON; }, 2500);
    }, true);
    target.appendChild(b);
  }

  function scanBadges() {
    if (!CFG.badges || !site) return;
    if (site.container) {
      var boxes = document.querySelectorAll(site.container);
      for (var i = 0; i < boxes.length; i++) {
        var box = boxes[i];
        if (box.__nzBadge || box.offsetHeight < 120) continue;
        var links = box.querySelectorAll('a[href]');
        for (var j = 0; j < links.length; j++) {
          if (site.link.test(links[j].href)) { addBadge(box, canonical(links[j].href)); break; }
        }
      }
    }
    var anchors = document.querySelectorAll('a[href]');
    for (var k = 0; k < anchors.length; k++) {
      var a = anchors[k];
      if (a.__nzBadge || !site.link.test(a.href)) continue;
      if (site.container && a.closest(site.container)) continue;
      // only thumbnails / cards, not text links
      if (a.offsetWidth < 90 || a.offsetHeight < 70) continue;
      if (!a.querySelector('img, video, picture, [style*="background-image"], canvas')) continue;
      addBadge(a, canonical(a.href));
    }
  }

  // ---------------------------------------------------------------- ad skipping
  var LABELS = ['Sponsored', 'Promoted', 'Ad', 'Paid partnership', 'ممول', 'مُموَّل', 'مموّل', 'إعلان', 'مُروَّج', 'مروج', 'Publicidad', 'Sponsorisé', 'Gesponsert'];

  function hasLabel(el) {
    var spans = el.querySelectorAll('span, a, div[dir]');
    for (var i = 0; i < spans.length && i < 60; i++) {
      var t = (spans[i].textContent || '').trim();
      if (t.length && t.length < 20 && LABELS.indexOf(t) !== -1) return true;
    }
    return false;
  }

  function hideSponsored() {
    if (!CFG.adblock) return;
    var groups = [];
    if (/instagram\.com$/.test(host)) groups.push(['article', null]);
    if (/(x|twitter)\.com$/.test(host)) groups.push(['article', '[data-testid="cellInnerDiv"]']);
    if (/tiktok\.com$/.test(host)) groups.push(['[data-e2e="recommend-list-item-container"]', null]);
    if (/reddit\.com$/.test(host)) groups.push(['shreddit-ad-post, [data-promoted="true"]', null]);
    groups.forEach(function (g) {
      var nodes = document.querySelectorAll(g[0]);
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        if (n.__nzAdChecked) continue;
        if (n.tagName && n.tagName.toLowerCase() === 'shreddit-ad-post' || hasLabel(n)) {
          var target = g[1] ? (n.closest(g[1]) || n) : n;
          target.style.setProperty('display', 'none', 'important');
        }
        n.__nzAdChecked = true;
      }
    });
  }

  function skipYouTubeAds() {
    if (!CFG.adblock || !/youtube\.com$/.test(host)) return;
    var player = document.querySelector('.html5-video-player');
    var video = document.querySelector('video');
    if (!video) return;
    var adShowing = player && (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'));
    if (adShowing) {
      if (!video.__nzMuted) { video.__nzMuted = true; video.__nzWasMuted = video.muted; }
      video.muted = true;
      try {
        if (isFinite(video.duration) && video.duration > 0.5) video.currentTime = video.duration - 0.1;
        video.playbackRate = 16;
      } catch (e) {}
      var skip = document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button,' +
        ' .ytp-ad-skip-button-container button, .ytm-skip-ad-button, button[class*="skip-ad"], [class*="skip-button"] button');
      for (var i = 0; i < skip.length; i++) { try { skip[i].click(); } catch (e) {} }
    } else if (video.__nzMuted) {
      video.muted = !!video.__nzWasMuted;
      video.__nzMuted = false;
      if (video.playbackRate === 16) video.playbackRate = 1;
    }
    // "ad blockers are not allowed" dialog: close it and keep playing
    var enforcement = document.querySelector('ytd-enforcement-message-view-model, ytm-enforcement-message-view-model');
    if (enforcement) {
      var dialog = enforcement.closest('tp-yt-paper-dialog, ytm-dialog, [role="dialog"]') || enforcement;
      dialog.remove();
      document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach(function (b) { b.remove(); });
      if (video.paused) { try { video.play(); } catch (e) {} }
    }
  }

  // ---------------------------------------------------------------- page info for the app
  var lastURL = '';
  function reportPage() {
    if (location.href === lastURL) return;
    lastURL = location.href;
    send({ type: 'page', url: location.href });
  }

  // ---------------------------------------------------------------- scheduling
  var pending = false;
  function schedule() {
    if (pending) return;
    pending = true;
    setTimeout(function () {
      pending = false;
      try { scanBadges(); } catch (e) {}
      try { hideSponsored(); } catch (e) {}
      reportPage();
    }, 350);
  }

  var observer = new MutationObserver(schedule);
  function start() {
    observer.observe(document.documentElement, { childList: true, subtree: true });
    schedule();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
  setInterval(schedule, 2000);
  if (/youtube\.com$/.test(host)) setInterval(skipYouTubeAds, 300);

  window.__nazzel = {
    setConfig: function (c) { CFG = c; schedule(); },
    currentMedia: function () { return canonical(location.href); }
  };
})();
