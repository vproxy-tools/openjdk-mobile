import SwiftUI

struct ContentView: View {
    @Environment(JvmModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            header
            actionRow
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

    /// vproxy's helloworld deployment listens on a fixed port (8080), so
    /// the app has no port input; just the start/stop control.
    private var actionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("vproxy").font(.subheadline)
                Text("helloworld(:8080)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.toggle()
            } label: {
                Text(model.phase == .stopping ? "退出中…" :
                     (model.canStop ? "停止并退出 App" : "启动"))
                    // The long stop label uses a smaller font so it does not
                    // inflate the button (and the row) it sits in.
                    .font(model.canStop || model.phase == .stopping
                          ? .subheadline.weight(.semibold)
                          : .body.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.canStop ? .red : .blue)
            .disabled(!model.canStart && !model.canStop)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var modeRow: some View {
        @Bindable var model = model
        return Toggle(isOn: $model.useBackgroundTask) {
            VStack(alignment: .leading, spacing: 2) {
                Text("后台任务运行 JVM").font(.subheadline)
                Text("(BGContinuedProcessingTask)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
            .textSelection(.enabled)
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
                            consoleText(pair.element)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(pair.offset)
                        }
                        // Bottom breathing room as an explicit anchor:
                        // scrolling here leaves the last line slightly above
                        // the console's bottom edge, exactly matching a
                        // manual scroll to the end (scrolling to the last
                        // row itself would pin it onto the edge).
                        Color.clear
                            .frame(height: 8)
                            .id("console-bottom")
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                .onAppear {
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
                .onChange(of: model.logLines.count) { _, _ in
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// One console line as concatenated styled runs: only the segments the
    /// program actually colored (vproxy's timestamp/level prefix) get a
    /// color; the message body stays default.
    private func consoleText(_ line: JvmModel.LogLine) -> Text {
        var result: Text?
        for segment in line.segments {
            let part = Text(segment.text).foregroundColor(consoleColor(segment.color))
            result = result == nil ? part : result! + part
        }
        return result ?? Text("")
    }

    /// ANSI SGR foreground color (30-37, 90-97 bright) to a SwiftUI color,
    /// tuned for readability on the black console background.
    private func consoleColor(_ code: Int) -> Color {
        let c = (code >= 90 && code <= 97) ? code - 60 : code
        switch c {
        case 30: return Color(white: 0.55)                          // black
        case 31: return Color(red: 1.00, green: 0.42, blue: 0.42)   // red
        case 32: return Color(red: 0.50, green: 0.93, blue: 0.55)   // green
        case 33: return Color(red: 0.98, green: 0.83, blue: 0.35)   // yellow
        case 34: return Color(red: 0.52, green: 0.66, blue: 1.00)   // blue
        case 35: return Color(red: 0.94, green: 0.56, blue: 0.94)   // magenta
        case 36: return Color(red: 0.45, green: 0.88, blue: 0.93)   // cyan
        case 37: return .white
        default: return .white
        }
    }
}
