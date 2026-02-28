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

            Text("DI.FM")
                .font(.title2)
                .fontWeight(.semibold)

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

    private func login() {
        guard !email.isEmpty, !password.isEmpty else { return }
        Task {
            await appState.login(email: email, password: password)
        }
    }
}
