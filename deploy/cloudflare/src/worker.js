export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      url.pathname = "/install.sh";
      request = new Request(url.toString(), request);
    }

    const response = await env.ASSETS.fetch(request);
    const headers = new Headers(response.headers);

    if (url.pathname.endsWith(".sh") || url.pathname === "/version" || url.pathname === "/sha256.txt") {
      headers.set("Content-Type", "text/plain; charset=utf-8");
      headers.set("Cache-Control", "public, max-age=300");
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
