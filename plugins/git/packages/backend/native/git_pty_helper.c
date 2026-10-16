// Original ADELE implementation; no code copied from pty2 or portable_pty.
// Published candidates inspected: pty2 0.5.4 (MIT, Dart >=3.11, parent setsid
// and Dart-side fork); portable_pty 0.0.5 (MIT, native SIGCHLD interposition).
// Neither is suitable unchanged in this shared Dart host on SDK 3.10.9.
// Linux 5.3+ with /proc and pidfds; single-threaded, never a Dart-host library.
// Protocol v1: type byte + big-endian uint32 length + payload (<= 16384).
// In: W bytes, S uint16 rows/cols. Out: R uint32 pid, O bytes, A empty,
// X uint32 shell-style exit code, E UTF-8 diagnostic. One command at a time.
// Helper exit (not child status): 0 = cleaned, 64 = invalid invocation/no child,
// 125 = setup/transport failure with cleanup complete, 126 = cleanup unconfirmed.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define LIMIT 16384
#define TRANSPORT_FAILED 125
#define CLEANUP_FAILED 126
static volatile sig_atomic_t stopping;

static void stop(int signal_number) { (void)signal_number; stopping = 1; }

static int64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) _exit(CLEANUP_FAILED);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static uint32_t decode(const unsigned char *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | p[3];
}

static void encode(unsigned char *p, uint32_t n) {
  p[0] = n >> 24; p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
}

// Neither an unresponsive terminal nor an unread pipe can hold cleanup forever.
static int write_all(int fd, const unsigned char *p, size_t n) {
  int64_t deadline = now_ms() + 5000;
  while (n && !stopping) {
    ssize_t written = write(fd, p, n);
    if (written > 0) { p += written; n -= (size_t)written; continue; }
    if (written < 0 && errno != EAGAIN && errno != EINTR) return -1;
    struct pollfd fds[2] = {{fd, POLLOUT, 0}, {STDIN_FILENO, 0, 0}};
    if (poll(fds, 2, 50) < 0 && errno != EINTR) return -1;
    if (fds[1].revents & (POLLHUP | POLLERR)) return -1;
    if (now_ms() >= deadline) { errno = ETIMEDOUT; return -1; }
  }
  return n ? -1 : 0;
}

static int frame(char type, const unsigned char *bytes, uint32_t n) {
  unsigned char header[5] = {(unsigned char)type, 0, 0, 0, 0};
  encode(header + 1, n);
  return write_all(STDOUT_FILENO, header, 5) ||
         (n && write_all(STDOUT_FILENO, bytes, n)) ? -1 : 0;
}

static void failure(const char *operation) {
  char message[256];
  snprintf(message, sizeof(message), "%s: %s", operation, strerror(errno));
  (void)frame('E', (const unsigned char *)message, (uint32_t)strlen(message));
}

static int nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void remember_foreground(int master, pid_t *foreground) {
  pid_t current = tcgetpgrp(master);
  if (current > 1) *foreground = current;
}

// The unreaped leader pins the session ID. Acquire a pidfd BEFORE revalidating
// membership, so a disappearing/reused PID cannot redirect a signal elsewhere.
// After leader death, the kernel forgets the terminal's foreground group; include
// remaining members of this private session, including a job switched between polls.
static int signal_owned(pid_t child, pid_t foreground, int sig, int64_t deadline) {
  siginfo_t info = {0};
  while (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
    if (errno != EINTR) return -1;
  }
  DIR *processes = opendir("/proc");
  if (!processes) return -1;
  int failed = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(processes);
    if (!entry) { if (errno) failed = 1; break; }
    if (now_ms() >= deadline) { errno = ETIMEDOUT; failed = 1; break; }
    char *end;
    long value = strtol(entry->d_name, &end, 10);
    if (*end || value <= 1 || value > INT32_MAX) continue;
    pid_t pid = (pid_t)value;
    if (pid != child && getsid(pid) != child) continue;
    int fd = (int)syscall(SYS_pidfd_open, pid, 0);
    if (fd < 0) {
      if (errno == ESRCH) continue;
      failed = 1; break;
    }
    pid_t group = getpgid(pid);
    if (pid == child || (getsid(pid) == child &&
        (info.si_pid || group == child || group == foreground))) {
      if (syscall(SYS_pidfd_send_signal, fd, sig, NULL, 0) < 0 && errno != ESRCH) {
        failed = 1;
      }
    }
    close(fd);
    if (failed) break;
  }
  closedir(processes);
  return failed ? -1 : 0;
}

