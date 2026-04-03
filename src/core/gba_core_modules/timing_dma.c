#if defined(__cplusplus)
// Imported from reference implementation: gbaLink.cpp
/* BEGIN gbaLink.cpp */

#ifdef _MSC_VER
#if __STDC_WANT_SECURE_LIB__
#define snprintf sprintf_s
#else
#define snprintf _snprintf
#endif
#endif

#ifdef UPDATE_REG
#undef UPDATE_REG
#endif
#define UPDATE_REG(address, value) WRITE16LE(((uint16_t*)&g_ioMem[address]), value)

static int vbaid = 0;
const char* MakeInstanceFilename(const char* Input)
{
    if (vbaid == 0) {
        return Input;
    }

    static char* result = NULL;
    if (result != NULL) {
        free(result);
    }

    result = (char*)malloc(strlen(Input) + 4);
    char* p = strrchr((char*)Input, '.');
    snprintf(result, strlen(Input) + 3, "%.*s-%d.%s", (int)(p - Input), Input, vbaid + 1, p + 1);
    return result;
}

enum {
    SENDING = 0,
    RECEIVING = 1
};

enum siocnt_lo_32bit {
    SIO_INT_CLOCK = 0x0001,
    SIO_INT_CLOCK_SEL_2MHZ = 0x0002,
    SIO_TRANS_FLAG_RECV_ENABLE = 0x0004,
    SIO_TRANS_FLAG_SEND_DISABLE = 0x0008,
    SIO_TRANS_START = 0x0080,
    SIO_TRANS_32BIT = 0x1000,
    SIO_IRQ_ENABLE = 0x4000
};

// If disabled, gba core won't call any (non-joybus) link functions
bool gba_link_enabled = false;

bool speedhack = true;

#define LOCAL_LINK_NAME "VBA link memory"

#include <stdint.h>

uint16_t IP_LINK_PORT = 5738;

std::string IP_LINK_BIND_ADDRESS = "*";

#if !defined(_WIN32)

#define ReleaseSemaphore(sem, nrel, orel) \
    do {                                  \
        for (int i = 0; i < nrel; i++)    \
            sem_post(sem);                \
    } while (0)
#define WAIT_TIMEOUT -1

#ifdef HAVE_SEM_TIMEDWAIT

int WaitForSingleObject(sem_t* s, int t)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += t / 1000;
    ts.tv_nsec += (t % 1000) * 1000000;
    do {
        if (!sem_timedwait(s, &ts))
            return 0;
    } while (errno == EINTR);
    return WAIT_TIMEOUT;
}

// urg.. MacOSX has no sem_timedwait (POSIX) or semtimedop (SYSV)
// so we'll have to simulate it..
// MacOSX also has no clock_gettime, and since both are "real-time", assume
// anyone who doesn't have one also doesn't have the other

// 2 ways to do this:
//   - poll & sleep loop
//   - poll & wait for timer interrupt loop

// the first consumes more CPU and requires selection of a good sleep value

// the second may interfere with other timers running on system, and
// requires that a dummy signal handler be installed for SIGALRM
#else
#include <sys/time.h>
#ifndef TIMEDWAIT_ALRM
#define TIMEDWAIT_ALRM 1
#endif
#if TIMEDWAIT_ALRM
#include <signal.h>
static void alrmhand(int sig)
{
    (void)sig;
}
#endif
int WaitForSingleObject(sem_t* s, int t)
{
#if !TIMEDWAIT_ALRM
    struct timeval ts;
    gettimeofday(&ts, NULL);
    ts.tv_sec += t / 1000;
    ts.tv_usec += (t % 1000) * 1000;
#else
    struct sigaction sa, osa;
    sigaction(SIGALRM, NULL, &osa);
    sa = osa;
    sa.sa_flags &= ~SA_RESTART;
    sa.sa_handler = alrmhand;
    sigaction(SIGALRM, &sa, NULL);
    struct itimerval tv, otv;
    tv.it_value.tv_sec = t / 1000;
    tv.it_value.tv_usec = (t % 1000) * 1000;
    // this should be 0/0, but in the wait loop, it's possible to
    // have the signal fire while not in sem_wait().  This will ensure
    // another signal within 1ms
    tv.it_interval.tv_sec = 0;
    tv.it_interval.tv_usec = 999;
    setitimer(ITIMER_REAL, &tv, &otv);
#endif
    while (1) {
#if !TIMEDWAIT_ALRM
        if (!sem_trywait(s))
            return 0;
        struct timeval ts2;
        gettimeofday(&ts2, NULL);
        if (ts2.tv_sec > ts.tv_sec || (ts2.tv_sec == ts.tv_sec && ts2.tv_usec > ts.tv_usec)) {
            return WAIT_TIMEOUT;
        }
        // is .1 ms short enough?  long enough?  who knows?
        struct timespec ts3;
        ts3.tv_sec = 0;
        ts3.tv_nsec = 100000;
        nanosleep(&ts3, NULL);
#else
        if (!sem_wait(s)) {
            setitimer(ITIMER_REAL, &otv, NULL);
            sigaction(SIGALRM, &osa, NULL);
            return 0;
        }
        getitimer(ITIMER_REAL, &tv);
        if (tv.it_value.tv_sec || tv.it_value.tv_usec > 999)
            continue;
        setitimer(ITIMER_REAL, &otv, NULL);
        sigaction(SIGALRM, &osa, NULL);
        break;
#endif
    }
    return WAIT_TIMEOUT;
}
#endif
#endif

#define UNSUPPORTED -1
#define MULTIPLAYER 0
#define NORMAL8 1
#define NORMAL32 2
#define UART 3
#define JOYBUS 4
#define GP 5

static int GetSIOMode(uint16_t, uint16_t);
static ConnectionState InitSocket();
static void StartCableSocket(uint16_t siocnt);
static ConnectionState ConnectUpdateSocket(char* const message, size_t size);
static void UpdateCableSocket(int ticks);
static void CloseSocket();

const uint64_t TICKS_PER_FRAME = TICKS_PER_SECOND / 60;
const uint64_t BITS_PER_SECOND = 115200;
const uint64_t BYTES_PER_SECOND = BITS_PER_SECOND / 8;

static uint32_t lastjoybusupdate = 0;
static uint32_t nextjoybusupdate = 0;
static uint32_t lastcommand = 0;
static bool booted = false;

static ConnectionState JoyBusConnect();
static void JoyBusUpdate(int ticks);
static void JoyBusShutdown();

static ConnectionState ConnectUpdateRFUSocket(char* const message, size_t size);
static void StartRFUSocket(uint16_t siocnt);
bool LinkRFUUpdateSocket();
static void UpdateRFUSocket(int ticks);

#define RFU_INIT 0
#define RFU_COMM 1
#define RFU_SEND 2
#define RFU_RECV 3

typedef struct {
    uint16_t linkdata[5];
    uint16_t linkcmd[4];
    uint16_t numtransfers;
    int32_t lastlinktime;
    uint8_t numgbas; //# of GBAs (max vbaid value plus 1), used in Single computer
    uint8_t trgbas;
    uint8_t linkflags;

    uint8_t rfu_proto[5]; // 0=UDP-like, 1=TCP-like protocols to see whether the data important or not (may or may not be received successfully by the other side)
    uint16_t rfu_qid[5];
    int32_t rfu_q[5];
    uint32_t rfu_signal[5];
    uint8_t rfu_is_host[5]; //request to join
    //uint8_t rfu_joined[5]; //bool //currenlty joined
    uint16_t rfu_reqid[5]; //id to join
    uint16_t rfu_clientidx[5]; //only used by clients
    int32_t rfu_linktime[5];
    uint32_t rfu_broadcastdata[5][7]; //for 0x16/0x1d/0x1e?
    uint32_t rfu_gdata[5]; //for 0x17/0x19?/0x1e?
    int32_t rfu_state[5]; //0=none, 1=waiting for ACK
    uint8_t rfu_listfront[5];
    uint8_t rfu_listback[5];
    rfu_datarec rfu_datalist[5][256];

    /*uint16_t rfu_qidlist[5][256];
	uint16_t rfu_qlist[5][256];
	uint32_t rfu_datalist[5][256][255];
	uint32_t rfu_timelist[5][256];*/
} LINKDATA;

class RFUServer {
    [[maybe_unused]] int numbytes;
    sf::SocketSelector fdset;
    [[maybe_unused]] int counter;
    [[maybe_unused]] int done;
    uint8_t current_host;

public:
    sf::TcpSocket tcpsocket[5];
    sf::IpAddress udpaddr[5] = { sf::IpAddress{0}, sf::IpAddress{0}, sf::IpAddress{0}, sf::IpAddress{0}, sf::IpAddress{0} };
    RFUServer(void);
    sf::Packet& Serialize(sf::Packet& packet, int slave);
    void DeSerialize(sf::Packet& packet, int slave);
    void Send(void);
    void Recv(void);
};

class RFUClient {
    sf::SocketSelector fdset;
    int numbytes;

public:
    sf::IpAddress serveraddr{0};
    unsigned short serverport;
    bool transferring;
    RFUClient(void);
    void Send(void);
    void Recv(void);
    sf::Packet& Serialize(sf::Packet& packet);
    void DeSerialize(sf::Packet& packet);
    void CheckConn(void);
};

// RFU crap (except for numtransfers note...should probably check that out)
[[maybe_unused]] static LINKDATA* linkmem = NULL;
static LINKDATA rfu_data;
static uint8_t rfu_cmd, rfu_qsend, rfu_qrecv_broadcast_data_len;
static int rfu_state, rfu_polarity, rfu_counter, rfu_masterq;
// numtransfers seems to be used interchangeably with linkmem->numtransfers
// in rfu code; probably a bug?
static int rfu_transfer_end;
// in local comm, setting this keeps slaves from trying to communicate even
// when master isn't
static uint16_t numtransfers = 0;

// time until next broadcast
static int rfu_last_broadcast_time;

static uint32_t rfu_masterdata[255];
bool rfu_enabled = false;
bool rfu_initialized = false;
bool rfu_waiting = false;
uint8_t rfu_qsend2, rfu_cmd2, rfu_lastcmd, rfu_lastcmd2;
uint16_t rfu_id, rfu_idx;
static int gbaid = 0;
static int gbaidx = 0;
bool rfu_ishost, rfu_cansend;
int rfu_lasttime;
uint32_t rfu_buf;
uint16_t PrevVAL = 0;
uint32_t PrevCOM = 0, PrevDAT = 0;
uint8_t rfu_numclients = 0;
uint8_t rfu_curclient = 0;
uint32_t rfu_clientlist[5];

static RFUServer rfu_server;
static RFUClient rfu_client;

uint8_t gbSIO_SC = 0;
bool EmuReseted = true;
bool LinkIsWaiting = false;
bool LinkFirstTime = true;

#if (defined _WIN32)

static ConnectionState InitIPC();
static void StartCableIPC(uint16_t siocnt);
static void ReconnectCableIPC();
static void UpdateCableIPC(int ticks);
static void StartRFU(uint16_t siocnt);
static void UpdateRFUIPC(int ticks);
static void CloseIPC();

#endif

struct LinkDriver {
    typedef ConnectionState(ConnectFunc)();
    typedef ConnectionState(ConnectUpdateFunc)(char* const message, size_t size);
    typedef void(StartFunc)(uint16_t siocnt);
    typedef void(UpdateFunc)(int ticks);
    typedef void(CloseFunc)();

    LinkMode mode;
    ConnectFunc* connect;
    ConnectUpdateFunc* connectUpdate;
    StartFunc* start;
    UpdateFunc* update;
    CloseFunc* close;
    bool uses_socket;
};

static const LinkDriver* linkDriver = NULL;
static ConnectionState gba_connection_state = LINK_OK;

static int linktime = 0;

static GBASockClient* dol = NULL;
static sf::IpAddress joybusHostAddr = sf::IpAddress::LocalHost;

static const LinkDriver linkDrivers[] = {
#if (defined __WIN32__ || defined _WIN32)
    { LINK_CABLE_IPC, InitIPC, NULL, StartCableIPC, UpdateCableIPC, CloseIPC, false },
    { LINK_RFU_IPC, InitIPC, NULL, StartRFU, UpdateRFUIPC, CloseIPC, false },
    { LINK_GAMEBOY_IPC, InitIPC, NULL, NULL, NULL, CloseIPC, false },
#endif
    { LINK_CABLE_SOCKET, InitSocket, ConnectUpdateSocket, StartCableSocket, UpdateCableSocket, CloseSocket, true },
    { LINK_RFU_SOCKET, InitSocket, ConnectUpdateRFUSocket, StartRFUSocket, UpdateRFUSocket, CloseSocket, true },
    { LINK_GAMECUBE_DOLPHIN, JoyBusConnect, NULL, NULL, JoyBusUpdate, JoyBusShutdown, false },
    { LINK_GAMEBOY_SOCKET, InitSocket, ConnectUpdateSocket, NULL, NULL, CloseSocket, true },
};

enum {
    JOY_CMD_RESET = 0xff,
    JOY_CMD_STATUS = 0x00,
    JOY_CMD_READ = 0x14,
    JOY_CMD_WRITE = 0x15
};

typedef struct {
    sf::TcpSocket tcpsocket;
    sf::TcpListener tcplistener;
    uint16_t numslaves;
    int connectedSlaves;
    int type;
    bool server;
    bool speed; //speedhack
} LANLINKDATA;

class CableServer {
    sf::SocketSelector fdset;
    //timeval udptimeout;
    char inbuffer[256], outbuffer[256];
    int32_t* intinbuffer;
    uint16_t* uint16_tinbuffer;
    int32_t* intoutbuffer;
    uint16_t* uint16_toutbuffer;
    int counter;
    [[maybe_unused]] int done;

public:
    sf::TcpSocket tcpsocket[4];
    sf::IpAddress udpaddr[4] = { sf::IpAddress{0}, sf::IpAddress{0}, sf::IpAddress{0}, sf::IpAddress{0} };
    CableServer(void);
    void Send(void);
    void Recv(void);
    void SendGB(void);
    bool RecvGB(void);
};

class CableClient {
    sf::SocketSelector fdset;
    char inbuffer[256], outbuffer[256];
    int32_t* intinbuffer;
    uint16_t* uint16_tinbuffer;
    int32_t* intoutbuffer;
    uint16_t* uint16_toutbuffer;
    int numbytes;

public:
    sf::IpAddress serveraddr{0};
    unsigned short serverport;
    bool transferring;
    CableClient(void);
    void Send(void);
    void Recv(void);
    void SendGB(void);
    bool RecvGB(void);
    void CheckConn(void);
};

static int linktimeout = 1;
static LANLINKDATA lanlink;
static uint16_t cable_data[4];
// Add extra byte to suppress warning.
static uint8_t cable_gb_data[5];
static CableServer ls;
static CableClient lc;

// time to end of single GBA's transfer, in 16.78 MHz clock ticks
// first index is GBA #
[[maybe_unused]] static const int trtimedata[4][4] = {
    // 9600 38400 57600 115200
    { 34080, 8520, 5680, 2840 },
    { 65536, 16384, 10923, 5461 },
    { 99609, 24903, 16602, 8301 },
    { 133692, 33423, 22282, 11141 }
};

// time to end of transfer
// for 3 slaves, this is time to transfer machine 4
// for < 3 slaves, this is time to transfer last machine + time to detect lack
// of start bit from next slave
// first index is (# of slaves) - 1
static const int trtimeend[3][4] = {
    // 9600 38400 57600 115200
    { 72527, 18132, 12088, 6044 },
    { 106608, 26652, 17768, 8884 },
    { 133692, 33423, 22282, 11141 }
};

// Hodgepodge
static uint8_t tspeed = 3;
static int transfer_direction = 0;
static uint16_t linkid = 0;
#if (defined __WIN32__ || defined _WIN32)
static HANDLE linksync[4];
#else
[[maybe_unused]] static sem_t* linksync[4];
#endif
static int transfer_start_time_from_master = 0;
#if (defined __WIN32__ || defined _WIN32)
static HANDLE mmf = NULL;
#else
[[maybe_unused]] static int mmf = -1;
#endif
static char linkevent[] =
#if !(defined __WIN32__ || defined _WIN32)
    "/"
#endif
    "VBA link event  ";

inline static int GetSIOMode(uint16_t siocnt, uint16_t rcnt)
{
    if (!(rcnt & 0x8000)) {
        switch (siocnt & 0x3000) {
        case 0x0000:
            return NORMAL8;
        case 0x1000:
            return NORMAL32;
        case 0x2000:
            return MULTIPLAYER;
        case 0x3000:
            return UART;
        }
    }

    if (rcnt & 0x4000)
        return JOYBUS;

    return GP;
}

LinkMode GetLinkMode()
{
    if (linkDriver && gba_connection_state == LINK_OK)
        return linkDriver->mode;
    else
        return LINK_DISCONNECTED;
}

bool GetLinkServerHost(char* const host, size_t size)
{
    if (host == NULL || size == 0) {
        return false;
    }

    host[0] = '\0';

    if (linkDriver && linkDriver->mode == LINK_GAMECUBE_DOLPHIN) {
#if __STDC_WANT_SECURE_LIB__
        strncpy_s(host, size, joybusHostAddr.toString().c_str(), size);
#else
        strncpy(host, joybusHostAddr.toString().c_str(), size);
#endif
    } else if (lanlink.server) {
        if (IP_LINK_BIND_ADDRESS == "*") {
            auto local_addr = sf::IpAddress::getLocalAddress();
            if (local_addr) {
#if __STDC_WANT_SECURE_LIB__
                strncpy_s(host, size, local_addr.value().toString().c_str(), size);
#else
                strncpy(host, local_addr.value().toString().c_str(), size);
#endif
            } else {
                return false;
            }
        } else {
#if __STDC_WANT_SECURE_LIB__
            strncpy_s(host, size, IP_LINK_BIND_ADDRESS.c_str(), size);
#else
            strncpy(host, IP_LINK_BIND_ADDRESS.c_str(), size);
#endif
        }
    }
    else {
#if __STDC_WANT_SECURE_LIB__
        strncpy_s(host, size, lc.serveraddr.toString().c_str(), size);
#else
        strncpy(host, lc.serveraddr.toString().c_str(), size);
#endif
    }

    return true;
}

bool SetLinkServerHost(const char* host)
{
    sf::IpAddress addr{0};

    auto resolved = sf::IpAddress::resolve(host);
    if (!resolved) {
        return false;
    }
    addr = resolved.value();
    lc.serveraddr = addr;
    joybusHostAddr = addr;

    return true;
}

int GetLinkPlayerId()
{
    if (GetLinkMode() == LINK_DISCONNECTED) {
        return -1;
    } else if (linkid > 0) {
        return linkid;
    } else {
        return vbaid;
    }
}

void SetLinkTimeout(int value)
{
    linktimeout = value;
}

void EnableLinkServer(bool enable, int numSlaves)
{
    lanlink.server = enable;
    lanlink.numslaves = (uint16_t)numSlaves;
}

void EnableSpeedHacks(bool enable)
{
    lanlink.speed = enable;
}

void BootLink(int m_type, const char* hostAddr, int timeout, bool m_hacks, int m_numplayers)
{
    (void)m_numplayers; // unused param
    if (linkDriver) {
        // Connection has already been established
        return;
    }

    LinkMode mode = (LinkMode)m_type;

    if (mode == LINK_DISCONNECTED || mode == LINK_CABLE_SOCKET || mode == LINK_RFU_SOCKET || mode == LINK_GAMEBOY_SOCKET) {
        return;
    }

    // Close any previous link
    CloseLink();

    bool needsServerHost = (mode == LINK_GAMECUBE_DOLPHIN);

    if (needsServerHost) {
        bool valid = SetLinkServerHost(hostAddr);
        if (!valid) {
            return;
        }
    }

    SetLinkTimeout(timeout);
    EnableSpeedHacks(m_hacks);

    // Init link
    ConnectionState state = InitLink(mode);

    if (!linkDriver->uses_socket) {
        // The user canceled the connection attempt
        if (state == LINK_ABORT) {
            CloseLink();
            return;
        }

        // Something failed during init
        if (state == LINK_ERROR) {
            return;
        }
    } else {
        CloseLink();
        return;
    }
}

//////////////////////////////////////////////////////////////////////////
// Probably from here down needs to be replaced with SFML goodness :)
// tjm: what SFML goodness?  SFML for network, yes, but not for IPC

ConnectionState InitLink(LinkMode mode)
{
    if (mode == LINK_DISCONNECTED)
        return LINK_ABORT;

    // Do nothing if we are already connected
    if (GetLinkMode() != LINK_DISCONNECTED) {
        systemMessage(0, N_("Error, link already connected"));
        return LINK_ERROR;
    }

    // Find the link driver
    linkDriver = NULL;
    for (uint8_t i = 0; i < sizeof(linkDrivers) / sizeof(linkDrivers[0]); i++) {
        if (linkDrivers[i].mode == mode) {
            linkDriver = &linkDrivers[i];
            break;
        }
    }

    if (!linkDriver || !linkDriver->connect) {
        systemMessage(0, N_("Unable to find link driver"));
        return LINK_ERROR;
    }

    // Connect the link
    gba_connection_state = linkDriver->connect();

    if (gba_connection_state == LINK_ERROR) {
        CloseLink();
    }

    return gba_connection_state;
}

void StartLink(uint16_t siocnt)
{
    if (!linkDriver || !linkDriver->start) {
        // We still need to update the SIOCNT register for consistency. Some
        // games (e.g. Digimon Racing EUR) will be stuck in an infinite loop
        // waiting git the SIOCNT register to be updated otherwise.
        // This mimicks the NO_LINK behavior.
        if (siocnt & 0x80) {
            siocnt &= 0xff7f;
            if (siocnt & 1 && (siocnt & 0x4000)) {
                UPDATE_REG(COMM_SIOCNT, 0xFF);
                IF |= 0x80;
                UPDATE_REG(IO_REG_IF, IF);
                siocnt &= 0x7f7f;
            }
        }
        UPDATE_REG(COMM_SIOCNT, siocnt);
        return;
    }

    linkDriver->start(siocnt);
}

ConnectionState ConnectLinkUpdate(char* const message, size_t size)
{
    message[0] = '\0';

    if (!linkDriver || !linkDriver->connectUpdate || gba_connection_state != LINK_NEEDS_UPDATE) {
        gba_connection_state = LINK_ERROR;
        snprintf(message, size, N_("Link connection does not need updates."));

        return LINK_ERROR;
    }

    gba_connection_state = linkDriver->connectUpdate(message, size);

    return gba_connection_state;
}

void StartGPLink(uint16_t value)
{
    UPDATE_REG(COMM_RCNT, value);

    if (!value)
        return;

    switch (GetSIOMode(READ16LE(&g_ioMem[COMM_SIOCNT]), value)) {
    case MULTIPLAYER:
        value &= 0xc0f0;
        value |= 3;
        if (linkid)
            value |= 4;
        UPDATE_REG(COMM_SIOCNT, ((READ16LE(&g_ioMem[COMM_SIOCNT]) & 0xff8b) | (linkid ? 0xcu : 8u) | (linkid << 4u)));
        break;

    case GP:
#if (defined __WIN32__ || defined _WIN32)
        if (GetLinkMode() == LINK_RFU_IPC)
            rfu_state = RFU_INIT;
#endif
        break;
    }
}

void LinkUpdate(int ticks)
{
    if (!linkDriver || !linkDriver->update) {
        return;
    }

    // this actually gets called every single instruction, so keep default
    // path as short as possible

    linktime += ticks;

    linkDriver->update(ticks);
}

void CheckLinkConnection()
{
    if (GetLinkMode() == LINK_CABLE_SOCKET) {
        if (linkid && !lc.transferring) {
            lc.CheckConn();
        }
    }
}

void CloseLink(void)
{
    if (!linkDriver || !linkDriver->close) {
        return; // Nothing to do
    }

    linkDriver->close();
    linkDriver = NULL;

    return;
}

// Server
CableServer::CableServer(void)
{
    intinbuffer = (int32_t*)inbuffer;
    uint16_tinbuffer = (uint16_t*)inbuffer;
    intoutbuffer = (int32_t*)outbuffer;
    uint16_toutbuffer = (uint16_t*)outbuffer;
}

void CableServer::Send(void)
{
    if (lanlink.type == 0) { // TCP
        outbuffer[1] = tspeed;
        WRITE16LE(&uint16_toutbuffer[1], cable_data[0]);
        WRITE32LE(&intoutbuffer[1], transfer_start_time_from_master);

        if (lanlink.numslaves == 1) {
            if (lanlink.type == 0) {
                outbuffer[0] = 8;
                (void)tcpsocket[1].send(outbuffer, 8);
            }
        } else if (lanlink.numslaves == 2) {
            WRITE16LE(&uint16_toutbuffer[4], cable_data[2]);
            if (lanlink.type == 0) {
                outbuffer[0] = 10;
                (void)tcpsocket[1].send(outbuffer, 10);
                WRITE16LE(&uint16_toutbuffer[4], cable_data[1]);
                (void)tcpsocket[2].send(outbuffer, 10);
            }
        } else {
            if (lanlink.type == 0) {
                outbuffer[0] = 12;
                WRITE16LE(&uint16_toutbuffer[4], cable_data[2]);
                WRITE16LE(&uint16_toutbuffer[5], cable_data[3]);
                (void)tcpsocket[1].send(outbuffer, 12);
                WRITE16LE(&uint16_toutbuffer[4], cable_data[1]);
                (void)tcpsocket[2].send(outbuffer, 12);
                WRITE16LE(&uint16_toutbuffer[5], cable_data[2]);
                (void)tcpsocket[3].send(outbuffer, 12);
            }
        }
    }
    return;
}

// Receive data from all slaves to master
void CableServer::Recv(void)
{
    int numbytes;
    if (lanlink.type == 0) { // TCP
        fdset.clear();

        for (int i = 0; i < lanlink.numslaves; i++)
            fdset.add(tcpsocket[i + 1]);

        if (fdset.wait(sf::milliseconds(50)) == 0) {
            return;
        }

        for (int i = 0; i < lanlink.numslaves; i++) {
            numbytes = 0;
            inbuffer[0] = 1;
            while (numbytes < inbuffer[0]) {
                size_t nr;
                (void)tcpsocket[i + 1].receive(inbuffer + numbytes, inbuffer[0] - numbytes, nr);
                numbytes += (int)nr;
            }
            if (inbuffer[1] == -32) {
                char message[30];
                snprintf(message, sizeof(message), _("Player %d disconnected."), i + 2);
                systemScreenMessage(message);
                outbuffer[0] = 4;
                outbuffer[1] = -32;
                for (i = 1; i < lanlink.numslaves; i++) {
                    (void)tcpsocket[i].send(outbuffer, 12);
                    size_t nr;
                    (void)tcpsocket[i].receive(inbuffer, 256, nr);
                    tcpsocket[i].disconnect();
                }
                CloseLink();
                return;
            }
            cable_data[i + 1] = READ16LE(&uint16_tinbuffer[1]);
        }
    }
    return;
}

void CableServer::SendGB(void)
{
    if (counter == 0)
        return;

    if (lanlink.type == 0) { // TCP
        if (lanlink.numslaves == 1) {
            if (lanlink.type == 0) {
                (void)tcpsocket[1].send(&cable_gb_data[0], 1);
            }
        }
    }
    counter = 0;
}

// Receive data from all slaves to master
bool CableServer::RecvGB(void)
{
    if (counter == 1)
        return false;

    int numbytes = 0;
    if (lanlink.type == 0) { // TCP
        fdset.clear();

        for (int i = 0; i < lanlink.numslaves; i++)
            fdset.add(tcpsocket[i + 1]);

        if (fdset.wait(sf::milliseconds(1)) == 0) {
            return false;
        }

        for (int i = 0; i < lanlink.numslaves; i++) {
            numbytes = 0;
            uint8_t recv_byte = 0;

            size_t nr;
            (void)tcpsocket[i + 1].receive(&recv_byte, 1, nr);
            numbytes += (int)nr;

            if (numbytes != 0)
                counter = 1;

            if (inbuffer[1] == -32) {
                char message[30];
                snprintf(message, sizeof(message), _("Player %d disconnected."), i + 2);
                systemScreenMessage(message);
                for (i = 1; i < lanlink.numslaves; i++) {
                    tcpsocket[i].disconnect();
                }
                CloseLink();
                return false;
            }
            if (numbytes > 0)
                cable_gb_data[i + 1] = recv_byte;
        }
    }

    return numbytes != 0;
}

// Client
CableClient::CableClient(void)
{
    intinbuffer = (int32_t*)inbuffer;
    uint16_tinbuffer = (uint16_t*)inbuffer;
    intoutbuffer = (int32_t*)outbuffer;
    uint16_toutbuffer = (uint16_t*)outbuffer;
    transferring = false;
    return;
}

void CableClient::CheckConn(void)
{
    size_t nr;
    (void)lanlink.tcpsocket.receive(inbuffer, 1, nr);
    numbytes = (int)nr;
    if (numbytes > 0) {
        while (numbytes < inbuffer[0]) {
            (void)lanlink.tcpsocket.receive(inbuffer + numbytes, inbuffer[0] - numbytes, nr);
            numbytes += (int)nr;
        }
        if (inbuffer[1] == -32) {
            outbuffer[0] = 4;
            (void)lanlink.tcpsocket.send(outbuffer, 4);
            systemScreenMessage(_("Server disconnected."));
            CloseLink();
            return;
        }
        transferring = true;
        transfer_start_time_from_master = 0;
        cable_data[0] = READ16LE(&uint16_tinbuffer[1]);
        tspeed = inbuffer[1] & 3;
        for (int i = 1, bytes = 4; i <= lanlink.numslaves; i++)
            if (i != linkid) {
                cable_data[i] = READ16LE(&uint16_tinbuffer[bytes]);
                bytes++;
            }
    }
    return;
}

bool CableClient::RecvGB(void)
{
    if (!transferring)
        return false;

    fdset.clear();
    // old code used socket # instead of mask again
    fdset.add(lanlink.tcpsocket);
    // old code stripped off ms again
    if (fdset.wait(sf::milliseconds(1)) == 0) {
        return false;
    }
    numbytes = 0;
    size_t nr;
    uint8_t recv_byte = 0;

    (void)lanlink.tcpsocket.receive(&recv_byte, 1, nr);
    numbytes += (int)nr;

    if (numbytes != 0)
        transferring = false;

    if (inbuffer[1] == -32) {
        systemScreenMessage(_("Server disconnected."));
        CloseLink();
        return false;
    }
    if (numbytes > 0)
        cable_gb_data[0] = recv_byte;

    return numbytes != 0;
}

void CableClient::SendGB()
{
    if (transferring)
        return;

    (void)lanlink.tcpsocket.send(&cable_gb_data[1], 1);

    transferring = true;
}

void CableClient::Recv(void)
{
    fdset.clear();
    // old code used socket # instead of mask again
    fdset.add(lanlink.tcpsocket);
    // old code stripped off ms again
    if (fdset.wait(sf::milliseconds(50)) == 0) {
        transferring = false;
        return;
    }
    numbytes = 0;
    inbuffer[0] = 1;
    size_t nr;
    while (numbytes < inbuffer[0]) {
        (void)lanlink.tcpsocket.receive(inbuffer + numbytes, inbuffer[0] - numbytes, nr);
        numbytes += (int)nr;
    }
    if (inbuffer[1] == -32) {
        outbuffer[0] = 4;
        (void)lanlink.tcpsocket.send(outbuffer, 4);
        systemScreenMessage(_("Server disconnected."));
        CloseLink();
        return;
    }
    tspeed = inbuffer[1] & 3;
    cable_data[0] = READ16LE(&uint16_tinbuffer[1]);
    transfer_start_time_from_master = (int32_t)READ32LE(&intinbuffer[1]);
    for (int i = 1, bytes = 4; i < lanlink.numslaves + 1; i++) {
        if (i != linkid) {
            cable_data[i] = READ16LE(&uint16_tinbuffer[bytes]);
            bytes++;
        }
    }
}

void CableClient::Send()
{
    outbuffer[0] = 4;
    outbuffer[1] = (char)(linkid << 2);
    WRITE16LE(&uint16_toutbuffer[1], cable_data[linkid]);
    (void)lanlink.tcpsocket.send(outbuffer, 4);
    return;
}

static ConnectionState InitSocket()
{
    linkid = 0;

    for (int i = 0; i < 4; i++) {
        cable_data[i] = 0xffff;
    }

    for (int i = 0; i < 4; i++) {
        cable_gb_data[i] = 0xff;
    }

    if (lanlink.server) {
        lanlink.connectedSlaves = 0;
        // should probably use GetPublicAddress()
        //sid->ShowServerIP(sf::IpAddress::getLocalAddress());

        // too bad Listen() doesn't take an address as well
        // then again, old code used INADDR_ANY anyway
        sf::IpAddress bind_ip{0};

        if (IP_LINK_BIND_ADDRESS != "*") {
            auto resolved = sf::IpAddress::resolve(IP_LINK_BIND_ADDRESS);
            if (resolved) {
                bind_ip = resolved.value();
            } else {
                return LINK_ERROR;
            }
        }

        if (lanlink.tcplistener.listen(IP_LINK_PORT, bind_ip) == sf::Socket::Status::Error) {
            // Note: old code closed socket & retried once on bind failure
            return LINK_ERROR; // FIXME: error code?
        } else {
            return LINK_NEEDS_UPDATE;
        }
    } else {
        lc.serverport = IP_LINK_PORT;

        lanlink.tcpsocket.setBlocking(false);
        sf::Socket::Status status = lanlink.tcpsocket.connect(lc.serveraddr, lc.serverport);

        if (status == sf::Socket::Status::Error || status == sf::Socket::Status::Disconnected) {
            return LINK_ERROR;
        } else {
            return LINK_NEEDS_UPDATE;
        }
    }
}

static ConnectionState ConnectUpdateSocket(char* const message, size_t size)
{
    ConnectionState newState = LINK_NEEDS_UPDATE;

    if (lanlink.server) {
        sf::SocketSelector fdset;
        fdset.add(lanlink.tcplistener);

        if (fdset.wait(sf::milliseconds(150))) {
            uint16_t nextSlave = (uint16_t)(lanlink.connectedSlaves + 1);

            sf::Socket::Status st = lanlink.tcplistener.accept(ls.tcpsocket[nextSlave]);

            if (st == sf::Socket::Status::Error) {
                for (int j = 1; j < nextSlave; j++)
                    ls.tcpsocket[j].disconnect();

                snprintf(message, size, N_("Network error."));
                newState = LINK_ERROR;
            } else {
                sf::Packet packet;
                packet << nextSlave << lanlink.numslaves;

                (void)ls.tcpsocket[nextSlave].send(packet);

                snprintf(message, size, N_("Player %d connected"), nextSlave);

                lanlink.connectedSlaves++;
            }
        }

        if (lanlink.numslaves == lanlink.connectedSlaves) {
            for (int i = 1; i <= lanlink.numslaves; i++) {
                sf::Packet packet;
                packet << true;

                (void)ls.tcpsocket[i].send(packet);
            }

            snprintf(message, size, N_("All players connected"));
            newState = LINK_OK;
        }
    } else {

        sf::Packet packet;
        sf::Socket::Status status = lanlink.tcpsocket.receive(packet);

        if (status == sf::Socket::Status::Error || status == sf::Socket::Status::Disconnected) {
            snprintf(message, size, N_("Network error."));
            newState = LINK_ERROR;
        } else if (status == sf::Socket::Status::Done) {

            if (linkid == 0) {
                uint16_t receivedId, receivedSlaves;
                packet >> receivedId >> receivedSlaves;

                if (packet) {
                    linkid = receivedId;
                    lanlink.numslaves = receivedSlaves;

                    snprintf(message, size, N_("Connected as #%d, Waiting for %d players to join"),
                        linkid + 1, lanlink.numslaves - linkid);
                }
            } else {
                bool gameReady;
                packet >> gameReady;

                if (packet && gameReady) {
                    newState = LINK_OK;
                    snprintf(message, size, N_("All players joined."));
                }
            }

            sf::SocketSelector fdset;
            fdset.add(lanlink.tcpsocket);
            (void)fdset.wait(sf::milliseconds(150));
        }
    }

    return newState;
}

