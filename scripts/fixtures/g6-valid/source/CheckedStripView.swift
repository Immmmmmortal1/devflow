import UIKit

final class CheckedStripView: UIView {
    private let imageView = UIImageView(image: UIImage(named: "lovon_checked"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.accessibilityIdentifier = "figma.2985_24400"
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
