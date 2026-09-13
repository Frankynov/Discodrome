import DiscodromeCore
import SwiftUI

struct DeviceView: View {
    let deviceID: String
    @Environment(AppModel.self) private var model
    @Environment(DeviceManager.self) private var devices
    @Environment(TransferManager.self) private var transfers
    @ViewState private var isTargeted = false

    var body: some View {
        if let device = devices.devices.first(where: { $0.id == deviceID }) {
            let contents = devices.contents[device.id]
            VStack(spacing: 0) {
                header(device, contents)
                Divider()
                if model.deviceShowsTransfers && !transfers.jobs.isEmpty {
                    TransferList(deviceID: device.id)
                } else {
                    TrackTable(
                        tracks: contents?.tracks ?? [],
                        version: contents?.tracksRevision ?? 0,
                        style: .init(visibleColumns: [.status, .title, .artist, .album, .time, .format, .size, .location],
                                     autosaveName: "DeviceTracks", device: device, defaultSort: .artist)
                    )
                    .overlay {
                        if let contents, contents.tracks.isEmpty {
                            if contents.isScanning {
                                ProgressView("Scanning “\(device.name)”…")
                            } else {
                                ContentUnavailableView(
                                    "No Music on “\(device.name)”",
                                    systemImage: "music.note",
                                    description: Text("Drag albums, playlists or songs here — or onto the device in the sidebar — to copy them.")
                                )
                            }
                        }
                    }
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: LibraryDragItem.self) { items, _ in
                model.copy(items, to: device)
                return true
            } isTargeted: { isTargeted = $0 }
            .navigationTitle(device.name)
            .navigationSubtitle(contents.map { "\($0.tracks.count.formatted()) songs" } ?? "")
            .onChange(of: transfers.isActive(on: device.id)) { _, active in
                if active { model.deviceShowsTransfers = true }
            }
        } else {
            ContentUnavailableView("Device Disconnected", systemImage: "cable.connector.slash")
        }
    }

    private func header(_ device: Device, _ contents: DeviceContents?) -> some View {
        HStack(alignment: .center, spacing: 20) {
            DeviceIllustration(device: device, size: 84)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.system(size: 22, weight: .bold))
                Text("\(device.details) · \(Formatting.bytes(device.available)) free")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let contents {
                    if contents.isScanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Scanning… \(contents.scannedCount.formatted()) songs")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else if !contents.clutter.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("\(contents.clutter.count) hidden macOS file\(contents.clutter.count == 1 ? "" : "s") — the DISC lists “._” files as broken songs.")
                            Button("Remove") {
                                _ = devices.cleanUp(device)
                            }
                            .controlSize(.small)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button { model.eject(device) } label: { Label("Eject", systemImage: "eject") }
                        .disabled(transfers.isActive(on: device.id))
                    Button { devices.scan(device) } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .disabled(contents?.isScanning == true)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([device.url]) } label: { Label("Show in Finder", systemImage: "folder") }
                    if !transfers.jobs.isEmpty {
                        Picker("View", selection: Binding(get: { model.deviceShowsTransfers }, set: { model.deviceShowsTransfers = $0 })) {
                            Text("Songs").tag(false)
                            Text("Transfers").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
    }
}

/// Every copy made to the device this session, newest first, one section per copy.
struct TransferList: View {
    let deviceID: String
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        let batches = Array(transfers.batches.filter { $0.deviceID == deviceID }.reversed())
        let hasFinished = batches.contains { batch in !transfers.jobs.contains { $0.batchID == batch.id && !$0.isFinished } }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                let progress = transfers.progress
                if transfers.isActive(on: deviceID) {
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 260)
                    Text("\(progress.done) of \(progress.total)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if let summary = transfers.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if transfers.isActive(on: deviceID) {
                    Button("Stop Copying", role: .cancel) { transfers.cancelAll() }
                }
                Button("Clear Finished") { transfers.clearFinished() }
                    .disabled(!hasFinished)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            List {
                ForEach(batches) { batch in
                    let jobs = transfers.jobs.filter { $0.batchID == batch.id }
                    Section {
                        ForEach(jobs) { job in row(job) }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(batch.title).lineLimit(1)
                            Spacer()
                            Text("\(Self.status(of: jobs)) · \(batch.started.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    /// "3 of 11", "11 copied", "10 copied, 1 failed".
    static func status(of jobs: [TransferManager.Job]) -> String {
        if jobs.contains(where: { !$0.isFinished }) {
            return "\(jobs.filter(\.isFinished).count) of \(jobs.count)"
        }
        let cancelled = jobs.filter { $0.phase == .failed("Cancelled") }.count
        let failed = jobs.filter { if case .failed = $0.phase { return true } else { return false } }.count - cancelled
        var parts = ["\(jobs.filter { $0.phase == .done }.count) copied"]
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.joined(separator: ", ")
    }

    private func row(_ job: TransferManager.Job) -> some View {
        HStack(spacing: 10) {
            icon(job.phase)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.track.title).lineLimit(1)
                Text(job.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            detail(job)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func icon(_ phase: TransferManager.Job.Phase) -> some View {
        switch phase {
        case .waiting: Image(systemName: "clock").foregroundStyle(.tertiary)
        case .downloading, .writing: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func detail(_ job: TransferManager.Job) -> some View {
        switch job.phase {
        case .waiting: Text(Formatting.bytes(job.estimatedBytes))
        case .downloading(let fraction): Text("Downloading \(Int(fraction * 100))%")
        case .writing(let fraction): Text("Writing \(Int(fraction * 100))%")
        case .done: Text(job.transcode ? "Converted to MP3" : "Copied")
        case .failed(let reason): Text(reason).lineLimit(1)
        }
    }
}
