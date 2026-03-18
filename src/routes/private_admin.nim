# SPDX-License-Identifier: AGPL-3.0-only
import jester

import router_utils
import ".."/[auth, types]

proc createPrivateAdminRouter*(cfg: Config) =
  router privateAdmin:
    get "/api/private/health":
      cond cfg.enableAdmin
      respJson getSessionPoolHealth()

    get "/api/private/sessions":
      cond cfg.enableAdmin
      respJson getSessionPoolDebug()

    get "/api/private/meta":
      cond cfg.enableAdmin
      let meta = "{\"product\":\"Finch\",\"mode\":\"private_admin\",\"admin_enabled\":" &
        $(cfg.enableAdmin) & ",\"debug_enabled\":" & $(cfg.enableDebug) & "}"
      resp meta, "application/json"
