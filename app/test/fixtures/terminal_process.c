#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>

static volatile sig_atomic_t hidden_requested;
static volatile sig_atomic_t resized;

static void notify(int signal) {
  if (signal == SIGUSR1) hidden_requested = 1;
  if (signal == SIGWINCH) resized = 1;
}

static int count_launch(void) {
  int fd = open("launch-count", O_RDWR | O_CREAT, 0600);
  if (fd < 0 || flock(fd, LOCK_EX) != 0) return -1;
  char text[32] = {0};
  if (read(fd, text, sizeof(text) - 1) < 0) return -1;
  int count = atoi(text) + 1;
  if (lseek(fd, 0, SEEK_SET) < 0 || ftruncate(fd, 0) != 0 ||
      dprintf(fd, "%d\n", count) < 0 || fsync(fd) != 0) return -1;
  close(fd);
  return count;
}

int main(void) {
  alarm(60); /* A broken test cannot leave this fixture running indefinitely. */
  setvbuf(stdout, NULL, _IONBF, 0);
  struct termios mode;
  struct winsize initial;
  char cwd[4096];
  uint64_t nonce;
  if (tcgetattr(STDIN_FILENO, &mode) != 0 ||
      ioctl(STDIN_FILENO, TIOCGWINSZ, &initial) != 0 ||
      getcwd(cwd, sizeof(cwd)) == NULL ||
      getrandom(&nonce, sizeof(nonce), 0) != sizeof(nonce)) return 90;
  cfmakeraw(&mode);
  if (tcsetattr(STDIN_FILENO, TCSANOW, &mode) != 0) return 91;

  struct sigaction action = {.sa_handler = notify};
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGUSR1, &action, NULL) != 0 ||
      sigaction(SIGWINCH, &action, NULL) != 0) return 92;
  sigset_t blocked, previous;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGUSR1);
  sigaddset(&blocked, SIGWINCH);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous) != 0) return 93;

  /* The file is only a startup barrier and respawn counter, not a transcript.
     Initial geometry is sampled before the test is allowed to mount a view. */
  int launches = count_launch();
  if (launches < 1) return 94;
  int controlling_tty = open("/dev/tty", O_RDWR);
  printf("BOOT=%016" PRIx64 "\r\nPID=%d\r\nSPAWNS=%d\r\n",
         nonce, getpid(), launches);
  printf("TTY=%d,%d,%d\r\nCTTY=%d\r\n", isatty(0), isatty(1), isatty(2),
         controlling_tty >= 0 && tcgetpgrp(0) == getpgrp());
  if (controlling_tty >= 0) close(controlling_tty);
  printf("CWD=%s\r\nINITIAL=%u,%u\r\n", cwd, initial.ws_col, initial.ws_row);
  fprintf(stderr, "STDERR-MERGED\r\n");
  printf("READY\r\n");

  char input[256];
  size_t used = 0;
  unsigned commands = 0;
  int reply = 0;
  for (;;) {
    if (resized) {
      resized = 0;
      struct winsize size;
      if (ioctl(0, TIOCGWINSZ, &size) != 0) return 95;
      printf("SIZE=%u,%u\r\n", size.ws_col, size.ws_row);
    }
    if (hidden_requested) {
      hidden_requested = 0;
      printf("\033[32mHIDDEN=%016" PRIx64 "\033[0m\r\n", nonce);
      /* Save/restore avoids destroying retained output while fixing the reply. */
      printf("\0337\033[3;7H\033[6n\0338");
    }
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(STDIN_FILENO, &readable);
    /* Atomically unblock signals while waiting, with no lost-wakeup window. */
    int ready = pselect(1, &readable, NULL, NULL, NULL, &previous);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) return 96;
    unsigned char byte;
    if (read(STDIN_FILENO, &byte, 1) != 1) return 97;
    if (byte == 3) {
      printf("CONTROL=03\r\n");
      continue;
    }
    if (byte == 27) {
      reply = 1;
      used = 0;
      continue;
    }
    if (used + 1 >= sizeof(input)) return 98;
    if (reply && byte == 'R') {
      unsigned row, column;
      input[used] = '\0';
      if (sscanf(input, "[%u;%u", &row, &column) != 2) return 99;
      printf("REPLY=%u,%u:%016" PRIx64 "\r\n", row, column, nonce);
      reply = 0;
      used = 0;
    } else if (!reply && (byte == '\r' || byte == '\n')) {
      input[used] = '\0';
      if (!strcmp(input, "exit")) {
        printf("FINAL=%016" PRIx64 "\r\n", nonce);
        return 37;
      }
      printf("ACK=%u:%016" PRIx64 ":%s\r\n", ++commands, nonce, input);
      used = 0;
    } else {
      input[used++] = (char)byte;
    }
  }
}
