import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BuddyCore

/// Lists presentations and edits the selected one. Changes are saved as you type.
struct SessionEditorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SessionStore
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.sessions) { session in
                    HStack {
                        Text(session.name)
                        Spacer()
                        if session.id == model.activeSession.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                                .help("Aktiv i Buddy")
                        }
                    }
                    .tag(session.id)
                }
            }
            .safeAreaInset(edge: .bottom) {
                sidebarButtons
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let id = selection, let session = store.sessions.first(where: { $0.id == id }) {
                SessionDetailView(model: model, original: session)
                    .id(id)
            } else {
                Text("Välj en presentation till vänster")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil {
                selection = model.activeSession.id
            }
        }
    }

    private var sidebarButtons: some View {
        HStack(spacing: 6) {
            Button {
                selection = store.createNew().id
            } label: {
                Image(systemName: "plus")
            }
            .help("Ny presentation")

            Button {
                if let id = selection, let copy = store.duplicate(id) {
                    selection = copy.id
                }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Duplicera")
            .disabled(selection == nil)

            Button {
                deleteSelected()
            } label: {
                Image(systemName: "trash")
            }
            .help("Ta bort")
            .disabled(selection == nil)

            Spacer()

            Button {
                importSession()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Importera från JSON-fil")

            Button {
                exportSelected()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Exportera till JSON-fil")
            .disabled(selection == nil)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private func deleteSelected() {
        guard let id = selection, let session = store.sessions.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Ta bort «\(session.name)»?"
        alert.informativeText = "Presentationen och alla dess moment tas bort. Det går inte att ångra."
        alert.addButton(withTitle: "Ta bort")
        alert.addButton(withTitle: "Avbryt")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.delete(id)
        selection = model.activeSession.id
    }

    private func importSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let session = try store.importFile(at: url)
            selection = session.id
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }

    private func exportSelected() {
        guard let id = selection, let session = store.sessions.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(session.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(session, to: url)
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }
}

/// Editor for one presentation: general settings and its moments.
struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    @State private var draft: Session

    init(model: AppModel, original: Session) {
        self.model = model
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Namn på presentationen", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                if draft.id == model.activeSession.id {
                    Label("Aktiv i Buddy", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Button("Använd i Buddy") {
                        model.activate(draft.id)
                    }
                }
            }
            .padding(16)

            TabView {
                GeneralTab(draft: $draft)
                    .tabItem { Text("Allmänt") }
                MomentsTab(model: model, draft: $draft)
                    .tabItem { Text("Moment") }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .onChange(of: draft) { newValue in
            model.save(newValue)
        }
    }
}

private struct GeneralTab: View {
    @Binding var draft: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Field("Buddys namn", help: "Namnet du använder när du tilltalar Buddy.") {
                    TextField("Buddy", text: $draft.buddyName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                Field("Personlighet", help: "Vem Buddy är och hur den pratar. Skickas till Claude.") {
                    BoxedTextEditor(text: $draft.persona, minHeight: 100)
                }
                Field("Om presentationen", help: "Ämne, publik, vem du är – sådant Buddy bör veta.") {
                    BoxedTextEditor(text: $draft.context, minHeight: 80)
                }
                Field(
                    "Triggerfraser för alla moment",
                    help: "En fras per rad. Startar nästa moment som inte är gjort, t.ex. ”vad tycker du buddy”. Moment kan också ha egna triggers."
                ) {
                    LinesEditor(lines: $draft.triggers)
                }
                Field("Avslutsfraser för alla moment", help: "En fras per rad, t.ex. ”tack buddy”.") {
                    LinesEditor(lines: $draft.endPhrases)
                }
                Field("Avskedsrepliker", help: "Buddy säger en av dessa när du avslutar med en avslutsfras.") {
                    LinesEditor(lines: $draft.farewells)
                }
                Field("Reservrepliker", help: "Används om Claude inte svarar i tid (t.ex. dåligt nätverk).") {
                    LinesEditor(lines: $draft.fallbackLines)
                }
                Field("Längd på svar") {
                    Stepper(value: $draft.maxWordsPerReply, in: 10...150, step: 5) {
                        Text("Högst cirka \(draft.maxWordsPerReply) ord per svar")
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
                Field(
                    "Andra stavningar av namnet",
                    help: "Hur taligenkänningen kan höra namnet, t.ex. ”baddy” eller ”body”. Räknas som namnet i fraserna."
                ) {
                    LinesEditor(lines: $draft.nameVariants)
                }
            }
            .padding(16)
        }
    }
}

private struct MomentsTab: View {
    @ObservedObject var model: AppModel
    @Binding var draft: Session
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Array(draft.moments.enumerated()), id: \.element.id) { index, moment in
                        HStack {
                            Text("\(index + 1).").foregroundColor(.secondary)
                            Text(moment.title)
                                .foregroundColor(moment.enabled ? .primary : .secondary)
                            Spacer()
                            Text(moment.mode == .ai ? "AI" : "Manus")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(moment.id)
                    }
                }
                HStack(spacing: 6) {
                    Button {
                        let moment = Moment(title: "Moment \(draft.moments.count + 1)")
                        draft.moments.append(moment)
                        selection = moment.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Nytt moment")
                    Button {
                        if let id = selection {
                            draft.moments.removeAll { $0.id == id }
                            selection = draft.moments.first?.id
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Ta bort momentet")
                    .disabled(selection == nil)
                    Spacer()
                    Button {
                        move(by: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .help("Flytta upp")
                    .disabled(selection == nil)
                    Button {
                        move(by: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .help("Flytta ner")
                    .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 250)

            Divider()

            if let id = selection, draft.moments.contains(where: { $0.id == id }) {
                MomentEditor(
                    moment: binding(for: id),
                    buddyName: draft.buddyName,
                    onTest: { model.startMoment(id) },
                    isActiveSession: draft.id == model.activeSession.id
                )
                .id(id)
            } else {
                Text("Välj eller lägg till ett moment")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil {
                selection = draft.moments.first?.id
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Moment> {
        Binding(
            get: { draft.moments.first(where: { $0.id == id }) ?? Moment(id: id, title: "") },
            set: { newValue in
                if let index = draft.moments.firstIndex(where: { $0.id == id }) {
                    draft.moments[index] = newValue
                }
            }
        )
    }

    private func move(by offset: Int) {
        guard let id = selection, let index = draft.moments.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard target >= 0, target < draft.moments.count else { return }
        draft.moments.swapAt(index, target)
    }
}

private struct MomentEditor: View {
    @Binding var moment: Moment
    let buddyName: String
    let onTest: () -> Void
    let isActiveSession: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TextField("Titel", text: $moment.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                    Toggle("Aktivt", isOn: $moment.enabled)
                }
                Field("Läge") {
                    Picker("Läge", selection: $moment.mode) {
                        Text("AI – Claude följer manuset fritt").tag(MomentMode.ai)
                        Text("Manus – Buddy säger replikerna ordagrant").tag(MomentMode.scripted)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                }
                Field(
                    "Egna triggerfraser",
                    help: "En fras per rad. Startar just det här momentet. De gemensamma triggerfraserna fungerar också."
                ) {
                    LinesEditor(lines: $moment.triggers)
                }
                Field("Egna avslutsfraser", help: "En fras per rad. De gemensamma avslutsfraserna fungerar också.") {
                    LinesEditor(lines: $moment.endPhrases)
                }
                Field("Antal svar") {
                    Stepper(value: $moment.maxTurns, in: 0...30) {
                        Text(moment.maxTurns == 0
                             ? "Obegränsat – tills du säger en avslutsfras"
                             : "Buddy svarar högst \(moment.maxTurns) gång\(moment.maxTurns == 1 ? "" : "er")")
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }
                Field(
                    "Manus",
                    help: "Ett grovt manus för dialogen. Skriv fritt, eller som dialog med rader som börjar med ”Du:” och ”\(buddyName):”."
                ) {
                    BoxedTextEditor(text: $moment.script, minHeight: 150)
                    Button("Hämta \(buddyName)s repliker från manuset") {
                        moment.lines = ScriptTools.lines(spokenBy: buddyName, in: moment.script)
                    }
                    .disabled(moment.script.isEmpty)
                }
                Field(
                    "Repliker",
                    help: "En replik per rad. I manusläge säger Buddy dem i tur och ordning, en per svar. I AI-läge används de som reserv om Claude inte svarar."
                ) {
                    LinesEditor(lines: $moment.lines, minHeight: 80)
                }
                Field("Avskedsrepliker", help: "Om tomt används presentationens avskedsrepliker.") {
                    LinesEditor(lines: $moment.farewells)
                }
                HStack {
                    Button("Starta momentet nu", action: onTest)
                        .disabled(!isActiveSession)
                    if !isActiveSession {
                        Text("Gör presentationen aktiv för att testa.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }
}
