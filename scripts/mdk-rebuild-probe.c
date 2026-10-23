#include "marmot.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: mdk-rebuild-probe EXPECTED_ERROR\n");
        return 2;
    }
    struct MarmotClient *client = NULL;
    MarmotStatus status = marmot_client_new(".", NULL, 0, NULL, &client);
    char *detail = marmot_last_error_message();
    int ok = status == MARMOT_STATUS_NULL_POINTER && client == NULL &&
             detail != NULL && strcmp(detail, argv[1]) == 0;
    printf("status=%d, client=%s, detail=\"%s\", expected=\"%s\": %s\n",
           (int)status, client == NULL ? "NULL" : "non-NULL",
           detail != NULL ? detail : "(NULL)", argv[1], ok ? "PASS" : "FAIL");
    marmot_string_free(detail);
    return ok ? 0 : 1;
}
