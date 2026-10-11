//
//  CEFBrowserOptions.swift
//  NucleantCEF
//
//  What a browser is made with, and what its frames have cost — the same on
//  every platform, read by each platform's `CEFBrowserBase`.
//

/// How a browser renders.
public struct CEFBrowserOptions: Sendable {
    /// GPU frames (IOSurfaces) when true — the fast path. False takes CEF's
    /// CPU buffer instead, for a machine where the GPU path misbehaves. In
    /// the browser build the page draws itself, and this is not read.
    public var sharedTexture: Bool
    /// Frames per second, 1…60. In the browser build the browser paces the
    /// page, and this is not read.
    public var frameRate: Int
    /// Page background, ARGB, shown where the page draws nothing. Opaque
    /// white is a browser's usual; clear lets the view behind show through.
    public var backgroundColor: UInt32

    public init(sharedTexture: Bool = true, frameRate: Int = 60, backgroundColor: UInt32 = 0xFFFF_FFFF) {
        self.sharedTexture = sharedTexture
        self.frameRate = frameRate
        self.backgroundColor = backgroundColor
    }
}

/// What a browser's frames have cost so far — for telling the GPU path from
/// the CPU fallback, and for seeing what a frame's copy takes. All zero in
/// the browser build, where no frame passes through the app.
public struct CEFFrameStatistics: Sendable {
    /// Frames that arrived as IOSurfaces and were copied GPU to GPU.
    public var acceleratedFrames = 0
    /// Frames that arrived as CPU buffers.
    public var softwareFrames = 0
    /// Time spent copying frames into the view's texture, waiting for the
    /// GPU included, in seconds — in total, and the longest single copy.
    public var totalCopyTime: Double = 0
    public var longestCopyTime: Double = 0

    public var averageCopyTime: Double {
        let frames = acceleratedFrames + softwareFrames
        return frames > 0 ? totalCopyTime / Double(frames) : 0
    }
}
