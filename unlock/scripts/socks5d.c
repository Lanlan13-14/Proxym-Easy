/*
 * unlock-socks5d — minimal SOCKS5 TCP CONNECT with RFC1929 user/pass.
 *
 * Credentials come from environment (SOCKS5_USERNAME / SOCKS5_PASSWORD) so they
 * never appear on argv. Username and password are raw octets, 1-255 bytes each
 * (UTF-8 / symbols / spaces / ':' all allowed). Outbound sockets optionally
 * bind to a concrete IPv4 (CloudflareWARP) so egress stays on WARP.
 *
 * Only TCP CONNECT is implemented. UDP ASSOCIATE is rejected.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_CRED 255
#define IO_BUF 16384
#define HANDSHAKE_TIMEOUT_SEC 30
#define CONNECT_TIMEOUT_SEC 20

static const char *g_user;
static const char *g_pass;
static size_t g_user_len;
static size_t g_pass_len;
static struct in_addr g_bind_ip;
static int g_have_bind_ip;
static int g_listen_port = 1080;
static volatile sig_atomic_t g_stop;

static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, " >> [socks5d] ERROR: ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
  exit(1);
}

static void logmsg(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, " >> [socks5d] ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
}

static void on_signal(int sig) {
  (void)sig;
  g_stop = 1;
}

static int ct_eq(const unsigned char *a, size_t alen, const unsigned char *b, size_t blen) {
  size_t i, max = alen > blen ? alen : blen;
  unsigned char diff = (unsigned char)(alen != blen);
  for (i = 0; i < max; i++) {
    unsigned char xa = i < alen ? a[i] : 0;
    unsigned char xb = i < blen ? b[i] : 0;
    diff |= (unsigned char)(xa ^ xb);
  }
  return diff == 0;
}

static int set_timeouts(int fd, int sec) {
  struct timeval tv;
  tv.tv_sec = sec;
  tv.tv_usec = 0;
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) return -1;
  if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) != 0) return -1;
  return 0;
}

static ssize_t read_full(int fd, void *buf, size_t n) {
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fd, (char *)buf + got, n - got);
    if (r == 0) return (ssize_t)got;
    if (r < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    got += (size_t)r;
  }
  return (ssize_t)got;
}

static ssize_t write_full(int fd, const void *buf, size_t n) {
  size_t sent = 0;
  while (sent < n) {
    ssize_t w = write(fd, (const char *)buf + sent, n - sent);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    sent += (size_t)w;
  }
  return (ssize_t)sent;
}

static int bind_outbound(int fd) {
  if (!g_have_bind_ip) return 0;
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_addr = g_bind_ip;
  sa.sin_port = 0;
  if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
    logmsg("bind outbound to %s failed: %s", inet_ntoa(g_bind_ip), strerror(errno));
    return -1;
  }
  return 0;
}

static int connect_host(const char *host, uint16_t port, int *out_fd) {
  char portstr[16];
  snprintf(portstr, sizeof(portstr), "%u", (unsigned)port);

  struct addrinfo hints, *res = NULL, *rp;
  memset(&hints, 0, sizeof(hints));
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  int gai = getaddrinfo(host, portstr, &hints, &res);
  if (gai != 0) {
    logmsg("resolve %s failed: %s", host, gai_strerror(gai));
    return 4; /* host unreachable-ish */
  }

  int last_err = 1;
  for (rp = res; rp; rp = rp->ai_next) {
    int fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0) continue;
    if (rp->ai_family == AF_INET && bind_outbound(fd) != 0) {
      close(fd);
      continue;
    }
    set_timeouts(fd, CONNECT_TIMEOUT_SEC);
    if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) {
      int one = 1;
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      *out_fd = fd;
      freeaddrinfo(res);
      return 0;
    }
    last_err = 5; /* connection refused */
    close(fd);
  }
  freeaddrinfo(res);
  return last_err;
}

static int connect_ipv4(const struct in_addr *ip, uint16_t port, int *out_fd) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 1;
  if (bind_outbound(fd) != 0) {
    close(fd);
    return 1;
  }
  set_timeouts(fd, CONNECT_TIMEOUT_SEC);
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_addr = *ip;
  sa.sin_port = htons(port);
  if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
    close(fd);
    return 5;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  *out_fd = fd;
  return 0;
}