// The shell and its ordinary job-control foreground child have different groups.
// Subreaping is helper-private and lets us collect an orphaned foreground job.
// This is not containment of intentionally daemonized/detached descendants.
static int cleanup(pid_t child, int master, pid_t foreground) {
  remember_foreground(master, &foreground);
  int64_t signal_deadline = now_ms() + 1000;
  int failed = signal_owned(child, foreground, SIGTERM, signal_deadline) != 0;
  if (signal_owned(child, foreground, SIGCONT, signal_deadline)) failed = 1;
  struct timespec grace = {0, 250000000};
  while (nanosleep(&grace, &grace) < 0 && errno == EINTR) {}
  remember_foreground(master, &foreground);
  if (signal_owned(child, foreground, SIGKILL, signal_deadline)) failed = 1;
  close(master);
  int result = -1;
  int64_t deadline = now_ms() + 1000;
  for (;;) {
    int status;
    pid_t reaped = waitpid(-1, &status, WNOHANG);
    if (reaped == child) {
      result = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
    if (reaped > 0) continue;
    if (reaped < 0 && errno == ECHILD) break;
    if (now_ms() >= deadline) { failed = 1; break; }
    struct timespec pause = {0, 10000000};
    nanosleep(&pause, NULL);
  }
  return failed ? -1 : result;
}

static unsigned short dimension(const char *text, long maximum) {
  char *end;
  long n = strtol(text, &end, 10);
  if (!*text || *end || n < 1 || n > maximum) return 0;
  return (unsigned short)n;
}

int main(int argc, char **argv) {
  if (argc < 5 || strcmp(argv[1], "--protocol=1") || argv[4][0] != '/') return 64;
  struct winsize size = {dimension(argv[2], 2000), dimension(argv[3], 1000), 0, 0};
  if (!size.ws_row || !size.ws_col) return 64;
  sigset_t mask;
  sigemptyset(&mask);
  if (sigprocmask(SIG_SETMASK, &mask, NULL) != 0) return TRANSPORT_FAILED;
  signal(SIGCHLD, SIG_DFL);
  signal(SIGPIPE, SIG_IGN);
  struct sigaction action = {0};
  action.sa_handler = stop;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGHUP, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  if (nonblocking(STDIN_FILENO) || nonblocking(STDOUT_FILENO) ||
      prctl(PR_SET_CHILD_SUBREAPER, 1) != 0) {
    failure("helper setup"); return TRANSPORT_FAILED;
  }
  int self = (int)syscall(SYS_pidfd_open, getpid(), 0);
  if (self < 0) { failure("pidfd_open"); return TRANSPORT_FAILED; }
  int supported = (int)syscall(SYS_pidfd_send_signal, self, 0, NULL, 0);
  close(self);
  if (supported < 0) { failure("pidfd_send_signal"); return TRANSPORT_FAILED; }
  DIR *processes = opendir("/proc");
  if (!processes) { failure("process enumeration"); return TRANSPORT_FAILED; }
  closedir(processes);
  int master, slave, errors[2];
  if (openpty(&master, &slave, NULL, NULL, &size) != 0) {
    failure("openpty"); return TRANSPORT_FAILED;
  }
  if (pipe2(errors, O_CLOEXEC) != 0) {
    failure("exec error pipe"); close(master); close(slave); return TRANSPORT_FAILED;
  }
  pid_t child = fork();
  if (child == 0) {
    close(errors[0]);
    close(master);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 ||
        dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0) {
      int error = errno;
      if (write(errors[1], &error, sizeof(error)) != sizeof(error)) _exit(125);
      _exit(126);
    }
    if (slave > 2) close(slave);
    execv(argv[4], &argv[4]);
    int error = errno;
    if (write(errors[1], &error, sizeof(error)) != sizeof(error)) _exit(125);
    _exit(127);
  }
  close(slave);
  close(errors[1]);
  if (child < 0) {
    failure("fork"); close(errors[0]); close(master); return TRANSPORT_FAILED;
  }
  struct pollfd exec_poll = {errors[0], POLLIN, 0};
  int polled = poll(&exec_poll, 1, 5000);
  int exec_error = 0;
  ssize_t error_size = polled > 0 ? read(errors[0], &exec_error, sizeof(exec_error)) : -1;
  close(errors[0]);
  if (error_size != 0 || stopping || nonblocking(master)) {
    errno = exec_error ? exec_error : ETIMEDOUT;
    failure("exec/setup");
    return cleanup(child, master, child) < 0 ? CLEANUP_FAILED : TRANSPORT_FAILED;
  }
  unsigned char data[LIMIT], input[LIMIT + 5], number[4];
  encode(number, (uint32_t)child);
  int failed = frame('R', number, 4) != 0;
  size_t used = 0, needed = 5;
  size_t pending = 0, written = 0;
  int64_t input_deadline = 0;
  pid_t foreground = child;
  int eof = 0;
  while (!stopping && !failed) {
    remember_foreground(master, &foreground);
    struct pollfd fds[2] = {
      {STDIN_FILENO, pending ? 0 : POLLIN, 0},
      {eof ? -1 : master, POLLIN | (pending ? POLLOUT : 0), 0}
    };
    int ready = poll(fds, 2, 50);
    if (ready < 0) { if (errno == EINTR) continue; failed = 1; break; }
    if (stopping) break;
    remember_foreground(master, &foreground);
    if (fds[0].revents & (POLLHUP | POLLERR)) break;
    if (!pending && (fds[0].revents & POLLIN)) {
      ssize_t n = read(STDIN_FILENO, input + used, needed - used);
      if (n == 0) break;
      if (n < 0 && errno != EINTR && errno != EAGAIN) { failed = 1; break; }
      if (n > 0) used += (size_t)n;
      if (used == 5 && needed == 5) {
        uint32_t length = decode(input + 1);
        if (length > LIMIT || (input[0] != 'W' && input[0] != 'S') ||
            (input[0] == 'S' && length != 4)) {
          errno = EPROTO; failed = 1; break;
        }
        needed += length;
      }
      if (used == needed) {
        if (input[0] == 'W') {
          pending = used - 5;
          written = 0;
          input_deadline = now_ms() + 5000;
        } else {
          size.ws_row = ((unsigned)input[5] << 8) | input[6];
          size.ws_col = ((unsigned)input[7] << 8) | input[8];
          if (!size.ws_row || !size.ws_col || size.ws_row > 2000 || size.ws_col > 1000) {
            errno = EINVAL; failed = 1;
          } else {
            failed = ioctl(master, TIOCSWINSZ, &size) != 0;
          }
        }
        if (!pending) {
          if (!failed) failed = frame('A', NULL, 0) != 0;
          used = 0; needed = 5;
        }
      }
    }
    if (!eof && !failed && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(master, data, LIMIT);
      if (n > 0) failed = frame('O', data, (uint32_t)n) != 0;
      else if (n == 0 || (n < 0 && errno == EIO)) eof = 1;
      else if (errno != EAGAIN && errno != EINTR) failed = 1;
    }
    if (pending && !failed && !stopping) {
      if (eof) { errno = EIO; failed = 1; }
      else if (fds[1].revents & POLLOUT) {
        ssize_t n = write(master, input + 5 + written, pending);
        if (n > 0) { written += (size_t)n; pending -= (size_t)n; }
        else if (n < 0 && errno != EAGAIN && errno != EINTR) failed = 1;
        if (!pending && !failed) {
          failed = frame('A', NULL, 0) != 0;
          used = 0; needed = 5;
        }
      }
      if (pending && now_ms() >= input_deadline) { errno = ETIMEDOUT; failed = 1; }
    }
    // Leave the leader waitable until cleanup has signalled its process group.
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
      if (errno == EINTR) continue;
      failed = 1; break;
    }
    if (info.si_pid) {
      // Drain a finite tail, even if a surviving descendant floods the terminal.
      size_t drained = 0;
      while (drained < 16 * LIMIT && !failed && !stopping) {
        size_t remaining = 16 * LIMIT - drained;
        ssize_t n = read(master, data, remaining < LIMIT ? remaining : LIMIT);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
          if (n < 0 && errno != EAGAIN && errno != EIO) failed = 1;
          break;
        }
        drained += (size_t)n;
        failed = frame('O', data, (uint32_t)n) != 0;
      }
      if (drained >= 16 * LIMIT) { errno = EOVERFLOW; failed = 1; }
      break;
    }
  }
  if (failed && !stopping) failure("PTY transport");
  int result = cleanup(child, master, foreground);
  // A close signal still permits a final exit frame, but never delays cleanup.
  stopping = 0;
  if (result < 0) {
    errno = ETIMEDOUT;
    failure("PTY cleanup did not complete");
    return CLEANUP_FAILED;
  }
  encode(number, (uint32_t)result);
  if (!failed) (void)frame('X', number, 4);
  return failed ? TRANSPORT_FAILED : 0;
}