void StartCableSocket(uint16_t value)
{
    switch (GetSIOMode(value, READ16LE(&g_ioMem[COMM_RCNT]))) {
    case MULTIPLAYER: {
        bool start = (value & 0x80) && !linkid && !transfer_direction;
        // clear start, seqno, si (RO on slave, start = pulse on master)
        value &= 0xff4b;
        // get current si.  This way, on slaves, it is low during xfer
        if (linkid) {
            if (!transfer_direction)
                value |= 4;
            else
                value |= READ16LE(&g_ioMem[COMM_SIOCNT]) & 4;
        }
        if (start) {
            cable_data[0] = READ16LE(&g_ioMem[COMM_SIODATA8]);
            transfer_start_time_from_master = linktime;
            tspeed = value & 3;
            (void)ls.Send();
            transfer_direction = RECEIVING;
            linktime = 0;
            UPDATE_REG(COMM_SIOMULTI0, cable_data[0]);
            UPDATE_REG(COMM_SIOMULTI1, 0xffff);
            WRITE32LE(&g_ioMem[COMM_SIOMULTI2], 0xffffffff);
            value &= ~0x40;
        }
        value |= (transfer_direction ? 1 : 0) << 7;
        value |= (linkid && !transfer_direction) ? 0x0c : 0x08; // set SD (high), SI (low on master)
        value |= linkid << 4; // set seq
        UPDATE_REG(COMM_SIOCNT, value);
        if (linkid)
            // SC low -> transfer in progress
            // not sure why SO is low
            UPDATE_REG(COMM_RCNT, transfer_direction ? 6 : 7);
        else
            // SI is always low on master
            // SO, SC always low during transfer
            // not sure why SO low otherwise
            UPDATE_REG(COMM_RCNT, transfer_direction ? 2 : 3);
        break;
    }
    case NORMAL8:
    case NORMAL32:
    case UART:
    default:
        UPDATE_REG(COMM_SIOCNT, value);
        break;
    }
}

static void UpdateCableSocket(int ticks)
{
    (void)ticks; // unused param
    if (linkid && transfer_direction == SENDING && lc.transferring && linktime >= transfer_start_time_from_master) {
        cable_data[linkid] = READ16LE(&g_ioMem[COMM_SIODATA8]);

        (void)lc.Send();
        UPDATE_REG(COMM_SIODATA32_L, cable_data[0]);
        UPDATE_REG(COMM_SIOCNT, READ16LE(&g_ioMem[COMM_SIOCNT]) | 0x80);
        transfer_direction = RECEIVING;
        linktime = 0;
    }

    if (transfer_direction == RECEIVING && linktime >= trtimeend[lanlink.numslaves - 1][tspeed]) {
        if (READ16LE(&g_ioMem[COMM_SIOCNT]) & 0x4000) {
            IF |= 0x80;
            UPDATE_REG(IO_REG_IF, IF);
        }

        UPDATE_REG(COMM_SIOCNT, (READ16LE(&g_ioMem[COMM_SIOCNT]) & 0xff0f) | (linkid << 4));
        transfer_direction = SENDING;
        linktime -= trtimeend[lanlink.numslaves - 1][tspeed];

        if (linkid) {
            lc.transferring = true;
            lc.Recv();
        } else {
            ls.Recv(); // Receive data from all of the slaves
        }
        UPDATE_REG(COMM_SIOMULTI1, cable_data[1]);
        UPDATE_REG(COMM_SIOMULTI2, cable_data[2]);
        UPDATE_REG(COMM_SIOMULTI3, cable_data[3]);
    }
}

static void CloseSocket()
{
    if (linkid) {
        char outbuffer[4];
        outbuffer[0] = 4;
        outbuffer[1] = -32;
        if (lanlink.type == 0)
            (void)lanlink.tcpsocket.send(outbuffer, 4);
    } else {
        char outbuffer[12];
        int i;
        outbuffer[0] = 12;
        outbuffer[1] = -32;
        for (i = 1; i <= lanlink.numslaves; i++) {
            if (lanlink.type == 0) {
                (void)ls.tcpsocket[i].send(outbuffer, 12);
            }
            ls.tcpsocket[i].disconnect();
        }
    }
    lanlink.tcpsocket.disconnect();
}

// call this to clean up crashed program's shared state
// or to use TCP on same machine (for testing)
// this may be necessary under MSW as well, but I wouldn't know how
void CleanLocalLink()
{
#if !(defined __WIN32__ || defined _WIN32)
    shm_unlink("/" LOCAL_LINK_NAME);
    for (int i = 0; i < 4; i++) {
        linkevent[sizeof(linkevent) - 2] = '1' + i;
        sem_unlink(linkevent);
    }
#endif
}

static ConnectionState JoyBusConnect()
{
    delete dol;
    dol = NULL;

    dol = new GBASockClient(joybusHostAddr);
    if (dol) {
        return LINK_OK;
    } else {
        return LINK_ERROR;
    }
}

static void JoyBusUpdate(int ticks)
{
    lastjoybusupdate += ticks;
    lastcommand += ticks;

    bool joybus_activated = ((READ16LE(&g_ioMem[COMM_RCNT])) >> 14) == 3;
    gba_joybus_active = dol && gba_joybus_enabled && joybus_activated;

    if ((lastjoybusupdate > nextjoybusupdate)) {
        if (!joybus_activated) {
            if (dol && booted) {
                JoyBusShutdown();
            }

            lastjoybusupdate = 0;
            nextjoybusupdate = 0;
            lastcommand = 0;
            return;
        }

        if (!dol) {
            booted = false;
            JoyBusConnect();
        }

        dol->ReceiveClock(false);

        if (dol->IsDisconnected()) {
            JoyBusShutdown();
            nextjoybusupdate = TICKS_PER_SECOND * 2; // try to connect after 2 seconds
            lastjoybusupdate = 0;
            lastcommand = 0;
            return;
        }

        dol->ClockSync(lastjoybusupdate);

        char data[5] = { 0x10, 0, 0, 0, 0 }; // init with invalid cmd
        std::vector<char> resp;
        uint8_t cmd = 0x10;

        if (lastcommand > (TICKS_PER_FRAME * 4)) {
            cmd = dol->ReceiveCmd(data, true);
        } else {
            cmd = dol->ReceiveCmd(data, false);
        }

        switch (cmd) {
        case JOY_CMD_RESET:
            UPDATE_REG(COMM_JOYCNT, READ16LE(&g_ioMem[COMM_JOYCNT]) | JOYCNT_RESET);
            resp.push_back(0x00); // GBA device ID
            resp.push_back(0x04);
            nextjoybusupdate = TICKS_PER_SECOND / BYTES_PER_SECOND;
            break;

        case JOY_CMD_STATUS:
            resp.push_back(0x00); // GBA device ID
            resp.push_back(0x04);

            nextjoybusupdate = TICKS_PER_SECOND / BYTES_PER_SECOND;
            break;

        case JOY_CMD_READ:
            resp.push_back((uint8_t)(READ16LE(&g_ioMem[COMM_JOY_TRANS_L]) & 0xff));
            resp.push_back((uint8_t)(READ16LE(&g_ioMem[COMM_JOY_TRANS_L]) >> 8));
            resp.push_back((uint8_t)(READ16LE(&g_ioMem[COMM_JOY_TRANS_H]) & 0xff));
            resp.push_back((uint8_t)(READ16LE(&g_ioMem[COMM_JOY_TRANS_H]) >> 8));

            UPDATE_REG(COMM_JOYCNT, READ16LE(&g_ioMem[COMM_JOYCNT]) | JOYCNT_SEND_COMPLETE);
            nextjoybusupdate = TICKS_PER_SECOND / BYTES_PER_SECOND;
            booted = true;
            break;

        case JOY_CMD_WRITE:
            UPDATE_REG(COMM_JOY_RECV_L, (uint16_t)((uint16_t)data[2] << 8) | (uint8_t)data[1]);
            UPDATE_REG(COMM_JOY_RECV_H, (uint16_t)((uint16_t)data[4] << 8) | (uint8_t)data[3]);
            UPDATE_REG(COMM_JOYSTAT, READ16LE(&g_ioMem[COMM_JOYSTAT]) | JOYSTAT_RECV);
            UPDATE_REG(COMM_JOYCNT, READ16LE(&g_ioMem[COMM_JOYCNT]) | JOYCNT_RECV_COMPLETE);
            nextjoybusupdate = TICKS_PER_SECOND / BYTES_PER_SECOND;
            booted = true;
            break;

        default:
            nextjoybusupdate = TICKS_PER_SECOND / 40000;
            lastjoybusupdate = 0;
            return; // ignore
        }

        lastjoybusupdate = 0;
        resp.push_back((uint8_t)READ16LE(&g_ioMem[COMM_JOYSTAT]));

        if (cmd == JOY_CMD_READ) {
            UPDATE_REG(COMM_JOYSTAT, READ16LE(&g_ioMem[COMM_JOYSTAT]) & ~JOYSTAT_SEND);
        }

        dol->Send(resp);

        // Generate SIO interrupt if we can
        if (((cmd == JOY_CMD_RESET) || (cmd == JOY_CMD_READ) || (cmd == JOY_CMD_WRITE))
            && (READ16LE(&g_ioMem[COMM_JOYCNT]) & JOYCNT_INT_ENABLE)) {
            IF |= 0x80;
            UPDATE_REG(IO_REG_IF, IF);
        }

        lastcommand = 0;
    }
}

static void JoyBusShutdown()
{
    delete dol;
    dol = NULL;
}

#define MAX_CLIENTS lanlink.numslaves + 1

// Server
RFUServer::RFUServer(void)
{
    for (int j = 0; j < 5; j++)
        rfu_data.rfu_signal[j] = 0;
}

sf::Packet& RFUServer::Serialize(sf::Packet& packet, int slave)
{
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (i != slave) {
            packet << (i == current_host);
            packet << rfu_data.rfu_reqid[i];
            if (i == current_host) {
                for (int j = 0; j < 7; j++)
                    packet << rfu_data.rfu_broadcastdata[i][j];
            }
        }

        if (i == slave) {
            packet << rfu_data.rfu_clientidx[i];
            packet << rfu_data.rfu_is_host[i];
            packet << rfu_data.rfu_listback[i];

            if (rfu_data.rfu_listback[i] > 0)
                log("num_data_packets from %d to %d = %d\n", linkid, i, rfu_data.rfu_listback[i]);

            for (int j = 0; j <= rfu_data.rfu_listback[i]; j++) {
                packet << rfu_data.rfu_datalist[i][j & 0xff].len;

                for (int k = 0; k < rfu_data.rfu_datalist[i][j & 0xff].len; k++)
                    packet << rfu_data.rfu_datalist[i][j & 0xff].data[k];

                packet << rfu_data.rfu_datalist[i][j & 0xff].gbaid;
            }
        }
    }

    packet << linktime; // Synchronise clocks by setting slave clock to master clock
    return packet;
}

void RFUServer::DeSerialize(sf::Packet& packet, int slave)
{
    bool slave_is_host = false;
    packet >> slave_is_host;
    packet >> rfu_data.rfu_reqid[slave];
    if (slave_is_host) {
        current_host = (uint8_t)slave;
        for (int j = 0; j < 7; j++)
            packet >> rfu_data.rfu_broadcastdata[slave][j];
    }

    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (i != slave) {
            uint8_t num_data_sent = 0;
            packet >> rfu_data.rfu_clientidx[i];
            packet >> rfu_data.rfu_is_host[i];
            packet >> num_data_sent;

            for (int j = rfu_data.rfu_listback[i]; j <= (rfu_data.rfu_listback[i] + num_data_sent); j++) {
                packet >> rfu_data.rfu_datalist[i][j & 0xff].len;

                for (int k = 0; k < rfu_data.rfu_datalist[i][j & 0xff].len; k++)
                    packet >> rfu_data.rfu_datalist[i][j & 0xff].data[k];

                packet >> rfu_data.rfu_datalist[i][j & 0xff].gbaid;
            }

            rfu_data.rfu_listback[i] = (rfu_data.rfu_listback[i] + num_data_sent) & 0xff;
        }
    }
}

void RFUServer::Send(void)
{
    if (lanlink.type == 0) { // TCP
        sf::Packet packet;
        if (lanlink.numslaves == 1) {
            if (lanlink.type == 0) {
                (void)tcpsocket[1].send(Serialize(packet, 1));
            }
        } else if (lanlink.numslaves == 2) {
            if (lanlink.type == 0) {
                (void)tcpsocket[1].send(Serialize(packet, 1));
                (void)tcpsocket[2].send(Serialize(packet, 2));
            }
        } else {
            if (lanlink.type == 0) {
                (void)tcpsocket[1].send(Serialize(packet, 1));
                (void)tcpsocket[2].send(Serialize(packet, 2));
                (void)tcpsocket[3].send(Serialize(packet, 3));
            }
        }
    }
}

// Receive data from all slaves to master
void RFUServer::Recv(void)
{
    //int numbytes;
    if (lanlink.type == 0) { // TCP
        fdset.clear();

        for (int i = 0; i < lanlink.numslaves; i++)
            fdset.add(tcpsocket[i + 1]);

        //bool all_ready = false;
        //while (!all_ready)
        //{
        //	fdset.wait(sf::milliseconds(1));
        //	int count = 0;
        //	for (int sl = 0; sl < lanlink.numslaves; sl++)
        //	{
        //		if (fdset.isReady(tcpsocket[sl + 1]))
        //			count++;
        //	}
        //	if (count == lanlink.numslaves)
        //		all_ready = true;
        //}

        for (int i = 0; i < lanlink.numslaves; i++) {
            sf::Packet packet;
            tcpsocket[i + 1].setBlocking(false);
            sf::Socket::Status status = tcpsocket[i + 1].receive(packet);
            if (status == sf::Socket::Status::Disconnected) {
                char message[30];
                snprintf(message, sizeof(message), _("Player %d disconnected."), i + 1);
                systemScreenMessage(message);
                //tcpsocket[i + 1].disconnect();
                //CloseLink();
                //return;
            }
            DeSerialize(packet, i + 1);
        }
    }
}

// Client
RFUClient::RFUClient(void)
{
    transferring = false;

    for (int j = 0; j < 5; j++)
        rfu_data.rfu_signal[j] = 0;
}

sf::Packet& RFUClient::Serialize(sf::Packet& packet)
{
    packet << rfu_ishost;
    packet << rfu_data.rfu_reqid[linkid];
    if (rfu_ishost) {
        for (int j = 0; j < 7; j++)
            packet << rfu_data.rfu_broadcastdata[linkid][j];
    }

    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (i != linkid) {
            packet << rfu_data.rfu_clientidx[i];
            packet << rfu_data.rfu_is_host[i];
            packet << rfu_data.rfu_listback[i];

            if (rfu_data.rfu_listback[i] > 0)
                log("num_data_packets from %d to %d = %d\n", linkid, i, rfu_data.rfu_listback[i]);

            for (int j = 0; j <= rfu_data.rfu_listback[i]; j++) {
                packet << rfu_data.rfu_datalist[i][j].len;

                for (int k = 0; k < rfu_data.rfu_datalist[i][j].len; k++)
                    packet << rfu_data.rfu_datalist[i][j].data[k];

                packet << rfu_data.rfu_datalist[i][j].gbaid;
            }
        }
    }
    return packet;
}

void RFUClient::DeSerialize(sf::Packet& packet)
{
    bool is_current_host = false;
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (i != linkid) {
            packet >> is_current_host;
            packet >> rfu_data.rfu_reqid[i];
            if (is_current_host) {
                for (int j = 0; j < 7; j++)
                    packet >> rfu_data.rfu_broadcastdata[i][j];
            }
        }

        if (i == linkid) {
            uint8_t num_data_sent = 0;
            packet >> rfu_data.rfu_clientidx[i];
            packet >> rfu_data.rfu_is_host[i];
            packet >> num_data_sent;

            for (int j = rfu_data.rfu_listback[i]; j <= (rfu_data.rfu_listback[i] + num_data_sent); j++) {
                packet >> rfu_data.rfu_datalist[i][j & 0xff].len;

                for (int k = 0; k < rfu_data.rfu_datalist[i][j & 0xff].len; k++)
                    packet >> rfu_data.rfu_datalist[i][j & 0xff].data[k];

                packet >> rfu_data.rfu_datalist[i][j & 0xff].gbaid;
            }

            rfu_data.rfu_listback[i] = (rfu_data.rfu_listback[i] + num_data_sent) & 0xff;
        }
    }

    packet >> linktime; // Synchronise clocks by setting slave clock to master clock
}

void RFUClient::Send()
{
    sf::Packet packet;
    (void)lanlink.tcpsocket.send(Serialize(packet));
}

void RFUClient::Recv(void)
{
    if (rfu_data.numgbas < 2)
        return;

    fdset.clear();
    // old code used socket # instead of mask again
    lanlink.tcpsocket.setBlocking(false);
    fdset.add(lanlink.tcpsocket);
    if (fdset.wait(sf::milliseconds(166)) == 0) {
        systemScreenMessage(_("Server timed out."));
        //transferring = false;
        //return;
    }
    sf::Packet packet;
    sf::Socket::Status status = lanlink.tcpsocket.receive(packet);
    if (status == sf::Socket::Status::Disconnected) {
        systemScreenMessage(_("Server disconnected."));
        CloseLink();
        return;
    }
    DeSerialize(packet);
}

static ConnectionState ConnectUpdateRFUSocket(char* const message, size_t size)
{
    ConnectionState newState = LINK_NEEDS_UPDATE;

    if (lanlink.server) {
        sf::SocketSelector fdset;
        fdset.add(lanlink.tcplistener);

        if (fdset.wait(sf::milliseconds(150))) {
            int nextSlave = lanlink.connectedSlaves + 1;

            sf::Socket::Status st = lanlink.tcplistener.accept(rfu_server.tcpsocket[nextSlave]);

            if (st == sf::Socket::Status::Error) {
                for (int j = 1; j < nextSlave; j++)
                    rfu_server.tcpsocket[j].disconnect();

                snprintf(message, size, N_("Network error."));
                newState = LINK_ERROR;
            } else {
                sf::Packet packet;
                packet << nextSlave << lanlink.numslaves;

                (void)rfu_server.tcpsocket[nextSlave].send(packet);

                snprintf(message, size, N_("Player %d connected"), nextSlave);
                lanlink.connectedSlaves++;
            }
        }

        if (lanlink.numslaves == lanlink.connectedSlaves) {
            for (int i = 1; i <= lanlink.numslaves; i++) {
                sf::Packet packet;
                packet << true;

                (void)rfu_server.tcpsocket[i].send(packet);
                rfu_server.tcpsocket[i].setBlocking(false);
            }

            snprintf(message, size, N_("All players connected"));
            newState = LINK_OK;
        }
    } else {

        sf::Packet packet;
        lanlink.tcpsocket.setBlocking(false);
        sf::Socket::Status status = lanlink.tcpsocket.receive(packet);

        if (status == sf::Socket::Status::Error || status == sf::Socket::Status::Disconnected) {
            snprintf(message, size, N_("Network error."));
            newState = LINK_ERROR;
        } else if (status == sf::Socket::Status::Done) {

            if (linkid == 0) {
                uint16_t receivedId, receivedSlaves;
                packet >> receivedId >> receivedSlaves;

                if (packet) {
                    linkid = receivedId;
                    lanlink.numslaves = receivedSlaves;

                    snprintf(message, size, N_("Connected as #%d, Waiting for %d players to join"),
                        linkid + 1, lanlink.numslaves - linkid);
                }
            } else {
                bool gameReady;
                packet >> gameReady;

                if (packet && gameReady) {
                    newState = LINK_OK;
                    snprintf(message, size, N_("All players joined."));
                }
            }

            sf::SocketSelector fdset;
            fdset.add(lanlink.tcpsocket);
            (void)fdset.wait(sf::milliseconds(150));
        }
    }

    rfu_data.numgbas = (uint8_t)(lanlink.numslaves + 1);
    log("num gbas: %d\n", rfu_data.numgbas);

    return newState;
}

// The GBA wireless RFU (see adapter3.txt)
static void StartRFUSocket(uint16_t value)
{
    int siomode = GetSIOMode(value, READ16LE(&g_ioMem[COMM_RCNT]));

    if (value)
        rfu_enabled = (siomode == NORMAL32);

    if (((READ16LE(&g_ioMem[COMM_SIOCNT]) & 0x5080) == SIO_TRANS_32BIT) && ((value & 0x5080) == (SIO_TRANS_32BIT | SIO_IRQ_ENABLE | SIO_TRANS_START))) { //RFU Reset, may also occur before cable link started
        rfu_data.rfu_listfront[linkid] = 0;
        rfu_data.rfu_listback[linkid] = 0;
    }

    if (!rfu_enabled) {
        if ((value & 0x5080) == (SIO_TRANS_32BIT | SIO_IRQ_ENABLE | SIO_TRANS_START)) { //0x5083 //game tried to send wireless command but w/o the adapter
            if (READ16LE(&g_ioMem[COMM_SIOCNT]) & SIO_IRQ_ENABLE) //IRQ Enable
            {
                IF |= 0x80; //Serial Communication
                UPDATE_REG(IO_REG_IF, IF); //Interrupt Request Flags / IRQ Acknowledge
            }
            value &= ~SIO_TRANS_START; //Start bit.7 reset //may cause the game to retry sending again
            value |= SIO_TRANS_FLAG_SEND_DISABLE; //SO bit.3 set automatically upon transfer completion
            transfer_direction = SENDING;
        }
        return;
    }

    uint32_t CurCOM = 0, CurDAT = 0;

    switch (GetSIOMode(value, READ16LE(&g_ioMem[COMM_RCNT]))) {
    case NORMAL8:
        rfu_polarity = 0;
        UPDATE_REG(COMM_SIOCNT, value);
        return;
        break;
    case NORMAL32:
        //don't do anything if previous cmd aren't sent yet, may fix Boktai2 Not Detecting wireless adapter
        //if (transfer_direction == RECEIVING)
        //{
        //	UPDATE_REG(COMM_SIOCNT, value);
        //	return;
        //}

        //Moving this to the bottom might prevent Mario Golf Adv from Occasionally Not Detecting wireless adapter
        if (value & SIO_TRANS_FLAG_SEND_DISABLE) //Transfer Enable Flag Send (SO.bit.3, 1=Disable Transfer/Not Ready)
            value &= ~SIO_TRANS_FLAG_RECV_ENABLE; //Transfer enable flag receive (0=Enable Transfer/Ready, SI.bit.2=SO.bit.3 of otherside)	// A kind of acknowledge procedure
        else //(SO.Bit.3, 0=Enable Transfer/Ready)
            value |= SIO_TRANS_FLAG_RECV_ENABLE; //SI.bit.2=1 (otherside is Not Ready)

        if ((value & (SIO_INT_CLOCK | SIO_TRANS_FLAG_RECV_ENABLE)) == SIO_INT_CLOCK)
            value |= SIO_INT_CLOCK_SEL_2MHZ; //wireless always use 2Mhz speed right? this will fix MarioGolfAdv Not Detecting wireless

        if (value & SIO_TRANS_START) //start/busy bit
        {
            if ((value & (SIO_INT_CLOCK | SIO_INT_CLOCK_SEL_2MHZ)) == SIO_INT_CLOCK)
                rfu_transfer_end = 2048;
            else
                rfu_transfer_end = 256;

            uint16_t siodata_h = READ16LE(&g_ioMem[COMM_SIODATA32_H]);
            switch (rfu_state) {
            case RFU_INIT:
                if (READ32LE(&g_ioMem[COMM_SIODATA32_L]) == 0xb0bb8001) {
                    rfu_state = RFU_COMM; // end of startup
                    rfu_initialized = true;
                    value &= ~SIO_TRANS_FLAG_RECV_ENABLE; //0xff7b; //Bit.2 need to be 0 to indicate a finished initialization to fix MarioGolfAdv from occasionally Not Detecting wireless adapter (prevent it from sending 0x7FFE8001 comm)?
                    rfu_polarity = 0; //not needed?
                }
                rfu_buf = (READ16LE(&g_ioMem[COMM_SIODATA32_L]) << 16) | siodata_h;
                break;
            case RFU_COMM:
                CurCOM = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                if (siodata_h == 0x9966) //initialize cmd
                {
                    uint8_t tmpcmd = (uint8_t)CurCOM;
                    if (tmpcmd != 0x10 && tmpcmd != 0x11 && tmpcmd != 0x13 && tmpcmd != 0x14 && tmpcmd != 0x16 && tmpcmd != 0x17 && tmpcmd != 0x19 && tmpcmd != 0x1a && tmpcmd != 0x1b && tmpcmd != 0x1c && tmpcmd != 0x1d && tmpcmd != 0x1e && tmpcmd != 0x1f && tmpcmd != 0x20 && tmpcmd != 0x21 && tmpcmd != 0x24 && tmpcmd != 0x25 && tmpcmd != 0x26 && tmpcmd != 0x27 && tmpcmd != 0x30 && tmpcmd != 0x32 && tmpcmd != 0x33 && tmpcmd != 0x34 && tmpcmd != 0x3d && tmpcmd != 0xa8 && tmpcmd != 0xee) {
                    }
                    rfu_counter = 0;
                    if ((rfu_qsend2 = rfu_qsend = g_ioMem[0x121]) != 0) { //COMM_SIODATA32_L+1, following data [to send]
                        rfu_state = RFU_SEND;
                    }
                    if (g_ioMem[COMM_SIODATA32_L] == 0xee) { //0xee cmd shouldn't override previous cmd
                        rfu_lastcmd = rfu_cmd2;
                        rfu_cmd2 = g_ioMem[COMM_SIODATA32_L];
                    } else {
                        rfu_lastcmd = rfu_cmd;
                        rfu_cmd = g_ioMem[COMM_SIODATA32_L];
                        rfu_cmd2 = 0;
                        if (rfu_cmd == 0x27 || rfu_cmd == 0x37) {
                            rfu_lastcmd2 = rfu_cmd;
                            rfu_lasttime = linktime;
                        } else if (rfu_cmd == 0x24) { //non-important data shouldn't overwrite important data from 0x25
                            rfu_lastcmd2 = rfu_cmd;
                            rfu_cansend = false;
                            //previous important data need to be received successfully before sending another important data
                            rfu_lasttime = linktime; //just to mark the last time a data being sent
                            if (rfu_data.rfu_q[linkid] < 2) { //can overwrite now
                                rfu_cansend = true;
                                rfu_data.rfu_q[linkid] = 0; //rfu_qsend;
                                rfu_data.rfu_qid[linkid] = 0;
                            } else if (!speedhack)
                                rfu_waiting = true; //don't wait with speedhack
                        } else if (rfu_cmd == 0x25 || rfu_cmd == 0x35) {
                            rfu_lastcmd2 = rfu_cmd;
                            rfu_cansend = false;
                            //previous important data need to be received successfully before sending another important data
                            rfu_lasttime = linktime;
                            if (rfu_data.rfu_q[linkid] < 2) {
                                rfu_cansend = true;
                                rfu_data.rfu_q[linkid] = 0; //rfu_qsend;
                                rfu_data.rfu_qid[linkid] = 0;
                            } else if (!speedhack)
                                rfu_waiting = true; //don't wait with speedhack
                        } else if (rfu_cmd == 0xa8 || rfu_cmd == 0xb6) {
                            //wait for [important] data when previously sent is important data, might only need to wait for the 1st 0x25 cmd
                        } else if (rfu_cmd == 0x11 || rfu_cmd == 0x1a || rfu_cmd == 0x26) {
                            if (rfu_lastcmd2 == 0x24)
                                rfu_waiting = true;
                        }
                    }
                    if (rfu_waiting)
                        rfu_buf = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    else
                        rfu_buf = 0x80000000;
                } else if (siodata_h == 0x8000) //finalize cmd, the game will send this when polarity reversed (expecting something)
                {
                    rfu_qrecv_broadcast_data_len = 0;
                    if (rfu_cmd2 == 0xee) {
                        if (rfu_masterdata[0] == 2) //is this value of 2 related to polarity?
                            rfu_polarity = 0; //to normalize polarity after finalize looks more proper
                        rfu_buf = 0x99660000 | (rfu_qrecv_broadcast_data_len << 8) | (rfu_cmd2 ^ 0x80);
                    } else {
                        switch (rfu_cmd) {
                        case 0x1a: // check if someone joined
                            if (rfu_data.rfu_is_host[linkid]) {
                                gbaidx = gbaid;

                                do {
                                    gbaidx = (gbaidx + 1) % rfu_data.numgbas; // check this numgbas = 3, gbaid = 0, gbaidx = 1,
                                    if (gbaidx != linkid && rfu_data.rfu_reqid[gbaidx] == (linkid << 3) + 0x61f1) {
                                        rfu_masterdata[rfu_qrecv_broadcast_data_len++] = (gbaidx << 3) + 0x61f1;
                                    }
                                } while (gbaidx != gbaid && rfu_data.numgbas >= 2);

                                if (rfu_qrecv_broadcast_data_len > 0) {
                                    bool ok = false;
                                    for (int i = 0; i < rfu_numclients; i++)
                                        if ((rfu_clientlist[i] & 0xffff) == rfu_masterdata[0]) {
                                            ok = true;
                                            break;
                                        }
                                    if (!ok) {
                                        rfu_curclient = rfu_numclients;
                                        rfu_data.rfu_clientidx[(rfu_masterdata[0] - 0x61f1) >> 3] = rfu_numclients;
                                        rfu_clientlist[rfu_numclients] = rfu_masterdata[0] | (rfu_numclients << 16);
                                        rfu_numclients++;
                                        gbaid = (rfu_masterdata[0] - 0x61f1) >> 3;
                                        rfu_data.rfu_signal[gbaid] = 0xffffffff >> ((3 - (rfu_numclients - 1)) << 3);
                                    }
                                    if (gbaid == linkid) {
                                        gbaid = (rfu_masterdata[0] - 0x61f1) >> 3;
                                    }
                                    rfu_state = RFU_RECV;
                                }
                            }
                            if (rfu_numclients > 0) {
                                for (int i = 0; i < rfu_numclients; i++)
                                    rfu_masterdata[i] = rfu_clientlist[i];
                            }
                            rfu_id = (uint16_t)((gbaid << 3) + 0x61f1);
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x1f: // join a room as client
                            // TODO: to fix infinte send&recv w/o giving much cance to update the screen when both side acting as client
                            // on MarioGolfAdv lobby(might be due to leftover data when switching from host to join mode at the same time?)
                            rfu_id = (uint16_t)rfu_masterdata[0];
                            gbaid = (rfu_id - 0x61f1) >> 3;
                            rfu_idx = rfu_id;
                            gbaidx = gbaid;
                            rfu_lastcmd2 = 0;
                            numtransfers = 0;
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            rfu_data.rfu_reqid[linkid] = rfu_id;
                            // TODO:might failed to reset rfu_request when being accessed by otherside at the same time, sometimes both acting
                            // as client but one of them still have request[linkid]!=0 //to prevent both GBAs from acting as Host, client can't
                            // be a host at the same time
                            rfu_data.rfu_is_host[linkid] = 0;
                            if (linkid != gbaid) {
                                rfu_data.rfu_signal[linkid] = 0x00ff;
                                rfu_data.rfu_is_host[gbaid] |= 1 << linkid; // tells the other GBA(a host) that someone(a client) is joining
                                log("%09d: joining room: signal: %d   linkid: %d  gbaid: %d\n", linktime, rfu_data.rfu_signal[linkid], linkid, gbaid);
                            }
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x1e: // receive broadcast data
                            numtransfers = 0;
                            rfu_numclients = 0;
                            rfu_data.rfu_is_host[linkid] = 0; //to prevent both GBAs from acting as Host and thinking both of them have Client?
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            [[fallthrough]];
                        case 0x1d: // no visible difference
                            rfu_data.rfu_is_host[linkid] = 0;
                            memset(rfu_masterdata, 0, sizeof(rfu_data.rfu_broadcastdata[linkid]));
                            rfu_qrecv_broadcast_data_len = 0;
                            for (int i = 0; i < rfu_data.numgbas; i++) {
                                if (i != linkid && rfu_data.rfu_broadcastdata[i][0]) {
                                    memcpy(&rfu_masterdata[rfu_qrecv_broadcast_data_len], rfu_data.rfu_broadcastdata[i], sizeof(rfu_data.rfu_broadcastdata[i]));
                                    rfu_qrecv_broadcast_data_len += 7;
                                }
                            }
                            // is this needed? to prevent MarioGolfAdv from joining it's own room when switching
                            // from host to client mode due to left over room data in the game buffer?
                            // if(rfu_qrecv==0) rfu_qrecv = 7;
                            if (rfu_qrecv_broadcast_data_len > 0) {
                                log("%09d: switching to RFU_RECV (broadcast)\n", linktime);
                                rfu_state = RFU_RECV;
                            }
                            rfu_polarity = 0;
                            rfu_counter = 0;
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x16: // send broadcast data (ie. room name)
                            //start broadcasting here may cause client to join other client in pokemon coloseum
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x11: // get signal strength
                            //Switch remote id
                            //check signal
                            if (rfu_data.numgbas >= 2 && (rfu_data.rfu_is_host[linkid] | rfu_data.rfu_is_host[gbaid])) //signal only good when connected
                                if (rfu_ishost) { //update, just incase there are leaving clients
                                    uint8_t rfureq = rfu_data.rfu_is_host[linkid];
                                    uint8_t oldnum = rfu_numclients;
                                    rfu_numclients = 0;
                                    for (int i = 0; i < 8; i++) {
                                        if (rfureq & 1)
                                            rfu_numclients++;
                                        rfureq >>= 1;
                                    }
                                    if (rfu_numclients > oldnum)
                                        rfu_numclients = oldnum; //must not be higher than old value, which means the new client haven't been processed by 0x1a cmd yet
                                    rfu_data.rfu_signal[linkid] = 0xffffffff >> ((4 - rfu_numclients) << 3);
                                } else
                                    rfu_data.rfu_signal[linkid] = rfu_data.rfu_signal[gbaid];
                            else
                                rfu_data.rfu_signal[linkid] = 0;
                            if (rfu_qrecv_broadcast_data_len == 0) {
                                rfu_qrecv_broadcast_data_len = 1;
                                rfu_masterdata[0] = (uint32_t)rfu_data.rfu_signal[linkid];
                            }
                            if (rfu_qrecv_broadcast_data_len > 0) {
                                rfu_state = RFU_RECV;
                                rfu_masterdata[rfu_qrecv_broadcast_data_len - 1] = (uint32_t)rfu_data.rfu_signal[gbaid];
                            }
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x33: // rejoin status check?
                            if (rfu_data.rfu_signal[linkid] || numtransfers == 0)
                                rfu_masterdata[0] = 0;
                            else //0=success
                                rfu_masterdata[0] = (uint32_t)-1; //0xffffffff; //1=failed, 2++ = reserved/invalid, we use invalid value to let the game retries 0x33 until signal restored
                            rfu_cmd ^= 0x80;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            break;
                        case 0x14: // reset current client index and error check?
                            if ((rfu_data.rfu_signal[linkid] || numtransfers == 0) && gbaid != linkid)
                                rfu_masterdata[0] = ((!rfu_ishost ? 0x100 : 0 + rfu_data.rfu_clientidx[gbaid]) << 16) | ((gbaid << 3) + 0x61f1);
                            rfu_masterdata[0] = 0; //0=error, non-zero=good?
                            rfu_cmd ^= 0x80;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            break;
                        case 0x13: // error check?
                            if (rfu_data.rfu_signal[linkid] || numtransfers == 0 || rfu_initialized) {
                                rfu_masterdata[0] = ((rfu_ishost ? 0x100 : 0 + rfu_data.rfu_clientidx[linkid]) << 16) | ((linkid << 3) + 0x61f1);
                            } else //high word should be 0x0200 ? is 0x0200 means 1st client and 0x4000 means 2nd client?
                            {
                                log("%09d: error status\n", linktime);
                                rfu_masterdata[0] = 0; //0=error, non-zero=good?
                            }
                            rfu_cmd ^= 0x80;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            break;
                        case 0x20: // client, this has something to do with 0x1f
                            rfu_masterdata[0] = (rfu_data.rfu_clientidx[linkid]) << 16; //needed for client
                            rfu_masterdata[0] |= (linkid << 3) + 0x61f1; //0x1234; //0x641b; //max id value? Encryption key or Station Mode? (0xFBD9/0xDEAD=Access Point mode?)
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            rfu_data.rfu_is_host[linkid] = 0; //TODO:may not works properly, sometimes both acting as client but one of them still have request[linkid]!=0 //to prevent both GBAs from acting as Host, client can't be a host at the same time
                            if (rfu_data.rfu_signal[gbaid] < rfu_data.rfu_signal[linkid])
                                rfu_data.rfu_signal[gbaid] = rfu_data.rfu_signal[linkid];

                            rfu_polarity = 0;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x21: // client, this too
                            rfu_masterdata[0] = (rfu_data.rfu_clientidx[linkid]) << 16; //not needed?
                            rfu_masterdata[0] |= (linkid << 3) + 0x61f1; //0x641b; //max id value? Encryption key or Station Mode? (0xFBD9/0xDEAD=Access Point mode?)
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            rfu_data.rfu_is_host[linkid] = 0; //TODO:may not works properly, sometimes both acting as client but one of them still have request[linkid]!=0 //to prevent both GBAs from acting as Host, client can't be a host at the same time
                            rfu_polarity = 0;
                            rfu_state = RFU_RECV; //3;
                            rfu_qrecv_broadcast_data_len = 1;
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x19: // server bind/start listening for client to join, may be used in the middle of host<->client communication w/o causing clients to dc?
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            rfu_data.rfu_broadcastdata[linkid][0] = (linkid << 3) + 0x61f1; //start broadcasting room name
                            rfu_data.rfu_clientidx[linkid] = 0;
                            rfu_ishost = true;
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x1c: //client, might reset some data?
                            rfu_ishost = false; //TODO: prevent both GBAs act as client but one of them have rfu_request[linkid]!=0 on MarioGolfAdv lobby
                            rfu_numclients = 0;
                            rfu_curclient = 0;
                            rfu_data.rfu_listfront[linkid] = 0;
                            rfu_data.rfu_listback[linkid] = 0;
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            [[fallthrough]];
                        case 0x1b: //host, might reset some data? may be used in the middle of host<->client communication w/o causing clients to dc?
                            rfu_data.rfu_broadcastdata[linkid][0] = 0; //0 may cause player unable to join in pokemon union room?
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x30: //reset some data
                            if (linkid != gbaid) { //(rfu_data.numgbas >= 2)
                                rfu_data.rfu_is_host[gbaid] &= ~(1 << linkid); //rfu_data.rfu_request[gbaid] = 0;
                            }
                            while (rfu_data.rfu_signal[linkid]) {
                                rfu_data.rfu_signal[linkid] = 0;
                                rfu_data.rfu_is_host[linkid] = 0; //There is a possibility where rfu_request/signal didn't get zeroed here when it's being read by the other GBA at the same time
                            }
                            rfu_data.rfu_listfront[linkid] = 0;
                            rfu_data.rfu_listback[linkid] = 0;
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            rfu_data.rfu_proto[linkid] = 0;
                            rfu_data.rfu_reqid[linkid] = 0;
                            rfu_data.rfu_linktime[linkid] = 0;
                            rfu_data.rfu_gdata[linkid] = 0;
                            rfu_data.rfu_broadcastdata[linkid][0] = 0;
                            rfu_polarity = 0; //is this included?
                            numtransfers = 0;
                            rfu_numclients = 0;
                            rfu_curclient = 0;
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x3d: // init/reset rfu data
                            rfu_initialized = false;
                            [[fallthrough]];
                        case 0x10: // init/reset rfu data
                            if (linkid != gbaid) { //(rfu_data.numgbas >= 2)
                                rfu_data.rfu_is_host[gbaid] &= ~(1 << linkid); //rfu_data.rfu_request[gbaid] = 0;
                            }
                            while (rfu_data.rfu_signal[linkid]) {
                                rfu_data.rfu_signal[linkid] = 0;
                                rfu_data.rfu_is_host[linkid] = 0; //There is a possibility where rfu_request/signal didn't get zeroed here when it's being read by the other GBA at the same time
                            }
                            rfu_data.rfu_listfront[linkid] = 0;
                            rfu_data.rfu_listback[linkid] = 0;
                            rfu_data.rfu_q[linkid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            rfu_data.rfu_proto[linkid] = 0;
                            rfu_data.rfu_reqid[linkid] = 0;
                            rfu_data.rfu_linktime[linkid] = 0;
                            rfu_data.rfu_gdata[linkid] = 0;
                            rfu_data.rfu_broadcastdata[linkid][0] = 0;
                            rfu_polarity = 0; //is this included?
                            numtransfers = 0;
                            rfu_numclients = 0;
                            rfu_curclient = 0;
                            rfu_id = 0;
                            rfu_idx = 0;
                            gbaid = linkid;
                            gbaidx = gbaid;
                            rfu_ishost = false;
                            rfu_qrecv_broadcast_data_len = 0;
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x36: //does it expect data returned?
                        case 0x26:
                            //Switch remote id to available data
                            bool ok;
                            int ctr;
                            ctr = 0;
                            if (rfu_data.rfu_listfront[linkid] != rfu_data.rfu_listback[linkid]) //data existed
                                do {
                                    uint8_t qdata_len = rfu_data.rfu_datalist[linkid][rfu_data.rfu_listfront[linkid]].len; //(uint8_t)rfu_data.rfu_qlist[linkid][rfu_data.rfu_listfront[linkid]];
                                    ok = false;
                                    if (qdata_len != rfu_qrecv_broadcast_data_len)
                                        ok = true;
                                    else
                                        for (int i = 0; i < qdata_len; i++)
                                            if (rfu_data.rfu_datalist[linkid][rfu_data.rfu_listfront[linkid]].data[i] != rfu_masterdata[i]) {
                                                ok = true;
                                                break;
                                            } // dupe data check

                                    if (qdata_len == 0 && ctr == 0)
                                        ok = true; //0-size data

                                    //if (ok) //next data is not a duplicate of currently unprocessed data
                                    if (rfu_qrecv_broadcast_data_len < 2 || qdata_len > 1) {
                                        if (rfu_qrecv_broadcast_data_len > 1) { //stop here if next data is different than currently unprocessed non-ping data
                                            //break;
                                        }

                                        if (qdata_len >= rfu_qrecv_broadcast_data_len) {
                                            rfu_masterq = rfu_qrecv_broadcast_data_len = qdata_len;
                                            gbaid = rfu_data.rfu_datalist[linkid][rfu_data.rfu_listfront[linkid]].gbaid;
                                            rfu_id = (uint16_t)((gbaid << 3) + 0x61f1);
                                            if (rfu_ishost) {
                                                rfu_curclient = (uint8_t)rfu_data.rfu_clientidx[gbaid];
                                            }
                                            if (rfu_qrecv_broadcast_data_len != 0) { //data size > 0
                                                memcpy(rfu_masterdata, rfu_data.rfu_datalist[linkid][rfu_data.rfu_listfront[linkid]].data, std::min(rfu_masterq << 2, (int)sizeof(rfu_masterdata)));
                                            }
                                        }
                                    }

                                    rfu_data.rfu_listfront[linkid]++;
                                    ctr++;

                                    ok = (rfu_data.rfu_listfront[linkid] != rfu_data.rfu_listback[linkid] && rfu_data.rfu_datalist[linkid][rfu_data.rfu_listfront[linkid]].gbaid == gbaid);
                                } while (ok);

                            if (rfu_qrecv_broadcast_data_len > 0) { //data was available
                                rfu_state = RFU_RECV;
                                rfu_counter = 0;
                                rfu_lastcmd2 = 0;

                                //Switch remote id to next remote id
                            }
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x24: // send [non-important] data (used by server often)
                            rfu_data.rfu_linktime[linkid] = linktime; //save the ticks before reseted to zero

			    // rfu_qsend2 >= 0 due to being `uint8_t`
                            if (rfu_cansend) {
                                if (rfu_ishost) {
                                    for (int j = 0; j < rfu_data.numgbas; j++)
                                        if (j != linkid) {
                                            memcpy(rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].data, rfu_masterdata, 4 * rfu_qsend2);
                                            rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].gbaid = (uint8_t)linkid;
                                            rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].len = rfu_qsend2;
                                            rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].time = linktime;
                                            rfu_data.rfu_listback[j]++;
                                        }
                                } else if (linkid != gbaid) {
                                    memcpy(rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].data, rfu_masterdata, 4 * rfu_qsend2);
                                    rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].gbaid = (uint8_t)linkid;
                                    rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].len = rfu_qsend2;
                                    rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].time = linktime;
                                    rfu_data.rfu_listback[gbaid]++;
                                }
                            } else {
                                log("IgnoredSend[%02X] %d\n", rfu_cmd, rfu_qsend2);
                            }
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x25: // send [important] data & wait for [important?] reply data
                        case 0x35: // send [important] data & wait for [important?] reply data
                            rfu_data.rfu_linktime[linkid] = linktime; //save the ticks before changed to synchronize performance

                            if (rfu_cansend && rfu_qsend2 > 0) {
                                if (rfu_ishost) {
                                    for (int j = 0; j < rfu_data.numgbas; j++)
                                        if (j != linkid) {
                                            memcpy(rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].data, rfu_masterdata, 4 * rfu_qsend2);
                                            rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].gbaid = (uint8_t)linkid;
                                            rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].len = rfu_qsend2;
                                            rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].time = linktime;
                                            rfu_data.rfu_listback[j]++;
                                        }
                                } else if (linkid != gbaid) {
                                    memcpy(rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].data, rfu_masterdata, 4 * rfu_qsend2);
                                    rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].gbaid = (uint8_t)linkid;
                                    rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].len = rfu_qsend2;
                                    rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].time = linktime;
                                    rfu_data.rfu_listback[gbaid]++;
                                }
                            } else {
                                log("IgnoredSend[%02X] %d\n", rfu_cmd, rfu_qsend2);
                            }
                            [[fallthrough]];
                        //TODO: there is still a chance for 0x25 to be used at the same time on both GBA (both GBAs acting as client but keep sending & receiving using 0x25 & 0x26 for infinity w/o updating the screen much)
                        //Waiting here for previous data to be received might be too late! as new data already sent before finalization cmd
                        case 0x27: // wait for data ?
                        case 0x37: // wait for data ?
                            rfu_data.rfu_linktime[linkid] = linktime; //save the ticks before changed to synchronize performance

                            if (rfu_ishost) {
                                for (int j = 0; j < rfu_data.numgbas; j++)
                                    if (j != linkid) {
                                        rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].gbaid = (uint8_t)linkid;
                                        rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].len = 0; //rfu_qsend2;
                                        rfu_data.rfu_datalist[j][rfu_data.rfu_listback[j]].time = linktime;
                                        rfu_data.rfu_listback[j]++;
                                    }
                            } else if (linkid != gbaid) {
                                rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].gbaid = (uint8_t)linkid;
                                rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].len = 0; //rfu_qsend2;
                                rfu_data.rfu_datalist[gbaid][rfu_data.rfu_listback[gbaid]].time = linktime;
                                rfu_data.rfu_listback[gbaid]++;
                            }
                            rfu_cmd ^= 0x80;
                            break;

                        case 0xee: //is this need to be processed?
                            rfu_cmd ^= 0x80;
                            rfu_polarity = 1;
                            break;

                        case 0x17: // setup or something ?
                        default:
                            rfu_cmd ^= 0x80;
                            break;

                        case 0xa5: //	2nd part of send&wait function 0x25
                        case 0xa7: //	2nd part of wait function 0x27
                        case 0xb5: //	2nd part of send&wait function 0x35?
                        case 0xb7: //	2nd part of wait function 0x37?
                            if (rfu_data.rfu_listfront[linkid] != rfu_data.rfu_listback[linkid]) {
                                rfu_polarity = 1; //reverse polarity to make the game send 0x80000000 command word (to be replied with 0x99660028 later by the adapter)
                                if (rfu_cmd == 0xa5 || rfu_cmd == 0xa7)
                                    rfu_cmd = 0x28;
                                else
                                    rfu_cmd = 0x36; //there might be 0x29 also //don't return 0x28 yet until there is incoming data (or until 500ms-6sec timeout? may reset RFU after timeout)
                            } else
                                rfu_waiting = true;
                            //prevent GBAs from sending data at the same time (which may cause waiting at the same time in the case of 0x25), also gives time for the other side to read the data

                            if (rfu_waiting) {
                                rfu_transfer_end = 1; //(rfu_masterq + rfu_qsend2 + 1) * 2500;
                            }

                            if (rfu_waiting && rfu_transfer_end < 0)
                                rfu_transfer_end = 0;

                            break;
                        }
                        if (!rfu_waiting)
                            rfu_buf = 0x99660000 | (rfu_qrecv_broadcast_data_len << 8) | rfu_cmd;
                        else
                            rfu_buf = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    }
                } else { //unknown COMM word //in MarioGolfAdv (when a player/client exiting lobby), There is a possibility COMM = 0x7FFE8001, PrevVAL = 0x5087, PrevCOM = 0, is this part of initialization?
                    log("%09d: UnkCOM %08X  %04X  %08X %08X\n", linktime, READ32LE(&g_ioMem[COMM_SIODATA32_L]), PrevVAL, PrevCOM, PrevDAT);
                    if ((READ32LE(&g_ioMem[COMM_SIODATA32_L]) >> 24) != 0x7ff)
                        rfu_state = RFU_INIT; //to prevent the next reinit words from getting in finalization processing (here), may cause MarioGolfAdv to show Linking error when this occurs instead of continuing with COMM cmd
                    rfu_buf = (READ16LE(&g_ioMem[COMM_SIODATA32_L]) << 16) | siodata_h;
                }
                break;

            case RFU_SEND: //data following after initialize cmd
                CurDAT = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                if (--rfu_qsend == 0) {
                    rfu_state = RFU_COMM;
                }

                switch (rfu_cmd) {
                case 0x16:
                    rfu_data.rfu_broadcastdata[linkid][1 + rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                case 0x17:
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                case 0x1f:
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                case 0x24:
                //if(rfu_data.rfu_proto[linkid]) break; //important data from 0x25 shouldn't be overwritten by 0x24
                case 0x25:
                case 0x35:
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                default:
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;
                }
                rfu_buf = 0x80000000;
                break;

            case RFU_RECV: //data following after finalize cmd
                if (--rfu_qrecv_broadcast_data_len == 0) {
                    rfu_state = RFU_COMM;
                }

                switch (rfu_cmd) {
                case 0x9d:
                case 0x9e:
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0xb6:
                case 0xa6:
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0x91: //signal strength
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0xb3: //rejoin error code?
                case 0x94: //last error code? //it seems like the game doesn't care about this value
                case 0x93: //last error code? //it seems like the game doesn't care about this value
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0xa0:
                    //max id value? Encryption key or Station Mode? (0xFBD9/0xDEAD=Access Point mode?)
                    //high word 0 = a success indication?
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;
                case 0xa1:
                    //max id value? the same with 0xa0 cmd?
                    //high word 0 = a success indication?
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0x9a:
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                default: //unknown data (should use 0 or -1 as default), usually returning 0 might cause the game to think there is something wrong with the connection (ie. 0x11/0x13 cmd)
                    //0x0173 //not 0x0000 as default?
                    //0x0000
                    //rfu_buf = 0xffffffff; //rfu_masterdata[rfu_counter++];
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;
                }
                break;
            }
            transfer_direction = RECEIVING;

            PrevVAL = value;
            PrevDAT = CurDAT;
            PrevCOM = CurCOM;
        }

        if (rfu_polarity)
            value ^= 4; // sometimes it's the other way around
        [[fallthrough]];
    default:
        UPDATE_REG(COMM_SIOCNT, value);
        return;
    }
}

