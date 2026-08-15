from mitmproxy import http

DEFAULT_UA = "opencode/1.17.13 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14"
TARGET_HOST = "opencode.ai"
TARGET_PATH = "/zen/v1/chat/completions"


class AutoPatch:
    def request(self, flow: http.HTTPFlow):
        if flow.request.pretty_host != TARGET_HOST:
            return
        if not flow.request.path.startswith(TARGET_PATH):
            return
        ua = flow.request.headers.get("User-Agent", "")
        if "opencode" in ua:
            return
        flow.request.headers["User-Agent"] = DEFAULT_UA


addons = [AutoPatch()]