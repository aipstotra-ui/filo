/* Filo "Privacy" page — vanilla-JS port of the prototype component logic.
   Reveal-on-scroll (reveals a container and its direct children) + responsive
   pillar layout. No framework, no network. */

(function () {
  'use strict';

  function init() {
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var revs = document.querySelectorAll('[data-reveal]');
    var showChildren = function (el) {
      el.style.opacity = 1; el.style.transform = 'none';
      Array.prototype.forEach.call(el.children, function (c) {
        if (c.style && c.style.opacity === '0') { c.style.opacity = 1; c.style.transform = 'none'; }
      });
    };
    if (reduce) {
      revs.forEach(showChildren);
    } else {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) { showChildren(e.target); io.unobserve(e.target); } });
      }, { threshold: .12, rootMargin: '0px 0px -8% 0px' });
      revs.forEach(function (el) { io.observe(el); });
    }
    var pillars = document.getElementById('pvPillars');
    var applyLayout = function () { pillars.style.gridTemplateColumns = window.innerWidth < 780 ? '1fr' : 'repeat(3,1fr)'; };
    applyLayout();
    window.addEventListener('resize', applyLayout, { passive: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
