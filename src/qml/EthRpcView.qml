import QtQuick 2.15
import QtQuick.Layouts 1.15
import Logos.Controls
import Logos.Theme

// Ethereum RPC — the endpoints and the verified-routing mode every Logos wallet on this
// device shares.
//
// This store is DEVICE-WIDE: eth_rpc_module persists chains.json in its own instance
// directory, and a wallet's Settings sheet is the wrong place to edit it — the wallet
// configures the wallet. Nothing here reaches an account, a balance or a key.
//
// Two things NOT to do in this directory, both of which break at runtime rather than at build
// time: do not ship a src/qml/qmldir (the builder generates one carrying this module's private
// URI), and do not create a src/qml/Logos/ directory (the host reserves that prefix).
//
// Rendering rule: every item showing a string this view did not author sets
// `textFormat: Text.PlainText`. LogosText is a bare Text with no textFormat, i.e. Qt's AutoText
// HTML autodetection — an endpoint URL or an error message containing markup would otherwise
// render as markup.
Item {
    id: root
    objectName: "ethRpcRoot"
    anchors.fill: parent

    // Paint the surface. Without this the QQuickWidget's white clear colour shows through and
    // LogosText's default (light) colour renders white-on-white.
    Rectangle { anchors.fill: parent; color: Theme.palette.background }

    readonly property var backend: logos.module("eth_rpc_ui")

    // Must be a writable property fed by the signal, NOT a binding: a binding containing a
    // function call evaluates once at creation, before ui-host has finished handing over, and
    // then latches false forever.
    property bool ready: false

    // Refusals this view authored itself, kept apart from the backend's lastError so one
    // does not silently overwrite the other.
    property string addChainError: ""

    // What came back from asking for the verified proxy, when it is worth saying. Empty is
    // the normal state: a request that reached a provider hands the user over to it, so this
    // screen is not the one they are looking at.
    property string routingNote: ""

    Connections {
        target: logos
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "eth_rpc_ui") root.ready = isReady && root.backend !== null
        }

        // Endpoints and verified-routing mode are what this app is; being brought here IS
        // the request, so answer at once. `handoff: true` leaves the user here afterwards.
        function onIntentRequested(requestId, intent, params, requesterName) {
            if (intent !== "evm.rpc.configure") return
            logos.respond(requestId, true, ({}), "")
        }
    }

    // Ask whoever provides verified routing to take over. The note above stays on screen
    // whatever happens — it is the instruction to follow by hand, and it is the only thing
    // left if nothing can service this.
    function operateVerifiedRouting() {
        root.routingNote = ""
        logos.request("evm.verified_routing.operate", ({}), function (res) {
            if (res.ok) return
            // `cancelled` is the user saying no, not a failure to report back at them.
            if (res.error === "cancelled") return
            root.routingNote = res.error === "unavailable"
                ? "Nothing on this device offers to do that — follow the note above."
                : "That request did not go through (" + res.error + ")."
        })
    }

    function j(text, fallback) {
        try { return JSON.parse(text && text.length ? text : fallback) }
        catch (e) { return JSON.parse(fallback) }
    }

    readonly property var chains: ready ? j(backend.chainsJson, "[]") : []
    readonly property int selectedChainId: ready ? backend.selectedChainId : 0
    readonly property var verdict: ready ? j(backend.verdictJson, "{}") : ({})
    readonly property var probe: ready ? j(backend.probeJson, "{}") : ({})

    function chainById(id) {
        for (var i = 0; i < chains.length; ++i)
            if (chains[i].chainId === id) return chains[i]
        return null
    }
    // The row the whole form below edits. Null before the first read, and after a chain has
    // been removed — every control checks it rather than reading through a null.
    readonly property var chain: chainById(selectedChainId)
    readonly property int chainIndex: {
        for (var i = 0; i < chains.length; ++i)
            if (chains[i].chainId === selectedChainId) return i
        return 0
    }

    function chainRowLabel(c) {
        return c.name + " · " + c.chainId + (c.configured ? "" : " · not configured")
    }

    // The form holds the user's edits, so it is filled imperatively when the chain changes
    // rather than bound: a binding on `text` is destroyed by the first keystroke, and would
    // then never follow a chain switch.
    function loadForm() {
        endpointField.text = chain ? chain.endpoint : ""
        timeoutField.value = chain ? chain.timeoutSecs : 8
        verifiedTimeoutField.value = chain ? chain.verifiedTimeoutSecs : 15
        root.addChainError = ""
    }
    onChainChanged: loadForm()

    // The closed set of actions eth_rpc's verdict may carry. Still the authoritative text:
    // `operateVerifiedRoutingButton` below raises an intent for the three actions that name
    // something to go and do, but nothing guarantees a provider exists, so the words stay.
    function actionHint(a) {
        if (a === "wait") return "Waiting for the verified proxy to catch up."
        if (a === "install_or_load") return "Install and start the Verified Proxy module, then reopen this app."
        if (a === "open_verified_proxy") return "Open Verified Proxy and press Start."
        if (a === "restart_or_reload") return "Open Verified Proxy, press Stop then Start. If that does not help, reload the app."
        return ""
    }

    // An empty verdict is "we are reading it", which is neither good news nor bad. Only a
    // verdict that says `usable` may be badged green.
    function verdictText(v) {
        if (v.mode === undefined) return "Reading…"
        if (v.mode === "off") return "Verification off"
        if (v.usable === true) return "Verified routing ready"
        return "Verified routing unavailable"
    }
    function verdictColor(v) {
        if (v.mode === undefined || v.mode === "off") return Theme.palette.textTertiary
        if (v.usable === true) return Theme.palette.success
        if (v.state === "syncing") return Theme.palette.warning
        return Theme.palette.error
    }

    // What the last eth_chainId round-trip proved. A reply from the WRONG chain is the
    // finding worth having: such an endpoint answers every later call confidently and wrongly.
    function probeText(p) {
        if (p.ok === undefined) return ""
        if (p.ok !== true) return "Test failed: " + (p.error || "")
        if (p.reportedChainId !== p.chainId)
            return "This endpoint answered for chain " + p.reportedChainId + ", not "
                 + p.chainId + ". It is an endpoint for a different network."
        return "Answered for chain " + p.reportedChainId + " (route: " + (p.route || "direct") + ")."
    }
    function probeColor(p) {
        if (p.ok === true && p.reportedChainId === p.chainId) return Theme.palette.success
        return Theme.palette.error
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosText {
                text: "Ethereum RPC"
                color: Theme.palette.text
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightBold
            }

            Item { Layout.fillWidth: true }

            LogosBadge {
                objectName: "verdictBadge"
                text: root.verdictText(root.verdict)
                color: root.verdictColor(root.verdict)
            }
            LogosButton {
                objectName: "refreshButton"
                text: "Refresh"
                enabled: root.ready && !root.backend.busy
                onClicked: root.backend.refresh()
            }
        }

        LogosText {
            objectName: "deviceWideNote"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
            text: "These endpoints are stored once for this device and are used by every "
                + "Logos wallet on it. Changing one here changes it for all of them."
        }

        LogosText {
            objectName: "errorLabel"
            Layout.fillWidth: true
            visible: root.ready && root.backend.lastError.length > 0
            // Backend-authored; may contain anything.
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Theme.palette.error
            text: root.ready ? root.backend.lastError : ""
        }

        // ── which chain ───────────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosComboBox {
                id: chainPicker
                objectName: "chainPicker"
                Layout.preferredWidth: 280
                model: root.chains.map(function (c) { return root.chainRowLabel(c) })
                enabled: root.ready && root.chains.length > 0
                // Assigned, never bound: selecting a row writes currentIndex internally, which
                // destroys a declarative binding and leaves the picker free to drift from the
                // chain the form is actually editing.
                onModelChanged: currentIndex = root.chainIndex
                onActivated: if (root.ready) root.backend.selectChain(root.chains[currentIndex].chainId)
            }

            Item { Layout.fillWidth: true }

            LogosTextField {
                id: addChainField
                objectName: "addChainField"
                Layout.preferredWidth: 160
                placeholderText: "Add chain by id"
            }
            LogosButton {
                objectName: "addChainButton"
                text: "Add"
                enabled: root.ready
                // The .rep carries chain ids as int, so this app cannot address one past
                // 2^31 — said out loud rather than silently wrapping the number.
                onClicked: {
                    var t = addChainField.text.trim()
                    var n = parseInt(t, 10)
                    if (!/^[0-9]+$/.test(t) || !(n > 0) || n > 2147483647) {
                        root.addChainError = "Enter a chain id: a whole number from 1 to 2147483647."
                        return
                    }
                    addChainField.text = ""
                    root.backend.selectChain(n)
                }
            }
        }

        LogosText {
            objectName: "addChainError"
            Layout.fillWidth: true
            visible: root.addChainError.length > 0
            wrapMode: Text.WordWrap
            color: Theme.palette.error
            text: root.addChainError
        }

        // ── the selected chain ────────────────────────────────────────────────────────
        LogosText {
            objectName: "noChainsNote"
            Layout.fillWidth: true
            visible: root.ready && root.chain === null
            wrapMode: Text.WordWrap
            color: Theme.palette.textSecondary
            text: "No chain selected. Pick one above, or add one by its chain id."
        }

        LogosScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.chain !== null

            ColumnLayout {
                width: parent.width
                spacing: Theme.spacing.small

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosText {
                        objectName: "chainTitle"
                        text: root.chain ? root.chain.name : ""
                        color: Theme.palette.text
                        font.weight: Theme.typography.weightBold
                    }
                    LogosBadge {
                        objectName: "chainKindBadge"
                        // Absent, not false: the backend names no `testnet` for a chain id it
                        // has no name for, and "unknown" is the only honest badge for one.
                        text: root.chain === null ? ""
                            : root.chain.testnet === true ? "TESTNET"
                            : root.chain.testnet === false ? "MAINNET" : "UNKNOWN NETWORK"
                        color: root.chain === null ? Theme.palette.textTertiary
                             : root.chain.testnet === true ? Theme.palette.accentOrange
                             : root.chain.testnet === false ? Theme.palette.success
                                                            : Theme.palette.warning
                    }
                    Item { Layout.fillWidth: true }
                    LogosText {
                        objectName: "configuredNote"
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        text: root.chain && root.chain.configured
                              ? "Configured" : "Not configured yet — the values below are defaults."
                    }
                }

                // ── endpoint ──────────────────────────────────────────────────────────
                LogosFrame {
                    Layout.fillWidth: true
                    contentItem: ColumnLayout {
                        spacing: Theme.spacing.small

                        LogosText { text: "JSON-RPC endpoint"; color: Theme.palette.textSecondary }

                        LogosTextField {
                            id: endpointField
                            objectName: "endpointField"
                            Layout.fillWidth: true
                            placeholderText: "https://…"
                        }

                        LogosText {
                            objectName: "endpointSchemeWarning"
                            Layout.fillWidth: true
                            visible: endpointField.text.trim().length > 0
                                     && endpointField.text.trim().indexOf("https://") !== 0
                            wrapMode: Text.WordWrap
                            color: Theme.palette.warning
                            font.pixelSize: Theme.typography.secondaryText
                            text: "This is not an https endpoint, so every request — including "
                                + "the addresses being asked about — travels in the clear."
                        }

                        RowLayout {
                            spacing: Theme.spacing.small
                            LogosButton {
                                objectName: "saveEndpointButton"
                                text: "Save endpoint"
                                enabled: root.ready && !root.backend.busy
                                // Saves ONLY the endpoint: the store is shared, so retyping a
                                // URL must not reset another wallet's mode or timeouts.
                                onClicked: root.backend.setEndpoint(root.selectedChainId,
                                                                    endpointField.text)
                            }
                            LogosButton {
                                objectName: "testEndpointButton"
                                text: "Test"
                                enabled: root.ready && root.chain && root.chain.configured
                                onClicked: root.backend.testEndpoint(root.selectedChainId)
                            }
                            LogosText {
                                objectName: "testHint"
                                visible: root.chain !== null && !root.chain.configured
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                                text: "Save an endpoint before testing it."
                            }
                        }

                        LogosText {
                            objectName: "probeResult"
                            Layout.fillWidth: true
                            visible: text.length > 0
                            // Carries eth_rpc's own transport error.
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            color: root.probeColor(root.probe)
                            text: root.probeText(root.probe)
                        }
                    }
                }

                // ── verified routing ──────────────────────────────────────────────────
                LogosFrame {
                    Layout.fillWidth: true
                    contentItem: ColumnLayout {
                        spacing: Theme.spacing.small

                        LogosSwitch {
                            id: verifiedSwitch
                            objectName: "verifiedProxySwitch"
                            text: "Route through the light-client verified proxy"
                            enabled: root.ready && root.chain !== null && root.chain.configured
                            onToggled: root.backend.setVerifiedProxyMode(
                                           root.selectedChainId, checked ? "required" : "off")
                        }

                        // A refused change must snap the switch back. Toggling writes `checked`
                        // internally, which destroys a plain binding — leaving the switch
                        // showing a setting eth_rpc never accepted.
                        Binding {
                            target: verifiedSwitch
                            property: "checked"
                            value: root.chain !== null && root.chain.verifiedProxyMode === "required"
                            restoreMode: Binding.RestoreNone
                        }

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.secondaryText
                            text: "There is no \"preferred\" setting. Verified routing either "
                                + "proves an answer or refuses it — answering from an unverified "
                                + "source when verification was asked for is the failure this "
                                + "prevents."
                        }

                        LogosText {
                            objectName: "verifiedNotConfigured"
                            Layout.fillWidth: true
                            visible: root.chain !== null && !root.chain.configured
                            wrapMode: Text.WordWrap
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.secondaryText
                            text: "Save an endpoint first: verified routing is stored against a "
                                + "chain's configuration, and there is none yet."
                        }

                        LogosText {
                            objectName: "verdictMessage"
                            Layout.fillWidth: true
                            visible: text.length > 0
                            // eth_rpc's own words.
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            color: root.verdictColor(root.verdict)
                            text: root.verdict.message !== undefined ? root.verdict.message : ""
                        }
                        LogosText {
                            objectName: "verdictAction"
                            Layout.fillWidth: true
                            visible: text.length > 0
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            color: Theme.palette.textSecondary
                            text: root.actionHint(root.verdict.action)
                        }
                        LogosButton {
                            objectName: "operateVerifiedRoutingButton"
                            // `wait` is the one action with nothing to go and do — the proxy
                            // is already running and catching up.
                            visible: root.verdict.action !== undefined
                                     && root.verdict.action.length > 0
                                     && root.verdict.action !== "wait"
                            text: "Open Verified Proxy"
                            onClicked: root.operateVerifiedRouting()
                        }
                        LogosText {
                            objectName: "routingNote"
                            Layout.fillWidth: true
                            visible: root.routingNote.length > 0
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            color: Theme.palette.textSecondary
                            text: root.routingNote
                        }
                        LogosText {
                            objectName: "verdictDetail"
                            Layout.fillWidth: true
                            visible: root.verdict.detail !== undefined && root.verdict.detail.length > 0
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            color: Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.secondaryText
                            text: root.verdict.detail !== undefined ? root.verdict.detail : ""
                        }

                        // Moved here from the wallet's Settings sheet, which no longer
                        // configures any of this.
                        LogosText {
                            objectName: "verifiedTestnetWarning"
                            Layout.fillWidth: true
                            visible: root.chain !== null && root.chain.testnet === true
                            wrapMode: Text.WordWrap
                            color: Theme.palette.warning
                            font.pixelSize: Theme.typography.secondaryText
                            text: "Verified mode needs an archive endpoint that serves "
                                + "eth_getProof for finalized blocks. No free Sepolia endpoint "
                                + "does, so balances will fail. Set your own archive endpoint "
                                + "above, or use verified mode on mainnet."
                        }
                    }
                }

                // ── transport timeouts ────────────────────────────────────────────────
                LogosFrame {
                    Layout.fillWidth: true
                    contentItem: ColumnLayout {
                        spacing: Theme.spacing.small

                        LogosText { text: "Timeouts (seconds)"; color: Theme.palette.textSecondary }

                        RowLayout {
                            spacing: Theme.spacing.small
                            LogosText { text: "Endpoint"; color: Theme.palette.textSecondary }
                            LogosSpinBox {
                                id: timeoutField
                                objectName: "timeoutField"
                                from: 1
                                to: 60
                            }
                            LogosText { text: "Verified leg"; color: Theme.palette.textSecondary }
                            LogosSpinBox {
                                id: verifiedTimeoutField
                                objectName: "verifiedTimeoutField"
                                from: 1
                                to: 60
                            }
                            LogosButton {
                                objectName: "saveTimeoutsButton"
                                text: "Save timeouts"
                                enabled: root.ready && root.chain && root.chain.configured
                                onClicked: root.backend.setTimeouts(root.selectedChainId,
                                                                     timeoutField.value,
                                                                     verifiedTimeoutField.value)
                            }
                        }

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.secondaryText
                            text: "Above about 20 seconds the Logos call deadline fires first, "
                                + "so a larger value has no effect. The verified leg is a second "
                                + "hop and needs the longer of the two."
                        }
                    }
                }

                // ── removal ───────────────────────────────────────────────────────────
                LogosButton {
                    objectName: "removeChainButton"
                    text: "Remove this chain's configuration"
                    enabled: root.ready && root.chain && root.chain.configured
                    onClicked: removeChainDialog.open()
                }
            }
        }
    }

    LogosWarningDialog {
        id: removeChainDialog
        objectName: "removeChainDialog"
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 460)
        accentColor: Theme.palette.error
        title: "Remove this chain's configuration?"
        message: "Every Logos wallet on this device loses this endpoint and its verified-routing "
               + "setting, not just this app. Nothing is deleted on the chain itself."

        leftActions: [
            LogosButton {
                objectName: "removeChainCancel"
                text: "Cancel"
                onClicked: removeChainDialog.close()
            }
        ]
        rightActions: [
            LogosButton {
                objectName: "removeChainConfirm"
                text: "Remove"
                onClicked: {
                    root.backend.removeChain(root.selectedChainId)
                    removeChainDialog.close()
                }
            }
        ]
    }
}
