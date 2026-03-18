;(function () {
  'use strict'

  var conn =
    navigator.connection ||
    navigator.mozConnection ||
    navigator.webkitConnection
  if (conn) {
    if (conn.saveData) return
    if (conn.effectiveType === '2g' || conn.effectiveType === 'slow-2g') return
  }

  var prefetched = {}
  var hoverTimer = null
  var HOVER_DELAY = 65

  function shouldPrefetch (url) {
    if (!url) return false
    if (prefetched[url]) return false
    try {
      var parsed = new URL(url, window.location.origin)
      if (parsed.origin !== window.location.origin) return false
      if (parsed.pathname === window.location.pathname) return false
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:')
        return false
    } catch (e) {
      return false
    }
    return true
  }

  function prefetchUrl (url) {
    if (prefetched[url]) return
    prefetched[url] = true

    var link = document.createElement('link')
    link.rel = 'prefetch'
    link.href = url
    link.as = 'document'
    document.head.appendChild(link)
  }

  document.addEventListener(
    'mouseover',
    function (e) {
      var anchor = e.target.closest('a[href]')
      if (!anchor) return

      var url = anchor.href
      if (!shouldPrefetch(url)) return

      clearTimeout(hoverTimer)
      hoverTimer = setTimeout(function () {
        prefetchUrl(url)
      }, HOVER_DELAY)
    },
    { passive: true }
  )

  document.addEventListener(
    'mouseout',
    function (e) {
      if (e.target.closest('a[href]')) {
        clearTimeout(hoverTimer)
      }
    },
    { passive: true }
  )

  document.addEventListener(
    'touchstart',
    function (e) {
      var anchor = e.target.closest('a[href]')
      if (!anchor) return
      var url = anchor.href
      if (shouldPrefetch(url)) {
        prefetchUrl(url)
      }
    },
    { passive: true }
  )
})()
