import AppKit

/// Frames of windows ScreenCaptureKit refuses to capture.
///
/// ScreenCaptureKit only captures windows on a Space that is on screen: for a
/// window on another desktop (a full-screen app in front, say) it fails with
/// SCStreamErrorDomain -3811. `CGWindowListCreateImage` still returns the real,
/// current content of such windows. Apple deprecated it and hid it from the
/// macOS 15 headers, but the symbol is still in the system and works on 27, so
/// it is looked up at runtime: if it ever goes away this returns nil and the
/// previews fall back to the last frame they had.
///
/// Same Screen Recording permission as ScreenCaptureKit; frames stay in memory.
enum OffSpaceCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let create: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// `CGWindowListOption.optionIncludingWindow`, and
    /// `boundsIgnoreFraming | nominalResolution`: the window alone, no shadow,
    /// at 1x so a full-screen window is not a 20 MB bitmap.
    private static let listOption: UInt32 = 1 << 3
    private static let imageOption: UInt32 = (1 << 0) | (1 << 4)

    /// The window's current content, scaled so its longest edge is `maxEdge`
    /// pixels. Call off the main thread: it copies the whole window first.
    static func image(of id: CGWindowID, maxEdge: CGFloat) -> CGImage? {
        guard let create, let full = create(.null, listOption, id, imageOption)?.takeRetainedValue()
        else { return nil }
        let longest = CGFloat(max(full.width, full.height))
        guard longest > 0 else { return nil }
        let scale = min(1, maxEdge / longest)
        let width = max(1, Int(CGFloat(full.width) * scale))
        let height = max(1, Int(CGFloat(full.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// `CGImage` is immutable, so handing one between threads is safe; the type
/// just is not marked for it.
struct SendableImage: @unchecked Sendable {
    let image: CGImage?
}
