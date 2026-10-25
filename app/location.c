/* One permission-backed location fix; never contacts a fallback provider.
 * API: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Location.html
 */
#include <gio/gio.h>
#include <glib-unix.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

#ifndef WN_LOCATION_TIMEOUT_MS
#define WN_LOCATION_TIMEOUT_MS 45000
#endif
#define PORTAL_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define LOCATION_IFACE "org.freedesktop.portal.Location"
#define REQUEST_IFACE "org.freedesktop.portal.Request"
#define SESSION_IFACE "org.freedesktop.portal.Session"

typedef enum {
    LOCATION_UNAVAILABLE,
    LOCATION_FIX,
} LocationResult;

typedef struct {
    GMainLoop *loop;
    GCancellable *cancel;
    GDBusConnection *bus;
    GHashTable *responses;
    char *session;
    char *request;
    guint location_sub, response_sub, closed_sub;
    gulong bus_closed;
    gboolean creating, starting, start_returned, have_fix, finished, success;
    double latitude, longitude;
} Location;

static void finish(Location *location, LocationResult result) {
    if (location->finished) {
        return;
    }
    location->finished = TRUE;
    location->success = result == LOCATION_FIX;
    g_cancellable_cancel(location->cancel);
    g_main_loop_quit(location->loop);
}

static gboolean deadline(gpointer data) {
    finish(data, LOCATION_UNAVAILABLE);
    return G_SOURCE_CONTINUE; /* Removed by main, including when it fires. */
}

/* A fix can precede Start's Response. Do not publish it until both the
 * method and the permission interaction have succeeded. */
static void maybe_finish(Location *location) {
    if (!location->start_returned) {
        return;
    }
    gpointer stored = g_hash_table_lookup(location->responses, location->request);
    if (!stored) {
        return;
    }
    guint response = GPOINTER_TO_UINT(stored) - 1;
    if (response != 0) {
        finish(location, LOCATION_UNAVAILABLE);
    } else if (location->have_fix) {
        finish(location, LOCATION_FIX);
    }
}

static void response_signal(GDBusConnection *bus, const char *sender, const char *path,
                            const char *interface, const char *signal, GVariant *parameters,
                            gpointer data) {
    (void)bus;
    (void)sender;
    (void)interface;
    (void)signal;
    Location *location = data;
    if (location->finished || !location->starting ||
        !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ua{sv})"))) {
        return;
    }
    guint response;
    g_variant_get_child(parameters, 0, "u", &response);
    /* Subscribe broadly before Start, then correlate its returned handle.
     * This also retains an early Response from portals using a different
     * handle than the modern token-derived path. Bound unrelated signals. */
    if (response <= 2 && (g_hash_table_contains(location->responses, path) ||
                          g_hash_table_size(location->responses) < 8)) {
        g_hash_table_replace(location->responses, g_strdup(path), GUINT_TO_POINTER(response + 1));
        maybe_finish(location);
    }
}

static void location_signal(GDBusConnection *bus, const char *sender, const char *path,
                            const char *interface, const char *signal, GVariant *parameters,
                            gpointer data) {
    (void)bus;
    (void)sender;
    (void)path;
    (void)interface;
    (void)signal;
    Location *location = data;
    if (location->finished || !location->starting ||
        !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(oa{sv})"))) {
        return;
    }
    const char *session;
    GVariant *values;
    g_variant_get(parameters, "(&o@a{sv})", &session, &values);
    double latitude, longitude;
    gboolean valid = g_strcmp0(session, location->session) == 0 &&
                     g_variant_lookup(values, "Latitude", "d", &latitude) &&
                     g_variant_lookup(values, "Longitude", "d", &longitude) && isfinite(latitude) &&
                     isfinite(longitude) && latitude >= -90.0 && latitude <= 90.0 &&
                     longitude >= -180.0 && longitude <= 180.0;
    g_variant_unref(values);
    if (valid && !location->have_fix) {
        location->latitude = latitude;
        location->longitude = longitude;
        location->have_fix = TRUE;
        maybe_finish(location);
    }
}

static void session_closed(GDBusConnection *bus, const char *sender, const char *path,
                           const char *interface, const char *signal, GVariant *parameters,
                           gpointer data) {
    (void)bus;
    (void)sender;
    (void)interface;
    (void)signal;
    (void)parameters;
    Location *location = data;
    if (g_strcmp0(path, location->session) == 0) {
        finish(location, LOCATION_UNAVAILABLE);
    }
}

static void bus_closed(GDBusConnection *bus, gboolean remote, GError *error, gpointer data) {
    (void)bus;
    (void)remote;
    (void)error;
    finish(data, LOCATION_UNAVAILABLE);
}

static void start_done(GObject *source, GAsyncResult *result, gpointer data) {
    Location *location = data;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    if (location->finished) {
        g_clear_pointer(&reply, g_variant_unref);
        return;
    }
    if (!reply) {
        finish(location, LOCATION_UNAVAILABLE);
        return;
    }
    const char *request;
    g_variant_get(reply, "(&o)", &request);
    g_free(location->request);
    location->request = g_strdup(request);
    location->start_returned = TRUE;
    g_variant_unref(reply);
    maybe_finish(location);
}

static void session_done(GObject *source, GAsyncResult *result, gpointer data) {
    Location *location = data;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    if (location->finished) {
        g_clear_pointer(&reply, g_variant_unref);
        return;
    }
    if (!reply) {
        finish(location, LOCATION_UNAVAILABLE);
        return;
    }
    const char *session;
    g_variant_get(reply, "(&o)", &session);
    g_free(location->session);
    location->session = g_strdup(session);
    g_variant_unref(reply);

    const char *token = strrchr(location->request, '/') + 1;
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
    location->starting = TRUE;
    /* An empty parent is permitted by the portal window-identifier contract.
     * The helper has no independently exported SDL/Wayland window handle. */
    g_dbus_connection_call(
        location->bus, PORTAL_NAME, PORTAL_PATH, LOCATION_IFACE, "Start",
        g_variant_new("(os@a{sv})", location->session, "", g_variant_builder_end(&options)),
        G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, WN_LOCATION_TIMEOUT_MS, location->cancel,
        start_done, location);
}