bool LinkRFUUpdateSocket()
{
    if (rfu_enabled) {
        if (transfer_direction == RECEIVING && rfu_transfer_end <= 0) {
            if (rfu_waiting) {
                if (rfu_state != RFU_INIT) {
                    if (rfu_cmd == 0x24 || rfu_cmd == 0x25 || rfu_cmd == 0x35) {
                        if (rfu_data.rfu_q[linkid] < 2 || rfu_qsend > 1) {
                            rfu_cansend = true;
                            rfu_data.rfu_q[linkid] = 0;
                            rfu_data.rfu_qid[linkid] = 0;
                        }
                        rfu_buf = 0x80000000;
                    } else {
                        if (rfu_cmd == 0xa5 || rfu_cmd == 0xa7 || rfu_cmd == 0xb5 || rfu_cmd == 0xb7 || rfu_cmd == 0xee)
                            rfu_polarity = 1;
                        if (rfu_cmd == 0xa5 || rfu_cmd == 0xa7)
                            rfu_cmd = 0x28;
                        else if (rfu_cmd == 0xb5 || rfu_cmd == 0xb7)
                            rfu_cmd = 0x36;

                        if (READ32LE(&g_ioMem[COMM_SIODATA32_L]) == 0x80000000)
                            rfu_buf = 0x99660000 | (rfu_qrecv_broadcast_data_len << 8) | rfu_cmd;
                        else
                            rfu_buf = 0x80000000;
                    }
                    rfu_waiting = false;
                }
            }
            UPDATE_REG(COMM_SIODATA32_L, (uint16_t)rfu_buf);
            UPDATE_REG(COMM_SIODATA32_H, rfu_buf >> 16);
        }
    }
    return true;
}

static void UpdateRFUSocket(int ticks)
{
    rfu_last_broadcast_time -= ticks;

    if (rfu_last_broadcast_time < 0) {
        if (linkid == 0) {
            linktime = 0;
            rfu_server.Recv(); // recv broadcast data
            (void)rfu_server.Send(); // send broadcast data
        } else {
            (void)rfu_client.Send(); // send broadcast data
            rfu_client.Recv(); // recv broadcast data
        }
        {
            const int max_clients = MAX_CLIENTS > 5 ? 5 : MAX_CLIENTS;
            for (int i = 0; i < max_clients; i++) {
                if (i != linkid) {
                    rfu_data.rfu_listback[i] = 0; // Flush the queue
                }
            }
        }
        rfu_transfer_end = 0;

        if (rfu_last_broadcast_time < 0)
            rfu_last_broadcast_time = 3000;
        //rfu_last_broadcast_time = 5600; // Upper physical limit of 5600? 3000 packets/sec
    }

    if (rfu_enabled) {
        if (LinkRFUUpdateSocket()) {
            if (transfer_direction == RECEIVING && rfu_transfer_end <= 0) {
                transfer_direction = SENDING;
                uint16_t value = READ16LE(&g_ioMem[COMM_SIOCNT]);
                if (value & SIO_IRQ_ENABLE) {
                    IF |= 0x80;
                    UPDATE_REG(IO_REG_IF, IF);
                }

                //if (rfu_polarity) value ^= 4;
                value &= ~SIO_TRANS_FLAG_RECV_ENABLE;
                value |= (value & 1) << 2; //this will automatically set the correct polarity, even w/o rfu_polarity since the game will be the one who change the polarity instead of the adapter

                UPDATE_REG(COMM_SIOCNT, (value & ~SIO_TRANS_START) | SIO_TRANS_FLAG_SEND_DISABLE); //Start bit.7 reset, SO bit.3 set automatically upon transfer completion?
            }
            return;
        }
    }
}

void gbInitLink()
{
    if (GetLinkMode() == LINK_GAMEBOY_IPC) {
#if (defined __WIN32__ || defined _WIN32)
        gbInitLinkIPC();
#endif
    } else {
        LinkIsWaiting = false;
        LinkFirstTime = true;
    }
}

uint8_t gbStartLink(uint8_t b) //used on internal clock
{
    uint8_t dat = 0xff; //master (w/ internal clock) will gets 0xff if slave is turned off (or not ready yet also?)
    //if(linkid) return 0xff; //b; //Slave shouldn't be sending from here
    //int gbSerialOn = (gbMemory[0xff02] & 0x80); //not needed?
    gba_link_enabled = true; //(gbMemory[0xff02]!=0); //not needed?
    rfu_enabled = false;

    if (!gba_link_enabled)
        return 0xff;

    //Single Computer
    if (GetLinkMode() == LINK_GAMEBOY_IPC) {
#if (defined __WIN32__ || defined _WIN32)
        dat = gbStartLinkIPC(b);
#endif
    } else {
        if (lanlink.numslaves == 1) {
            if (lanlink.server) {
                cable_gb_data[0] = b;
                ls.SendGB();

                if (ls.RecvGB())
                    dat = cable_gb_data[1];
            } else {
                cable_gb_data[1] = b;
                lc.SendGB();

                if (lc.RecvGB())
                    dat = cable_gb_data[0];
            }

            LinkIsWaiting = false;
            LinkFirstTime = true;
            if (dat != 0xff /*||b==0x00||dat==0x00*/)
                LinkFirstTime = false;
        }
    }
    return dat;
}

uint16_t gbLinkUpdate(uint8_t b, int gbSerialOn) //used on external clock
{
    uint8_t dat = b; //0xff; //slave (w/ external clocks) won't be getting 0xff if master turned off
    uint8_t recvd = 0;

    gba_link_enabled = true; //(gbMemory[0xff02]!=0);
    rfu_enabled = false;

    if (gbSerialOn) {
        if (gba_link_enabled) {
            //Single Computer
            if (GetLinkMode() == LINK_GAMEBOY_IPC) {
#if (defined __WIN32__ || defined _WIN32)
                return gbLinkUpdateIPC(b, gbSerialOn);
#endif
            } else {
                if (lanlink.numslaves == 1) {
                    if (lanlink.server) {
                        recvd = ls.RecvGB() ? 1 : 0;
                        if (recvd) {
                            dat = cable_gb_data[1];
                            LinkIsWaiting = false;
                        } else
                            LinkIsWaiting = true;

                        if (!LinkIsWaiting) {
                            cable_gb_data[0] = b;
                            ls.SendGB();
                        }
                    } else {
                        recvd = lc.RecvGB() ? 1 : 0;
                        if (recvd) {
                            dat = cable_gb_data[0];
                            LinkIsWaiting = false;
                        } else
                            LinkIsWaiting = true;

                        if (!LinkIsWaiting) {
                            cable_gb_data[1] = b;
                            lc.SendGB();
                        }
                    }
                }
            }
	}
        if (dat == 0xff /*||dat==0x00||b==0x00*/) //dat==0xff||dat==0x00
            LinkFirstTime = true;
    }
    return ((dat << 8) | (recvd & (uint8_t)0xff));
}

#if (defined __WIN32__ || defined _WIN32)

static ConnectionState InitIPC()
{
    linkid = 0;

#if (defined __WIN32__ || defined _WIN32)
    if ((mmf = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(LINKDATA), LOCAL_LINK_NAME)) == NULL) {
        systemMessage(0, N_("Error creating file mapping"));
        return LINK_ERROR;
    }

    if (GetLastError() == ERROR_ALREADY_EXISTS)
        vbaid = 1;
    else
        vbaid = 0;

    if ((linkmem = (LINKDATA*)MapViewOfFile(mmf, FILE_MAP_WRITE, 0, 0, sizeof(LINKDATA))) == NULL) {
        CloseHandle(mmf);
        systemMessage(0, N_("Error mapping file"));
        return LINK_ERROR;
    }
#else
    if ((mmf = shm_open("/" LOCAL_LINK_NAME, O_RDWR | O_CREAT | O_EXCL, 0777)) < 0) {
        vbaid = 1;
        mmf = shm_open("/" LOCAL_LINK_NAME, O_RDWR, 0);
    } else
        vbaid = 0;
    if (mmf < 0 || ftruncate(mmf, sizeof(LINKDATA)) < 0 || !(linkmem = (LINKDATA*)mmap(NULL, sizeof(LINKDATA), PROT_READ | PROT_WRITE, MAP_SHARED, mmf, 0))) {
        systemMessage(0, N_("Error creating file mapping"));
        if (mmf) {
            if (!vbaid)
                shm_unlink("/" LOCAL_LINK_NAME);
            close(mmf);
        }
    }
#endif

    // get lowest-numbered available machine slot
    bool firstone = !vbaid;
    if (firstone) {
        linkmem->linkflags = 1;
        linkmem->numgbas = 1;
        linkmem->numtransfers = 0;
        for (int i = 0; i < 4; i++)
            linkmem->linkdata[i] = 0xffff;
    } else {
        // FIXME: this should be done while linkmem is locked
        // (no xfer in progress, no other vba trying to connect)
        int n = linkmem->numgbas;
        int f = linkmem->linkflags;
        for (int i = 0; i <= n; i++)
            if (!(f & (1 << i))) {
                vbaid = i;
                break;
            }
        if (vbaid == 4) {
#if (defined __WIN32__ || defined _WIN32)
            UnmapViewOfFile(linkmem);
            CloseHandle(mmf);
#else
            munmap(linkmem, sizeof(LINKDATA));
            if (!vbaid)
                shm_unlink("/" LOCAL_LINK_NAME);
            close(mmf);
#endif
            systemMessage(0, N_("5 or more GBAs not supported."));
            return LINK_ERROR;
        }
        if (vbaid == n)
            linkmem->numgbas = (uint8_t)(n + 1);
        linkmem->linkflags = (uint8_t)(f | (1 << vbaid));
    }
    linkid = (uint16_t)vbaid;

    for (int i = 0; i < 4; i++) {
        linkevent[sizeof(linkevent) - 2] = (char)i + '1';
#if (defined __WIN32__ || defined _WIN32)
        linksync[i] = firstone ? CreateSemaphoreA(NULL, 0, 4, linkevent) : OpenSemaphoreA(SEMAPHORE_ALL_ACCESS, false, linkevent);
        if (linksync[i] == NULL) {
            UnmapViewOfFile(linkmem);
            CloseHandle(mmf);
            for (int j = 0; j < i; j++) {
                CloseHandle(linksync[j]);
            }
            systemMessage(0, N_("Error opening event"));
            return LINK_ERROR;
        }
#else
        if ((linksync[i] = sem_open(linkevent,
                 firstone ? O_CREAT | O_EXCL : 0,
                 0777, 0))
            == SEM_FAILED) {
            if (firstone)
                shm_unlink("/" LOCAL_LINK_NAME);
            munmap(linkmem, sizeof(LINKDATA));
            close(mmf);
            for (j = 0; j < i; j++) {
                sem_close(linksync[i]);
                if (firstone) {
                    linkevent[sizeof(linkevent) - 2] = (char)i + '1';
                    sem_unlink(linkevent);
                }
            }
            systemMessage(0, N_("Error opening event"));
            return LINK_ERROR;
        }
#endif
    }

    return LINK_OK;
}

static void StartCableIPC(uint16_t value)
{
    switch (GetSIOMode(value, READ16LE(&g_ioMem[COMM_RCNT]))) {
    case MULTIPLAYER: {
        bool start = (value & 0x80) && !linkid && !transfer_direction;
        // clear start, seqno, si (RO on slave, start = pulse on master)
        value &= 0xff4b;
        // get current si.  This way, on slaves, it is low during xfer
        if (linkid) {
            if (!transfer_direction)
                value |= 4;
            else
                value |= READ16LE(&g_ioMem[COMM_SIOCNT]) & 4;
        }
        if (start) {
            if (linkmem->numgbas > 1) {
                // find first active attached GBA
                // doing this first reduces the potential
                // race window size for new connections
                int n = linkmem->numgbas + 1;
                int f = linkmem->linkflags;
                int m;
                do {
                    n--;
                    m = (1 << n) - 1;
                } while ((f & m) != m);
                linkmem->trgbas = (uint8_t)n;

                // before starting xfer, make pathetic attempt
                // at clearing out any previous stuck xfer
                // this will fail if a slave was stuck for
                // too long
                for (int i = 0; i < 4; i++)
                    while (WaitForSingleObject(linksync[i], 0) != WAIT_TIMEOUT)
                        ;

                // transmit first value
                linkmem->linkcmd[0] = ('M' << 8) + (value & 3);
                linkmem->linkdata[0] = READ16LE(&g_ioMem[COMM_SIODATA8]);

                // start up slaves & sync clocks
                numtransfers = linkmem->numtransfers;
                if (numtransfers != 0)
                    linkmem->lastlinktime = linktime;
                else
                    linkmem->lastlinktime = 0;

                if ((++numtransfers) == 0)
                    linkmem->numtransfers = 2;
                else
                    linkmem->numtransfers = numtransfers;

                transfer_direction = 1;
                linktime = 0;
                tspeed = value & 3;
                WRITE32LE(&g_ioMem[COMM_SIOMULTI0], 0xffffffff);
                WRITE32LE(&g_ioMem[COMM_SIOMULTI2], 0xffffffff);
                value &= ~0x40;
            } else {
                value |= 0x40; // comm error
            }
        }
        value |= (transfer_direction != 0) << 7;
        value |= (linkid && !transfer_direction ? 0xc : 8); // set SD (high), SI (low on master)
        value |= linkid << 4; // set seq
        UPDATE_REG(COMM_SIOCNT, value);
        if (linkid)
            // SC low -> transfer in progress
            // not sure why SO is low
            UPDATE_REG(COMM_RCNT, transfer_direction ? 6 : 7);
        else
            // SI is always low on master
            // SO, SC always low during transfer
            // not sure why SO low otherwise
            UPDATE_REG(COMM_RCNT, transfer_direction ? 2 : 3);
        break;
    }
    case NORMAL8:
    case NORMAL32:
    case UART:
    default:
        UPDATE_REG(COMM_SIOCNT, value);
        break;
    }
}

static void ReconnectCableIPC()
{
    int f = linkmem->linkflags;
    int n = linkmem->numgbas;
    if (f & (1 << linkid)) {
        systemMessage(0, N_("Lost link; reinitialize to reconnect"));
        return;
    }
    linkmem->linkflags |= 1 << linkid;
    if (n < linkid + 1)
        linkmem->numgbas = (uint8_t)(linkid + 1);
    numtransfers = linkmem->numtransfers;
    systemScreenMessage(_("Lost link; reconnected"));
}

static void UpdateCableIPC(int)
{
    if (((READ16LE(&g_ioMem[COMM_RCNT])) >> 14) == 3)
        return;

    // slave startup depends on detecting change in numtransfers
    // and syncing clock with master (after first transfer)
    // this will fail if > ~2 minutes have passed since last transfer due
    // to integer overflow
    if (!transfer_direction && numtransfers && linktime < 0) {
        linktime = 0;
        // there is a very, very, small chance that this will abort
        // a transfer that was just started
        linkmem->numtransfers = numtransfers = 0;
    }
    if (linkid && !transfer_direction && linktime >= linkmem->lastlinktime && linkmem->numtransfers != numtransfers) {
        numtransfers = linkmem->numtransfers;
        if (!numtransfers)
            return;

        // if this or any previous machine was dropped, no transfer
        // can take place
        if (linkmem->trgbas <= linkid) {
            transfer_direction = 0;
            numtransfers = 0;
            // if this is the one that was dropped, reconnect
            if (!(linkmem->linkflags & (1 << linkid)))
                ReconnectCableIPC();
            return;
        }

        // sync clock
        if (numtransfers == 1)
            linktime = 0;
        else
            linktime -= linkmem->lastlinktime;

// there's really no point to this switch; 'M' is the only
// possible command.
#if 0
		switch ((linkmem->linkcmd) >> 8)
		{
		case 'M':
#endif
        tspeed = linkmem->linkcmd[0] & 3;
        transfer_direction = 1;
        WRITE32LE(&g_ioMem[COMM_SIOMULTI0], 0xffffffff);
        WRITE32LE(&g_ioMem[COMM_SIOMULTI2], 0xffffffff);
        UPDATE_REG(COMM_SIOCNT, (READ16LE(&g_ioMem[COMM_SIOCNT]) & ~0x40) | 0x80);
#if 0
			break;
		}
#endif
    }

    if (!transfer_direction)
        return;

    if (transfer_direction <= linkmem->trgbas && linktime >= trtimedata[transfer_direction - 1][tspeed]) {
        // transfer #n -> wait for value n - 1
        if (transfer_direction > 1 && linkid != transfer_direction - 1) {
            if (WaitForSingleObject(linksync[transfer_direction - 1], linktimeout) == WAIT_TIMEOUT) {
                // assume slave has dropped off if timed out
                if (!linkid) {
                    linkmem->trgbas = (uint8_t)(transfer_direction - 1);
                    int f = linkmem->linkflags;
                    f &= ~(1 << (transfer_direction - 1));
                    linkmem->linkflags = (uint8_t)f;
                    if (f < (1 << transfer_direction) - 1)
                        linkmem->numgbas = (uint8_t)(transfer_direction - 1);
                    char message[30];
                    snprintf(message, sizeof(message), _("Player %d disconnected."), transfer_direction - 1);
                    systemScreenMessage(message);
                }
                transfer_direction = linkmem->trgbas + 1;
                // next cycle, transfer will finish up
                return;
            }
        }
        // now that value is available, store it
        UPDATE_REG((COMM_SIOMULTI0 - 2) + (transfer_direction << 1), linkmem->linkdata[transfer_direction - 1]);

        // transfer machine's value at start of its transfer cycle
        if (linkid == transfer_direction) {
            // skip if dropped
            if (linkmem->trgbas <= linkid) {
                transfer_direction = 0;
                numtransfers = 0;
                // if this is the one that was dropped, reconnect
                if (!(linkmem->linkflags & (1 << linkid)))
                    ReconnectCableIPC();
                return;
            }
            // SI becomes low
            UPDATE_REG(COMM_SIOCNT, READ16LE(&g_ioMem[COMM_SIOCNT]) & ~4);
            UPDATE_REG(COMM_RCNT, 10);
            linkmem->linkdata[linkid] = READ16LE(&g_ioMem[COMM_SIODATA8]);
            ReleaseSemaphore(linksync[linkid], linkmem->numgbas - 1, NULL);
        }
        if (linkid == transfer_direction - 1) {
            // SO becomes low to begin next trasnfer
            // may need to set DDR as well
            UPDATE_REG(COMM_RCNT, 0x22);
        }

        // next cycle
        transfer_direction = !transfer_direction;
    }

    if (transfer_direction > linkmem->trgbas && linktime >= trtimeend[transfer_direction - 3][tspeed]) {
        // wait for slaves to finish
        // this keeps unfinished slaves from screwing up last xfer
        // not strictly necessary; may just slow things down
        if (!linkid) {
            for (int i = 2; i < transfer_direction; i++)
                if (WaitForSingleObject(linksync[0], linktimeout) == WAIT_TIMEOUT) {
                    // impossible to determine which slave died
                    // so leave them alone for now
                    systemScreenMessage(_("Unknown slave timed out; resetting comm"));
                    linkmem->numtransfers = numtransfers = 0;
                    break;
                }
        } else if (linkmem->trgbas > linkid)
            // signal master that this slave is finished
            ReleaseSemaphore(linksync[0], 1, NULL);
        linktime -= trtimeend[transfer_direction - 3][tspeed];
        transfer_direction = 0;
        uint16_t value = READ16LE(&g_ioMem[COMM_SIOCNT]);
        if (!linkid)
            value |= 4; // SI becomes high on slaves after xfer
        UPDATE_REG(COMM_SIOCNT, (value & 0xff0f) | (linkid << 4));
        // SC/SI high after transfer
        UPDATE_REG(COMM_RCNT, linkid ? 15 : 11);
        if (value & 0x4000) {
            IF |= 0x80;
            UPDATE_REG(IO_REG_IF, IF);
        }
    }
}

