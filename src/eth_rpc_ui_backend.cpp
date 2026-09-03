#include "eth_rpc_ui_backend.h"

#include <limits>

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

// The generated umbrella carrying `struct LogosModules` — without it `modules()` is an
// incomplete type and every dependency call fails to compile.
#include "logos_sdk.h"

namespace {

// eth_rpc caches a verdict for 5s, so a faster poll only re-pays the probe budget.
constexpr int kVerdictPollMs = 5000;
// How long a call may be outstanding before its callback is treated as LOST rather than
// late. It matches the deadline handed to the transport, so there is one number, not two.
constexpr int kCallBudgetMs = 20000;
// Verdict polls that learned nothing tolerated (~15s) before the badge goes to "unreadable".
// One transport blip must not repaint it; a backend that stopped answering must not leave
// "ready" on screen while nothing is being verified.
constexpr int kMaxSilentPolls = 3;

// eth_rpc's own defaults (its rust-lib/src/rpc.rs default_timeout / default_verified_timeout),
// shown for a chain it has no record of. A second copy free to drift — but a form with empty
// boxes cannot tell the user what the value would be.
constexpr int kDefaultTimeoutSecs = 8;
constexpr int kDefaultVerifiedTimeoutSecs = 15;

// Display names only. NOT a security boundary and NOT an allowlist: eth_rpc will configure
// any chain id, and an id absent from this table renders as "Chain 42161" with no `testnet`
// claim at all. The wallet's own network allowlist is a different list answering a different
// question, and is deliberately not imported here.
struct KnownChain
{
    int id;
    const char *name;
    bool testnet;
};
constexpr KnownChain kKnownChains[] = {
    {1, "Ethereum", false},
    {11155111, "Sepolia", true},
    {560048, "Hoodi", true},
};

const KnownChain *known(int id)
{
    for (const KnownChain &k : kKnownChains)
        if (k.id == id)
            return &k;
    return nullptr;
}

QJsonObject parseObject(const QString &reply)
{
    return QJsonDocument::fromJson(reply.toUtf8()).object();
}

bool replyOk(const QString &reply)
{
    return parseObject(reply).value(QStringLiteral("ok")).toBool();
}

QString replyError(const QString &reply)
{
    const QString e = parseObject(reply).value(QStringLiteral("error")).toString();
    return e.isEmpty() ? QStringLiteral("eth_rpc refused the request") : e;
}

QString compact(const QJsonObject &o)
{
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString compact(const QJsonArray &a)
{
    return QString::fromUtf8(QJsonDocument(a).toJson(QJsonDocument::Compact));
}

/// One `chainsJson` row, flattened from eth_rpc's `{ ok, config }`. A failed read is not an
/// error here: a chain eth_rpc has no record of is exactly what `configured: false` says.
QJsonObject chainEntry(int id, const QString &configReply)
{
    const KnownChain *k = known(id);
    QJsonObject e{
        {QStringLiteral("chainId"), id},
        {QStringLiteral("name"), k ? QString::fromLatin1(k->name)
                                   : QStringLiteral("Chain %1").arg(id)},
    };
    // Absent, never false: calling an unrecognised chain "mainnet" is the one wrong answer.
    if (k)
        e[QStringLiteral("testnet")] = k->testnet;

    const bool configured = replyOk(configReply);
    const QJsonObject c = parseObject(configReply).value(QStringLiteral("config")).toObject();
    e[QStringLiteral("configured")] = configured;
    e[QStringLiteral("endpoint")] = c.value(QStringLiteral("endpoint")).toString();
    e[QStringLiteral("proxy")] = c.value(QStringLiteral("proxy")).toString();
    e[QStringLiteral("proxyRequired")] = c.value(QStringLiteral("proxyRequired")).toBool();
    e[QStringLiteral("timeoutSecs")] =
        c.value(QStringLiteral("timeoutSecs")).toInt(kDefaultTimeoutSecs);
    e[QStringLiteral("verifiedTimeoutSecs")] =
        c.value(QStringLiteral("verifiedTimeoutSecs")).toInt(kDefaultVerifiedTimeoutSecs);
    e[QStringLiteral("verifiedProxyMode")] =
        c.value(QStringLiteral("verifiedProxyMode")).toString(QStringLiteral("off"));
    return e;
}

/// The verdict to publish once eth_rpc has stopped answering. It mirrors the shape eth_rpc
/// emits and cannot be sourced from there for the obvious reason. Unknown is not "off".
QString unreadableVerdict(int chainId)
{
    return compact(QJsonObject{
        {QStringLiteral("ok"), false},
        {QStringLiteral("chainId"), chainId},
        {QStringLiteral("mode"), QStringLiteral("unknown")},
        {QStringLiteral("state"), QStringLiteral("unhealthy")},
        {QStringLiteral("usable"), false},
        {QStringLiteral("blocking"), true},
        {QStringLiteral("message"), QStringLiteral("The verified-routing state could not be read.")},
        {QStringLiteral("action"), QStringLiteral("restart_or_reload")},
        {QStringLiteral("detail"), QStringLiteral("eth_rpc stopped answering")},
    });
}

} // namespace

bool EthRpcUiBackend::failed(const QString &reply, const QString &context)
{
    if (replyOk(reply))
        return false;
    setLastError(context.isEmpty() ? replyError(reply)
                                   : QStringLiteral("%1: %2").arg(context, replyError(reply)));
    return true;
}

QList<int> EthRpcUiBackend::roster() const
{
    QList<int> out;
    for (const KnownChain &k : kKnownChains)
        out.append(k.id);

    const QJsonArray configured =
        parseObject(modules().eth_rpc_module.list_chains()).value(QStringLiteral("chains")).toArray();
    for (const QJsonValue &v : configured) {
        // The .rep carries chain ids as int, so an id past 2^31 cannot be selected, edited
        // or removed from this app. Dropping it is honest; showing an unusable row is not.
        const qint64 id = v.toInteger(0);
        if (id > 0 && id <= std::numeric_limits<int>::max() && !out.contains(static_cast<int>(id)))
            out.append(static_cast<int>(id));
    }
    for (int id : m_asked)
        if (!out.contains(id))
            out.append(id);
    return out;
}

void EthRpcUiBackend::onContextReady()
{
    m_verdictPoll.setInterval(kVerdictPollMs);
    QObject::connect(&m_verdictPoll, &QTimer::timeout, [this] {
        // A tick that could not even ask has still learned nothing, and silence is what the
        // staleness bound counts — one unanswered probe would otherwise hold a verdict on
        // screen forever.
        if (m_verdictInFlight.busy())
            applyVerdict(QString(), selectedChainId());
        else
            refreshVerdict();
    });
    m_verdictPoll.start();

    // This app is a viewer of a store it does not own: the wallet seeds chains through
    // `init_defaults` and `seed_chain_config`, and a second instance of this app edits the
    // same file. `chain_config_changed` is the event for exactly that — one chain's record
    // moved, re-read it — and it accompanies every mode change, so subscribing to
    // `verified_proxy_mode_changed` as well would only refresh twice for one move.
    //
    // Queued, not immediate: `refresh()` reads every chain synchronously, and this arrives on
    // an IPC callback. The verdict poll stays — proxy HEALTH moves with no event behind it.
    modules().eth_rpc_module.onChain_config_changed([this](int) {
        QTimer::singleShot(0, this, [this] { refresh(); });
    });

    refresh();
}

void EthRpcUiBackend::refresh()
{
    setBusy(true);
    setLastError(QString());

    QJsonArray chains;
    bool kept = false;
    for (int id : roster()) {
        chains.append(chainEntry(id, modules().eth_rpc_module.get_chain_config(id)));
        kept = kept || id == selectedChainId();
    }
    setChainsJson(compact(chains));

    // Fall to the first row when the selection is gone, rather than leaving the form
    // pointed at a chain this app no longer offers.
    if (!kept)
        setSelectedChainId(chains.isEmpty()
                               ? 0
                               : chains.first().toObject().value(QStringLiteral("chainId")).toInt());

    setStatusText(QStringLiteral("Ready"));
    setBusy(false);
    refreshVerdict();
}

void EthRpcUiBackend::selectChain(int chainId)
{
    if (chainId <= 0)
        return;
    if (chainId != selectedChainId()) {
        // A verdict and a probe read for the previous chain say nothing about this one.
        setVerdictJson(QStringLiteral("{}"));
        setProbeJson(QStringLiteral("{}"));
        m_verdictSilent = 0;
    }
    setSelectedChainId(chainId);
    // Also how "Add chain by id" works: an id eth_rpc has no record of stays on the list
    // long enough for the user to give it an endpoint.
    if (!m_asked.contains(chainId))
        m_asked.append(chainId);
    refresh();
}

void EthRpcUiBackend::setEndpoint(int chainId, QString url)
{
    setLastError(QString());
    const QString trimmed = url.trimmed();
    if (trimmed.isEmpty()) {
        setLastError(QStringLiteral("enter a JSON-RPC endpoint URL"));
        return;
    }
    if (failed(modules().eth_rpc_module.patch_chain_endpoint(chainId, trimmed),
               QStringLiteral("endpoint")))
        return;
    // Whatever the last test proved, it proved it about a different endpoint.
    setProbeJson(QStringLiteral("{}"));
    refresh();
}

void EthRpcUiBackend::setVerifiedProxyMode(int chainId, QString mode)
{
    setLastError(QString());
    failed(modules().eth_rpc_module.set_verified_proxy_mode(chainId, mode),
           QStringLiteral("verified routing"));
    // Refreshed on refusal too: the view re-applies the STORED mode from this reply, so a
    // switch the user moved and eth_rpc declined snaps back instead of showing a setting
    // they never got. The verdict on screen was read under the previous mode either way.
    setVerdictJson(QStringLiteral("{}"));
    m_verdictSilent = 0;
    refresh();
}

void EthRpcUiBackend::setTimeouts(int chainId, int timeoutSecs, int verifiedTimeoutSecs)
{
    setLastError(QString());
    const QString reply =
        modules().eth_rpc_module.patch_chain_transport(chainId, timeoutSecs, verifiedTimeoutSecs);
    if (!replyOk(reply)) {
        // eth_rpc answers a bare `{ok:false}` for a chain it has no record of — the only
        // reachable failure, and one it gives no message of its own.
        setLastError(QStringLiteral("chain %1 has no stored configuration yet: save an "
                                    "endpoint first").arg(chainId));
        return;
    }
    refresh();
}

void EthRpcUiBackend::removeChain(int chainId)
{
    setLastError(QString());
    if (!modules().eth_rpc_module.remove_chain_config(chainId))
        setLastError(QStringLiteral("chain %1 had no stored configuration to remove").arg(chainId));
    // Drop the user's ask too, or a chain removed here reappears as an empty row forever.
    m_asked.removeAll(chainId);
    setProbeJson(QStringLiteral("{}"));
    setVerdictJson(QStringLiteral("{}"));
    m_verdictSilent = 0;
    refresh();
}

void EthRpcUiBackend::testEndpoint(int chainId)
{
    setLastError(QString());
    quint64 slot = 0;
    if (!m_probeInFlight.take(kCallBudgetMs, &slot))
        return;
    setProbeJson(QStringLiteral("{}"));
    setStatusText(QStringLiteral("Testing chain %1…").arg(chainId));

    // ASYNC deliberately: this runs on the GUI thread and a dead endpoint costs the chain's
    // whole transport timeout before it answers.
    modules().eth_rpc_module.verify_chain_idAsyncResult(chainId,
        [this, chainId, slot](logos::AsyncResult<QString> r) {
            m_probeInFlight.release(slot);
            setStatusText(QStringLiteral("Ready"));

            QJsonObject out{{QStringLiteral("chainId"), chainId}};
            if (!r.ok()) {
                out[QStringLiteral("ok")] = false;
                out[QStringLiteral("error")] = QStringLiteral("eth_rpc did not answer the test");
            } else if (replyOk(r.value)) {
                const QJsonObject reply = parseObject(r.value);
                out[QStringLiteral("ok")] = true;
                // What the endpoint SAID it is. The view compares it with `chainId`: an
                // endpoint answering for another network is configured against the wrong one.
                out[QStringLiteral("reportedChainId")] =
                    reply.value(QStringLiteral("chainId")).toInteger(0);
                out[QStringLiteral("route")] = reply.value(QStringLiteral("route")).toString();
            } else {
                out[QStringLiteral("ok")] = false;
                out[QStringLiteral("error")] = replyError(r.value);
            }
            setProbeJson(compact(out));
        },
        Timeout(kCallBudgetMs));
}

void EthRpcUiBackend::refreshVerdict()
{
    const int chain = selectedChainId();
    if (chain <= 0) {
        setVerdictJson(QStringLiteral("{}"));
        return;
    }
    // ASYNC deliberately: eth_rpc spends its modules-state and proxy probe budgets before
    // answering when the proxy is not installed. The guard is a DEADLINE — a callback that
    // never fires must not wedge the probe shut for good.
    quint64 slot = 0;
    if (!m_verdictInFlight.take(kCallBudgetMs, &slot))
        return;
    modules().eth_rpc_module.verified_proxy_statusAsyncResult(chain,
        [this, chain, slot](logos::AsyncResult<QString> r) {
            m_verdictInFlight.release(slot);
            if (chain != selectedChainId())
                return;
            // A failed call is silence, never a verdict — the plain Async twin cannot say.
            applyVerdict(r.ok() ? r.value : QString(), chain);
        },
        Timeout(kCallBudgetMs));
}

void EthRpcUiBackend::applyVerdict(const QString &verdictJson, int chainId)
{
    QString publish = verdictJson;
    if (!parseObject(publish).contains(QStringLiteral("mode"))) {
        if (++m_verdictSilent < kMaxSilentPolls)
            return;
        publish = unreadableVerdict(chainId);
    } else {
        m_verdictSilent = 0;
    }
    setVerdictJson(publish);
}