static int connect_ipv6(const struct in6_addr *ip, uint16_t port, int *out_fd) {
  /* Do not force IPv4 WARP bind on IPv6 sockets; most WARP deployments here are IPv4. */
  int fd = socket(AF_INET6, SOCK_STREAM, 0);
  if (fd < 0) return 1;
  set_timeouts(fd, CONNECT_TIMEOUT_SEC);
  struct sockaddr_in6 sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin6_family = AF_INET6;
  sa.sin6_addr = *ip;
  sa.sin6_port = htons(port);
  if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
    close(fd);
    return 5;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  *out_fd = fd;
  return 0;
}

static void relay(int a, int b) {
  char buf[IO_BUF];
  set_timeouts(a, 0);
  set_timeouts(b, 0);
  for (;;) {
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(a, &rfds);
    FD_SET(b, &rfds);
    int maxfd = a > b ? a : b;
    int n = select(maxfd + 1, &rfds, NULL, NULL, NULL);
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (FD_ISSET(a, &rfds)) {
      ssize_t r = read(a, buf, sizeof(buf));
      if (r <= 0) break;
      if (write_full(b, buf, (size_t)r) < 0) break;
    }
    if (FD_ISSET(b, &rfds)) {
      ssize_t r = read(b, buf, sizeof(buf));
      if (r <= 0) break;
      if (write_full(a, buf, (size_t)r) < 0) break;
    }
  }
}