// The GBA wireless RFU (see adapter3.txt)
static void StartRFU(uint16_t value)
{
    int siomode = GetSIOMode(value, READ16LE(&g_ioMem[COMM_RCNT]));

    if (value)
        rfu_enabled = (siomode == NORMAL32);

    if (((READ16LE(&g_ioMem[COMM_SIOCNT]) & 0x5080) == 0x1000) && ((value & 0x5080) == 0x5080)) { //RFU Reset, may also occur before cable link started
        log("RFU Reset2 : %04X  %04X  %d\n", READ16LE(&g_ioMem[COMM_RCNT]), READ16LE(&g_ioMem[COMM_SIOCNT]), GetTickCount());
        linkmem->rfu_listfront[vbaid] = 0;
        linkmem->rfu_listback[vbaid] = 0;
    }

    if (!rfu_enabled) {
        if ((value & 0x5080) == 0x5080) { //0x5083 //game tried to send wireless command but w/o the adapter
            /*if (value & 8) //Transfer Enable Flag Send (bit.3, 1=Disable Transfer/Not Ready)
			value &= 0xfffb; //Transfer enable flag receive (0=Enable Transfer/Ready, bit.2=bit.3 of otherside)	// A kind of acknowledge procedure
			else //(Bit.3, 0=Enable Transfer/Ready)
			value |= 4; //bit.2=1 (otherside is Not Ready)*/
            if (READ16LE(&g_ioMem[COMM_SIOCNT]) & 0x4000) //IRQ Enable
            {
                IF |= 0x80; //Serial Communication
                UPDATE_REG(IO_REG_IF, IF); //Interrupt Request Flags / IRQ Acknowledge
            }
            value &= 0xff7f; //Start bit.7 reset //may cause the game to retry sending again
            //value |= 0x0008; //SO bit.3 set automatically upon transfer completion
            transfer_direction = 0;
        }
        return;
    }

    linktimeout = 1;

    uint32_t CurCOM = 0, CurDAT = 0;
    // bool rfulogd = (READ16LE(&g_ioMem[COMM_SIOCNT]) != value);

    switch (GetSIOMode(value, READ16LE(&g_ioMem[COMM_RCNT]))) {
    case NORMAL8:
        rfu_polarity = 0;
        UPDATE_REG(COMM_SIOCNT, value);
        return;
        break;
    case NORMAL32:
        //don't do anything if previous cmd aren't sent yet, may fix Boktai2 Not Detecting wireless adapter
        if (transfer_direction) {
            UPDATE_REG(COMM_SIOCNT, value);
            return;
        }

        //Moving this to the bottom might prevent Mario Golf Adv from Occasionally Not Detecting wireless adapter
        if (value & 8) //Transfer Enable Flag Send (SO.bit.3, 1=Disable Transfer/Not Ready)
            value &= 0xfffb; //Transfer enable flag receive (0=Enable Transfer/Ready, SI.bit.2=SO.bit.3 of otherside)	// A kind of acknowledge procedure
        else //(SO.Bit.3, 0=Enable Transfer/Ready)
            value |= 4; //SI.bit.2=1 (otherside is Not Ready)

        if ((value & 5) == 1)
            value |= 0x02; //wireless always use 2Mhz speed right? this will fix MarioGolfAdv Not Detecting wireless

        if (value & 0x80) //start/busy bit
        {
            if ((value & 3) == 1)
                rfu_transfer_end = 2048;
            else
                rfu_transfer_end = 256;
            uint16_t siodata_h = READ16LE(&g_ioMem[COMM_SIODATA32_H]);
            switch (rfu_state) {
            case RFU_INIT:
                if (READ32LE(&g_ioMem[COMM_SIODATA32_L]) == 0xb0bb8001) {
                    rfu_state = RFU_COMM; // end of startup
                    rfu_initialized = true;
                    value &= 0xfffb; //0xff7b; //Bit.2 need to be 0 to indicate a finished initialization to fix MarioGolfAdv from occasionally Not Detecting wireless adapter (prevent it from sending 0x7FFE8001 comm)?
                    rfu_polarity = 0; //not needed?
                }
                rfu_buf = (READ16LE(&g_ioMem[COMM_SIODATA32_L]) << 16) | siodata_h;
                break;
            case RFU_COMM:
                CurCOM = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                if (siodata_h == 0x9966) //initialize cmd
                {
                    uint8_t tmpcmd = (uint8_t)CurCOM;
                    if (tmpcmd != 0x10 && tmpcmd != 0x11 && tmpcmd != 0x13 && tmpcmd != 0x14 && tmpcmd != 0x16 && tmpcmd != 0x17 && tmpcmd != 0x19 && tmpcmd != 0x1a && tmpcmd != 0x1b && tmpcmd != 0x1c && tmpcmd != 0x1d && tmpcmd != 0x1e && tmpcmd != 0x1f && tmpcmd != 0x20 && tmpcmd != 0x21 && tmpcmd != 0x24 && tmpcmd != 0x25 && tmpcmd != 0x26 && tmpcmd != 0x27 && tmpcmd != 0x30 && tmpcmd != 0x32 && tmpcmd != 0x33 && tmpcmd != 0x34 && tmpcmd != 0x3d && tmpcmd != 0xa8 && tmpcmd != 0xee) {
                        log("%08X : UnkCMD %08X  %04X  %08X %08X\n", GetTickCount(), CurCOM, PrevVAL, PrevCOM, PrevDAT);
                    }
                    rfu_counter = 0;
                    if ((rfu_qsend2 = rfu_qsend = g_ioMem[0x121]) != 0) { //COMM_SIODATA32_L+1, following data [to send]
                        rfu_state = RFU_SEND;
                    }
                    if (g_ioMem[COMM_SIODATA32_L] == 0xee) { //0xee cmd shouldn't override previous cmd
                        rfu_lastcmd = rfu_cmd2;
                        rfu_cmd2 = g_ioMem[COMM_SIODATA32_L];
                        //rfu_polarity = 0; //when polarity back to normal the game can initiate a new cmd even when 0xee hasn't been finalized, but it looks improper isn't?
                    } else {
                        rfu_lastcmd = rfu_cmd;
                        rfu_cmd = g_ioMem[COMM_SIODATA32_L];
                        rfu_cmd2 = 0;
                        if (rfu_cmd == 0x27 || rfu_cmd == 0x37) {
                            rfu_lastcmd2 = rfu_cmd;
                            rfu_lasttime = GetTickCount();
                        } else if (rfu_cmd == 0x24) { //non-important data shouldn't overwrite important data from 0x25
                            rfu_lastcmd2 = rfu_cmd;
                            rfu_cansend = false;
                            //previous important data need to be received successfully before sending another important data
                            rfu_lasttime = GetTickCount(); //just to mark the last time a data being sent
                            if (!speedhack) {
                                while (linkmem->numgbas >= 2 && linkmem->rfu_q[vbaid] > 1 && vbaid != gbaid && linkmem->rfu_signal[vbaid] && linkmem->rfu_signal[gbaid] && (GetTickCount() - rfu_lasttime) < (DWORD)linktimeout) {
                                    if (!rfu_ishost)
                                        SetEvent(linksync[gbaid]);
                                    else //unlock other gba, allow other gba to move (sending their data)  //is max value of vbaid=1 ?
                                        for (int j = 0; j < linkmem->numgbas; j++)
                                            if (j != vbaid)
                                                SetEvent(linksync[j]);
                                    WaitForSingleObject(linksync[vbaid], 1); //linktimeout //wait until this gba allowed to move (to prevent both GBAs from using 0x25 at the same time)
                                    ResetEvent(linksync[vbaid]); //lock this gba, don't allow this gba to move (prevent sending another data too fast w/o giving the other side chances to read it)
                                    if (!rfu_ishost && linkmem->rfu_is_host[vbaid]) {
                                        linkmem->rfu_is_host[vbaid] = 0;
                                        break;
                                    } //workaround for a bug where rfu_request failed to reset when GBA act as client
                                }
                            }
                            //SetEvent(linksync[vbaid]); //set again to reduce the lag since it will be waited again during finalization cmd
                            else {
                                if (linkmem->numgbas >= 2 && gbaid != vbaid && linkmem->rfu_q[vbaid] > 1 && linkmem->rfu_signal[vbaid] && linkmem->rfu_signal[gbaid]) {
                                    if (!rfu_ishost)
                                        SetEvent(linksync[gbaid]);
                                    else //unlock other gba, allow other gba to move (sending their data)  //is max value of vbaid=1 ?
                                        for (int j = 0; j < linkmem->numgbas; j++)
                                            if (j != vbaid)
                                                SetEvent(linksync[j]);
                                    WaitForSingleObject(linksync[vbaid], speedhack ? 1 : linktimeout); //wait until this gba allowed to move
                                    ResetEvent(linksync[vbaid]); //lock this gba, don't allow this gba to move (prevent sending another data too fast w/o giving the other side chances to read it)
                                }
                            }
                            if (linkmem->rfu_q[vbaid] < 2) { //can overwrite now
                                rfu_cansend = true;
                                linkmem->rfu_q[vbaid] = 0; //rfu_qsend;
                                linkmem->rfu_qid[vbaid] = 0;
                            } else if (!speedhack)
                                rfu_waiting = true; //don't wait with speedhack
                        } else if (rfu_cmd == 0x25 || rfu_cmd == 0x35) {
                            rfu_lastcmd2 = rfu_cmd;
                            rfu_cansend = false;
                            //previous important data need to be received successfully before sending another important data
                            rfu_lasttime = GetTickCount();
                            if (!speedhack) {
                                //2 players connected
                                while (linkmem->numgbas >= 2 && linkmem->rfu_q[vbaid] > 1 && vbaid != gbaid && linkmem->rfu_signal[vbaid] && linkmem->rfu_signal[gbaid] && (GetTickCount() - rfu_lasttime) < (DWORD)linktimeout) {
                                    if (!rfu_ishost)
                                        SetEvent(linksync[gbaid]); //unlock other gba, allow other gba to move (sending their data)  //is max value of vbaid=1 ?
                                    else
                                        for (int j = 0; j < linkmem->numgbas; j++)
                                            if (j != vbaid)
                                                SetEvent(linksync[j]);
                                    WaitForSingleObject(linksync[vbaid], 1); //linktimeout //wait until this gba allowed to move (to prevent both GBAs from using 0x25 at the same time)
                                    ResetEvent(linksync[vbaid]); //lock this gba, don't allow this gba to move (prevent sending another data too fast w/o giving the other side chances to read it)
                                    if (!rfu_ishost && linkmem->rfu_is_host[vbaid]) {
                                        linkmem->rfu_is_host[vbaid] = 0;
                                        break;
                                    } //workaround for a bug where rfu_request failed to reset when GBA act as client
                                }
                            }
                            //SetEvent(linksync[vbaid]); //set again to reduce the lag since it will be waited again during finalization cmd
                            else {
                                //2 players connected
                                if (linkmem->numgbas >= 2 && gbaid != vbaid && linkmem->rfu_q[vbaid] > 1 && linkmem->rfu_signal[vbaid] && linkmem->rfu_signal[gbaid]) {
                                    if (!rfu_ishost)
                                        SetEvent(linksync[gbaid]);
                                    else //unlock other gba, allow other gba to move (sending their data)  //is max value of vbaid=1 ?
                                        for (int j = 0; j < linkmem->numgbas; j++)
                                            if (j != vbaid)
                                                SetEvent(linksync[j]);
                                    WaitForSingleObject(linksync[vbaid], speedhack ? 1 : linktimeout); //wait until this gba allowed to move
                                    ResetEvent(linksync[vbaid]); //lock this gba, don't allow this gba to move (prevent sending another data too fast w/o giving the other side chances to read it)
                                }
                            }
                            if (linkmem->rfu_q[vbaid] < 2) {
                                rfu_cansend = true;
                                linkmem->rfu_q[vbaid] = 0; //rfu_qsend;
                                linkmem->rfu_qid[vbaid] = 0; //don't wait with speedhack
                            } else if (!speedhack)
                                rfu_waiting = true;
                        } else if (rfu_cmd == 0xa8 || rfu_cmd == 0xb6) {
                            //wait for [important] data when previously sent is important data, might only need to wait for the 1st 0x25 cmd
                            // bool ok = false;
                        } else if (rfu_cmd == 0x11 || rfu_cmd == 0x1a || rfu_cmd == 0x26) {
                            if (rfu_lastcmd2 == 0x24)
                                rfu_waiting = true;
                        }
                    }
                    if (rfu_waiting)
                        rfu_buf = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    else
                        rfu_buf = 0x80000000;
                } else if (siodata_h == 0x8000) //finalize cmd, the game will send this when polarity reversed (expecting something)
                {
                    rfu_qrecv_broadcast_data_len = 0;
                    if (rfu_cmd2 == 0xee) {
                        if (rfu_masterdata[0] == 2) //is this value of 2 related to polarity?
                            rfu_polarity = 0; //to normalize polarity after finalize looks more proper
                        rfu_buf = 0x99660000 | (rfu_qrecv_broadcast_data_len << 8) | (rfu_cmd2 ^ 0x80);
                    } else {
                        switch (rfu_cmd) {
                        case 0x1a: // check if someone joined
                            if (linkmem->rfu_is_host[vbaid]) {
                                gbaidx = gbaid;
                                do {
                                    gbaidx = (gbaidx + 1) % linkmem->numgbas;
                                    if (gbaidx != vbaid && linkmem->rfu_reqid[gbaidx] == (vbaid << 3) + 0x61f1)
                                        rfu_masterdata[rfu_qrecv_broadcast_data_len++] = (gbaidx << 3) + 0x61f1;
                                    log("qrecv++ %d\n", rfu_qrecv_broadcast_data_len);
                                } while (gbaidx != gbaid && linkmem->numgbas >= 2);
                                if (rfu_qrecv_broadcast_data_len > 0) {
                                    bool ok = false;
                                    for (int i = 0; i < rfu_numclients; i++)
                                        if ((rfu_clientlist[i] & 0xffff) == rfu_masterdata[0]) {
                                            ok = true;
                                            break;
                                        }
                                    if (!ok) {
                                        rfu_curclient = rfu_numclients;
                                        linkmem->rfu_clientidx[(rfu_masterdata[0] - 0x61f1) >> 3] = rfu_numclients;
                                        rfu_clientlist[rfu_numclients] = rfu_masterdata[0] | (rfu_numclients << 16);
                                        rfu_numclients++;
                                        gbaid = (rfu_masterdata[0] - 0x61f1) >> 3;
                                        linkmem->rfu_signal[gbaid] = 0xffffffff >> ((3 - (rfu_numclients - 1)) << 3);
                                    }
                                    if (gbaid == vbaid) {
                                        gbaid = (rfu_masterdata[0] - 0x61f1) >> 3;
                                    }
                                    rfu_state = RFU_RECV;
                                }
                            }
                            if (rfu_numclients > 0) {
                                for (int i = 0; i < rfu_numclients; i++)
                                    rfu_masterdata[i] = rfu_clientlist[i];
                            }
                            rfu_id = (uint16_t)((gbaid << 3) + 0x61f1);
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x1f: // join a room as client
                            // TODO: to fix infinte send&recv w/o giving much cance to update the screen when both side acting as client
                            // on MarioGolfAdv lobby(might be due to leftover data when switching from host to join mode at the same time?)
                            rfu_id = (uint16_t)rfu_masterdata[0];
                            gbaid = (rfu_id - 0x61f1) >> 3;
                            rfu_idx = rfu_id;
                            gbaidx = gbaid;
                            rfu_lastcmd2 = 0;
                            numtransfers = 0;
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            linkmem->rfu_reqid[vbaid] = rfu_id;
                            // TODO:might failed to reset rfu_request when being accessed by otherside at the same time, sometimes both acting
                            // as client but one of them still have request[vbaid]!=0 //to prevent both GBAs from acting as Host, client can't
                            // be a host at the same time
                            linkmem->rfu_is_host[vbaid] = 0;
                            if (vbaid != gbaid) {
                                linkmem->rfu_signal[vbaid] = 0x00ff;
                                linkmem->rfu_is_host[gbaid] |= 1 << vbaid; // tells the other GBA(a host) that someone(a client) is joining
                            }
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x1e: // receive broadcast data
                            numtransfers = 0;
                            rfu_numclients = 0;
                            linkmem->rfu_is_host[vbaid] = 0; //to prevent both GBAs from acting as Host and thinking both of them have Client?
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            [[fallthrough]];
                        case 0x1d: // no visible difference
                            linkmem->rfu_is_host[vbaid] = 0;
                            memset(rfu_masterdata, 0, sizeof(linkmem->rfu_broadcastdata[vbaid]));
                            rfu_qrecv_broadcast_data_len = 0;
                            for (int i = 0; i < linkmem->numgbas; i++) {
                                if (i != vbaid && linkmem->rfu_broadcastdata[i][0]) {
                                    memcpy(&rfu_masterdata[rfu_qrecv_broadcast_data_len], linkmem->rfu_broadcastdata[i], sizeof(linkmem->rfu_broadcastdata[i]));
                                    rfu_qrecv_broadcast_data_len += 7;
                                }
                            }
                            // is this needed? to prevent MarioGolfAdv from joining it's own room when switching
                            // from host to client mode due to left over room data in the game buffer?
                            // if(rfu_qrecv==0) rfu_qrecv = 7;
                            if (rfu_qrecv_broadcast_data_len > 0)
                                rfu_state = RFU_RECV;
                            rfu_polarity = 0;
                            rfu_counter = 0;
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x16: // send broadcast data (ie. room name)
                            //start broadcasting here may cause client to join other client in pokemon coloseum
                            //linkmem->rfu_bdata[vbaid][0] = (vbaid<<3)+0x61f1;
                            //linkmem->rfu_q[vbaid] = 0;
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x11: // get signal strength
                            //Switch remote id
                            if (linkmem->rfu_is_host[vbaid]) { //is a host
                                /*//gbaid = 1-vbaid; //linkmem->rfu_request[vbaid] & 1;
								gbaidx = gbaid;
								do {
								gbaidx = (gbaidx+1) % linkmem->numgbas;
								} while (gbaidx!=gbaid && linkmem->numgbas>=2 && (linkmem->rfu_reqid[gbaidx]!=(vbaid<<3)+0x61f1 || linkmem->rfu_q[gbaidx]<=0));
								if (gbaidx!=vbaid) {
								gbaid = gbaidx;
								rfu_id = (gbaid<<3)+0x61f1;
								}*/
                                /*if(rfu_numclients>0) {
								rfu_curclient = (rfu_curclient+1) % rfu_numclients;
								rfu_id = rfu_clientlist[rfu_curclient];
								gbaid = (rfu_id-0x61f1)>>3;
								}*/
                            }
                            //check signal
                            if (linkmem->numgbas >= 2 && (linkmem->rfu_is_host[vbaid] | linkmem->rfu_is_host[gbaid])) //signal only good when connected
                                if (rfu_ishost) { //update, just incase there are leaving clients
                                    uint8_t rfureq = linkmem->rfu_is_host[vbaid];
                                    uint8_t oldnum = rfu_numclients;
                                    rfu_numclients = 0;
                                    for (int i = 0; i < 8; i++) {
                                        if (rfureq & 1)
                                            rfu_numclients++;
                                        rfureq >>= 1;
                                    }
                                    if (rfu_numclients > oldnum)
                                        rfu_numclients = oldnum; //must not be higher than old value, which means the new client haven't been processed by 0x1a cmd yet
                                    linkmem->rfu_signal[vbaid] = 0xffffffff >> ((4 - rfu_numclients) << 3);
                                } else
                                    linkmem->rfu_signal[vbaid] = linkmem->rfu_signal[gbaid];
                            else
                                linkmem->rfu_signal[vbaid] = 0;
                            if (rfu_ishost) {
                                //linkmem->rfu_signal[vbaid] = 0x00ff; //host should have signal to prevent it from canceling the room? (may cause Digimon Racing host not knowing when a client leaving the room)
                                /*for (int i=0;i<linkmem->numgbas;i++)
								if (i!=vbaid && linkmem->rfu_reqid[i]==(vbaid<<3)+0x61f1) {
								rfu_masterdata[rfu_qrecv++] = linkmem->rfu_signal[i];
								}*/
                                //int j = 0;
                                /*int i = gbaid;
								if (linkmem->numgbas>=2)
								do {
								if (i!=vbaid && linkmem->rfu_reqid[i]==(vbaid<<3)+0x61f1) rfu_masterdata[rfu_qrecv++] = linkmem->rfu_signal[i];
								i = (i+1) % linkmem->numgbas;
								} while (i!=gbaid);*/
                                /*if(rfu_numclients>0)
								for(int i=0; i<rfu_numclients; i++) {
								uint32_t cid = (rfu_clientlist[i] & 0x0ffff);
								if(cid>=0x61f1) {
								cid = (cid-0x61f1)>>3;
								rfu_masterdata[rfu_qrecv++] = linkmem->rfu_signal[cid] = 0xffffffff>>((3-linkmem->rfu_clientidx[cid])<<3); //0x0ff << (linkmem->rfu_clientidx[cid]<<3);
								}
								}*/
                                //rfu_masterdata[0] = (uint32_t)linkmem->rfu_signal[vbaid];
                            }
                            if (rfu_qrecv_broadcast_data_len == 0) {
                                rfu_qrecv_broadcast_data_len = 1;
                                rfu_masterdata[0] = (uint32_t)linkmem->rfu_signal[vbaid];
                            }
                            if (rfu_qrecv_broadcast_data_len > 0) {
                                rfu_state = RFU_RECV;
                                int hid = vbaid;
                                if (!rfu_ishost)
                                    hid = gbaid;
                                rfu_masterdata[rfu_qrecv_broadcast_data_len - 1] = (uint32_t)linkmem->rfu_signal[hid];
                            }
                            rfu_cmd ^= 0x80;
                            //rfu_polarity = 0;
                            //rfu_transfer_end = 2048; //make it longer, giving time for data to come (since 0x26 usually used after 0x11)
                            /*//linktime = -2048; //1; //0;
							//numtransfers++; //not needed, just to keep track
							if ((numtransfers++) == 0) linktime = 1; //0; //might be needed to synchronize both performance? //numtransfers used to reset linktime to prevent it from reaching beyond max value of integer? //seems to be needed? otherwise data can't be received properly? //related to 0x24?
							linkmem->rfu_linktime[vbaid] = linktime; //save the ticks before changed to synchronize performance
							rfu_transfer_end = linkmem->rfu_linktime[gbaid] - linktime + 256; //waiting ticks = ticks difference between GBAs send/recv? //is max value of vbaid=1 ?
							if (rfu_transfer_end < 256) //lower/unlimited = faster client but slower host
							rfu_transfer_end = 256; //need to be positive for balanced performance in both GBAs?
							linktime = -rfu_transfer_end; //needed to synchronize performance on both side*/
                            break;
                        case 0x33: // rejoin status check?
                            if (linkmem->rfu_signal[vbaid] || numtransfers == 0)
                                rfu_masterdata[0] = 0;
                            else //0=success
                                rfu_masterdata[0] = (uint32_t)-1; //0xffffffff; //1=failed, 2++ = reserved/invalid, we use invalid value to let the game retries 0x33 until signal restored
                            rfu_cmd ^= 0x80;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            break;
                        case 0x14: // reset current client index and error check?
                            if ((linkmem->rfu_signal[vbaid] || numtransfers == 0) && gbaid != vbaid)
                                rfu_masterdata[0] = ((!rfu_ishost ? 0x100 : 0 + linkmem->rfu_clientidx[gbaid]) << 16) | ((gbaid << 3) + 0x61f1);
                            rfu_masterdata[0] = 0; //0=error, non-zero=good?
                            rfu_cmd ^= 0x80;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            break;
                        case 0x13: // error check?
                            if (linkmem->rfu_signal[vbaid] || numtransfers == 0 || rfu_initialized)
                                rfu_masterdata[0] = ((rfu_ishost ? 0x100 : 0 + linkmem->rfu_clientidx[vbaid]) << 16) | ((vbaid << 3) + 0x61f1);
                            else //high word should be 0x0200 ? is 0x0200 means 1st client and 0x4000 means 2nd client?
                                rfu_masterdata[0] = 0; //0=error, non-zero=good?
                            rfu_cmd ^= 0x80;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            break;
                        case 0x20: // client, this has something to do with 0x1f
                            rfu_masterdata[0] = (linkmem->rfu_clientidx[vbaid]) << 16; //needed for client
                            rfu_masterdata[0] |= (vbaid << 3) + 0x61f1; //0x1234; //0x641b; //max id value? Encryption key or Station Mode? (0xFBD9/0xDEAD=Access Point mode?)
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            linkmem->rfu_is_host[vbaid] = 0; //TODO:may not works properly, sometimes both acting as client but one of them still have request[vbaid]!=0 //to prevent both GBAs from acting as Host, client can't be a host at the same time
                            if (linkmem->rfu_signal[gbaid] < linkmem->rfu_signal[vbaid])
                                linkmem->rfu_signal[gbaid] = linkmem->rfu_signal[vbaid];
                            rfu_polarity = 0;
                            rfu_state = RFU_RECV;
                            rfu_qrecv_broadcast_data_len = 1;
                            rfu_cmd ^= 0x80;
                            break;
                        case 0x21: // client, this too
                            rfu_masterdata[0] = (linkmem->rfu_clientidx[vbaid]) << 16; //not needed?
                            rfu_masterdata[0] |= (vbaid << 3) + 0x61f1; //0x641b; //max id value? Encryption key or Station Mode? (0xFBD9/0xDEAD=Access Point mode?)
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            linkmem->rfu_is_host[vbaid] = 0; //TODO:may not works properly, sometimes both acting as client but one of them still have request[vbaid]!=0 //to prevent both GBAs from acting as Host, client can't be a host at the same time
                            rfu_polarity = 0;
                            rfu_state = RFU_RECV; //3;
                            rfu_qrecv_broadcast_data_len = 1;
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x19: // server bind/start listening for client to join, may be used in the middle of host<->client communication w/o causing clients to dc?
                            //linkmem->rfu_request[vbaid] = 0; //to prevent both GBAs from acting as Host and thinking both of them have Client?
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            linkmem->rfu_broadcastdata[vbaid][0] = (vbaid << 3) + 0x61f1; //start broadcasting room name
                            linkmem->rfu_clientidx[vbaid] = 0;
                            //numtransfers = 0;
                            //rfu_numclients = 0;
                            //rfu_curclient = 0;
                            //rfu_lastcmd2 = 0;
                            //rfu_polarity = 0;
                            rfu_ishost = true;
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x1c: //client, might reset some data?
                            //linkmem->rfu_request[vbaid] = 0; //to prevent both GBAs from acting as Host and thinking both of them have Client
                            //linkmem->rfu_bdata[vbaid][0] = 0; //stop broadcasting room name
                            rfu_ishost = false; //TODO: prevent both GBAs act as client but one of them have rfu_request[vbaid]!=0 on MarioGolfAdv lobby
                            //rfu_polarity = 0;
                            rfu_numclients = 0;
                            rfu_curclient = 0;
                            //c_s.Lock();
                            linkmem->rfu_listfront[vbaid] = 0;
                            linkmem->rfu_listback[vbaid] = 0;
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            //DATALIST.clear();
                            //c_s.Unlock();
                            [[fallthrough]];
                        case 0x1b: //host, might reset some data? may be used in the middle of host<->client communication w/o causing clients to dc?
                            //linkmem->rfu_request[vbaid] = 0; //to prevent both GBAs from acting as Client and thinking one of them is a Host?
                            linkmem->rfu_broadcastdata[vbaid][0] = 0; //0 may cause player unable to join in pokemon union room?
                            //numtransfers = 0;
                            //linktime = 1;
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x30: //reset some data
                            if (vbaid != gbaid) { //(linkmem->numgbas >= 2)
                                //linkmem->rfu_signal[gbaid] = 0;
                                linkmem->rfu_is_host[gbaid] &= ~(1 << vbaid); //linkmem->rfu_request[gbaid] = 0;
                                SetEvent(linksync[gbaid]); //allow other gba to move
                            }
                            //WaitForSingleObject(linksync[vbaid], 40/*linktimeout*/);
                            while (linkmem->rfu_signal[vbaid]) {
                                WaitForSingleObject(linksync[vbaid], 1 /*linktimeout*/);
                                linkmem->rfu_signal[vbaid] = 0;
                                linkmem->rfu_is_host[vbaid] = 0; //There is a possibility where rfu_request/signal didn't get zeroed here when it's being read by the other GBA at the same time
                                //SleepEx(1,true);
                            }
                            //c_s.Lock();
                            linkmem->rfu_listfront[vbaid] = 0;
                            linkmem->rfu_listback[vbaid] = 0;
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            //DATALIST.clear();
                            linkmem->rfu_proto[vbaid] = 0;
                            linkmem->rfu_reqid[vbaid] = 0;
                            linkmem->rfu_linktime[vbaid] = 0;
                            linkmem->rfu_gdata[vbaid] = 0;
                            linkmem->rfu_broadcastdata[vbaid][0] = 0;
                            //c_s.Unlock();
                            rfu_polarity = 0; //is this included?
                            //linkid = -1; //0;
                            numtransfers = 0;
                            rfu_numclients = 0;
                            rfu_curclient = 0;
                            linktime = 1; //0; //reset here instead of at 0x24/0xa5/0xa7
                            /*rfu_id = 0;
							rfu_idx = 0;
							gbaid = vbaid;
							gbaidx = gbaid;
							rfu_ishost = false;
							rfu_isfirst = false;*/
                            rfu_cmd ^= 0x80;
                            SetEvent(linksync[vbaid]); //may not be needed
                            break;

                        case 0x3d: // init/reset rfu data
                            rfu_initialized = false;
                            [[fallthrough]];
                        case 0x10: // init/reset rfu data
                            if (vbaid != gbaid) { //(linkmem->numgbas >= 2)
                                //linkmem->rfu_signal[gbaid] = 0;
                                linkmem->rfu_is_host[gbaid] &= ~(1 << vbaid); //linkmem->rfu_request[gbaid] = 0;
                                SetEvent(linksync[gbaid]); //allow other gba to move
                            }
                            //WaitForSingleObject(linksync[vbaid], 40/*linktimeout*/);
                            while (linkmem->rfu_signal[vbaid]) {
                                WaitForSingleObject(linksync[vbaid], 1 /*linktimeout*/);
                                linkmem->rfu_signal[vbaid] = 0;
                                linkmem->rfu_is_host[vbaid] = 0; //There is a possibility where rfu_request/signal didn't get zeroed here when it's being read by the other GBA at the same time
                                //SleepEx(1,true);
                            }
                            //c_s.Lock();
                            linkmem->rfu_listfront[vbaid] = 0;
                            linkmem->rfu_listback[vbaid] = 0;
                            linkmem->rfu_q[vbaid] = 0; //to prevent leftover data from previous session received immediately in the new session
                            //DATALIST.clear();
                            linkmem->rfu_proto[vbaid] = 0;
                            linkmem->rfu_reqid[vbaid] = 0;
                            linkmem->rfu_linktime[vbaid] = 0;
                            linkmem->rfu_gdata[vbaid] = 0;
                            linkmem->rfu_broadcastdata[vbaid][0] = 0;
                            //c_s.Unlock();
                            rfu_polarity = 0; //is this included?
                            //linkid = -1; //0;
                            numtransfers = 0;
                            rfu_numclients = 0;
                            rfu_curclient = 0;
                            linktime = 1; //0; //reset here instead of at 0x24/0xa5/0xa7
                            rfu_id = 0;
                            rfu_idx = 0;
                            gbaid = vbaid;
                            gbaidx = gbaid;
                            rfu_ishost = false;
                            rfu_qrecv_broadcast_data_len = 0;
                            SetEvent(linksync[vbaid]); //may not be needed
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x36: //does it expect data returned?
                        case 0x26:
                            //Switch remote id to available data
                            /*//if(vbaid==gbaid) {
							if(linkmem->numgbas>=2)
							if((linkmem->rfu_q[gbaid]<=0) || !(linkmem->rfu_qid[gbaid] & (1<<vbaid))) //current remote id doesn't have data
							//do
							{
							if(rfu_numclients>0) { //is a host
							uint8_t cc = rfu_curclient;
							do {
							rfu_curclient = (rfu_curclient+1) % rfu_numclients;
							rfu_idx = rfu_clientlist[rfu_curclient];
							gbaidx = (rfu_idx-0x61f1)>>3;
							} while (!AppTerminated && cc!=rfu_curclient && rfu_numclients>=1 && (!(linkmem->rfu_qid[gbaidx] & (1<<vbaid)) || linkmem->rfu_q[gbaidx]<=0));
							if (cc!=rfu_curclient) { //gbaidx!=vbaid && gbaidx!=gbaid
							gbaid = gbaidx;
							rfu_id = rfu_idx;
							//log("%d  Switch%02X:%d\n",GetTickCount(),rfu_cmd,gbaid);
							//if(linkmem->rfu_q[gbaid]>0 || rfu_lastcmd2==0)
							//break;
							}
							}
							//SleepEx(1,true);
							} //while (!AppTerminated && gbaid!=vbaid && linkmem->numgbas>=2 && linkmem->rfu_signal[gbaid] && linkmem->rfu_q[gbaid]<=0 && linkmem->rfu_q[vbaid]>0 && (GetTickCount()-rfu_lasttime)<1); //(DWORD)linktimeout
							}*/

                            //Wait for data

                            //Read data when available
                            /*if((linkmem->rfu_qid[gbaid] & (1<<vbaid))) //data is for this GBA
							if((rfu_qrecv=rfu_masterq=linkmem->rfu_q[gbaid])!=0) { //data size > 0
							memcpy(rfu_masterdata, linkmem->linkdata[gbaid], min(rfu_masterq<<2,sizeof(rfu_masterdata))); //128 //read data from other GBA
							linkmem->rfu_qid[gbaid] &= ~(1<<vbaid); //mark as received by this GBA
							if(linkmem->rfu_request[gbaid]) linkmem->rfu_qid[gbaid] &= linkmem->rfu_request[gbaid]; //remask if it's host, just incase there are client leaving multiplayer
							if(!linkmem->rfu_qid[gbaid]) linkmem->rfu_q[gbaid] = 0; //mark that it has been fully received
							if(!linkmem->rfu_q[gbaid]) SetEvent(linksync[gbaid]); // || (rfu_ishost && linkmem->rfu_qid[gbaid]!=linkmem->rfu_request[gbaid])
							//ResetEvent(linksync[vbaid]); //linksync[vbaid] //lock this gba, don't allow this gba to move (prevent both GBA using 0x25 at the same time) //slower but improve stability by preventing both GBAs from using 0x25 at the same time
							//SetEvent(linksync[1-vbaid]); //unlock other gba, allow other gba to move (sending their data) //faster but may affect stability and cause both GBAs using 0x25 at the same time, too fast communication could also cause the game from updating the screen
							}*/
                            bool ok;
                            int ctr;
                            ctr = 0;
                            //WaitForSingleObject(linksync[vbaid], linktimeout); //wait until unlocked
                            //ResetEvent(linksync[vbaid]); //lock it so noone can access it
                            if (linkmem->rfu_listfront[vbaid] != linkmem->rfu_listback[vbaid]) //data existed
                                do {
                                    uint8_t tmpq = linkmem->rfu_datalist[vbaid][linkmem->rfu_listfront[vbaid]].len; //(uint8_t)linkmem->rfu_qlist[vbaid][linkmem->rfu_listfront[vbaid]];
                                    ok = false;
                                    if (tmpq != rfu_qrecv_broadcast_data_len)
                                        ok = true;
                                    else
                                        for (int i = 0; i < tmpq; i++)
                                            if (linkmem->rfu_datalist[vbaid][linkmem->rfu_listfront[vbaid]].data[i] != rfu_masterdata[i]) {
                                                ok = true;
                                                break;
                                            }

                                    if (tmpq == 0 && ctr == 0)
                                        ok = true; //0-size data

                                    if (ok) //next data is not a duplicate of currently unprocessed data
                                        if (rfu_qrecv_broadcast_data_len < 2 || tmpq > 1) {
                                            if (rfu_qrecv_broadcast_data_len > 1) { //stop here if next data is different than currently unprocessed non-ping data
                                                linkmem->rfu_linktime[gbaid] = linkmem->rfu_datalist[vbaid][linkmem->rfu_listfront[vbaid]].time;
                                                break;
                                            }

                                            if (tmpq >= rfu_qrecv_broadcast_data_len) {
                                                rfu_masterq = rfu_qrecv_broadcast_data_len = tmpq;
                                                gbaid = linkmem->rfu_datalist[vbaid][linkmem->rfu_listfront[vbaid]].gbaid;
                                                rfu_id = (uint16_t)((gbaid << 3) + 0x61f1);
                                                if (rfu_ishost)
                                                    rfu_curclient = (uint8_t)linkmem->rfu_clientidx[gbaid];
                                                if (rfu_qrecv_broadcast_data_len != 0) { //data size > 0
                                                    memcpy(rfu_masterdata, linkmem->rfu_datalist[vbaid][linkmem->rfu_listfront[vbaid]].data, std::min(rfu_masterq << 2, (int)sizeof(rfu_masterdata)));
                                                }
                                            }
                                        } //else log("%08X  CMD26 Skip: %d %d %d\n",GetTickCount(),rfu_qrecv,linkmem->rfu_q[gbaid],tmpq);

                                    linkmem->rfu_listfront[vbaid]++;
                                    ctr++;

                                    ok = (linkmem->rfu_listfront[vbaid] != linkmem->rfu_listback[vbaid] && linkmem->rfu_datalist[vbaid][linkmem->rfu_listfront[vbaid]].gbaid == gbaid);
                                } while (ok);
                            //SetEvent(linksync[vbaid]); //unlock it so anyone can access it

                            if (rfu_qrecv_broadcast_data_len > 0) { //data was available
                                rfu_state = RFU_RECV;
                                rfu_counter = 0;
                                rfu_lastcmd2 = 0;

                                //Switch remote id to next remote id
                                /*if (linkmem->rfu_request[vbaid]) { //is a host
									if(rfu_numclients>0) {
									rfu_curclient = (rfu_curclient+1) % rfu_numclients;
									rfu_id = rfu_clientlist[rfu_curclient];
									gbaid = (rfu_id-0x61f1)>>3;
									//log("%d  SwitchNext%02X:%d\n",GetTickCount(),rfu_cmd,gbaid);
									}
									}*/
                            }
                            /*if(vbaid!=gbaid && linkmem->rfu_request[vbaid] && linkmem->rfu_request[gbaid])
								MessageBox(0,_T("Both GBAs are Host!"),_T("Warning"),0);*/
                            rfu_cmd ^= 0x80;
                            break;

                        case 0x24: // send [non-important] data (used by server often)
                            //numtransfers++; //not needed, just to keep track
                            if ((numtransfers++) == 0)
                                linktime = 1; //needed to synchronize both performance and for Digimon Racing's client to join successfully //numtransfers used to reset linktime to prevent it from reaching beyond max value of integer? //numtransfers doesn't seems to be used?
                            //linkmem->rfu_linktime[vbaid] = linktime; //save the ticks before reseted to zero

                            if (rfu_cansend) {
                                /*memcpy(linkmem->rfu_data[vbaid],rfu_masterdata,4*rfu_qsend2);
								linkmem->rfu_proto[vbaid] = 0; //UDP-like
								if(rfu_ishost)
								linkmem->rfu_qid[vbaid] = linkmem->rfu_request[vbaid]; else
								linkmem->rfu_qid[vbaid] |= 1<<gbaid;
								linkmem->rfu_q[vbaid] = rfu_qsend2;*/
                                if (rfu_ishost) {
                                    for (int j = 0; j < linkmem->numgbas; j++)
                                        if (j != vbaid) {
                                            WaitForSingleObject(linksync[j], linktimeout); //wait until unlocked
                                            ResetEvent(linksync[j]); //lock it so noone can access it
                                            memcpy(linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].data, rfu_masterdata, 4 * rfu_qsend2);
                                            linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].gbaid = (uint8_t)vbaid;
                                            linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].len = rfu_qsend2;
                                            linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].time = linktime;
                                            linkmem->rfu_listback[j]++;
                                            SetEvent(linksync[j]); //unlock it so anyone can access it
                                        }
                                } else if (vbaid != gbaid) {
                                    WaitForSingleObject(linksync[gbaid], linktimeout); //wait until unlocked
                                    ResetEvent(linksync[gbaid]); //lock it so noone can access it
                                    memcpy(linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].data, rfu_masterdata, 4 * rfu_qsend2);
                                    linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].gbaid = (uint8_t)vbaid;
                                    linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].len = rfu_qsend2;
                                    linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].time = linktime;
                                    linkmem->rfu_listback[gbaid]++;
                                    SetEvent(linksync[gbaid]); //unlock it so anyone can access it
                                }
                            } else {
                                //log("%08X : IgnoredSend[%02X] %d\n", GetTickCount(), rfu_cmd, rfu_qsend2);
                            }

                            linktime = 0; //need to zeroed when sending? //0 might cause slowdown in performance
                            rfu_cmd ^= 0x80;
                            //linkid = -1; //not needed?
                            break;

                        case 0x25: // send [important] data & wait for [important?] reply data
                        case 0x35: // send [important] data & wait for [important?] reply data
                            //numtransfers++; //not needed, just to keep track
                            if ((numtransfers++) == 0)
                                linktime = 1; //0; //might be needed to synchronize both performance? //numtransfers used to reset linktime to prevent it from reaching beyond max value of integer? //seems to be needed? otherwise data can't be received properly? //related to 0x24?
                            //linktime = 0;
                            //linkmem->rfu_linktime[vbaid] = linktime; //save the ticks before changed to synchronize performance

                            if (rfu_cansend && rfu_qsend2 > 0) {
                                /*memcpy(linkmem->rfu_data[vbaid],rfu_masterdata,4*rfu_qsend2);
								linkmem->rfu_proto[vbaid] = 1; //TCP-like
								if(rfu_ishost)
								linkmem->rfu_qid[vbaid] = linkmem->rfu_request[vbaid]; else
								linkmem->rfu_qid[vbaid] |= 1<<gbaid;
								linkmem->rfu_q[vbaid] = rfu_qsend2;*/
                                if (rfu_ishost) {
                                    for (int j = 0; j < linkmem->numgbas; j++)
                                        if (j != vbaid) {
                                            WaitForSingleObject(linksync[j], linktimeout); //wait until unlocked
                                            ResetEvent(linksync[j]); //lock it so noone can access it
                                            memcpy(linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].data, rfu_masterdata, 4 * rfu_qsend2);
                                            linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].gbaid = (uint8_t)vbaid;
                                            linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].len = rfu_qsend2;
                                            linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].time = linktime;
                                            linkmem->rfu_listback[j]++;
                                            SetEvent(linksync[j]); //unlock it so anyone can access it
                                        }
                                } else if (vbaid != gbaid) {
                                    WaitForSingleObject(linksync[gbaid], linktimeout); //wait until unlocked
                                    ResetEvent(linksync[gbaid]); //lock it so noone can access it
                                    memcpy(linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].data, rfu_masterdata, 4 * rfu_qsend2);
                                    linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].gbaid = (uint8_t)vbaid;
                                    linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].len = rfu_qsend2;
                                    linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].time = linktime;
                                    linkmem->rfu_listback[gbaid]++;
                                    SetEvent(linksync[gbaid]); //unlock it so anyone can access it
                                }
                            } else {
                                //log("%08X : IgnoredSend[%02X] %d\n", GetTickCount(), rfu_cmd, rfu_qsend2);
                            }
                            //numtransfers++; //not needed, just to keep track
                            //if((numtransfers++)==0) linktime = 1; //may not be needed here?
                            //linkmem->rfu_linktime[vbaid] = linktime; //may not be needed here? save the ticks before reseted to zero
                            //linktime = 0; //may not be needed here? //need to zeroed when sending? //0 might cause slowdown in performance
                            //TODO: there is still a chance for 0x25 to be used at the same time on both GBA (both GBAs acting as client but keep sending & receiving using 0x25 & 0x26 for infinity w/o updating the screen much)
                            //Waiting here for previous data to be received might be too late! as new data already sent before finalization cmd
                            [[fallthrough]];
                        case 0x27: // wait for data ?
                        case 0x37: // wait for data ?
                            //numtransfers++; //not needed, just to keep track
                            if ((numtransfers++) == 0)
                                linktime = 1; //0; //might be needed to synchronize both performance? //numtransfers used to reset linktime to prevent it from reaching beyond max value of integer? //seems to be needed? otherwise data can't be received properly? //related to 0x24?
                            //linktime = 0;
                            //linkmem->rfu_linktime[vbaid] = linktime; //save the ticks before changed to synchronize performance

                            if (rfu_ishost) {
                                for (int j = 0; j < linkmem->numgbas; j++)
                                    if (j != vbaid) {
                                        WaitForSingleObject(linksync[j], linktimeout); //wait until unlocked
                                        ResetEvent(linksync[j]); //lock it so noone can access it
                                        //memcpy(linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].data,rfu_masterdata,4*rfu_qsend2);
                                        linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].gbaid = (uint8_t)vbaid;
                                        linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].len = 0; //rfu_qsend2;
                                        linkmem->rfu_datalist[j][linkmem->rfu_listback[j]].time = linktime;
                                        linkmem->rfu_listback[j]++;
                                        SetEvent(linksync[j]); //unlock it so anyone can access it
                                    }
                            } else if (vbaid != gbaid) {
                                WaitForSingleObject(linksync[gbaid], linktimeout); //wait until unlocked
                                ResetEvent(linksync[gbaid]); //lock it so noone can access it
                                //memcpy(linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].data,rfu_masterdata,4*rfu_qsend2);
                                linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].gbaid = (uint8_t)vbaid;
                                linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].len = 0; //rfu_qsend2;
                                linkmem->rfu_datalist[gbaid][linkmem->rfu_listback[gbaid]].time = linktime;
                                linkmem->rfu_listback[gbaid]++;
                                SetEvent(linksync[gbaid]); //unlock it so anyone can access it
                            }
                            //}
                            rfu_cmd ^= 0x80;
                            break;

                        case 0xee: //is this need to be processed?
                            rfu_cmd ^= 0x80;
                            rfu_polarity = 1;
                            break;

                        case 0x17: // setup or something ?
                        default:
                            rfu_cmd ^= 0x80;
                            break;

                        case 0xa5: //	2nd part of send&wait function 0x25
                        case 0xa7: //	2nd part of wait function 0x27
                        case 0xb5: //	2nd part of send&wait function 0x35?
                        case 0xb7: //	2nd part of wait function 0x37?
                            if (linkmem->rfu_listfront[vbaid] != linkmem->rfu_listback[vbaid]) {
                                rfu_polarity = 1; //reverse polarity to make the game send 0x80000000 command word (to be replied with 0x99660028 later by the adapter)
                                if (rfu_cmd == 0xa5 || rfu_cmd == 0xa7)
                                    rfu_cmd = 0x28;
                                else
                                    rfu_cmd = 0x36; //there might be 0x29 also //don't return 0x28 yet until there is incoming data (or until 500ms-6sec timeout? may reset RFU after timeout)
                            } else
                                rfu_waiting = true;

                            /*//numtransfers++; //not needed, just to keep track
							if ((numtransfers++) == 0) linktime = 1; //0; //might be needed to synchronize both performance? //numtransfers used to reset linktime to prevent it from reaching beyond max value of integer? //seems to be needed? otherwise data can't be received properly? //related to 0x24?
							//linktime = 0;
							//if (rfu_cmd==0xa5)
							linkmem->rfu_linktime[vbaid] = linktime; //save the ticks before changed to synchronize performance
							*/

                            //prevent GBAs from sending data at the same time (which may cause waiting at the same time in the case of 0x25), also gives time for the other side to read the data
                            //if (linkmem->numgbas>=2 && linkmem->rfu_signal[vbaid] && linkmem->rfu_signal[gbaid]) {
                            //	SetEvent(linksync[gbaid]); //allow other gba to move (sending their data)
                            //	WaitForSingleObject(linksync[vbaid], 1); //linktimeout //wait until this gba allowed to move
                            //	//if(rfu_cmd==0xa5)
                            //	ResetEvent(linksync[vbaid]); //don't allow this gba to move (prevent sending another data too fast w/o giving the other side chances to read it)
                            //}

                            rfu_transfer_end = linkmem->rfu_linktime[gbaid] - linktime + 1; //256; //waiting ticks = ticks difference between GBAs send/recv? //is max value of vbaid=1 ?

                            if (rfu_transfer_end > 2560) //may need to cap the max ticks to prevent some games (ie. pokemon) from getting in-game timeout due to executing too many opcodes (too fast)
                                rfu_transfer_end = 2560; //10240;

                            if (rfu_transfer_end < 256) //lower/unlimited = faster client but slower host
                                rfu_transfer_end = 256; //need to be positive for balanced performance in both GBAs?

                            linktime = -rfu_transfer_end; //needed to synchronize performance on both side
                            break;
                        }
                        if (!rfu_waiting)
                            rfu_buf = 0x99660000 | (rfu_qrecv_broadcast_data_len << 8) | rfu_cmd;
                        else
                            rfu_buf = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    }
                } else { //unknown COMM word //in MarioGolfAdv (when a player/client exiting lobby), There is a possibility COMM = 0x7FFE8001, PrevVAL = 0x5087, PrevCOM = 0, is this part of initialization?
                    log("%08X : UnkCOM %08X  %04X  %08X %08X\n", GetTickCount(), READ32LE(&g_ioMem[COMM_SIODATA32_L]), PrevVAL, PrevCOM, PrevDAT);
                    /*rfu_cmd ^= 0x80;
				 UPDATE_REG(COMM_SIODATA32_L, 0);
				 UPDATE_REG(COMM_SIODATA32_H, 0x8000);*/
                    rfu_state = RFU_INIT; //to prevent the next reinit words from getting in finalization processing (here), may cause MarioGolfAdv to show Linking error when this occurs instead of continuing with COMM cmd
                    //UPDATE_REG(COMM_SIODATA32_H, READ16LE(&g_ioMem[COMM_SIODATA32_L])); //replying with reversed words may cause MarioGolfAdv to reinit RFU when COMM = 0x7FFE8001
                    //UPDATE_REG(COMM_SIODATA32_L, a);
                    rfu_buf = (READ16LE(&g_ioMem[COMM_SIODATA32_L]) << 16) | siodata_h;
                }
                break;

            case RFU_SEND: //data following after initialize cmd
                //if(rfu_qsend==0) {rfu_state = RFU_COMM; break;}
                CurDAT = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                if (--rfu_qsend == 0) {
                    rfu_state = RFU_COMM;
                }

                switch (rfu_cmd) {
                case 0x16:
                    linkmem->rfu_broadcastdata[vbaid][1 + rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                case 0x17:
                    //linkid = 1;
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                case 0x1f:
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                case 0x24:
                //if(linkmem->rfu_proto[vbaid]) break; //important data from 0x25 shouldn't be overwritten by 0x24
                case 0x25:
                case 0x35:
                    //if(rfu_cansend)
                    //linkmem->rfu_data[vbaid][rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;

                default:
                    rfu_masterdata[rfu_counter++] = READ32LE(&g_ioMem[COMM_SIODATA32_L]);
                    break;
                }
                rfu_buf = 0x80000000;
                break;

            case RFU_RECV: //data following after finalize cmd
                //if(rfu_qrecv==0) {rfu_state = RFU_COMM; break;}
                if (--rfu_qrecv_broadcast_data_len == 0)
                    rfu_state = RFU_COMM;

                switch (rfu_cmd) {
                case 0x9d:
                case 0x9e:
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0xb6:
                case 0xa6:
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0x91: //signal strength
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0xb3: //rejoin error code?
                /*UPDATE_REG(COMM_SIODATA32_L, 2); //0 = success, 1 = failed, 0x2++ = invalid
					UPDATE_REG(COMM_SIODATA32_H, 0x0000); //high word 0 = a success indication?
					break;*/
                case 0x94: //last error code? //it seems like the game doesn't care about this value
                case 0x93: //last error code? //it seems like the game doesn't care about this value
                    /*if(linkmem->rfu_signal[vbaid] || linkmem->numgbas>=2) {
					UPDATE_REG(COMM_SIODATA32_L, 0x1234);	// put anything in here
					UPDATE_REG(COMM_SIODATA32_H, 0x0200);	// also here, but it should be 0200
					} else {
					UPDATE_REG(COMM_SIODATA32_L, 0);	// put anything in here
					UPDATE_REG(COMM_SIODATA32_H, 0x0000);
					}*/
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0xa0:
                    //max id value? Encryption key or Station Mode? (0xFBD9/0xDEAD=Access Point mode?)
                    //high word 0 = a success indication?
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;
                case 0xa1:
                    //max id value? the same with 0xa0 cmd?
                    //high word 0 = a success indication?
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                case 0x9a:
                    rfu_buf = rfu_masterdata[rfu_counter++];
                    break;

                default: //unknown data (should use 0 or -1 as default), usually returning 0 might cause the game to think there is something wrong with the connection (ie. 0x11/0x13 cmd)
                    //0x0173 //not 0x0000 as default?
                    //0x0000
                    rfu_buf = 0xffffffff; //rfu_masterdata[rfu_counter++];
                    break;
                }
                break;
            }
            transfer_direction = 1;

            PrevVAL = value;
            PrevDAT = CurDAT;
            PrevCOM = CurCOM;
        }

        //Moved from the top to fix Mario Golf Adv from Occasionally Not Detecting wireless adapter
        /*if (value & 8) //Transfer Enable Flag Send (bit.3, 1=Disable Transfer/Not Ready)
		value &= 0xfffb; //Transfer enable flag receive (0=Enable Transfer/Ready, bit.2=bit.3 of otherside)	// A kind of acknowledge procedure
		else //(Bit.3, 0=Enable Transfer/Ready)
		value |= 4; //bit.2=1 (otherside is Not Ready)*/

        /*if (value & 1)
		value |= 0x02; //wireless always use 2Mhz speed right? this will fix MarioGolfAdv Not Detecting wireless*/

        if (rfu_polarity)
            value ^= 4; // sometimes it's the other way around
        /*value &= 0xfffb;
		value |= (value & 1)<<2;*/
        [[fallthrough]];
    default:
        UPDATE_REG(COMM_SIOCNT, value);
        return;
    }
}

