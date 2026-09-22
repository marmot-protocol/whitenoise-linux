// One-shot Nostr fetch over a websocket: dial, send one REQ, hand back
// the first EVENT message, hang up. libcurl supplies the socket and the
// TLS (CONNECT_ONLY over https://); the upgrade handshake and the frame
// codec live here so the build does not need curl's ws API, which the
// libcurl in Ubuntu 24.04 (8.5) ships without.
//
//   nevent.odin ──wn_ws_fetch──▶ ws_shim.c ──libcurl──▶ wss://relay
//
// ponytail: no ping/pong, no fragment reassembly across control
// frames, no Sec-WebSocket-Accept check. Enough for a REQ that
// answers in one round trip; grow it if a relay starts pinging first.
#include <curl/curl.h>
#include <poll.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

// Block on the curl socket until it is readable/writable or the
// deadline passes. 0 = ready, -1 = timed out.
static int wait_sock(CURL *c, int for_recv, long deadline) {
    curl_socket_t s;
    if (curl_easy_getinfo(c, CURLINFO_ACTIVESOCKET, &s) != CURLE_OK) {
        return -1;
    }
    long left = deadline - now_ms();
    if (left <= 0) {
        return -1;
    }
    struct pollfd p = {.fd = s, .events = for_recv ? POLLIN : POLLOUT};
    return poll(&p, 1, (int)left) > 0 ? 0 : -1;
}

static int send_all(CURL *c, const unsigned char *b, size_t n, long deadline) {
    while (n > 0) {
        size_t sent = 0;
        CURLcode r = curl_easy_send(c, b, n, &sent);
        if (r == CURLE_AGAIN) {
            if (wait_sock(c, 0, deadline) < 0) {
                return -1;
            }
            continue;
        }
        if (r != CURLE_OK) {
            return -1;
        }
        b += sent;
        n -= sent;
    }
    return 0;
}

static int recv_all(CURL *c, unsigned char *b, size_t n, long deadline) {
    while (n > 0) {
        size_t got = 0;
        CURLcode r = curl_easy_recv(c, b, n, &got);
        if (r == CURLE_AGAIN) {
            if (wait_sock(c, 1, deadline) < 0) {
                return -1;
            }
            continue;
        }
        if (r != CURLE_OK || got == 0) {
            return -1;
        }
        b += got;
        n -= got;
    }
    return 0;
}

// One masked text frame, the client side of RFC 6455 §5.2.
static int send_text(CURL *c, const char *msg, long deadline) {
    size_t n = strlen(msg);
    unsigned char hdr[14];
    size_t hl = 2;
    hdr[0] = 0x81; // FIN + text
    if (n < 126) {
        hdr[1] = 0x80 | (unsigned char)n;
    } else if (n < 65536) {
        hdr[1] = 0x80 | 126;
        hdr[2] = (unsigned char)(n >> 8);
        hdr[3] = (unsigned char)n;
        hl = 4;
    } else {
        hdr[1] = 0x80 | 127;
        for (int i = 0; i < 8; i++) {
            hdr[2 + i] = (unsigned char)(n >> (56 - 8 * i));
        }
        hl = 10;
    }
    unsigned char mask[4] = {(unsigned char)rand(), (unsigned char)rand(), (unsigned char)rand(),
                             (unsigned char)rand()};
    memcpy(hdr + hl, mask, 4);
    hl += 4;
    unsigned char *body = malloc(n);
    if (!body) {
        return -1;
    }
    for (size_t i = 0; i < n; i++) {
        body[i] = (unsigned char)msg[i] ^ mask[i & 3];
    }
    int ok = send_all(c, hdr, hl, deadline) == 0 && send_all(c, body, n, deadline) == 0;
    free(body);
    return ok ? 0 : -1;
}

