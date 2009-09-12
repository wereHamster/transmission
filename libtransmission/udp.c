
#include <assert.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>

#include <event.h>


#include "transmission.h"
#include "udp.h"

/*
 * There are three important types of packets: connect, announce and scrape.
 * Each type consist of a 'request' and 'reply' packet. When the request
 * packet is sent, we wait up to 15 seconds for the reply. If the reply
 * doesn't arrive we retry (up to three times).
 * The two functions for sending and receiving request and reply packets of
 * a certain type are grouped into a task. The udp state structure contains
 * the torrent and tracker address, some additional state tracking
 * (connection/transaction IDs) and a list of tasks to execute.
 *
 * A new socket is created for each announce or scrape. UDP sockets are very
 * cheap.
 */

static void printAddr(struct addrinfo *addr)
{
	char namebuf[100];
	int error;

	error = getnameinfo(addr->ai_addr, addr->ai_addrlen, namebuf, sizeof(namebuf), NULL, 0, NI_NUMERICHOST);
	if (error)
		perror("getnameinfo");

	printf("name: %s\n", namebuf);
}

static int setupSocket(const char *url)
{
	struct addrinfo hints, *res;
	int error, sockfd;

	memset(&hints, 0, sizeof(hints));

	/* set-up hints structure */
	hints.ai_family = PF_INET;
	hints.ai_flags = AI_PASSIVE;
	hints.ai_socktype = SOCK_DGRAM;

	error = getaddrinfo(NULL, "6969", &hints, &res);
	if (error || !res) {
		printf("first getaddrinfo\n");
		perror(gai_strerror(error));
		return -1;
	}
//	printAddr(res);
	sockfd = socket(res->ai_family, res->ai_socktype, 0);
	perror("socket");
//	bind(sockfd, res->ai_addr, res->ai_addrlen);
//	perror("bind");

	hints.ai_flags = 0;

	printf("url: %s\n", url);

	error = getaddrinfo(url, "6969", &hints, &res);
	if (error || !res) {
		printf("second getaddrinfo\n");
		perror(gai_strerror(error));
		return -1;
	}
	printAddr(res);
	error = connect(sockfd, res->ai_addr, res->ai_addrlen);
	printf("connected %d\n", error);
	perror("connect");

	printf("returning socket %d\n", sockfd);

	return sockfd;
}

/*
 * Schedules current task and activates the reply/timeout handler
 */
static void schedule(struct tr_udp_state * state)
{
    struct timeval timeout;

    printf("calling send\n");
    state->task[state->curTask]->send(state);

    timeout.tv_sec = 15;
    event_add(&state->ev, &timeout);
}

/*
 * Reply/timeout callback. In case of a timeout reschedules
 * task again, otherwise advances to the next task.
 */
static void callback(int fd, short event, void * data)
{
    struct tr_udp_state * state = data;
    struct timeval timeout;

    printf("event: %04x\n", event);
    if (event == EV_TIMEOUT || state->task[state->curTask]->recv(state)) {
        if (++state->failures >= 4)
            return;
    } else {
        state->failures = 0;
        state->curTask++;

        printf("advancing task counter\n");
    }

    printf("rescheduling\n");
    if (state->curTask < state->numTasks)
        schedule(state);
}

static int connect_send(struct tr_udp_state *state)
{
    int ret;

    struct tr_udp_connect_request connect_request;
    connect_request.connection_id = state->connection_id;
    connect_request.transaction_id = state->transaction_id;

    ret = send(state->sockfd, &connect_request, sizeof(connect_request), 0);
    printf("sending request (%d)\n", ret);
    perror("send");
}

static int connect_recv(struct tr_udp_state *state)
{
    struct tr_udp_connect_reply connect_reply;
    int ret;

    ret = recv(state->sockfd, &connect_reply, sizeof(connect_reply), 0);
    if (ret != sizeof(connect_reply))
        return -1;

    if (state->transaction_id != connect_reply.transaction_id)
        return -1;

    state->connection_id = connect_reply.connection_id;

    return 0;
}

static struct tr_udp_task __task_connect = {
    connect_send, connect_recv
};


static int announce_send(struct tr_udp_state *state)
{
    int ret;
    
    struct tr_udp_announce_request announce_request;
    
    announce_request.connection_id = state->connection_id;
    announce_request.action = htonl(TR_UDP_ACTION_ANNOUNCE);
    announce_request.transaction_id = random();
    //announce_request.info_hash
    //announce_request.peer_id
    //announce_request.downloaded
    //announce_request.left
    //announce_request.uploaded
    //announce_request.event
    //announce_request.ip
    //announce_request.key
    announce_request.num_want = 10;
    announce_request.port = htons(51413);
    //announce_request.extensions
    
    ret = send(state->sockfd, &announce_request, sizeof(announce_request), 0);
    printf("sending request (%d)\n", ret);
    perror("send");
    
    return 0;
}

static int announce_recv(struct tr_udp_state *state)
{
    int ret, num, i;
    
    struct tr_udp_announce_reply *announce_reply = malloc(1024*16);
    struct tr_udp_announce_reply_rest *announce_reply_rest;

    ret = recv(state->sockfd, announce_reply, 1024*16, 0);
    num = (ret - sizeof(struct tr_udp_announce_reply)) / sizeof(struct tr_udp_announce_reply_rest);
    printf("announce reply: %d, num peers: %d\n", ret, num);

    announce_reply_rest = (struct tr_udp_announce_reply_rest *) (announce_reply + 1);

    for (i = 0; i < num; ++i) {
        struct sockaddr_in sin;
        char namebuf[100];

        sin.sin_family = AF_INET;
        sin.sin_port = announce_reply_rest[i].port;
        sin.sin_addr.s_addr = announce_reply_rest[i].ip;
        
        ret = getnameinfo((struct sockaddr *) &sin, sizeof(sin), namebuf, sizeof(namebuf), NULL, 0, NI_NUMERICHOST);
        printf("%s:%d\n", namebuf, ntohs(announce_reply_rest[i].port));
    }

    return 0;
}

static struct tr_udp_task __task_announce = {
    announce_send, announce_recv
};

void tr_udpAnnounce(const tr_tracker_info * address, int reqtype)
{
    struct tr_udp_state *state = malloc(sizeof(struct tr_udp_state) + 2 * sizeof(struct tr_udp_task));
    int ret;
    char *url = "udp://192.168.0.82";

    state->numTasks = 2;
    state->curTask = 0;

    state->task[0] = &__task_connect;
    state->task[1] = &__task_announce;

    printf("creating socket to connect with %s\n", address->announce);
    
    state->sockfd = setupSocket(url + 6);
    event_set(&state->ev, state->sockfd, EV_READ, callback, state);

#define hton64(i)   ( ((uint64_t)(htonl((i) & 0xffffffff)) << 32) | htonl(((i) >> 32) & 0xffffffff ) )

    state->connection_id = hton64(0x0000041727101980ULL);
    state->transaction_id = random();

    schedule(state);
}
