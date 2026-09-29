import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ClaudeClient.models[0].id

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    if !apiKey.isEmpty {
                        Button("مسح المفتاح", role: .destructive) { apiKey = "" }
                    }
                } header: {
                    Text("مفتاح Claude API")
                } footer: {
                    Text("سوّ مفتاح من console.anthropic.com ← API Keys، واشحن رصيد بسيط. المفتاح يبقى محفوظ على جهازك بس.")
                }

                Section("النموذج") {
                    Picker("النموذج", selection: $model) {
                        ForEach(ClaudeClient.models) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                        Label("فتح صفحة المفاتيح", systemImage: "safari")
                    }
                }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
        }
    }
}
