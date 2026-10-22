import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

struct LoginView: View {
    @EnvironmentObject var store: Store
    @AppStorage("lastUserCode") private var userCode = ""
    @State private var qr: String?
    @State private var qrImage: UIImage?
    @State private var busy = false
    @State private var message: String?
    @State private var saved = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.background(Theme.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "dot.radiowaves.right")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("Smart Life, once").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Only for the IR blaster. Phosphor uses it to fetch the blaster's local key; everything after that goes straight over your Wi-Fi. The TV itself needs no account.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    if let qrImage, qr != nil {
                        qrStep(qrImage)
                    } else {
                        codeStep
                    }

                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                    }
                }
                .padding(20)
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. In Smart Life, go to **Me › ⚙︎ Settings › Account and Security › User Code** and copy it.")
            Text("2. Paste it here.")
            TextField("User code", text: $userCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.title3, design: .monospaced))
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
            Button {
                Task { await getQR() }
            } label: {
                HStack {
                    if busy { ProgressView().tint(.black) }
                    Text("Get login QR").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.black)
            }
            .disabled(busy || userCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(.callout)
        .card()
    }

    private func qrStep(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan this in Smart Life").font(.headline)
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: 260)
                .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                Button {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    saved = true
                } label: {
                    Label(saved ? "Saved" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
                ShareLink(item: Image(uiImage: image), preview: SharePreview("Smart Life login", image: Image(uiImage: image))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .foregroundStyle(.white)

            Text("On this phone: save it, then open Smart Life, tap **+** › **Scan**, tap the photo icon and pick the QR. Confirm the login and come back here. If you have a second phone or tablet with Smart Life, just scan the screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let url = URL(string: "smartlife://") {
                Link(destination: url) {
                    Label("Open Smart Life", systemImage: "arrow.up.forward.app")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                }
            }

            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for you to confirm in Smart Life…").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Start over") { reset() }.font(.footnote)
            }
        }
        .card()
    }

    private func reset() {
        pollTask?.cancel()
        qr = nil
        qrImage = nil
        saved = false
    }

    private func getQR() async {
        let code = userCode.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        message = nil
        defer { busy = false }
        do {
            let token = try await TuyaLogin.requestQR(userCode: code)
            qr = token
            qrImage = Self.makeQR(TuyaConst.qrPrefix + token)
            startPolling(qr: token, userCode: code)
        } catch {
            message = error.localizedDescription
        }
    }

    private func startPolling(qr token: String, userCode code: String) {
        pollTask?.cancel()
        pollTask = Task {
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if let t = try? await TuyaLogin.poll(qr: token, userCode: code) {
                    store.signedIn(t)
                    return
                }
                if Date().timeIntervalSince(started) > 280 {
                    message = "That QR expired. Get a new one."
                    reset()
                    return
                }
            }
        }
    }

    static func makeQR(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
