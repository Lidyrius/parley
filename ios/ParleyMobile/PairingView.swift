import SwiftUI

/// First launch: pair with the host by scanning its QR code or pasting the link.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var link = ""
    @State private var error: String?
    @State private var showsScanner = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 14) {
                    AppMark().frame(width: 84, height: 84)
                    Text("Parley auf dem iPhone")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Alle Sessions deines Macs im Blick – und mit einem Tipp fortgesetzt.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 14) {
                    Step(n: 1, text: "Öffne Parley auf dem Mac.")
                    Step(n: 2, text: "Wähle im Menü „iPhone\u{00A0}verbinden…\u{2060}“.")  // keeps the menu name in one piece
                    Step(n: 3, text: "Scanne den QR-Code – oder füge den Link hier ein.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))

                VStack(spacing: 14) {
                    Button { showsScanner = true } label: {
                        Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack(spacing: 10) {
                        TextField("parley://pair?…", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { pair(link) }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                        if link.isEmpty {
                            PasteButton(payloadType: String.self) { items in
                                Task { @MainActor in if let first = items.first { pair(first) } }
                            }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.roundedRectangle(radius: 12))
                        } else {
                            Button("Verbinden") { pair(link) }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .fullScreenCover(isPresented: $showsScanner) {
            ScannerSheet { code in
                do { try model.pair(code); return nil } catch { return error.localizedDescription }
            }
        }
    }

    private func pair(_ text: String) {
        do {
            try model.pair(text)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct Step: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.claude))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text)
        }
    }
}

/// The app's mark: a voice wave on Claude orange.
struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [Theme.claudeLight, Theme.claude], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: "waveform").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: Theme.claude.opacity(0.35), radius: 14, y: 6)
            .accessibilityHidden(true)
    }
}
