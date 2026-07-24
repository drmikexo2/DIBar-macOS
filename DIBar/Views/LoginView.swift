import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "radio")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("Sign in with DI.FM")
                .font(.title2)
                .fontWeight(.semibold)

            Text("One login works for all of these sites:")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The family of sites, so users arriving from any of them see
            // theirs listed. The umbrella company name means nothing to them.
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(Array(Network.allCases.prefix(3)), id: \.self) { network in
                        siteChip(network)
                    }
                }
                HStack(spacing: 5) {
                    ForEach(Array(Network.allCases.dropFirst(3)), id: \.self) { network in
                        siteChip(network)
                    }
                }
            }
            .padding(.bottom, 4)

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { login() }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: login) {
                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sign In")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || appState.isLoading)

            Divider()

            Button("Quit DIBar") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(24)
    }

    private func siteChip(_ network: Network) -> some View {
        Text(network.listenDomain)
            .font(.system(size: 10, weight: network == .di ? .semibold : .regular))
            .foregroundStyle(network == .di ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                network == .di
                    ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                    : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
    }

    private func login() {
        guard !email.isEmpty, !password.isEmpty else { return }
        Task {
            await appState.login(email: email, password: password)
        }
    }
}
