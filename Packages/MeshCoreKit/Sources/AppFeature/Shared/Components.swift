import CoreImage.CIFilterBuiltins
import MeshCoreProtocol
import SwiftUI
#if canImport(VisionKit)
import VisionKit
#endif

/// Renders a string as a QR code.
struct QRCodeView: View {
  let text: String

  var body: some View {
    if let image = Self.render(text) {
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .accessibilityLabel("QR code")
    } else {
      ContentUnavailableView("Couldn't create QR code", systemImage: "qrcode")
    }
  }

  static func render(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

/// A sheet showing a share link as a QR code with copy/share actions.
struct ShareLinkSheet: View {
  let title: String
  let subtitle: String?
  let link: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          QRCodeView(text: link)
            .frame(maxWidth: 280)
            .padding()
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
          if let subtitle {
            Text(subtitle)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          Text(link)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .truncationMode(.middle)
          HStack {
            Button {
              UIPasteboard.general.string = link
            } label: {
              Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            if let url = URL(string: link) {
              ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
              }
              .buttonStyle(.borderedProminent)
            }
          }
        }
        .padding()
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

/// Scans a QR code with the camera (VisionKit), falling back to paste.
struct QRScannerView: View {
  let onScan: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        #if canImport(VisionKit) && !targetEnvironment(simulator)
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
          DataScannerRepresentable { value in
            onScan(value)
            dismiss()
          }
          .ignoresSafeArea()
        } else {
          unavailable
        }
        #else
        unavailable
        #endif
      }
      .navigationTitle("Scan QR Code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Paste") {
            if let text = UIPasteboard.general.string {
              onScan(text)
              dismiss()
            }
          }
        }
      }
    }
  }

  private var unavailable: some View {
    ContentUnavailableView(
      "Camera unavailable",
      systemImage: "camera",
      description: Text("Copy a meshcore:// link and tap Paste instead.")
    )
  }
}

#if canImport(VisionKit) && !targetEnvironment(simulator)
private struct DataScannerRepresentable: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      isHighlightingEnabled: true
    )
    controller.delegate = context.coordinator
    try? controller.startScanning()
    return controller
  }

  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let onScan: (String) -> Void
    private var didScan = false

    init(onScan: @escaping (String) -> Void) {
      self.onScan = onScan
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      guard !didScan else { return }
      for item in addedItems {
        if case let .barcode(barcode) = item, let value = barcode.payloadStringValue {
          didScan = true
          dataScanner.stopScanning()
          onScan(value)
          return
        }
      }
    }
  }
}
#endif

/// Icon for a node type.
struct NodeAvatar: View {
  let type: NodeType
  var size: CGFloat = 36

  var body: some View {
    Image(systemName: type.symbolName)
      .font(.system(size: size * 0.45, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(type.tint.gradient, in: Circle())
      .accessibilityLabel(type.displayName)
  }
}

struct ChannelAvatar: View {
  let channel: ChannelInfo?
  var size: CGFloat = 36

  var body: some View {
    Image(systemName: channel?.isPublic == true ? "globe" : (channel?.isHashtag == true ? "number" : "lock.fill"))
      .font(.system(size: size * 0.45, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Color.teal.gradient, in: Circle())
  }
}

/// A labelled value row for detail screens.
struct ValueRow: View {
  let title: String
  let value: String
  var monospaced = false

  var body: some View {
    LabeledContent(title) {
      Text(value)
        .font(monospaced ? .callout.monospaced() : .callout)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

/// Small capsule for metadata such as hops and SNR.
struct InfoTag: View {
  let text: String
  var systemImage: String?

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage { Image(systemName: systemImage) }
      Text(text)
    }
    .font(.caption2)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(.quaternary, in: Capsule())
  }
}

struct TelemetryList: View {
  let readings: [TelemetryReading]

  var body: some View {
    ForEach(readings) { reading in
      LabeledContent {
        Text(reading.formattedValue).monospacedDigit()
      } label: {
        Text(reading.name)
        Text("Channel \(reading.channel)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
