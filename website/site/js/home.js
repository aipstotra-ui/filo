/* Filo home page — vanilla-JS port of the approved design prototype's component logic.
   Reimplements: looping hero popup demo, chaos->calm scroll scrub with progress meter,
   reveal-on-scroll, JS-driven responsive layout, and the waitlist submit handler.
   No framework, no network, no third-party dependencies. */

(function () {
  'use strict';

  function init() {
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var lerp = function (a, b, t) { return a + (b - a) * t; };
    var smooth = function (t) { t = t < 0 ? 0 : t > 1 ? 1 : t; return t * t * (3 - 2 * t); };
    function mulberry32(a) { return function () { a |= 0; a = a + 0x6D2B79F5 | 0; var t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
    var timers = [];
    var wait = function (fn, ms) { var t = setTimeout(fn, ms); timers.push(t); return t; };

    /* ---------- waitlist submit (non-functional stub) ---------- */
    var form = document.getElementById('filoForm');
    if (form) {
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        var el = document.getElementById('filoEmail');
        var v = el ? el.value.trim() : '';
        if (!v || v.indexOf('@') < 1) { if (el) el.focus(); return; }
        // ---------------------------------------------------------------------
        // STUB: no data is sent anywhere. This preview only flips to the
        // thank-you state locally. When a real waitlist vendor is approved,
        // replace this block with a POST to that vendor's endpoint (and only
        // that endpoint) before showing the success state.
        // ---------------------------------------------------------------------
        var fw = document.getElementById('filoFormWrap');
        var sw = document.getElementById('filoSentWrap');
        if (fw) fw.hidden = true;
        if (sw) sw.hidden = false;
      });
    }

    /* ---------- reveal on scroll ---------- */
    var revs = document.querySelectorAll('[data-reveal]');
    if (reduce) {
      revs.forEach(function (el) { el.style.opacity = 1; el.style.transform = 'none'; });
    } else {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) { e.target.style.opacity = 1; e.target.style.transform = 'none'; io.unobserve(e.target); } });
      }, { threshold: .14, rootMargin: '0px 0px -8% 0px' });
      revs.forEach(function (el) { io.observe(el); });
    }

    /* ---------- hero demo: looping popup, cycles Finance -> Work -> Photos -> Media ---------- */
    var $ = function (id) { return document.getElementById(id); };
    var rgba = function (hex, a) { var n = parseInt(hex.slice(1), 16); return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')'; };
    var folderSvg = function (c) { return '<svg viewBox="0 0 24 20" width="15" height="13" fill="none"><path d="M2 5A1.5 1.5 0 0 1 3.5 3.5h4l2 2h11A1.5 1.5 0 0 1 22 7v9.5A1.5 1.5 0 0 1 20.5 18h-17A1.5 1.5 0 0 1 2 16.5V5Z" fill="' + c + '"/></svg> → '; };
    var fileSvg = function (c) { return '<svg viewBox="0 0 26 30" width="17" height="20" fill="none"><path d="M3 2.5A1.5 1.5 0 0 1 4.5 1H16l7 7v19.5A1.5 1.5 0 0 1 21.5 29h-17A1.5 1.5 0 0 1 3 27.5V2.5Z" stroke="' + c + '" stroke-width="1.4"/><path d="M16 1v7h7" stroke="' + c + '" stroke-width="1.4"/></svg>'; };
    var ITEMS = [
      { color: '#ff6b5c', old: 'invoice_final_v2 (3).pdf', status: 'Reading PDF text · on-device', name: 'Acme Studio — Invoice 1042.pdf', dest: 'Finance / Invoices', fly: 'Invoice 1042.pdf', tile: 'filoFinance', count: 'filoFinCount', base: 3 },
      { color: '#3d8bff', old: 'Untitled document.docx', status: 'Reading document · on-device', name: 'Q3 Planning — Notes.docx', dest: 'Work / Notes', fly: 'Q3 Planning.docx', tile: 'filoWork', count: 'filoWorkCount', base: 41 },
      { color: '#22c39a', old: 'Screenshot 2026-06-14.png', status: 'Reading image · on-device', name: 'Dashboard mockup.png', dest: 'Photos / Screenshots', fly: 'Dashboard.png', tile: 'filoPhotos', count: 'filoPhotosCount', base: 128 },
      { color: '#a97bff', old: 'assets-export (1).zip', status: 'Reading archive · on-device', name: 'Brand kit — assets.zip', dest: 'Media / Archives', fly: 'Brand kit.zip', tile: 'filoMedia', count: 'filoMediaCount', base: 17 }
    ];
    var demo = $('filoDemo'), fly = $('filoFly');
    ITEMS.forEach(function (it) { var tl = $(it.tile); if (tl) tl.style.transition = 'background .4s,box-shadow .4s'; });
    var clearTiles = function () { ITEMS.forEach(function (it) { var tl = $(it.tile); if (tl) { tl.style.background = 'transparent'; tl.style.boxShadow = 'none'; } var c = $(it.count); if (c) c.textContent = it.base + ' items'; }); };
    var setItem = function (it) {
      var hi = $('filoHeadIc'); if (hi) hi.style.background = it.color;
      var sp = $('filoSpin'); if (sp) sp.style.borderTopColor = it.color;
      var stx = $('filoStatusText'); if (stx) stx.textContent = it.status;
      var old = $('filoOld'); if (old) { old.textContent = it.old; old.style.color = 'rgba(0,0,0,.85)'; old.style.textDecoration = 'none'; }
      var nm = $('filoNewName'); if (nm) nm.textContent = it.name;
      var de = $('filoDest'); if (de) { de.style.background = rgba(it.color, .1); de.style.borderColor = rgba(it.color, .24); de.innerHTML = folderSvg(it.color) + it.dest; }
      var mv = $('filoMovedText'); if (mv) mv.textContent = 'Moved to ' + it.dest;
      if (fly) { fly.style.background = rgba(it.color, .14); fly.style.borderColor = it.color; fly.style.opacity = '0'; fly.innerHTML = fileSvg(it.color) + '<span style="font-size:11px;font-weight:600;color:#1d1d1f;white-space:nowrap;">' + it.fly + '</span>'; }
    };
    var resetPopup = function () {
      var st = $('filoStatus'); if (st) st.style.opacity = 1;
      var su = $('filoSuggest'); if (su) su.style.opacity = 0;
      var ac = $('filoActs'); if (ac) ac.style.opacity = 0;
      var mv = $('filoMoved'); if (mv) mv.style.opacity = 0;
      var acc = $('filoAccept'); if (acc) { acc.style.boxShadow = 'none'; acc.style.transform = 'scale(1)'; }
    };
    var landFile = function (it) {
      var tl = $(it.tile); if (tl) { tl.style.background = rgba(it.color, .16); tl.style.boxShadow = '0 0 0 2px ' + rgba(it.color, .5) + ' inset'; }
      var c = $(it.count); if (c) c.textContent = (it.base + 1) + ' items';
      wait(function () { if (tl) { tl.style.boxShadow = 'none'; tl.style.background = rgba(it.color, .1); } }, 900);
      wait(function () { var ac = $('filoActs'); if (ac) ac.style.opacity = 0; var mv = $('filoMoved'); if (mv) mv.style.opacity = 1; }, 500);
    };
    var flyFile = function (it) {
      var acc = $('filoAccept'), tl = $(it.tile);
      if (!demo || !fly || !acc || !tl) { landFile(it); return; }
      var dr = demo.getBoundingClientRect(), ar = acc.getBoundingClientRect(), fr = tl.getBoundingClientRect();
      var sx = ar.left - dr.left + ar.width / 2, sy = ar.top - dr.top + ar.height / 2;
      var ex = fr.left - dr.left + fr.width / 2, ey = fr.top - dr.top + fr.height / 2;
      fly.style.transition = 'none';
      fly.style.left = sx + 'px'; fly.style.top = sy + 'px';
      fly.style.transform = 'translate(-50%,-50%) scale(1)'; fly.style.opacity = '1';
      fly.getBoundingClientRect();
      requestAnimationFrame(function () {
        fly.style.transition = 'transform 1.2s cubic-bezier(.5,0,.25,1),opacity .35s ease .95s';
        fly.style.transform = 'translate(calc(-50% + ' + (ex - sx) + 'px),calc(-50% + ' + (ey - sy) + 'px)) scale(.42)';
        fly.style.opacity = '0';
      });
      wait(function () { landFile(it); }, 1150);
    };
    var cyc = 0;
    var runCycle = function () {
      var it = ITEMS[cyc % ITEMS.length];
      clearTiles(); setItem(it); resetPopup();
      wait(function () { var st = $('filoStatus'); if (st) st.style.opacity = 0; var su = $('filoSuggest'); if (su) su.style.opacity = 1; var old = $('filoOld'); if (old) { old.style.color = 'rgba(0,0,0,.4)'; old.style.textDecoration = 'line-through'; } }, 2600);
      wait(function () { var ac = $('filoActs'); if (ac) ac.style.opacity = 1; }, 5000);
      wait(function () { var acc = $('filoAccept'); if (acc) acc.style.boxShadow = '0 0 0 4px rgba(10,132,255,.35)'; }, 6400);
      wait(function () { var acc = $('filoAccept'); if (acc) acc.style.transform = 'scale(.94)'; }, 7600);
      wait(function () { var acc = $('filoAccept'); if (acc) { acc.style.transform = 'scale(1)'; acc.style.boxShadow = 'none'; } flyFile(it); }, 7900);
      wait(function () { cyc++; runCycle(); }, 11500);
    };
    var endStateStatic = function () {
      var it = ITEMS[0]; clearTiles(); setItem(it);
      var st = $('filoStatus'); if (st) st.style.opacity = 0;
      var su = $('filoSuggest'); if (su) su.style.opacity = 1;
      var ac = $('filoActs'); if (ac) ac.style.opacity = 1;
      var old = $('filoOld'); if (old) { old.style.color = 'rgba(0,0,0,.4)'; old.style.textDecoration = 'line-through'; }
      var mv = $('filoMoved'); if (mv) mv.style.opacity = 1;
      var tl = $(it.tile); if (tl) tl.style.background = rgba(it.color, .12);
      var c = $(it.count); if (c) c.textContent = (it.base + 1) + ' items';
    };
    if (reduce) endStateStatic(); else runCycle();

    /* ---------- chaos -> calm scrub (colorful, once, tuned speed) ---------- */
    var stage = document.getElementById('filoStage');
    var FW = 640, FH = 520;
    var COLS = [8, 168, 328, 488];
    var TYPES = [
      { k: 'pdf', c: '#ff6b5c', bg: '#fdeae7', label: 'Finance' },
      { k: 'img', c: '#22c39a', bg: '#e3f6ef', label: 'Photos' },
      { k: 'doc', c: '#3d8bff', bg: '#e8f1ff', label: 'Work' },
      { k: 'zip', c: '#a97bff', bg: '#f1e9ff', label: 'Media' }
    ];
    var NAMES = {
      pdf: ['bank_statement.pdf', 'receipt (2).pdf', 'contract_FINAL.pdf'],
      img: ['IMG_0921.png', 'Screen Shot 3.png', 'logo-draft.png'],
      doc: ['resume v3.docx', 'meeting-notes.docx', 'draft copy.docx'],
      zip: ['export (1).zip', 'backup-old.zip', 'photos.zip']
    };
    var glyph = function (c) { return '<svg viewBox="0 0 26 30" width="22" height="26" fill="none" style="flex:0 0 auto;"><path d="M3 2.5A1.5 1.5 0 0 1 4.5 1H16l7 7v19.5A1.5 1.5 0 0 1 21.5 29h-17A1.5 1.5 0 0 1 3 27.5V2.5Z" fill="' + c + '" opacity=".14"/><path d="M3 2.5A1.5 1.5 0 0 1 4.5 1H16l7 7v19.5A1.5 1.5 0 0 1 21.5 29h-17A1.5 1.5 0 0 1 3 27.5V2.5Z" stroke="' + c + '" stroke-width="1.4"/><path d="M16 1v7h7" stroke="' + c + '" stroke-width="1.4"/></svg>'; };
    var rng = mulberry32(20260724);
    var fnodes = [], folders = [];
    TYPES.forEach(function (T, ci) {
      var fo = document.createElement('div');
      fo.style.cssText = 'position:absolute;top:0;left:' + COLS[ci] + 'px;width:136px;display:flex;flex-direction:column;align-items:center;gap:7px;opacity:0;transition:opacity .3s;';
      fo.innerHTML = '<svg viewBox="0 0 52 42" width="50" height="40" fill="none"><path d="M2 8A3 3 0 0 1 5 5h13l4 4h24a3 3 0 0 1 3 3v24a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3V8Z" fill="' + T.c + '"/></svg><span style="font-weight:600;font-size:13px;color:#f5f5f7;">' + T.label + '</span>';
      stage.appendChild(fo);
      folders.push(fo);
      for (var r = 0; r < 3; r++) {
        var el = document.createElement('div');
        el.style.cssText = 'position:absolute;left:0;top:0;width:136px;display:flex;align-items:center;gap:8px;padding:9px 11px;border-radius:12px;background:' + T.bg + ';border:1px solid ' + T.c + ';box-shadow:0 18px 40px -18px rgba(0,0,0,.7);will-change:transform;';
        el.innerHTML = glyph(T.c) + '<span style="font-size:11px;font-weight:600;line-height:1.2;color:#1d1d1f;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;word-break:break-word;">' + NAMES[T.k][r] + '</span>';
        stage.appendChild(el);
        var mess = [10 + rng() * 470, 60 + rng() * 400, -18 + rng() * 36];
        var tidy = [COLS[ci], 92 + r * 66, 0];
        fnodes.push({ el: el, mess: mess, tidy: tidy });
      }
    });

    var wrap = document.getElementById('filoStageWrap');
    var scale = 1;
    var fit = function () { var w = wrap.clientWidth; scale = Math.min(1, w / FW); if (scale < 0.5) scale = 0.5; stage.style.transform = 'scale(' + scale + ')'; wrap.style.height = (FH * scale) + 'px'; };
    fit();

    var meter = document.getElementById('filoMeter');
    var pct = document.getElementById('filoScrubPct');
    var tMess = document.getElementById('filoTitleMess');
    var tCalm = document.getElementById('filoTitleCalm');
    var calmWord = document.getElementById('filoCalmWord');
    var glow = document.getElementById('filoScrubGlow');

    var apply = function (p) {
      fnodes.forEach(function (c, i) {
        var st = (i / fnodes.length) * 0.4;
        var lp = smooth((p - st) / 0.46);
        var x = lerp(c.mess[0], c.tidy[0], lp), y = lerp(c.mess[1], c.tidy[1], lp), r = lerp(c.mess[2], c.tidy[2], lp);
        c.el.style.transform = 'translate(' + x + 'px,' + y + 'px) rotate(' + r + 'deg)';
      });
      var fo = smooth((p - 0.14) / 0.28);
      folders.forEach(function (f) { f.style.opacity = fo; });
      if (glow) glow.style.opacity = smooth((p - 0.1) / 0.5).toFixed(3);
      if (tMess) tMess.style.opacity = (1 - smooth((p - 0.32) / 0.2)).toFixed(3);
      if (tCalm) tCalm.style.opacity = smooth((p - 0.42) / 0.2).toFixed(3);
      if (calmWord) { var hh = Math.round(lerp(210, 145, smooth(p))); calmWord.style.color = 'hsl(' + hh + ',82%,62%)'; }
      var percent = Math.round(smooth((p - 0.04) / 0.82) * 100);
      if (pct) pct.textContent = percent + '% sorted';
      if (meter) meter.style.width = percent + '%';
    };

    var track = document.getElementById('filoScrubTrack');
    var grid = document.getElementById('filoScrubGrid');
    var wide = window.matchMedia('(min-width:901px)');
    var progress = function () { var rct = track.getBoundingClientRect(); var total = rct.height - window.innerHeight; return total > 0 ? Math.max(0, Math.min(1, (-rct.top) / total)) : 0; };
    var ticking = false;
    var frame = function () { if (wide.matches) apply(progress()); ticking = false; };
    var req = function () { if (!ticking) { ticking = true; requestAnimationFrame(frame); } };

    var applyLayout = function () {
      if (wide.matches) { grid.style.gridTemplateColumns = '.9fr 1.1fr'; track.style.height = '260vh'; frame(); }
      else { grid.style.gridTemplateColumns = '1fr'; track.style.height = 'auto'; apply(1); folders.forEach(function (f) { f.style.opacity = 1; }); if (tMess) tMess.style.opacity = 0; if (tCalm) tCalm.style.opacity = 1; }
    };
    var featGrid = document.getElementById('filoFeatGrid');
    var applyFeat = function () { featGrid.style.gridTemplateColumns = window.innerWidth < 780 ? '1fr' : 'repeat(3,1fr)'; };

    applyLayout(); applyFeat();
    if (reduce) { apply(1); folders.forEach(function (f) { f.style.opacity = 1; }); if (tMess) tMess.style.opacity = 0; if (tCalm) tCalm.style.opacity = 1; }

    window.addEventListener('scroll', req, { passive: true });
    window.addEventListener('resize', function () { fit(); applyLayout(); applyFeat(); req(); }, { passive: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
