import AVFoundation
import SwiftUI

#if os(macOS)
import AppKit

/// AVSampleBufferDisplayLayer'ı barındıran AppKit görünümü.
final class VideoContainerView: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) desteklenmiyor")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoLayerView: NSViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> VideoContainerView {
        VideoContainerView(videoLayer: videoLayer)
    }

    func updateNSView(_ nsView: VideoContainerView, context: Context) {}
}

#else
import UIKit

/// AVSampleBufferDisplayLayer'ı barındıran UIKit görünümü.
final class VideoContainerView: UIView {
    private let videoLayer: AVSampleBufferDisplayLayer

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) desteklenmiyor")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoLayerView: UIViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoContainerView {
        VideoContainerView(videoLayer: videoLayer)
    }

    func updateUIView(_ uiView: VideoContainerView, context: Context) {}
}
#endif
