#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define SERVICE "com.nininunz.Clerestory.LowPowerMode"
#define APP_REQUIREMENT "anchor apple generic and identifier \"com.nininunz.Clerestory\" and certificate leaf[subject.OU] = \"8KB55P2YKQ\""

static int active_profile(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return -1;
    CFStringRef source = IOPSGetProvidingPowerSourceType(info);
    int profile = -1;
    if (source && CFEqual(source, CFSTR(kIOPSBatteryPowerValue))) profile = 0;
    if (source && CFEqual(source, CFSTR(kIOPSACPowerValue))) profile = 1;
    CFRelease(info);
    return profile;
}

static bool toggle_mode(void) {
    int profile = active_profile();
    if (profile < 0) return false;

    FILE *profiles = popen("/usr/bin/pmset -g custom", "r");
    if (!profiles) return false;
    bool active = false;
    // Macs with High Power Mode report "powermode" (0 Automatic, 1 Low Power,
    // 2 High Power); others report "lowpowermode" (0 or 1).
    int power_mode = -1, low_power_mode = -1;
    char line[512];
    // Read all of pmset's output before closing the pipe.
    while (fgets(line, sizeof line, profiles)) {
        int value;
        if (line[0] != ' ' && line[0] != '\t') {
            active = strcmp(line, profile ? "AC Power:\n" : "Battery Power:\n") == 0;
        } else if (active && sscanf(line, " powermode %d", &value) == 1) {
            power_mode = value;
        } else if (active && sscanf(line, " lowpowermode %d", &value) == 1) {
            low_power_mode = value;
        }
    }
    if (pclose(profiles) != 0 || active_profile() != profile) return false;

    char *key;
    char *value;
    if (power_mode >= 0 && power_mode <= 2) {
        // Turning Low Power off returns to Automatic, not to High Power.
        key = "powermode";
        value = power_mode == 1 ? "0" : "1";
    } else if (low_power_mode == 0 || low_power_mode == 1) {
        key = "lowpowermode";
        value = low_power_mode ? "0" : "1";
    } else {
        return false;
    }

    char *argv[] = {"/usr/bin/pmset", profile ? "-c" : "-b", key, value, NULL};
    char *env[] = {"PATH=/usr/bin:/bin", NULL};
    pid_t child;
    if (posix_spawn(&child, argv[0], NULL, NULL, argv, env) != 0) return false;
    int status;
    return waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int main(void) {
    if (geteuid() != 0) return 1;

    // Serialize toggles across peers so two requests cannot read the same profile.
    dispatch_queue_t queue = dispatch_queue_create(SERVICE, DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create_mach_service(
        SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)event;
        if (xpc_connection_set_peer_code_signing_requirement(peer, APP_REQUIREMENT) != 0) {
            xpc_connection_cancel(peer);
            return;
        }
        xpc_connection_set_target_queue(peer, queue);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t request) {
            if (xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
            xpc_object_t reply = xpc_dictionary_create_reply(request);
            if (!reply) return;
            const char *action = xpc_dictionary_get_string(request, "action");
            xpc_dictionary_set_bool(reply, "success", action && strcmp(action, "toggle") == 0 && toggle_mode());
            xpc_connection_send_message(peer, reply);
            xpc_release(reply);
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    dispatch_main();
}
