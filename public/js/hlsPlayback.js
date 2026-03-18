;(function () {
  'use strict'

  var hlsLoaded = false
  var hlsLoadPromise = null

  function loadHls () {
    if (typeof Hls !== 'undefined') {
      hlsLoaded = true
      return Promise.resolve()
    }
    if (hlsLoaded) return Promise.resolve()
    if (hlsLoadPromise) return hlsLoadPromise

    hlsLoadPromise = new Promise(function (resolve, reject) {
      var script = document.createElement('script')
      script.src = '/js/hls.min.js'
      script.onload = function () {
        hlsLoaded = true
        resolve()
      }
      script.onerror = function () {
        hlsLoadPromise = null
        reject(new Error('Failed to load HLS library'))
      }
      document.head.appendChild(script)
    })

    return hlsLoadPromise
  }

  window.playVideo = function (overlay) {
    var video = overlay.closest('.video-container').querySelector('video')
    if (!video) return

    overlay.style.display = 'none'
    var url = video.getAttribute('data-url')
    if (!url) return

    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = url
      video.controls = true
      video.play()
      return
    }

    loadHls()
      .then(function () {
        if (typeof Hls === 'undefined' || !Hls.isSupported()) {
          video.src = url
          video.controls = true
          video.play()
          return
        }

        var hls = new Hls({ autoStartLoad: true })
        hls.loadSource(url)
        hls.attachMedia(video)
        hls.on(Hls.Events.MANIFEST_PARSED, function () {
          hls.currentLevel = hls.levels.length - 1
          video.controls = true
          video.play()
        })
        hls.on(Hls.Events.ERROR, function (event, data) {
          if (data.fatal) {
            console.warn('HLS fatal error:', data.type)
            hls.destroy()
            video.src = url
            video.controls = true
            video.play()
          }
        })
      })
      .catch(function () {
        video.src = url
        video.controls = true
        video.play()
      })
  }
})()
