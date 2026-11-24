// vdisplay: create a headless virtual display for game streaming on macOS.
//
//   vdisplay start [-w W] [-h H] [-r FPS] [--hidpi]
//                                           create the display (reused if already up at that mode);
//                                           --hidpi presents W x H pixels at 2x (for Wine RetinaMode)
//   vdisplay stop                           remove it
//   vdisplay status                                      print the running display, if any
//   vdisplay list                                        print all displays
//
// `start` defaults the mode from Sunshine's SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS, so it works as a
// Sunshine prep-cmd with no arguments: {"do": "vdisplay start", "undo": "vdisplay stop"}.
// The display is owned by a detached `vdisplay serve` process; `start` returns once it is ready.
//
// The display is deliberately NOT made main: it is an extra monitor to the right of the desktop that
// nothing uses unless told to. Point the game at it (e.g. a fullscreen monitor setting) and point
// Sunshine's output_name at its device id. See README for why making it main doesn't work.

#import <Foundation/Foundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <libproc.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>

#import "VDVirtualDisplay.h"

extern char **environ;

static const uint32_t kSerial = 0x53554E31;  // fixed so macOS remembers the display's settings

static void logf_(FILE *f, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void logf_(FILE *f, NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fprintf(f, "vdisplay: %s\n", s.UTF8String);
  fflush(f);
}
#define LOG(...) logf_(stdout, __VA_ARGS__)
#define ERR(...) logf_(stderr, __VA_ARGS__)

static NSString *StateDir(void) {
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vdisplay"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return dir;
}
static NSString *PidPath(void) { return [StateDir() stringByAppendingPathComponent:@"vdisplay.pid"]; }
static NSString *LogPath(void) { return [StateDir() stringByAppendingPathComponent:@"vdisplay.log"]; }
static NSString *PendingPath(void) { return [StateDir() stringByAppendingPathComponent:@"pending-removal"]; }

// Returns the pid of a live `vdisplay serve` process from the pid file, or 0.
static pid_t RunningServer(void) {
  NSString *s = [NSString stringWithContentsOfFile:PidPath() encoding:NSUTF8StringEncoding error:nil];
  pid_t pid = (pid_t)[s intValue];
  if (pid <= 0 || kill(pid, 0) != 0) {
    return 0;
  }
  char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
  if (proc_name(pid, name, sizeof(name)) <= 0 || strcmp(name, "vdisplay") != 0) {
    return 0;  // stale pid file, pid reused by something else
  }
  return pid;
}

static NSInteger EnvInt(const char *name, NSInteger fallback) {
  const char *v = getenv(name);
  NSInteger n = v ? atol(v) : 0;
  return n > 0 ? n : fallback;
}

typedef struct {
  NSInteger width, height, fps;
  BOOL hiDPI;
} Options;

static BOOL ParseOptions(NSArray<NSString *> *args, Options *o) {
  o->width = EnvInt("SUNSHINE_CLIENT_WIDTH", 1920);
  o->height = EnvInt("SUNSHINE_CLIENT_HEIGHT", 1080);
  o->fps = EnvInt("SUNSHINE_CLIENT_FPS", 60);
  o->hiDPI = NO;
  for (NSUInteger i = 0; i < args.count; i++) {
    NSString *a = args[i];
    BOOL hasValue = i + 1 < args.count;
    if ([a isEqualToString:@"-w"] && hasValue) o->width = [args[++i] integerValue];
    else if ([a isEqualToString:@"-h"] && hasValue) o->height = [args[++i] integerValue];
    else if ([a isEqualToString:@"-r"] && hasValue) o->fps = [args[++i] integerValue];
    else if ([a isEqualToString:@"--hidpi"]) o->hiDPI = YES;
    else {
      ERR(@"unknown option: %@", a);
      return NO;
    }
  }
  return YES;
}

static int Stop(void) {
  pid_t pid = RunningServer();
  if (!pid) {
    LOG(@"not running");
    [[NSFileManager defaultManager] removeItemAtPath:PidPath() error:nil];
    return 0;
  }
  kill(pid, SIGTERM);
  for (int i = 0; i < 300 && kill(pid, 0) == 0; i++) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:PendingPath()]) {
      LOG(@"the Mac is locked or asleep; the display will be removed after unlock (server pid %d)", pid);
      return 0;
    }
    usleep(50 * 1000);
  }
  if (kill(pid, 0) == 0) {
    // Don't SIGKILL: an owner dying is still a hotplug, and the server only lingers if something is wrong.
    ERR(@"server %d did not exit within 15 s; leaving it running", pid);
    return 1;
  }
  [[NSFileManager defaultManager] removeItemAtPath:PidPath() error:nil];
  LOG(@"stopped");
  return 0;
}

