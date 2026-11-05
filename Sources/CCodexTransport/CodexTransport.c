#include "CCodexTransport.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <math.h>

struct CGPCodexSession {
    CURL *curl;
    pthread_mutex_t lock;
    bool cancelled, opened, reconnect, connection_close;
    curl_socket_t socket;
    size_t body_size, header_size;
    long latency;
    char error[CURL_ERROR_SIZE];
};

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static void initialize_curl(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

static curl_socket_t open_socket(void *context, curlsocktype purpose, struct curl_sockaddr *address) {
    CGPCodexSession *s = context;
    pthread_mutex_lock(&s->lock);
    curl_socket_t fd = CURL_SOCKET_BAD;
    if (!s->cancelled && !s->opened && purpose == CURLSOCKTYPE_IPCXN) {
        fd = socket(address->family, address->socktype, address->protocol);
        if (fd != CURL_SOCKET_BAD) { s->opened = true; s->socket = fd; }
    } else if (s->opened) {
        s->reconnect = true;
    }
    pthread_mutex_unlock(&s->lock);
    return fd;
}

static int close_socket(void *context, curl_socket_t fd) {
    CGPCodexSession *s = context;
    pthread_mutex_lock(&s->lock);
    if (s->socket == fd) s->socket = CURL_SOCKET_BAD;
    int result = close(fd);
    pthread_mutex_unlock(&s->lock);
    return result;
}

static int progress(void *context, curl_off_t dt, curl_off_t dn, curl_off_t ut, curl_off_t un) {
    CGPCodexSession *s = context;
    pthread_mutex_lock(&s->lock);
    bool cancelled = s->cancelled;
    pthread_mutex_unlock(&s->lock);
    return cancelled ? 1 : 0;
}

static size_t body(char *data, size_t size, size_t count, void *context) {
    CGPCodexSession *s = context;
    size_t length = size * count;
    if (length > 65536 - s->body_size) return 0;
    s->body_size += length;
    return length;
}

static size_t header(char *data, size_t size, size_t count, void *context) {
    CGPCodexSession *s = context;
    size_t length = size * count;
    if (length > 32768 - s->header_size) return 0;
    s->header_size += length;
    if (length >= 11 && strncasecmp(data, "Connection:", 11) == 0) {
        for (size_t i = 11; i + 5 <= length; i++)
            if (strncasecmp(data + i, "close", 5) == 0) s->connection_close = true;
    }
    return length;
}

CGPCodexSession *cgp_codex_create(const char *proxy, const char *target, const char *ca_file) {
    pthread_once(&curl_once, initialize_curl);
    CGPCodexSession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    pthread_mutex_init(&s->lock, NULL);
    s->socket = CURL_SOCKET_BAD;
    s->curl = curl_easy_init();
    if (!s->curl) { cgp_codex_destroy(s); return NULL; }
    CURL *c = s->curl;
#define SET(option, value) if (curl_easy_setopt(c, option, value) != CURLE_OK) { cgp_codex_destroy(s); return NULL; }
    SET(CURLOPT_URL, target);
    SET(CURLOPT_PROXY, proxy);
    SET(CURLOPT_PROXYTYPE, (long)CURLPROXY_SOCKS5_HOSTNAME);
    SET(CURLOPT_NOPROXY, "");
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_HTTPAUTH, (long)CURLAUTH_NONE);
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    SET(CURLOPT_MAXLIFETIME_CONN, 0L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_USERAGENT, "ChatGPTProxy-Probe/1.0");
    SET(CURLOPT_ERRORBUFFER, s->error);
    SET(CURLOPT_WRITEFUNCTION, body);
    SET(CURLOPT_WRITEDATA, s);
    SET(CURLOPT_HEADERFUNCTION, header);
    SET(CURLOPT_HEADERDATA, s);
    SET(CURLOPT_OPENSOCKETFUNCTION, open_socket);
    SET(CURLOPT_OPENSOCKETDATA, s);
    SET(CURLOPT_CLOSESOCKETFUNCTION, close_socket);
    SET(CURLOPT_CLOSESOCKETDATA, s);
    SET(CURLOPT_XFERINFOFUNCTION, progress);
    SET(CURLOPT_XFERINFODATA, s);
    SET(CURLOPT_NOPROGRESS, 0L);
    if (ca_file) { SET(CURLOPT_CAINFO, ca_file); }
#undef SET
    return s;
}

int cgp_codex_heartbeat(CGPCodexSession *s, long timeout_ms) {
    s->body_size = s->header_size = 0;
    s->connection_close = false;
    s->error[0] = '\0';
    curl_easy_setopt(s->curl, CURLOPT_TIMEOUT_MS, timeout_ms);
    CURLcode result = curl_easy_perform(s->curl);
    if (progress(s, 0, 0, 0, 0)) return 2;
    if (s->reconnect) { snprintf(s->error, sizeof(s->error), "底层 TCP/TLS 连接已重建"); return 1; }
    if (result != CURLE_OK) {
        if (!s->error[0]) snprintf(s->error, sizeof(s->error), "%s", curl_easy_strerror(result));
        return 1;
    }
    long status = 0;
    double seconds = 0;
    curl_easy_getinfo(s->curl, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(s->curl, CURLINFO_TOTAL_TIME, &seconds);
    s->latency = (long)fmax(1, ceil(seconds * 1000));
    if (status != 401) { snprintf(s->error, sizeof(s->error), "Codex 心跳返回 HTTP %ld（预期 401）", status); return 1; }
    if (s->connection_close) { snprintf(s->error, sizeof(s->error), "服务端关闭了长连接"); return 1; }
    return 0;
}

const char *cgp_codex_error(CGPCodexSession *s) { return s->error; }
long cgp_codex_latency_ms(CGPCodexSession *s) { return s->latency; }

void cgp_codex_cancel(CGPCodexSession *s) {
    pthread_mutex_lock(&s->lock);
    s->cancelled = true;
    if (s->socket != CURL_SOCKET_BAD) shutdown(s->socket, SHUT_RDWR);
    pthread_mutex_unlock(&s->lock);
}

void cgp_codex_destroy(CGPCodexSession *s) {
    if (!s) return;
    if (s->curl) curl_easy_cleanup(s->curl);
    pthread_mutex_destroy(&s->lock);
    free(s);
}