static void bus_ready(GObject *source, GAsyncResult *result, gpointer data) {
    (void)source;
    Location *location = data;
    GDBusConnection *bus = g_bus_get_finish(result, NULL);
    if (location->finished) {
        g_clear_object(&bus);
        return;
    }
    if (!bus) {
        finish(location, LOCATION_UNAVAILABLE);
        return;
    }
    location->bus = bus;
    g_dbus_connection_set_exit_on_close(bus, FALSE);
    location->bus_closed = g_signal_connect(bus, "closed", G_CALLBACK(bus_closed), location);

    char *sender = g_strdup(g_dbus_connection_get_unique_name(bus) + 1);
    for (char *p = sender; *p; ++p) {
        if (*p == '.') {
            *p = '_';
        }
    }
    char *token = g_uuid_string_random();
    for (char *p = token; *p; ++p) {
        if (*p == '-') {
            *p = '_';
        }
    }
    location->session = g_strdup_printf(PORTAL_PATH "/session/%s/wn_location_%s", sender, token);
    location->request = g_strdup_printf(PORTAL_PATH "/request/%s/wn_location_%s", sender, token);
    g_free(sender);

    /* All subscriptions precede CreateSession/Start, including Response:
     * neither an immediate fix nor a fast denial can outrun our listener. */
    location->response_sub = g_dbus_connection_signal_subscribe(
        bus, PORTAL_NAME, REQUEST_IFACE, "Response", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        response_signal, location, NULL);
    location->location_sub = g_dbus_connection_signal_subscribe(
        bus, PORTAL_NAME, LOCATION_IFACE, "LocationUpdated", PORTAL_PATH, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, location_signal, location, NULL);
    location->closed_sub = g_dbus_connection_signal_subscribe(
        bus, PORTAL_NAME, SESSION_IFACE, "Closed", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        session_closed, location, NULL);

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    char *session_token = g_strdup_printf("wn_location_%s", token);
    g_variant_builder_add(&options, "{sv}", "session_handle_token",
                          g_variant_new_string(session_token));
    g_variant_builder_add(&options, "{sv}", "accuracy", g_variant_new_uint32(5)); /* EXACT */
    g_variant_builder_add(&options, "{sv}", "distance-threshold", g_variant_new_uint32(0));
    g_variant_builder_add(&options, "{sv}", "time-threshold", g_variant_new_uint32(0));
    g_free(session_token);
    g_free(token);
    location->creating = TRUE;
    g_dbus_connection_call(bus, PORTAL_NAME, PORTAL_PATH, LOCATION_IFACE, "CreateSession",
                           g_variant_new("(@a{sv})", g_variant_builder_end(&options)),
                           G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, WN_LOCATION_TIMEOUT_MS,
                           location->cancel, session_done, location);
}

static void close_portal_object(Location *location, const char *path, const char *interface) {
    /* Cleanup has its own short bound even when acquisition used its entire
     * deadline. A vanishing bus client closes its remaining portal sessions. */
    GVariant *reply =
        g_dbus_connection_call_sync(location->bus, PORTAL_NAME, path, interface, "Close", NULL,
                                    G_VARIANT_TYPE_UNIT, G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
    g_clear_pointer(&reply, g_variant_unref);
}

int main(void) {
    Location location = {0};
    location.loop = g_main_loop_new(NULL, FALSE);
    location.cancel = g_cancellable_new();
    location.responses = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    /* Cancellation must dismiss permission UI and stop an approved session,
     * not merely discard the coordinates in the parent. Install before bus
     * setup so every created portal object has this graceful exit path. */
    guint terminate_source = g_unix_signal_add(SIGTERM, deadline, &location);
    /* Includes connection setup, permission UI, and waiting for the first fix. */
    guint timer = g_timeout_add(WN_LOCATION_TIMEOUT_MS, deadline, &location);
    g_bus_get(G_BUS_TYPE_SESSION, location.cancel, bus_ready, &location);
    g_main_loop_run(location.loop);
    g_source_remove(timer);
    g_source_remove(terminate_source);
    if (location.bus) {
        if (location.starting && !g_hash_table_contains(location.responses, location.request)) {
            close_portal_object(&location, location.request, REQUEST_IFACE);
        }
        if (location.creating) {
            close_portal_object(&location, location.session, SESSION_IFACE);
        }
        g_dbus_connection_signal_unsubscribe(location.bus, location.response_sub);
        g_dbus_connection_signal_unsubscribe(location.bus, location.location_sub);
        g_dbus_connection_signal_unsubscribe(location.bus, location.closed_sub);
        g_signal_handler_disconnect(location.bus, location.bus_closed);
        g_object_unref(location.bus);
    }
    g_hash_table_unref(location.responses);
    g_free(location.session);
    g_free(location.request);
    g_object_unref(location.cancel);
    g_main_loop_unref(location.loop);
    if (!location.success) {
        return 1;
    }
    char latitude[G_ASCII_DTOSTR_BUF_SIZE], longitude[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_dtostr(latitude, sizeof(latitude), location.latitude);
    g_ascii_dtostr(longitude, sizeof(longitude), location.longitude);
    return printf("%s %s\n", latitude, longitude) < 0 ? 1 : 0;
}
