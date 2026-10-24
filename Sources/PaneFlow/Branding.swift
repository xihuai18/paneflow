import AppKit

enum PaneFlowBrand {
    static func image(size: CGFloat, template: Bool = false) -> NSImage {
        let image = NSImage(size:NSSize(width:size,height:size),flipped:false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scale(by: size / 100)
            transform.concat()
            if !template {
                let background = NSBezierPath(roundedRect:NSRect(x:10,y:10,width:80,height:80),xRadius:18,yRadius:18)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width:0,height:-1.5); shadow.set()
                NSColor.white.setFill(); background.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGradient(starting:NSColor(srgbRed:0.84,green:0.88,blue:0.93,alpha:1),ending:NSColor(srgbRed:0.99,green:0.99,blue:1,alpha:1))?.draw(in:background,angle:90)
                NSColor.white.withAlphaComponent(0.85).setStroke(); background.lineWidth = 0.8; background.stroke()
            }
            let frame = template ? NSRect(x:10,y:15,width:80,height:70) : NSRect(x:25,y:29,width:50,height:42)
            let outline = NSBezierPath(roundedRect:frame,xRadius:template ? 8 : 5,yRadius:template ? 8 : 5)
            if !template {
                NSColor.white.withAlphaComponent(0.92).setFill(); outline.fill()
                NSGraphicsContext.saveGraphicsState(); outline.addClip()
                let left = NSRect(x:frame.minX,y:frame.minY,width:frame.width*0.56,height:frame.height)
                NSGradient(starting:NSColor(srgbRed:0.25,green:0.48,blue:0.81,alpha:1),ending:NSColor(srgbRed:0.42,green:0.65,blue:0.93,alpha:1))?.draw(in:left,angle:90)
                NSGraphicsContext.restoreGraphicsState()
            }
            let divisions = NSBezierPath()
            let split = frame.minX+frame.width*0.56
            divisions.move(to:NSPoint(x:split,y:frame.minY)); divisions.line(to:NSPoint(x:split,y:frame.maxY))
            divisions.move(to:NSPoint(x:split,y:frame.midY)); divisions.line(to:NSPoint(x:frame.maxX,y:frame.midY))
            (template ? NSColor.black : NSColor(srgbRed:0.30,green:0.36,blue:0.44,alpha:1)).setStroke()
            outline.lineWidth = template ? 6 : 2.6; outline.stroke()
            divisions.lineWidth = outline.lineWidth; divisions.lineCapStyle = .round; divisions.stroke()
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "窗合 PaneFlow"
        return image
    }

    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for points in [16,32,128,256,512] {
            for scale in [1,2] {
                let pixels = points*scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
                      let context = NSGraphicsContext(bitmapImageRep:bitmap) else {
                    throw NSError(domain:"PaneFlowIcon",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not render app icon."])
                }
                bitmap.size = NSSize(width:pixels,height:pixels)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let bounds = NSRect(x:0,y:0,width:pixels,height:pixels)
                NSColor.clear.setFill(); bounds.fill(using:.copy)
                image(size:CGFloat(pixels)).draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1)
                NSGraphicsContext.restoreGraphicsState()
                guard let data = bitmap.representation(using:.png,properties:[:]) else {
                    throw NSError(domain:"PaneFlowIcon",code:2,userInfo:[NSLocalizedDescriptionKey:"Could not encode app icon."])
                }
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try data.write(to:directory.appendingPathComponent(name))
            }
        }
    }
}
