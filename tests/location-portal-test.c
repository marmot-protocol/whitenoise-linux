/* Deterministic protocol tests against the real wn-location subprocess.
 * Compile that helper with -DWN_LOCATION_TIMEOUT_MS=1000 for this suite.
 * cc -O2 -Wall -Wextra tests/location-portal-test.c $(pkg-config --cflags --libs gio-2.0) -lm -o
 * build/location-portal-test build/location-portal-test build/wn-location-test-helper
 */
#include <gio/gio.h>
#include <math.h>
#include <signal.h>
#include <string.h>

#define PORTAL_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define LOCATION_IFACE "org.freedesktop.portal.Location"
#define REQUEST_IFACE "org.freedesktop.portal.Request"
#define SESSION_IFACE "org.freedesktop.portal.Session"

typedef enum {
    SUCCESS,
    DENIED,
    FIX_BEFORE_RESPONSE,
    FIX_BEFORE_DENIAL,
    SIGNALS_BEFORE_METHOD_REPLY,
    ALTERNATE_REQUEST_HANDLE,
    NO_FIX,
    INVALID_FIXES,
    NO_START_RESPONSE,
    START_ERROR,
    SESSION_CLOSED,
    CANCEL_PERMISSION,
    CANCEL_APPROVED,
} Scenario;

typedef struct {
    Scenario scenario;
    GMainLoop *loop;
    GDBusConnection *bus;
    GSubprocess *child;
    GDBusNodeInfo *node;
    char *session, *request, *sender;
    char *output, *errors;
    GError *communication_error;
    guint location_registration, session_registration, request_registration;
    guint response_timer, cancel_timer;
    guint creates, starts, session_closes, request_closes;
    gboolean communicated, timed_out, responded;
    gint64 canceled_at;
} Fixture;

static char *helper;
static const GDBusInterfaceVTable methods;
static const char xml[] =
    "<node>"
    "<interface name='org.freedesktop.portal.Location'>"
    "<method name='CreateSession'><arg type='a{sv}' direction='in'/><arg type='o' "
    "direction='out'/></method>"
    "<method name='Start'><arg type='o' direction='in'/><arg type='s' direction='in'/>"
    "<arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>"
    "<signal name='LocationUpdated'><arg type='o'/><arg type='a{sv}'/></signal>"
    "</interface>"
    "<interface name='org.freedesktop.portal.Session'>"
    "<method name='Close'/><signal name='Closed'><arg type='a{sv}'/></signal>"
    "</interface>"
    "<interface name='org.freedesktop.portal.Request'>"
    "<method name='Close'/><signal name='Response'><arg type='u'/><arg type='a{sv}'/></signal>"
    "</interface>"
    "</node>";

static GVariant *empty_dict(void) {
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
    return g_variant_builder_end(&builder);
}

static void emit(Fixture *fixture, const char *path, const char *interface, const char *signal,
                 GVariant *parameters) {
    GError *error = NULL;
    gboolean emitted = g_dbus_connection_emit_signal(fixture->bus, fixture->sender, path, interface,
                                                     signal, parameters, &error);
    g_assert_no_error(error);
    g_assert_true(emitted);
}

static void fix(Fixture *fixture, const char *session, double latitude, double longitude) {
    GVariantBuilder values;
    g_variant_builder_init(&values, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&values, "{sv}", "Latitude", g_variant_new_double(latitude));
    g_variant_builder_add(&values, "{sv}", "Longitude", g_variant_new_double(longitude));
    emit(fixture, PORTAL_PATH, LOCATION_IFACE, "LocationUpdated",
         g_variant_new("(o@a{sv})", session, g_variant_builder_end(&values)));
}

static gboolean response(gpointer data) {
    Fixture *fixture = data;
    fixture->response_timer = 0;
    fixture->responded = TRUE;
    guint code = fixture->scenario == DENIED || fixture->scenario == FIX_BEFORE_DENIAL ? 1 : 0;
    emit(fixture, fixture->request, REQUEST_IFACE, "Response",
         g_variant_new("(u@a{sv})", code, empty_dict()));
    return G_SOURCE_REMOVE;
}

