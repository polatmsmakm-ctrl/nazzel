/*
 * Nazzel early script (runs before the page's own scripts).
 * YouTube: removes the ad schedule from the player's data, so ads never start and the
 * video never has to be interrupted.
 *
 * Kept deliberately small and quiet:
 *  - only player responses are touched (they are recognised by their own fields), not
 *    every piece of JSON the page reads;
 *  - the wrapped functions are Proxies, so they still look like the browser's own
 *    functions. A page that notices tampering can punish playback (slow buffering,
 *    freezes), which is exactly what we want to avoid.
 */
(function () {
  'use strict';
  var cfg = window.__nazzelConfig || {};
  if (!cfg.adblock) return;
  if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
  if (window.__nazzelEarly) return;
  try { Object.defineProperty(window, '__nazzelEarly', { value: true }); } catch (e) { return; }

  var AD_KEYS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
  var stats = { pruned: 0 };
  try { Object.defineProperty(window, '__nazzelStats', { value: stats }); } catch (e) {}

  function isPlayerResponse(o) {
    return 'playabilityStatus' in o || 'streamingData' in o || 'videoDetails' in o;
  }

  function prune(o) {
    var hit = false;
    for (var i = 0; i < AD_KEYS.length; i++) {
      if (AD_KEYS[i] in o) {
        try { delete o[AD_KEYS[i]]; hit = true; } catch (e) {}
      }
    }
    // the "ad blockers are not allowed" dialog is also delivered with the player data
    var ui = o.auxiliaryUi && o.auxiliaryUi.messageRenderers;
    if (ui && (ui.bkaEnforcementMessageViewModel || ui.enforcementMessageViewModel)) {
      try { delete o.auxiliaryUi; hit = true; } catch (e) {}
    }
    if (hit) stats.pruned++;
  }

  function visit(o) {
    if (!o || typeof o !== 'object') return;
    if (isPlayerResponse(o)) prune(o);
    var inner = o.playerResponse;
    if (inner && typeof inner === 'object') prune(inner);
    if (Array.isArray(o)) {
      for (var i = 0; i < o.length && i < 6; i++) {
        var item = o[i];
        if (item && typeof item === 'object' && item.playerResponse && typeof item.playerResponse === 'object') {
          prune(item.playerResponse);
        }
      }
    }
  }

  JSON.parse = new Proxy(JSON.parse, {
    apply: function (target, self, args) {
      var result = Reflect.apply(target, self, args);
      try { visit(result); } catch (e) {}
      return result;
    }
  });

  if (window.Response && Response.prototype.json) {
    Response.prototype.json = new Proxy(Response.prototype.json, {
      apply: function (target, self, args) {
        return Reflect.apply(target, self, args).then(function (result) {
          try { visit(result); } catch (e) {}
          return result;
        });
      }
    });
  }

  var initial;
  try {
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      get: function () { return initial; },
      set: function (value) {
        try { visit(value); } catch (e) {}
        initial = value;
      }
    });
  } catch (e) {}
})();
