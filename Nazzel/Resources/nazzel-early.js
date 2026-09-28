/*
 * Nazzel early script (runs before the page's own scripts).
 * YouTube: removes the ad schedule from the player data, so ads never start
 * and the video never has to be interrupted or skipped.
 */
(function () {
  'use strict';
  var cfg = window.__nazzelConfig || {};
  if (!cfg.adblock) return;
  if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
  if (window.__nazzelEarly) return;
  window.__nazzelEarly = true;

  var KEYS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];

  function strip(o, depth) {
    if (!o || typeof o !== 'object' || depth > 4) return o;
    if (Array.isArray(o)) {
      for (var j = 0; j < o.length && j < 10; j++) strip(o[j], depth + 1);
      return o;
    }
    for (var i = 0; i < KEYS.length; i++) {
      if (KEYS[i] in o) {
        try { delete o[KEYS[i]]; } catch (e) {}
      }
    }
    if (o.playerResponse) strip(o.playerResponse, depth + 1);
    if (o.response) strip(o.response, depth + 1);
    return o;
  }

  var parse = JSON.parse;
  JSON.parse = function () {
    var result = parse.apply(this, arguments);
    try { strip(result, 0); } catch (e) {}
    return result;
  };

  if (window.Response && Response.prototype.json) {
    var json = Response.prototype.json;
    Response.prototype.json = function () {
      return json.apply(this, arguments).then(function (result) {
        try { strip(result, 0); } catch (e) {}
        return result;
      });
    };
  }

  var initial;
  try {
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      get: function () { return initial; },
      set: function (value) { initial = strip(value, 0); }
    });
  } catch (e) {}
})();
