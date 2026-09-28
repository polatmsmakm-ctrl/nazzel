import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var engine: EngineStatus
    @EnvironmentObject private var downloads: DownloadManager
    @AppStorage("autoSaveToPhotos") private var autoSave = true
    @AppStorage("autoStartShared") private var autoStartShared = true
    @AppStorage("defaultQuality") private var qualityRaw = VideoQuality.best.rawValue
    @AppStorage("defaultMode") private var modeRaw = DownloadMode.video.rawValue
    @AppStorage("adblock") private var adblock = true
    @AppStorage("downloadBadges") private var badges = true
    @AppStorage("backgroundDownloads") private var backgroundDownloads = true
    @AppStorage("notifyWhenDone") private var notifyWhenDone = true
    @AppStorage("autoPiP") private var autoPiP = true
    @State private var signedIn: Set<String> = []
    @State private var loginSite: LoginSite?
    @State private var update = UpdateState.idle

    enum UpdateState: Equatable {
        case idle, checking, upToDate, updating
        case available(String)
        case done(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("التحميل") {
                    Toggle("حفظ الفيديو في الصور تلقائياً", isOn: $autoSave)
                    Picker("الجودة الافتراضية", selection: $qualityRaw) {
                        ForEach(VideoQuality.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    Picker("النوع الافتراضي", selection: $modeRaw) {
                        ForEach(DownloadMode.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    Toggle("ابدأ التحميل فوراً للروابط اللي توصل من المشاركة", isOn: $autoStartShared)
                    Toggle("كمّل التحميل لو طلعت من التطبيق", isOn: $backgroundDownloads)
                    Toggle("نبهني لما يخلص التحميل", isOn: $notifyWhenDone)
                }

                Section {
                    Toggle("مانع الإعلانات", isOn: $adblock)
                        .onChange(of: adblock) { _ in BrowserModel.shared.applySettings() }
                    Toggle("زر ⬇ على كل منشور وفيديو", isOn: $badges)
                        .onChange(of: badges) { _ in BrowserModel.shared.applySettings() }
                } header: {
                    Text("المتصفح")
                } footer: {
                    Text("مانع الإعلانات يتخطى إعلانات فيديوهات يوتيوب ويخفي المنشورات الممولة في إنستقرام وإكس وتيك توك.")
                }

                Section("المشغّل") {
                    Toggle("صورة داخل صورة تلقائياً للفيديو", isOn: $autoPiP)
                }

                Section {
                    ForEach(LoginSite.all) { site in
                        Button {
                            loginSite = site
                        } label: {
                            HStack {
                                Label(site.name, systemImage: site.symbol)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if signedIn.contains(site.id) {
                                    Text("مسجّل ✓")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                } else {
                                    Text("تسجيل دخول")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            if signedIn.contains(site.id) {
                                Button("خروج", role: .destructive) {
                                    Task { @MainActor in
                                        await CookieStore.signOut(site)
                                        await refreshSignIns()
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("تسجيل الدخول للمواقع")
                } footer: {
                    Text("سجّل دخولك إذا الفيديو خاص أو الموقع يطلب حساب (خصوصاً إنستقرام). نفس الدخول يشتغل في تبويب «تصفّح». بياناتك تبقى في جهازك. للخروج اسحب الصف لليسار.")
                }

                engineSection

                Section {
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("طريقة الاستخدام والاختصار", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("سجل العمليات", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section {
                    LabeledContent("إصدار التطبيق", value: appVersion)
                    LabeledContent("Python", value: engine.pythonVersion ?? "…")
                    ForEach(engine.extras.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: engine.extras[key] ?? "")
                    }
                } footer: {
                    Text("استخدم التطبيق لتحميل محتواك أو المحتوى اللي عندك إذن تحمله، واحترم حقوق أصحاب المحتوى.")
                }
            }
            .navigationTitle("الإعدادات")
            .task { await refreshSignIns() }
            .sheet(item: $loginSite, onDismiss: {
                Task { @MainActor in
                    await CookieStore.exportForEngine()
                    await refreshSignIns()
                }
            }) { site in
                LoginView(site: site)
            }
        }
    }

    private var engineSection: some View {
        Section {
            LabeledContent("محرك التحميل") {
                if engine.isBooting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(engine.ytDlpVersion.map { "yt-dlp \($0)" } ?? "غير متوفر")
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            LabeledContent("النسخة", value: engine.isUpdated ? "محدّثة من الإنترنت" : "المرفقة مع التطبيق")

            switch update {
            case .idle, .upToDate, .failed, .done:
                Button {
                    checkForUpdate()
                } label: {
                    Label("تحقق من تحديث المحرك", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(engine.isBooting)
            case .checking:
                HStack { ProgressView(); Text("جاري التحقق…").foregroundStyle(.secondary) }
            case .available(let version):
                Button {
                    runUpdate()
                } label: {
                    Label("حدّث إلى \(version)", systemImage: "arrow.down.circle.fill")
                }
            case .updating:
                HStack { ProgressView(); Text("جاري التحديث…").foregroundStyle(.secondary) }
            }

            switch update {
            case .upToDate:
                Text("المحرك محدّث لآخر نسخة ✓").font(.footnote).foregroundStyle(.green)
            case .done(let version):
                Text("تم التحديث إلى \(version) ✓").font(.footnote).foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            default:
                EmptyView()
            }

            if engine.isUpdated {
                Button(role: .destructive) {
                    resetEngine()
                } label: {
                    Label("رجوع للنسخة المرفقة", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("المحرك")
        } footer: {
            Text("المواقع تغيّر أنظمتها باستمرار. إذا وقف التحميل من موقع، حدّث المحرك من هنا، وما تحتاج تنزّل نسخة جديدة من التطبيق.")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    @MainActor
    private func refreshSignIns() async {
        var result: Set<String> = []
        for site in LoginSite.all {
            if await CookieStore.isSignedIn(site) {
                result.insert(site.id)
            }
        }
        signedIn = result
    }

    private func checkForUpdate() {
        update = .checking
        Task { @MainActor in
            let result = await PythonEngine.shared.callAsync("check_update")
            if result["ok"] as? Bool == true {
                if result["update_available"] as? Bool == true {
                    update = .available(result["latest"] as? String ?? "")
                } else {
                    update = .upToDate
                }
            } else {
                update = .failed((result["error"] as? String).map { "تعذر التحقق: \($0)" } ?? "تعذر التحقق")
            }
        }
    }

    private func runUpdate() {
        guard !downloads.jobs.contains(where: { $0.isActive }) else {
            update = .failed("انتظر لين تخلص التحميلات الحالية")
            return
        }
        update = .updating
        Task { @MainActor in
            let result = await PythonEngine.shared.callAsync("update_engine")
            if result["ok"] as? Bool == true, var info = result["info"] as? [String: Any] {
                info["ok"] = true
                engine.update(with: info)
                update = .done(info["yt_dlp"] as? String ?? "")
            } else {
                update = .failed(result["error"] as? String ?? "فشل التحديث")
            }
        }
    }

    private func resetEngine() {
        update = .updating
        Task { @MainActor in
            let result = await PythonEngine.shared.callAsync("reset_engine")
            engine.update(with: result)
            update = .idle
        }
    }
}

struct LogView: View {
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "السجل فاضي" : lines.joined(separator: "\n"))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .environment(\.layoutDirection, .leftToRight)
        }
        .navigationTitle("سجل العمليات")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                } label: {
                    Label("نسخ", systemImage: "doc.on.doc")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        let result = await PythonEngine.shared.callAsync("log", ["lines": 400])
        lines = result["log"] as? [String] ?? []
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("التحميل العادي") {
                step("١", "افتح الفيديو في تيك توك أو إنستقرام أو أي تطبيق، واضغط «مشاركة» ثم «نسخ الرابط».")
                step("٢", "افتح نزّل واضغط زر «لصق». التحميل يبدأ على طول.")
                step("٣", "الفيديو ينحفظ في الصور، وتلقى نسخة في تبويب «الملفات» وفي تطبيق الملفات › على الـ iPhone › نزّل.")
            }
            Section {
                step("١", "افتح تطبيق «الاختصارات» واضغط +.")
                step("٢", "اضغط على اسم الاختصار واختار «إظهار في ورقة المشاركة»، ونوع المدخل: عناوين URL ونصوص.")
                step("٣", "أضف إجراء «ترميز URL» (URL Encode) على «مدخل الاختصار».")
                step("٤", "أضف إجراء «نص» واكتب فيه: nazzel://download?url= وبعده مباشرة متغير «نص مرمّز».")
                step("٥", "أضف إجراء «فتح عناوين URL» على النص، وسمّ الاختصار «تحميل بنزّل».")
                step("٦", "الحين من أي تطبيق: مشاركة › تحميل بنزّل، والتطبيق يفتح ويحمل بنفسه.")
            } header: {
                Text("تحميل من زر المشاركة مباشرة")
            } footer: {
                Text("إذا ما ظهر الاختصار في قائمة المشاركة، اضغط «المزيد» أو «تعديل الإجراءات» وفعّله.")
            }
            Section("إذا ما اشتغل التحميل") {
                step("•", "إذا الحساب خاص أو إنستقرام يطلب دخول: الإعدادات › تسجيل الدخول للمواقع.")
                step("•", "إذا موقع وقف فجأة: الإعدادات › تحقق من تحديث المحرك.")
                step("•", "خلك داخل التطبيق لين يخلص التحميل، لأن الآيفون يوقف التطبيقات اللي بالخلفية.")
                step("•", "للمساعدة: الإعدادات › سجل العمليات › نسخ، وأرسل النص لمن يساعدك.")
            }
        }
        .navigationTitle("طريقة الاستخدام")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.bold())
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
