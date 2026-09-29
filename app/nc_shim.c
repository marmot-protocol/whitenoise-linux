// Namecoin ElectrumX one-shot JSON-RPC over WebSocket Secure.
//
// The Namecoin `.bit` resolver in namecoin.odin needs a browser-shaped
// WSS client so it can reach the ElectrumX endpoints Namecoin operators
// publish (see DEFAULT_ELECTRUMX_SERVERS). Same shape as ws_shim.c: dial
// with libcurl CONNECT_ONLY over https://, do the RFC 6455 handshake
// here, ship one masked text frame, then read frames off the socket and
// hand the first reply whose JSON id matches the request back to Odin.
//
//   namecoin.odin ──wn_nc_call──▶ nc_shim.c ──libcurl──▶ wss://electrumx
//
// One call = one RPC = one socket. The Odin caller opens a fresh socket
// for every method it wants; the resolver only issues a few per name
// (server.version, blockchain.scripthash.get_history,
// blockchain.transaction.get, and optionally blockchain.headers.subscribe)
// and short-lived sockets keep the per-server timeout the resolver's
// only fallback signal.
//
// ponytail: shares no code with ws_shim.c today. Both files carry the
// same tiny RFC 6455 codec; fold them into one wn_ws helper when a
// third caller appears.
#include <curl/curl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static long nc_now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int nc_wait_sock(CURL *c, int for_recv, long deadline) {
	curl_socket_t s;
	if (curl_easy_getinfo(c, CURLINFO_ACTIVESOCKET, &s) != CURLE_OK) {
		return -1;
	}
	long left = deadline - nc_now_ms();
	if (left <= 0) {
		return -1;
	}
	struct pollfd p = {.fd = s, .events = for_recv ? POLLIN : POLLOUT};
	return poll(&p, 1, (int)left) > 0 ? 0 : -1;
}