bool LinkRFUUpdate()
{
    //if (IsLinkConnected()) {
    //}
    if (rfu_enabled) {
        if (transfer_direction && rfu_transfer_end <= 0) {
            if (rfu_waiting) {
                bool ok = false;
                // uint32_t tmout = linktimeout;
                // if ((!lanlink.active&&speedhack) || (lanlink.speed&&IsLinkConnected()))tmout = 16;
                if (rfu_state != RFU_INIT) {
                    if (rfu_cmd == 0x24 || rfu_cmd == 0x25 || rfu_cmd == 0x35) {
                        //c_s.Lock();
                        ok = linkmem->rfu_signal[vbaid] && linkmem->rfu_q[vbaid] > 1 && rfu_qsend > 1;
                        //c_s.Unlock();
                        if (ok && (GetTickCount() - rfu_lasttime) < (DWORD)linktimeout) {
                            return false;
                        }
                        if (linkmem->rfu_q[vbaid] < 2 || rfu_qsend > 1) {
                            rfu_cansend = true;
                            //c_s.Lock();
                            linkmem->rfu_q[vbaid] = 0;
                            linkmem->rfu_qid[vbaid] = 0;
                            //c_s.Unlock();
                        }
                        rfu_buf = 0x80000000;
                    } else {

                        if (((rfu_cmd == 0x11 || rfu_cmd == 0x1a || rfu_cmd == 0x26) && (GetTickCount() - rfu_lasttime) < 16) || ((rfu_cmd == 0xa5 || rfu_cmd == 0xb5) && (GetTickCount() - rfu_lasttime) < 16) || ((rfu_cmd == 0xa7 || rfu_cmd == 0xb7) && (GetTickCount() - rfu_lasttime) < (DWORD)linktimeout)) {
                            //c_s.Lock();
                            ok = (linkmem->rfu_listfront[vbaid] != linkmem->rfu_listback[vbaid]);
                            //c_s.Unlock();
                            if (!ok)
                                for (int i = 0; i < linkmem->numgbas; i++)
                                    if (i != vbaid)
                                        if (linkmem->rfu_q[i] && (linkmem->rfu_qid[i] & (1 << vbaid))) {
                                            ok = true;
                                            break;
                                        }
                            if (!linkmem->rfu_signal[vbaid])
                                ok = true;
                            if (!ok) {
                                return false;
                            }
                        }
                        if (rfu_cmd == 0xa5 || rfu_cmd == 0xa7 || rfu_cmd == 0xb5 || rfu_cmd == 0xb7 || rfu_cmd == 0xee)
                            rfu_polarity = 1;
                        if (rfu_cmd == 0xa5 || rfu_cmd == 0xa7)
                            rfu_cmd = 0x28;
                        else if (rfu_cmd == 0xb5 || rfu_cmd == 0xb7)
                            rfu_cmd = 0x36;

                        if (READ32LE(&g_ioMem[COMM_SIODATA32_L]) == 0x80000000)
                            rfu_buf = 0x99660000 | (rfu_qrecv_broadcast_data_len << 8) | rfu_cmd;
                        else
                            rfu_buf = 0x80000000;
                    }
                    rfu_waiting = false;
                }
            }
            UPDATE_REG(COMM_SIODATA32_L, (uint16_t)rfu_buf);
            UPDATE_REG(COMM_SIODATA32_H, rfu_buf >> 16);
        }
    }
    return true;
}

static void UpdateRFUIPC(int ticks)
{
    if (rfu_enabled) {
        rfu_transfer_end -= ticks;

        if (LinkRFUUpdate()) {
            if (transfer_direction && rfu_transfer_end <= 0) {
                transfer_direction = 0;
                uint16_t value = READ16LE(&g_ioMem[COMM_SIOCNT]);
                if (value & 0x4000) {
                    IF |= 0x80;
                    UPDATE_REG(IO_REG_IF, IF);
                }

                //if (rfu_polarity) value ^= 4;
                value &= 0xfffb;
                value |= (value & 1) << 2; //this will automatically set the correct polarity, even w/o rfu_polarity since the game will be the one who change the polarity instead of the adapter

                //UPDATE_REG(COMM_SIOCNT, READ16LE(&g_ioMem[COMM_SIOCNT]) & 0xff7f);
                UPDATE_REG(COMM_SIOCNT, (value & 0xff7f) | 0x0008); //Start bit.7 reset, SO bit.3 set automatically upon transfer completion?
                //log("SIOn32 : %04X %04X  %08X  (VCOUNT = %d) %d %d\n", READ16LE(&g_ioMem[COMM_RCNT]), READ16LE(&g_ioMem[COMM_SIOCNT]), READ32LE(&g_ioMem[COMM_SIODATA32_L]), VCOUNT);
            }
            return;
        }
    }
}

void gbInitLinkIPC()
{
    LinkIsWaiting = false;
    LinkFirstTime = true;
    linkmem->linkcmd[linkid] = 0;
    linkmem->linkdata[linkid] = 0xff;
}

uint8_t gbStartLinkIPC(uint8_t b) //used on internal clock
{
    uint8_t dat = 0xff; //master (w/ internal clock) will gets 0xff if slave is turned off (or not ready yet also?)
    //if(linkid) return 0xff; //b; //Slave shouldn't be sending from here
    //int gbSerialOn = (gbMemory[0xff02] & 0x80); //not needed?
    gba_link_enabled = true; //(gbMemory[0xff02]!=0); //not needed?
    rfu_enabled = false;

    if (!gba_link_enabled)
        return 0xff;

    //Single Computer
    if (GetLinkMode() == LINK_GAMEBOY_IPC) {
        uint32_t tm = GetTickCount();
        do {
            WaitForSingleObject(linksync[linkid], 1);
            ResetEvent(linksync[linkid]);
        } while (linkmem->linkcmd[linkid] && (GetTickCount() - tm) < (uint32_t)linktimeout);
        linkmem->linkdata[linkid] = b;
        linkmem->linkcmd[linkid] = 1;
        SetEvent(linksync[linkid]);

        LinkIsWaiting = false;
        tm = GetTickCount();
        do {
            WaitForSingleObject(linksync[1 - linkid], 1);
            ResetEvent(linksync[1 - linkid]);
        } while (!linkmem->linkcmd[1 - linkid] && (GetTickCount() - tm) < (uint32_t)linktimeout);
        if (linkmem->linkcmd[1 - linkid]) {
            dat = (uint8_t)linkmem->linkdata[1 - linkid];
            linkmem->linkcmd[1 - linkid] = 0;
        } //else LinkIsWaiting = true;
        SetEvent(linksync[1 - linkid]);

        LinkFirstTime = true;
        if (dat != 0xff /*||b==0x00||dat==0x00*/)
            LinkFirstTime = false;

        return dat;
    }
    return dat;
}

uint16_t gbLinkUpdateIPC(uint8_t b, int gbSerialOn) //used on external clock
{
    uint8_t dat = b; //0xff; //slave (w/ external clocks) won't be getting 0xff if master turned off
    BOOL recvd = false;

    gba_link_enabled = true; //(gbMemory[0xff02]!=0);
    rfu_enabled = false;

    if (gbSerialOn) {
        if (gba_link_enabled) {
            //Single Computer
            if (GetLinkMode() == LINK_GAMEBOY_IPC) {
                uint32_t tm; // = GetTickCount();
                //do {
                WaitForSingleObject(linksync[1 - linkid], linktimeout);
                ResetEvent(linksync[1 - linkid]);
                //} while (!linkmem->linkcmd[1-linkid] && (GetTickCount()-tm)<(uint32_t)linktimeout);
                if (linkmem->linkcmd[1 - linkid]) {
                    dat = (uint8_t)linkmem->linkdata[1 - linkid];
                    linkmem->linkcmd[1 - linkid] = 0;
                    recvd = true;
                    LinkIsWaiting = false;
                } else
                    LinkIsWaiting = true;
                SetEvent(linksync[1 - linkid]);

                if (!LinkIsWaiting) {
                    tm = GetTickCount();
                    do {
                        WaitForSingleObject(linksync[linkid], 1);
                        ResetEvent(linksync[linkid]);
                    } while (linkmem->linkcmd[1 - linkid] && (GetTickCount() - tm) < (uint32_t)linktimeout);
                    if (!linkmem->linkcmd[linkid]) {
                        linkmem->linkdata[linkid] = b;
                        linkmem->linkcmd[linkid] = 1;
                    }
                    SetEvent(linksync[linkid]);
                }
            }
        }

        if (dat == 0xff /*||dat==0x00||b==0x00*/) //dat==0xff||dat==0x00
            LinkFirstTime = true;
    }
    return ((dat << 8) | (recvd & (uint8_t)0xff));
}

static void CloseIPC()
{
    int f = linkmem->linkflags;
    f &= ~(1 << linkid);
    if (f & 0xf) {
        linkmem->linkflags = (uint8_t)f;
        int n = linkmem->numgbas;
        for (int i = 0; i < n; i--)
            if (f <= (1 << (i + 1)) - 1) {
                linkmem->numgbas = (uint8_t)(i + 1);
                break;
            }
    }

    for (int i = 0; i < 4; i++) {
        if (linksync[i] != NULL) {
#if (defined __WIN32__ || defined _WIN32)
            ReleaseSemaphore(linksync[i], 1, NULL);
            CloseHandle(linksync[i]);
#else
            sem_close(linksync[i]);
            if (!(f & 0xf)) {
                linkevent[sizeof(linkevent) - 2] = (char)i + '1';
                sem_unlink(linkevent);
            }
#endif
        }
    }
#if (defined __WIN32__ || defined _WIN32)
    CloseHandle(mmf);
    UnmapViewOfFile(linkmem);

// FIXME: move to caller
// (but there are no callers, so why bother?)
//regSetDwordValue("LAN", lanlink.active);
#else
    if (!(f & 0xf))
        shm_unlink("/" LOCAL_LINK_NAME);
    munmap(linkmem, sizeof(LINKDATA));
    close(mmf);
#endif
}

#endif
/* END gbaLink.cpp */

// Imported from reference implementation: gbaRemote.cpp
/* BEGIN gbaRemote.cpp */

extern int emulating;
extern void CPUUpdateCPSR();

int remotePort = 0;
int remoteSignal = 5;
SOCKET remoteSocket = (SOCKET)(-1);
SOCKET remoteListenSocket = (SOCKET)(-1);
bool remoteConnected = false;
bool remoteResumed = false;

int (*remoteSendFnc)(char*, int) = NULL;
int (*remoteRecvFnc)(char*, int) = NULL;
bool (*remoteInitFnc)() = NULL;
void (*remoteCleanUpFnc)() = NULL;

#ifndef SDL
void remoteSetSockets(SOCKET l, SOCKET r)
{
    remoteSocket = r;
    remoteListenSocket = l;
}
#endif

#define debuggerReadMemory(addr) \
    (*(uint32_t*)&map[(addr) >> 24].address[(addr)&map[(addr) >> 24].mask])

#define debuggerReadHalfWord(addr) \
    (*(uint16_t*)&map[(addr) >> 24].address[(addr)&map[(addr) >> 24].mask])

#define debuggerReadByte(addr) \
    map[(addr) >> 24].address[(addr)&map[(addr) >> 24].mask]

#define debuggerWriteMemory(addr, value) \
    *(uint32_t*)&map[(addr) >> 24].address[(addr)&map[(addr) >> 24].mask] = (value)

#define debuggerWriteHalfWord(addr, value) \
    *(uint16_t*)&map[(addr) >> 24].address[(addr)&map[(addr) >> 24].mask] = (value)

#define debuggerWriteByte(addr, value) \
    map[(addr) >> 24].address[(addr)&map[(addr) >> 24].mask] = (value)

bool dontBreakNow = false;
int debuggerNumOfDontBreak = 0;
int debuggerRadix = 0;

#define NUMBEROFDB 1000
uint32_t debuggerNoBreakpointList[NUMBEROFDB];

const char* cmdAliasTable[] = { "help", "?", "h", "?", "continue", "c", "next", "n",
    "cpyb", "copyb", "cpyh", "copyh", "cpyw", "copyw",
    "exe", "execute", "exec", "execute",
    NULL, NULL };

struct DebuggerCommand {
    const char* name;
    void (*function)(int, char**);
    const char* help;
    const char* syntax;
};

char monbuf[1000];
void monprintf(std::string line);
std::string StringToHex(std::string& cmd);
std::string HexToString(char* p);
void debuggerUsage(const char* cmd);
void debuggerHelp(int n, char** args);
void printFlagHelp();
void dbgExecute(std::string& cmd);

extern bool debuggerBreakOnWrite(uint32_t, uint32_t, int);
extern bool debuggerBreakOnRegisterCondition(uint8_t, uint32_t, uint32_t, uint8_t);
extern bool debuggerBreakOnExecution(uint32_t, uint8_t);

regBreak* breakRegList[16];
uint8_t lowRegBreakCounter[4]; //(r0-r3)
uint8_t medRegBreakCounter[4]; //(r4-r7)
uint8_t highRegBreakCounter[4]; //(r8-r11)
uint8_t statusRegBreakCounter[4]; //(r12-r15)
uint8_t* regBreakCounter[4] = {
    &lowRegBreakCounter[0],
    &medRegBreakCounter[0],
    &highRegBreakCounter[0],
    &statusRegBreakCounter[0]
};
uint32_t lastWasBranch = 0;

struct regBreak* getFromBreakRegList(uint8_t regnum, int location)
{
    if (location > regBreakCounter[regnum >> 2][regnum & 3])
        return NULL;

    struct regBreak* ans = breakRegList[regnum];
    for (int i = 0; i < location && ans; i++) {
        ans = ans->next;
    }
    return ans;
}

bool enableRegBreak = false;
reg_pair oldReg[16];
uint32_t regDiff[16];

void breakReg_check(int i)
{
    struct regBreak* brkR = breakRegList[i];
    bool notFound = true;
    uint8_t counter = regBreakCounter[i >> 2][i & 3];
    for (int bri = 0; (bri < counter) && notFound; bri++) {
        if (!brkR) {
            regBreakCounter[i >> 2][i & 3] = (uint8_t)bri;
            break;
        } else {
            if (brkR->flags != 0) {
                uint32_t regVal = (i == 15 ? (armState ? reg[15].I - 4 : reg[15].I - 2) : reg[i].I);
                if ((brkR->flags & 0x1) && (regVal == brkR->intVal)) {
                    debuggerBreakOnRegisterCondition((uint8_t)i, brkR->intVal, regVal, 1);
                    notFound = false;
                }
                if ((brkR->flags & 0x8)) {
                    if ((brkR->flags & 0x4) && ((int)regVal < (int)brkR->intVal)) {
                        debuggerBreakOnRegisterCondition((uint8_t)i, brkR->intVal, regVal, 4);
                        notFound = false;
                    }
                    if ((brkR->flags & 0x2) && ((int)regVal > (int)brkR->intVal)) {
                        debuggerBreakOnRegisterCondition((uint8_t)i, brkR->intVal, regVal, 5);
                        notFound = false;
                    }
                }
                if ((brkR->flags & 0x4) && (regVal < brkR->intVal)) {
                    debuggerBreakOnRegisterCondition((uint8_t)i, brkR->intVal, regVal, 2);
                    notFound = false;
                }
                if ((brkR->flags & 0x2) && (regVal > brkR->intVal)) {
                    debuggerBreakOnRegisterCondition((uint8_t)i, brkR->intVal, regVal, 3);
                    notFound = false;
                }
            }
            brkR = brkR->next;
        }
    }
    if (!notFound) {
        //CPU_BREAK_LOOP_2;
    }
}

void clearParticularRegListBreaks(int regNum)
{

    while (breakRegList[regNum]) {
        struct regBreak* ans = breakRegList[regNum]->next;
        free(breakRegList[regNum]);
        breakRegList[regNum] = ans;
    }
    regBreakCounter[regNum >> 2][regNum & 3] = 0;
}

void clearBreakRegList()
{
    for (int i = 0; i < 16; i++) {
        clearParticularRegListBreaks(i);
    }
}

void deleteFromBreakRegList(uint8_t regNum, int num)
{
    int counter = regBreakCounter[regNum >> 2][regNum & 3];
    if (num >= counter) {
        return;
    }
    struct regBreak* ans = breakRegList[regNum];
    struct regBreak* prev = NULL;
    for (int i = 0; i < num; i++) {
        prev = ans;
        ans = ans->next;
    }
    if (prev) {
        prev->next = ans->next;
    } else {
        breakRegList[regNum] = ans->next;
    }
    free(ans);
    regBreakCounter[regNum >> 2][regNum & 3]--;
}

void addBreakRegToList(uint8_t regnum, uint8_t flags, uint32_t value)
{
    struct regBreak* ans = (struct regBreak*)malloc(sizeof(struct regBreak));
    ans->flags = flags;
    ans->intVal = value;
    ans->next = breakRegList[regnum];
    breakRegList[regnum] = ans;
    regBreakCounter[regnum >> 2][regnum & 3]++;
}

void printBreakRegList(bool verbose)
{
    const char* flagsToOP[] = { "never", "==", ">", ">=", "<", "<=", "!=", "always" };
    bool anyPrint = false;
    for (int i = 0; i < 4; i++) {
        for (int k = 0; k < 4; k++) {
            if (regBreakCounter[i][k]) {
                if (!anyPrint) {
                    {
                        snprintf(monbuf, sizeof(monbuf), "Register breakpoint list:\n");
                        monprintf(monbuf);
                    }
                    {
                        snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                        monprintf(monbuf);
                    }
                    anyPrint = true;
                }
                struct regBreak* tmp = breakRegList[i * 4 + k];
                for (int j = 0; j < regBreakCounter[i][k]; j++) {
                    if (tmp->flags & 8) {
                        snprintf(monbuf, sizeof(monbuf), "No. %d:\tBreak if (signed)%s %08x\n", j, flagsToOP[tmp->flags & 7], tmp->intVal);
                        monprintf(monbuf);
                    } else {
                        snprintf(monbuf, sizeof(monbuf), "No. %d:\tBreak if %s %08x\n", j, flagsToOP[tmp->flags], tmp->intVal);
                        monprintf(monbuf);
                    }
                    tmp = tmp->next;
                }
                {
                    snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                    monprintf(monbuf);
                }
            } else {
                if (verbose) {
                    if (!anyPrint) {
                        {
                            snprintf(monbuf, sizeof(monbuf), "Register breakpoint list:\n");
                            monprintf(monbuf);
                        }
                        {
                            snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                            monprintf(monbuf);
                        }
                        anyPrint = true;
                    }
                    {
                        snprintf(monbuf, sizeof(monbuf), "No breaks on r%d.\n", i);
                        monprintf(monbuf);
                    }
                    {
                        snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                        monprintf(monbuf);
                    }
                }
            }
        }
    }
    if (!verbose && !anyPrint) {
        {
            snprintf(monbuf, sizeof(monbuf), "No Register breaks found.\n");
            monprintf(monbuf);
        }
    }
}

void debuggerOutput(const char* s, uint32_t addr)
{
    if (s)
        printf("%s", s);
    else {
        char c;

        c = debuggerReadByte(addr);
        addr++;
        while (c) {
            putchar(c);
            c = debuggerReadByte(addr);
            addr++;
        }
    }
}

// checks that the given address is in the DB list
bool debuggerInDB(uint32_t address)
{

    for (int i = 0; i < debuggerNumOfDontBreak; i++) {
        if (debuggerNoBreakpointList[i] == address)
            return true;
    }

    return false;
}

void debuggerDontBreak(int n, char** args)
{
    if (n == 2) {
        uint32_t address = 0;
        sscanf(args[1], "%x", &address);
        int i = debuggerNumOfDontBreak;
        if (i > NUMBEROFDB) {
            monprintf("Can't have this many DB entries");
            return;
        }
        debuggerNoBreakpointList[i] = address;
        debuggerNumOfDontBreak++;
        {
            snprintf(monbuf, sizeof(monbuf), "Added Don't Break at %08x\n", address);
            monprintf(monbuf);
        }
    } else
        debuggerUsage("db");
}

void debuggerDontBreakClear(int n, char** args)
{
    (void)args; // unused params
    if (n == 1) {
        debuggerNumOfDontBreak = 0;
        {
            snprintf(monbuf, sizeof(monbuf), "Cleared Don't Break list.\n");
            monprintf(monbuf);
        }
    } else
        debuggerUsage("dbc");
}