static gboolean cancel_child(gpointer data) {
    Fixture *fixture = data;
    fixture->cancel_timer = 0;
    fixture->canceled_at = g_get_monotonic_time();
    g_subprocess_send_signal(fixture->child, SIGTERM);
    return G_SOURCE_REMOVE;
}

static char *handle(const char *sender, const char *kind, const char *token) {
    char *component = g_strdup(sender + 1);
    for (char *p = component; *p; ++p) {
        if (*p == '.') {
            *p = '_';
        }
    }
    char *path = g_strdup_printf(PORTAL_PATH "/%s/%s/%s", kind, component, token);
    g_free(component);
    return path;
}

static guint register_object(Fixture *fixture, const char *path, const char *interface) {
    GError *error = NULL;
    guint registration = g_dbus_connection_register_object(
        fixture->bus, path, g_dbus_node_info_lookup_interface(fixture->node, interface), &methods,
        fixture, NULL, &error);
    g_assert_no_error(error);
    g_assert_cmpuint(registration, !=, 0);
    return registration;
}

static void method_call(GDBusConnection *bus, const char *sender, const char *path,
                        const char *interface, const char *method, GVariant *parameters,
                        GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus;
    (void)path;
    Fixture *fixture = data;
    if (g_str_equal(method, "CreateSession")) {
        fixture->creates += 1;
        fixture->sender = g_strdup(sender);
        GVariant *options;
        g_variant_get(parameters, "(@a{sv})", &options);
        const char *token;
        guint accuracy, distance, time;
        g_assert_true(g_variant_lookup(options, "session_handle_token", "&s", &token));
        g_assert_true(g_variant_lookup(options, "accuracy", "u", &accuracy));
        g_assert_cmpuint(accuracy, ==, 5);
        g_assert_true(g_variant_lookup(options, "distance-threshold", "u", &distance));
        g_assert_cmpuint(distance, ==, 0);
        g_assert_true(g_variant_lookup(options, "time-threshold", "u", &time));
        g_assert_cmpuint(time, ==, 0);
        fixture->session = handle(sender, "session", token);
        g_variant_unref(options);
        fixture->session_registration = register_object(fixture, fixture->session, SESSION_IFACE);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(o)", fixture->session));
        return;
    }
    if (g_str_equal(method, "Start")) {
        fixture->starts += 1;
        const char *session, *parent, *token;
        GVariant *options;
        g_variant_get(parameters, "(&o&s@a{sv})", &session, &parent, &options);
        g_assert_cmpstr(session, ==, fixture->session);
        g_assert_cmpstr(parent, ==, "");
        g_assert_true(g_variant_lookup(options, "handle_token", "&s", &token));
        fixture->request = handle(
            sender, "request",
            fixture->scenario == ALTERNATE_REQUEST_HANDLE ? "legacy_returned_handle" : token);
        g_variant_unref(options);
        fixture->request_registration = register_object(fixture, fixture->request, REQUEST_IFACE);
        if (fixture->scenario == START_ERROR) {
            g_dbus_method_invocation_return_dbus_error(
                invocation, "org.freedesktop.portal.Error.NotAllowed", "Location disabled");
            return;
        }
        if (fixture->scenario == SIGNALS_BEFORE_METHOD_REPLY ||
            fixture->scenario == ALTERNATE_REQUEST_HANDLE) {
            /* Both signals intentionally precede the method reply. */
            fix(fixture, fixture->session, 51.5074, -0.1278);
            response(fixture);
        }
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(o)", fixture->request));
        switch (fixture->scenario) {
        case FIX_BEFORE_RESPONSE:
        case FIX_BEFORE_DENIAL:
            fix(fixture, fixture->session, 51.5074, -0.1278);
            fixture->response_timer = g_timeout_add(40, response, fixture);
            break;
        case SUCCESS:
            response(fixture);
            fix(fixture, fixture->session, 51.5074, -0.1278);
            break;
        case DENIED:
        case NO_FIX:
            response(fixture);
            break;
        case INVALID_FIXES: {
            response(fixture);
            fix(fixture, fixture->session, NAN, 0);
            fix(fixture, fixture->session, 0, INFINITY);
            fix(fixture, fixture->session, 91, 0);
            fix(fixture, fixture->session, 0, -181);
            fix(fixture, PORTAL_PATH "/session/wrong/session", 51.5074, -0.1278);
            GVariantBuilder values;
            g_variant_builder_init(&values, G_VARIANT_TYPE_VARDICT);
            g_variant_builder_add(&values, "{sv}", "Latitude", g_variant_new_string("51.5074"));
            g_variant_builder_add(&values, "{sv}", "Longitude", g_variant_new_double(-0.1278));
            emit(fixture, PORTAL_PATH, LOCATION_IFACE, "LocationUpdated",
                 g_variant_new("(o@a{sv})", fixture->session, g_variant_builder_end(&values)));
            emit(fixture, PORTAL_PATH, LOCATION_IFACE, "LocationUpdated",
                 g_variant_new("(o@a{sv})", fixture->session, empty_dict()));
            break;
        }
        case SESSION_CLOSED:
            emit(fixture, fixture->session, SESSION_IFACE, "Closed",
                 g_variant_new("(@a{sv})", empty_dict()));
            break;
        case CANCEL_PERMISSION:
        case CANCEL_APPROVED:
            if (fixture->scenario == CANCEL_APPROVED) {
                response(fixture);
            }
            fixture->cancel_timer = g_timeout_add(40, cancel_child, fixture);
            break;
        case NO_START_RESPONSE:
        case SIGNALS_BEFORE_METHOD_REPLY:
        case ALTERNATE_REQUEST_HANDLE:
        case START_ERROR:
            break;
        }
        return;
    }
    g_assert_cmpstr(method, ==, "Close");
    if (g_str_equal(interface, SESSION_IFACE)) {
        fixture->session_closes += 1;
    } else {
        g_assert_cmpstr(interface, ==, REQUEST_IFACE);
        fixture->request_closes += 1;
    }
    g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
}

