# SPDX-License-Identifier: AGPL-3.0-only
import karax/[karaxdsl, vdom]

import renderutils
import ".."/[csrf, types]

proc renderIdentityPrompt*(csrfToken: string): VNode =
  buildHtml(tdiv(class="overlay-panel")):
    h2: text "Create your Finch key"
    p(class="identity-desc"):
      text "A recovery key syncs your Following and Lists across devices. Skip if you only need public access."

    tdiv(class="identity-actions"):
      form(`method`="post", action="/api/f/identity/create", class="identity-form"):
        csrfField csrfToken
        button(`type`="submit", class="btn-primary"):
          text "Create key"

      tdiv(class="identity-divider"):
        span: text "or"

      form(`method`="post", action="/api/f/identity/import", class="identity-form"):
        csrfField csrfToken
        input(`type`="text", name="identity_key", placeholder="Paste recovery key",
              class="identity-input", autocomplete="off")
        button(`type`="submit", class="btn-secondary"):
          text "Import key"

    tdiv(class="identity-skip"):
      a(href="/", class="btn-skip"):
        text "Skip"

proc renderIdentityInfo*(key, csrfToken: string): VNode =
  buildHtml(tdiv(class="overlay-panel")):
    h2: text "Your Finch key"
    p(class="identity-desc"):
      text "Save this key to restore your Following and Lists on another device."
    pre(class="identity-key"):
      text key
    tdiv(class="identity-actions"):
      form(`method`="post", action="/api/f/identity/clear", class="identity-form"):
        csrfField csrfToken
        button(`type`="submit", class="btn-danger"):
          text "Delete key"