void debuggerDumpLoad(int n, char** args)
{
    uint32_t address;
    char* file;
    FILE* f;
    int c;

    if (n == 3) {
        file = args[1];

        if (!dexp_eval(args[2], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        }

#if __STDC_WANT_SECURE_LIB__
        fopen_s(&f, file, "rb");
#else
        f = fopen(file, "rb");
#endif
        if (f == NULL) {
            {
                snprintf(monbuf, sizeof(monbuf), "Error opening file.\n");
                monprintf(monbuf);
            }
            return;
        }

        fseek(f, 0, SEEK_END);
        int size = ftell(f);
        fseek(f, 0, SEEK_SET);

        for (int i = 0; i < size; i++) {
            c = fgetc(f);
            if (c == -1)
                break;
            debuggerWriteByte(address, (uint8_t)c);
            address++;
        }

        fclose(f);
    } else
        debuggerUsage("dload");
}

void debuggerDumpSave(int n, char** args)
{
    uint32_t address;
    uint32_t size;
    char* file;
    FILE* f;

    if (n == 4) {
        file = args[1];
        if (!dexp_eval(args[2], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        }
        if (!dexp_eval(args[3], &size)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in size");
                monprintf(monbuf);
            }
            return;
        }

#if __STDC_WANT_SECURE_LIB__
        fopen_s(&f, file, "wb");
#else
        f = fopen(file, "wb");
#endif

        if (f == NULL) {
            {
                snprintf(monbuf, sizeof(monbuf), "Error opening file.\n");
                monprintf(monbuf);
            }
            return;
        }

        for (uint32_t i = 0; i < size; i++) {
            fputc(debuggerReadByte(address), f);
            address++;
        }

        fclose(f);
    } else
        debuggerUsage("dsave");
}

void debuggerEditByte(int n, char** args)
{
    if (n >= 3) {
        uint32_t address;
        uint32_t value;
        if (!dexp_eval(args[1], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        }
        for (int i = 2; i < n; i++) {
            if (!dexp_eval(args[i], &value)) {
                {
                    snprintf(monbuf, sizeof(monbuf), "Invalid expression in %d value.Ignored.\n", (i - 1));
                    monprintf(monbuf);
                }
            }
            debuggerWriteByte(address, (uint8_t)value);
            address++;
        }
    } else
        debuggerUsage("eb");
}

void debuggerEditHalfWord(int n, char** args)
{
    if (n >= 3) {
        uint32_t address;
        uint32_t value;
        if (!dexp_eval(args[1], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        }
        if (address & 1) {
            {
                snprintf(monbuf, sizeof(monbuf), "Error: address must be half-word aligned\n");
                monprintf(monbuf);
            }
            return;
        }
        for (int i = 2; i < n; i++) {
            if (!dexp_eval(args[i], &value)) {
                {
                    snprintf(monbuf, sizeof(monbuf), "Invalid expression in %d value.Ignored.\n", (i - 1));
                    monprintf(monbuf);
                }
            }
            debuggerWriteHalfWord(address, (uint16_t)value);
            address += 2;
        }
    } else
        debuggerUsage("eh");
}

void debuggerEditWord(int n, char** args)
{
    if (n >= 3) {
        uint32_t address;
        uint32_t value;
        if (!dexp_eval(args[1], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        }
        if (address & 3) {
            {
                snprintf(monbuf, sizeof(monbuf), "Error: address must be word aligned\n");
                monprintf(monbuf);
            }
            return;
        }
        for (int i = 2; i < n; i++) {
            if (!dexp_eval(args[i], &value)) {
                {
                    snprintf(monbuf, sizeof(monbuf), "Invalid expression in %d value.Ignored.\n", (i - 1));
                    monprintf(monbuf);
                }
            }
            debuggerWriteMemory(address, (uint32_t)value);
            address += 4;
        }
    } else
        debuggerUsage("ew");
}

bool debuggerBreakOnRegisterCondition(uint8_t registerName, uint32_t compareVal, uint32_t regVal, uint8_t type)
{
    const char* typeName;
    switch (type) {
    case 1:
        typeName = "equal to";
        break;
    case 2:
        typeName = "greater (unsigned) than";
        break;
    case 3:
        typeName = "smaller (unsigned) than";
        break;
    case 4:
        typeName = "greater (signed) than";
        break;
    case 5:
        typeName = "smaller (signed) than";
        break;
    default:
        typeName = "unknown";
    }
    {
        snprintf(monbuf, sizeof(monbuf), "Breakpoint on R%02d : %08x is %s register content (%08x)\n", registerName, compareVal, typeName, regVal);
        monprintf(monbuf);
    }
    if (debuggerInDB(armState ? reg[15].I - 4 : reg[15].I - 2)) {
        {
            snprintf(monbuf, sizeof(monbuf), "But this address is marked not to break, so skipped\n");
            monprintf(monbuf);
        }
        return false;
    }
    debugger = true;
    return true;
}

void debuggerBreakRegisterList(bool verbose)
{
    printBreakRegList(verbose);
}

int getRegisterNumber(char* regName)
{
    int r = -1;
    if (toupper(regName[0]) == 'P' && toupper(regName[1]) == 'C') {
        r = 15;
    } else if (toupper(regName[0]) == 'L' && toupper(regName[1]) == 'R') {
        r = 14;
    } else if (toupper(regName[0]) == 'S' && toupper(regName[1]) == 'P') {
        r = 13;
    } else if (toupper(regName[0]) == 'R') {
        sscanf((char*)(regName + 1), "%d", &r);
    } else {
        sscanf(regName, "%d", &r);
    }

    return r;
}

void debuggerEditRegister(int n, char** args)
{
    if (n == 3) {
        int r = getRegisterNumber(args[1]);
        uint32_t val;
        if (r > 16) {
            {
                snprintf(monbuf, sizeof(monbuf), "Error: Register must be valid (0-16)\n");
                monprintf(monbuf);
            }
            return;
        }
        if (!dexp_eval(args[2], &val)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in value.\n");
                monprintf(monbuf);
            }
            return;
        }
        if (r == 16) {
            bool savedArmState = armState;
            reg[r].I = val;
            CPUUpdateFlags();
            if (armState != savedArmState) {
                if (armState) {
                    reg[15].I &= 0xFFFFFFFC;
                    armNextPC = reg[15].I;
                    reg[15].I += 4;
                    ARM_PREFETCH;
                } else {
                    reg[15].I &= 0xFFFFFFFE;
                    armNextPC = reg[15].I;
                    reg[15].I += 2;
                    THUMB_PREFETCH;
                }
            }
        } else {
            reg[r].I = val;
            if (r == 15) {
                if (armState) {
                    reg[15].I = val & 0xFFFFFFFC;
                    armNextPC = reg[15].I;
                    reg[15].I += 4;
                    ARM_PREFETCH;
                } else {
                    reg[15].I = val & 0xFFFFFFFE;
                    armNextPC = reg[15].I;
                    reg[15].I += 2;
                    THUMB_PREFETCH;
                }
            }
        }
        {
            snprintf(monbuf, sizeof(monbuf), "R%02d=%08X\n", r, val);
            monprintf(monbuf);
        }
    } else
        debuggerUsage("er");
}

void debuggerEval(int n, char** args)
{
    if (n == 2) {
        uint32_t result = 0;
        if (dexp_eval(args[1], &result)) {
            {
                snprintf(monbuf, sizeof(monbuf), " =$%08X\n", result);
                monprintf(monbuf);
            }
        } else {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression\n");
                monprintf(monbuf);
            }
        }
    } else
        debuggerUsage("eval");
}

void debuggerFillByte(int n, char** args)
{
    if (n == 4) {
        uint32_t address;
        uint32_t value;
        uint32_t reps;
        if (!dexp_eval(args[1], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        }
        if (!dexp_eval(args[2], &value)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in value.\n");
                monprintf(monbuf);
            }
        }
        if (!dexp_eval(args[3], &reps)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in repetition number.\n");
                monprintf(monbuf);
            }
        }
        for (uint32_t i = 0; i < reps; i++) {
            debuggerWriteByte(address, (uint8_t)value);
            address++;
        }
    } else
        debuggerUsage("fillb");
}

void debuggerFillHalfWord(int n, char** args)
{
    if (n == 4) {
        uint32_t address;
        uint32_t value;
        uint32_t reps;
        if (!dexp_eval(args[1], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        } /*
		 if(address & 1) {
		 { snprintf(monbuf, sizeof(monbuf), "Error: address must be halfword aligned\n"); monprintf(monbuf); }
		 return;
		 }*/
        if (!dexp_eval(args[2], &value)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in value.\n");
                monprintf(monbuf);
            }
        }
        if (!dexp_eval(args[3], &reps)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in repetition number.\n");
                monprintf(monbuf);
            }
        }
        for (uint32_t i = 0; i < reps; i++) {
            debuggerWriteHalfWord(address, (uint16_t)value);
            address += 2;
        }
    } else
        debuggerUsage("fillh");
}

void debuggerFillWord(int n, char** args)
{
    if (n == 4) {
        uint32_t address;
        uint32_t value;
        uint32_t reps;
        if (!dexp_eval(args[1], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in address.\n");
                monprintf(monbuf);
            }
            return;
        } /*
		 if(address & 3) {
		 { snprintf(monbuf, sizeof(monbuf), "Error: address must be word aligned\n"); monprintf(monbuf); }
		 return;
		 }*/
        if (!dexp_eval(args[2], &value)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in value.\n");
                monprintf(monbuf);
            }
        }
        if (!dexp_eval(args[3], &reps)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in repetition number.\n");
                monprintf(monbuf);
            }
        }
        for (uint32_t i = 0; i < reps; i++) {
            debuggerWriteMemory(address, (uint32_t)value);
            address += 4;
        }
    } else
        debuggerUsage("fillw");
}

unsigned int SearchStart = 0xFFFFFFFF;
unsigned int SearchMaxMatches = 5;
uint8_t SearchData[64]; // It actually doesn't make much sense to search for more than 64 bytes, does it?
unsigned int SearchLength = 0;
unsigned int SearchResults;

unsigned int AddressToGBA(uint8_t* mem)
{
    if (mem >= &g_bios[0] && mem <= &g_bios[0x3fff])
        return (unsigned int)(0x00000000 + (mem - &g_bios[0]));
    else if (mem >= &g_workRAM[0] && mem <= &g_workRAM[0x3ffff])
        return (unsigned int)(0x02000000 + (mem - &g_workRAM[0]));
    else if (mem >= &g_internalRAM[0] && mem <= &g_internalRAM[0x7fff])
        return (unsigned int)(0x03000000 + (mem - &g_internalRAM[0]));
    else if (mem >= &g_ioMem[0] && mem <= &g_ioMem[0x3ff])
        return (unsigned int)(0x04000000 + (mem - &g_ioMem[0]));
    else if (mem >= &g_paletteRAM[0] && mem <= &g_paletteRAM[0x3ff])
        return (unsigned int)(0x05000000 + (mem - &g_paletteRAM[0]));
    else if (mem >= &g_vram[0] && mem <= &g_vram[0x1ffff])
        return (unsigned int)(0x06000000 + (mem - &g_vram[0]));
    else if (mem >= &g_oam[0] && mem <= &g_oam[0x3ff])
        return (unsigned int)(0x07000000 + (mem - &g_oam[0]));
    else if (mem >= &g_rom[0] && mem <= &g_rom[0x1ffffff])
        return (unsigned int)(0x08000000 + (mem - &g_rom[0]));
    else
        return 0xFFFFFFFF;
};

void debuggerDoSearch()
{
    unsigned int count = 0;

    while (true) {
        unsigned int final = SearchStart + SearchLength - 1;
        uint8_t* end;
        uint8_t* start;

        switch (SearchStart >> 24) {
        case 0:
            if (final > 0x00003FFF) {
                SearchStart = 0x02000000;
                continue;
            } else {
                start = g_bios + (SearchStart & 0x3FFF);
                end = g_bios + 0x3FFF;
                break;
            };
        case 2:
            if (final > 0x0203FFFF) {
                SearchStart = 0x03000000;
                continue;
            } else {
                start = g_workRAM + (SearchStart & 0x3FFFF);
                end = g_workRAM + 0x3FFFF;
                break;
            };
        case 3:
            if (final > 0x03007FFF) {
                SearchStart = 0x04000000;
                continue;
            } else {
                start = g_internalRAM + (SearchStart & 0x7FFF);
                end = g_internalRAM + 0x7FFF;
                break;
            };
        case 4:
            if (final > 0x040003FF) {
                SearchStart = 0x05000000;
                continue;
            } else {
                start = g_ioMem + (SearchStart & 0x3FF);
                end = g_ioMem + 0x3FF;
                break;
            };
        case 5:
            if (final > 0x050003FF) {
                SearchStart = 0x06000000;
                continue;
            } else {
                start = g_paletteRAM + (SearchStart & 0x3FF);
                end = g_paletteRAM + 0x3FF;
                break;
            };
        case 6:
            if (final > 0x0601FFFF) {
                SearchStart = 0x07000000;
                continue;
            } else {
                start = g_vram + (SearchStart & 0x1FFFF);
                end = g_vram + 0x1FFFF;
                break;
            };
        case 7:
            if (final > 0x070003FF) {
                SearchStart = 0x08000000;
                continue;
            } else {
                start = g_oam + (SearchStart & 0x3FF);
                end = g_oam + 0x3FF;
                break;
            };
        case 8:
        case 9:
        case 10:
        case 11:
        case 12:
        case 13:
            if (final <= 0x09FFFFFF) {
                start = g_rom + (SearchStart & 0x01FFFFFF);
                end = g_rom + 0x01FFFFFF;
                break;
            }
            [[fallthrough]];
        default: {
            snprintf(monbuf, sizeof(monbuf), "Search completed.\n");
            monprintf(monbuf);
        }
            SearchLength = 0;
            return;
        };

        end -= SearchLength - 1;
        uint8_t firstbyte = SearchData[0];
        while (start <= end) {
            while ((start <= end) && (*start != firstbyte))
                start++;

            if (start > end)
                break;

            unsigned int p = 1;
            while ((start[p] == SearchData[p]) && (p < SearchLength))
                p++;

            if (p == SearchLength) {
                {
                    snprintf(monbuf, sizeof(monbuf), "Search result (%d): %08x\n", count + SearchResults, AddressToGBA(start));
                    monprintf(monbuf);
                }
                count++;
                if (count == SearchMaxMatches) {
                    SearchStart = AddressToGBA(start + p);
                    SearchResults += count;
                    return;
                };

                start += p; // assume areas don't overlap; alternative: start++;
            } else
                start++;
        };

        SearchStart = AddressToGBA(end + SearchLength - 1) + 1;
    };
};

void debuggerFindText(int n, char** args)
{
    if ((n == 4) || (n == 3)) {
        SearchResults = 0;
        if (!dexp_eval(args[1], &SearchStart)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression.\n");
                monprintf(monbuf);
            }
            return;
        }

        if (n == 4) {
            sscanf(args[2], "%u", &SearchMaxMatches);
#if __STDC_WANT_SECURE_LIB__
            strncpy_s((char*)SearchData, sizeof(SearchData), args[3], 64);
#else
            strncpy((char*)SearchData, args[3], 64);
#endif
            SearchLength = (unsigned int)strlen(args[3]);
        } else if (n == 3) {
#if __STDC_WANT_SECURE_LIB__
            strncpy_s((char*)SearchData, sizeof(SearchData), args[2], 64);
#else
            strncpy((char*)SearchData, args[2], 64);
#endif
            SearchLength = (unsigned int)strlen(args[2]);
        };

        if (SearchLength > 64) {
            {
                snprintf(monbuf, sizeof(monbuf), "Entered string (length: %d) is longer than 64 bytes and was cut.\n", SearchLength);
                monprintf(monbuf);
            }
            SearchLength = 64;
        };

        debuggerDoSearch();

    } else
        debuggerUsage("ft");
};

void debuggerFindHex(int n, char** args)
{
    if ((n == 4) || (n == 3)) {
        SearchResults = 0;
        if (!dexp_eval(args[1], &SearchStart)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression.\n");
                monprintf(monbuf);
            }
            return;
        }

        char SearchHex[128];
        if (n == 4) {
            sscanf(args[2], "%u", &SearchMaxMatches);
#if __STDC_WANT_SECURE_LIB__
            strncpy_s(SearchHex, sizeof(SearchHex), args[3], 128);
#else
            strncpy(SearchHex, args[3], 128);
#endif
            SearchLength = (unsigned int)strlen(args[3]);
        } else if (n == 3) {
#if __STDC_WANT_SECURE_LIB__
            strncpy_s(SearchHex, sizeof(SearchHex), args[2], 128);
#else
            strncpy(SearchHex, args[2], 128);
#endif
            SearchLength = (unsigned int)strlen(args[2]);
        };

        if (SearchLength & 1) {
            snprintf(monbuf, sizeof(monbuf), "Unaligned bytecount: %d,5. Last digit (%c) cut.\n", SearchLength / 2, SearchHex[SearchLength - 1]);
            monprintf(monbuf);
        }

        SearchLength /= 2;

        if (SearchLength > 64) {
            {
                snprintf(monbuf, sizeof(monbuf), "Entered string (length: %d) is longer than 64 bytes and was cut.\n", SearchLength);
                monprintf(monbuf);
            }
            SearchLength = 64;
        };

        for (unsigned int i = 0; i < SearchLength; i++) {
            unsigned int cbuf = 0;
            sscanf(&SearchHex[i << 1], "%02x", &cbuf);
            SearchData[i] = (uint8_t)cbuf;
        };

        debuggerDoSearch();

    } else
        debuggerUsage("fh");
};

void debuggerFindResume(int n, char** args)
{
    if ((n == 1) || (n == 2)) {
        if (SearchLength == 0) {
            {
                snprintf(monbuf, sizeof(monbuf), "Error: No search in progress. Start a search with ft or fh.\n");
                monprintf(monbuf);
            }
            debuggerUsage("fr");
            return;
        };

        if (n == 2)
            sscanf(args[1], "%u", &SearchMaxMatches);

        debuggerDoSearch();

    } else
        debuggerUsage("fr");
};

void debuggerCopyByte(int n, char** args)
{
    uint32_t source;
    uint32_t dest;
    uint32_t number = 1;
    uint32_t reps = 1;
    if (n > 5 || n < 3) {
        debuggerUsage("copyb");
    }

    if (n == 5) {
        if (!dexp_eval(args[4], &reps)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in repetition number.\n");
                monprintf(monbuf);
            }
        }
    }
    if (n > 3) {
        if (!dexp_eval(args[3], &number)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in number of copy units.\n");
                monprintf(monbuf);
            }
        }
    }
    if (!dexp_eval(args[1], &source)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Invalid expression in source address.\n");
            monprintf(monbuf);
        }
        return;
    }
    if (!dexp_eval(args[2], &dest)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Invalid expression in destination address.\n");
            monprintf(monbuf);
        }
    }

    for (uint32_t j = 0; j < reps; j++) {
        for (uint32_t i = 0; i < number; i++) {
            debuggerWriteByte(dest + i, debuggerReadByte(source + i));
        }
        dest += number;
    }
}

void debuggerCopyHalfWord(int n, char** args)
{
    uint32_t source;
    uint32_t dest;
    uint32_t number = 2;
    uint32_t reps = 1;
    if (n > 5 || n < 3) {
        debuggerUsage("copyh");
    }

    if (n == 5) {
        if (!dexp_eval(args[4], &reps)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in repetition number.\n");
                monprintf(monbuf);
            }
        }
    }
    if (n > 3) {
        if (!dexp_eval(args[3], &number)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in number of copy units.\n");
                monprintf(monbuf);
            }
        }
        number = number << 1;
    }
    if (!dexp_eval(args[1], &source)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Invalid expression in source address.\n");
            monprintf(monbuf);
        }
        return;
    }
    if (!dexp_eval(args[2], &dest)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Invalid expression in destination address.\n");
            monprintf(monbuf);
        }
    }

    for (uint32_t j = 0; j < reps; j++) {
        for (uint32_t i = 0; i < number; i += 2) {
            debuggerWriteHalfWord(dest + i, debuggerReadHalfWord(source + i));
        }
        dest += number;
    }
}

void debuggerCopyWord(int n, char** args)
{
    uint32_t source;
    uint32_t dest;
    uint32_t number = 4;
    uint32_t reps = 1;
    if (n > 5 || n < 3) {
        debuggerUsage("copyw");
    }

    if (n == 5) {
        if (!dexp_eval(args[4], &reps)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in repetition number.\n");
                monprintf(monbuf);
            }
        }
    }
    if (n > 3) {
        if (!dexp_eval(args[3], &number)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression in number of copy units.\n");
                monprintf(monbuf);
            }
        }
        number = number << 2;
    }
    if (!dexp_eval(args[1], &source)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Invalid expression in source address.\n");
            monprintf(monbuf);
        }
        return;
    }
    if (!dexp_eval(args[2], &dest)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Invalid expression in destination address.\n");
            monprintf(monbuf);
        }
    }

    for (uint32_t j = 0; j < reps; j++) {
        for (uint32_t i = 0; i < number; i += 4) {
            debuggerWriteMemory(dest + i, debuggerReadMemory(source + i));
        }
        dest += number;
    }
}

void debuggerIoVideo()
{
    {
        snprintf(monbuf, sizeof(monbuf), "DISPCNT  = %04x\n", DISPCNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DISPSTAT = %04x\n", DISPSTAT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "VCOUNT   = %04x\n", VCOUNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG0CNT   = %04x\n", BG0CNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG1CNT   = %04x\n", BG1CNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2CNT   = %04x\n", BG2CNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3CNT   = %04x\n", BG3CNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "WIN0H    = %04x\n", WIN0H);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "WIN0V    = %04x\n", WIN0V);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "WIN1H    = %04x\n", WIN1H);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "WIN1V    = %04x\n", WIN1V);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "WININ    = %04x\n", WININ);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "WINOUT   = %04x\n", WINOUT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "MOSAIC   = %04x\n", MOSAIC);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BLDMOD   = %04x\n", BLDMOD);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "COLEV    = %04x\n", COLEV);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "COLY     = %04x\n", COLY);
        monprintf(monbuf);
    }
}

void debuggerIoVideo2()
{
    {
        snprintf(monbuf, sizeof(monbuf), "BG0HOFS  = %04x\n", BG0HOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG0VOFS  = %04x\n", BG0VOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG1HOFS  = %04x\n", BG1HOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG1VOFS  = %04x\n", BG1VOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2HOFS  = %04x\n", BG2HOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2VOFS  = %04x\n", BG2VOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3HOFS  = %04x\n", BG3HOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3VOFS  = %04x\n", BG3VOFS);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2PA    = %04x\n", BG2PA);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2PB    = %04x\n", BG2PB);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2PC    = %04x\n", BG2PC);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2PD    = %04x\n", BG2PD);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2X     = %08x\n", (BG2X_H << 16) | BG2X_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG2Y     = %08x\n", (BG2Y_H << 16) | BG2Y_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3PA    = %04x\n", BG3PA);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3PB    = %04x\n", BG3PB);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3PC    = %04x\n", BG3PC);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3PD    = %04x\n", BG3PD);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3X     = %08x\n", (BG3X_H << 16) | BG3X_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "BG3Y     = %08x\n", (BG3Y_H << 16) | BG3Y_L);
        monprintf(monbuf);
    }
}

void debuggerIoDMA()
{
    {
        snprintf(monbuf, sizeof(monbuf), "DM0SAD   = %08x\n", (DM0SAD_H << 16) | DM0SAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM0DAD   = %08x\n", (DM0DAD_H << 16) | DM0DAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM0CNT   = %08x\n", (DM0CNT_H << 16) | DM0CNT_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM1SAD   = %08x\n", (DM1SAD_H << 16) | DM1SAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM1DAD   = %08x\n", (DM1DAD_H << 16) | DM1DAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM1CNT   = %08x\n", (DM1CNT_H << 16) | DM1CNT_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM2SAD   = %08x\n", (DM2SAD_H << 16) | DM2SAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM2DAD   = %08x\n", (DM2DAD_H << 16) | DM2DAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM2CNT   = %08x\n", (DM2CNT_H << 16) | DM2CNT_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM3SAD   = %08x\n", (DM3SAD_H << 16) | DM3SAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM3DAD   = %08x\n", (DM3DAD_H << 16) | DM3DAD_L);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "DM3CNT   = %08x\n", (DM3CNT_H << 16) | DM3CNT_L);
        monprintf(monbuf);
    }
}

void debuggerIoTimer()
{
    {
        snprintf(monbuf, sizeof(monbuf), "TM0D     = %04x\n", TM0D);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "TM0CNT   = %04x\n", TM0CNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "TM1D     = %04x\n", TM1D);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "TM1CNT   = %04x\n", TM1CNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "TM2D     = %04x\n", TM2D);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "TM2CNT   = %04x\n", TM2CNT);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "TM3D     = %04x\n", TM3D);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "TM3CNT   = %04x\n", TM3CNT);
        monprintf(monbuf);
    }
}

void debuggerIoMisc()
{
    {
        snprintf(monbuf, sizeof(monbuf), "P1       = %04x\n", P1);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "IE       = %04x\n", IE);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "IF       = %04x\n", IF);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "IME      = %04x\n", IME);
        monprintf(monbuf);
    }
}

void debuggerIo(int n, char** args)
{
    if (n == 1) {
        debuggerIoVideo();
        return;
    }
    if (!strcmp(args[1], "video"))
        debuggerIoVideo();
    else if (!strcmp(args[1], "video2"))
        debuggerIoVideo2();
    else if (!strcmp(args[1], "dma"))
        debuggerIoDMA();
    else if (!strcmp(args[1], "timer"))
        debuggerIoTimer();
    else if (!strcmp(args[1], "misc"))
        debuggerIoMisc();
    else {
        snprintf(monbuf, sizeof(monbuf), "Unrecognized option %s\n", args[1]);
        monprintf(monbuf);
    }
}

#define ASCII(c) (c)<32 ? '.' : (c)> 127 ? '.' : (c)

bool canUseTbl = true;
bool useWordSymbol = false;
bool thereIsATable = false;
char** wordSymbol;
bool isTerminator[256];
bool isNewline[256];
bool isTab[256];
uint8_t largestSymbol = 1;

void freeWordSymbolContents()
{
    for (int i = 0; i < 256; i++) {
        if (wordSymbol[i])
            free(wordSymbol[i]);
        wordSymbol[i] = NULL;
        isTerminator[i] = false;
        isNewline[i] = false;
        isTab[i] = false;
    }
}

void freeWordSymbol()
{
    useWordSymbol = false;
    thereIsATable = false;
    free(wordSymbol);
    largestSymbol = 1;
}

void debuggerReadCharTable(int n, char** args)
{
    if (n == 2) {
        if (!canUseTbl) {
            {
                snprintf(monbuf, sizeof(monbuf), "Cannot operate over character table, as it was disabled.\n");
                monprintf(monbuf);
            }
            return;
        }
        if (strcmp(args[1], "none") == 0) {
            freeWordSymbol();
            {
                snprintf(monbuf, sizeof(monbuf), "Cleared table. Reverted to ASCII.\n");
                monprintf(monbuf);
            }
            return;
        }
#if __STDC_WANT_SECURE_LIB__
        FILE* tlb = NULL;
        fopen_s(&tlb, args[1], "r");
#else
        FILE* tlb = fopen(args[1], "r");
#endif
        if (!tlb) {
            {
                snprintf(monbuf, sizeof(monbuf), "Could not open specified file. Abort.\n");
                monprintf(monbuf);
            }
            return;
        }
        char buffer[30];
        uint32_t slot;
        char* character = (char*)calloc(10, sizeof(char));
        wordSymbol = (char**)calloc(256, sizeof(char*));
        while (fgets(buffer, 30, tlb)) {
#if __STDC_WANT_SECURE_LIB__
            sscanf_s(buffer, "%02x=%s", &slot, character, 10);
#else
            sscanf(buffer, "%02x=%s", &slot, character);
#endif

            if (character[0]) {
                if (strlen(character) == 4) {
                    if ((character[0] == '<') && (character[1] == '\\') && (character[3] == '>')) {
                        if (character[2] == '0') {
                            isTerminator[slot] = true;
                        }
                        if (character[2] == 'n') {
                            isNewline[slot] = true;
                        }
                        if (character[2] == 't') {
                            isTab[slot] = true;
                        }
                        continue;
                    } else
                        wordSymbol[slot] = character;
                } else
                    wordSymbol[slot] = character;
            } else
                wordSymbol[slot] = (char*)' ';

            if (largestSymbol < strlen(character))
                largestSymbol = (uint8_t)strlen(character);

            character = (char*)malloc(10);
        }
        useWordSymbol = true;
        thereIsATable = true;

    } else {
        debuggerUsage("tbl");
    }
}

void printCharGroup(uint32_t addr, bool useAscii)
{
    for (int i = 0; i < 16; i++) {
        if (useWordSymbol && !useAscii) {
            char* c = wordSymbol[debuggerReadByte(addr + i)];
            int j;
            if (c) {
                {
                    snprintf(monbuf, sizeof(monbuf), "%s", c);
                    monprintf(monbuf);
                }
                j = (int)strlen(c);
            } else {
                j = 0;
            }
            while (j < largestSymbol) {
                {
                    snprintf(monbuf, sizeof(monbuf), " ");
                    monprintf(monbuf);
                }
                j++;
            }
        } else {
            {
                snprintf(monbuf, sizeof(monbuf), "%c", ASCII(debuggerReadByte(addr + i)));
                monprintf(monbuf);
            }
        }
    }
}

void debuggerMemoryByte(int n, char** args)
{
    if (n == 2) {
        uint32_t addr = 0;

        if (!dexp_eval(args[1], &addr)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression\n");
                monprintf(monbuf);
            }
            return;
        }
        for (int loop = 0; loop < 16; loop++) {
            {
                snprintf(monbuf, sizeof(monbuf), "%08x ", addr);
                monprintf(monbuf);
            }
            for (int j = 0; j < 16; j++) {
                {
                    snprintf(monbuf, sizeof(monbuf), "%02x ", debuggerReadByte(addr + j));
                    monprintf(monbuf);
                }
            }
            printCharGroup(addr, true);
            {
                snprintf(monbuf, sizeof(monbuf), "\n");
                monprintf(monbuf);
            }
            addr += 16;
        }
    } else
        debuggerUsage("mb");
}

void debuggerMemoryHalfWord(int n, char** args)
{
    if (n == 2) {
        uint32_t addr = 0;

        if (!dexp_eval(args[1], &addr)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression\n");
                monprintf(monbuf);
            }
            return;
        }

        addr = addr & 0xfffffffe;

        for (int loop = 0; loop < 16; loop++) {
            {
                snprintf(monbuf, sizeof(monbuf), "%08x ", addr);
                monprintf(monbuf);
            }
            for (int j = 0; j < 16; j += 2) {
                {
                    snprintf(monbuf, sizeof(monbuf), "%02x%02x ", debuggerReadByte(addr + j + 1), debuggerReadByte(addr + j));
                    monprintf(monbuf);
                }
            }
            printCharGroup(addr, true);
            {
                snprintf(monbuf, sizeof(monbuf), "\n");
                monprintf(monbuf);
            }
            addr += 16;
        }
    } else
        debuggerUsage("mh");
}

void debuggerMemoryWord(int n, char** args)
{
    if (n == 2) {
        uint32_t addr = 0;
        if (!dexp_eval(args[1], &addr)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression\n");
                monprintf(monbuf);
            }
            return;
        }
        addr = addr & 0xfffffffc;
        for (int loop = 0; loop < 16; loop++) {
            {
                snprintf(monbuf, sizeof(monbuf), "%08x ", addr);
                monprintf(monbuf);
            }
            for (int j = 0; j < 16; j += 4) {
                {
                    snprintf(monbuf, sizeof(monbuf), "%02x%02x%02x%02x ", debuggerReadByte(addr + j + 3), debuggerReadByte(addr + j + 2), debuggerReadByte(addr + j + 1), debuggerReadByte(addr + j));
                    monprintf(monbuf);
                }
            }
            printCharGroup(addr, true);
            {
                snprintf(monbuf, sizeof(monbuf), "\n");
                monprintf(monbuf);
            }
            addr += 16;
        }
    } else
        debuggerUsage("mw");
}

void debuggerStringRead(int n, char** args)
{
    if (n == 2) {
        uint32_t addr = 0;

        if (!dexp_eval(args[1], &addr)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression\n");
                monprintf(monbuf);
            }
            return;
        }
        for (int i = 0; i < 512; i++) {
            uint8_t slot = debuggerReadByte(addr + i);

            if (useWordSymbol) {
                if (isTerminator[slot]) {
                    {
                        snprintf(monbuf, sizeof(monbuf), "\n");
                        monprintf(monbuf);
                    }
                    return;
                } else if (isNewline[slot]) {
                    {
                        snprintf(monbuf, sizeof(monbuf), "\n");
                        monprintf(monbuf);
                    }
                } else if (isTab[slot]) {
                    {
                        snprintf(monbuf, sizeof(monbuf), "\t");
                        monprintf(monbuf);
                    }
                } else {
                    if (wordSymbol[slot]) {
                        {
                            snprintf(monbuf, sizeof(monbuf), "%s", wordSymbol[slot]);
                            monprintf(monbuf);
                        }
                    }
                }
            } else {
                {
                    snprintf(monbuf, sizeof(monbuf), "%c", ASCII(slot));
                    monprintf(monbuf);
                }
            }
        }
    } else
        debuggerUsage("ms");
}

void debuggerRegisters(int, char**)
{
    {
        snprintf(monbuf, sizeof(monbuf), "R00=%08x R04=%08x R08=%08x R12=%08x\n", reg[0].I, reg[4].I, reg[8].I, reg[12].I);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "R01=%08x R05=%08x R09=%08x R13=%08x\n", reg[1].I, reg[5].I, reg[9].I, reg[13].I);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "R02=%08x R06=%08x R10=%08x R14=%08x\n", reg[2].I, reg[6].I, reg[10].I, reg[14].I);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "R03=%08x R07=%08x R11=%08x R15=%08x\n", reg[3].I, reg[7].I, reg[11].I, reg[15].I);
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "CPSR=%08x (%c%c%c%c%c%c%c Mode: %02x)\n",
            reg[16].I,
            (N_FLAG ? 'N' : '.'),
            (Z_FLAG ? 'Z' : '.'),
            (C_FLAG ? 'C' : '.'),
            (V_FLAG ? 'V' : '.'),
            (armIrqEnable ? '.' : 'I'),
            ((!(reg[16].I & 0x40)) ? '.' : 'F'),
            (armState ? '.' : 'T'),
            armMode);
        monprintf(monbuf);
    }
}

void debuggerExecuteCommands(int n, char** args)
{
    if (n == 1) {
        {
            snprintf(monbuf, sizeof(monbuf), "%s requires at least one pathname to execute.", args[0]);
            monprintf(monbuf);
        }
        return;
    } else {
        char buffer[4096];
        n--;
        args++;
        while (n) {
#if __STDC_WANT_SECURE_LIB__
            FILE* toExec = NULL;
            fopen_s(&toExec, args[0], "r");
#else
            FILE* toExec = fopen(args[0], "r");
#endif
            if (toExec) {
                while (fgets(buffer, 4096, toExec)) {
                    std::string buf(buffer);
                    dbgExecute(buf);
                    if (!debugger || !emulating) {
                        return;
                    }
                }
            } else {
                snprintf(monbuf, sizeof(monbuf), "Could not open %s. Will not be executed.\n", args[0]);
                monprintf(monbuf);
            }

            args++;
            n--;
        }
    }
}

void debuggerSetRadix(int argc, char** argv)
{
    if (argc != 2)
        debuggerUsage(argv[0]);
    else {
        int r = atoi(argv[1]);

        bool error = false;
        switch (r) {
        case 10:
            debuggerRadix = 0;
            break;
        case 8:
            debuggerRadix = 2;
            break;
        case 16:
            debuggerRadix = 1;
            break;
        default:
            error = true;
            {
                snprintf(monbuf, sizeof(monbuf), "Unknown radix %d. Valid values are 8, 10 and 16.\n", r);
                monprintf(monbuf);
            }
            break;
        }
        if (!error) {
            snprintf(monbuf, sizeof(monbuf), "Radix set to %d\n", r);
            monprintf(monbuf);
        }
    }
}

void debuggerSymbols(int argc, char** argv)
{
    int i = 0;
    uint32_t value;
    uint32_t size;
    int type;
    bool match = false;
    int matchSize = 0;
    char* matchStr = NULL;

    if (argc == 2) {
        match = true;
        matchSize = (int)strlen(argv[1]);
        matchStr = argv[1];
    }
    {
        snprintf(monbuf, sizeof(monbuf), "Symbol               Value    Size     Type   \n");
        monprintf(monbuf);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "-------------------- -------  -------- -------\n");
        monprintf(monbuf);
    }
    const char* s = NULL;
    while ((s = elfGetSymbol(i, &value, &size, &type))) {
        if (*s) {
            if (match) {
                if (strncmp(s, matchStr, matchSize) != 0) {
                    i++;
                    continue;
                }
            }
            const char* ts = "?";
            switch (type) {
            case 2:
                ts = "ARM";
                break;
            case 0x0d:
                ts = "THUMB";
                break;
            case 1:
                ts = "DATA";
                break;
            }
            {
                snprintf(monbuf, sizeof(monbuf), "%-20s %08x %08x %-7s\n", s, value, size, ts);
                monprintf(monbuf);
            }
        }
        i++;
    }
}

void debuggerWhere(int n, char** args)
{
    (void)n; // unused params
    (void)args; // unused params
    void elfPrintCallChain(uint32_t);
    elfPrintCallChain(armNextPC);
}

