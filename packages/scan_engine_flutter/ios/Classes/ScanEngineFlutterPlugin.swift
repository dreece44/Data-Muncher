import Flutter
import Photos
import UIKit

/// iOS half of the DataMuncher scan engine: storage totals, the Photos
/// library listing, and small greyscale thumbnails for photo analysis.
/// Permission prompts are handled by permission_handler.
public class ScanEngineFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "datamuncher/scan_engine", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ScanEngineFlutterPlugin(), channel: channel)
  }

  private let queue = DispatchQueue(label: "datamuncher.scan_engine", qos: .userInitiated)

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStorageStats":
      result(storageStats())
    case "listPhotoAssets":
      inBackground(result) { self.listPhotoAssets() }
    case "photoThumbnail":
      guard let args = call.arguments as? [String: Any],
        let id = args["id"] as? String,
        let size = args["size"] as? Int, size > 0
      else {
        result(FlutterError(code: "bad_args", message: "Expected id and size", details: nil))
        return
      }
      inBackground(result) { self.thumbnail(id: id, size: size) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func inBackground(_ result: @escaping FlutterResult, _ work: @escaping () -> Any?) {
    queue.async {
      let value = work()
      DispatchQueue.main.async { result(value) }
    }
  }

  /// Totals as shown in Settings → General → iPhone Storage.
  private func storageStats() -> [String: Int64]? {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    guard
      let values = try? home.resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
      ]),
      let total = values.volumeTotalCapacity,
      let free = values.volumeAvailableCapacityForImportantUsage
    else { return nil }
    return ["totalBytes": Int64(total), "freeBytes": free]
  }

  /// Every image the app is allowed to see (all of them with Full access,
  /// the chosen ones with Limited access).
  private func listPhotoAssets() -> [[String: Any]] {
    let assets = PHAsset.fetchAssets(with: .image, options: nil)
    var out: [[String: Any]] = []
    out.reserveCapacity(assets.count)
    assets.enumerateObjects { asset, _, _ in
      let resources = PHAssetResource.assetResources(for: asset)
      let original = resources.first { $0.type == .photo } ?? resources.first
      // "fileSize" isn't public API but is the standard way to get an asset's
      // size without loading it. Summing all resources counts edited versions
      // and Live Photo videos, which are freed too when the asset is deleted.
      let size = resources.reduce(Int64(0)) { total, resource in
        total + ((resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
      }
      var item: [String: Any] = [
        "id": asset.localIdentifier,
        "filename": original?.originalFilename ?? "\(asset.localIdentifier).jpg",
        "sizeBytes": size,
        "width": asset.pixelWidth,
        "height": asset.pixelHeight,
      ]
      if let created = asset.creationDate {
        item["createdAt"] = Int64(created.timeIntervalSince1970 * 1000)
      }
      if let modified = asset.modificationDate {
        item["modifiedAt"] = Int64(modified.timeIntervalSince1970 * 1000)
      }
      out.append(item)
    }
    return out
  }

  /// A size×size greyscale thumbnail (one byte per pixel, rows top to
  /// bottom), stretched to a square like the Dart decoders. Never downloads
  /// from iCloud; returns nil if there's no local image to draw.
  private func thumbnail(id: String, size: Int) -> FlutterStandardTypedData? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    else { return nil }

    let options = PHImageRequestOptions()
    options.isSynchronous = true  // Already on a background queue.
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    var image: UIImage?
    PHImageManager.default().requestImage(
      for: asset, targetSize: CGSize(width: size, height: size),
      contentMode: .aspectFill, options: options
    ) { result, _ in image = result }
    guard let cgImage = image?.cgImage else { return nil }

    var pixels = [UInt8](repeating: 0, count: size * size)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
          bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
      return true
    }
    return drawn ? FlutterStandardTypedData(bytes: Data(pixels)) : nil
  }
}
