const IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable";
const SHORT_CACHE_CONTROL = "public, max-age=60";
const NO_STORE_CACHE_CONTROL = "no-store";
const WORKER_MARKER = "cloudflare-media-proxy";
const DEBUG_CACHE_HEADER = "X-Media-CDN-Cache";
const DEBUG_ORIGIN_STATUS_HEADER = "X-Media-CDN-Origin-Status";
const DEBUG_WORKER_HEADER = "X-Media-CDN";
const INTERNAL_RESPONSE_HEADERS = [
  "alt-svc",
  "cf-cache-status",
  "cf-ray",
  "nel",
  "report-to",
  "server",
  "server-timing",
  "set-cookie",
  "sb-gateway-mode",
  "sb-gateway-version",
  "sb-project-ref",
  "sb-request-id",
];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (!["GET", "HEAD"].includes(request.method)) {
      logEvent("warn", "reject_method", {
        method: request.method,
        path: url.pathname,
      });

      return textResponse("Method not allowed", 405, {
        Allow: "GET, HEAD",
        "Cache-Control": SHORT_CACHE_CONTROL,
        [DEBUG_WORKER_HEADER]: WORKER_MARKER,
        [DEBUG_CACHE_HEADER]: "BYPASS",
      });
    }

    const pathParts = url.pathname.split("/").filter(Boolean);

    if (pathParts.length < 2) {
      logEvent("warn", "reject_path", {
        method: request.method,
        path: url.pathname,
      });

      return textResponse("Not found", 404, {
        "Cache-Control": SHORT_CACHE_CONTROL,
        [DEBUG_WORKER_HEADER]: WORKER_MARKER,
        [DEBUG_CACHE_HEADER]: "BYPASS",
      });
    }

    const bucket = pathParts[0];
    const objectPath = pathParts.slice(1).join("/");
    const allowedBuckets = new Set(
      String(env.MEDIA_CDN_ALLOWED_BUCKETS || "chat-media,music-cache")
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean),
    );

    if (!allowedBuckets.has(bucket)) {
      logEvent("warn", "reject_bucket", {
        bucket,
        method: request.method,
        path: url.pathname,
      });

      return textResponse("Forbidden", 403, {
        "Cache-Control": SHORT_CACHE_CONTROL,
        [DEBUG_WORKER_HEADER]: WORKER_MARKER,
        [DEBUG_CACHE_HEADER]: "BYPASS",
      });
    }

    const supabaseBase = String(env.SUPABASE_URL || "").trim().replace(/\/+$/, "");
    if (!supabaseBase) {
      logEvent("error", "missing_supabase_url", {
        bucket,
        method: request.method,
        path: url.pathname,
      });

      return textResponse("Missing SUPABASE_URL", 500, {
        "Cache-Control": NO_STORE_CACHE_CONTROL,
        [DEBUG_WORKER_HEADER]: WORKER_MARKER,
        [DEBUG_CACHE_HEADER]: "BYPASS",
      });
    }

    const originUrl =
      `${supabaseBase}/storage/v1/object/public/${bucket}/${objectPath}` +
      (url.search || "");

    const cacheKey = buildCacheKey(url, request);

    const cache = caches.default;
    const cached = await cache.match(cacheKey);
    if (cached) {
      logEvent("info", "cache_hit", {
        bucket,
        method: request.method,
        path: url.pathname,
        status: cached.status,
        range: request.headers.get("range") || null,
      });

      return cloneResponse(cached, request.method, {
        [DEBUG_WORKER_HEADER]: WORKER_MARKER,
        [DEBUG_CACHE_HEADER]: "HIT",
      });
    }

    const originRequest = new Request(originUrl, {
      method: request.method,
      headers: forwardHeaders(request.headers),
    });

    const originResponse = await fetch(originRequest, {
      cf: {
        cacheEverything: true,
        cacheTtlByStatus: {
          "200-299": 31536000,
          "404": 60,
        },
      },
    });

    const normalizedOrigin = await normalizeOriginResponse(originResponse);
    const cacheState = isCacheableStatus(normalizedOrigin.status) ? "MISS" : "BYPASS";
    const response = buildClientResponse(normalizedOrigin, originResponse.status, request.method, {
      [DEBUG_WORKER_HEADER]: WORKER_MARKER,
      [DEBUG_CACHE_HEADER]: cacheState,
      [DEBUG_ORIGIN_STATUS_HEADER]: String(originResponse.status),
    });

    logEvent("info", "origin_fetch", {
      bucket,
      method: request.method,
      path: url.pathname,
      originStatus: originResponse.status,
      responseStatus: response.status,
      cacheState,
      range: request.headers.get("range") || null,
    });

    if (request.method === "GET" && isCacheableStatus(response.status)) {
      ctx.waitUntil(
        cache.put(cacheKey, response.clone()).catch((error) => {
          logEvent("error", "cache_put_failed", {
            bucket,
            method: request.method,
            path: url.pathname,
            status: response.status,
            error: String(error),
          });
        }),
      );
    }

    return response;
  },
};

