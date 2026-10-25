// Only model assets touch disk. Message text and results stay in anonymous IPC.
#include <llama.h>
#include <fasttext.h>
#include <curl/curl.h>
#include <glib.h>
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <vector>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>
extern "C" {
#include "helper_ipc.h"
}
#include "translation_models.h"

static WnIpc *speech_ipc;
static bool runtime_started;
#include "speech_download.h"

enum { DOWNLOAD_ERROR = 1, INFERENCE_ERROR = 2, SOURCE_ERROR = 3, LIMIT_ERROR = 4 };
enum {
    REGION = 65536,
    HEADER = 8,
    OUTPUT = HEADER + REGION,
    IPC_SIZE = OUTPUT + REGION,
    INPUT_TOKENS = 2048,
    OUTPUT_TOKENS = 2048,
    CONTEXT = INPUT_TOKENS + OUTPUT_TOKENS,
    BATCH = 64
};

struct Language {
    const char *code, *name;
};
// Base forms also serve fastText's language (not dialect) predictions.
static const Language languages[] = {
    {"en", "English"},       {"ar", "Arabic"},     {"ar-EG", "Arabic"},    {"ar-SA", "Arabic"},
    {"bg", "Bulgarian"},     {"bn", "Bengali"},    {"ca", "Catalan"},      {"cs", "Czech"},
    {"da", "Danish"},        {"de", "German"},     {"el", "Greek"},        {"es", "Spanish"},
    {"et", "Estonian"},      {"fa", "Persian"},    {"fi", "Finnish"},      {"fil-PH", "Filipino"},
    {"fr", "French"},        {"fr-CA", "French"},  {"fr-FR", "French"},    {"gu", "Gujarati"},
    {"he", "Hebrew"},        {"hi", "Hindi"},      {"hr", "Croatian"},     {"hu", "Hungarian"},
    {"id", "Indonesian"},    {"is", "Icelandic"},  {"it", "Italian"},      {"ja", "Japanese"},
    {"kn", "Kannada"},       {"ko", "Korean"},     {"lt", "Lithuanian"},   {"lv", "Latvian"},
    {"ml", "Malayalam"},     {"mr", "Marathi"},    {"nl", "Dutch"},        {"no", "Norwegian"},
    {"pa", "Punjabi"},       {"pl", "Polish"},     {"pt", "Portuguese"},   {"pt-BR", "Portuguese"},
    {"pt-PT", "Portuguese"}, {"ro", "Romanian"},   {"ru", "Russian"},      {"sk", "Slovak"},
    {"sl", "Slovenian"},     {"sr", "Serbian"},    {"sv", "Swedish"},      {"sw", "Swahili"},
    {"sw-KE", "Swahili"},    {"sw-TZ", "Swahili"}, {"ta", "Tamil"},        {"te", "Telugu"},
    {"th", "Thai"},          {"tr", "Turkish"},    {"uk", "Ukrainian"},    {"ur", "Urdu"},
    {"vi", "Vietnamese"},    {"zh", "Chinese"},    {"zh-Hans", "Chinese"}, {"zh-Hant", "Chinese"},
    {"zu", "Zulu"},
};

static const Language *language(const char *code) {
    for (const auto &entry : languages) {
        if (!strcmp(entry.code, code)) {
            return &entry;
        }
    }
    return nullptr;
}

static bool status(char value) {
    return wn_ipc_write(speech_ipc, &value, 1, 0) == 1;
}

static const Language *detect(const std::string &text, const char *directory) {
    // fastText predictLine stops at newline. Flatten only its private input;
    // translation still receives the original, including all internal newlines.
    std::string line = text;
    for (char &c : line) {
        if (c == '\n' || c == '\r') {
            c = ' ';
        }
    }
    bool letters = false;
    for (const char *p = line.c_str(); *p; p = g_utf8_next_char(p)) {
        letters |= g_unichar_isalpha(g_utf8_get_char(p));
    }
    if (!letters) {
        return nullptr;
    }
    fasttext::FastText detector;
    detector.loadModel(std::string(directory) + "/" + models[1].name);
    std::istringstream input(line);
    std::vector<std::pair<fasttext::real, std::string>> predictions;
    // Reject low confidence and ambiguous predictions instead of assuming English.
    if (!detector.predictLine(input, predictions, 2, 0.0f) || predictions.empty() ||
        predictions[0].first < 0.5f ||
        (predictions.size() > 1 && predictions[0].first - predictions[1].first < 0.15f)) {
        return nullptr;
    }
    const auto &label = predictions[0].second;
    if (label.compare(0, 9, "__label__")) {
        return nullptr;
    }
    const char *code = label.c_str() + 9;
    if (!strcmp(code, "tl")) {
        code = "fil-PH";
    }
    return language(code);
}

