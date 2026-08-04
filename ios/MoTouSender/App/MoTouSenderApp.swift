import SwiftUI

@main
@MainActor
struct MoTouSenderApp: App {
    @State private var persistence: PersistenceStore
    @State private var connection: ConnectionStore
    @State private var discovery: BonjourDiscovery
    @State private var transfer: TransferStore
    @State private var settings: SettingsStore
    @State private var chat: ChatStore
    @State private var speechRecognizer: SpeechRecognizer
    @State private var speechSynthesizer: SpeechSynthesizer

    init() {
        let persistence = PersistenceStore()
        let connection = ConnectionStore(persistence: persistence)
        let settings = SettingsStore()

        _persistence = State(initialValue: persistence)
        _connection = State(initialValue: connection)
        _discovery = State(initialValue: BonjourDiscovery())
        _transfer = State(initialValue: TransferStore(connection: connection, persistence: persistence))
        _settings = State(initialValue: settings)
        _chat = State(initialValue: ChatStore(
            settings: settings,
            persistence: persistence,
            connection: connection
        ))
        _speechRecognizer = State(initialValue: SpeechRecognizer())
        _speechSynthesizer = State(initialValue: SpeechSynthesizer())
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environment(persistence)
                .environment(connection)
                .environment(discovery)
                .environment(transfer)
                .environment(settings)
                .environment(chat)
                .environment(speechRecognizer)
                .environment(speechSynthesizer)
        }
    }
}
