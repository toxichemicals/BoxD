#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <dirent.h>
#include <pthread.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/reboot.h>

#define MAX_SERVICES 128
#define PORT 209

extern char **environ;

typedef struct {
    char name[128];
    char file_path[256];
    char runner[128];
    char shell[128];
    char path_env[256];
    char exec_cmd[512];
    char inscript[2048];
    char shutdown_cmd[512];
    char waiton[128];
    int autorestart;
    int enabled;
    pid_t pid;
    int running;
} Service;

Service services[MAX_SERVICES];
int service_count = 0;
pthread_mutex_t services_lock = PTHREAD_MUTEX_INITIALIZER;
char journals_dir[256];
char base_dir[256];

// --- MountD & ReapD ---
void initialize_mounts() {
    if (getpid() == 1) {
        printf("[MountD] PID 1 detected; Mounting filesystems.\n");
        mkdir("/proc", 0755);
        mkdir("/sys", 0755);
        mkdir("/dev", 0755);
        mkdir("/dev/pts", 0755);

        mount("proc", "/proc", "proc", 0, NULL);
        mount("sysfs", "/sys", "sysfs", 0, NULL);
        mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
        mount("devpts", "/dev/pts", "devpts", 0, NULL);

        system("ip link set lo up");
        system("ip addr add 127.0.0.1/8 dev lo");
        system("ifconfig lo up 127.0.0.1");

        if (access("/etc/fstab", F_OK) == 0) {
            system("mount -a");
        }
        printf("[MountD] Core mounts completed successfully.\n");
    }
}

void verify_and_link_libraries() {
    struct stat st;
    if (stat("/usr/lib/libpcre2-8.so.0.15.0", &st) == 0 && stat("/usr/lib/libpcre2-8.so.0", &st) != 0) {
        symlink("/usr/lib/libpcre2-8.so.0.15.0", "/usr/lib/libpcre2-8.so.0");
        printf("[LibD] Created symlink for libpcre2-8.so.0 -> libpcre2-8.so.0.15.0 [OK]\n");
    }
    // Refresh dynamic linker run-time bindings
    system("ldconfig >/dev/null 2>&1");
}

void* start_reaper(void* arg) {
    if (getpid() == 1) {
        printf("[ReapD] Initializing zombie process reaper...\n");
        while (1) {
            pid_t pid;
            int status;
            while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
                pthread_mutex_lock(&services_lock);
                for (int i = 0; i < service_count; i++) {
                    if (services[i].pid == pid) {
                        services[i].running = 0;
                        services[i].pid = 0;
                        break;
                    }
                }
                pthread_mutex_unlock(&services_lock);
            }
            // usleep(100000); Might be holding up the system's boot time? Maybe try a value of 10, instead. Off for testing.
        }
    }
    return NULL;
}

// --- Parser & Service Management ---
void parse_service_file(const char* filepath, Service* s) {
    FILE* f = fopen(filepath, "r");
    if (!f) return;

    char line[512];
    int in_inscript = 0;
    char inscript_buf[2048] = {0};

    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = 0;
        char* trimmed = line;
        while (*trimmed == ' ' || *trimmed == '\t') trimmed++;

        if (in_inscript) {
            if (strcmp(trimmed, "}") == 0) {
                in_inscript = 0;
                strncpy(s->inscript, inscript_buf, sizeof(s->inscript) - 1);
            } else {
                strncat(inscript_buf, line, sizeof(inscript_buf) - strlen(inscript_buf) - 1);
                strncat(inscript_buf, "\n", sizeof(inscript_buf) - strlen(inscript_buf) - 1);
            }
            continue;
        }

        if (strncmp(trimmed, "Inscript{", 9) == 0) {
            in_inscript = 1;
            continue;
        }

        if (trimmed[0] == '#' || trimmed[0] == '\0') continue;

        char* eq = strchr(trimmed, '=');
        if (!eq) continue;

        *eq = '\0';
        char* key = trimmed;
        char* val = eq + 1;

        while (*key == ' ') key++;
        while (*val == ' ') val++;

        if (strcasecmp(key, "runner") == 0) strncpy(s->runner, val, sizeof(s->runner) - 1);
        else if (strcasecmp(key, "shell") == 0) strncpy(s->shell, val, sizeof(s->shell) - 1);
        else if (strcasecmp(key, "path") == 0) strncpy(s->path_env, val, sizeof(s->path_env) - 1);
        else if (strcasecmp(key, "exec") == 0) strncpy(s->exec_cmd, val, sizeof(s->exec_cmd) - 1);
        else if (strcasecmp(key, "shutdown") == 0) strncpy(s->shutdown_cmd, val, sizeof(s->shutdown_cmd) - 1);
        else if (strcasecmp(key, "waiton") == 0) strncpy(s->waiton, val, sizeof(s->waiton) - 1);
        else if (strcasecmp(key, "autorestart") == 0) s->autorestart = (strcasecmp(val, "y") == 0 || strcasecmp(val, "true") == 0);
        else if (strcasecmp(key, "enabled") == 0) s->enabled = (strcasecmp(val, "y") == 0 || strcasecmp(val, "true") == 0);
    }
    fclose(f);
}

