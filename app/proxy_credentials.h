#ifndef WN_PROXY_CREDENTIALS_H
#define WN_PROXY_CREDENTIALS_H

#include <stdlib.h>
#include <string.h>

/* Environment strings cannot contain NUL. Validate bytes, not codepoints:
 * RFC 1929 limits each UTF-8 credential to 255 bytes. Never report their value. */
static int wn_proxy_credential_valid(const char *value) {
    size_t length = strlen(value);
    if (length == 0 || length > 255) {
        return 0;
    }
    const unsigned char *s = (const unsigned char *)value;
    for (size_t i = 0; i < length;) {
        unsigned char first = s[i++];
        if (first < 0x80) {
            continue;
        }
        unsigned need;
        unsigned char low = 0x80, high = 0xbf;
        if (first >= 0xc2 && first <= 0xdf) {
            need = 1;
        } else if (first >= 0xe0 && first <= 0xef) {
            need = 2;
            if (first == 0xe0) {
                low = 0xa0;
            }
            if (first == 0xed) {
                high = 0x9f;
            }
        } else if (first >= 0xf0 && first <= 0xf4) {
            need = 3;
            if (first == 0xf0) {
                low = 0x90;
            }
            if (first == 0xf4) {
                high = 0x8f;
            }
        } else {
            return 0;
        }
        if (length - i < need || s[i] < low || s[i] > high) {
            return 0;
        }
        i++;
        while (--need) {
            if (s[i] < 0x80 || s[i] > 0xbf) {
                return 0;
            }
            i++;
        }
    }
    return 1;
}

/* 0 = anonymous, 1 = authenticated, -1 = invalid (fail closed). */
static int wn_proxy_credentials(const char **username, const char **password) {
    *username = getenv("WN_SOCKS5_USERNAME");
    *password = getenv("WN_SOCKS5_PASSWORD");
    if (!*username) {
        *username = "";
    }
    if (!*password) {
        *password = "";
    }
    if (!**username && !**password) {
        return 0;
    }
    return wn_proxy_credential_valid(*username) && wn_proxy_credential_valid(*password) ? 1 : -1;
}

#endif
