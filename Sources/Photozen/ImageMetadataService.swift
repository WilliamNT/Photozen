import CoreLocation
import Foundation
import ImageIO

struct RawMetadataItem: Identifiable, Sendable, Equatable {
    let id: String
    let key: String
    let value: String
}

struct RawMetadataGroup: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let items: [RawMetadataItem]
}

struct PhotoMetadata: Equatable, Sendable {
    // Location
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let speed: Double?
    let direction: Double?
    var placename: String?

    // Camera & Hardware
    let cameraMake: String?
    let cameraModel: String?
    let lensMake: String?
    let lensModel: String?
    let software: String?

    // Exposure & Optics
    let focalLength: Double?
    let focalLength35mm: Int?
    let fNumber: Double?
    let exposureTime: Double?
    let iso: Int?
    let exposureBias: Double?
    let exposureProgram: String?
    let meteringMode: String?
    let flash: String?
    let whiteBalance: String?
    let digitalZoomRatio: Double?

    // Image & Color
    let pixelWidth: Int?
    let pixelHeight: Int?
    let colorModel: String?
    let colorProfile: String?
    let depth: Int?
    let dpiWidth: Double?
    let dpiHeight: Double?
    let orientation: String?

    // File & Dates
    let captureDate: Date?
    let fileSize: Int64?
    let fileFormat: String?

    // Complete Raw Metadata Groups
    let rawGroups: [RawMetadataGroup]

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var hasLocation: Bool {
        coordinate != nil
    }

