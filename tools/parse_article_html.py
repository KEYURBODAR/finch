#!/usr/bin/env python3
import json
import re
import sys
from html import unescape
from typing import Any, Dict, Iterable, List

from parsel import Selector


class ArticleScraper:
    def _norm(self, value: Any) -> str:
        return unescape(str(value or "")).strip()

    def _flatten_strings(self, node: Any) -> Iterable[str]:
        if isinstance(node, str):
            value = self._norm(node)
            if value:
                yield value
            return
        if isinstance(node, dict):
            for value in node.values():
                yield from self._flatten_strings(value)
            return
        if isinstance(node, list):
            for value in node:
                yield from self._flatten_strings(value)

    def _find_key_values(self, node: Any, keys: set[str]) -> List[str]:
        out: List[str] = []
        if isinstance(node, dict):
            for key, value in node.items():
                if str(key) in keys:
                    out.extend(self._flatten_strings(value))
                out.extend(self._find_key_values(value, keys))
        elif isinstance(node, list):
            for item in node:
                out.extend(self._find_key_values(item, keys))
        return out

    def _parse_next_data(self, sel: Selector) -> Dict[str, str]:
        scripts = sel.css("script::text").getall() or []
        title_keys = {"title", "headline", "name"}
        body_keys = {"plain_text", "plainText", "body", "content", "articleBody", "description"}
        title = ""
        body = ""

        for raw in scripts:
            raw = raw.strip()
            if not raw or not raw.startswith("{"):
                continue
            try:
                payload = json.loads(raw)
            except Exception:
                continue

            titles = self._find_key_values(payload, title_keys)
            bodies = self._find_key_values(payload, body_keys)

            for item in titles:
                if len(item) > len(title):
                    title = item
            for item in bodies:
                if len(item) > len(body):
                    body = item

        return {"title": title, "body": body}

    def parse_article_html(self, html: str, url: str = "") -> Dict[str, str]:
        sel = Selector(text=html or "")
        title = self._norm(sel.css("meta[property='twitter:title']::attr(content)").get())
        desc = self._norm(sel.css("meta[property='twitter:description']::attr(content)").get())
        if not title:
            title = self._norm(sel.css("meta[property='og:title']::attr(content)").get())
        if not desc:
            desc = self._norm(sel.css("meta[property='og:description']::attr(content)").get())

        from_scripts = self._parse_next_data(sel)
        if len(from_scripts.get("title", "")) > len(title):
            title = from_scripts["title"]
        if len(from_scripts.get("body", "")) > len(desc):
            desc = from_scripts["body"]

        if not title:
            match = re.search(r"<title>(.*?)</title>", html or "", re.I | re.S)
            if match:
                title = self._norm(match.group(1))

        if desc and re.fullmatch(r"https?://\S+", desc):
            desc = ""

        return {
            "url": self._norm(url),
            "title": title,
            "body": desc,
        }


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else ""
    html = sys.stdin.read()
    result = ArticleScraper().parse_article_html(html, url=url)
    sys.stdout.write(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
