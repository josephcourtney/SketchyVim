#include "Carbon/Carbon.h"
#include "Cocoa/Cocoa.h"
#include "event_tap.h"
#include "ax.h"
#include "workspace.h"
#include <string.h>

void* g_workspace;

static void suspend_svim(int signal_number) {
  (void) signal_number;
  g_svim_suspended = 1;
}

static void resume_svim(int signal_number) {
  (void) signal_number;
  g_svim_suspended = 0;
}

static void acquire_lockfile(void) {
  char *user = getenv("USER");
  if (!user) printf("Error: User variable not set.\n"), exit(1);

  char buffer[256];
  snprintf(buffer, 256, "/tmp/svim_%s.lock" , user);

  int handle = open(buffer, O_CREAT | O_WRONLY, 0600);
  if (handle == -1) {
    printf("Error: Could not create lock-file.\n");
    exit(1);
  }

  struct flock lockfd = {
    .l_start  = 0,
    .l_len    = 0,
    .l_pid    = getpid(),
    .l_type   = F_WRLCK,
    .l_whence = SEEK_SET
  };

  if (fcntl(handle, F_SETLK, &lockfd) == -1) {
    printf("Error: Could not acquire lock-file.\nsvim already running?\n");
    exit(1);
  }
}

int main (int argc, char *argv[]) {
  // One-shot CLI operations do not need AppKit initialization. Keeping them
  // ahead of NSApplicationLoad() avoids unnecessary application registration
  // and lets status/access checks run cleanly when the daemon is stopped.
  if (argc == 2 && strcmp(argv[1], "--check-access") == 0) {
    return ax_access_granted() ? 0 : 1;
  }

  if (argc == 2 && strcmp(argv[1], "--request-access") == 0) {
    bool granted = ax_request_access();
    if (granted) {
      printf("Accessibility access is already granted.\n");
    } else {
      printf("Accessibility access requested. Grant access in System Settings, then start svim.\n");
    }
    return 0;
  }

  NSApplicationLoad();

  signal(SIGCHLD, SIG_IGN);
  signal(SIGPIPE, SIG_IGN);
  signal(SIGUSR1, suspend_svim);
  signal(SIGUSR2, resume_svim);

  acquire_lockfile();
  ax_begin(&g_ax);
  event_tap_begin(&g_event_tap);
  workspace_begin(&g_workspace);

  CFRunLoopRun();
  return 0;
}