    var formattedCoordinatesDecimal: String? {
        guard let lat = latitude, let lon = longitude else { return nil }
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), latDir, abs(lon), lonDir)
    }

    var formattedCoordinatesDMS: String? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return "\(Self.dms(for: lat, isLatitude: true)), \(Self.dms(for: lon, isLatitude: false))"
    }

    private static func dms(for value: Double, isLatitude: Bool) -> String {
        let absVal = abs(value)
        let deg = Int(absVal)
        let minFraction = (absVal - Double(deg)) * 60.0
        let min = Int(minFraction)
        let sec = (minFraction - Double(min)) * 60.0
        let dir: String
        if isLatitude {
            dir = value >= 0 ? "N" : "S"
        } else {
            dir = value >= 0 ? "E" : "W"
        }
        return String(format: "%d° %02d' %04.1f\" %@", deg, min, sec, dir)
    }

    var formattedAltitude: String? {
        guard let alt = altitude else { return nil }
        let feet = alt * 3.28084
        return String(format: "%.0f m (%.0f ft)", alt, feet)
    }

    var formattedSpeed: String? {
        guard let sp = speed, sp > 0 else { return nil }
        let kmh = sp * 3.6
        let mph = sp * 2.23694
        return String(format: "%.1f km/h (%.1f mph)", kmh, mph)
    }

    var formattedDirection: String? {
        guard let dir = direction else { return nil }
        return String(format: "%.0f°", dir)
    }

    var formattedCamera: String? {
        if let model = cameraModel {
            if let make = cameraMake, !model.localizedCaseInsensitiveContains(make) {
                return "\(make) \(model)"
            }
            return model
        }
        return cameraMake
    }

    var formattedAperture: String? {
        guard let f = fNumber else { return nil }
        return String(format: "ƒ/%.1f", f)
    }

    var formattedFocalLength: String? {
        guard let fl = focalLength else { return nil }
        if let eq = focalLength35mm, eq != Int(round(fl)) {
            return String(format: "%.0f mm (35mm: %d mm)", fl, eq)
        }
        return String(format: "%.0f mm", fl)
    }

    var formattedISO: String? {
        guard let iso = iso else { return nil }
        return "ISO \(iso)"
    }

    var formattedExposure: String? {
        guard let sec = exposureTime, sec > 0 else { return nil }
        if sec < 1.0 {
            let denom = Int(round(1.0 / sec))
            return "1/\(denom) s"
        } else {
            return String(format: "%.1f s", sec)
        }
    }

    var formattedExposureBias: String? {
        guard let ev = exposureBias else { return nil }
        if abs(ev) < 0.01 { return "0 EV" }
        return String(format: "%+.1f EV", ev)
    }

    var formattedDimensions: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    var formattedMegapixels: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        let mp = Double(w * h) / 1_000_000.0
        return String(format: "%.1f MP", mp)
    }

    var formattedDPI: String? {
        if let dw = dpiWidth, let dh = dpiHeight {
            if abs(dw - dh) < 0.5 {
                return String(format: "%.0f DPI", dw)
            } else {
                return String(format: "%.0f × %.0f DPI", dw, dh)
            }
        } else if let d = dpiWidth ?? dpiHeight {
            return String(format: "%.0f DPI", d)
        }
        return nil
    }

    var formattedApertureApple: String? {
        guard let f = fNumber else { return nil }
        if f == floor(f) {
            return String(format: "ƒ%.0f", f)
        } else if (f * 10).rounded() == f * 10 {
            return String(format: "ƒ%.1f", f)
        } else {
            return String(format: "ƒ%.2f", f)
        }
    }

    var formattedExposureBiasApple: String? {
        guard let ev = exposureBias else { return "0 ev" }
        if abs(ev) < 0.01 { return "0 ev" }
        return String(format: "%+.1f ev", ev)
    }

    var formattedFocalLengthApple: String? {
        if let eq = focalLength35mm {
            return "\(eq) mm"
        } else if let fl = focalLength {
            return String(format: "%.0f mm", fl)
        }
        return nil
    }

    var formattedMegapixelsApple: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        let mp = Double(w * h) / 1_000_000.0
        if mp >= 10.0 {
            return String(format: "%.0f MP", round(mp))
        } else {
            return String(format: "%.1f MP", mp)
        }
    }

    var formattedLensSubtitle: String? {
        if let lens = lensModel {
            let lower = lens.lowercased()
            if lower.contains("camera") && (lower.contains("iphone") || lower.contains("ipad")) {
                let focalStr = formattedFocalLengthApple ?? ""
                let apStr = formattedApertureApple ?? ""
                let specStr = [focalStr, apStr].filter { !$0.isEmpty }.joined(separator: " ")
                let specSuffix = specStr.isEmpty ? "" : " — \(specStr)"

                if lower.contains("front") {
                    return "Front Camera\(specSuffix)"
                } else if let f35 = focalLength35mm, f35 <= 16 {
                    return "Ultra Wide Camera\(specSuffix)"
                } else if let f35 = focalLength35mm, f35 >= 70 {
                    return "Telephoto Camera\(specSuffix)"
                } else {
                    return "Main Camera\(specSuffix)"
                }
            }
            return lens
        } else if let fl = formattedFocalLengthApple, let ap = formattedApertureApple {
            return "\(fl) \(ap)"
        }
        return nil
    }

    var formattedSummary: String {
        var lines: [String] = []
        if let cam = formattedCamera { lines.append("Camera: \(cam)") }
        if let lens = lensModel { lines.append("Lens: \(lens)") }
        var exposureLine: [String] = []
        if let fl = formattedFocalLength { exposureLine.append(fl) }
        if let ap = formattedAperture { exposureLine.append(ap) }
        if let exp = formattedExposure { exposureLine.append(exp) }
        if let iso = formattedISO { exposureLine.append(iso) }
        if !exposureLine.isEmpty { lines.append("Exposure: " + exposureLine.joined(separator: " • ")) }
        if let dim = formattedDimensions, let mp = formattedMegapixels { lines.append("Dimensions: \(dim) (\(mp))") }
        if let profile = colorProfile { lines.append("Color Profile: \(profile)") }
        if let coord = formattedCoordinatesDMS { lines.append("GPS: \(coord)") }
        if let place = placename { lines.append("Location: \(place)") }
        if let date = captureDate { lines.append("Date: \(date.formatted(date: .long, time: .standard))") }
        return lines.joined(separator: "\n")
    }
}

