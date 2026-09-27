#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifdef PTY_IO_FAULTS
// Linked only into the test's second helper build, never the production helper
// or child. Do not fault the atomic exec-error pipe handshake.
ssize_t __real_read(int fd, void *bytes, size_t length);
ssize_t __real_write(int fd, const void *bytes, size_t length);

ssize_t __wrap_read(int fd, void *bytes, size_t length) {
  static unsigned calls;
  if (fd == STDIN_FILENO || isatty(fd)) {
    if (++calls % 5 == 0) { errno = EINTR; return -1; }
    size_t limit = length > 128 ? 97 : 3;
    if (length > limit) length = limit;
  }
  return __real_read(fd, bytes, length);
}

ssize_t __wrap_write(int fd, const void *bytes, size_t length) {
  static unsigned calls;
  if (fd == STDOUT_FILENO || isatty(fd)) {
    if (++calls % 5 == 0) { errno = EINTR; return -1; }
    size_t limit = length > 128 ? 97 : 3;
    if (length > limit) length = limit;
  }
  return __real_write(fd, bytes, length);
}
#else

static int write_all(int fd, const void *bytes, size_t length) {
  const char *p = bytes;
  while (length) {
    ssize_t n = write(fd, p, length);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    p += n; length -= (size_t)n;
  }
  return 0;
}

static int raw(void) {
  struct termios mode;
  if (tcgetattr(0, &mode) != 0) return -1;
  cfmakeraw(&mode);
  return tcsetattr(0, TCSANOW, &mode);
}

static volatile sig_atomic_t finish_fake;
static void finish(int sig) { (void)sig; finish_fake = 1; }

int main(int argc, char **argv) {
  alarm(30); // Failed assertions must not leave a fixture running indefinitely.
  if (argc > 1 && !strcmp(argv[1], "--protocol=1")) {
    // Prepared-helper stand-in: fragmented readiness, then intentionally no
    // complete exit evidence. It never creates a PTY or another process.
    const char *mode = argc > 5 ? argv[5] : "missing";
    int cleanup_failed = !strcmp(mode, "cleanup-failed");
    int transport_clean = !strcmp(mode, "transport-clean");
    signal(SIGUSR1, finish);
    if (cleanup_failed || transport_clean) signal(SIGTERM, finish);
    if (!strcmp(mode, "ignore-close")) signal(SIGTERM, SIG_IGN);
    uint32_t pid = (uint32_t)getpid();
    unsigned char ready[] = {'R', 0, 0, 0, 4, pid >> 24, pid >> 16, pid >> 8, pid};
    for (size_t i = 0; i < sizeof(ready); i++) {
      if (write_all(1, ready + i, 1)) return 90;
      usleep(1000);
    }
    while (!finish_fake) usleep(1000);
    if (cleanup_failed || transport_clean) {
      const char *messages[] = {"fixture transport failed", "PTY cleanup did not complete"};
      for (int i = 0; i < (cleanup_failed ? 2 : 1); i++) {
        size_t length = strlen(messages[i]);
        const unsigned char header[] = {'E', 0, 0, 0, (unsigned char)length};
        if (write_all(1, header, sizeof(header)) || write_all(1, messages[i], length)) return 90;
      }
      return cleanup_failed ? 126 : 125;
    }
    if (!strcmp(mode, "truncated")) {
      const unsigned char partial[] = {'X', 0, 0, 0, 4, 0, 0};
      if (write_all(1, partial, sizeof(partial))) return 90;
    }
    return 0;
  }
  if (argc > 1 && !strcmp(argv[1], "--duplex")) {
    if (raw() || write_all(1, "DUPLEX-READY", 12)) return 90;
    unsigned char input[1024], output[65536];
    size_t total = 0;
    while (total < 3 * 16384) {
      ssize_t n = read(0, input, sizeof(input));
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return 90;
      for (ssize_t i = 0; i < n; i++) memset(output + i * 64, input[i], 64);
      if (write_all(1, output, (size_t)n * 64)) return 90;
      total += (size_t)n;
    }
    return 38;
  }
  if (argc > 1 && !strcmp(argv[1], "--foreground")) {
    if (raw()) return 90;
    int ready[2], release[2];
    if (pipe(ready) || pipe(release)) return 90;
    pid_t job = fork();
    if (job < 0) return 90;
    if (!job) {
      alarm(30);
      close(ready[0]); close(release[0]);
      signal(SIGHUP, SIG_IGN); signal(SIGTERM, SIG_IGN);
      if (setpgid(0, 0) || write_all(ready[1], "r", 1)) _exit(90);
      close(ready[1]);
      // The leader releases us only after tcsetpgrp, avoiding a SIGTTIN race.
      raise(SIGSTOP);
      char byte;
      if (read(0, &byte, 1) != 1 || write_all(release[1], "x", 1)) _exit(90);
      close(release[1]);
      for (;;) pause();
    }
    close(ready[1]); close(release[1]);
    char byte;
    int status;
    if (read(ready[0], &byte, 1) != 1 || waitpid(job, &status, WUNTRACED) != job ||
        tcsetpgrp(0, job) || kill(job, SIGCONT)) return 90;
    close(ready[0]);
    printf("JOB=%d\n", job); fflush(stdout);
    if (read(release[0], &byte, 1) != 1) return 90;
    close(release[0]);
    return 37;
  }
  if (argc > 1 && !strcmp(argv[1], "--burst")) {
    if (raw() || write_all(1, "BURST-READY", 11)) return 90;
    char byte, output[65536];
    if (read(0, &byte, 1) != 1) return 90;
    memset(output, 'b', sizeof(output));
    if (write_all(1, output, sizeof(output))) return 90;
    raise(SIGSTOP); // Test observes this only after all output has been written.
    for (;;) pause();
  }
  int tty = open("/dev/tty", O_RDWR);
  printf("TTY=%d,%d,%d CTTY=%d SID=%d PID=%d PGID=%d FG=%d\n",
         isatty(0), isatty(1), isatty(2), tty >= 0, getsid(0), getpid(),
         getpgrp(), tcgetpgrp(0));
  if (tty >= 0) close(tty);
  char cwd[4096];
  if (!getcwd(cwd, sizeof(cwd))) return 91;
  printf("CWD=%s TERM=%s SENTINEL=%s\n", cwd, getenv("TERM"),
         getenv("ADELE_PTY_SENTINEL") ? "leaked" : "absent");
  // Deliberately split a UTF-8 sequence across writes; transport is raw bytes.
  if (write(1, "\033[31m\xe2", 6) != 6) return 95;
  if (write(1, "\x98\x83\033[0m\n", 7) != 7) return 95;
  fprintf(stderr, "STDERR-MERGED\n");
  fflush(stdout);
  char line[16384];
  while (fgets(line, sizeof(line), stdin)) {
    if (!strcmp(line, "size\n")) {
      struct winsize size;
      if (ioctl(0, TIOCGWINSZ, &size) != 0) return 92;
      printf("SIZE=%u,%u\n", size.ws_row, size.ws_col);
    } else if (!strcmp(line, "exit\n")) {
      printf("FINAL\n"); fflush(stdout); return 37;
    } else if (!strcmp(line, "flood\n")) {
      memset(line, 'x', sizeof(line));
      for (;;) if (write(1, line, sizeof(line)) < 0) return 93;
    } else if (!strcmp(line, "block\n")) {
      if (raw()) return 96;
      printf("BLOCKED\n"); fflush(stdout);
      sleep(60);
      return 97;
    } else {
      printf("RECEIVED:%s", line);
    }
    fflush(stdout);
  }
  return 94;
}

#endif