enum class Token_Mode { Literal, Template };

static bool append_tokens(const llama_vocab *vocab, const std::string &text, Token_Mode mode,
                          std::vector<llama_token> &tokens) {
    const int count = llama_tokenize(vocab, text.data(), (int)text.size(), nullptr, 0, false,
                                     mode == Token_Mode::Template);
    if (count == INT32_MIN) {
        return false;
    }
    const size_t required = count < 0 ? (size_t)-count : (size_t)count;
    if (required > INPUT_TOKENS - tokens.size()) {
        return false;
    }
    const size_t before = tokens.size();
    tokens.resize(before + required);
    const int written = llama_tokenize(vocab, text.data(), (int)text.size(), tokens.data() + before,
                                       (int)required, false, mode == Token_Mode::Template);
    return written >= 0 && (size_t)written == required;
}

static int translate(const std::string &text, const Language &source, const Language &target,
                     const char *directory, std::string &output) {
    llama_backend_init();
    runtime_started = true;
    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;
    model_params.load_mode = LLAMA_LOAD_MODE_MMAP;
    const std::string path = std::string(directory) + "/" + models[0].name;
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
        llama_model_load_from_file(path.c_str(), model_params), llama_model_free);
    if (!model) {
        return INFERENCE_ERROR;
    }
    const llama_vocab *vocab = llama_model_get_vocab(model.get());
    // Verbatim text branch of Google's pinned TranslateGemma chat template.
    const std::string prefix =
        std::string("<bos><start_of_turn>user\nYou are a professional ") + source.name + " (" +
        source.code + ") to " + target.name + " (" + target.code +
        ") translator. Your goal is to accurately convey the meaning and nuances of the original " +
        source.name + " text while adhering to " + target.name +
        " grammar, vocabulary, and cultural sensitivities.\nProduce only the " + target.name +
        " translation, without any additional explanations or commentary. Please translate the "
        "following " +
        source.name + " text into " + target.name + ":\n\n\n";
    std::vector<llama_token> tokens;
    tokens.reserve(INPUT_TOKENS);
    // Parse only trusted template control tokens. A literal token-looking string
    // in a message must never terminate the user turn or impersonate the model.
    if (!append_tokens(vocab, prefix, Token_Mode::Template, tokens) ||
        !append_tokens(vocab, text, Token_Mode::Literal, tokens) ||
        !append_tokens(vocab, "<end_of_turn>\n<start_of_turn>model\n", Token_Mode::Template,
                       tokens)) {
        return LIMIT_ERROR;
    }
    auto params = llama_context_default_params();
    params.n_ctx = CONTEXT;
    params.n_batch = BATCH;
    params.n_ubatch = BATCH;
    params.n_threads = params.n_threads_batch =
        (int)std::max(1L, std::min(4L, sysconf(_SC_NPROCESSORS_ONLN)));
    std::unique_ptr<llama_context, decltype(&llama_free)> context(
        llama_init_from_model(model.get(), params), llama_free);
    if (!context) {
        return INFERENCE_ERROR;
    }
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
        llama_sampler_init_greedy(), llama_sampler_free);
    if (!sampler || !status('T')) {
        return INFERENCE_ERROR;
    }
    for (size_t pos = 0; pos < tokens.size(); pos += BATCH) {
        auto batch = llama_batch_get_one(tokens.data() + pos,
                                         (int)std::min((size_t)BATCH, tokens.size() - pos));
        if (llama_decode(context.get(), batch)) {
            return INFERENCE_ERROR;
        }
    }
    output.reserve(REGION - 1);
    for (int generated = 0; generated < OUTPUT_TOKENS; ++generated) {
        llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) {
            if (output.empty() || !g_utf8_validate(output.data(), output.size(), nullptr) ||
                output.find('\0') != std::string::npos) {
                return INFERENCE_ERROR;
            }
            return 0;
        }
        // Unexpected controls are errors, never invisible gaps in a partial result.
        if (llama_vocab_is_control(vocab, token)) {
            return INFERENCE_ERROR;
        }
        char piece[512];
        int bytes = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (bytes < 0 || (size_t)bytes > sizeof(piece)) {
            return LIMIT_ERROR;
        }
        if (output.size() + (size_t)bytes >= REGION) {
            return LIMIT_ERROR;
        }
        output.append(piece, (size_t)bytes);
        if (generated + 1 < OUTPUT_TOKENS &&
            llama_decode(context.get(), llama_batch_get_one(&token, 1))) {
            return INFERENCE_ERROR;
        }
    }
    // A token/context ceiling is not a finished translation, even for valid UTF-8.
    return LIMIT_ERROR;
}