function forwardHeaders(headers) {
  const nextHeaders = new Headers();

  for (const [key, value] of headers.entries()) {
    const lower = key.toLowerCase();
    if (lower === "host") continue;
    if (lower === "authorization") continue;
    if (lower === "cookie") continue;
    if (lower === "cf-connecting-ip") continue;
    nextHeaders.set(key, value);
  }

  return nextHeaders;
}

function buildCacheKey(url, request) {
  const cacheUrl = new URL(url.toString());
  const range = request.headers.get("range");

  if (range) {
    cacheUrl.searchParams.set("__range", range);
  }

  return new Request(cacheUrl.toString(), { method: "GET" });
}

async function normalizeOriginResponse(originResponse) {
  if (originResponse.status !== 400) {
    return originResponse;
  }

  const contentType = String(originResponse.headers.get("content-type") || "").toLowerCase();
  if (!contentType.includes("application/json")) {
    return originResponse;
  }

  const bodyText = await originResponse.clone().text();
  const parsed = safeParseJson(bodyText);
  const rawStatusCode = parsed && parsed.statusCode;
  const statusCode =
    typeof rawStatusCode === "number" ? rawStatusCode : Number.parseInt(rawStatusCode, 10);

  if (statusCode !== 404 && parsed?.error !== "not_found") {
    return originResponse;
  }

  logEvent("info", "normalize_not_found", {
    originStatus: originResponse.status,
    responseStatus: 404,
  });

  const headers = new Headers(originResponse.headers);
  headers.delete("content-length");

  return new Response(bodyText, {
    status: 404,
    statusText: "Not Found",
    headers,
  });
}

function buildClientResponse(originResponse, originStatus, method, extraHeaders = {}) {
  const headers = sanitizeResponseHeaders(originResponse.headers);
  headers.set("Cache-Control", cacheControlForStatus(originResponse.status));
  headers.set("X-Content-Type-Options", "nosniff");

  for (const [key, value] of Object.entries(extraHeaders)) {
    headers.set(key, value);
  }

  return new Response(method === "HEAD" ? null : originResponse.body, {
    status: originResponse.status,
    statusText: originResponse.statusText || statusTextFor(originResponse.status, originStatus),
    headers,
  });
}

function sanitizeResponseHeaders(headers) {
  const nextHeaders = new Headers(headers);

  for (const name of INTERNAL_RESPONSE_HEADERS) {
    nextHeaders.delete(name);
  }

  return nextHeaders;
}

function cloneResponse(response, method, extraHeaders = {}) {
  const headers = sanitizeResponseHeaders(response.headers);

  for (const [key, value] of Object.entries(extraHeaders)) {
    headers.set(key, value);
  }

  return new Response(method === "HEAD" ? null : response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function cacheControlForStatus(status) {
  if (status === 200 || status === 206) {
    return IMMUTABLE_CACHE_CONTROL;
  }

  if (status === 404 || status === 403 || status === 405) {
    return SHORT_CACHE_CONTROL;
  }

  if (status >= 500) {
    return NO_STORE_CACHE_CONTROL;
  }

  return SHORT_CACHE_CONTROL;
}

function isCacheableStatus(status) {
  return status === 200 || status === 206 || status === 404;
}

function safeParseJson(value) {
  try {
    return JSON.parse(value);
  } catch (_error) {
    return null;
  }
}

function statusTextFor(status) {
  if (status === 404) return "Not Found";
  if (status === 405) return "Method Not Allowed";
  if (status === 403) return "Forbidden";
  if (status === 500) return "Internal Server Error";
  return "";
}

function textResponse(body, status, headers = {}) {
  return new Response(body, {
    status,
    headers,
  });
}

function logEvent(level, event, data) {
  const payload = JSON.stringify({
    scope: "media_cdn",
    event,
    ...data,
  });

  if (level === "error") {
    console.error(payload);
    return;
  }

  if (level === "warn") {
    console.warn(payload);
    return;
  }

  console.log(payload);
}