void set_service_enabled_status(Service* s, int status) {
    s->enabled = status;
    FILE* f = fopen(s->file_path, "r");
    if (!f) return;

    char buffer[4096] = {0};
    char line[512];
    int found = 0;

    while (fgets(line, sizeof(line), f)) {
        char temp[512];
        strcpy(temp, line);
        char* trimmed = temp;
        while (*trimmed == ' ' || *trimmed == '\t') trimmed++;

        if (strncasecmp(trimmed, "enabled", 7) == 0) {
            found = 1;
            char new_line[64];
            snprintf(new_line, sizeof(new_line), "enabled=%s\n", status ? "y" : "n");
            strcat(buffer, new_line);
        } else {
            strcat(buffer, line);
        }
    }
    fclose(f);

    if (!found) {
        char new_line[64];
        snprintf(new_line, sizeof(new_line), "enabled=%s\n", status ? "y" : "n");
        strcat(buffer, new_line);
    }

    f = fopen(s->file_path, "w");
    if (f) {
        fputs(buffer, f);
        fclose(f);
    }
}

int stop_service_recursive(Service* s, int client_fd);

// --- Dependency-Aware Execution ---
int start_service_recursive(Service* s, int client_fd, char visited[][128], int depth) {
    if (!s->enabled) {
        if (client_fd >= 0) {
            dprintf(client_fd, "\033[33m[WARN]\033[0m Service %s is disabled.\n", s->name);
        }
        return 0;
    }
    if (s->running) return 1;

    for (int i = 0; i < depth; i++) {
        if (strcmp(visited[i], s->name) == 0) {
            if (client_fd >= 0) {
                dprintf(client_fd, "[%s] >> \033[31m[FAIL]\033[0m (Circular dependency detected!)\n", s->name);
            }
            return 0;
        }
    }
    strcpy(visited[depth], s->name);

    if (strlen(s->waiton) > 0) {
        Service* parent = NULL;
        for (int i = 0; i < service_count; i++) {
            if (strcmp(services[i].name, s->waiton) == 0) {
                parent = &services[i];
                break;
            }
        }
        if (parent && !parent->running) {
            if (client_fd >= 0) {
                dprintf(client_fd, "\033[33m[INFO]\033[0m [%s] waiting on dependency %s...\n", s->name, parent->name);
            }
            start_service_recursive(parent, client_fd, visited, depth + 1);
        }
    }

    if (client_fd >= 0) {
        dprintf(client_fd, "[%s] >> ", s->name);
    }

    int is_tty = (strncmp(s->name, "tty", 3) == 0 || strstr(s->exec_cmd, "getty"));

    pid_t pid = fork();
    if (pid < 0) {
        if (client_fd >= 0) dprintf(client_fd, "\033[31m[FAIL]\033[0m (Fork failed)\n");
        return 0;
    }

    if (pid == 0) {
        char path_val[512];
        if (strlen(s->path_env) > 0) {
            snprintf(path_val, sizeof(path_val), "PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", s->path_env);
        } else {
            strcpy(path_val, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        }

        char *child_env[] = {
            "HOME=/",
            "TERM=linux",
            path_val,
            "LD_LIBRARY_PATH=/usr/lib:/lib:/usr/lib64:/lib64",
            NULL
        };

        if (is_tty) {
            setsid();
            char tty_path[64];
            snprintf(tty_path, sizeof(tty_path), "/dev/%s", s->name);
            int tty_fd = open(tty_path, O_RDWR);
            if (tty_fd < 0) tty_fd = open("/dev/tty1", O_RDWR);
            if (tty_fd >= 0) {
                dup2(tty_fd, 0); dup2(tty_fd, 1); dup2(tty_fd, 2);
                ioctl(0, TIOCSCTTY, 0);
                if (tty_fd > 2) close(tty_fd);
            }
        } else {
            char log_path[256];
            snprintf(log_path, sizeof(log_path), "%s/%s.log", journals_dir, s->name);
            int log_fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (log_fd >= 0) {
                dup2(log_fd, 1); dup2(log_fd, 2);
                close(log_fd);
            }
        }

        char* shell = (strlen(s->shell) > 0) ? s->shell : "/bin/sh";
        if (strcasecmp(shell, "true") == 0 || strcasecmp(shell, "y") == 0) shell = "/bin/sh";

        if (strlen(s->inscript) > 0) {
            int pipefds[2];
            pipe(pipefds);
            if (fork() == 0) {
                dup2(pipefds[0], 0);
                close(pipefds[1]);
                execle(shell, shell, NULL, child_env);
                _exit(127);
            }
            close(pipefds[0]);
            write(pipefds[1], s->inscript, strlen(s->inscript));
            close(pipefds[1]);
            exit(0);
        } else {
            char* args[4];
            args[0] = shell;
            args[1] = "-c";
            args[2] = s->exec_cmd;
            args[3] = NULL;
            execve(shell, args, child_env);
            _exit(127);
        }
    } else {
        s->pid = pid;
        s->running = 1;
        if (client_fd >= 0) dprintf(client_fd, "\033[32m[OK]\033[0m\n");
        return 1;
    }
}

int stop_service_recursive(Service* s, int client_fd) {
    for (int i = 0; i < service_count; i++) {
        if (strcmp(services[i].waiton, s->name) == 0 && services[i].running) {
            stop_service_recursive(&services[i], client_fd);
        }
    }

    if (!s->running) return 0;

    if (client_fd >= 0) {
        dprintf(client_fd, "[%s] >> ", s->name);
    }

    if (strlen(s->shutdown_cmd) > 0) {
        system(s->shutdown_cmd);
    }

    if (s->pid > 0) {
        kill(s->pid, SIGTERM);
        usleep(300000);
        kill(s->pid, SIGKILL);
    }

    s->running = 0;
    s->pid = 0;
    if (client_fd >= 0) dprintf(client_fd, "\033[32m[OK]\033[0m\n");
    return 1;
}

// --- Journal Subsystem ---
void handle_journal_command(int client_fd, int argc, char** argv) {
    char* subflag = (argc > 1) ? argv[1] : NULL;
    
    if (!subflag) {
        dprintf(client_fd, "\033[31m[FAIL]\033[0m Missing service or target for journal.\n");
        return;
    }

    if (subflag[0] == '-') {
        char flag_type = subflag[1];
        if (flag_type == 't' || flag_type == 'h') {
            int count = (argc > 2) ? atoi(argv[2]) : 10;
            char* target = (argc > 3) ? argv[3] : "all";
            
            char path[512];
            snprintf(path, sizeof(path), "%s/%s.log", journals_dir, target);
            FILE* f = fopen(path, "r");
            if (f) {
                char lines[512][512];
                int total = 0;
                while (fgets(lines[total], sizeof(lines[total]), f) && total < 512) total++;
                fclose(f);

                int start = (flag_type == 't') ? (total > count ? total - count : 0) : 0;
                int end = (flag_type == 'h') ? (count < total ? count : total) : total;

                for (int i = start; i < end; i++) {
                    dprintf(client_fd, "%s", lines[i]);
                }
            } else {
                dprintf(client_fd, "\033[33m[WARN]\033[0m No journal logs found.\n");
            }
        } else if (flag_type == 'c') {
            int count = 0;
            char* target = "all";
            if (argc > 2 && atoi(argv[2]) != 0) {
                count = atoi(argv[2]);
                target = (argc > 3) ? argv[3] : "all";
            } else if (argc > 2) {
                target = argv[2];
            }

            if (strcmp(target, "all") == 0) {
                for (int i = 0; i < service_count; i++) {
                    char path[512];
                    snprintf(path, sizeof(path), "%s/%s.log", journals_dir, services[i].name);
                    FILE* f = fopen(path, "w");
                    if (f) fclose(f);
                }
            } else {
                char path[512];
                snprintf(path, sizeof(path), "%s/%s.log", journals_dir, target);
                FILE* f = fopen(path, "w");
                if (f) fclose(f);
            }
            dprintf(client_fd, "Journal clear >> \033[32m[OK]\033[0m\n");
        }
    } else {
        char path[512];
        snprintf(path, sizeof(path), "%s/%s.log", journals_dir, subflag);
        FILE* f = fopen(path, "r");
        if (f) {
            char buf[512];
            while (fgets(buf, sizeof(buf), f)) dprintf(client_fd, "%s", buf);
            fclose(f);
        } else {
            dprintf(client_fd, "\033[33m[WARN]\033[0m Journal not found.\n");
        }
    }
}

// --- Client Handler ---
void* handle_client(void* arg) {
    int client_fd = *(int*)arg;
    free(arg);

    char buf[2048];
    memset(buf, 0, sizeof(buf));
    ssize_t bytes = read(client_fd, buf, sizeof(buf) - 1);

    if (bytes > 0) {
        buf[strcspn(buf, "\r\n")] = 0;
        char* argv[16];
        int argc = 0;
        char* token = strtok(buf, " ");
        while (token && argc < 16) {
            argv[argc++] = token;
            token = strtok(NULL, " ");
        }

        if (argc == 0) {
            close(client_fd);
            return NULL;
        }

        pthread_mutex_lock(&services_lock);
        if (strcasecmp(argv[0], "help") == 0 || strcmp(argv[0], "--help") == 0) {
            char* help_text = 
                "\033[1mBoxD Command Reference:\033[0m\n"
                "  start <service>                   - Start a service (and dependencies)\n"
                "  stop <service>                    - Stop a service (and dependents)\n"
                "  restart <service>                 - Restart a service\n"
                "  reload                            - Reload service configurations\n"
                "  enable [--now] <service>          - Enable a service\n"
                "  disable [--now] <service>         - Disable a service\n"
                "  poweroff / shutdown               - Power off the system\n"
                "  journal <service>                 - View full journal for a service\n"
                "  journal -t <lines> <service|all>  - Tail journal lines\n"
                "  journal -h <lines> <service|all>  - Head journal lines\n"
                "  journal -c [<lines>] <service|all>- Clear or truncate journal\n"
                "  list                              - List all loaded services\n";
            dprintf(client_fd, "%s", help_text);
        } else if (strcasecmp(argv[0], "list") == 0) {
            dprintf(client_fd, "\033[1mLoaded Services:\033[0m\n");
            for (int i = 0; i < service_count; i++) {
                char* status = services[i].running ? "\033[32mRUNNING\033[0m" : "\033[31mSTOPPED\033[0m";
                char* enabled = services[i].enabled ? "\033[32m[enabled]\033[0m" : "\033[33m[disabled]\033[0m";
                dprintf(client_fd, " - %s [%s] %s\n", services[i].name, status, enabled);
            }
        } else if (strcasecmp(argv[0], "poweroff") == 0 || strcasecmp(argv[0], "shutdown") == 0) {
            dprintf(client_fd, "System is shutting down...\n");
            
            // Stop all running services gracefully
            for (int i = 0; i < service_count; i++) {
                if (services[i].running) {
                    stop_service_recursive(&services[i], -1);
                }
            }

            // Sync filesystems and power off if PID 1
            sync();
            if (getpid() == 1) {
                reboot(RB_POWER_OFF);
            } else {
                system("poweroff");
            }
            exit(0);
        } else if (strcasecmp(argv[0], "start") == 0 && argc > 1) {
            char visited[128][128];
            for (int i = 0; i < service_count; i++) {
                if (strcmp(services[i].name, argv[1]) == 0) {
                    start_service_recursive(&services[i], client_fd, visited, 0);
                    break;
                }
            }
        } else if (strcasecmp(argv[0], "stop") == 0 && argc > 1) {
            for (int i = 0; i < service_count; i++) {
                if (strcmp(services[i].name, argv[1]) == 0) {
                    stop_service_recursive(&services[i], client_fd);
                    break;
                }
            }
        } else if (strcasecmp(argv[0], "restart") == 0 && argc > 1) {
            for (int i = 0; i < service_count; i++) {
                if (strcmp(services[i].name, argv[1]) == 0) {
                    stop_service_recursive(&services[i], client_fd);
                    sleep(1);
                    char visited[128][128];
                    start_service_recursive(&services[i], client_fd, visited, 0);
                    break;
                }
            }
        } else if (strcasecmp(argv[0], "reload") == 0) {
            DIR* d = opendir(base_dir);
            if (d) {
                char found_names[MAX_SERVICES][128];
                int found_count = 0;
                struct dirent* dir_ent;
                while ((dir_ent = readdir(d)) != NULL) {
                    char* ext = strstr(dir_ent->d_name, ".serv");
                    if (ext && *(ext + 5) == '\0') {
                        size_t name_len = ext - dir_ent->d_name;
                        strncpy(found_names[found_count], dir_ent->d_name, name_len);
                        found_names[found_count][name_len] = '\0';
                        found_count++;

                        char filepath[256];
                        snprintf(filepath, sizeof(filepath), "%s/%s", base_dir, dir_ent->d_name);

                        int exists = 0;
                        for (int i = 0; i < service_count; i++) {
                            if (strcmp(services[i].name, found_names[found_count - 1]) == 0) {
                                strcpy(services[i].file_path, filepath);
                                parse_service_file(filepath, &services[i]);
                                exists = 1;
                                break;
                            }
                        }
                        if (!exists && service_count < MAX_SERVICES) {
                            Service* s = &services[service_count];
                            memset(s, 0, sizeof(Service));
                            strcpy(s->name, found_names[found_count - 1]);
                            strcpy(s->file_path, filepath);
                            s->enabled = 1;
                            parse_service_file(filepath, s);
                            service_count++;
                        }
                    }
                }
                closedir(d);

                for (int i = 0; i < service_count; i++) {
                    int still_exists = 0;
                    for (int j = 0; j < found_count; j++) {
                        if (strcmp(services[i].name, found_names[j]) == 0) {
                            still_exists = 1;
                            break;
                        }
                    }
                    if (!still_exists) {
                        stop_service_recursive(&services[i], -1);
                        for (int k = i; k < service_count - 1; k++) {
                            services[k] = services[k + 1];
                        }
                        service_count--;
                        i--;
                    }
                }
            }
            dprintf(client_fd, "Reload services >> \033[32m[OK]\033[0m\n");
        } else if (strcasecmp(argv[0], "enable") == 0 && argc > 1) {
            for (int i = 0; i < service_count; i++) {
                if (strcmp(services[i].name, argv[1]) == 0) {
                    set_service_enabled_status(&services[i], 1);
                    dprintf(client_fd, "Enable >> \033[32m[OK]\033[0m\n");
                    if (argc > 2 && strcmp(argv[2], "--now") == 0) {
                        char visited[128][128];
                        start_service_recursive(&services[i], client_fd, visited, 0);
                    }
                    break;
                }
            }
        } else if (strcasecmp(argv[0], "disable") == 0 && argc > 1) {
            for (int i = 0; i < service_count; i++) {
                if (strcmp(services[i].name, argv[1]) == 0) {
                    if (argc > 2 && strcmp(argv[2], "--now") == 0) {
                        stop_service_recursive(&services[i], client_fd);
                    }
                    set_service_enabled_status(&services[i], 0);
                    dprintf(client_fd, "Disable >> \033[32m[OK]\033[0m\n");
                    break;
                }
            }
        } else if (strcasecmp(argv[0], "journal") == 0) {
            handle_journal_command(client_fd, argc, argv);
        }
        pthread_mutex_unlock(&services_lock);
    }

    close(client_fd);
    return NULL;
}

int main(int argc, char* argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    strcpy(base_dir, (getpid() == 1) ? "/services" : ".");
    int custom_port = PORT;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-u") == 0 || strcmp(argv[i], "--user") == 0) {}
        else if ((strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--dir") == 0) && i + 1 < argc) strcpy(base_dir, argv[++i]);
        else if ((strcmp(argv[i], "-C") == 0 || strcmp(argv[i], "--port") == 0) && i + 1 < argc) custom_port = atoi(argv[++i]);
    }

    initialize_mounts();
    verify_and_link_libraries();

    pthread_t reaper;
    pthread_create(&reaper, NULL, start_reaper, NULL);

    mkdir(base_dir, 0755);
    snprintf(journals_dir, sizeof(journals_dir), "%s/journals", base_dir);
    mkdir(journals_dir, 0755);

    DIR* d = opendir(base_dir);
    if (d) {
        struct dirent* dir;
        while ((dir = readdir(d)) != NULL) {
            char* ext = strstr(dir->d_name, ".serv");
            if (ext && *(ext + 5) == '\0' && service_count < MAX_SERVICES) {
                Service* s = &services[service_count];
                memset(s, 0, sizeof(Service));
                size_t name_len = ext - dir->d_name;
                strncpy(s->name, dir->d_name, name_len);
                snprintf(s->file_path, sizeof(s->file_path), "%s/%s", base_dir, dir->d_name);
                s->enabled = 1;
                parse_service_file(s->file_path, s);
                service_count++;
            }
        }
        closedir(d);
    }

    printf("Starting Services:\n");

    // --- Prioritize starting tty1 immediately ---
    for (int i = 0; i < service_count; i++) {
        if (strcmp(services[i].name, "tty1") == 0 && services[i].enabled && !services[i].running) {
            char visited[128][128];
            printf("Starting Primary Console (tty1):\n");
            start_service_recursive(&services[i], STDOUT_FILENO, visited, 0);
            break;
        }
    }

    // --- Start remaining services ---
    for (int i = 0; i < service_count; i++) {
        if (strcmp(services[i].name, "tty1") != 0 && services[i].enabled && !services[i].running) {
            char visited[128][128];
            start_service_recursive(&services[i], STDOUT_FILENO, visited, 0);
        }
    }

    char sock_path[256];
    snprintf(sock_path, sizeof(sock_path), "%s/boxd.sock", base_dir);
    unlink(sock_path);

    int unix_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr_un;
    memset(&addr_un, 0, sizeof(addr_un));
    addr_un.sun_family = AF_UNIX;
    strncpy(addr_un.sun_path, sock_path, sizeof(addr_un.sun_path) - 1);
    bind(unix_fd, (struct sockaddr*)&addr_un, sizeof(addr_un));
    listen(unix_fd, 128);

    int tcp_fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(tcp_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr_in;
    memset(&addr_in, 0, sizeof(addr_in));
    addr_in.sin_family = AF_INET;
    addr_in.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr_in.sin_port = htons(custom_port);
    bind(tcp_fd, (struct sockaddr*)&addr_in, sizeof(addr_in));
    listen(tcp_fd, 128);

    printf("Daemons active: TCP port %d, UNIX socket %s [OK]\n", custom_port, sock_path);

    while (1) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(tcp_fd, &readfds);
        FD_SET(unix_fd, &readfds);
        int max_fd = (tcp_fd > unix_fd) ? tcp_fd : unix_fd;

        if (select(max_fd + 1, &readfds, NULL, NULL, NULL) < 0) continue;

        if (FD_ISSET(tcp_fd, &readfds)) {
            int* client = malloc(sizeof(int));
            *client = accept(tcp_fd, NULL, NULL);
            if (*client >= 0) {
                pthread_t t;
                pthread_create(&t, NULL, handle_client, client);
                pthread_detach(t);
            } else {
                free(client);
            }
        }

        if (FD_ISSET(unix_fd, &readfds)) {
            int* client = malloc(sizeof(int));
            *client = accept(unix_fd, NULL, NULL);
            if (*client >= 0) {
                pthread_t t;
                pthread_create(&t, NULL, handle_client, client);
                pthread_detach(t);
            } else {
                free(client);
            }
        }
    }

    return 0;
}