actor ImageMetadataService {
    static let shared = ImageMetadataService()

    private var cache: [String: PhotoMetadata] = [:]

    private init() {}

    func clearCache() {
        cache.removeAll()
    }

    func metadata(for path: String) async -> PhotoMetadata? {
        if let cached = cache[path] {
            return cached
        }

        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        // 1. Location / GPS
        var lat: Double?
        var lon: Double?
        var alt: Double?
        var sp: Double?
        var dir: Double?

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let rawLat = gps[kCGImagePropertyGPSLatitude] as? Double {
                let ref = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() ?? "N"
                lat = (ref == "S") ? -rawLat : rawLat
            }
            if let rawLon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let ref = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() ?? "E"
                lon = (ref == "W") ? -rawLon : rawLon
            }
            if let rawAlt = gps[kCGImagePropertyGPSAltitude] as? Double {
                let ref = gps[kCGImagePropertyGPSAltitudeRef] as? Int ?? 0
                alt = (ref == 1) ? -rawAlt : rawAlt
            }
            if let rawSpeed = gps[kCGImagePropertyGPSSpeed] as? Double {
                sp = rawSpeed
            }
            if let rawDir = gps[kCGImagePropertyGPSImgDirection] as? Double {
                dir = rawDir
            }
        }

        // 2. TIFF & EXIF
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]

        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let software = tiff?[kCGImagePropertyTIFFSoftware] as? String

        let lensMake = exif?[kCGImagePropertyExifLensMake] as? String
        let lensModel = exif?[kCGImagePropertyExifLensModel] as? String
        let focal = exif?[kCGImagePropertyExifFocalLength] as? Double
        let focal35 = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        let fNumber = exif?[kCGImagePropertyExifFNumber] as? Double
        let exposure = exif?[kCGImagePropertyExifExposureTime] as? Double
        let ev = exif?[kCGImagePropertyExifExposureBiasValue] as? Double
        let zoomRatio = exif?[kCGImagePropertyExifDigitalZoomRatio] as? Double

        var iso: Int?
        if let isos = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isos.first {
            iso = first
        } else if let isoVal = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            iso = isoVal
        }

        let exposureProgramStr = (exif?[kCGImagePropertyExifExposureProgram] as? Int).map { Self.decodeExposureProgram($0) }
        let meteringModeStr = (exif?[kCGImagePropertyExifMeteringMode] as? Int).map { Self.decodeMeteringMode($0) }
        let flashStr = (exif?[kCGImagePropertyExifFlash] as? Int).map { Self.decodeFlash($0) }
        let whiteBalanceStr = (exif?[kCGImagePropertyExifWhiteBalance] as? Int).map { Self.decodeWhiteBalance($0) }

        // 3. Image Dimensions & Color
        let pWidth = properties[kCGImagePropertyPixelWidth] as? Int
        let pHeight = properties[kCGImagePropertyPixelHeight] as? Int
        let colModel = properties[kCGImagePropertyColorModel] as? String
        let profName = properties[kCGImagePropertyProfileName] as? String
        let depth = properties[kCGImagePropertyDepth] as? Int
        let dpiW = properties[kCGImagePropertyDPIWidth] as? Double
        let dpiH = properties[kCGImagePropertyDPIHeight] as? Double
        let orientStr = (properties[kCGImagePropertyOrientation] as? Int).map { Self.decodeOrientation($0) }

        // 4. Dates
        var captureDate: Date?
        if let dateStr = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff?[kCGImagePropertyTIFFDateTime] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.timeZone = TimeZone.current
            captureDate = formatter.date(from: dateStr)
        }

        // File stats
        var fSize: Int64?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            fSize = attrs[.size] as? Int64
        }
        let fFormat = url.pathExtension.uppercased()

        // 5. Complete Raw Metadata Inspector
        let rawGroups = Self.extractRawGroups(from: properties)

        var meta = PhotoMetadata(
            latitude: lat,
            longitude: lon,
            altitude: alt,
            speed: sp,
            direction: dir,
            placename: nil,
            cameraMake: make?.trimmingCharacters(in: .whitespacesAndNewlines),
            cameraModel: model?.trimmingCharacters(in: .whitespacesAndNewlines),
            lensMake: lensMake?.trimmingCharacters(in: .whitespacesAndNewlines),
            lensModel: lensModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            software: software?.trimmingCharacters(in: .whitespacesAndNewlines),
            focalLength: focal,
            focalLength35mm: focal35,
            fNumber: fNumber,
            exposureTime: exposure,
            iso: iso,
            exposureBias: ev,
            exposureProgram: exposureProgramStr,
            meteringMode: meteringModeStr,
            flash: flashStr,
            whiteBalance: whiteBalanceStr,
            digitalZoomRatio: zoomRatio,
            pixelWidth: pWidth,
            pixelHeight: pHeight,
            colorModel: colModel,
            colorProfile: profName,
            depth: depth,
            dpiWidth: dpiW,
            dpiHeight: dpiH,
            orientation: orientStr,
            captureDate: captureDate,
            fileSize: fSize,
            fileFormat: fFormat,
            rawGroups: rawGroups
        )

        // Asynchronously resolve place name if coordinate exists
        if let lat, let lon {
            meta.placename = await Self.reverseGeocode(latitude: lat, longitude: lon)
        }

        cache[path] = meta
        return meta
    }

    private static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let loc = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        do {
            let marks = try await geocoder.reverseGeocodeLocation(loc)
            if let place = marks.first {
                var comps: [String] = []
                if let name = place.name, name != place.locality {
                    comps.append(name)
                }
                if let city = place.locality {
                    comps.append(city)
                }
                if let state = place.administrativeArea {
                    comps.append(state)
                }
                if let country = place.country {
                    comps.append(country)
                }
                return comps.joined(separator: ", ")
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func extractRawGroups(from properties: [CFString: Any]) -> [RawMetadataGroup] {
        var result: [RawMetadataGroup] = []

        // Top-level image properties
        var topItems: [RawMetadataItem] = []
        for (k, v) in properties {
            let keyStr = k as String
            if !(v is [CFString: Any]) && !(v is [String: Any]) {
                topItems.append(RawMetadataItem(id: "Top_\(keyStr)", key: keyStr, value: formatRawValue(v)))
            }
        }
        if !topItems.isEmpty {
            result.append(RawMetadataGroup(id: "Image", name: "Image Attributes", items: topItems.sorted(by: { $0.key < $1.key })))
        }

        // Sub-dictionaries
        let known: [(CFString, String)] = [
            (kCGImagePropertyExifDictionary, "EXIF (Shooting & Optics)"),
            (kCGImagePropertyTIFFDictionary, "TIFF (Camera & Device)"),
            (kCGImagePropertyGPSDictionary, "GPS (Location Coordinates)"),
            (kCGImagePropertyIPTCDictionary, "IPTC (Content & Rights)"),
            (kCGImagePropertyMakerAppleDictionary, "Apple Maker Notes"),
            (kCGImagePropertyJFIFDictionary, "JFIF"),
            (kCGImagePropertyPNGDictionary, "PNG")
        ]

        for (dictKey, dictName) in known {
            if let dict = properties[dictKey] as? [CFString: Any] {
                var items: [RawMetadataItem] = []
                for (k, v) in dict {
                    let kStr = k as String
                    items.append(RawMetadataItem(id: "\(dictName)_\(kStr)", key: kStr, value: formatRawValue(v)))
                }
                if !items.isEmpty {
                    result.append(RawMetadataGroup(id: dictName, name: dictName, items: items.sorted(by: { $0.key < $1.key })))
                }
            }
        }

        // Any other dictionaries
        for (k, v) in properties {
            let keyStr = k as String
            if let dict = v as? [CFString: Any], !known.contains(where: { ($0.0 as String) == keyStr }) {
                var items: [RawMetadataItem] = []
                for (subK, subV) in dict {
                    let subKStr = subK as String
                    items.append(RawMetadataItem(id: "\(keyStr)_\(subKStr)", key: subKStr, value: formatRawValue(subV)))
                }
                if !items.isEmpty {
                    result.append(RawMetadataGroup(id: keyStr, name: keyStr, items: items.sorted(by: { $0.key < $1.key })))
                }
            }
        }

        return result
    }

    private static func formatRawValue(_ value: Any) -> String {
        if let arr = value as? [Any] {
            return arr.map { "\($0)" }.joined(separator: ", ")
        }
        if let d = value as? Double {
            if d.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0f", d)
            }
            return String(format: "%.4f", d)
        }
        return "\(value)"
    }

    private static func decodeExposureProgram(_ code: Int) -> String {
        switch code {
        case 1: return "Manual"
        case 2: return "Normal Program (Program AE)"
        case 3: return "Aperture Priority (Av)"
        case 4: return "Shutter Priority (Tv)"
        case 5: return "Creative Program"
        case 6: return "Action Program"
        case 7: return "Portrait Mode"
        case 8: return "Landscape Mode"
        default: return "Mode \(code)"
        }
    }

    private static func decodeMeteringMode(_ code: Int) -> String {
        switch code {
        case 1: return "Average"
        case 2: return "Center-Weighted Average"
        case 3: return "Spot"
        case 4: return "Multi-Spot"
        case 5: return "Multi-Segment / Pattern"
        case 6: return "Partial"
        default: return "Mode \(code)"
        }
    }

    private static func decodeFlash(_ code: Int) -> String {
        let fired = (code & 1) != 0
        return fired ? "Flash Fired" : "Flash Off, Did Not Fire"
    }

    private static func decodeWhiteBalance(_ code: Int) -> String {
        switch code {
        case 0: return "Auto White Balance"
        case 1: return "Manual White Balance"
        default: return "Custom (\(code))"
        }
    }

    private static func decodeOrientation(_ code: Int) -> String {
        switch code {
        case 1: return "1 (Normal, 0°)"
        case 3: return "3 (Rotate 180°)"
        case 6: return "6 (Rotate 90° CW)"
        case 8: return "8 (Rotate 90° CCW)"
        default: return "\(code)"
        }
    }
}
