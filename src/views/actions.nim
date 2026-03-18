# SPDX-License-Identifier: AGPL-3.0-only
import strutils, uri
import karax/[karaxdsl, vdom]

import renderutils
import ".."/types

proc renderExportControls*(basePath, queryString, formId: string;
                           includeRss = ""; selectionScope = "tweet-export"): VNode =
  proc hiddenPairs(): seq[(string, string)] =
    if queryString.len > 0:
      for pair in queryString.split('&'):
        let parts = pair.split('=', 1)
        if parts.len == 2:
          result.add (decodeUrl(parts[0]), decodeUrl(parts[1]))

  buildHtml(tdiv(class="page-export-toolbar")):
    if includeRss.len > 0:
      menu(class="buttons page-actions"):
        li:
          a(class="page-action button outline small", href=includeRss):
            text "RSS"

    form(`method`="get", action=(basePath & "/json"), class="page-export-form", id=formId):
      for (name, value) in hiddenPairs():
        input(`type`="hidden", name=name, value=value)
      input(`type`="hidden", name="selected_ids", value="", id=(formId & "-selected"))

      menu(class="buttons page-actions"):
        li:
          button(`type`="submit", class="page-action button outline small",
                 formaction=(basePath & "/live/json")):
            text "LIVE"

      details(class="page-export-details"):
        summary(class="page-action button outline small"):
          text "Export"
        tdiv(class="page-export-panel"):
          if selectionScope.len > 0:
            tdiv(class="page-export-select-actions"):
              button(`type`="button", class="button outline compact",
                     `data-checkbox-scope`=selectionScope,
                     `data-checkbox-action`="select-all",
                     `data-checkbox-root`=formId):
                text "Select visible"
              button(`type`="button", class="button outline compact",
                     `data-checkbox-scope`=selectionScope,
                     `data-checkbox-action`="clear",
                     `data-checkbox-root`=formId):
                text "Clear"

          label(class="page-export-limit"):
            span: text "Last"
            input(`type`="number", name="limit", min="1", max="500", step="1",
                  placeholder="100", inputmode="numeric",
                  `data-export-limit`=formId)

          menu(class="buttons page-actions"):
            li:
              button(`type`="submit", class="page-action button outline small",
                     formaction=(basePath & "/json")):
                text "JSON"
            li:
              button(`type`="submit", class="page-action button outline small",
                     formaction=(basePath & "/md")):
                text "MD"
            li:
              button(`type`="submit", class="page-action button outline small",
                     formaction=(basePath & "/txt")):
                text "TXT"

proc renderPageActions*(actions: seq[(string, string)]): VNode =
  buildHtml(menu(class="buttons page-actions")):
    for (label, href) in actions:
      li:
        a(class="page-action button outline small", href=href):
          text label
