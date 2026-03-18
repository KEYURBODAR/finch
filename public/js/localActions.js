;(function () {
  'use strict'

  // === Debounce utility ===
  function debounce (fn, delay) {
    var timer = null
    return function () {
      var context = this
      var args = arguments
      clearTimeout(timer)
      timer = setTimeout(function () {
        fn.apply(context, args)
      }, delay)
    }
  }

  // === Checkbox selection helpers ===
  function getVisibleCheckboxes (container) {
    if (!container) container = document
    return Array.from(
      container.querySelectorAll(
        'input[type="checkbox"][data-select-target]:not([disabled])'
      )
    )
  }

  function setAllCheckboxes (checked, container) {
    var boxes = getVisibleCheckboxes(container)
    boxes.forEach(function (cb) {
      cb.checked = checked
      cb.dispatchEvent(new Event('change', { bubbles: true }))
    })
    updateSelectionCount(container)
  }

  function updateSelectionCount (container) {
    if (!container) container = document
    var counter = container.querySelector('[data-select-count]')
    if (!counter) return
    var boxes = getVisibleCheckboxes(container)
    var checked = boxes.filter(function (cb) {
      return cb.checked
    })
    counter.textContent = checked.length + ' selected'
    if (checked.length > 0) {
      counter.removeAttribute('hidden')
    } else {
      counter.setAttribute('hidden', '')
    }
    updateBulkActions(container, checked.length)
  }

  function updateBulkActions (container, count) {
    if (!container) container = document
    var actions = container.querySelector('[data-bulk-actions]')
    if (!actions) return
    if (count > 0) {
      actions.removeAttribute('hidden')
    } else {
      actions.setAttribute('hidden', '')
    }
  }

  // === Select visible / Clear (debounced) ===
  var handleSelectVisible = debounce(function (container) {
    setAllCheckboxes(true, container)
  }, 150)

  var handleClearSelection = debounce(function (container) {
    setAllCheckboxes(false, container)
  }, 150)

  // === Export form loading state ===
  function handleExportSubmit (form) {
    var submitBtn = form.querySelector(
      'button[type="submit"], input[type="submit"]'
    )
    if (!submitBtn || submitBtn.disabled) return

    submitBtn.disabled = true
    submitBtn.setAttribute('aria-busy', 'true')
    var originalText = submitBtn.textContent
    submitBtn.textContent = 'Exporting...'

    setTimeout(function () {
      submitBtn.disabled = false
      submitBtn.removeAttribute('aria-busy')
      submitBtn.textContent = originalText
    }, 5000)
  }

  // === Secret field toggle (inline variant) ===
  function toggleSecretField (input, toggle) {
    if (!input || !toggle) return
    var isVisible = input.type === 'text'
    input.type = isVisible ? 'password' : 'text'
    toggle.textContent = isVisible ? 'Show' : 'Hide'
    toggle.setAttribute('aria-pressed', isVisible ? 'false' : 'true')
  }

  // === Event delegation ===
  function initLocalActions () {
    document.addEventListener('click', function (e) {
      var selectAllBtn = e.target.closest('[data-action="select-visible"]')
      if (selectAllBtn) {
        e.preventDefault()
        var container = selectAllBtn.closest('[data-select-scope]') || document
        handleSelectVisible(container)
        return
      }

      var clearBtn = e.target.closest('[data-action="clear-selection"]')
      if (clearBtn) {
        e.preventDefault()
        var scope = clearBtn.closest('[data-select-scope]') || document
        handleClearSelection(scope)
        return
      }

      var secretToggle = e.target.closest('[data-secret-toggle]')
      if (secretToggle) {
        e.preventDefault()
        var targetId = secretToggle.getAttribute('data-secret-toggle')
        var input = document.getElementById(targetId)
        toggleSecretField(input, secretToggle)
        return
      }
    })

    document.addEventListener('change', function (e) {
      if (
        e.target.matches &&
        e.target.matches('input[type="checkbox"][data-select-target]')
      ) {
        var container = e.target.closest('[data-select-scope]') || document
        updateSelectionCount(container)
      }
    })

    document.addEventListener('submit', function (e) {
      var form = e.target
      if (!form) return
      if (
        form.hasAttribute('data-export-form') ||
        form.classList.contains('export-form')
      ) {
        handleExportSubmit(form)
      }
    })
  }

  // === Init ===
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initLocalActions)
  } else {
    initLocalActions()
  }
})()
