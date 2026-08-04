import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class SpeechRecognizer: NSObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case failure(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var hasAudioTap = false

    var isListening: Bool { state == .listening }

    func start(localeIdentifier: String = "zh-CN") async {
        stop(resetState: false)
        state = .requestingPermission

        let speechStatus = await requestSpeechPermission()
        guard speechStatus == .authorized else {
            state = .failure("未获得语音识别权限")
            return
        }
        guard await requestMicrophonePermission() else {
            state = .failure("未获得麦克风权限")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable
        else {
            state = .failure("当前语音识别服务不可用")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request
            transcript = ""

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw SpeechServiceError.noAudioInput
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasAudioTap = true
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        transcript = result.bestTranscription.formattedString
                        if result.isFinal {
                            stop()
                        }
                    } else if let error {
                        stop(resetState: false)
                        state = .failure(error.localizedDescription)
                    }
                }
            }
        } catch {
            stop(resetState: false)
            state = .failure(error.localizedDescription)
        }
    }

    func stop() {
        stop(resetState: true)
    }

    func clearTranscript() {
        transcript = ""
    }

    private func stop(resetState: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if resetState {
            state = .idle
        }
    }

    private func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
            return SFSpeechRecognizer.authorizationStatus()
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

@MainActor
@Observable
final class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String = "zh-CN", rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }
}

private enum SpeechServiceError: LocalizedError {
    case noAudioInput

    var errorDescription: String? {
        "当前设备没有可用的音频输入"
    }
}
