/* Filo "How it works" page — vanilla-JS port of the prototype component logic.
   Reveal-on-scroll + JS-driven responsive layout. No framework, no network. */

(function () {
  'use strict';

  function init() {
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var revs = document.querySelectorAll('[data-reveal]');
    if (reduce) {
      revs.forEach(function (el) { el.style.opacity = 1; el.style.transform = 'none'; });
    } else {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) { e.target.style.opacity = 1; e.target.style.transform = 'none'; io.unobserve(e.target); } });
      }, { threshold: .12, rootMargin: '0px 0px -8% 0px' });
      revs.forEach(function (el) { io.observe(el); });
    }
    var grid = document.getElementById('hiwGrid');
    var setup = document.getElementById('hiwSetup');
    var applyLayout = function () {
      var narrow = window.innerWidth < 840;
      grid.style.gridTemplateColumns = narrow ? '1fr' : '1fr 1fr';
      setup.style.gridTemplateColumns = window.innerWidth < 780 ? '1fr' : 'repeat(3,1fr)';
    };
    applyLayout();
    window.addEventListener('resize', applyLayout, { passive: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
