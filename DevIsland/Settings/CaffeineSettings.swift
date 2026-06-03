import SwiftUI
import AppKit
import CoreLocation

struct CaffeineSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var coordinator: CaffeineCoordinator
    @ObservedObject private var l10n = L10n.shared

    @State private var showingSSIDPicker = false
    @State private var selection = Set<String>()

    var body: some View {
        Form {
            Section(l10n.secCaffeineStatus) {
                LabeledContent(l10n.lblOnAC, value: coordinator.isOnACPower ? "ON" : "OFF")
                LabeledContent(l10n.lblBatteryLevel, value: batteryString)
                LabeledContent(l10n.lblCurrentSSID, value: coordinator.currentSSID ?? "—")
                LabeledContent(l10n.lblHoldingAssertion, value: coordinator.isHoldingAssertion ? "ON" : "OFF")
            }

            Section(l10n.secCaffeineBehavior) {
                Toggle(l10n.lblCaffeineEnabled, isOn: Binding(
                    get: { store.settings.caffeineEnabled },
                    set: { store.settings.caffeineEnabled = $0 }
                ))
                Text(l10n.hintCaffeineRule)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(l10n.secCaffeineExcludedSSIDs) {
                if store.settings.caffeineExcludedSSIDs.isEmpty {
                    Text("—")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.settings.caffeineExcludedSSIDs, id: \.self) { ssid in
                        HStack {
                            Text(ssid)
                            Spacer()
                            Button {
                                removeSSID(ssid)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button(l10n.btnAddSSID) {
                    selection.removeAll()
                    showingSSIDPicker = true
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingSSIDPicker) {
            CaffeineSSIDPickerSheet(
                connectedSSID: coordinator.currentSSID,
                existing: Set(store.settings.caffeineExcludedSSIDs),
                onConfirm: { newSSIDs in
                    addSSIDs(newSSIDs)
                    showingSSIDPicker = false
                },
                onCancel: { showingSSIDPicker = false }
            )
        }
    }

    private var batteryString: String {
        guard let level = coordinator.batteryLevel else { return "—" }
        return "\(Int(level * 100))%"
    }

    private func removeSSID(_ ssid: String) {
        store.settings.caffeineExcludedSSIDs.removeAll { $0 == ssid }
    }

    private func addSSIDs(_ ssids: [String]) {
        var current = store.settings.caffeineExcludedSSIDs
        for ssid in ssids {
            let trimmed = ssid.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !current.contains(trimmed) else { continue }
            current.append(trimmed)
        }
        store.settings.caffeineExcludedSSIDs = current
    }
}

private struct CaffeineSSIDPickerSheet: View {
    let connectedSSID: String?
    let existing: Set<String>
    let onConfirm: ([String]) -> Void
    let onCancel: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @StateObject private var permission = LocationPermissionRequester()
    @State private var scanResults: [String] = []
    @State private var isScanning = true
    @State private var scanError: WifiScanError? = nil
    @State private var selection = Set<String>()
    @State private var manualEntry: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.btnAddSSID)
                .font(.headline)

            if let connected = connectedSSID, !existing.contains(connected) {
                Toggle(isOn: bindingForSelection(connected)) {
                    HStack {
                        Image(systemName: "wifi")
                        Text(connected)
                        Text("(\(l10n.lblConnectedSSID))")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Text(l10n.lblScanNearbyWifi)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if isScanning {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if let error = scanError {
                scanErrorView(for: error)
            } else {
                List(scanResults.filter { $0 != connectedSSID && !existing.contains($0) }, id: \.self) { ssid in
                    Toggle(isOn: bindingForSelection(ssid)) {
                        Text(ssid)
                    }
                }
                .frame(minHeight: 160)
            }

            Divider()

            Text(l10n.lblManualSSIDEntry)
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextField("SSID", text: $manualEntry)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(l10n.btnCancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(l10n.btnAdd) {
                    var picked = Array(selection)
                    let trimmed = manualEntry.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { picked.append(trimmed) }
                    onConfirm(picked)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty && manualEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 460)
        .task {
            permission.requestIfNeeded()
            // .notDetermined 상태에서는 권한 응답을 기다린다 — onChange가 처리.
            // 이미 결정된 상태에서만 즉시 스캔/오류 표시.
            switch permission.status {
            case .authorizedAlways, .authorizedWhenInUse:
                await runScan()
            case .denied, .restricted:
                isScanning = false
                scanError = .permissionDenied
            case .notDetermined:
                isScanning = false
            @unknown default:
                isScanning = false
            }
        }
        .onChange(of: permission.status) { _, newStatus in
            switch newStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                isScanning = true
                scanError = nil
                Task { await runScan() }
            case .denied, .restricted:
                isScanning = false
                scanError = .permissionDenied
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private func scanErrorView(for error: WifiScanError) -> some View {
        switch error {
        case .permissionDenied:
            HStack {
                Text(l10n.lblScanErrorPermission)
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Button(l10n.btnOpenLocationSettings) {
                    // macOS 13+ 정식 경로. deploymentTarget이 15.0이므로 안전.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Settings.extension.Privacy.Location") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        case .radioOff:
            Text(l10n.lblScanErrorRadioOff)
                .font(.caption)
                .foregroundColor(.orange)
        case .unknown(let nsError):
            Text(l10n.lblScanErrorUnknown(nsError.localizedDescription))
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private func bindingForSelection(_ ssid: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(ssid) },
            set: { isOn in
                if isOn { selection.insert(ssid) } else { selection.remove(ssid) }
            }
        )
    }

    private func runScan() async {
        do {
            scanResults = try await WifiSSIDMonitor.scanForNetworks()
            scanError = nil
        } catch let error as WifiScanError {
            scanError = error
        } catch {
            scanError = .unknown(error as NSError)
        }
        isScanning = false
    }
}