// Read one complete message into out (fragments concatenated).
// Returns its length, 0 for a control frame / a message the buffer
// cannot hold, -1 on close or socket error.
static long recv_message(CURL *c, unsigned char *out, size_t cap, long deadline) {
    size_t len = 0;
    for (;;) {
        unsigned char h[2];
        if (recv_all(c, h, 2, deadline) < 0) {
            return -1;
        }
        int fin = h[0] & 0x80, op = h[0] & 0x0F, masked = h[1] & 0x80;
        uint64_t n = h[1] & 0x7F;
        if (n == 126) {
            unsigned char e[2];
            if (recv_all(c, e, 2, deadline) < 0) {
                return -1;
            }
            n = ((uint64_t)e[0] << 8) | e[1];
        } else if (n == 127) {
            unsigned char e[8];
            if (recv_all(c, e, 8, deadline) < 0) {
                return -1;
            }
            n = 0;
            for (int i = 0; i < 8; i++) {
                n = (n << 8) | e[i];
            }
        }
        unsigned char mask[4] = {0};
        if (masked && recv_all(c, mask, 4, deadline) < 0) {
            return -1;
        }
        if (op == 8) {
            return -1;
        }
        int keep = (op == 1 || op == 0) && len + n <= cap;
        if (keep) {
            if (recv_all(c, out + len, (size_t)n, deadline) < 0) {
                return -1;
            }
            if (masked) {
                for (uint64_t i = 0; i < n; i++) {
                    out[len + i] ^= mask[i & 3];
                }
            }
            len += (size_t)n;
        } else {
            // Drain what we will not keep: a ping, a binary frame, or a
            // message past cap.
            unsigned char sink[4096];
            while (n > 0) {
                size_t chunk = n < sizeof sink ? (size_t)n : sizeof sink;
                if (recv_all(c, sink, chunk, deadline) < 0) {
                    return -1;
                }
                n -= chunk;
            }
            len = 0;
        }
        if (fin) {
            return (long)len;
        }
    }
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Sec-WebSocket-Key: 16 random bytes, base64. Servers only echo it.
static void ws_key(char out[25]) {
    unsigned char raw[16];
    for (int i = 0; i < 16; i++) {
        raw[i] = (unsigned char)rand();
    }
    for (int i = 0, o = 0; i < 16; i += 3, o += 4) {
        uint32_t v = (uint32_t)raw[i] << 16 | (uint32_t)(i + 1 < 16 ? raw[i + 1] : 0) << 8 |
                     (i + 2 < 16 ? raw[i + 2] : 0);
        out[o] = B64[v >> 18 & 63];
        out[o + 1] = B64[v >> 12 & 63];
        out[o + 2] = i + 1 < 16 ? B64[v >> 6 & 63] : '=';
        out[o + 3] = i + 2 < 16 ? B64[v & 63] : '=';
    }
    out[24] = 0;
}

// Send `req` (a Nostr REQ array) to `url` (wss:// or ws://) and copy
// the first message beginning with ["EVENT" into out. Returns its
// length; 0 when EOSE/CLOSED/NOTICE arrives first; -1 when the dial or
// the handshake fails. The caller frees nothing.
int wn_ws_fetch(const char *url, const char *req, char *out, size_t cap, long timeout_ms) {
    long deadline = now_ms() + timeout_ms;
    const char *rest = strstr(url, "://");
    if (!rest) {
        return -1;
    }
    int tls = strncmp(url, "wss://", 6) == 0;
    rest += 3;
    const char *slash = strchr(rest, '/');
    size_t host_len = slash ? (size_t)(slash - rest) : strlen(rest);
    const char *path = slash ? slash : "/";
    if (host_len == 0 || host_len > 250) {
        return -1;
    }
    char host[256];
    memcpy(host, rest, host_len);
    host[host_len] = 0;

    char http_url[1024];
    snprintf(http_url, sizeof http_url, "%s://%s%s", tls ? "https" : "http", host, path);

    CURL *c = curl_easy_init();
    if (!c) {
        return -1;
    }
    curl_easy_setopt(c, CURLOPT_URL, http_url);
    curl_easy_setopt(c, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT_MS, timeout_ms);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    // Raw HTTP/1.1 only: an ALPN-negotiated h2 socket would frame the
    // handshake bytes as a stream instead of passing them through.
    curl_easy_setopt(c, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(c, CURLOPT_SSL_ENABLE_ALPN, 0L);
    int debug = getenv("WN_WS_DEBUG") != NULL;
    curl_easy_setopt(c, CURLOPT_VERBOSE, (long)debug);
    int result = -1;
    if (curl_easy_perform(c) != CURLE_OK) {
        goto done;
    }

    char key[25];
    ws_key(key);
    char hs[1536];
    int hl = snprintf(hs, sizeof hs,
                      "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
                      path, host, key);
    if (hl <= 0 || (size_t)hl >= sizeof hs ||
        send_all(c, (unsigned char *)hs, (size_t)hl, deadline) < 0) {
        goto done;
    }

    // Byte-at-a-time so nothing past the blank line is swallowed: the
    // bytes after it are already frames.
    char resp[4096];
    size_t rl = 0;
    for (;;) {
        if (rl + 1 >= sizeof resp || recv_all(c, (unsigned char *)resp + rl, 1, deadline) < 0) {
            goto done;
        }
        rl++;
        if (rl >= 4 && memcmp(resp + rl - 4, "\r\n\r\n", 4) == 0) {
            break;
        }
    }
    resp[rl] = 0;
    if (debug) {
        fprintf(stderr, "[ws] %s -> %.*s\n", url, (int)strcspn(resp, "\r"), resp);
    }
    if (strncmp(resp, "HTTP/1.1 101", 12) != 0) {
        goto done;
    }

    if (send_text(c, req, deadline) < 0) {
        goto done;
    }
    result = 0;
    for (;;) {
        long n = recv_message(c, (unsigned char *)out, cap, deadline);
        if (n < 0) {
            break;
        }
        if (n >= 8 && strncmp(out, "[\"EVENT\"", 8) == 0) {
            result = (int)n;
            break;
        }
        if (n >= 7 && (strncmp(out, "[\"EOSE\"", 7) == 0 || strncmp(out, "[\"CLOSED\"", 9) == 0)) {
            break;
        }
    }

done:
    curl_easy_cleanup(c);
    return result;
}