void debuggerVar(int n, char** args)
{
    uint32_t val;

    if (n < 2) {
        dexp_listVars();
        return;
    }

    if (strcmp(args[1], "set") == 0) {

        if (n < 4) {
            {
                snprintf(monbuf, sizeof(monbuf), "No expression specified.\n");
                monprintf(monbuf);
            }
            return;
        }

        if (!dexp_eval(args[3], &val)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression.\n");
                monprintf(monbuf);
            }
            return;
        }

        dexp_setVar(args[2], val);
        {
            snprintf(monbuf, sizeof(monbuf), "%s = $%08x\n", args[2], val);
            monprintf(monbuf);
        }
        return;
    }

    if (strcmp(args[1], "list") == 0) {
        dexp_listVars();
        return;
    }

    if (strcmp(args[1], "save") == 0) {
        if (n < 3) {
            {
                snprintf(monbuf, sizeof(monbuf), "No file specified.\n");
                monprintf(monbuf);
            }
            return;
        }
        dexp_saveVars(args[2]);
        return;
    }

    if (strcmp(args[1], "load") == 0) {
        if (n < 3) {
            {
                snprintf(monbuf, sizeof(monbuf), "No file specified.\n");
                monprintf(monbuf);
            }
            return;
        }
        dexp_loadVars(args[2]);
        return;
    }

    {
        snprintf(monbuf, sizeof(monbuf), "Unrecognized sub-command.\n");
        monprintf(monbuf);
    }
}

bool debuggerBreakOnExecution(uint32_t address, uint8_t state)
{
    (void)state; // unused params
    if (dontBreakNow)
        return false;
    if (debuggerInDB(address))
        return false;
    if (!doesBreak(address, armState ? 0x44 : 0x88))
        return false;

    {
        snprintf(monbuf, sizeof(monbuf), "Breakpoint (on %s) address %08x\n", (armState ? "ARM" : "Thumb"), address);
        monprintf(monbuf);
    }
    debugger = true;
    return true;
}

bool debuggerBreakOnRead(uint32_t address, int size)
{
    (void)size; // unused params
    if (dontBreakNow)
        return false;
    if (debuggerInDB(armState ? reg[15].I - 4 : reg[15].I - 2))
        return false;
    if (!doesBreak(address, 0x22))
        return false;
    //if (size == 2)
    //	monprintf("Breakpoint (on read) address %08x value:%08x\n",
    //	address, debuggerReadMemory(address));
    //else if (size == 1)
    //	monprintf("Breakpoint (on read) address %08x value:%04x\n",
    //	address, debuggerReadHalfWord(address));
    //else
    //	monprintf("Breakpoint (on read) address %08x value:%02x\n",
    //	address, debuggerReadByte(address));
    debugger = true;
    return true;
}

bool debuggerBreakOnWrite(uint32_t address, uint32_t value, int size)
{
    (void)value; // unused params
    (void)size; // unused params
    if (dontBreakNow)
        return false;
    if (debuggerInDB(armState ? reg[15].I - 4 : reg[15].I - 2))
        return false;
    if (!doesBreak(address, 0x11))
        return false;
    //uint32_t lastValue;
    //dexp_eval("old_value", &lastValue);
    //if (size == 2)
    //	monprintf("Breakpoint (on write) address %08x old:%08x new:%08x\n",
    //	address, lastValue, value);
    //else if (size == 1)
    //	monprintf("Breakpoint (on write) address %08x old:%04x new:%04x\n",
    //	address, (uint16_t)lastValue, (uint16_t)value);
    //else
    //	monprintf("Breakpoint (on write) address %08x old:%02x new:%02x\n",
    //	address, (uint8_t)lastValue, (uint8_t)value);
    debugger = true;
    return true;
}

void debuggerBreakOnWrite(uint32_t address, uint32_t oldvalue, uint32_t value, int size, int t)
{
    (void)oldvalue; // unused params
    (void)t; // unused params
    debuggerBreakOnWrite(address, value, size);
    //uint32_t lastValue;
    //dexp_eval("old_value", &lastValue);

    //const char *type = "write";
    //if (t == 2)
    //	type = "change";

    //if (size == 2)
    //	monprintf("Breakpoint (on %s) address %08x old:%08x new:%08x\n",
    //	type, address, oldvalue, value);
    //else if (size == 1)
    //	monprintf("Breakpoint (on %s) address %08x old:%04x new:%04x\n",
    //	type, address, (uint16_t)oldvalue, (uint16_t)value);
    //else
    //	monprintf("Breakpoint (on %s) address %08x old:%02x new:%02x\n",
    //	type, address, (uint8_t)oldvalue, (uint8_t)value);
    //debugger = true;
}

uint8_t getFlags(char* flagName)
{

    for (int i = 0; flagName[i] != '\0'; i++) {
        flagName[i] = (char)toupper(flagName[i]);
    }

    if (strcmp(flagName, "ALWAYS") == 0) {
        return 0x7;
    }

    if (strcmp(flagName, "NEVER") == 0) {
        return 0x0;
    }

    uint8_t flag = 0;

    bool negate_flag = false;

    for (int i = 0; flagName[i] != '\0'; i++) {
        switch (flagName[i]) {
        case 'E':
            flag |= 1;
            break;
        case 'G':
            flag |= 2;
            break;
        case 'L':
            flag |= 4;
            break;
        case 'S':
            flag |= 8;
            break;
        case 'U':
            flag &= 7;
            break;
        case 'N':
            negate_flag = (!negate_flag);
            break;
        }
    }
    if (negate_flag) {
        flag = ((flag & 8) | ((~flag) & 7));
    }
    return flag;
}

void debuggerBreakRegister(int n, char** args)
{
    if (n != 3) {
        {
            snprintf(monbuf, sizeof(monbuf), "Incorrect usage of breg. Correct usage is breg <register> {flag} {value}\n");
            monprintf(monbuf);
        }
        printFlagHelp();
        return;
    }
    uint8_t _reg = (uint8_t)getRegisterNumber(args[0]);
    uint8_t flag = getFlags(args[1]);
    uint32_t value;
    if (!dexp_eval(args[2], &value)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Invalid expression.\n");
            monprintf(monbuf);
        }
        return;
    }
    if (flag != 0) {
        addBreakRegToList(_reg, flag, value);
        {
            snprintf(monbuf, sizeof(monbuf), "Added breakpoint on register R%02d, value %08x\n", _reg, value);
            monprintf(monbuf);
        }
    }
    return;
}

void debuggerBreakRegisterClear(int n, char** args)
{
    if (n > 0) {
        int r = getRegisterNumber(args[0]);
        if (r >= 0) {
            clearParticularRegListBreaks(r);
            {
                snprintf(monbuf, sizeof(monbuf), "Cleared all Register breakpoints for %s.\n", args[0]);
                monprintf(monbuf);
            }
        }
    } else {
        clearBreakRegList();
        {
            snprintf(monbuf, sizeof(monbuf), "Cleared all Register breakpoints.\n");
            monprintf(monbuf);
        }
    }
}

void debuggerBreakRegisterDelete(int n, char** args)
{
    if (n < 2) {
        {
            snprintf(monbuf, sizeof(monbuf), "Illegal use of Break register delete:\n Correct usage requires <register> <breakpointNo>.\n");
            monprintf(monbuf);
        }
        return;
    }
    int r = getRegisterNumber(args[0]);
    if ((r < 0) || (r > 16)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Could not find a correct register number:\n Correct usage requires <register> <breakpointNo>.\n");
            monprintf(monbuf);
        }
        return;
    }
    uint32_t num;
    if (!dexp_eval(args[1], &num)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Could not parse the breakpoint number:\n Correct usage requires <register> <breakpointNo>.\n");
            monprintf(monbuf);
        }
        return;
    }
    deleteFromBreakRegList((uint8_t)r, num);
    {
        snprintf(monbuf, sizeof(monbuf), "Deleted Breakpoint %d of regsiter %s.\n", num, args[0]);
        monprintf(monbuf);
    }
}

//WARNING: Some old particle to new code conversion may convert a single command
//into two or more words. Such words are separated by space, so a new tokenizer can
//find them.
const char* replaceAlias(const char* lower_cmd, const char** aliasTable)
{
    for (int i = 0; aliasTable[i]; i = i + 2) {
        if (strcmp(lower_cmd, aliasTable[i]) == 0) {
            return aliasTable[i + 1];
        }
    }
    return lower_cmd;
}

const char* breakAliasTable[] = {

    //actual beginning
    "break", "b 0 0",
    "breakpoint", "b 0 0",
    "bp", "b 0 0",
    "b", "b 0 0",

    //break types
    "thumb", "t",
    "arm", "a",
    "execution", "x",
    "exec", "x",
    "e", "x",
    "exe", "x",
    "x", "x",
    "read", "r",
    "write", "w",
    "access", "i",
    "acc", "i",
    "io", "i",
    "register", "g",
    "reg", "g",
    "any", "*",

    //code modifiers
    "clear", "c",
    "clean", "c",
    "cls", "c",
    "list", "l",
    "lst", "l",
    "delete", "d",
    "del", "d",
    "make", "m",
    /*
	//old parts made to look like the new code parts
	"bt", "b t m",
	"ba", "b a m",
	"bd", "b * d",
	"bl", "b * l",
	"bpr","b r m",
	"bprc","b r c",
	"bpw", "b w m",
	"bpwc", "b w c",
	"bt", "b t m",
	*/
    //and new parts made to look like old parts
    "breg", "b g m",
    "bregc", "b g c",
    "bregd", "b g d",
    "bregl", "b g l",

    "blist", "b * l",
    /*
	"btc", "b t c",
	"btd", "b t d",
	"btl", "b t l",

	"bac", "b a c",
	"bad", "b a d",
	"bal", "b a l",

	"bx", "b x m",
	"bxc", "b x c",
	"bxd", "b x d",
	"bxl", "b x l",

	"bw", "b w m",
	"bwc", "b w c",
	"bwd", "b w d",
	"bwl", "b w l",

	"br", "b r m",
	"brc", "b r c",
	"brd", "b r d",
	"brl", "b r l",
	*/
    "bio", "b i m",
    "bioc", "b i c",
    "biod", "b i d",
    "biol", "b i l",

    "bpio", "b i m",
    "bpioc", "b i c",
    "bpiod", "b i d",
    "bpiol", "b i l",
    /*
	"bprd", "b r d",
	"bprl", "b r l",

	"bpwd", "b w d",
	"bpwl", "b w l",
	*/
    NULL, NULL

};

char* breakSymbolCombo(char* command, int* length)
{
    char* res = (char*)malloc(6);
    res[0] = 'b';
    res[1] = ' ';
    res[2] = '0';
    res[3] = ' ';
    res[4] = '0';
    int i = 1;
    if (command[1] == 'p') {
        i++;
    }
    while (i < *length) {
        switch (command[i]) {
        case 'l':
        case 'c':
        case 'd':
        case 'm':
            if (res[4] == '0')
                res[4] = command[i];
            else {
                free(res);
                return command;
            }
            break;
        case '*':
        case 't':
        case 'a':
        case 'x':
        case 'r':
        case 'w':
        case 'i':
            if (res[2] == '0')
                res[2] = command[i];
            else {
                free(res);
                return command;
            }
            break;
        default:
            free(res);
            return command;
        }
        i++;
    }
    if (res[2] == '0')
        res[2] = '*';
    if (res[4] == '0')
        res[4] = 'm';
    *length = 5;
    return res;
}

const char* typeMapping[] = { "'uint8_t", "'uint16_t", "'uint32_t", "'uint32_t", "'int8_t", "'int16_t", "'int32_t", "'int32_t" };

const char* compareFlagMapping[] = { "Never", "==", ">", ">=", "<", "<=", "!=", "<=>" };

struct intToString {
    int value;
    const char mapping[20];
};

struct intToString breakFlagMapping[] = {
    { 0x80, "Thumb" },
    { 0x40, "ARM" },
    { 0x20, "Read" },
    { 0x10, "Write" },
    { 0x8, "Thumb" },
    { 0x4, "ARM" },
    { 0x2, "Read" },
    { 0x1, "Write" },
    { 0x0, "None" }
};

//printers
void printCondition(struct ConditionalBreakNode* toPrint)
{
    if (toPrint) {
        const char* firstType = typeMapping[toPrint->exp_type_flags & 0x7];
        const char* secondType = typeMapping[(toPrint->exp_type_flags >> 4) & 0x7];
        const char* operand = compareFlagMapping[toPrint->cond_flags & 0x7];
        {
            snprintf(monbuf, sizeof(monbuf), "%s %s %s%s %s %s", firstType, toPrint->address,
                ((toPrint->cond_flags & 8) ? "s" : ""), operand,
                secondType, toPrint->value);
            monprintf(monbuf);
        }
        if (toPrint->next) {
            {
                snprintf(monbuf, sizeof(monbuf), " &&\n\t\t");
                monprintf(monbuf);
            }
            printCondition(toPrint->next);
        } else {
            {
                snprintf(monbuf, sizeof(monbuf), "\n");
                monprintf(monbuf);
            }
            return;
        }
    }
}

void printConditionalBreak(struct ConditionalBreak* toPrint, bool printAddress)
{
    if (toPrint) {
        if (printAddress) {
            snprintf(monbuf, sizeof(monbuf), "At %08x, ", toPrint->break_address);
            monprintf(monbuf);
        }
        if (toPrint->type_flags & 0xf0) {
            snprintf(monbuf, sizeof(monbuf), "Break Always on");
            monprintf(monbuf);
        }
        bool hasPrevCond = false;
        uint8_t flgs = 0x80;
        while (flgs != 0) {
            if (toPrint->type_flags & flgs) {
                if (hasPrevCond) {
                    snprintf(monbuf, sizeof(monbuf), ",");
                    monprintf(monbuf);
                }
                for (int i = 0; i < 9; i++) {
                    if (breakFlagMapping[i].value == flgs) {
                        {
                            snprintf(monbuf, sizeof(monbuf), "\t%s", breakFlagMapping[i].mapping);
                            monprintf(monbuf);
                        }
                        hasPrevCond = true;
                    }
                }
            }
            flgs = flgs >> 1;
            if ((flgs == 0x8) && (toPrint->type_flags & 0xf)) {
                {
                    snprintf(monbuf, sizeof(monbuf), "\n\t\tBreak conditional on");
                    monprintf(monbuf);
                }
                hasPrevCond = false;
            }
        }
        {
            snprintf(monbuf, sizeof(monbuf), "\n");
            monprintf(monbuf);
        }
        if (toPrint->type_flags & 0xf && toPrint->firstCond) {
            {
                snprintf(monbuf, sizeof(monbuf), "With conditions:\n\t\t");
                monprintf(monbuf);
            }
            printCondition(toPrint->firstCond);
        } else if (toPrint->type_flags & 0xf) {
            //should not happen
            {
                snprintf(monbuf, sizeof(monbuf), "No conditions detected, but conditional. Assumed always by default.\n");
                monprintf(monbuf);
            }
        }
    }
}

void printAllConditionals()
{

    for (int i = 0; i < 16; i++) {

        if (conditionals[i] != NULL) {
            {
                snprintf(monbuf, sizeof(monbuf), "Address range 0x%02x000000 breaks:\n", i);
                monprintf(monbuf);
            }
            {
                snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                monprintf(monbuf);
            }
            struct ConditionalBreak* base = conditionals[i];
            int count = 1;
            uint32_t lastAddress = base->break_address;
            {
                snprintf(monbuf, sizeof(monbuf), "Address %08x\n-------------------------\n", lastAddress);
                monprintf(monbuf);
            }
            while (base) {
                if (lastAddress != base->break_address) {
                    lastAddress = base->break_address;
                    count = 1;
                    {
                        snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                        monprintf(monbuf);
                    }
                    {
                        snprintf(monbuf, sizeof(monbuf), "Address %08x\n-------------------------\n", lastAddress);
                        monprintf(monbuf);
                    }
                }
                {
                    snprintf(monbuf, sizeof(monbuf), "No.%d\t-->\t", count);
                    monprintf(monbuf);
                }
                printConditionalBreak(base, false);
                count++;
                base = base->next;
            }
        }
    }
}

uint8_t printConditionalsFromAddress(uint32_t address)
{
    uint8_t count = 1;
    if (conditionals[address >> 24] != NULL) {
        struct ConditionalBreak* base = conditionals[address >> 24];
        while (base) {
            if (address == base->break_address) {
                if (count == 1) {
                    {
                        snprintf(monbuf, sizeof(monbuf), "Address %08x\n-------------------------\n", address);
                        monprintf(monbuf);
                    }
                }
                {
                    snprintf(monbuf, sizeof(monbuf), "No.%d\t-->\t", count);
                    monprintf(monbuf);
                }
                printConditionalBreak(base, false);
                count++;
            }
            if (address < base->break_address)
                break;
            base = base->next;
        }
    }
    if (count == 1) {
        {
            snprintf(monbuf, sizeof(monbuf), "None\n");
            monprintf(monbuf);
        }
    }
    return count;
}

void printAllFlagConditionals(uint8_t flag, bool orMode)
{
    int count = 1;
    int actualCount = 1;
    for (int i = 0; i < 16; i++) {
        if (conditionals[i] != NULL) {
            bool isCondStart = true;
            struct ConditionalBreak* base = conditionals[i];

            uint32_t lastAddress = base->break_address;

            while (base) {
                if (lastAddress != base->break_address) {
                    lastAddress = base->break_address;
                    count = 1;
                    actualCount = 1;
                }
                if (((base->type_flags & flag) == base->type_flags) || (orMode && (base->type_flags & flag))) {
                    if (actualCount == 1) {
                        if (isCondStart) {
                            {
                                snprintf(monbuf, sizeof(monbuf), "Address range 0x%02x000000 breaks:\n", i);
                                monprintf(monbuf);
                            }
                            {
                                snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                                monprintf(monbuf);
                            }
                            isCondStart = false;
                        }
                        {
                            snprintf(monbuf, sizeof(monbuf), "Address %08x\n-------------------------\n", lastAddress);
                            monprintf(monbuf);
                        }
                    }
                    {
                        snprintf(monbuf, sizeof(monbuf), "No.%d\t-->\t", count);
                        monprintf(monbuf);
                    }
                    printConditionalBreak(base, false);
                    actualCount++;
                }
                base = base->next;
                count++;
            }
        }
    }
}

void printAllFlagConditionalsWithAddress(uint32_t address, uint8_t flag, bool orMode)
{
    int count = 1;
    int actualCount = 1;
    for (int i = 0; i < 16; i++) {
        if (conditionals[i] != NULL) {
            bool isCondStart = true;
            struct ConditionalBreak* base = conditionals[i];

            uint32_t lastAddress = base->break_address;

            while (base) {
                if (lastAddress != base->break_address) {
                    lastAddress = base->break_address;
                    count = 1;
                    actualCount = 1;
                }
                if ((lastAddress == address) && (((base->type_flags & flag) == base->type_flags) || (orMode && (base->type_flags & flag)))) {
                    if (actualCount == 1) {
                        if (isCondStart) {
                            {
                                snprintf(monbuf, sizeof(monbuf), "Address range 0x%02x000000 breaks:\n", i);
                                monprintf(monbuf);
                            }
                            {
                                snprintf(monbuf, sizeof(monbuf), "-------------------------\n");
                                monprintf(monbuf);
                            }
                            isCondStart = false;
                        }
                        {
                            snprintf(monbuf, sizeof(monbuf), "Address %08x\n-------------------------\n", lastAddress);
                            monprintf(monbuf);
                        }
                    }
                    {
                        snprintf(monbuf, sizeof(monbuf), "No.%d\t-->\t", count);
                        monprintf(monbuf);
                    }
                    printConditionalBreak(base, false);
                    actualCount++;
                }
                base = base->next;
                count++;
            }
        }
    }
}

void makeBreak(uint32_t address, uint8_t flags, char** expression, int n)
{
    if (n >= 1) {
        if (tolower(expression[0][0]) == 'i' && tolower(expression[0][1]) == 'f') {
            expression = expression + 1;
            n--;
            if (n != 0) {
                parseAndCreateConditionalBreaks(address, flags, expression, n);
                return;
            }
        }
    } else {
        flags = flags << 0x4;
        printConditionalBreak(addConditionalBreak(address, flags), true);
        return;
    }
}
void deleteBreak(uint32_t address, uint8_t flags, char** expression, int howToDelete)
{
    bool applyOr = true;
    if (howToDelete > 0) {
        if (((expression[0][0] == '&') && !expression[0][1]) || ((tolower(expression[0][0]) == 'o') && (tolower(expression[0][1]) == 'n')) || ((tolower(expression[0][0]) == 'l') && (tolower(expression[0][1]) == 'y'))) {
            applyOr = false;
            howToDelete--;
            expression++;
        }
        if (howToDelete > 0) {
            uint32_t number = 0;
            if (!dexp_eval(expression[0], &number)) {
                {
                    snprintf(monbuf, sizeof(monbuf), "Invalid expression for number format.\n");
                    monprintf(monbuf);
                }
                return;
            }
            removeFlagFromConditionalBreakNo(address, (uint8_t)number, (flags | (flags >> 4)));
            {
                snprintf(monbuf, sizeof(monbuf), "Removed all specified breaks from %08x.\n", address);
                monprintf(monbuf);
            }
            return;
        }
        removeConditionalWithAddressAndFlag(address, flags, applyOr);
        removeConditionalWithAddressAndFlag(address, flags << 4, applyOr);
        {
            snprintf(monbuf, sizeof(monbuf), "Removed all specified breaks from %08x.\n", address);
            monprintf(monbuf);
        }
    } else {
        removeConditionalWithAddressAndFlag(address, flags, applyOr);
        removeConditionalWithAddressAndFlag(address, flags << 4, applyOr);
        {
            snprintf(monbuf, sizeof(monbuf), "Removed all specified breaks from %08x.\n", address);
            monprintf(monbuf);
        }
    }
    return;
}
void clearBreaks(uint32_t address, uint8_t flags, char** expression, int howToClear)
{
    (void)address; // unused params
    (void)expression; // unused params
    if (howToClear == 2) {
        removeConditionalWithFlag(flags, true);
        removeConditionalWithFlag(flags << 4, true);
    } else {
        removeConditionalWithFlag(flags, false);
        removeConditionalWithFlag(flags << 4, false);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "Cleared all requested breaks.\n");
        monprintf(monbuf);
    }
}

void listBreaks(uint32_t address, uint8_t flags, char** expression, int howToList)
{
    (void)expression; // unused params
    flags |= (flags << 4);
    if (howToList) {
        printAllFlagConditionalsWithAddress(address, flags, true);
    } else {
        printAllFlagConditionals(flags, true);
    }
    {
        snprintf(monbuf, sizeof(monbuf), "\n");
        monprintf(monbuf);
    }
}

void executeBreakCommands(int n, char** cmd)
{
    char* command = cmd[0];
    int len = (int)strlen(command);
    bool changed = false;
    if (len <= 4) {
        command = breakSymbolCombo(command, &len);
        changed = (len == 5);
    }
    if (!changed) {
        command = strdup(replaceAlias(cmd[0], breakAliasTable));
        changed = (strcmp(cmd[0], command));
    }
    if (!changed) {
        cmd[0][0] = '!';
        return;
    }
    cmd++;
    n--;
    void (*operation)(uint32_t, uint8_t, char**, int) = &makeBreak; //the function to be called

    uint8_t flag = 0;
    uint32_t address = 0;
    //if(strlen(command) == 1){
    //Cannot happen, that would mean cmd[0] != b
    //}
    char target;
    char ope;

    if (command[2] == '0') {
        if (n <= 0) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid break command.\n");
                monprintf(monbuf);
            }
            free(command);
            return;
        }

        for (int i = 0; cmd[0][i]; i++) {
            cmd[0][i] = (char)tolower(cmd[0][i]);
        }
        const char* replaced = replaceAlias(cmd[0], breakAliasTable);
        if (replaced == cmd[0]) {
            target = '*';
        } else {
            target = replaced[0];
            if ((target == 'c') || (target == 'd') || (target == 'l') || (target == 'm')) {
                command[4] = target;
                target = '*';
            }
            cmd++;
            n--;
        }
        command[2] = target;
    }

    if (command[4] == '0') {
        if (n <= 0) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid break command.\n");
                monprintf(monbuf);
            }
            free(command);
            return;
        }

        for (int i = 0; cmd[0][i]; i++) {
            cmd[0][i] = (char)tolower(cmd[0][i]);
        }
        ope = replaceAlias(cmd[0], breakAliasTable)[0];
        if ((ope == 'c') || (ope == 'd') || (ope == 'l') || (ope == 'm')) {
            command[4] = ope;
            cmd++;
            n--;
        } else {
            command[4] = 'm';
        }
    }

    switch (command[4]) {
    case 'l':
        operation = &listBreaks;
        break;
    case 'c':
        operation = &clearBreaks;
        break;
    case 'd':
        operation = &deleteBreak;
        break;

    case 'm':
    default:
        operation = &makeBreak;
    };

    switch (command[2]) {
    case 'g':
        switch (command[4]) {
        case 'l':
            debuggerBreakRegisterList((n > 0) && (tolower(cmd[0][0]) == 'v'));
            return;
        case 'c':
            debuggerBreakRegisterClear(n, cmd);
            return;
        case 'd':
            debuggerBreakRegisterDelete(n, cmd);
            return;

        case 'm':
            debuggerBreakRegister(n, cmd);
        default:
            return;
        };
        return;
    case '*':
        flag = 0xf;
        break;
    case 't':
        flag = 0x8;
        break;
    case 'a':
        flag = 0x4;
        break;
    case 'x':
        flag = 0xC;
        break;
    case 'r':
        flag = 0x2;
        break;
    case 'w':
        flag = 0x1;
        break;
    case 'i':
        flag = 0x3;
        break;
    default:
        free(command);
        return;
    };

    free(command);
    bool hasAddress = false;
    if ((n >= 1) && (operation != clearBreaks)) {
        if (!dexp_eval(cmd[0], &address)) {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid expression for address format.\n");
                monprintf(monbuf);
            }
            return;
        }
        hasAddress = true;
    }
    if (operation == listBreaks) {
        operation(address, flag, NULL, hasAddress);
        return;
    } else if (operation == clearBreaks) {
        if (!hasAddress && (n >= 1)) {
            if ((cmd[0][0] == '|' && cmd[0][1] == '|') || ((cmd[0][0] == 'O' || cmd[0][0] == 'o') && (cmd[0][1] == 'R' || cmd[0][1] == 'r'))) {
                operation(address, flag, NULL, 2);
            } else {
                operation(address, flag, NULL, 0);
            }
        } else {
            operation(address, flag, NULL, 0);
        }
        return;
    } else if (!hasAddress && (operation == deleteBreak)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Delete breakpoint operation requires at least one address;\n");
            monprintf(monbuf);
        }
        {
            snprintf(monbuf, sizeof(monbuf), "Usage: break [type] delete [address] no.[number] --> Deletes breakpoint [number] of [address].\n");
            monprintf(monbuf);
        }
        //{ snprintf(monbuf, sizeof(monbuf), "Usage: [delete Operand] [address] End [address] --> Deletes range between [address] and [end]\n"); monprintf(monbuf); }
        {
            snprintf(monbuf, sizeof(monbuf), "Usage: break [type] delete [address]\n --> Deletes all breakpoints of [type] on [address].");
            monprintf(monbuf);
        }
        return;
    } else if (!hasAddress && (operation == makeBreak)) {
        {
            snprintf(monbuf, sizeof(monbuf), "Can only create breakpoints if an address is provided");
            monprintf(monbuf);
        }
        //print usage here
        return;
    } else {
        operation(address, flag, cmd + 1, n - 1);
        return;
    }
}

void debuggerDisable(int n, char** args)
{
    if (n >= 3) {
        debuggerUsage("disable");
        return;
    }
    while (n > 1) {
        int i = 0;
        while (args[3 - n][i]) {
            args[3 - n][i] = (char)tolower(args[2 - n][i]);
            i++;
        }
        if (strcmp(args[3 - n], "breg")) {
            enableRegBreak = false;
            {
                snprintf(monbuf, sizeof(monbuf), "Break on register disabled.\n");
                monprintf(monbuf);
            }
        } else if (strcmp(args[3 - n], "tbl")) {
            canUseTbl = false;
            useWordSymbol = false;
            {
                snprintf(monbuf, sizeof(monbuf), "Symbol table disabled.\n");
                monprintf(monbuf);
            }
        } else {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid command. Only tbl and breg are accepted as commands\n");
                monprintf(monbuf);
            }
            return;
        }
        n--;
    }
}

void debuggerEnable(int n, char** args)
{
    if (n >= 3) {
        debuggerUsage("enable");
        return;
    }
    while (n > 1) {
        int i = 0;
        while (args[3 - n][i]) {
            args[3 - n][i] = (char)tolower(args[2 - n][i]);
            i++;
        }
        if (strcmp(args[3 - n], "breg")) {
            enableRegBreak = true;
            {
                snprintf(monbuf, sizeof(monbuf), "Break on register enabled.\n");
                monprintf(monbuf);
            }
        } else if (strcmp(args[3 - n], "tbl")) {
            canUseTbl = true;
            useWordSymbol = thereIsATable;
            {
                snprintf(monbuf, sizeof(monbuf), "Symbol table enabled.\n");
                monprintf(monbuf);
            }
        } else {
            {
                snprintf(monbuf, sizeof(monbuf), "Invalid command. Only tbl and breg are accepted as commands\n");
                monprintf(monbuf);
            }
            return;
        }
        n--;
    }
}

DebuggerCommand debuggerCommands[] = {
    //simple commands
    { "?", debuggerHelp, "Shows this help information. Type ? <command> for command help. Alias 'help', 'h'.", "[<command>]" },
    //	{ "n", debuggerNext, "Executes the next instruction.", "[<count>]" },
    //	{ "c", debuggerContinue, "Continues execution", NULL },
    //	// Hello command, shows Hello on the board

    //{ "br", debuggerBreakRead, "Break on read", "{address} {size}" },
    //{ "bw", debuggerBreakWrite, "Break on write", "{address} {size}" },
    //{ "bt", debuggerBreakWrite, "Break on write", "{address} {size}" },

    //{ "ba", debuggerBreakArm, "Adds an ARM breakpoint", "{address}" },
    //{ "bd", debuggerBreakDelete, "Deletes a breakpoint", "<number>" },
    //{ "bl", debuggerBreakList, "Lists breakpoints" },
    //{ "bpr", debuggerBreakRead, "Break on read", "{address} {size}" },
    //{ "bprc", debuggerBreakReadClear, "Clear break on read", NULL },
    //{ "bpw", debuggerBreakWrite, "Break on write", "{address} {size}" },
    //{ "bpwc", debuggerBreakWriteClear, "Clear break on write", NULL },
    { "breg", debuggerBreakRegister, "Breaks on a register specified value", "<register_number> {flag} {value}" },
    { "bregc", debuggerBreakRegisterClear, "Clears all break on register", "<register_number> {flag} {value}" },
    //{ "bt", debuggerBreakThumb, "Adds a THUMB breakpoint", "{address}" }

    //	//diassemble commands
    //	{ "d", debuggerDisassemble, "Disassembles instructions", "[<address> [<number>]]" },
    //	{ "da", debuggerDisassembleArm, "Disassembles ARM instructions", "[{address} [{number}]]" },
    //	{ "dt", debuggerDisassembleThumb, "Disassembles Thumb instructions", "[{address} [{number}]]" },

    { "db", debuggerDontBreak, "Don't break at the following address.", "[{address} [{number}]]" },
    { "dbc", debuggerDontBreakClear, "Clear the Don't Break list.", NULL },
    { "dload", debuggerDumpLoad, "Load raw data dump from file", "<file> {address}" },
    { "dsave", debuggerDumpSave, "Dump raw data to file", "<file> {address} {size}" },
    //	{ "dn", debuggerDisassembleNear, "Disassembles instructions near PC", "[{number}]" },

    { "disable", debuggerDisable, "Disables operations.", "tbl|breg" },
    { "enable", debuggerEnable, "Enables operations.", "tbl|breg" },

    { "eb", debuggerEditByte, "Modify memory location (byte)", "{address} {value}*" },
    { "eh", debuggerEditHalfWord, "Modify memory location (half-word)", "{address} {value}*" },
    { "ew", debuggerEditWord, "Modify memory location (word)", "{address} {value}*" },
    { "er", debuggerEditRegister, "Modify register", "<register number> {value}" },

    { "eval", debuggerEval, "Evaluate expression", "{expression}" },

    { "fillb", debuggerFillByte, "Fills memory location (byte)", "{address} {value} {number of times}" },
    { "fillh", debuggerFillHalfWord, "Fills memory location (half-word)", "{address} {value} {number of times}" },
    { "fillw", debuggerFillWord, "Fills memory location (word)", "{address} {value} {number of times}" },

    { "copyb", debuggerCopyByte, "Copies memory content (byte)", "{address} {second address} {size} optional{repeat}" },
    { "copyh", debuggerCopyHalfWord, "Copies memory content (half-word)", "{address} {second address} {size} optional{repeat}" },
    { "copyw", debuggerCopyWord, "Copies memory content (word)", "{address} {second address} {size} optional{repeat}" },

    { "ft", debuggerFindText, "Search memory for ASCII-string.", "<start> [<max-result>] <string>" },
    { "fh", debuggerFindHex, "Search memory for hex-string.", "<start> [<max-result>] <hex-string>" },
    { "fr", debuggerFindResume, "Resume current search.", "[<max-result>]" },

    { "io", debuggerIo, "Show I/O registers status", "[video|video2|dma|timer|misc]" },
    //	{ "load", debuggerReadState, "Loads a Fx type savegame", "<number>" },

    { "mb", debuggerMemoryByte, "Shows memory contents (bytes)", "{address}" },
    { "mh", debuggerMemoryHalfWord, "Shows memory contents (half-words)", "{address}" },
    { "mw", debuggerMemoryWord, "Shows memory contents (words)", "{address}" },
    { "ms", debuggerStringRead, "Shows memory contents (table string)", "{address}" },

    { "r", debuggerRegisters, "Shows ARM registers", NULL },
    //	{ "rt", debuggerRunTo, "Run to address", "{address}" },
    //	{ "rta", debuggerRunToArm, "Run to address (ARM)", "{address}" },
    //	{ "rtt", debuggerRunToThumb, "Run to address (Thumb)", "{address}" },

    //	{ "reset", debuggerResetSystem, "Resets the system", NULL },
    //	{ "reload", debuggerReloadRom, "Reloads the ROM", "optional {rom path}" },
    { "execute", debuggerExecuteCommands, "Executes commands from a text file", "{file path}" },

    //	{ "save", debuggerWriteState, "Creates a Fx type savegame", "<number>" },
    //	{ "sbreak", debuggerBreak, "Adds a breakpoint on the given function", "<function>|<line>|<file:line>" },
    { "sradix", debuggerSetRadix, "Sets the print radix", "<radix>" },
    //	{ "sprint", debuggerPrint, "Print the value of a expression (if known)", "[/x|/o|/d] <expression>" },
    { "ssymbols", debuggerSymbols, "List symbols", "[<symbol>]" },
    //#ifndef FINAL_VERSION
    //	{ "strace", debuggerDebug, "Sets the trace level", "<value>" },
    //#endif
    //#ifdef DEV_VERSION
    //	{ "sverbose", debuggerVerbose, "Change verbose setting", "<value>" },
    //#endif
    { "swhere", debuggerWhere, "Shows call chain", NULL },

    { "tbl", debuggerReadCharTable, "Loads a character table", "<file>" },

    //	{ "trace", debuggerTrace, "Control tracer", "start|stop|file <file>" },
    { "var", debuggerVar, "Define variables", "<name> {variable}" },
    { NULL, NULL, NULL, NULL } // end marker
};

void printFlagHelp()
{
    monprintf("Flags are combinations of six distinct characters:\n");
    monprintf("\t\te --> Equal to;\n");
    monprintf("\t\tg --> Greater than;\n");
    monprintf("\t\tl --> Less than;\n");
    monprintf("\t\ts --> signed;\n");
    monprintf("\t\tu --> unsigned (assumed by ommision);\n");
    monprintf("\t\tn --> not;\n");
    monprintf("Ex: ge -> greater or equal; ne -> not equal; lg --> less or greater (same as not equal);\n");
    monprintf("s and u parts cannot be used in the same line, and are not negated by n;\n");
    monprintf("Special flags: always(all true), never(all false).\n");
}

