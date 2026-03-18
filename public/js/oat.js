;(function () {
  'use strict'

  // === Utility: reduced motion check ===
  function prefersReducedMotion () {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  function getTransitionDuration (type) {
    if (prefersReducedMotion()) return 0
    if (type === 'feedback') return 150
    if (type === 'layout') return 300
    return 200
  }

  // ==========================================================================
  // Toast Notifications
  // ==========================================================================
  var TOAST_CONTAINER_ID = 'ot-toast-container'
  var TOAST_DURATION = 4000

  function getToastContainer () {
    var container = document.getElementById(TOAST_CONTAINER_ID)
    if (!container) {
      container = document.createElement('div')
      container.id = TOAST_CONTAINER_ID
      container.setAttribute('role', 'region')
      container.setAttribute('aria-label', 'Notifications')
      container.style.cssText =
        'position:fixed;bottom:1rem;right:1rem;z-index:9999;display:flex;flex-direction:column;gap:0.5rem;max-width:24rem;'
      document.body.appendChild(container)
    }
    return container
  }

  function showToast (message, variant) {
    var container = getToastContainer()
    var toast = document.createElement('div')
    toast.className = 'ot-toast'
    if (variant) toast.className += ' ot-toast--' + variant
    toast.setAttribute('role', variant === 'error' ? 'alert' : 'status')
    toast.setAttribute('aria-live', variant === 'error' ? 'assertive' : 'polite')
    toast.setAttribute('aria-atomic', 'true')

    var msgSpan = document.createElement('span')
    msgSpan.className = 'ot-toast-message'
    msgSpan.textContent = message
    toast.appendChild(msgSpan)

    var closeBtn = document.createElement('button')
    closeBtn.className = 'ot-toast-close'
    closeBtn.setAttribute('aria-label', 'Dismiss notification')
    closeBtn.textContent = '\u00d7'
    closeBtn.addEventListener('click', function () {
      dismissToast(toast)
    })
    toast.appendChild(closeBtn)

    toast.style.opacity = '0'
    toast.style.transform = 'translateY(0.5rem)'
    toast.style.transition =
      'opacity ' +
      getTransitionDuration('feedback') +
      'ms ease, transform ' +
      getTransitionDuration('feedback') +
      'ms ease'
    container.appendChild(toast)

    requestAnimationFrame(function () {
      toast.style.opacity = '1'
      toast.style.transform = 'translateY(0)'
    })

    var autoTimer = setTimeout(function () {
      dismissToast(toast)
    }, TOAST_DURATION)
    toast._autoTimer = autoTimer
  }

  function dismissToast (toast) {
    if (toast._dismissed) return
    toast._dismissed = true
    clearTimeout(toast._autoTimer)
    toast.style.opacity = '0'
    toast.style.transform = 'translateY(0.5rem)'
    setTimeout(function () {
      if (toast.parentNode) toast.parentNode.removeChild(toast)
    }, getTransitionDuration('feedback'))
  }

  window.OtToast = { show: showToast, dismiss: dismissToast }

  // ==========================================================================
  // Tooltip (converts title attributes)
  // ==========================================================================
  var activeTooltip = null
  var tooltipIdCounter = 0

  function createTooltip (text, anchor) {
    var id = 'ot-tooltip-' + ++tooltipIdCounter
    var tip = document.createElement('div')
    tip.id = id
    tip.className = 'ot-tooltip'
    tip.setAttribute('role', 'tooltip')
    tip.textContent = text
    tip.style.cssText =
      'position:absolute;z-index:10000;pointer-events:none;opacity:0;transition:opacity ' +
      getTransitionDuration('feedback') +
      'ms ease;'
    document.body.appendChild(tip)

    anchor.setAttribute('aria-describedby', id)

    var rect = anchor.getBoundingClientRect()
    var tipRect = tip.getBoundingClientRect()

    var top = rect.top - tipRect.height - 6 + window.scrollY
    var left = rect.left + rect.width / 2 - tipRect.width / 2 + window.scrollX

    if (left < 4) left = 4
    if (left + tipRect.width > document.documentElement.clientWidth - 4) {
      left = document.documentElement.clientWidth - tipRect.width - 4
    }
    if (top < window.scrollY + 4) {
      top = rect.bottom + 6 + window.scrollY
    }

    tip.style.top = top + 'px'
    tip.style.left = left + 'px'

    requestAnimationFrame(function () {
      tip.style.opacity = '1'
    })

    activeTooltip = { el: tip, anchor: anchor }
    return tip
  }

  function removeTooltip () {
    if (!activeTooltip) return
    var tip = activeTooltip.el
    var anchor = activeTooltip.anchor
    anchor.removeAttribute('aria-describedby')
    tip.style.opacity = '0'
    var el = tip
    setTimeout(function () {
      if (el.parentNode) el.parentNode.removeChild(el)
    }, getTransitionDuration('feedback'))
    activeTooltip = null
  }

  function initTooltips () {
    document.querySelectorAll('[title]').forEach(function (el) {
      var text = el.getAttribute('title')
      if (!text) return
      el.setAttribute('data-ot-tooltip', text)
      el.removeAttribute('title')
    })

    document.addEventListener('mouseover', function (e) {
      var target = e.target.closest('[data-ot-tooltip]')
      if (!target) return
      removeTooltip()
      createTooltip(target.getAttribute('data-ot-tooltip'), target)
    })

    document.addEventListener('mouseout', function (e) {
      var target = e.target.closest('[data-ot-tooltip]')
      if (target) removeTooltip()
    })

    document.addEventListener('focusin', function (e) {
      var target = e.target.closest('[data-ot-tooltip]')
      if (!target) return
      removeTooltip()
      createTooltip(target.getAttribute('data-ot-tooltip'), target)
    })

    document.addEventListener('focusout', function (e) {
      var target = e.target.closest('[data-ot-tooltip]')
      if (target) removeTooltip()
    })
  }

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && activeTooltip) {
      removeTooltip()
    }
  })

  // ==========================================================================
  // OtTabs Web Component
  // ==========================================================================
  if (typeof customElements !== 'undefined') {
    var OtTabs = function () {
      var el = Reflect.construct(HTMLElement, [], OtTabs)
      return el
    }
    OtTabs.prototype = Object.create(HTMLElement.prototype)
    OtTabs.prototype.constructor = OtTabs

    OtTabs.prototype.connectedCallback = function () {
      var self = this
      var tablist = self.querySelector('[role="tablist"]')
      if (!tablist) return

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
          tabs[currentIndex].setAttribute('aria-selected', 'false')
          tabs[nextIndex].setAttribute('tabindex', '0')
          tabs[nextIndex].setAttribute('aria-selected', 'true')
          tabs[nextIndex].focus()

          var panelId = tabs[nextIndex].getAttribute('aria-controls')
          if (panelId) {
            self.querySelectorAll('[role="tabpanel"]').forEach(function (panel) {
              panel.hidden = panel.id !== panelId
            })
          }
        }
      })

      tabs.forEach(function (tab) {
        tab.addEventListener('click', function () {
          tabs.forEach(function (t) {
            t.setAttribute('aria-selected', 'false')
            t.setAttribute('tabindex', '-1')
          })
          tab.setAttribute('aria-selected', 'true')
          tab.setAttribute('tabindex', '0')

          var panelId = tab.getAttribute('aria-controls')
          if (panelId) {
            self.querySelectorAll('[role="tabpanel"]').forEach(function (panel) {
              panel.hidden = panel.id !== panelId
            })
          }
        })
      })
    }

    try {
      customElements.define('ot-tabs', OtTabs)
    } catch (e) {
      // Already defined or unsupported
    }
  }

  // ==========================================================================
  // OtDropdown
  // ==========================================================================
  function initDropdowns () {
    document.addEventListener('click', function (e) {
      var trigger = e.target.closest('[data-ot-dropdown-trigger]')
      if (trigger) {
        e.preventDefault()
        e.stopPropagation()
        var dropdownId = trigger.getAttribute('data-ot-dropdown-trigger')
        var dropdown = document.getElementById(dropdownId)
        if (!dropdown) return

        var isOpen = dropdown.getAttribute('data-open') === 'true'
        closeAllDropdowns()

        if (!isOpen) {
          openDropdown(trigger, dropdown)
        }
        return
      }

      if (!e.target.closest('[data-ot-dropdown]')) {
        closeAllDropdowns()
      }
    })

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') {
        closeAllDropdowns()
      }
    })
  }

  function openDropdown (trigger, dropdown) {
    dropdown.setAttribute('data-open', 'true')
    dropdown.hidden = false
    trigger.setAttribute('aria-expanded', 'true')
    positionDropdown(trigger, dropdown)

    var firstFocusable = dropdown.querySelector(
      'a, button, input, [tabindex]:not([tabindex="-1"])'
    )
    if (firstFocusable) firstFocusable.focus()
  }

  function closeAllDropdowns () {
    document.querySelectorAll('[data-ot-dropdown][data-open="true"]').forEach(
      function (dd) {
        dd.setAttribute('data-open', 'false')
        dd.hidden = true
      }
    )
    document.querySelectorAll('[data-ot-dropdown-trigger][aria-expanded="true"]').forEach(
      function (t) {
        t.setAttribute('aria-expanded', 'false')
      }
    )
  }

  function positionDropdown (trigger, dropdown) {
    var triggerRect = trigger.getBoundingClientRect()
    var viewW = document.documentElement.clientWidth
    var viewH = document.documentElement.clientHeight

    dropdown.style.position = 'absolute'
    dropdown.style.visibility = 'hidden'
    dropdown.style.display = 'block'
    var ddRect = dropdown.getBoundingClientRect()
    dropdown.style.visibility = ''

    var top = triggerRect.bottom + window.scrollY + 4
    var left = triggerRect.left + window.scrollX

    if (left + ddRect.width > viewW - 8) {
      left = triggerRect.right + window.scrollX - ddRect.width
    }
    if (left < 8) left = 8

    if (top + ddRect.height > viewH + window.scrollY - 8) {
      top = triggerRect.top + window.scrollY - ddRect.height - 4
    }

    dropdown.style.top = top + 'px'
    dropdown.style.left = left + 'px'
  }

  // ==========================================================================
  // Init
  // ==========================================================================
  function init () {
    initTooltips()
    initDropdowns()
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init)
  } else {
    init()
  }
})()
