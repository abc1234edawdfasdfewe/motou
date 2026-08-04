import AVFoundation
import SwiftUI

struct QRScannerView: UIViewControllerRepresentable {
    var onResult: (String) -> Void
    var onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onResult: onResult, onError: onError)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "com.motou.sender.qr-session",
        qos: .userInitiated
    )
    private let onResult: (String) -> Void
    private let onError: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false

    // These two properties are only read or written on sessionQueue.
    private var isSessionConfigured = false
    private var wantsSessionRunning = false

    init(onResult: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        configureCamera()

        let guide = UIView()
        guide.layer.borderWidth = 2
        guide.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        guide.layer.cornerRadius = 18
        guide.isUserInteractionEnabled = false
        guide.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guide)
        NSLayoutConstraint.activate([
            guide.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            guide.heightAnchor.constraint(equalTo: guide.widthAnchor),
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            wantsSessionRunning = true
            startSessionIfPossible()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            wantsSessionRunning = false
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            installCapturePipeline()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                if allowed {
                    self?.installCapturePipeline()
                } else {
                    self?.reportError("未获得相机权限")
                }
            }
        default:
            onError("请在系统设置中允许墨投访问相机")
        }
    }

    private func installCapturePipeline() {
        sessionQueue.async { [weak self] in
            self?.configureCapturePipeline()
        }
    }

    private func configureCapturePipeline() {
        guard !isSessionConfigured else {
            startSessionIfPossible()
            return
        }

        session.beginConfiguration()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            reportError("无法使用相机")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            reportError("无法启动二维码识别")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        session.commitConfiguration()
        isSessionConfigured = true
        startSessionIfPossible()
    }

    private func startSessionIfPossible() {
        guard isSessionConfigured, wantsSessionRunning, !session.isRunning else { return }
        session.startRunning()
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError(message)
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = code.stringValue else { return }
        delivered = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            wantsSessionRunning = false
            if session.isRunning {
                session.stopRunning()
            }
        }
        onResult(value)
    }
}
