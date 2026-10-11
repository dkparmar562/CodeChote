import SwiftUI
import UIKit

/// An image the way Photos shows it: fitted to the screen at first, pinch to zoom, double-tap to zoom in or back
/// out, drag to pan when zoomed. Small images are not blown up past their real size.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingView { ZoomingView(image: image) }

    func updateUIView(_ view: ZoomingView, context: Context) {
        if view.imageView.image !== image { view.show(image) }
    }
}

final class ZoomingView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var lastBounds: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        show(image)
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = "Image, \(Int(image.size.width)) by \(Int(image.size.height))"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: UIImage) {
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBounds, bounds.width > 0, bounds.height > 0, let image = imageView.image, image.size.width > 0 else {
            centre()
            return
        }
        lastBounds = bounds.size
        // Fit the whole image; never enlarge a small one beyond 1:1 at first.
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        minimumZoomScale = min(fit, 1)
        maximumZoomScale = max(minimumZoomScale * 6, 3)
        zoomScale = minimumZoomScale
        centre()
    }

    /// Keeps the image in the middle when it is smaller than the screen.
    private func centre() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let target = min(maximumZoomScale, max(minimumZoomScale * 2.5, 1))
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
