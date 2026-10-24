import AppKit

/// A native material surface with one continuous outline, including its anchor pointer.
final class PaletteChrome: NSView {
    static let pointerHeight: CGFloat = 12
    let material = NSVisualEffectView()
    private let outline = CAShapeLayer()
    private let surfaceMask = CAShapeLayer()
    private let pointsUp: Bool
    private let pointerX: CGFloat

    init(content: NSView, pointsUp: Bool, pointerX: CGFloat) {
        self.pointsUp = pointsUp; self.pointerX = pointerX
        super.init(frame: .zero)
        wantsLayer = true
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.mask = surfaceMask
        addSubview(material)
        outline.fillColor = nil; outline.lineWidth = 1
        layer?.addSublayer(outline)
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor, constant: pointsUp ? Self.pointerHeight : 0),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: pointsUp ? 0 : -Self.pointerHeight)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        material.frame = bounds
        let path = bubblePath(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surfaceMask.frame = bounds; surfaceMask.path = path
        outline.frame = bounds; outline.path = path
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.strokeColor = NSColor.separatorColor.cgColor
        }
        CATransaction.commit()
        window?.invalidateShadow()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    private func bubblePath(in rect: CGRect) -> CGPath {
        // Build the upper-pointer shape, then reflect it for a panel above its anchor.
        let r: CGFloat = 13, h = Self.pointerHeight
        let left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY - h
        let x = min(right - r - 18, max(left + r + 18, pointerX))
        let p = CGMutablePath()
        p.move(to: CGPoint(x:left+r,y:bottom))
        p.addLine(to: CGPoint(x:right-r,y:bottom))
        p.addQuadCurve(to:CGPoint(x:right,y:bottom+r),control:CGPoint(x:right,y:bottom))
        p.addLine(to:CGPoint(x:right,y:top-r))
        p.addQuadCurve(to:CGPoint(x:right-r,y:top),control:CGPoint(x:right,y:top))
        p.addLine(to:CGPoint(x:x+17,y:top))
        p.addCurve(to:CGPoint(x:x+5,y:top+9),control1:CGPoint(x:x+11,y:top),control2:CGPoint(x:x+9,y:top+5))
        p.addQuadCurve(to:CGPoint(x:x-5,y:top+9),control:CGPoint(x:x,y:top+h+5))
        p.addCurve(to:CGPoint(x:x-17,y:top),control1:CGPoint(x:x-9,y:top+5),control2:CGPoint(x:x-11,y:top))
        p.addLine(to:CGPoint(x:left+r,y:top))
        p.addQuadCurve(to:CGPoint(x:left,y:top-r),control:CGPoint(x:left,y:top))
        p.addLine(to:CGPoint(x:left,y:bottom+r))
        p.addQuadCurve(to:CGPoint(x:left+r,y:bottom),control:CGPoint(x:left,y:bottom))
        p.closeSubpath()
        if pointsUp { return p }
        var reflection = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:bounds.height)
        return p.copy(using:&reflection) ?? p
    }
}
