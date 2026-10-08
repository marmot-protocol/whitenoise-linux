#define _POSIX_C_SOURCE 200809L
#include "../app/network_proxy.h"
#include <assert.h>

int main(void) {
    CURL *curl = curl_easy_init();
    assert(curl);
    assert(setenv("WN_SOCKS5_PROXY", "127.0.0.1:9050", 1) == 0);
    assert(unsetenv("WN_SOCKS5_USERNAME") == 0);
    assert(unsetenv("WN_SOCKS5_PASSWORD") == 0);
    assert(setenv("WN_SOCKS5_USERNAME", "user", 1) == 0);
    assert(wn_curl_proxy(curl) == CURLE_BAD_FUNCTION_ARGUMENT);
    assert(setenv("WN_SOCKS5_PASSWORD", "", 1) == 0);
    assert(wn_curl_proxy(curl) == CURLE_BAD_FUNCTION_ARGUMENT);
    char boundary[257];
    memset(boundary, 'x', 255);
    boundary[255] = 0;
    assert(wn_proxy_credential_valid(boundary));
    boundary[255] = 'x';
    boundary[256] = 0;
    assert(!wn_proxy_credential_valid(boundary));
    assert(wn_proxy_credential_valid("\xc2\x80\xe0\xa0\x80\xed\x9f\xbf\xf4\x8f\xbf\xbf"));
    assert(!wn_proxy_credential_valid("\xc0\x80"));
    assert(!wn_proxy_credential_valid("\xe0\x80\x80"));
    assert(!wn_proxy_credential_valid("\xed\xa0\x80"));
    assert(!wn_proxy_credential_valid("\xf4\x90\x80\x80"));
    assert(!wn_proxy_credential_valid("\xf0\x9f"));
    assert(setenv("WN_SOCKS5_PASSWORD", "\x80", 1) == 0);
    assert(wn_curl_proxy(curl) == CURLE_BAD_FUNCTION_ARGUMENT);
    assert(setenv("WN_SOCKS5_PASSWORD", "password", 1) == 0);
    assert(unsetenv("WN_SOCKS5_PROXY") == 0);
    assert(wn_curl_proxy(curl) == CURLE_BAD_FUNCTION_ARGUMENT);
    curl_easy_cleanup(curl);
    return 0;
}
