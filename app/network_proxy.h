#ifndef WN_NETWORK_PROXY_H
#define WN_NETWORK_PROXY_H

#include <curl/curl.h>
#include <stdlib.h>
#include "proxy_credentials.h"

/* Explicit proxy mode overrides NO_PROXY and resolves destinations through
 * SOCKS5. A configuration error stops the request rather than dialing direct. */
static CURLcode wn_curl_proxy(CURL *curl) {
    const char *proxy = getenv("WN_SOCKS5_PROXY");
    const char *username, *password;
    int authentication = wn_proxy_credentials(&username, &password);
    if (authentication < 0 || (authentication && (!proxy || !*proxy))) {
        return CURLE_BAD_FUNCTION_ARGUMENT;
    }
    if (!proxy || !*proxy) {
        return CURLE_OK;
    }
    CURLcode status = curl_easy_setopt(curl, CURLOPT_PROXY, proxy);
    if (status != CURLE_OK) {
        return status;
    }
    status = curl_easy_setopt(curl, CURLOPT_PROXYTYPE, (long)CURLPROXY_SOCKS5_HOSTNAME);
    if (status != CURLE_OK) {
        return status;
    }
    status = curl_easy_setopt(curl, CURLOPT_SOCKS5_AUTH,
                              (long)(authentication ? CURLAUTH_BASIC : CURLAUTH_NONE));
    if (status != CURLE_OK) {
        return status;
    }
    status = curl_easy_setopt(curl, CURLOPT_PROXYUSERNAME, authentication ? username : NULL);
    if (status != CURLE_OK) {
        return status;
    }
    status = curl_easy_setopt(curl, CURLOPT_PROXYPASSWORD, authentication ? password : NULL);
    if (status != CURLE_OK) {
        return status;
    }
    return curl_easy_setopt(curl, CURLOPT_NOPROXY, "");
}

#endif
