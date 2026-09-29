import SwiftUI

struct PlanView: View {
    @Binding var plan: LessonPlan
    @State private var mode = 0
    @State private var image: UIImage?
    @State private var files: [URL] = []
    @State private var savedMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("الورقة").tag(0)
                Text("تعديل").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if mode == 0 {
                ScrollView {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 20)
                    } else {
                        ProgressView().padding(40)
                    }
                }
                .background(Color(.systemGroupedBackground))
            } else {
                PlanEditor(plan: $plan)
            }
        }
        .navigationTitle(plan.title.isEmpty ? "التحضير" : plan.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    save()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                if !files.isEmpty {
                    ShareLink(items: files) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let savedMessage {
                Text(savedMessage)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 30)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: plan) { _ in refresh() }
    }

    private func refresh() {
        let p = plan.cleaned()
        image = PaperRenderer.image(p)
        files = PaperRenderer.exportFiles(p)
    }

    private func save() {
        let img = PaperRenderer.image(plan.cleaned())
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        withAnimation { savedMessage = "تم الحفظ في الصور" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { savedMessage = nil }
        }
    }
}

struct PlanEditor: View {
    @Binding var plan: LessonPlan

    var body: some View {
        Form {
            Section("اسم الدرس") {
                TextField("Letter Ee", text: $plan.title)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Section {
                ForEach(plan.steps.indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        Text("\(i + 1)-").foregroundColor(.secondary)
                        TextField("Step", text: binding($plan.steps, i), axis: .vertical)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                }
                .onDelete { plan.steps.remove(atOffsets: $0) }
                .onMove { plan.steps.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    plan.steps.append("Asking learners to ")
                } label: {
                    Label("إضافة خطوة", systemImage: "plus")
                }
            } header: {
                Text("الخطوات")
            } footer: {
                Text("اسحب الخطوة لليسار عشان تحذفها.")
            }
            Section("عنوان قسم الكتاب") {
                TextField("Setting the scene (Page 14)", text: $plan.sectionTitle)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Section("خطوات الكتاب") {
                ForEach(plan.sectionSteps.indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        Text("-").foregroundColor(.secondary)
                        TextField("Step", text: binding($plan.sectionSteps, i), axis: .vertical)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                }
                .onDelete { plan.sectionSteps.remove(atOffsets: $0) }
                .onMove { plan.sectionSteps.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    plan.sectionSteps.append("Asking learners to ")
                } label: {
                    Label("إضافة خطوة", systemImage: "plus")
                }
            }
        }
        .toolbar { EditButton() }
    }

    /// Index binding that stays safe if the row was just deleted.
    private func binding(_ list: Binding<[String]>, _ i: Int) -> Binding<String> {
        Binding(
            get: { i < list.wrappedValue.count ? list.wrappedValue[i] : "" },
            set: { if i < list.wrappedValue.count { list.wrappedValue[i] = $0 } }
        )
    }
}
