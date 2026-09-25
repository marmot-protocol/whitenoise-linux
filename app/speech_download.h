// Shared by the TTS and STT helpers; the including file supplies its manifest.
#include <openssl/evp.h>
#include <glib/gstdio.h>
static int valid_file(const char *path, const ModelFile *model) {
    GStatBuf st;
    if (g_stat(path, &st) || st.st_size < 0 || (size_t)st.st_size != model->size) {
        return 0;
    }
    FILE *file = g_fopen(path, "rb");
    if (!file) {
        return 0;
    }
    EVP_MD_CTX *sum = EVP_MD_CTX_new();
    int ok = sum && EVP_DigestInit_ex(sum, EVP_sha256(), NULL) == 1;
    unsigned char buf[65536];
    size_t n;
    while (ok && (n = fread(buf, 1, sizeof(buf), file)) > 0) {
        ok = EVP_DigestUpdate(sum, buf, n) == 1;
    }
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    ok = ok && !ferror(file) && EVP_DigestFinal_ex(sum, digest, &length) == 1 && length == 32;
    EVP_MD_CTX_free(sum);
    if (ok) {
        char hex[65];
        for (unsigned int i = 0; i < length; ++i) {
            snprintf(hex + i * 2, 3, "%02x", digest[i]);
        }
        ok = !strcmp(hex, model->sha256);
    }
    fclose(file);
    return ok;
}

typedef struct {
    FILE *file;
    size_t remaining;
    const ModelFile *model;
    unsigned char percent;
} Download;

static size_t download_write(char *data, size_t size, size_t count, void *user) {
    Download *download = user;
    if (size && count > download->remaining / size) {
        return 0;
    }
    size_t bytes = size * count;
    size_t written = fwrite(data, 1, bytes, download->file);
    download->remaining -= written;
    unsigned char percent = (unsigned char)(100 * (download->model->size - download->remaining) /
                                            download->model->size);
    if (percent != download->percent) {
        unsigned char update[] = {'D', (unsigned char)(download->model - models), percent};
        if (wn_ipc_write(speech_ipc, update, sizeof(update), 0) != sizeof(update)) {
            return 0;
        }
        download->percent = percent;
    }
    return written;
}

static int ensure_model(const char *dir, const ModelFile *model) {
    char *path = g_build_filename(dir, model->name, NULL);
    if (valid_file(path, model)) {
        g_free(path);
        return 1;
    }
    unsigned char update[] = {'D', (unsigned char)(model - models), 0};
    if (wn_ipc_write(speech_ipc, update, sizeof(update), 0) != sizeof(update)) {
        g_free(path);
        return 0;
    }
    char *parent = g_path_get_dirname(path);
    int ready = g_mkdir_with_parents(parent, 0700) == 0;
    g_free(parent);
    char *partial = g_strdup_printf("%s.part", path);
    FILE *file = ready ? g_fopen(partial, "wb") : NULL;
    CURL *curl = file ? curl_easy_init() : NULL;
    int ok = 0;
    if (curl) {
        char *url = g_strdup_printf("%s/%s", MODEL_URL, model->name);
        Download download = {.file = file, .remaining = model->size, .model = model};
        curl_easy_setopt(curl, CURLOPT_URL, url);
        const char *ca_file = getenv("SSL_CERT_FILE");
        if (ca_file && *ca_file)
            curl_easy_setopt(curl, CURLOPT_CAINFO, ca_file);
        curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
        curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "https");
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
        curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);
        curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1024L);
        curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 60L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, download_write);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &download);
        ok = curl_easy_perform(curl) == CURLE_OK;
        curl_easy_cleanup(curl);
        g_free(url);
    }
    if (file && fclose(file)) {
        ok = 0;
    }
    if (ok) {
        ok = valid_file(partial, model) && g_rename(partial, path) == 0;
    }
    g_unlink(partial);
    g_free(partial);
    g_free(path);
    return ok;
}
