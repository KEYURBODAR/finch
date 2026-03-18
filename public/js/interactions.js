// NOTE: This script should be loaded via <script src="/js/interactions.js" defer></script>
// in src/views/general.nim renderHead proc (requires .nim file change in separate task)
;(function () {
  'use strict'

  // === Reduced Motion Detection ===
  var prefersReducedMotion = function () {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  // Expose globally for other scripts
  window.__finch = window.__finch || {}
  window.__finch.prefersReducedMotion = prefersReducedMotion

  // === Roving Tabindex for Tab Bars ===
  // The app has `role="tablist"` elements with `role="tab"` children
  // Per impeccable interaction design: one item tabbable, arrow keys move within
  function initRovingTabindex () {
    document.querySelectorAll('[role="tablist"]').forEach(function (tablist) {
      var tabs = Array.from(tablist.querySelectorAll('[role="tab"]'))
      if (tabs.length < 2) return

      tabs.forEach(function (tab) {
        if (tab.getAttribute('aria-selected') === 'true') {
          tab.setAttribute('tabindex', '0')
        } else {
          tab.setAttribute('tabindex', '-1')
        }
      })

      tablist.addEventListener('keydown', function (e) {
        var currentIndex = tabs.indexOf(document.activeElement)
        if (currentIndex === -1) return

        var nextIndex = -1
        if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
          nextIndex = (currentIndex + 1) % tabs.length
        } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
          nextIndex = (currentIndex - 1 + tabs.length) % tabs.length
        } else if (e.key === 'Home') {
          nextIndex = 0
        } else if (e.key === 'End') {
          nextIndex = tabs.length - 1
        }

        if (nextIndex !== -1) {
          e.preventDefault()
          tabs[currentIndex].setAttribute('tabindex', '-1')
          tabs[nextIndex].setAttribute('tabindex', '0')
          tabs[nextIndex].focus()
        }
      })
    })
  }

  // === Smooth Scroll with Reduced Motion Respect ===
  function smoothScrollTo (element) {
    if (!element) return
    var behavior = prefersReducedMotion() ? 'auto' : 'smooth'
    element.scrollIntoView({ behavior: behavior, block: 'start' })
  }

  // Override hash navigation for smooth scroll
  document.addEventListener('click', function (e) {
    var link = e.target.closest('a[href^="#"]')
    if (!link) return
    var href = link.getAttribute('href')
    if (!href || href === '#') return
    var target = document.querySelector(href)
    if (target) {
      e.preventDefault()
      smoothScrollTo(target)
      history.pushState(null, '', href)
    }
  })

  // === Double-Submit Prevention ===
  // Prevent forms from being submitted twice (export buttons, etc.)
  document.addEventListener('submit', function (e) {
    var form = e.target
    if (!form || form.tagName !== 'FORM') return
    var submitBtn = form.querySelector(
      'button[type="submit"]:focus, button[type="submit"]:active'
    )
    if (!submitBtn) {
      submitBtn = form.querySelector('button[type="submit"]')
    }
    if (submitBtn && !submitBtn.disabled) {
      submitBtn.disabled = true
      submitBtn.setAttribute('aria-busy', 'true')
      setTimeout(function () {
        submitBtn.disabled = false
        submitBtn.removeAttribute('aria-busy')
      }, 3000)
    }
  })

  // === Init on DOM Ready ===
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initRovingTabindex)
  } else {
    initRovingTabindex()
  }
})()
