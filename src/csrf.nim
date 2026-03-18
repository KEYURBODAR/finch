# SPDX-License-Identifier: AGPL-3.0-only
import std/[sysrand, strutils]

const
  csrfCookieName* = "finch_csrf"
  csrfFieldName* = "csrf_token"

proc toHexString(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add toHex(b.int, 2).toLowerAscii

proc generateCsrfToken*(): string =
  toHexString(urandom(32))

proc csrfTokensMatch*(cookieValue, formValue: string): bool =
  if cookieValue.len == 0 or formValue.len == 0:
    return false
  cookieValue == formValue
