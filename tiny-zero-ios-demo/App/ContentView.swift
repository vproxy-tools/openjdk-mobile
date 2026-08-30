import SwiftUI

struct ContentView: View {
    @Environment(JvmModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            header
            portRow
            modeRow
            backgroundCard
            if let err = model.errorMessage {
                errorBanner(err)
            }
            logView
        }
        .padding()
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear { model.handleLaunchArguments() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            Text("Tiny Zero JVM")
                .font(.headline)
            Spacer()
            Text(model.phase.rawValue.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .running: .green
        case .starting, .stopping: .orange
        case .idle: .gray
        }
    }

    private var portRow: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Text("端口").font(.subheadline)
            TextField("8080", text: $model.portText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .keyboardType(.numberPad)
                .frame(maxWidth: 96)
                .disabled(!model.canStart)
            Button {
                model.toggle()
            } label: {
                Text(model.phase == .stopping ? "退出中…" :
                     (model.canStop ? "停止并退出 App" : "启动"))
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.canStop ? .red : .blue)
            .disabled(!model.canStart && !model.canStop)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var modeRow: some View {
        @Bindable var model = model
        return Toggle("后台任务运行 JVM(BGContinuedProcessingTask)", isOn: $model.useBackgroundTask)
            .font(.subheadline)
            .disabled(!model.canSwitchMode)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("后台执行").font(.caption).foregroundStyle(.secondary)
            Text(model.backgroundMode).font(.footnote)
            ProgressView(value: model.progress)
            Text(model.remainingText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.85)))
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("控制台输出(stdout/stderr)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.logLines.count) 行").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { pair in
                            Text(pair.element)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(pair.offset)
                        }
                    }
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                .onAppear {
                    // Start at the bottom (restored history / early lines).
                    if !model.logLines.isEmpty {
                        proxy.scrollTo(model.logLines.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: model.logLines.count) { _, count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
