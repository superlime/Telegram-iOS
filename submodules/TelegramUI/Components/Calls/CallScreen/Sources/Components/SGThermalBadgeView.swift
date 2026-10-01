import Foundation
import UIKit
import Display

// MARK: Swiftgram - cooler video calls
/// Small pill in the top corner of the call screen showing the phone's thermal
/// level, battery temperature (when readable), battery and charging state, and
/// a second line while the call video is being throttled for heat.
final class SGThermalBadgeView: UIView {
    private let backgroundView: UIView
    private let dotView: UIView
    private let statusLabel: UILabel
    private let throttleLabel: UILabel

    private var currentBadge: PrivateCallScreen.State.ThermalBadge?
    private var currentSize: CGSize = .zero

    override init(frame: CGRect) {
        self.backgroundView = UIView()
        self.backgroundView.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        self.backgroundView.layer.cornerRadius = 10.0
        if #available(iOS 13.0, *) {
            self.backgroundView.layer.cornerCurve = .continuous
        }

        self.dotView = UIView()
        self.dotView.layer.cornerRadius = 4.0

        self.statusLabel = UILabel()
        self.statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .semibold)
        self.statusLabel.textColor = .white

        self.throttleLabel = UILabel()
        self.throttleLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .medium)
        self.throttleLabel.textColor = UIColor(white: 1.0, alpha: 0.92)

        super.init(frame: frame)

        self.isUserInteractionEnabled = false
        self.addSubview(self.backgroundView)
        self.addSubview(self.dotView)
        self.addSubview(self.statusLabel)
        self.addSubview(self.throttleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func color(for level: PrivateCallScreen.State.ThermalBadge.Level) -> UIColor {
        switch level {
        case .nominal:
            return UIColor(red: 0.20, green: 0.84, blue: 0.40, alpha: 1.0)
        case .fair:
            return UIColor(red: 1.00, green: 0.83, blue: 0.20, alpha: 1.0)
        case .serious:
            return UIColor(red: 1.00, green: 0.55, blue: 0.10, alpha: 1.0)
        case .critical:
            return UIColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1.0)
        }
    }

    func update(badge: PrivateCallScreen.State.ThermalBadge, constrainedWidth: CGFloat) -> CGSize {
        if self.currentBadge == badge {
            return self.currentSize
        }
        self.currentBadge = badge

        let levelColor = SGThermalBadgeView.color(for: badge.level)
        let horizontalInset: CGFloat = 9.0
        let verticalInset: CGFloat = 5.0
        let dotSize: CGFloat = 8.0
        let dotSpacing: CGFloat = 6.0
        let lineSpacing: CGFloat = 2.0
        let maxTextWidth = max(40.0, constrainedWidth - horizontalInset * 2.0 - dotSize - dotSpacing)

        var y = verticalInset
        var width: CGFloat = 0.0

        if let statusText = badge.statusText {
            self.statusLabel.isHidden = false
            self.dotView.isHidden = false
            self.statusLabel.text = statusText
            let size = self.statusLabel.sizeThatFits(CGSize(width: maxTextWidth, height: 100.0))
            let labelSize = CGSize(width: min(ceil(size.width), maxTextWidth), height: ceil(size.height))
            self.dotView.backgroundColor = levelColor
            self.dotView.frame = CGRect(x: horizontalInset, y: y + floor((labelSize.height - dotSize) * 0.5), width: dotSize, height: dotSize)
            self.statusLabel.frame = CGRect(origin: CGPoint(x: horizontalInset + dotSize + dotSpacing, y: y), size: labelSize)
            width = max(width, dotSize + dotSpacing + labelSize.width)
            y += labelSize.height
        } else {
            self.statusLabel.isHidden = true
            self.dotView.isHidden = true
        }

        if let throttleText = badge.throttleText {
            if badge.statusText != nil {
                y += lineSpacing
            }
            self.throttleLabel.isHidden = false
            self.throttleLabel.text = throttleText
            let size = self.throttleLabel.sizeThatFits(CGSize(width: maxTextWidth + dotSize + dotSpacing, height: 100.0))
            let labelSize = CGSize(width: min(ceil(size.width), maxTextWidth + dotSize + dotSpacing), height: ceil(size.height))
            self.throttleLabel.frame = CGRect(origin: CGPoint(x: horizontalInset, y: y), size: labelSize)
            width = max(width, labelSize.width)
            y += labelSize.height
        } else {
            self.throttleLabel.isHidden = true
        }

        // Tint the pill with the level colour while throttled, so the reason
        // for the lower video quality is visible at a glance.
        if badge.throttleText != nil {
            self.backgroundView.backgroundColor = levelColor.withMultipliedBrightnessBy(0.55).withAlphaComponent(0.75)
        } else {
            self.backgroundView.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        }

        let size = CGSize(width: ceil(width + horizontalInset * 2.0), height: ceil(y + verticalInset))
        self.backgroundView.frame = CGRect(origin: .zero, size: size)
        self.currentSize = size
        return size
    }
}
