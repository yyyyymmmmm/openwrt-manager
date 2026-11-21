import SwiftUI
import OpenWrtKit

/// Routes a registry page to its view. Dedicated kinds get their native
/// pages; everything else lands on the generic UCI page or the generic
/// menu page — visibly labelled, never disguised.
struct PageDestination: View {
    let page: PageDescriptor

    var body: some View {
        switch page.kind {
        // Overview
        case .overviewHome:
            OverviewHomeRedirect()
        case .routesStatus:
            RoutesStatusView()
        case .firewallStatus:
            FirewallStatusView()
        case .logs:
            LogsView()
        case .processes:
            ProcessesView()
        case .realtime:
            RealtimeView()
        case .wireguardStatus:
            WireGuardStatusView()
        case .channelAnalysis:
            ChannelAnalysisView()
        // Network
        case .interfaces:
            InterfacesView()
        case .staticRoutes:
            StaticRoutesView()
        case .dhcp(let merged):
            DHCPView(merged: merged)
        case .dns:
            DNSView()
        case .diagnostics:
            NetworkDiagnosticsView()
        case .speedTest:
            SpeedTestView()
        case .sqm:
            UCIConfigView(title: page.title, configNames: page.configNames)
        case .firewallConfig:
            FirewallConfigView()
        case .upnp:
            UPnPView()
        case .bandwidthMonitor:
            BandwidthView()
        case .wireless:
            WirelessView()
        // Services
        case .serviceDedicated(let key):
            switch key {
            case "openbox": OpenBoxView()
            case "homeproxy": HomeProxyView()
            case "mosdns": MosDNSView()
            case "ddns": DDNSView()
            case "appfilter": AppFilterView()
            case "wol": WolView()
            case "vlmcsd": VLMCSDView()
            case "frpc": FrpcView()
            case "natmap": NatmapView()
            case "socat": SocatView()
            case "zerotier": ZeroTierView()
            case "webdav": WebdavView()
            default: GenericServiceView(page: page)
            }
        case .serviceGeneric:
            GenericServiceView(page: page)
        // System
        case .packages:
            PackagesView()
        case .startup:
            StartupView()
        case .crontab:
            CrontabView()
        case .mounts:
            MountsView()
        case .onlineUpgrade:
            OnlineUpgradeView()
        case .backupRestore:
            BackupRestoreView()
        case .rebootInfo:
            RebootInfoView()
        case .terminal:
            TerminalView()
        case .fileManager:
            FileManagerView()
        case .uci:
            UCIConfigView(title: page.title, configNames: page.configNames,
                          isGenericFallback: page.isGenericFallback)
        case .genericMenuPage:
            GenericMenuPageView(page: page)
        // Settings (not normally pushed; the tab renders them directly)
        case .profiles, .about:
            GenericMenuPageView(page: page)
        }
    }
}

/// The overview home is the overview tab's root; a stray push of its
/// descriptor just explains that instead of nesting a second home.
private struct OverviewHomeRedirect: View {
    var body: some View {
        EmptyStateView(title: "概况", message: "概况即概览页首页内容，请返回上一层查看。", symbol: "square.grid.2x2")
            .navigationTitle("概况")
            .navigationBarTitleDisplayMode(.inline)
    }
}