static const GDBusInterfaceVTable methods = {.method_call = method_call};

static void communicated(GObject *source, GAsyncResult *result, gpointer data) {
    Fixture *fixture = data;
    fixture->communicated =
        g_subprocess_communicate_utf8_finish(G_SUBPROCESS(source), result, &fixture->output,
                                             &fixture->errors, &fixture->communication_error);
    g_main_loop_quit(fixture->loop);
}

static gboolean watchdog(gpointer data) {
    Fixture *fixture = data;
    fixture->timed_out = TRUE;
    g_subprocess_force_exit(fixture->child);
    return G_SOURCE_CONTINUE;
}

static void test_portal(gconstpointer data) {
    Fixture fixture = {.scenario = GPOINTER_TO_INT(data)};
    GError *error = NULL;
    GTestDBus *daemon = g_test_dbus_new(G_TEST_DBUS_NONE);
    g_test_dbus_up(daemon);
    fixture.loop = g_main_loop_new(NULL, FALSE);
    fixture.node = g_dbus_node_info_new_for_xml(xml, &error);
    g_assert_no_error(error);
    fixture.bus =
        g_dbus_connection_new_for_address_sync(g_test_dbus_get_bus_address(daemon),
                                               G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                                                   G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
                                               NULL, NULL, &error);
    g_assert_no_error(error);
    GVariant *name_reply = g_dbus_connection_call_sync(
        fixture.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "RequestName", g_variant_new("(su)", PORTAL_NAME, 0u), G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    g_assert_no_error(error);
    g_assert_nonnull(name_reply);
    guint name_result;
    g_variant_get(name_reply, "(u)", &name_result);
    g_assert_cmpuint(name_result, ==, 1);
    g_variant_unref(name_reply);
    fixture.location_registration = register_object(&fixture, PORTAL_PATH, LOCATION_IFACE);
    fixture.child = g_subprocess_new(
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE, &error, helper, NULL);
    g_assert_no_error(error);
    g_subprocess_communicate_utf8_async(fixture.child, NULL, NULL, communicated, &fixture);
    guint timer = g_timeout_add(5000, watchdog, &fixture);
    g_main_loop_run(fixture.loop);
    g_source_remove(timer);
    if (fixture.response_timer) {
        g_source_remove(fixture.response_timer);
    }
    if (fixture.cancel_timer) {
        g_source_remove(fixture.cancel_timer);
    }
    g_assert_false(fixture.timed_out);
    g_assert_no_error(fixture.communication_error);
    g_assert_true(fixture.communicated);
    g_assert_cmpstr(fixture.errors, ==, "");
    g_assert_cmpuint(fixture.creates, ==, 1);
    g_assert_cmpuint(fixture.starts, ==, 1);
    g_assert_cmpuint(fixture.session_closes, ==, 1);
    gboolean success = fixture.scenario == SUCCESS || fixture.scenario == FIX_BEFORE_RESPONSE ||
                       fixture.scenario == SIGNALS_BEFORE_METHOD_REPLY ||
                       fixture.scenario == ALTERNATE_REQUEST_HANDLE;
    g_assert_cmpint(g_subprocess_get_exit_status(fixture.child), ==, success ? 0 : 1);
    if (success) {
        char *end;
        double latitude = g_ascii_strtod(fixture.output, &end);
        g_assert_cmpfloat_with_epsilon(latitude, 51.5074, 0.000000001);
        double longitude = g_ascii_strtod(end, &end);
        g_assert_cmpfloat_with_epsilon(longitude, -0.1278, 0.000000001);
        g_assert_cmpstr(end, ==, "\n");
    } else {
        g_assert_cmpstr(fixture.output, ==, "");
    }
    if (fixture.scenario == FIX_BEFORE_RESPONSE || fixture.scenario == FIX_BEFORE_DENIAL) {
        g_assert_true(fixture.responded); /* An early fix must not finish acquisition. */
    }
    if (fixture.scenario == CANCEL_PERMISSION || fixture.scenario == CANCEL_APPROVED) {
        g_assert_cmpint(fixture.canceled_at, >, 0);
    }
    gboolean close_request =
        fixture.scenario == NO_START_RESPONSE || fixture.scenario == START_ERROR ||
        fixture.scenario == SESSION_CLOSED || fixture.scenario == CANCEL_PERMISSION;
    g_assert_cmpuint(fixture.request_closes, ==, close_request ? 1 : 0);
    g_dbus_connection_unregister_object(fixture.bus, fixture.location_registration);
    g_dbus_connection_unregister_object(fixture.bus, fixture.session_registration);
    g_dbus_connection_unregister_object(fixture.bus, fixture.request_registration);
    g_dbus_connection_close_sync(fixture.bus, NULL, &error);
    g_assert_no_error(error);
    g_object_unref(fixture.bus);
    g_object_unref(fixture.child);
    g_dbus_node_info_unref(fixture.node);
    g_main_loop_unref(fixture.loop);
    g_free(fixture.session);
    g_free(fixture.request);
    g_free(fixture.sender);
    g_free(fixture.output);
    g_free(fixture.errors);
    g_test_dbus_down(daemon);
    g_object_unref(daemon);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        g_printerr("Usage: %s <wn-location helper built with 1000 ms timeout>\n", argv[0]);
        return 2;
    }
    helper = g_canonicalize_filename(argv[1], NULL);
    int test_argc = 1;
    char **test_argv = argv;
    g_test_init(&test_argc, &test_argv, NULL);
    static const char *names[] = {
        "success",
        "denied",
        "fix-before-response",
        "fix-before-denial",
        "signals-before-method-reply",
        "alternate-request-handle",
        "no-fix-timeout",
        "invalid-fixes-timeout",
        "no-start-response-timeout",
        "start-error",
        "session-closed",
        "cancel-permission",
        "cancel-approved-session",
    };
    for (guint i = 0; i < G_N_ELEMENTS(names); ++i) {
        char *path = g_strdup_printf("/location-portal/%s", names[i]);
        g_test_add_data_func(path, GUINT_TO_POINTER(i), test_portal);
        g_free(path);
    }
    int result = g_test_run();
    g_free(helper);
    return result;
}
