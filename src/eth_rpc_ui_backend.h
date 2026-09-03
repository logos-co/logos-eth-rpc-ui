#pragma once

#include <QDeadlineTimer>
#include <QList>
#include <QObject>
#include <QString>
#include <QTimer>

#include "rep_eth_rpc_ui_source.h"
#include "logos_ui_plugin_context.h"

/// An in-flight claim that EXPIRES. An async callback can simply never fire, so a guard
/// derived from one is a deadline, never a latch.
class InFlight
{
public:
    /// True while a call taken out inside its budget has neither answered nor expired.
    bool busy() const { return m_held && !m_deadline.hasExpired(); }
    /// Take the slot, or refuse it to a second call while the first is still live. The
    /// ticket identifies THIS claim, so a completion arriving after its deadline lapsed
    /// cannot free the call that replaced it.
    bool take(int budgetMs, quint64 *ticket)
    {
        if (busy())
            return false;
        m_held = true;
        m_deadline.setRemainingTime(budgetMs);
        *ticket = ++m_ticket;
        return true;
    }
    void release(quint64 ticket)
    {
        if (ticket == m_ticket)
            m_held = false;
    }

private:
    bool m_held = false;
    quint64 m_ticket = 0;
    QDeadlineTimer m_deadline;
};

// The Ethereum RPC panel's backend.
//
// eth_rpc_module persists `chains.json` in its own instance directory and that store is
// DEVICE-WIDE: every Logos wallet on this device reads the endpoints and the verified-proxy
// modes edited here. Nothing on this class reaches an account, a balance or a key — it
// configures transport, and reads back what eth_rpc says about it.
class EthRpcUiBackend : public EthRpcUiSimpleSource,
                        public LogosUiPluginContext
{
public:
    void refresh() override;
    void selectChain(int chainId) override;
    void setEndpoint(int chainId, QString url) override;
    void setVerifiedProxyMode(int chainId, QString mode) override;
    void setTimeouts(int chainId, int timeoutSecs, int verifiedTimeoutSecs) override;
    void removeChain(int chainId) override;
    void testEndpoint(int chainId) override;
    void refreshVerdict() override;

protected:
    void onContextReady() override;

private:
    /// Surface an eth_rpc refusal verbatim. The rule that produced it lives there, so
    /// restating it here would be a second copy free to drift.
    bool failed(const QString &reply, const QString &context);

    /// Every chain this app offers, in a stable order: the display roster, then every chain
    /// eth_rpc holds a config for, then every id the user has asked about this session.
    QList<int> roster() const;

    /// Publish a verdict, or count a poll that learned nothing. A single unanswered probe
    /// must not repaint the badge; a backend that has gone quiet must not leave "ready" on
    /// screen while nothing is being verified.
    void applyVerdict(const QString &verdictJson, int chainId);

    /// Ids typed into "Add chain by id" and ids selected but not yet configured. Without
    /// this a chain the user just asked for vanishes from the list before it is saved.
    /// A QList, not a QSet: set iteration order is unspecified, and the picker's rows
    /// would then reshuffle on every refresh.
    QList<int> m_asked;

    QTimer m_verdictPoll;
    /// One verdict probe at a time: it can outlast the poll interval.
    InFlight m_verdictInFlight;
    /// One endpoint test at a time — a dead endpoint costs the full transport timeout.
    InFlight m_probeInFlight;
    /// Verdict polls in a row that learned nothing.
    int m_verdictSilent = 0;
};