static int run(int argc, char **argv) {
    if (argc != 7) {
        return INFERENCE_ERROR;
    }
    char *end = nullptr;
    errno = 0;
    unsigned long parent = strtoul(argv[2], &end, 10);
    if (errno || !*argv[2] || *end || !wn_helper_guard(parent) || !wn_helper_silence()) {
        return INFERENCE_ERROR;
    }
    // Native inference buffers contain plaintext. Do not let crashes write cores.
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core) || prctl(PR_SET_DUMPABLE, 0)) {
        return INFERENCE_ERROR;
    }
    if (strcmp(argv[6], "131080") || !(speech_ipc = wn_ipc_open(argv[5], IPC_SIZE))) {
        return INFERENCE_ERROR;
    }
    const Language *source = language(argv[3]), *target = language(argv[4]);
    if (!target || (!source && strcmp(argv[3], "auto"))) {
        return SOURCE_ERROR;
    }
    char input[REGION];
    if (wn_ipc_read(speech_ipc, input, sizeof(input), HEADER) != sizeof(input)) {
        return INFERENCE_ERROR;
    }
    const char *nul = (const char *)memchr(input, 0, sizeof(input));
    if (!nul) {
        return LIMIT_ERROR;
    }
    if (nul == input || !g_utf8_validate(input, nul - input, nullptr)) {
        return SOURCE_ERROR;
    }
    // Jinja's |trim removes surrounding whitespace, not internal line breaks.
    const char *begin = input;
    while (begin < nul && g_unichar_isspace(g_utf8_get_char(begin))) {
        begin = g_utf8_next_char(begin);
    }
    while (nul > begin) {
        const char *previous = g_utf8_find_prev_char(begin, nul);
        if (!g_unichar_isspace(g_utf8_get_char(previous))) {
            break;
        }
        nul = previous;
    }
    if (begin == nul) {
        return SOURCE_ERROR;
    }
    std::string text(begin, nul);
    if (!status('G')) {
        return INFERENCE_ERROR;
    }
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) {
        return DOWNLOAD_ERROR;
    }
    if (g_mkdir_with_parents(argv[1], 0700)) {
        return DOWNLOAD_ERROR;
    }
    void *lock = wn_model_lock(argv[1]);
    if (!lock) {
        return DOWNLOAD_ERROR;
    }
    int result = 0;
    for (const auto &file : models) {
        if (!ensure_model(argv[1], &file)) {
            result = DOWNLOAD_ERROR;
            break;
        }
    }
    wn_model_unlock(lock);
    curl_global_cleanup();
    if (result) {
        return result;
    }
    if (!status('G')) {
        return INFERENCE_ERROR;
    }
    if (!source) {
        source = detect(text, argv[1]);
    }
    if (!source) {
        return SOURCE_ERROR;
    }
    std::string output;
    result = translate(text, *source, *target, argv[1], output);
    if (result) {
        return result;
    }
    const uint32_t size = (uint32_t)output.size();
    unsigned char length[] = {(unsigned char)size, (unsigned char)(size >> 8),
                              (unsigned char)(size >> 16), (unsigned char)(size >> 24)};
    if (wn_ipc_write(speech_ipc, output.data(), size, OUTPUT) != size ||
        wn_ipc_write(speech_ipc, length, sizeof(length), 4) != sizeof(length) || !status('R')) {
        return INFERENCE_ERROR;
    }
    return 0;
}

int main(int argc, char **argv) {
    int result;
    try {
        result = run(argc, argv);
    } catch (...) {
        result = INFERENCE_ERROR;
    } // Never print exception text or input.
    if (speech_ipc) {
        wn_ipc_close(speech_ipc);
    }
    if (runtime_started) {
        llama_backend_free();
    }
    return result;
}
