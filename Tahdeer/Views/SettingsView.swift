import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("provider") private var providerRaw = Provider.gemini.rawValue
    @AppStorage("apiKey") private var claudeKey = ""
    @AppStorage("model") private var claudeModel = ClaudeClient.models[0].id
    @AppStorage("geminiKey") private var geminiKey = ""
    @AppStorage("geminiModel") private var geminiModel = PlanWriter.geminiModels[0].id

    private var provider: Provider { Provider(rawValue: providerRaw) ?? .gemini }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("الخدمة", selection: $providerRaw) {
                        ForEach(Provider.allCases) { p in
                            Text(p.name).tag(p.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("الخدمة اللي تكتب التحضير")
                }

                if provider == .gemini {
                    Section {
                        SecureField("AIza...", text: $geminiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                        if !geminiKey.isEmpty {
                            Button("مسح المفتاح", role: .destructive) { geminiKey = "" }
                        }
                        Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                            Label("احصل على مفتاح مجاني", systemImage: "safari")
                        }
                    } header: {
                        Text("مفتاح Gemini (مجاني)")
                    } footer: {
                        Text("افتح الرابط وسجّل بحساب Google، واضغط Create API key وانسخه هنا. مجاني وما يحتاج بطاقة، وله حد يومي يكفي للاستخدام العادي.")
                    }
                    Section("النموذج") {
                        Picker("النموذج", selection: $geminiModel) {
                            ForEach(PlanWriter.geminiModels) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } else {
                    Section {
                        SecureField("sk-ant-...", text: $claudeKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                        if !claudeKey.isEmpty {
                            Button("مسح المفتاح", role: .destructive) { claudeKey = "" }
                        }
                        Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                            Label("فتح صفحة المفاتيح", systemImage: "safari")
                        }
                    } header: {
                        Text("مفتاح Claude API (مدفوع)")
                    } footer: {
                        Text("يحتاج رصيد مشحون في console.anthropic.com. التحضير الواحد يكلّف تقريباً ١٠–٢٠ سنت.")
                    }
                    Section("النموذج") {
                        Picker("النموذج", selection: $claudeModel) {
                            ForEach(ClaudeClient.models) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                Section {
                    Text("المفاتيح تنحفظ على جهازك بس.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
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
