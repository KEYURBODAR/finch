;(function () {
  'use strict'

  var AUTO_HIDE_DELAY = 10000

  function initRecoveryKey () {
    var toggles = document.querySelectorAll('[data-secret-toggle]')
    toggles.forEach(function (toggle) {
      var targetId = toggle.getAttribute('data-secret-toggle')
      var input = document.getElementById(targetId)
      if (!input) return

      toggle.setAttribute('aria-pressed', 'false')

      var autoHideTimer = null

      toggle.addEventListener('click', function (e) {
        e.preventDefault()
        var isVisible = input.type === 'text'

        if (isVisible) {
          input.type = 'password'
          toggle.textContent = 'Show'
          toggle.setAttribute('aria-pressed', 'false')
          clearTimeout(autoHideTimer)
        } else {
          input.type = 'text'
          toggle.textContent = 'Hide'
          toggle.setAttribute('aria-pressed', 'true')

          clearTimeout(autoHideTimer)
          autoHideTimer = setTimeout(function () {
            input.type = 'password'
            toggle.textContent = 'Show'
            toggle.setAttribute('aria-pressed', 'false')

            var announcer = document.getElementById('finch-live-announcer')
            if (!announcer) {
              announcer = document.createElement('div')
              announcer.id = 'finch-live-announcer'
              announcer.setAttribute('role', 'status')
              announcer.setAttribute('aria-live', 'polite')
              announcer.setAttribute('aria-atomic', 'true')
              announcer.style.cssText =
                'position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;'
              document.body.appendChild(announcer)
            }
            announcer.textContent = 'Secret field hidden for security.'
          }, AUTO_HIDE_DELAY)
        }
      })
    })
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initRecoveryKey)
  } else {
    initRecoveryKey()
  }
})()