static int nc_send_all(CURL *c, const unsigned char *b, size_t n, long deadline) {
	while (n > 0) {
		size_t sent = 0;
		CURLcode r = curl_easy_send(c, b, n, &sent);
		if (r == CURLE_AGAIN) {
			if (nc_wait_sock(c, 0, deadline) < 0) {
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

static int nc_recv_all(CURL *c, unsigned char *b, size_t n, long deadline) {
	while (n > 0) {
		size_t got = 0;
		CURLcode r = curl_easy_recv(c, b, n, &got);
		if (r == CURLE_AGAIN) {
			if (nc_wait_sock(c, 1, deadline) < 0) {
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

// One masked text frame, RFC 6455 §5.2 client side.
static int nc_send_text(CURL *c, const char *msg, long deadline) {
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
	int ok = nc_send_all(c, hdr, hl, deadline) == 0 && nc_send_all(c, body, n, deadline) == 0;
	free(body);
	return ok ? 0 : -1;
}

// Read one complete message into out (fragments concatenated). Returns
// its length, 0 for control / oversize (drained), -1 on close or error.
// A masked server frame is unmasked in place; the ElectrumX servers do
// not mask, but the RFC allows it and it costs one branch.
static long nc_recv_message(CURL *c, unsigned char *out, size_t cap, long deadline) {
	size_t len = 0;
	for (;;) {
		unsigned char h[2];
		if (nc_recv_all(c, h, 2, deadline) < 0) {
			return -1;
		}
		int fin = h[0] & 0x80, op = h[0] & 0x0F, masked = h[1] & 0x80;
		uint64_t n = h[1] & 0x7F;
		if (n == 126) {
			unsigned char e[2];
			if (nc_recv_all(c, e, 2, deadline) < 0) {
				return -1;
			}
			n = ((uint64_t)e[0] << 8) | e[1];
		} else if (n == 127) {
			unsigned char e[8];
			if (nc_recv_all(c, e, 8, deadline) < 0) {
				return -1;
			}
			n = 0;
			for (int i = 0; i < 8; i++) {
				n = (n << 8) | e[i];
			}
		}
		unsigned char mask[4] = {0};
		if (masked && nc_recv_all(c, mask, 4, deadline) < 0) {
			return -1;
		}
		if (op == 8) {
			return -1;
		}
		// Reject frames larger than the caller's buffer up front. `n` is a
		// 64-bit length under attacker control; comparing `len + n` before
		// this check overflows when a server (or MITM) sends a length near
		// UINT64_MAX and drops the arithmetic into a wrap. Cap `n` at
		// `cap - len` (both non-negative size_t) so the arithmetic stays in
		// range, and additionally refuse anything above a hard cap so a
		// hostile server cannot pin us in `nc_recv_all` reading many GiB.
		const uint64_t NC_HARD_FRAME_CAP = 16 * 1024 * 1024;
		size_t room = cap > len ? cap - len : 0;
		int keep = (op == 1 || op == 0) && n <= NC_HARD_FRAME_CAP && n <= (uint64_t)room;
		if (keep) {
			if (nc_recv_all(c, out + len, (size_t)n, deadline) < 0) {
				return -1;
			}
			if (masked) {
				for (uint64_t i = 0; i < n; i++) {
					out[len + i] ^= mask[i & 3];
				}
			}
			len += (size_t)n;
		} else {
			unsigned char sink[4096];
			while (n > 0) {
				size_t chunk = n < sizeof sink ? (size_t)n : sizeof sink;
				if (nc_recv_all(c, sink, chunk, deadline) < 0) {
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

static const char NC_B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void nc_ws_key(char out[25]) {
	unsigned char raw[16];
	for (int i = 0; i < 16; i++) {
		raw[i] = (unsigned char)rand();
	}
	for (int i = 0, o = 0; i < 16; i += 3, o += 4) {
		uint32_t v = (uint32_t)raw[i] << 16 | (uint32_t)(i + 1 < 16 ? raw[i + 1] : 0) << 8 |
					 (i + 2 < 16 ? raw[i + 2] : 0);
		out[o] = NC_B64[v >> 18 & 63];
		out[o + 1] = NC_B64[v >> 12 & 63];
		out[o + 2] = i + 1 < 16 ? NC_B64[v >> 6 & 63] : '=';
		out[o + 3] = i + 2 < 16 ? NC_B64[v & 63] : '=';
	}
	out[24] = 0;
}

// Extract the top-level "id" from a JSON-RPC 2.0 reply envelope.
//
// Correctness contract: return the integer value of the key "id" at
// object depth 1 of the outermost JSON value. Return -1 when the
// envelope is not a JSON object, when "id" is missing at depth 1, when
// it is not an integer, or when the buffer is not well-formed enough to
// walk. Nested `{"result":{"id":99},"id":2}` returns 2; whitespace
// between the colon and the number is allowed; `"id"` occurring inside
// a string value is ignored; `"id"` occurring at a nested depth is
// ignored.
//
// The shim is not a full JSON parser: this walker only tracks (a)
// string state with backslash escapes and (b) structural depth via
// `{ [ ] }`. That is sufficient for the ElectrumX subset of JSON-RPC
// 2.0 the resolver speaks — one flat envelope per reply. The Odin
// caller re-validates the envelope with core:encoding/json before
// trusting any payload; this scanner exists only to filter server
// notifications from replies at the socket layer.
static int nc_message_id(const char *buf, long len) {
	int depth = 0; // 0 = before outer, 1 = inside outer object, >1 = nested
	int in_str = 0;
	int escaped = 0;
	long i = 0;

	while (i < len) {
		char c = buf[i];
		if (in_str) {
			if (escaped) {
				escaped = 0;
			} else if (c == '\\') {
				escaped = 1;
			} else if (c == '"') {
				in_str = 0;
			}
			i++;
			continue;
		}
		if (c == '"') {
			// Only match `"id"` when we are at depth 1 (a key of the
			// outer envelope). Anywhere else: consume as a string.
			if (depth == 1 && i + 3 < len && buf[i + 1] == 'i' && buf[i + 2] == 'd' &&
				buf[i + 3] == '"') {
				long j = i + 4;
				while (j < len &&
					   (buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\r' || buf[j] == '\n')) {
					j++;
				}
				if (j >= len || buf[j] != ':') {
					// `"id"` occurred as a value or without a colon — skip.
					i = j;
					continue;
				}
				j++;
				while (j < len &&
					   (buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\r' || buf[j] == '\n')) {
					j++;
				}
				if (j >= len) {
					return -1;
				}
				int neg = 0;
				if (buf[j] == '-') {
					neg = 1;
					j++;
				}
				long val = 0;
				int digits = 0;
				while (j < len && buf[j] >= '0' && buf[j] <= '9' && digits < 10) {
					val = val * 10 + (buf[j] - '0');
					j++;
					digits++;
				}
				if (digits == 0) {
					// `"id"` at depth 1 but not an integer (null / string).
					return -1;
				}
				return neg ? -(int)val : (int)val;
			}
			in_str = 1;
			i++;
			continue;
		}
		if (c == '{' || c == '[') {
			depth++;
		} else if (c == '}' || c == ']') {
			depth--;
			if (depth < 0) {
				return -1;
			}
		}
		i++;
	}
	return -1;
}

// Do one ElectrumX JSON-RPC call at `url` (wss:// or ws://) and copy the
// reply body whose id matches `want_id` into out. Returns the reply
// length; -1 for dial or handshake failure, timeout, or socket close
// without a matching reply. Caller frees nothing.
//
// `req` is the caller-supplied JSON-RPC 2.0 request body already carrying
// the id `want_id`; the shim does not synthesize it. `want_id` is the
// integer id the caller placed in `req`, used to filter server pushes
// (blockchain.headers.subscribe notifications, etc.) that ElectrumX may
// interleave with the reply.
//
// `pin` (NULL or empty) is a libcurl CURLOPT_PINNEDPUBLICKEY value.
// When non-empty the TLS handshake requires the leaf's public key SHA-256
// to equal the pin; the server cert chain is NOT walked against system
// CAs. This is how Namecoin's ElectrumX operators (self-signed by
// convention) are trusted here without disabling TLS. Pass NULL/"" to
// require a browser-trusted chain.
int wn_nc_call(const char *url, const char *req, const char *pin, int want_id, char *out,
			   size_t cap, long timeout_ms) {
	long deadline = nc_now_ms() + timeout_ms;
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
	// Raw HTTP/1.1: an ALPN-negotiated h2 socket would frame the
	// handshake bytes as a stream.
	curl_easy_setopt(c, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
	curl_easy_setopt(c, CURLOPT_SSL_ENABLE_ALPN, 0L);
	if (tls && pin != NULL && pin[0] != '\0') {
		// Pinning replaces chain-of-trust verification with a public-key
		// equality check: the server's leaf must present a public key
		// whose SHA-256 matches the caller-supplied pin. A wrong pin
		// (rotated cert, MITM) fails the TLS handshake before any data
		// flows. See the pinned server list in namecoin.odin for the
		// fingerprints and the rotation runbook.
		curl_easy_setopt(c, CURLOPT_PINNEDPUBLICKEY, pin);
		curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
		curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, 0L);
	}
	int debug = getenv("WN_NC_DEBUG") != NULL;
	curl_easy_setopt(c, CURLOPT_VERBOSE, (long)debug);
	int result = -1;
	if (curl_easy_perform(c) != CURLE_OK) {
		goto done;
	}

	char key[25];
	nc_ws_key(key);
	char hs[1536];
	int hl = snprintf(hs, sizeof hs,
					  "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
					  "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
					  path, host, key);
	if (hl <= 0 || (size_t)hl >= sizeof hs ||
		nc_send_all(c, (unsigned char *)hs, (size_t)hl, deadline) < 0) {
		goto done;
	}

	char resp[4096];
	size_t rl = 0;
	for (;;) {
		if (rl + 1 >= sizeof resp || nc_recv_all(c, (unsigned char *)resp + rl, 1, deadline) < 0) {
			goto done;
		}
		rl++;
		if (rl >= 4 && memcmp(resp + rl - 4, "\r\n\r\n", 4) == 0) {
			break;
		}
	}
	resp[rl] = 0;
	if (debug) {
		fprintf(stderr, "[nc] %s -> %.*s\n", url, (int)strcspn(resp, "\r"), resp);
	}
	if (strncmp(resp, "HTTP/1.1 101", 12) != 0) {
		goto done;
	}

	if (nc_send_text(c, req, deadline) < 0) {
		goto done;
	}
	for (;;) {
		long n = nc_recv_message(c, (unsigned char *)out, cap, deadline);
		if (n < 0) {
			break;
		}
		if (n == 0) {
			// Control frame or oversize message the reader drained;
			// keep going for the real reply.
			continue;
		}
		int id = nc_message_id(out, n);
		if (id == want_id) {
			result = (int)n;
			break;
		}
		// Notification (subscribe result push) or an id we did not ask
		// for; keep reading.
	}

done:
	curl_easy_cleanup(c);
	return result;
}