void debuggerUsage(const char* cmd)
{
    if (!strcmp(cmd, "break")) {
        monprintf("Break command, composed of three parts:\n");
        monprintf("Break (b, bp or break): Indicates a break command;\n");
        monprintf("Type of break: Indicates the type of break the command applies to;\n");
        monprintf("Command: Indicates the type of command to be applied.\n");
        monprintf("Type Flags:\n\tt (thumb): The Thumb execution mode.\n");
        monprintf("\ta (ARM): The ARM execution mode.\n");
        monprintf("\tx (execution, exe, exec, e): Any execution mode.\n");
        monprintf("\tr (read): When a read occurs.\n");
        monprintf("\tw (write): When a write occurs.\n");
        monprintf("\ti (io, access,acc): When memory access (read or write) occurs.\n");
        monprintf("\tg (register, reg): Special On Register value change break.\n");
        monprintf("\t* (any): On any occasion (except register change).Omission value.\n");
        monprintf("Cmd Flags:\n\tm (make): Create a breakpoint.Default omission value.\n");
        monprintf("\tl (list,lst): Lists all existing breakpoints of the specified type.\n");
        monprintf("\td (delete,del): Deletes a specific breakpoint of the specified type.\n");
        monprintf("\tc (clear, clean, cls): Erases all breakpoints of the specified type.\n");
        monprintf("\n");
        monprintf("All those flags can be combined in order to access the several break functions\n");
        monprintf("EX: btc clears all breaks; bx, bxm creates a breakpoint on any type of execution.\n");
        monprintf("All commands can be built by using [b|bp][TypeFlag][CommandFlag];\n");
        monprintf("All commands can be built by using [b|bp|break] [TypeFlag|alias] [CommandFlag|alias];\n");
        monprintf("Each command has separate arguments from each other.\nFor more details, use help b[reg|m|d|c|l]\n");
        return;
    }
    if (!strcmp(cmd, "breg")) {
        monprintf("Break on register command, special case of the break command.\n");
        monprintf("It allows the user to break when a certain value is inside a register.\n");
        monprintf("All register breaks are conditional.\n");
        monprintf("Usage: breg [regName] [condition] [Expression].\n");
        monprintf("regName is between r0 and r15 (PC, LR and SP included);\n");
        monprintf("expression is an evaluatable expression whose value determines when to break;\n");
        monprintf("condition is the condition to be evaluated in typeFlags.\n");
        printFlagHelp();
        monprintf("---------!!!WARNING!!!---------\n");
        monprintf("Register checking and breaking is extremely expensive for the computer.\n");
        monprintf("On one of the test machines, a maximum value of 600% for speedup collapsed\n");
        monprintf("to 350% just from having them enabled.\n");
        monprintf("If (or while) not needed, you can have a speedup by disabling them, using\n");
        monprintf("disable breg.\n");
        monprintf("Breg is disabled by default. Re-enable them using enable breg.\n");
        monprintf("Use example: breg r0 ne 0x0 --> Breaks as soon as r0 is not 0.\n");
        return;
    }
    if (!strcmp(cmd, "bm")) {
        monprintf("Create breakpoint command. Used to place a breakpoint on a given address.\n");
        monprintf("It allows for breaks on execution(any processor mode) and on access(r/w).\n");
        monprintf("Breaks can be Conditional or Inconditional.\n\n");
        monprintf("Inconditional breaks:\nUsage: [breakTag] [address]\n");
        monprintf("Simplest of the two, the old type of breaks. Creates a breakpoint that, when\n");
        monprintf("the given type flag occurs (like a read, or a run when in thumb mode), halts;\n\n");
        monprintf("Conditional breaks:\n");
        monprintf("Usage:\n\t[breakTag] [address] if {'<type> [expr] [cond] '<type> [expr] <&&,||>}\n");
        monprintf("Where <> elements are optional, {} are repeateable;\n");
        monprintf("[expression] are evaluatable expressions, in the usual VBA format\n(that is, eval acceptable);\n");
        monprintf("type is the type of that expression. Uses C-like names. Omission means integer.\n");
        monprintf("cond is the condition to be evaluated.\n");
        monprintf("If && or || are not present, the chain of evaluation stops.\n");
        monprintf("&& states the next condition must happen with the previous one, or the break\nfails.\n");
        monprintf("|| states the next condition is independent from the last one, and break\nseparately.\n\n");
        monprintf("Type can be:\n");
        monprintf("   [uint8_t, b, byte],[uint16_t, h, hword, halfword],[uint32_t,w, word]\n");
        monprintf("   [int8_t, sb, sbyte],[int16_t, sh, shword, short, shalfword],[int32_t, int, sw, word]\n");
        monprintf("Types have to be preceded by a ' ex: 'int, 'uint8_t\n\n");
        monprintf("Conditions may be:\n");
        monprintf("C-like:\t\t[<], [<=], [>], [>=] , [==], [!= or <>]\n");
        monprintf("ASM-like:\t[lt], [le], [gt], [ge] , [eq], [ne]\n\n");
        monprintf("EX:	bw 0x03005008 if old_value == 'uint32_t [0x03005008]\n");
        monprintf("Breaks on write from 0x03005008, when the old_value variable, that is assigned\n");
        monprintf("as the previous memory value when a write is performed, is equal to the new\ncontents of 0x03005008.\n\n");
        monprintf("EX:	bx 0x08000500 if r0 == 1 || r0 > 1 && r2 == 0 || 'uint8_t [r7] == 5\n");
        monprintf("Breaks in either thumb or arm execution of 0x08000500, if r0's contents are 1,\n");
        monprintf("or if r0's contents are bigger than 1 and r2 is equal to 0, or the content of\nthe address at r7(as byte) is equal to 5.\n");
        monprintf("It will not break if r0 > 1 and r2 != 0.\n");
        return;
    }
    if (!strcmp(cmd, "bl")) {
        monprintf("List breakpoints command. Used to view breakpoints.\n");
        monprintf("Usage: [breakTag] <address> <v>\n");
        monprintf("It will list all breaks on the specified type (read, write..).\n");
        monprintf("If (optional) address is included, it will try and list all breaks of that type\n");
        monprintf("for that address.\n");
        monprintf("The numbers shown on that list (No.) are the ones needed to delete it directly.\n");
        monprintf("v option lists all requested values, even if empty.\n");
        return;
    }
    if (!strcmp(cmd, "bc")) {
        monprintf("Clear breakpoints command. Clears all specified breakpoints.\n");
        monprintf("Usage: [breakTag] <or,||>\n");
        monprintf("It will delete all breaks on all addresses for the specified type.\n");
        monprintf("If (optional) or is included, it will try and delete all breaks associated with\n");
        monprintf("the flags. EX: bic or --> Deletes all breaks on read and all on write.\n");
        return;
    }
    if (!strcmp(cmd, "bd")) {
        monprintf("Delete breakpoint command. Clears the specified breakpoint.\n");
        monprintf("Usage: [breakTag] [address] <only> [number]\n");
        monprintf("It will delete the numbered break on that addresses for the specified type.\n");
        monprintf("If only is included, it will delete only breaks with the specified flag.\n");
        monprintf("EX: bxd 0x8000000 only -->Deletes all breaks on 0x08000000 that break on both\n");
        monprintf("arm and thumb modes. Thumb only or ARM only are unnafected.\n");
        monprintf("EX: btd 0x8000000 5 -->Deletes the thumb break from the 5th break on 0x8000000.\n");
        monprintf("---------!!!WARNING!!!---------\n");
        monprintf("Break numbers are volatile, and may change at any time. before deleting any one\n");
        monprintf("breakpoint, list them to see if the number hasn't changed. The numbers may\n");
        monprintf("change only when you add or delete a breakpoint to that address. Numbers are \n");
        monprintf("internal to each address.\n");
        return;
    }

    for (int i = 0;; i++) {
        if (debuggerCommands[i].name) {
            if (!strcmp(debuggerCommands[i].name, cmd)) {
                snprintf(monbuf, sizeof(monbuf), "%s %s\t%s\n",
                    debuggerCommands[i].name,
                    debuggerCommands[i].syntax ? debuggerCommands[i].syntax : "",
                    debuggerCommands[i].help);
                monprintf(monbuf);
                break;
            }
        } else {
            {
                snprintf(monbuf, sizeof(monbuf), "Unrecognized command '%s'.", cmd);
                monprintf(monbuf);
            }
            break;
        }
    }
}

void debuggerHelp(int n, char** args)
{
    if (n == 2) {
        debuggerUsage(args[1]);
    } else {
        for (int i = 0;; i++) {
            if (debuggerCommands[i].name) {
                {
                    snprintf(monbuf, sizeof(monbuf), "%-10s%s\n", debuggerCommands[i].name, debuggerCommands[i].help);
                    monprintf(monbuf);
                }
            } else
                break;
        }
        {
            snprintf(monbuf, sizeof(monbuf), "%-10s%s\n", "break", "Breakpoint commands");
            monprintf(monbuf);
        }
    }
}

char* strqtok(char* string, const char* ctrl)
{
    static char* nexttoken = NULL;
    char* str;

    if (string != NULL)
        str = string;
    else {
        if (nexttoken == NULL)
            return NULL;
        str = nexttoken;
    };

    char deli[32];
    memset(deli, 0, 32 * sizeof(char));
    while (*ctrl) {
        deli[*ctrl >> 3] |= (1 << (*ctrl & 7));
        ctrl++;
    };
    // can't allow to be set
    deli['"' >> 3] &= ~(1 << ('"' & 7));

    // jump over leading delimiters
    while ((deli[*str >> 3] & (1 << (*str & 7))) && *str)
        str++;

    if (*str == '"') {
        string = ++str;

        // only break if another quote or end of string is found
        while ((*str != '"') && *str)
            str++;
    } else {
        string = str;

        // break on delimiter
        while (!(deli[*str >> 3] & (1 << (*str & 7))) && *str)
            str++;
    };

    if (string == str) {
        nexttoken = NULL;
        return NULL;
    } else {
        if (*str) {
            *str = 0;
            nexttoken = str + 1;
        } else
            nexttoken = NULL;

        return string;
    };
};

void dbgExecute(char* toRun)
{
    char* commands[40];
    int commandCount = 0;
    commands[0] = strqtok(toRun, " \t\n");
    if (commands[0] == NULL)
        return;
    commandCount++;
    while ((commands[commandCount] = strqtok(NULL, " \t\n"))) {
        commandCount++;
        if (commandCount == 40)
            break;
    }

    //from here on, new algorithm.
    // due to the division of functions, some steps have to be made

    //first, convert the command name to a standart lowercase form
    //if more lowercasing needed, do it on the caller.
    for (int i = 0; commands[0][i]; i++) {
        commands[0][i] = (char)tolower(commands[0][i]);
    }

    // checks if it is a quit command, if so quits.
    //if (isQuitCommand(commands[0])){
    //	if (quitConfirm()){
    //		debugger = false;
    //		emulating = false;
    //	}
    //	return;
    //}

    commands[0] = (char*)replaceAlias(commands[0], cmdAliasTable);

    if (commands[0][0] == 'b') {
        executeBreakCommands(commandCount, commands);
        if (commands[0][0] == '!')
            commands[0][0] = 'b';
        else
            return;
    }

    //although it mights seem weird, the old step is the last one to be executed.
    for (int j = 0;; j++) {
        if (debuggerCommands[j].name == NULL) {
            {
                snprintf(monbuf, sizeof(monbuf), "Unrecognized command %s. Type h for help.\n", commands[0]);
                monprintf(monbuf);
            }
            return;
        }
        if (!strcmp(commands[0], debuggerCommands[j].name)) {
            debuggerCommands[j].function(commandCount, commands);
            return;
        }
    }
}

void dbgExecute(std::string& cmd)
{
    char* dbgCmd = new char[cmd.length() + 1];
#if __STDC_WANT_SECURE_LIB__
    strcpy_s(dbgCmd, cmd.length() + 1, cmd.c_str());
#else
    strcpy(dbgCmd, cmd.c_str());
#endif
    dbgExecute(dbgCmd);
    delete[] dbgCmd;
}

int remoteTcpSend(char* data, int len)
{
    return send(remoteSocket, data, len, 0);
}

int remoteTcpRecv(char* data, int len)
{
    return recv(remoteSocket, data, len, 0);
}

bool remoteTcpInit()
{
    if (remoteSocket == INVALID_SOCKET) {
#ifdef _WIN32
        WSADATA wsaData;
#ifdef _DEBUG
        int error = WSAStartup(MAKEWORD(1, 1), &wsaData);
        fprintf(stderr, "WSAStartup: %d\n", error);
#else
        WSAStartup(MAKEWORD(1, 1), &wsaData);
#endif
#endif // _WIN32
        SOCKET s = socket(PF_INET, SOCK_STREAM, 0);

        remoteListenSocket = s;

        if (s == INVALID_SOCKET) {
            fprintf(stderr, "Error opening socket\n");
            exit(-1);
        }
        int tmp = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (char*)&tmp, sizeof(tmp));

        //    char hostname[256];
        //    gethostname(hostname, 256);

        //    hostent *ent = gethostbyname(hostname);
        //    unsigned long a = *((unsigned long *)ent->h_addr);

        sockaddr_in addr;
        addr.sin_family = AF_INET;
        addr.sin_port = htons((unsigned short)remotePort);
        addr.sin_addr.s_addr = htonl(0);
        int count = 0;
        while (count < 3) {
            if (bind(s, (sockaddr*)&addr, sizeof(addr))) {
                addr.sin_port = htons(ntohs(addr.sin_port) + 1);
            } else
                break;
        }
        if (count == 3) {
            fprintf(stderr, "Error binding \n");
            exit(-1);
        }

        fprintf(stderr, "Listening for a connection at port %d\n",
            ntohs(addr.sin_port));

        if (listen(s, 1)) {
            fprintf(stderr, "Error listening\n");
            exit(-1);
        }
        socklen_t len = sizeof(addr);

#ifdef _WIN32
        int flag = 0;
        ioctlsocket(s, FIONBIO, (unsigned long*)&flag);
#endif // _WIN32
        SOCKET s2 = accept(s, (sockaddr*)&addr, &len);
        if (s2 > 0) {
            fprintf(stderr, "Got a connection from %s %d\n",
                inet_ntoa((in_addr)addr.sin_addr),
                ntohs(addr.sin_port));
        } else {
#ifdef _WIN32
#ifdef _DEBUG
            int _error = WSAGetLastError();
            fprintf(stderr, "WSA Error: %d\n", _error);
#endif
#endif // _WIN32
        }
        //char dummy;
        //recv(s2, &dummy, 1, 0);
        //if(dummy != '+') {
        //  fprintf(stderr, "ACK not received\n");
        //  exit(-1);
        //}
        remoteSocket = s2;
        //    close(s);
    }
    return true;
}

void remoteTcpCleanUp()
{
    if (remoteSocket > 0) {
        fprintf(stderr, "Closing remote socket\n");
        close(remoteSocket);
        remoteSocket = (SOCKET)(-1);
    }
    if (remoteListenSocket > 0) {
        fprintf(stderr, "Closing listen socket\n");
        close(remoteListenSocket);
        remoteListenSocket = (SOCKET)(-1);
    }
}

int remotePipeSend(char* data, int len)
{
    int res = write(1, data, len);
    return res;
}

int remotePipeRecv(char* data, int len)
{
    int res = read(0, data, len);
    return res;
}

bool remotePipeInit()
{
    //  char dummy;
    //  if (read(0, &dummy, 1) == 1)
    //  {
    //    if(dummy != '+') {
    //      fprintf(stderr, "ACK not received\n");
    //      exit(-1);
    //    }
    //  }

    return true;
}

void remotePipeCleanUp()
{
}

void remoteSetPort(int port)
{
    remotePort = port;
}

void remoteSetProtocol(int p)
{
    if (p == 0) {
        remoteSendFnc = remoteTcpSend;
        remoteRecvFnc = remoteTcpRecv;
        remoteInitFnc = remoteTcpInit;
        remoteCleanUpFnc = remoteTcpCleanUp;
    } else {
        remoteSendFnc = remotePipeSend;
        remoteRecvFnc = remotePipeRecv;
        remoteInitFnc = remotePipeInit;
        remoteCleanUpFnc = remotePipeCleanUp;
    }
}

void remoteInit()
{
    if (remoteInitFnc)
        remoteInitFnc();
}

void remotePutPacket(const char* packet)
{
    const char* hex = "0123456789abcdef";

    size_t count = strlen(packet);
    char* buffer = new char[count + 5];

    unsigned char csum = 0;

    char* p = buffer;
    *p++ = '$';

    for (size_t i = 0; i < count; i++) {
        csum += packet[i];
        *p++ = packet[i];
    }
    *p++ = '#';
    *p++ = hex[csum >> 4];
    *p++ = hex[csum & 15];
    *p++ = 0;
    //log("send: %s\n", buffer);

    char c = 0;
    while (c != '+') {
        remoteSendFnc(buffer, (int)count + 4);

        if (remoteRecvFnc(&c, 1) < 0) {
            delete[] buffer;
            return;
        }
        //    fprintf(stderr,"sent:%s recieved:%c\n",buffer,c);
    }

    delete[] buffer;
}

void remoteOutput(const char* s, uint32_t addr)
{
    char buffer[16384];

    char* d = buffer;
    *d++ = 'O';

    if (s) {
        char c = *s++;
        while (c) {
            snprintf(d, (sizeof(buffer) - (d - buffer)), "%02x", c);
            d += 2;
            c = *s++;
        }
    } else {
        char c = debuggerReadByte(addr);
        addr++;
        while (c) {
            snprintf(d, (sizeof(buffer) - (d - buffer)), "%02x", c);
            d += 2;
            c = debuggerReadByte(addr);
            addr++;
        }
    }
    remotePutPacket(buffer);
    //  fprintf(stderr, "Output sent %s\n", buffer);
}

void remoteSendSignal()
{
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "S%02x", remoteSignal);
    remotePutPacket(buffer);
}

void remoteSendStatus()
{
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "T%02x", remoteSignal);
    char* s = buffer;
    s += 3;
    for (int i = 0; i < 15; i++) {
        uint32_t v = reg[i].I;
        snprintf(s, (sizeof(buffer) - (s - buffer)), "%02x:%02x%02x%02x%02x;", i,
            (v & 255),
            (v >> 8) & 255,
            (v >> 16) & 255,
            (v >> 24) & 255);
        s += 12;
    }
    uint32_t v = armNextPC;
    snprintf(s, (sizeof(buffer) - (s - buffer)), "0f:%02x%02x%02x%02x;", (v & 255),
        (v >> 8) & 255,
        (v >> 16) & 255,
        (v >> 24) & 255);
    s += 12;
    CPUUpdateCPSR();
    v = reg[16].I;
    snprintf(s, (sizeof(buffer) - (s - buffer)), "19:%02x%02x%02x%02x;", (v & 255),
        (v >> 8) & 255,
        (v >> 16) & 255,
        (v >> 24) & 255);
    s += 12;
    *s = 0;
    //log("Sending %s\n", buffer);
    remotePutPacket(buffer);
}

void remoteBinaryWrite(char* p)
{
    uint32_t address;
    int count;
    sscanf(p, "%x,%x:", &address, &count);
    //  monprintf("Binary write for %08x %d\n", address, count);

    p = strchr(p, ':');
    p++;
    for (int i = 0; i < count; i++) {
        uint8_t b = *p++;
        switch (b) {
        case 0x7d:
            b = *p++;
            debuggerWriteByte(address, (b ^ 0x20));
            address++;
            break;
        default:
            debuggerWriteByte(address, b);
            address++;
            break;
        }
    }
    //  monprintf("ROM is %08x\n", debuggerReadMemory(0x8000254));
    remotePutPacket("OK");
}

void remoteMemoryWrite(char* p)
{
    uint32_t address;
    int count;
    sscanf(p, "%x,%x:", &address, &count);
    //  monprintf("Memory write for %08x %d\n", address, count);

    p = strchr(p, ':');
    p++;
    for (int i = 0; i < count; i++) {
        uint8_t v = 0;
        char c = *p++;
        if (c <= '9')
            v = (c - '0') << 4;
        else
            v = (c + 10 - 'a') << 4;
        c = *p++;
        if (c <= '9')
            v += (c - '0');
        else
            v += (c + 10 - 'a');
        debuggerWriteByte(address, v);
        address++;
    }
    //  monprintf("ROM is %08x\n", debuggerReadMemory(0x8000254));
    remotePutPacket("OK");
}

void remoteMemoryRead(char* p)
{
    uint32_t address;
    int count;
    sscanf(p, "%x,%x:", &address, &count);
    //  monprintf("Memory read for %08x %d\n", address, count);

    char* buffer = new char[(count*2)+1];

    char* s = buffer;
    for (int i = 0; i < count; i++) {
        uint8_t b = debuggerReadByte(address);
        snprintf(s, (count*2), "%02x", b);
        address++;
        s += 2;
    }
    *s = 0;
    remotePutPacket(buffer);

    delete[] buffer;
}

void remoteQuery(char* p)
{
    if (!strncmp(p, "fThreadInfo", 11)) {
        remotePutPacket("m1");
    } else if (!strncmp(p, "sThreadInfo", 11)) {
        remotePutPacket("l");
    } else if (!strncmp(p, "Supported", 9)) {
        remotePutPacket("PacketSize=1000");
    } else if (!strncmp(p, "HostInfo", 8)) {
        remotePutPacket("cputype:12;cpusubtype:5;ostype:unknown;vendor:nintendo;endian:little;ptrsize:4;");
    } else if (!strncmp(p, "C", 1)) {
        remotePutPacket("QC1");
    } else if (!strncmp(p, "Attached", 8)) {
        remotePutPacket("1");
    } else if (!strncmp(p, "Symbol", 6)) {
        remotePutPacket("OK");
    } else if (!strncmp(p, "Rcmd,", 5)) {
        p += 5;
        std::string cmd = HexToString(p);
        dbgExecute(cmd);
        remotePutPacket("OK");
    } else {
        fprintf(stderr, "Unknown packet %s\n", --p);
        remotePutPacket("");
    }
}

void remoteStepOverRange(char* p)
{
    uint32_t address;
    uint32_t final;
    sscanf(p, "%x,%x", &address, & final);

    remotePutPacket("OK");

    remoteResumed = true;
    do {
        CPULoop(1);
        if (debugger)
            break;
    } while (armNextPC >= address && armNextPC < final);

    remoteResumed = false;

    remoteSendStatus();
}

void remoteSetBreakPoint(char* p)
{
    uint32_t address;
    int count;
    sscanf(p, ",%x,%x#", &address, &count);

    for (int n = 0; n < count; n += 4)
        addConditionalBreak(address + n, armState ? 0x04 : 0x08);

    // Out of bounds memory checks
    //if (address < 0x2000000 || address > 0x3007fff) {
    //	remotePutPacket("E01");
    //	return;
    //}

    //if (address > 0x203ffff && address < 0x3000000) {
    //	remotePutPacket("E01");
    //	return;
    //}

    //uint32_t final = address + count;

    //if (address < 0x2040000 && final > 0x2040000) {
    //	remotePutPacket("E01");
    //	return;
    //}
    //else if (address < 0x3008000 && final > 0x3008000) {
    //	remotePutPacket("E01");
    //	return;
    //}
    remotePutPacket("OK");
}

void remoteClearBreakPoint(char* p)
{
    int result = 0;
    uint32_t address;
    int count;
    sscanf(p, ",%x,%x#", &address, &count);

    for (int n = 0; n < count; n += 4)
        result = removeConditionalWithAddressAndFlag(address + n, armState ? 0x04 : 0x08, true);

    if (result != -2)
        remotePutPacket("OK");
    else
        remotePutPacket("");
}

void remoteSetMemoryReadBreakPoint(char* p)
{
    uint32_t address;
    int count;
    sscanf(p, ",%x,%x#", &address, &count);

    for (int n = 0; n < count; n++)
        addConditionalBreak(address + n, 0x02);

    // Out of bounds memory checks
    //if (address < 0x2000000 || address > 0x3007fff) {
    //	remotePutPacket("E01");
    //	return;
    //}

    //if (address > 0x203ffff && address < 0x3000000) {
    //	remotePutPacket("E01");
    //	return;
    //}

    //uint32_t final = address + count;

    //if (address < 0x2040000 && final > 0x2040000) {
    //	remotePutPacket("E01");
    //	return;
    //}
    //else if (address < 0x3008000 && final > 0x3008000) {
    //	remotePutPacket("E01");
    //	return;
    //}
    remotePutPacket("OK");
}

void remoteClearMemoryReadBreakPoint(char* p)
{
    bool error = false;
    int result;
    uint32_t address;
    int count;
    sscanf(p, ",%x,%x#", &address, &count);

    for (int n = 0; n < count; n++) {
        result = removeConditionalWithAddressAndFlag(address + n, 0x02, true);
        if (result == -2)
            error = true;
    }

    if (!error)
        remotePutPacket("OK");
    else
        remotePutPacket("");
}

void remoteSetMemoryAccessBreakPoint(char* p)
{
    uint32_t address;
    int count;
    sscanf(p, ",%x,%x#", &address, &count);

    for (int n = 0; n < count; n++)
        addConditionalBreak(address + n, 0x03);

    // Out of bounds memory checks
    //if (address < 0x2000000 || address > 0x3007fff) {
    //	remotePutPacket("E01");
    //	return;
    //}

    //if (address > 0x203ffff && address < 0x3000000) {
    //	remotePutPacket("E01");
    //	return;
    //}

    //uint32_t final = address + count;

    //if (address < 0x2040000 && final > 0x2040000) {
    //	remotePutPacket("E01");
    //	return;
    //}
    //else if (address < 0x3008000 && final > 0x3008000) {
    //	remotePutPacket("E01");
    //	return;
    //}
    remotePutPacket("OK");
}

void remoteClearMemoryAccessBreakPoint(char* p)
{
    bool error = false;
    int result;
    uint32_t address;
    int count;
    sscanf(p, ",%x,%x#", &address, &count);

    for (int n = 0; n < count; n++) {
        result = removeConditionalWithAddressAndFlag(address + n, 0x03, true);
        if (result == -2)
            error = true;
    }

    if (!error)
        remotePutPacket("OK");
    else
        remotePutPacket("");
}

void remoteWriteWatch(char* p, bool active)
{
    uint32_t address;
    int count;
    sscanf(p, ",%x,%x#", &address, &count);

    if (active) {
        for (int n = 0; n < count; n++)
            addConditionalBreak(address + n, 0x01);
    } else {
        for (int n = 0; n < count; n++)
            removeConditionalWithAddressAndFlag(address + n, 0x01, true);
    }

    // Out of bounds memory check
    //fprintf(stderr, "Write watch for %08x %d\n", address, count);

    //if(address < 0x2000000 || address > 0x3007fff) {
    //  remotePutPacket("E01");
    //  return;
    //}

    //if(address > 0x203ffff && address < 0x3000000) {
    //  remotePutPacket("E01");
    //  return;
    //}

    // uint32_t final = address + count;

//if(address < 0x2040000 && final > 0x2040000) {
//  remotePutPacket("E01");
//  return;
//} else if(address < 0x3008000 && final > 0x3008000) {
//  remotePutPacket("E01");
//  return;
//}

#ifdef VBAM_ENABLE_DEBUGGER
    for (int i = 0; i < count; i++) {
        if ((address >> 24) == 2)
            freezeWorkRAM[address & 0x3ffff] = active;
        else
            freezeInternalRAM[address & 0x7fff] = active;
        address++;
    }
#endif

    remotePutPacket("OK");
}

void remoteReadRegister(char* p)
{
    int r;
    sscanf(p, "%x", &r);
    if(r < 0 || r > 15)
    {
        remotePutPacket("E 00");
        return;
    }
    char buffer[1024];
    char* s = buffer;
    uint32_t v = reg[r].I;
    snprintf(s, sizeof(buffer), "%02x%02x%02x%02x", v & 255, (v >> 8) & 255,
        (v >> 16) & 255, (v >> 24) & 255);
    remotePutPacket(buffer);
}

void remoteReadRegisters(char* p)
{
    (void)p; // unused params
    char buffer[1024];

    char* s = buffer;
    int i;
    // regular registers
    for (i = 0; i < 15; i++) {
        uint32_t v = reg[i].I;
        snprintf(s, sizeof(buffer), "%02x%02x%02x%02x", v & 255, (v >> 8) & 255,
            (v >> 16) & 255, (v >> 24) & 255);
        s += 8;
    }
    // PC
    uint32_t pc = armNextPC;
    snprintf(s, sizeof(buffer) - 8, "%02x%02x%02x%02x", pc & 255, (pc >> 8) & 255,
        (pc >> 16) & 255, (pc >> 24) & 255);
    s += 8;

    // floating point registers (24-bit)
    for (i = 0; i < 8; i++) {
        snprintf(s, sizeof(buffer) - 16, "000000000000000000000000");
        s += 24;
    }

    // FP status register
    snprintf(s, sizeof(buffer) - 40, "00000000");
    s += 8;
    // CPSR
    CPUUpdateCPSR();
    uint32_t v = reg[16].I;
    snprintf(s, sizeof(buffer) - 48, "%02x%02x%02x%02x", v & 255, (v >> 8) & 255,
        (v >> 16) & 255, (v >> 24) & 255);
    s += 8;
    *s = 0;
    remotePutPacket(buffer);
}

void remoteWriteRegister(char* p)
{
    int r;

    sscanf(p, "%x=", &r);

    if(r < 0 || r > 16)
    {
        remotePutPacket("E 00");
        return;
    }

    p = strchr(p, '=');
    p++;

    char c = *p++;

    uint32_t v = 0;

    uint8_t data[4] = { 0, 0, 0, 0 };

    int i = 0;

    while (i < 4) {
        uint8_t b = 0;
        if (c <= '9')
            b = (c - '0') << 4;
        else
            b = (c + 10 - 'a') << 4;
        c = *p++;
        if (c <= '9')
            b += (c - '0');
        else
            b += (c + 10 - 'a');
        data[i++] = b;
        c = *p++;
    }

    v = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);

    //  monprintf("Write register %d=%08x\n", r, v);
    if (r == 16) {
        bool savedArmState = armState;
        reg[r].I = v;
        CPUUpdateFlags();
        if (armState != savedArmState) {
            if (armState) {
                reg[15].I &= 0xFFFFFFFC;
                armNextPC = reg[15].I;
                reg[15].I += 4;
                ARM_PREFETCH;
            } else {
                reg[15].I &= 0xFFFFFFFE;
                armNextPC = reg[15].I;
                reg[15].I += 2;
                THUMB_PREFETCH;
            }
        }
    } else {
        reg[r].I = v;
        if (r == 15) {
            if (armState) {
                reg[15].I = v & 0xFFFFFFFC;
                armNextPC = reg[15].I;
                reg[15].I += 4;
                ARM_PREFETCH;
            } else {
                reg[15].I = v & 0xFFFFFFFE;
                armNextPC = reg[15].I;
                reg[15].I += 2;
                THUMB_PREFETCH;
            }
        }
    }
    remotePutPacket("OK");
}

void remoteStubMain()
{
    if (!debugger)
        return;

    if (remoteResumed) {
        remoteSendStatus();
        remoteResumed = false;
    }

    const char* hex = "0123456789abcdef";
    while (1) {
        char ack;
        char buffer[1024];
        int res = remoteRecvFnc(buffer, 1024);

        if (res == -1) {
            fprintf(stderr, "GDB connection lost\n");
            debugger = false;
            break;
        } else if (res == -2)
            break;
        if (res < 1024) {
            buffer[res] = 0;
        } else {
            fprintf(stderr, "res=%d\n", res);
        }

        //    fprintf(stderr, "res=%d Received %s\n",res, buffer);
        char c = buffer[0];
        char* p = &buffer[0];
        int i = 0;
        unsigned char csum = 0;
        while (i < res) {
            if (buffer[i] == '$') {
                i++;
                csum = 0;
                c = buffer[i];
                p = &buffer[i + 1];
                while ((i < res) && (buffer[i] != '#')) {
                    csum += buffer[i];
                    i++;
                }
            } else if (buffer[i] == '#') {
                buffer[i] = 0;
                if ((i + 2) < res) {
                    if ((buffer[i + 1] == hex[csum >> 4]) && (buffer[i + 2] == hex[csum & 0xf])) {
                        ack = '+';
                        remoteSendFnc(&ack, 1);
                        //fprintf(stderr, "SentACK c=%c\n",c);
                        //process message...
                        char type;
                        switch (c) {
                        case '?':
                            remoteSendSignal();
                            break;
                        case 'D':
                            remotePutPacket("OK");
                            remoteResumed = true;
                            debugger = false;
                            return;
                        case 'e':
                            remoteStepOverRange(p);
                            break;
                        case 'k':
                            remotePutPacket("OK");
                            debugger = false;
                            emulating = false;
                            return;
                        case 'C':
                            remoteResumed = true;
                            debugger = false;
                            return;
                        case 'c':
                            remoteResumed = true;
                            debugger = false;
                            return;
                        case 's':
                            remoteResumed = true;
                            remoteSignal = 5;
                            CPULoop(1);
                            if (remoteResumed) {
                                remoteResumed = false;
                                remoteSendStatus();
                            }
                            break;
                        case 'g':
                            remoteReadRegisters(p);
                            break;
                        case 'p':
                            remoteReadRegister(p);
                            break;
                        case 'P':
                            remoteWriteRegister(p);
                            break;
                        case 'M':
                            remoteMemoryWrite(p);
                            break;
                        case 'm':
                            remoteMemoryRead(p);
                            break;
                        case 'X':
                            remoteBinaryWrite(p);
                            break;
                        case 'H':
                            remotePutPacket("OK");
                            break;
                        case 'q':
                            remoteQuery(p);
                            break;
                        case 'Z':
                            type = *p++;
                            if (type == '0') {
                                remoteSetBreakPoint(p);
                            } else if (type == '1') {
                                remoteSetBreakPoint(p);
                            } else if (type == '2') {
                                remoteWriteWatch(p, true);
                            } else if (type == '3') {
                                remoteSetMemoryReadBreakPoint(p);
                            } else if (type == '4') {
                                remoteSetMemoryAccessBreakPoint(p);
                            } else {
                                remotePutPacket("");
                            }
                            break;
                        case 'z':
                            type = *p++;
                            if (type == '0') {
                                remoteClearBreakPoint(p);
                            } else if (type == '1') {
                                remoteClearBreakPoint(p);
                            } else if (type == '2') {
                                remoteWriteWatch(p, false);
                            } else if (type == '3') {
                                remoteClearMemoryReadBreakPoint(p);
                            } else if (type == '4') {
                                remoteClearMemoryAccessBreakPoint(p);
                            } else {
                                remotePutPacket("");
                            }
                            break;
                        default: {
                            fprintf(stderr, "Unknown packet %s\n", --p);
                            remotePutPacket("");
                        } break;
                        }
                    } else {
                        fprintf(stderr, "bad chksum csum=%x msg=%c%c\n", csum, buffer[i + 1], buffer[i + 2]);
                        ack = '-';
                        remoteSendFnc(&ack, 1);
                        fprintf(stderr, "SentNACK\n");
                    } //if
                    i += 3;
                } else {
                    fprintf(stderr, "didn't receive chksum i=%d res=%d\n", i, res);
                    i++;
                } //if
            } else {
                if (buffer[i] != '+') { //ingnore ACKs
                    fprintf(stderr, "not sure what to do with:%c i=%d res=%d\n", buffer[i], i, res);
                }
                i++;
            } //if
        } //while
    }
}

void remoteStubSignal(int sig, int number)
{
    (void)number; // unused params
    remoteSignal = sig;
    remoteResumed = false;
    remoteSendStatus();
    debugger = true;
}

void remoteCleanUp()
{
    if (remoteCleanUpFnc)
        remoteCleanUpFnc();
}

std::string HexToString(char* p)
{
    std::string hex(p);
    std::string cmd;
    std::stringstream ss;
    uint32_t offset = 0;
    while (offset < hex.length()) {
        unsigned int buffer = 0;
        ss.clear();
        ss << std::hex << hex.substr(offset, 2);
        ss >> std::hex >> buffer;
        cmd.push_back(static_cast<unsigned char>(buffer));
        offset += 2;
    }
    return cmd;
}

std::string StringToHex(std::string& cmd)
{
    std::stringstream ss;
    ss << std::hex;
    for (uint32_t i = 0; i < cmd.length(); ++i)
        ss << std::setw(2) << std::setfill('0') << (int)cmd.c_str()[i];
    return ss.str();
}

void monprintf(std::string line)
{
    std::string output = "O";
    line = StringToHex(line);
    output += line;

    if (output.length() <= 1000) {
        char dbgReply[1000];
#if __STDC_WANT_SECURE_LIB__
        strcpy_s(dbgReply, sizeof(dbgReply), output.c_str());
#else
        strcpy(dbgReply, output.c_str());
#endif
        remotePutPacket(dbgReply);
    }
}
/* END gbaRemote.cpp */

#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
