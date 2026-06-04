#!/usr/bin/env python3
"""
Playwright fetch helper — 通过浏览器同源 fetch 调东财后台 API，绕过 IP 风控。

工作原理：
1. 启动 chromium（默认 headless；--headed 给人工验证）
2. goto 一个东财域名页（建立 cookies + 通过 JS challenge）
3. 在 page context 内 fetch(url) — 浏览器自动带正确 cookie/TLS 指纹
4. 拿到的 JSON 原样输出 stdout
5. 关闭浏览器

用法：
    python3 pw_fetch.py <url>
    python3 pw_fetch.py --headed <url>     # 人工验证模式，浏览器可见
    python3 pw_fetch.py --bootstrap <bootstrap_url> <fetch_url>  # 自定义 bootstrap 页

输出：fetch 返回的 raw 响应文本到 stdout，与 curl 等价。
"""

import sys
import time


def main():
    args = sys.argv[1:]
    headed = False
    if "--headed" in args:
        headed = True
        args.remove("--headed")

    bootstrap = "http://quote.eastmoney.com/center/boardlist.html"  # 默认
    if "--bootstrap" in args:
        i = args.index("--bootstrap")
        bootstrap = args[i + 1]
        args = args[:i] + args[i + 2:]

    if not args:
        print("usage: pw_fetch.py [--headed] [--bootstrap URL] <fetch_url>", file=sys.stderr)
        sys.exit(2)

    target_url = args[0]

    from playwright.sync_api import sync_playwright

    ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not headed, args=["--disable-blink-features=AutomationControlled"])
        context = browser.new_context(user_agent=ua, viewport={"width": 1280, "height": 720})
        page = context.new_page()

        # bootstrap 页加载（建立 session）
        try:
            page.goto(bootstrap, wait_until="domcontentloaded", timeout=20000)
            # 留 1s 给 JS challenge / cookie set
            time.sleep(1)
        except Exception as e:
            print(f"playwright: bootstrap goto failed: {e}", file=sys.stderr)
            browser.close()
            sys.exit(1)

        # 优先用 page.request.fetch（服务端 fetch，自动带浏览器 cookies，不受 CORS 限制）
        # 如果失败再降级到 page.evaluate 的浏览器内 fetch
        result = None
        try:
            api_response = page.request.fetch(target_url, headers={"Referer": bootstrap})
            result = {"ok": True, "status": api_response.status, "body": api_response.text()}
        except Exception as e:
            # 降级方案：浏览器内 fetch（适用于 CORS 允许的 endpoint）
            try:
                result = page.evaluate("""
                    async (url) => {
                        try {
                            const r = await fetch(url, {credentials: 'include'});
                            return {ok: true, status: r.status, body: await r.text()};
                        } catch (e) {
                            return {ok: false, error: e.message};
                        }
                    }
                """, target_url)
            except Exception as e2:
                print(f"playwright: both page.request.fetch and page.evaluate failed: {e} / {e2}", file=sys.stderr)
                browser.close()
                sys.exit(1)

        if headed:
            print(f"\n[playwright headed mode] press Enter to close browser ...", file=sys.stderr)
            try:
                input()
            except EOFError:
                pass

        browser.close()

        if not result.get("ok"):
            print(f"playwright: fetch failed: {result.get('error')}", file=sys.stderr)
            sys.exit(1)
        if result.get("status") != 200:
            print(f"playwright: fetch status {result.get('status')}", file=sys.stderr)
            sys.exit(1)

        body = result.get("body", "")
        if not body:
            print("playwright: empty response body", file=sys.stderr)
            sys.exit(1)

        sys.stdout.write(body)


if __name__ == "__main__":
    main()
