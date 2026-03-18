;(function () {
  'use strict'

  // === Aria-live announcer for loaded content ===
  function announceLoad (count) {
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
    announcer.textContent = count + ' more posts loaded.'
  }

  // === Skeleton loading placeholders ===
  function insertSkeletons (container, count) {
    var skeletonHtml =
      '<div class="timeline-item timeline-item-skeleton">' +
      '<figure data-variant="avatar" role="status" class="skeleton box"></figure>' +
      '<div class="skeleton-body">' +
      '<div role="status" class="skeleton line" style="width:38%"></div>' +
      '<div role="status" class="skeleton line"></div>' +
      '<div role="status" class="skeleton line" style="width:60%"></div>' +
      '</div></div>'
    var fragment = document.createDocumentFragment()
    for (var i = 0; i < count; i++) {
      var div = document.createElement('div')
      div.innerHTML = skeletonHtml
      fragment.appendChild(div.firstElementChild)
    }
    container.appendChild(fragment)
    return container.querySelectorAll('.timeline-item-skeleton')
  }

  function removeSkeletons (skeletons) {
    skeletons.forEach(function (s) {
      s.remove()
    })
  }

  // === Parse next page URL from a button or anchor ===
  function getNextUrl (el) {
    return el.getAttribute('href') || el.getAttribute('data-href') || null
  }

  // === Main infinite scroll handler ===
  function initInfiniteScroll () {
    document.addEventListener('click', function (e) {
      var button = e.target.closest('[data-infinite-target="load-more"]')
      if (!button) return
      e.preventDefault()

      var url = getNextUrl(button)
      if (!url) return

      var container = button.closest('.timeline') || button.parentElement
      var originalText = button.textContent

      // Loading state
      button.textContent = 'Loading...'
      button.setAttribute('aria-busy', 'true')
      button.disabled = true

      // Remove button from flow and insert skeletons
      var buttonParent = button.parentNode
      var skeletons = insertSkeletons(container, 3)

      fetch(url)
        .then(function (response) {
          if (!response.ok) {
            throw new Error('Network response was not ok: ' + response.status)
          }
          return response.text()
        })
        .then(function (html) {
          removeSkeletons(skeletons)

          var parser = new DOMParser()
          var doc = parser.parseFromString(html, 'text/html')
          var items = doc.querySelectorAll('.timeline-item')
          var fragment = document.createDocumentFragment()
          var count = 0

          items.forEach(function (item) {
            fragment.appendChild(item)
            count++
          })

          if (count > 0) {
            container.appendChild(fragment)
            announceLoad(count)
          }

          // Check for a new "Load more" button in the fetched page
          var newButton = doc.querySelector('[data-infinite-target="load-more"]')
          if (newButton) {
            button.textContent = originalText
            button.removeAttribute('aria-busy')
            button.disabled = false
            var newUrl = getNextUrl(newButton)
            if (newUrl) {
              button.setAttribute('href', newUrl)
              button.setAttribute('data-href', newUrl)
            }
          } else {
            // No more pages — remove the button entirely
            if (buttonParent && buttonParent.contains(button)) {
              buttonParent.removeChild(button)
            } else {
              button.remove()
            }
          }
        })
        .catch(function () {
          removeSkeletons(skeletons)
          button.textContent = "Couldn't load. Try again."
          button.removeAttribute('aria-busy')
          button.disabled = false
        })
    })
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initInfiniteScroll)
  } else {
    initInfiniteScroll()
  }
})()
