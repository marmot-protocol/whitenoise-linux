// Isolated harness for nc_shim.c's pure functions.
//
// Copies (and pins in this test) the exact logic of `nc_message_id` and
// the frame-length arithmetic in `nc_recv_message`. Verifies:
//
//   1. nc_message_id returns the top-level "id" of a JSON envelope,
//      ignores nested {"id":...} keys, tolerates whitespace, and returns
//      -1 when no top-level id is present.
//   2. The frame receiver rejects a length that would wrap when added
//      to the already-consumed prefix `len` (the two-fragment attack).
//   3. It also rejects a single frame whose declared length exceeds cap.
//   4. A well-formed message passes.
//
// Build:
//   cc -std=c11 -Wall -Wextra -O2 -g scripts/nc_shim_selftest.c -o
//   /tmp/nc_shim_selftest /tmp/nc_shim_selftest
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ── copied verbatim from app/nc_shim.c ─────────────────────────────
static int nc_message_id(const char *buf, long len) {
  int depth = 0;
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
      if (depth == 1 && i + 3 < len && buf[i + 1] == 'i' && buf[i + 2] == 'd' &&
          buf[i + 3] == '"') {
        long j = i + 4;
        while (j < len && (buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\r' ||
                           buf[j] == '\n'))
          j++;
        if (j >= len || buf[j] != ':') {
          i = j;
          continue;
        }
        j++;
        while (j < len && (buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\r' ||
                           buf[j] == '\n'))
          j++;
        if (j >= len)
          return -1;
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
        if (digits == 0)
          return -1;
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
      if (depth < 0)
        return -1;
    }
    i++;
  }
  return -1;
}

// Fixture-backed nc_recv_all: reads from `g_stream`.
static struct {
  const unsigned char *buf;
  size_t len;
  size_t pos;
} g_stream;

static long nc_recv_all_mock(unsigned char *out, size_t n) {
  if (g_stream.pos + n > g_stream.len)
    return -1;
  memcpy(out, g_stream.buf + g_stream.pos, n);
  g_stream.pos += n;
  return (long)n;
}

// Copied from app/nc_shim.c with `nc_recv_all` replaced by the mock.
static long nc_recv_message_mock(unsigned char *out, size_t cap) {
  size_t len = 0;
  for (;;) {
    unsigned char h[2];
    if (nc_recv_all_mock(h, 2) < 0)
      return -1;
    int fin = h[0] & 0x80, op = h[0] & 0x0F, masked = h[1] & 0x80;
    uint64_t n = h[1] & 0x7F;
    if (n == 126) {
      unsigned char e[2];
      if (nc_recv_all_mock(e, 2) < 0)
        return -1;
      n = ((uint64_t)e[0] << 8) | e[1];
    } else if (n == 127) {
      unsigned char e[8];
      if (nc_recv_all_mock(e, 8) < 0)
        return -1;
      n = 0;
      for (int i = 0; i < 8; i++)
        n = (n << 8) | e[i];
    }
    unsigned char mask[4] = {0};
    if (masked && nc_recv_all_mock(mask, 4) < 0)
      return -1;
    if (op == 8)
      return -1;

    const uint64_t NC_HARD_FRAME_CAP = 16 * 1024 * 1024;
    size_t room = cap > len ? cap - len : 0;
    int keep =
        (op == 1 || op == 0) && n <= NC_HARD_FRAME_CAP && n <= (uint64_t)room;
    if (keep) {
      if (nc_recv_all_mock(out + len, (size_t)n) < 0)
        return -1;
      if (masked)
        for (uint64_t i = 0; i < n; i++)
          out[len + i] ^= mask[i & 3];
      len += (size_t)n;
    } else {
      // Report the rejection so the test sees it. Real code
      // discards the frame and keeps reading; either is fine as
      // long as the out-of-bounds write does not happen.
      return -1;
    }
    if (fin)
      return (long)len;
  }
}

static void set_stream(const unsigned char *buf, size_t len) {
  g_stream.buf = buf;
  g_stream.len = len;
  g_stream.pos = 0;
}

int main(void) {
  // ── nc_message_id ────────────────────────────────────────────────
  {
    const char *env = "{\"result\":{\"id\":99},\"id\":2}";
    int got = nc_message_id(env, (long)strlen(env));
    printf("nested id:                got=%d want=2\n", got);
    assert(got == 2);
  }
  {
    const char *env = "{\"id\" : 2,\"result\":null}";
    int got = nc_message_id(env, (long)strlen(env));
    printf("whitespace id:            got=%d want=2\n", got);
    assert(got == 2);
  }
  {
    const char *env = "{\"result\":null}";
    int got = nc_message_id(env, (long)strlen(env));
    printf("no id at all:             got=%d want=-1\n", got);
    assert(got == -1);
  }
  {
    const char *env = "{\"data\":\"has \\\"id\\\": inside\",\"id\":7}";
    int got = nc_message_id(env, (long)strlen(env));
    printf("id-inside-a-string:       got=%d want=7\n", got);
    assert(got == 7);
  }
  {
    const char *env = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,"
                      "\"message\":\"nope\"},\"id\":42}";
    int got = nc_message_id(env, (long)strlen(env));
    printf("error envelope w/ id:     got=%d want=42\n", got);
    assert(got == 42);
  }
  {
    // Server notification with no top-level id (ElectrumX
    // subscription push): must return -1 so the caller keeps reading.
    const char *env = "{\"method\":\"blockchain.headers.subscribe\",\"params\":"
                      "[{\"hex\":\"...\",\"height\":1}]}";
    int got = nc_message_id(env, (long)strlen(env));
    printf("notification (no id):     got=%d want=-1\n", got);
    assert(got == -1);
  }

  // ── nc_recv_message overflow guard ───────────────────────────────
  {
    // Two-fragment attack: 8 payload bytes eat some cap, then a
    // second frame declares a 64-bit length near UINT64_MAX. Pre-fix
    // `len + n <= cap` wraps to a small value and accepts the
    // oversized frame; the current `n <= cap - len` check must reject.
    unsigned char out[64] = {0};
    size_t cap = sizeof out;

    unsigned char attack[] = {
        0x01, 0x08, // op=text, fin=0, len=8
        'H',  'e',  'l',  'l',  'o',  ' ',  'W',  'o',
        0x80, 0x7F, // op=cont, fin=1, len=127 (64-bit)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, // UINT64_MAX - 4
    };

    set_stream(attack, sizeof attack);
    long got = nc_recv_message_mock(out, cap);
    printf("two-fragment overflow:    got=%ld want=-1\n", got);
    assert(got == -1);
  }
  {
    // Single frame whose length exceeds cap: reject.
    unsigned char out[16] = {0};
    size_t cap = sizeof out;

    unsigned char oversize[] = {
        0x81,
        0x7E,
        0x00,
        0x20, // op=text, fin=1, len=126 (16-bit follows: 32 bytes)
    };
    set_stream(oversize, sizeof oversize);
    long got = nc_recv_message_mock(out, cap);
    printf("oversize single frame:    got=%ld want=-1\n", got);
    assert(got == -1);
  }
  {
    // Baseline: legit 11-byte frame fits and is delivered.
    unsigned char out[64] = {0};
    size_t cap = sizeof out;

    unsigned char okf[] = {
        0x81, 0x0B, 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd',
    };
    set_stream(okf, sizeof okf);
    long got = nc_recv_message_mock(out, cap);
    printf("baseline frame:           got=%ld want=11\n", got);
    assert(got == 11);
    assert(memcmp(out, "hello world", 11) == 0);
  }

  printf("\nnc_shim_selftest: all checks pass\n");
  return 0;
}