// ---- serve: owns the display until SIGTERM ----------------------------------------------

static VDVirtualDisplay *gDisplay;
static BOOL DisplayIsOnline(CGDirectDisplayID displayID) {
  CGDirectDisplayID ids[32];
  uint32_t count = 0;
  CGGetOnlineDisplayList(32, ids, &count);
  for (uint32_t i = 0; i < count; i++) {
    if (ids[i] == displayID) return YES;
  }
  return NO;
}

static IOPMAssertionID gAssertion;
static dispatch_source_t gPendingTimer;

// Adding or removing a display while the session is locked or the displays are asleep is unsafe:
// WindowServer defers the hotplug, and processing it later (on wake) has left WindowServer unable
// to stream any display, with the console unresponsive until a forced restart (see README,
// 2026-11-21). Never force-wake the displays to get around this either; that is what triggered it.
static BOOL SessionIsLocked(void) {
  CFDictionaryRef session = CGSessionCopyCurrentDictionary();
  if (!session) return YES;  // no GUI session (e.g. at the login window)
  BOOL locked = [((__bridge NSDictionary *)session)[@"CGSSessionScreenIsLocked"] boolValue];
  CFRelease(session);
  return locked;
}

static NSString *UnsafeReason(void) {
  // Test hook: `touch $TMPDIR/vdisplay/simulate-lock` to exercise the locked paths without locking.
  if ([[NSFileManager defaultManager] fileExistsAtPath:[StateDir() stringByAppendingPathComponent:@"simulate-lock"]]) {
    return @"the Mac is locked (simulated)";
  }
  if (SessionIsLocked()) return @"the Mac is locked";
  if (CGDisplayIsAsleep(CGMainDisplayID())) return @"the displays are asleep";
  return nil;
}

static void Teardown(void) {
  CGDirectDisplayID displayID = gDisplay.displayID;
  [gDisplay invalidate];
  gDisplay = nil;
  // Keep display sleep off until WindowServer has actually removed ours.
  for (int i = 0; i < 200 && DisplayIsOnline(displayID); i++) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  if (DisplayIsOnline(displayID)) ERR(@"display %u still online 10 s after teardown", displayID);
  if (gAssertion) IOPMAssertionRelease(gAssertion);
  [[NSFileManager defaultManager] removeItemAtPath:PendingPath() error:nil];
  NSString *pidText = [NSString stringWithContentsOfFile:PidPath() encoding:NSUTF8StringEncoding error:nil];
  if ([pidText intValue] == getpid()) {
    [[NSFileManager defaultManager] removeItemAtPath:PidPath() error:nil];
  }
  LOG(@"display %u removed; server exiting", displayID);
  exit(0);
}

static void Shutdown(int sig) {
  if (gPendingTimer) return;  // already waiting for an unlock
  NSString *reason = UnsafeReason();
  if (!reason) {
    Teardown();
  }
  // Keep the display until it's safe to remove it. Let the Mac sleep normally meanwhile.
  LOG(@"stop requested (signal %d) but %@; removing the display after unlock", sig, reason);
  [@"" writeToFile:PendingPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if (gAssertion) {
    IOPMAssertionRelease(gAssertion);
    gAssertion = 0;
  }
  gPendingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(gPendingTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
  dispatch_source_set_event_handler(gPendingTimer, ^{
    if (!UnsafeReason()) {
      // Give WindowServer a moment after the unlock before reconfiguring.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!UnsafeReason()) Teardown();
      });
    }
  });
  dispatch_resume(gPendingTimer);
}

static void Report(int fd, NSString *line) {
  if (fd < 0) return;
  NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
  write(fd, d.bytes, d.length);
  close(fd);
}

