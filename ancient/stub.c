#define _GNU_SOURCE
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

void log_msg(const char *msg) {
    write(1, msg, strlen(msg));
}

// Helper to check standard library search paths
int check_library(const char *lib_filename) {
    const char *search_paths[] = {
        "/lib64",
        "/usr/lib",
        "/lib",
        "/usr/lib64",
        NULL
    };
    char full_path[512];
    for (int i = 0; search_paths[i] != NULL; i++) {
        snprintf(full_path, sizeof(full_path), "%s/%s", search_paths[i], lib_filename);
        if (access(full_path, F_OK) == 0) {
            return 1;
        }
    }
    if (access(lib_filename, F_OK) == 0) {
        return 1;
    }
    return 0;
}

void report_lib(const char *libname) {
    char buf[256];
    int found = check_library(libname);
    if (found) {
        snprintf(buf, sizeof(buf), "Loading [%s] [\033[32mOK\033[0m]\n", libname);
    } else {
        snprintf(buf, sizeof(buf), "Loading [%s] [\033[31mFAIL\033[0m]\n", libname);
    }
    write(1, buf, strlen(buf));
}

int main() {
    // 1. Mount essential virtual filesystems
    mkdir("/dev", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    
    mkdir("/proc", 0755);
    mount("proc", "/proc", "proc", 0, NULL);

    mkdir("/sys", 0755);
    mount("sysfs", "/sys", "sysfs", 0, NULL);

    // 2. Open console and bind stdin, stdout, stderr
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) {
        fd = open("/dev/ttyS0", O_RDWR);
    }
    if (fd >= 0) {
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
    }

    log_msg("\n[BoxD Stub] Initializing runtime environment...\n");

    // 3. Verify core dynamic linker and dependencies required by boxd (/init.real)
    report_lib("ld-linux-x86-64.so.2");
    report_lib("libpcre2-8.so.0");
    report_lib("libgc.so.1");
    report_lib("libgcc_s.so.1");
    report_lib("libc.so.6");

    // Verify /init.real existence
    if (access("/init.real", F_OK) == 0) {
        log_msg("Loading [/init.real] [\033[32mOK\033[0m]\n");
    } else {
        log_msg("Loading [/init.real] [\033[31mFAIL\033[0m]\n");
    }

    log_msg("[BoxD Stub] Handing over execution to /init.real...\n\n");

    // 4. Launch /init.real
    char *args[] = { "/init.real", NULL };
    char *env[] = { 
        "HOME=/", 
        "TERM=linux", 
        "LD_LIBRARY_PATH=/lib64:/usr/lib:/lib:/usr/lib64",
        NULL 
    };

    execve(args[0], args, env);

    // If execve fails
    char err_buf[256];
    int err = errno;
    int len = snprintf(err_buf, sizeof(err_buf), "[BoxD Stub] CRITICAL: execve failed! errno = %d (%s)\n", err, strerror(err));
    log_msg(err_buf);

    // Hang PID 1 on failure
    while(1) {
        sleep(10);
    }
    return 0;
}
