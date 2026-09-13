import SwiftUI
@preconcurrency import AVFoundation

private let cameraQueue = DispatchQueue(label: "Nomva.BarcodeScanner.camera", qos: .userInitiated)

struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> BarcodeScanViewController {
        let vc = BarcodeScanViewController()
        vc.onScan = { barcode in
            onScan(barcode)
        }
        vc.onCancel = {
            // handled by sheet dismiss
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: BarcodeScanViewController, context: Context) {}
}

// MARK: - Barcode Scan View Controller

@MainActor
final class BarcodeScanViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {

    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    private var metadataOutput: AVCaptureMetadataOutput?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                Task { @MainActor in
                    if allowed { self?.setupCamera() }
                    else { self?.showFailure(message: "Allow camera access in Settings to scan. You can also search or type a barcode.") }
                }
            }
        default: showFailure(message: "Allow camera access in Settings to scan. You can also search or type a barcode.")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let captureSession, !captureSession.isRunning {
            cameraQueue.async {
                captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let captureSession { cameraQueue.async { captureSession.stopRunning() } }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        captureSession = session

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              session.canAddInput(videoInput) else {
            showFailure()
            return
        }

        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        self.metadataOutput = metadataOutput
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)

        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.ean8, .ean13, .upce, .code128].filter { metadataOutput.availableMetadataObjectTypes.contains($0) }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer

        cameraQueue.async {
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let connection = previewLayer?.connection,
           let orientation = view.window?.windowScene?.interfaceOrientation {
            let angle: CGFloat = orientation == .landscapeLeft ? 0 : orientation == .landscapeRight ? 180 : orientation == .portraitUpsideDown ? 270 : 90
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    private func setupUI() {
        // Scan region indicator
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = .clear
        view.addSubview(overlayView)

        let cutoutSize = CGSize(width: 260, height: 120)
        let cutoutOrigin = CGPoint(
            x: (view.bounds.width - cutoutSize.width) / 2,
            y: (view.bounds.height - cutoutSize.height) / 2 - 40
        )
        let cutoutRect = CGRect(origin: cutoutOrigin, size: cutoutSize)

        let path = UIBezierPath(rect: view.bounds)
        let cutoutPath = UIBezierPath(roundedRect: cutoutRect, cornerRadius: 12)
        path.append(cutoutPath)
        path.usesEvenOddFillRule = true

        let dimLayer = CAShapeLayer()
        dimLayer.path = path.cgPath
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.5).cgColor
        overlayView.layer.addSublayer(dimLayer)

        // Border around cutout
        let borderLayer = CAShapeLayer()
        borderLayer.path = UIBezierPath(roundedRect: cutoutRect, cornerRadius: 12).cgPath
        borderLayer.strokeColor = UIColor.white.cgColor
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.lineWidth = 2
        overlayView.layer.addSublayer(borderLayer)

        // Label
        let label = UILabel()
        label.text = "Point at the UPC or EAN barcode"
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: cutoutOrigin.y + cutoutSize.height + 20)
        ])

        // Cancel button
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.tintColor = .white
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
        onCancel?()
    }

    private func showFailure(message: String = "Camera not available. You can still search or type a barcode.") {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 30, dy: 140)
        view.addSubview(label)
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasScanned else { return }
        let identity = metadataObjects.compactMap { object -> BarcodeIdentity? in
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue else { return nil }
            return BarcodeIdentity(value, isUPCE: code.type == .upce)
        }.first
        guard let barcode = identity?.digits else { return }

        hasScanned = true
        if let captureSession { cameraQueue.async { captureSession.stopRunning() } }

        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))

        dismiss(animated: true) { [onScan] in
            onScan?(barcode)
        }
    }
}