static int Serve(Options o) {
  const char *fdEnv = getenv("VDISPLAY_READY_FD");
  int readyFd = fdEnv ? atoi(fdEnv) : -1;
  unsetenv("VDISPLAY_READY_FD");

  NSString *reason = UnsafeReason();
  if (reason) {
    Report(readyFd, [NSString stringWithFormat:@"error %@: unlock it, then launch again", reason]);
    return 1;
  }
  // Hold display sleep off while the display exists: sleep is global, and usually locks the session.
  IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertionLevelOn,
                              CFSTR("vdisplay: streaming display active"), &gAssertion);

  NSError *error;
  gDisplay = [[VDVirtualDisplay alloc] initWithName:@"Streaming Display"
                                              width:(NSUInteger)o.width
                                             height:(NSUInteger)o.height
                                        refreshRate:(double)o.fps
                                              hiDPI:o.hiDPI
                                             serial:kSerial
                                            timeout:5
                                              error:&error];
  if (!gDisplay) {
    Report(readyFd, [@"error " stringByAppendingString:error.localizedDescription]);
    ERR(@"%@", error.localizedDescription);
    return 1;
  }

  [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:PidPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
  [[NSString stringWithFormat:@"%u %ldx%ld@%ld%@\n", gDisplay.displayID, (long)o.width, (long)o.height, (long)o.fps, o.hiDPI ? @"-hidpi" : @""]
      writeToFile:[StateDir() stringByAppendingPathComponent:@"display"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

  int sigs[] = {SIGTERM, SIGINT, SIGHUP};
  for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
    signal(sigs[i], SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sigs[i], 0, dispatch_get_main_queue());
    int s = sigs[i];
    dispatch_source_set_event_handler(src, ^{ Shutdown(s); });
    dispatch_resume(src);
    (void)CFBridgingRetain(src);
  }

  LOG(@"display %u ready at %ldx%ld@%ld", gDisplay.displayID, (long)o.width, (long)o.height, (long)o.fps);
  Report(readyFd, [NSString stringWithFormat:@"ok %u", gDisplay.displayID]);

  CFRunLoopRun();
  return 0;
}

// ---- start: spawn the server detached and wait for it to report ----------------------------

static int Start(NSArray<NSString *> *args) {
  Options o;
  if (!ParseOptions(args, &o)) return 2;
  NSString *reason = UnsafeReason();
  if (reason) {
    // Fails the Sunshine prep-cmd, so Moonlight reports the launch failed instead of streaming black.
    ERR(@"refusing to start: %@. Unlock it, then launch again.", reason);
    return 1;
  }
  BOOL pending = [[NSFileManager defaultManager] fileExistsAtPath:PendingPath()];
  if (RunningServer() && !pending) {
    // Same mode already up (e.g. the client reconnected): keep it, so the game's window stays put.
    NSString *info = [NSString stringWithContentsOfFile:[StateDir() stringByAppendingPathComponent:@"display"]
                                               encoding:NSUTF8StringEncoding error:nil];
    NSString *mode = [NSString stringWithFormat:@"%ldx%ld@%ld%@", (long)o.width, (long)o.height, (long)o.fps, o.hiDPI ? @"-hidpi" : @""];
    NSArray<NSString *> *parts = [[info stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@" "];
    if (parts.count == 2 && [parts[1] isEqualToString:mode]) {
      LOG(@"display %@ already running at %@", parts[0], mode);
      return 0;
    }
    Stop();
  }
  // A server from a session that ended while locked removes its display shortly after unlock; wait
  // for that rather than stacking a second display on top of a pending removal.
  for (int i = 0; i < 300 && RunningServer(); i++) usleep(50 * 1000);
  if (RunningServer()) {
    ERR(@"a previous display is still being removed; try again in a few seconds");
    return 1;
  }

  char exe[PATH_MAX];
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0) return 1;

  int fds[2];
  if (pipe(fds) != 0) return 1;

  NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:@"serve"];
  [argv addObjectsFromArray:args];
  NSUInteger argc = argv.count + 1;
  char **cargv = calloc(argc + 1, sizeof(char *));
  cargv[0] = exe;
  for (NSUInteger i = 0; i < argv.count; i++) cargv[i + 1] = (char *)argv[i].UTF8String;

  // Pass the resolved mode explicitly so the server doesn't depend on inherited env.
  setenv("SUNSHINE_CLIENT_WIDTH", [@(o.width) stringValue].UTF8String, 1);
  setenv("SUNSHINE_CLIENT_HEIGHT", [@(o.height) stringValue].UTF8String, 1);
  setenv("SUNSHINE_CLIENT_FPS", [@(o.fps) stringValue].UTF8String, 1);
  setenv("VDISPLAY_READY_FD", [@(fds[1]) stringValue].UTF8String, 1);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, LogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
  posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
  posix_spawn_file_actions_addclose(&actions, fds[0]);
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

  pid_t pid;
  int rc = posix_spawn(&pid, exe, &actions, &attr, cargv, environ);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  free(cargv);
  close(fds[1]);
  if (rc != 0) {
    ERR(@"failed to spawn server: %s", strerror(rc));
    return 1;
  }

  // Wait for one status line (or EOF if the server died) with a timeout.
  NSMutableData *buf = [NSMutableData data];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while ([deadline timeIntervalSinceNow] > 0) {
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fds[0], &set);
    struct timeval tv = {0, 100 * 1000};
    if (select(fds[0] + 1, &set, NULL, NULL, &tv) > 0) {
      char chunk[256];
      ssize_t n = read(fds[0], chunk, sizeof(chunk));
      if (n <= 0) break;
      [buf appendBytes:chunk length:(NSUInteger)n];
      if (memchr(chunk, '\n', (size_t)n)) break;
    }
  }
  close(fds[0]);

  NSString *line = [[[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([line hasPrefix:@"ok "]) {
    LOG(@"display %@ ready at %ldx%ld@%ld (server pid %d, log %@)", [line substringFromIndex:3],
        (long)o.width, (long)o.height, (long)o.fps, pid, LogPath());
    return 0;
  }
  ERR(@"%@", line.length ? line : @"server exited or timed out before reporting; see log");
  kill(pid, SIGTERM);
  waitpid(pid, NULL, WNOHANG);
  return 1;
}

static int Status(void) {
  pid_t pid = RunningServer();
  if (!pid) {
    LOG(@"not running");
    return 1;
  }
  NSString *info = [NSString stringWithContentsOfFile:[StateDir() stringByAppendingPathComponent:@"display"]
                                             encoding:NSUTF8StringEncoding error:nil];
  LOG(@"running (pid %d): display %@", pid,
      [info stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
  return 0;
}

static int List(void) {
  CGDirectDisplayID ids[32];
  uint32_t count = 0;
  CGGetOnlineDisplayList(32, ids, &count);
  for (uint32_t i = 0; i < count; i++) {
    CGRect b = CGDisplayBounds(ids[i]);
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(ids[i]);
    printf("%u\t%s%s%s\t%.0fx%.0f at (%.0f,%.0f)\tpixels %zux%zu @ %.0fHz\tvendor 0x%x model 0x%x\n", ids[i],
           CGDisplayIsMain(ids[i]) ? "main " : "", CGDisplayIsBuiltin(ids[i]) ? "builtin " : "",
           CGDisplayIsActive(ids[i]) ? "active" : "inactive", b.size.width, b.size.height, b.origin.x, b.origin.y,
           m ? CGDisplayModeGetPixelWidth(m) : 0, m ? CGDisplayModeGetPixelHeight(m) : 0,
           m ? CGDisplayModeGetRefreshRate(m) : 0, CGDisplayVendorNumber(ids[i]), CGDisplayModelNumber(ids[i]));
    if (m) CGDisplayModeRelease(m);
  }
  return 0;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
    NSString *cmd = args.firstObject ?: @"";
    if (args.count) [args removeObjectAtIndex:0];

    if ([cmd isEqualToString:@"start"]) return Start(args);
    if ([cmd isEqualToString:@"stop"]) return Stop();
    if ([cmd isEqualToString:@"status"]) return Status();
    if ([cmd isEqualToString:@"list"]) return List();
    if ([cmd isEqualToString:@"check"]) {
      // Whether `start` would run now: exit 0 and "ok", or exit 1 and the reason.
      NSString *reason = UnsafeReason();
      printf("%s\n", reason ? reason.UTF8String : "ok");
      return reason ? 1 : 0;
    }
    if ([cmd isEqualToString:@"serve"]) {
      Options o;
      if (!ParseOptions(args, &o)) return 2;
      return Serve(o);
    }
    fprintf(stderr, "usage: vdisplay start [-w W] [-h H] [-r FPS] [--hidpi] | stop | status | list | check\n");
    return 2;
  }
}
