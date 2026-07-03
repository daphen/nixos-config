// Injected into netflix.com's MAIN world at document_start.
//
// 1. Hide AV1 support. Netflix's av1-hd-bitrate-capped ladder decodes in
//    software under Widevine L3, drops frames, and the player downshifts
//    to 540p/250kbps regardless of bandwidth. Without av01 it serves the
//    VP9/H.264 ladders: lighter decode, far healthier bitrates. EME/DRM
//    is untouched — same Widevine path as before.
// 2. Pin visibility. The player reads document.visibilityState and dumps
//    bitrate for hidden windows; watching-while-working wants full quality.
(function () {
  var realIsTypeSupported = MediaSource.isTypeSupported.bind(MediaSource);
  MediaSource.isTypeSupported = function (type) {
    return /av01|av1/i.test(String(type)) ? false : realIsTypeSupported(type);
  };

  if (navigator.mediaCapabilities && navigator.mediaCapabilities.decodingInfo) {
    var realDecodingInfo = navigator.mediaCapabilities.decodingInfo.bind(
      navigator.mediaCapabilities,
    );
    navigator.mediaCapabilities.decodingInfo = function (cfg) {
      var ct = cfg && cfg.video && cfg.video.contentType;
      if (ct && /av01|av1/i.test(ct)) {
        return Promise.resolve({
          supported: false,
          smooth: false,
          powerEfficient: false,
        });
      }
      return realDecodingInfo(cfg);
    };
  }

  // 3. Hide dropped frames. When the window is scrolled out of niri's
  //    viewport / covered, the compositor stops frame callbacks and frames
  //    miss presentation — Netflix reads those via getVideoPlaybackQuality
  //    and downshifts the rung even at 140 Mbps. Nobody is watching a
  //    hidden window; report zero so rung choice follows bandwidth only.
  var realQuality = HTMLVideoElement.prototype.getVideoPlaybackQuality;
  if (realQuality) {
    HTMLVideoElement.prototype.getVideoPlaybackQuality = function () {
      var q = realQuality.call(this);
      return {
        creationTime: q.creationTime,
        totalVideoFrames: q.totalVideoFrames,
        droppedVideoFrames: 0,
        corruptedVideoFrames: 0,
      };
    };
  }
  try {
    Object.defineProperty(HTMLVideoElement.prototype, "webkitDroppedFrameCount", {
      get: function () { return 0; },
      configurable: true,
    });
  } catch (e) { /* best-effort */ }

  try {
    Object.defineProperty(Document.prototype, "hidden", {
      get: function () { return false; },
      configurable: true,
    });
    Object.defineProperty(Document.prototype, "visibilityState", {
      get: function () { return "visible"; },
      configurable: true,
    });
    var swallow = function (e) { e.stopImmediatePropagation(); };
    window.addEventListener("visibilitychange", swallow, true);
    document.addEventListener("visibilitychange", swallow, true);
  } catch (e) { /* best-effort */ }
})();