static void send_reply(int fd, uint8_t rep) {
  unsigned char reply[10] = {0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
  (void)write_full(fd, reply, sizeof(reply));
}

static void handle_client(int cfd) {
  unsigned char buf[512];
  set_timeouts(cfd, HANDSHAKE_TIMEOUT_SEC);

  /* greeting: VER NMETHODS METHODS */
  if (read_full(cfd, buf, 2) != 2 || buf[0] != 0x05) return;
  unsigned nmethods = buf[1];
  if (nmethods == 0 || nmethods > 255) return;
  if (read_full(cfd, buf, nmethods) != (ssize_t)nmethods) return;

  int has_userpass = 0;
  for (unsigned i = 0; i < nmethods; i++) {
    if (buf[i] == 0x02) has_userpass = 1;
  }
  if (!has_userpass) {
    unsigned char resp[2] = {0x05, 0xFF};
    (void)write_full(cfd, resp, 2);
    return;
  }
  {
    unsigned char resp[2] = {0x05, 0x02};
    if (write_full(cfd, resp, 2) < 0) return;
  }

  /* RFC1929: VER ULEN UNAME PLEN PASSWD */
  if (read_full(cfd, buf, 2) != 2 || buf[0] != 0x01) return;
  unsigned ulen = buf[1];
  if (ulen == 0 || ulen > MAX_CRED) {
    unsigned char resp[2] = {0x01, 0x01};
    (void)write_full(cfd, resp, 2);
    return;
  }
  if (read_full(cfd, buf, ulen) != (ssize_t)ulen) return;
  unsigned char uname[MAX_CRED];
  memcpy(uname, buf, ulen);

  if (read_full(cfd, buf, 1) != 1) return;
  unsigned plen = buf[0];
  if (plen == 0 || plen > MAX_CRED) {
    unsigned char resp[2] = {0x01, 0x01};
    (void)write_full(cfd, resp, 2);
    return;
  }
  if (read_full(cfd, buf, plen) != (ssize_t)plen) return;
  unsigned char passwd[MAX_CRED];
  memcpy(passwd, buf, plen);

  int ok = ct_eq(uname, ulen, (const unsigned char *)g_user, g_user_len) &&
           ct_eq(passwd, plen, (const unsigned char *)g_pass, g_pass_len);
  {
    unsigned char resp[2] = {0x01, ok ? 0x00 : 0x01};
    if (write_full(cfd, resp, 2) < 0) return;
  }
  if (!ok) return;

  /* request: VER CMD RSV ATYP ... */
  if (read_full(cfd, buf, 4) != 4 || buf[0] != 0x05) return;
  uint8_t cmd = buf[1];
  uint8_t atyp = buf[3];
  if (cmd != 0x01) {
    /* only CONNECT */
    send_reply(cfd, 0x07);
    return;
  }

  char host[256];
  uint16_t port = 0;
  int remote = -1;
  int rep = 0;

  if (atyp == 0x01) {
    struct in_addr ip;
    if (read_full(cfd, &ip, 4) != 4) return;
    if (read_full(cfd, buf, 2) != 2) return;
    port = (uint16_t)((buf[0] << 8) | buf[1]);
    rep = connect_ipv4(&ip, port, &remote);
  } else if (atyp == 0x03) {
    if (read_full(cfd, buf, 1) != 1) return;
    unsigned hlen = buf[0];
    if (hlen == 0 || hlen > 255) {
      send_reply(cfd, 0x01);
      return;
    }
    if (read_full(cfd, host, hlen) != (ssize_t)hlen) return;
    host[hlen] = '\0';
    if (read_full(cfd, buf, 2) != 2) return;
    port = (uint16_t)((buf[0] << 8) | buf[1]);
    rep = connect_host(host, port, &remote);
  } else if (atyp == 0x04) {
    struct in6_addr ip6;
    if (read_full(cfd, &ip6, 16) != 16) return;
    if (read_full(cfd, buf, 2) != 2) return;
    port = (uint16_t)((buf[0] << 8) | buf[1]);
    rep = connect_ipv6(&ip6, port, &remote);
  } else {
    send_reply(cfd, 0x08);
    return;
  }

  if (rep != 0 || remote < 0) {
    send_reply(cfd, (uint8_t)(rep ? rep : 1));
    if (remote >= 0) close(remote);
    return;
  }

  send_reply(cfd, 0x00);
  relay(cfd, remote);
  close(remote);
}

static void usage(const char *argv0) {
  fprintf(stderr,
          "usage: %s --port <1-65535> [--bind-ip <IPv4>]\n"
          "  Credentials: env SOCKS5_USERNAME and SOCKS5_PASSWORD (1-255 bytes each).\n",
          argv0);
}

int main(int argc, char **argv) {
  const char *bind_ip = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
      g_listen_port = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--bind-ip") == 0 && i + 1 < argc) {
      bind_ip = argv[++i];
    } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      usage(argv[0]);
      return 0;
    } else {
      usage(argv[0]);
      return 2;
    }
  }

  if (g_listen_port < 1 || g_listen_port > 65535) die("invalid --port");

  g_user = getenv("SOCKS5_USERNAME");
  g_pass = getenv("SOCKS5_PASSWORD");
  if (!g_user || !g_pass) die("SOCKS5_USERNAME and SOCKS5_PASSWORD env required");
  g_user_len = strlen(g_user);
  g_pass_len = strlen(g_pass);
  if (g_user_len < 1 || g_user_len > MAX_CRED) die("SOCKS5_USERNAME must be 1-255 bytes");
  if (g_pass_len < 1 || g_pass_len > MAX_CRED) die("SOCKS5_PASSWORD must be 1-255 bytes");
  /* getenv/strlen cannot carry embedded NUL; RFC1929 lengths come from strlen. */

  if (bind_ip && bind_ip[0]) {
    if (inet_pton(AF_INET, bind_ip, &g_bind_ip) != 1) die("invalid --bind-ip %s", bind_ip);
    g_have_bind_ip = 1;
  }

  signal(SIGCHLD, SIG_IGN);
  signal(SIGPIPE, SIG_IGN);
  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);

  int lfd = socket(AF_INET, SOCK_STREAM, 0);
  if (lfd < 0) die("socket: %s", strerror(errno));
  int one = 1;
  setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = htons((uint16_t)g_listen_port);
  if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) != 0) die("bind :%d: %s", g_listen_port, strerror(errno));
  if (listen(lfd, 128) != 0) die("listen: %s", strerror(errno));

  if (g_have_bind_ip)
    logmsg("listening TCP %d; outbound bind %s; RFC1929 auth", g_listen_port, bind_ip);
  else
    logmsg("listening TCP %d; RFC1929 auth (no outbound bind)", g_listen_port);

  while (!g_stop) {
    struct sockaddr_in peer;
    socklen_t plen = sizeof(peer);
    int cfd = accept(lfd, (struct sockaddr *)&peer, &plen);
    if (cfd < 0) {
      if (errno == EINTR) continue;
      if (g_stop) break;
      logmsg("accept: %s", strerror(errno));
      continue;
    }
    pid_t pid = fork();
    if (pid == 0) {
      close(lfd);
      handle_client(cfd);
      close(cfd);
      _exit(0);
    }
    close(cfd);
    if (pid < 0) logmsg("fork: %s", strerror(errno));
  }

  close(lfd);
  logmsg("stopped");
  return 0;
}
