import UIKit

final class PlayIconView: UIView {
    override func draw(_ rect: CGRect) {
        UIColor.black.setFill()
        UIRectFill(rect)
    }
}

final class CheckedStripView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let play = PlayIconView()
        play.accessibilityIdentifier = "figma.I2985_24400_1732_8193"
        addSubview(play)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
